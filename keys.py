"""
Cross-platform keyboard shim: the small slice of the `keyboard` library API the
app uses (hook / unhook / write / send + KEY_DOWN / KEY_UP), plus paste().

  - Windows: a thin re-export of the `keyboard` library (unchanged behavior).
  - macOS:   a native Quartz implementation. A listen-only CGEventTap watches
             keys (needs Input Monitoring permission) and CGEventPost injects
             text / shortcuts (needs Accessibility permission). We deliberately
             avoid pynput here: its listener queries the keyboard layout from a
             background thread, which macOS 14+ aborts the process for.

Key names follow the `keyboard` library style ("right ctrl", "f13", "a"). On
macOS the modifiers are named "right option", "right cmd", "fn", etc., and the
Windows-style spellings ("right alt", "right command", ...) are accepted as
aliases so a roaming settings file still works.
"""

import sys
import threading
import queue
import time

IS_MAC = sys.platform == "darwin"

KEY_DOWN = "down"
KEY_UP = "up"

if not IS_MAC:
    # -------------------------------------------------------------- Windows
    import keyboard as _kb

    KEY_DOWN = _kb.KEY_DOWN
    KEY_UP = _kb.KEY_UP
    DEFAULT_HOTKEY = "right ctrl"
    PASTE_LABEL = "Ctrl+V"

    def hook(callback):
        return _kb.hook(callback)

    def unhook(handle):
        _kb.unhook(handle)

    def write(text, delay=0):
        _kb.write(text, delay=delay)

    def send(combo):
        _kb.send(combo)

    def paste():
        _kb.send("ctrl+v")

    def normalize(name):
        return name

    def request_permissions():
        return True

    def permission_problems():
        return []

else:
    # ---------------------------------------------------------------- macOS
    import Quartz

    DEFAULT_HOTKEY = "right option"
    PASTE_LABEL = "Cmd+V"

    # Tag on events we inject so our own tap ignores them.
    _MAGIC = 0x50414B54  # "PAKT"

    # Virtual keycodes (US ANSI positions; hotkeys are layout-independent).
    _KEYCODES = {
        # modifiers
        55: "cmd", 54: "right cmd", 56: "shift", 60: "right shift",
        58: "option", 61: "right option", 59: "ctrl", 62: "right ctrl",
        63: "fn", 57: "caps lock",
        # function keys
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18",
        80: "f19", 90: "f20",
        # navigation / editing
        36: "enter", 48: "tab", 49: "space", 51: "backspace", 53: "esc",
        117: "delete", 115: "home", 119: "end", 116: "page up",
        121: "page down", 123: "left", 124: "right", 125: "down", 126: "up",
        114: "insert",
        # letters / digits / punctuation
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l",
        38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 50: "`",
        # keypad
        65: "num .", 67: "num *", 69: "num +", 71: "num clear", 75: "num /",
        76: "num enter", 78: "num -", 81: "num =", 82: "num 0", 83: "num 1",
        84: "num 2", 85: "num 3", 86: "num 4", 87: "num 5", 88: "num 6",
        89: "num 7", 91: "num 8", 92: "num 9",
    }
    _NAME_TO_CODE = {v: k for k, v in _KEYCODES.items()}

    # Device-dependent flag bits (IOLLEvent.h NX_DEVICE*KEYMASK) tell left and
    # right modifiers apart, so releasing right Option while left Option is
    # still held is still seen as a release.
    _MOD_BITS = {
        59: 0x00000001,   # left ctrl
        62: 0x00002000,   # right ctrl
        56: 0x00000002,   # left shift
        60: 0x00000004,   # right shift
        55: 0x00000008,   # left cmd
        54: 0x00000010,   # right cmd
        58: 0x00000020,   # left option
        61: 0x00000040,   # right option
        63: 0x00800000,   # fn (kCGEventFlagMaskSecondaryFn)
        57: 0x00010000,   # caps lock (alpha shift)
    }

    _ALIASES = {
        "right alt": "right option", "alt gr": "right option",
        "altgr": "right option", "alt": "option", "left alt": "option",
        "left option": "option",
        "right command": "right cmd", "command": "cmd", "left cmd": "cmd",
        "left command": "cmd", "right windows": "right cmd",
        "windows": "cmd", "left windows": "cmd",
        "right control": "right ctrl", "control": "ctrl", "left ctrl": "ctrl",
        "left control": "ctrl", "left shift": "shift",
        "return": "enter", "escape": "esc", "spacebar": "space",
    }

    _COMBO_FLAGS = {
        "shift": Quartz.kCGEventFlagMaskShift,
        "ctrl": Quartz.kCGEventFlagMaskControl,
        "option": Quartz.kCGEventFlagMaskAlternate,
        "cmd": Quartz.kCGEventFlagMaskCommand,
    }

    def normalize(name):
        n = (name or "").strip().lower()
        return _ALIASES.get(n, n)

    class _Event:
        __slots__ = ("name", "event_type", "scan_code")

        def __init__(self, name, event_type, scan_code):
            self.name = name
            self.event_type = event_type
            self.scan_code = scan_code

    # ---- listening -------------------------------------------------------
    class _Tap:
        """One shared CGEventTap on its own CFRunLoop thread. Events are handed
        to a dispatcher thread so slow handlers (e.g. a transcription on key
        release) never stall the tap."""

        def __init__(self):
            self._callbacks = {}
            self._next = 1
            self._lock = threading.Lock()
            self._tap = None
            self._loop = None
            self._q = queue.Queue()
            self._ready = threading.Event()
            self.error = None
            threading.Thread(target=self._run, name="keys-tap",
                             daemon=True).start()
            threading.Thread(target=self._dispatch, name="keys-dispatch",
                             daemon=True).start()
            self._ready.wait(5)

        def _run(self):
            mask = (Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
                    | Quartz.CGEventMaskBit(Quartz.kCGEventKeyUp)
                    | Quartz.CGEventMaskBit(Quartz.kCGEventFlagsChanged))
            tap = Quartz.CGEventTapCreate(
                Quartz.kCGSessionEventTap, Quartz.kCGHeadInsertEventTap,
                Quartz.kCGEventTapOptionListenOnly, mask, self._on_event, None)
            if tap is None:
                self.error = ("cannot watch the keyboard - allow Parakeet "
                              "Dictate under System Settings > Privacy & "
                              "Security > Input Monitoring, then relaunch")
                self._ready.set()
                return
            self._tap = tap
            src = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
            self._loop = Quartz.CFRunLoopGetCurrent()
            Quartz.CFRunLoopAddSource(self._loop, src,
                                      Quartz.kCFRunLoopCommonModes)
            Quartz.CGEventTapEnable(tap, True)
            self._ready.set()
            Quartz.CFRunLoopRun()

        def _on_event(self, proxy, etype, event, refcon):
            try:
                if etype in (Quartz.kCGEventTapDisabledByTimeout,
                             Quartz.kCGEventTapDisabledByUserInput):
                    if self._tap is not None:
                        Quartz.CGEventTapEnable(self._tap, True)
                    return event
                if Quartz.CGEventGetIntegerValueField(
                        event, Quartz.kCGEventSourceUserData) == _MAGIC:
                    return event
                code = Quartz.CGEventGetIntegerValueField(
                    event, Quartz.kCGKeyboardEventKeycode)
                if etype == Quartz.kCGEventFlagsChanged:
                    bit = _MOD_BITS.get(code)
                    if bit is None:
                        return event
                    down = bool(Quartz.CGEventGetFlags(event) & bit)
                    kind = KEY_DOWN if down else KEY_UP
                elif etype == Quartz.kCGEventKeyDown:
                    kind = KEY_DOWN
                elif etype == Quartz.kCGEventKeyUp:
                    kind = KEY_UP
                else:
                    return event
                name = _KEYCODES.get(code, f"key {code}")
                self._q.put(_Event(name, kind, code))
            except Exception as e:
                print(f"[keys] tap error: {e}", file=sys.stderr)
            return event

        def _dispatch(self):
            while True:
                ev = self._q.get()
                with self._lock:
                    cbs = list(self._callbacks.values())
                for cb in cbs:
                    try:
                        cb(ev)
                    except Exception as e:
                        print(f"[keys] handler error: {e}", file=sys.stderr)

        def add(self, cb):
            with self._lock:
                h = self._next
                self._next += 1
                self._callbacks[h] = cb
                return h

        def remove(self, h):
            with self._lock:
                self._callbacks.pop(h, None)

    _tap = None
    _tap_lock = threading.Lock()

    def hook(callback):
        """Call callback(event) for every key down/up. Raises RuntimeError if
        macOS won't let us watch the keyboard (Input Monitoring not granted)."""
        global _tap
        with _tap_lock:
            if _tap is None or _tap.error:
                _tap = _Tap()
            if _tap.error:
                raise RuntimeError(_tap.error)
            return _tap.add(callback)

    def unhook(handle):
        if _tap is not None:
            _tap.remove(handle)

    # ---- injecting -------------------------------------------------------
    def _post(code, down, flags=0, text=None):
        ev = Quartz.CGEventCreateKeyboardEvent(None, code, down)
        # Explicit flags: a physically held hotkey modifier (e.g. right Option
        # during continuous dictation) must not alter the injected characters.
        Quartz.CGEventSetFlags(ev, flags)
        if text is not None:
            # length is in UTF-16 units (non-BMP characters need two)
            Quartz.CGEventKeyboardSetUnicodeString(
                ev, len(text.encode("utf-16-le")) // 2, text)
        Quartz.CGEventSetIntegerValueField(
            ev, Quartz.kCGEventSourceUserData, _MAGIC)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)

    def _tap_key(code, flags=0):
        _post(code, True, flags)
        _post(code, False, flags)

    def write(text, delay=0):
        """Type text at the cursor as Unicode key events (clipboard untouched).
        One character per event pair: some apps drop multi-character events."""
        pause = max(delay, 0.002)
        for ch in text:
            if ch in "\r\n":
                _tap_key(36)          # Return
            elif ch == "\t":
                _tap_key(48)          # Tab
            else:
                _post(0, True, 0, ch)
                _post(0, False, 0, ch)
            time.sleep(pause)

    def send(combo):
        """Press a combo like 'tab', 'shift+tab', 'cmd+v'."""
        parts = [normalize(p) for p in combo.split("+")]
        flags = 0
        for p in parts[:-1]:
            base = p.replace("right ", "")
            flags |= _COMBO_FLAGS.get(base, 0)
        code = _NAME_TO_CODE.get(parts[-1])
        if code is None:
            raise ValueError(f"unknown key: {parts[-1]}")
        _tap_key(code, flags)

    def paste():
        send("cmd+v")

    # ---- permissions -----------------------------------------------------
    def _accessibility_ok(prompt=False):
        try:
            import HIServices
            if prompt:
                return bool(HIServices.AXIsProcessTrustedWithOptions(
                    {HIServices.kAXTrustedCheckOptionPrompt: True}))
            return bool(HIServices.AXIsProcessTrusted())
        except Exception:
            try:
                from ApplicationServices import AXIsProcessTrusted
                return bool(AXIsProcessTrusted())
            except Exception:
                return True   # can't tell; don't nag

    def _listen_ok(prompt=False):
        try:
            if prompt and hasattr(Quartz, "CGRequestListenEventAccess"):
                return bool(Quartz.CGRequestListenEventAccess())
            if hasattr(Quartz, "CGPreflightListenEventAccess"):
                return bool(Quartz.CGPreflightListenEventAccess())
        except Exception:
            pass
        return True

    def request_permissions():
        """Trigger the system prompts for Input Monitoring (hotkey) and
        Accessibility (typing/pasting). Returns True if both are granted."""
        a = _listen_ok(prompt=True)
        b = _accessibility_ok(prompt=True)
        return a and b

    def permission_problems():
        out = []
        if not _listen_ok():
            out.append("Input Monitoring")
        if not _accessibility_ok():
            out.append("Accessibility")
        return out
