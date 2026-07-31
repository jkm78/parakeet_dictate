"""
Small Windows theming helpers for a standard (decorated) Tk window:
detect the Windows light/dark app theme and paint the native title bar to match.

Everything is best-effort and Windows-only: each function is a no-op (returning
False) elsewhere or if a Win32 call fails.
"""

import sys

try:
    import ctypes
    _user32 = ctypes.windll.user32
    _dwmapi = ctypes.windll.dwmapi
except Exception:
    _user32 = _dwmapi = None

# DWMWA_USE_IMMERSIVE_DARK_MODE: 20 on Windows 10 20H1+ / Windows 11, 19 before.
_DWMWA_DARK = (20, 19)


def available():
    return sys.platform.startswith("win") and _user32 is not None


GA_ROOT = 2


def top_hwnd(root):
    """The decorated top-level window handle for a Tk window.

    Uses GetAncestor(GA_ROOT), which walks *parent* links only. GetParent would
    return the OWNER for an owned/transient window (e.g. the Settings dialog),
    which would point DWM at the wrong window."""
    wid = root.winfo_id()
    try:
        h = _user32.GetAncestor(wid, GA_ROOT)
        if h:
            return h
    except Exception:
        pass
    h = _user32.GetParent(wid)
    return h or wid


def set_titlebar_theme(root, dark):
    """Paint the native title bar dark (or light) to match the app theme. Best
    applied before the window is first shown so it paints correctly the first
    time. Returns True if DWM accepted the immersive-dark attribute."""
    if not available():
        return False
    try:
        hwnd = top_hwnd(root)
        val = ctypes.c_int(1 if dark else 0)
        applied = False
        for attr in _DWMWA_DARK:
            if _dwmapi.DwmSetWindowAttribute(
                    hwnd, attr, ctypes.byref(val), ctypes.sizeof(val)) == 0:
                applied = True
                break
        # Best-effort caption + border colors so the title bar AND the thin
        # window border are dark. Supported on Windows 11 (DWMWA_CAPTION_COLOR=35,
        # DWMWA_BORDER_COLOR=34); silently ignored on Windows 10.
        if dark:
            cref = ctypes.c_uint(0x001E1F1F)   # COLORREF ~ #1f1f1e
            for attr in (35, 34):
                try:
                    _dwmapi.DwmSetWindowAttribute(
                        hwnd, attr, ctypes.byref(cref), ctypes.sizeof(cref))
                except Exception:
                    pass
        # Force the non-client area (title bar) to repaint so the new attribute
        # takes effect even if the window was already shown.
        try:
            SWP = 0x0002 | 0x0001 | 0x0004 | 0x0020  # NOMOVE|NOSIZE|NOZORDER|FRAMECHANGED
            _user32.SetWindowPos(hwnd, 0, 0, 0, 0, 0, SWP)
        except Exception:
            pass
        return applied
    except Exception:
        return False


def is_dark_mode():
    """True if Windows apps are set to the dark theme (registry-based)."""
    try:
        import winreg
        k = winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")
        val, _ = winreg.QueryValueEx(k, "AppsUseLightTheme")
        winreg.CloseKey(k)
        return val == 0
    except Exception:
        return False
