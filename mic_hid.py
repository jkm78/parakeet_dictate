"""
Generic HID button support for Parakeet Dictate (Windows via pywinusb, macOS
via hidapi).

Nothing device-specific is hardcoded. The GUI lets the user pick a HID device
and press whatever button they want; learn_binding() watches the reports and
works out which byte/bit changed. That binding is stored in settings, and
MicButtonReader replays it at runtime to fire press/release callbacks.
"""

import sys
import threading
import time

IS_MAC = sys.platform == "darwin"


def _popcount(b):
    return bin(b).count("1")


# ---------------------------------------------------------------------------
# Backend: pywinusb on Windows; on macOS a small hidapi wrapper that mimics the
# bits of pywinusb's HidDevice we use (open / set_raw_data_handler / close).
# ---------------------------------------------------------------------------
class _HidapiDevice:
    """One HID interface opened through hidapi, read on a background thread."""

    def __init__(self, info):
        self._info = info
        self.vendor_id = info.get("vendor_id")
        self.product_id = info.get("product_id")
        self.product_name = info.get("product_string") or ""
        self.vendor_name = info.get("manufacturer_string") or ""
        self.usage_page = info.get("usage_page")
        self.usage = info.get("usage")
        self._dev = None
        self._handler = None
        self._stop = threading.Event()
        self._thread = None

    def open(self):
        import hid
        d = hid.device()
        d.open_path(self._info["path"])
        self._dev = d
        self._stop.clear()

    def set_raw_data_handler(self, handler):
        self._handler = handler
        if self._thread is None and self._dev is not None:
            self._thread = threading.Thread(target=self._read_loop, daemon=True)
            self._thread.start()

    def _read_loop(self):
        while not self._stop.is_set():
            try:
                data = self._dev.read(64, 100)   # 100 ms timeout
            except Exception as e:
                if not self._stop.is_set():
                    print(f"[hid] read failed: {e}")
                return
            if data and self._handler is not None:
                try:
                    self._handler(list(data))
                except Exception as e:
                    print(f"[hid] handler: {e}")

    def close(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=0.5)
            self._thread = None
        if self._dev is not None:
            try:
                self._dev.close()
            except Exception:
                pass
            self._dev = None


def _iface_key(dev):
    """Identifies one interface of a multi-interface device (macOS only)."""
    up, u = getattr(dev, "usage_page", None), getattr(dev, "usage", None)
    return None if up is None else f"{up:04x}:{u:04x}"


def _get_devices(vid=None, pid=None):
    """HID device objects (all, or those matching vid/pid). On macOS each
    interface of a device is its own entry, like pywinusb's collections."""
    if IS_MAC:
        import hid
        out = []
        for info in hid.enumerate(vid or 0, pid or 0):
            out.append(_HidapiDevice(info))
        return out
    from pywinusb import hid
    if vid is None:
        return hid.HidDeviceFilter().get_devices()
    return hid.HidDeviceFilter(vendor_id=vid, product_id=pid).get_devices()


def _backend_error():
    try:
        if IS_MAC:
            import hid  # noqa: F401
        else:
            from pywinusb import hid  # noqa: F401
        return None
    except Exception as e:
        return e


def list_hid_devices():
    """Return [{vid, pid, product, vendor}] for all HID devices."""
    err = _backend_error()
    if err is not None:
        print(f"[hid] HID backend unavailable: {err}")
        return []
    out, seen = [], set()
    for d in _get_devices():
        key = (d.vendor_id, d.product_id, d.product_name)
        if key in seen:
            continue
        seen.add(key)
        out.append({
            "vid": d.vendor_id,
            "pid": d.product_id,
            "product": (d.product_name or "").strip() or "(unknown)",
            "vendor": (d.vendor_name or "").strip(),
        })
    return out


class ButtonLearner:
    """Collect reports from a device for a short window, then infer a binding.

    Result (or None) lands in .result once .done is set. Binding shape:
        {"byte_index": int, "match": "bitmask", "mask": int}
        {"byte_index": int, "match": "value",   "value": int}
    """

    def __init__(self):
        self.reports = []
        self.done = threading.Event()
        self.result = None

    def start(self, vid, pid, window=5.0):
        threading.Thread(target=self._run, args=(vid, pid, window),
                         daemon=True).start()

    def _run(self, vid, pid, window):
        err = _backend_error()
        if err is not None:
            print(f"[hid] {err}")
            self.done.set()
            return
        devs = _get_devices(vid, pid)
        if not devs:
            self.done.set()
            return
        if IS_MAC and len(devs) > 1:
            self._run_multi(devs, window)
            return
        dev = devs[0]
        got = threading.Event()

        def on_report(data):
            self.reports.append(bytes(data))
            # once we've seen at least two distinct reports (idle + press),
            # we can infer immediately instead of waiting out the window.
            if len({r for r in self.reports}) >= 2:
                got.set()

        try:
            dev.open()
            dev.set_raw_data_handler(on_report)
            got.wait(timeout=window)
            # brief settle so we also capture the release report if it's mid-flight
            if got.is_set():
                time.sleep(0.25)
        except Exception as e:
            print(f"[hid] learn open failed (is Dragon holding the mic?): {e}")
        finally:
            try:
                dev.close()
            except Exception:
                pass
        self.result = self._infer()
        self.done.set()

    def _run_multi(self, devs, window):
        """macOS: a device's interfaces are separate entries and we can't tell
        which one carries the buttons, so watch them all and bind to whichever
        one changed. The interface is stored in the binding as "iface"."""
        per = {}            # iface key -> list of reports
        got = threading.Event()
        opened = []

        def make_handler(key):
            def on_report(data):
                rs = per.setdefault(key, [])
                rs.append(bytes(data))
                if len(set(rs)) >= 2:
                    got.set()
            return on_report

        for dev in devs:
            try:
                dev.open()
                dev.set_raw_data_handler(make_handler(_iface_key(dev)))
                opened.append(dev)
            except Exception as e:
                print(f"[hid] could not open interface {_iface_key(dev)}: {e}")
        try:
            got.wait(timeout=window)
            if got.is_set():
                time.sleep(0.25)
        finally:
            for dev in opened:
                dev.close()
        for key, reports in per.items():
            if len(set(reports)) >= 2:
                self.reports = reports
                res = self._infer()
                if res is not None:
                    if key is not None:
                        res["iface"] = key
                    self.result = res
                    break
        self.done.set()

    def _infer(self):
        uniq = []
        for r in self.reports:
            if r not in uniq:
                uniq.append(r)
        if len(uniq) < 2:
            return None
        # idle = the resting report (fewest bits set overall)
        idle = min(uniq, key=lambda r: sum(_popcount(x) for x in r))
        # prefer a bit that turns ON when pressed
        for r in uniq:
            if r == idle:
                continue
            n = min(len(r), len(idle))
            for i in range(n):
                newly = r[i] & (~idle[i] & 0xFF)
                if newly:
                    return {"byte_index": i, "match": "bitmask", "mask": newly}
        # fallback: a byte that changes to a distinct value
        for r in uniq:
            if r == idle:
                continue
            n = min(len(r), len(idle))
            for i in range(n):
                if r[i] != idle[i]:
                    return {"byte_index": i, "match": "value", "value": r[i]}
        return None


def describe(binding):
    if not binding:
        return "none"
    i = binding.get("byte_index")
    if binding.get("match") == "value":
        return f"byte {i} = 0x{binding['value']:02x}"
    return f"byte {i} bit 0x{binding['mask']:02x}"


def binding_pressed(binding, data):
    """Is `binding` currently pressed in this raw report? Works for any button
    binding (byte/bitmask or byte/value)."""
    if not binding:
        return False
    i = binding.get("byte_index", 0)
    if i >= len(data):
        return False
    if binding.get("match") == "value":
        return data[i] == binding.get("value")
    return bool(data[i] & binding.get("mask", 0))


class MicButtonReader:
    """Open a HID device and drive callbacks from learned button bindings.

    The Dictate button uses on_press/on_release (hold or toggle). Each entry in
    `actions` is a (binding, callback) pair fired once on the press edge — used
    for momentary buttons like Tab Forward / Tab Backward that emit a keystroke.
    All buttons are read from the same report stream (one HID collection)."""

    def __init__(self, vid, pid, binding, on_press, on_release, actions=None):
        self.vid = vid
        self.pid = pid
        self.binding = binding
        self.on_press = on_press
        self.on_release = on_release
        self.actions = list(actions or [])
        self._action_down = [False] * len(self.actions)
        self._dev = None
        self._down = False
        self._ok = False

    def available(self):
        return self._ok

    def _on_report(self, data):
        pressed = binding_pressed(self.binding, data)
        if pressed and not self._down:
            self._down = True
            try:
                self.on_press()
            except Exception as e:
                print(f"[mic] on_press: {e}")
        elif not pressed and self._down:
            self._down = False
            try:
                self.on_release()
            except Exception as e:
                print(f"[mic] on_release: {e}")
        # momentary action buttons (fire once per press edge)
        for idx, (binding, callback) in enumerate(self.actions):
            down = binding_pressed(binding, data)
            if down and not self._action_down[idx]:
                self._action_down[idx] = True
                try:
                    callback()
                except Exception as e:
                    print(f"[mic] action: {e}")
            elif not down and self._action_down[idx]:
                self._action_down[idx] = False

    def start(self):
        err = _backend_error()
        if err is not None:
            print(f"[mic] HID backend unavailable: {err}")
            return False
        if not self.binding:
            print("[mic] no button binding set")
            return False
        devs = _get_devices(self.vid, self.pid)
        if not devs:
            print(f"[mic] device 0x{self.vid:04x}/0x{self.pid:04x} not found")
            return False
        # macOS: pick the interface the button was learned on, if recorded.
        want = self.binding.get("iface")
        if want:
            devs = [d for d in devs if _iface_key(d) == want] or devs
        self._dev = devs[0]
        try:
            self._dev.open()
            self._dev.set_raw_data_handler(self._on_report)
            self._ok = True
            print(f"[mic] armed: {self._dev.product_name} ({describe(self.binding)})")
            return True
        except Exception as e:
            print(f"[mic] open failed (is Dragon holding it?): {e}")
            self._dev = None
            return False

    def stop(self):
        if self._dev is not None:
            try:
                self._dev.close()
            except Exception:
                pass
            self._dev = None
        self._ok = False
