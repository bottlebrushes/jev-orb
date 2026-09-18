# @acid: DISPATCH-2, DISPATCH-3, DISPATCH-4
"""Hybrid CDP & Quartz WindowServer input synthesizer."""

import time
import urllib.request

def _is_cdp_active():
    try:
        req = urllib.request.urlopen("http://127.0.0.1:9222/json/version", timeout=0.3)
        return req.status == 200
    except Exception:
        return False

def click_at(x: int, y: int):
    """Click at screen/viewport coordinates (x, y)."""
    if _is_cdp_active():
        try:
            from browser_harness.helpers import cdp
            cdp("Input.dispatchMouseEvent", type="mouseMoved", x=x, y=y)
            time.sleep(0.02)
            cdp("Input.dispatchMouseEvent", type="mousePressed", x=x, y=y, button="left", clickCount=1)
            time.sleep(0.04)
            cdp("Input.dispatchMouseEvent", type="mouseReleased", x=x, y=y, button="left", clickCount=1)
            return
        except Exception:
            pass

    import Quartz.CoreGraphics as CG
    point = CG.CGPoint(x=x, y=y)
    down = CG.CGEventCreateMouseEvent(None, CG.kCGEventLeftMouseDown, point, CG.kCGMouseButtonLeft)
    up = CG.CGEventCreateMouseEvent(None, CG.kCGEventLeftMouseUp, point, CG.kCGMouseButtonLeft)
    CG.CGEventPost(CG.kCGHIDEventTap, down)
    time.sleep(0.04)
    CG.CGEventPost(CG.kCGHIDEventTap, up)

def type_text(text: str):
    """Type text into focused element."""
    if _is_cdp_active():
        try:
            from browser_harness.helpers import cdp
            cdp("Input.insertText", text=text)
            return
        except Exception:
            pass

    import Quartz.CoreGraphics as CG
    for char in text:
        utf16 = [ord(char)]
        down = CG.CGEventCreateKeyboardEvent(None, 0, True)
        up = CG.CGEventCreateKeyboardEvent(None, 0, False)
        CG.CGEventKeyboardSetUnicodeString(down, len(utf16), utf16)
        CG.CGEventKeyboardSetUnicodeString(up, len(utf16), utf16)
        CG.CGEventPost(CG.kCGHIDEventTap, down)
        time.sleep(0.012)
        CG.CGEventPost(CG.kCGHIDEventTap, up)
        time.sleep(0.012)

def press_key(key_name: str):
    """Press a key."""
    if _is_cdp_active():
        try:
            from browser_harness.helpers import cdp
            if key_name.lower() in {"enter", "return"}:
                cdp("Input.dispatchKeyEvent", type="keyDown", key="Enter", code="Enter", text="\r", windowsVirtualKeyCode=13)
                time.sleep(0.03)
                cdp("Input.dispatchKeyEvent", type="keyUp", key="Enter", code="Enter", windowsVirtualKeyCode=13)
                return
        except Exception:
            pass

    import Quartz.CoreGraphics as CG
    key_codes = {"return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53}
    code = key_codes.get(key_name.lower(), 36)
    down = CG.CGEventCreateKeyboardEvent(None, code, True)
    up = CG.CGEventCreateKeyboardEvent(None, code, False)
    CG.CGEventPost(CG.kCGHIDEventTap, down)
    time.sleep(0.03)
    CG.CGEventPost(CG.kCGHIDEventTap, up)
