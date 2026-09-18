# @acid: DISPATCH-2, DISPATCH-3, DISPATCH-4
"""Pure Quartz WindowServer event synthesizer for hardware-accurate screen interaction."""

import time
import Quartz.CoreGraphics as CG

def click_at(x: int, y: int):
    """Synthesize a hardware left mouse click at logical screen coordinates (x, y)."""
    point = CG.CGPoint(x=x, y=y)
    
    move = CG.CGEventCreateMouseEvent(None, CG.kCGEventMouseMoved, point, CG.kCGMouseButtonLeft)
    CG.CGEventPost(CG.kCGHIDEventTap, move)
    time.sleep(0.04)

    down = CG.CGEventCreateMouseEvent(None, CG.kCGEventLeftMouseDown, point, CG.kCGMouseButtonLeft)
    CG.CGEventPost(CG.kCGHIDEventTap, down)
    time.sleep(0.05)

    up = CG.CGEventCreateMouseEvent(None, CG.kCGEventLeftMouseUp, point, CG.kCGMouseButtonLeft)
    CG.CGEventPost(CG.kCGHIDEventTap, up)
    time.sleep(0.04)

def type_text(text: str):
    """Synthesize keyboard typing into the currently focused control."""
    for char in text:
        down = CG.CGEventCreateKeyboardEvent(None, 0, True)
        up = CG.CGEventCreateKeyboardEvent(None, 0, False)
        CG.CGEventKeyboardSetUnicodeString(down, len(char), char)
        CG.CGEventKeyboardSetUnicodeString(up, len(char), char)
        CG.CGEventPost(CG.kCGHIDEventTap, down)
        time.sleep(0.012)
        CG.CGEventPost(CG.kCGHIDEventTap, up)
        time.sleep(0.012)

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

def replace_text_at(x: int, y: int, new_text: str):
    """Clicks an element, selects all existing text via Cmd+A, types new text, and submits with Return."""
    click_at(x, y)
    time.sleep(0.08)

    # Cmd + A (Select All)
    down = CG.CGEventCreateKeyboardEvent(None, 0, True)
    up = CG.CGEventCreateKeyboardEvent(None, 0, False)
    CG.CGEventSetFlags(down, CG.kCGEventFlagMaskCommand)
    CG.CGEventSetFlags(up, CG.kCGEventFlagMaskCommand)
    CG.CGEventPost(CG.kCGHIDEventTap, down)
    time.sleep(0.04)
    CG.CGEventPost(CG.kCGHIDEventTap, up)
    time.sleep(0.05)

    type_text(new_text)
    time.sleep(0.05)
    press_key("return")
