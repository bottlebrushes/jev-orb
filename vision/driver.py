# @acid: DISPATCH-2, DISPATCH-3, DISPATCH-4
"""Pure Quartz WindowServer event synthesizer for hardware-accurate screen interaction."""

import time
import Quartz.CoreGraphics as CG

def click_at(x: int, y: int):
    """Synthesize a hardware left mouse click at logical screen coordinates (x, y)."""
    point = CG.CGPoint(x=x, y=y)
    
    # Move mouse
    move = CG.CGEventCreateMouseEvent(None, CG.kCGEventMouseMoved, point, CG.kCGMouseButtonLeft)
    CG.CGEventPost(CG.kCGHIDEventTap, move)
    time.sleep(0.04)

    # Mouse Down
    down = CG.CGEventCreateMouseEvent(None, CG.kCGEventLeftMouseDown, point, CG.kCGMouseButtonLeft)
    CG.CGEventPost(CG.kCGHIDEventTap, down)
    time.sleep(0.05)

    # Mouse Up
    up = CG.CGEventCreateMouseEvent(None, CG.kCGEventLeftMouseUp, point, CG.kCGMouseButtonLeft)
    CG.CGEventPost(CG.kCGHIDEventTap, up)
    time.sleep(0.04)

def type_text(text: str):
    """Synthesize keyboard typing into the currently focused control."""
    for char in text:
        utf16 = [ord(char)]
        down = CG.CGEventCreateKeyboardEvent(None, 0, True)
        up = CG.CGEventCreateKeyboardEvent(None, 0, False)
        CG.CGEventKeyboardSetUnicodeString(down, len(utf16), utf16)
        CG.CGEventKeyboardSetUnicodeString(up, len(utf16), utf16)
        CG.CGEventPost(CG.kCGHIDEventTap, down)
        time.sleep(0.015)
        CG.CGEventPost(CG.kCGHIDEventTap, up)
        time.sleep(0.015)

def press_key(key_name: str):
    """Synthesize specific hardware keys (return, tab, space, escape, backspace)."""
    key_codes = {
        "return": 36,
        "enter": 36,
        "tab": 48,
        "space": 49,
        "backspace": 51,
        "escape": 53
    }
    code = key_codes.get(key_name.lower(), 36)
    down = CG.CGEventCreateKeyboardEvent(None, code, True)
    up = CG.CGEventCreateKeyboardEvent(None, code, False)
    CG.CGEventPost(CG.kCGHIDEventTap, down)
    time.sleep(0.03)
    CG.CGEventPost(CG.kCGHIDEventTap, up)
    time.sleep(0.02)
