// @acid: DISPATCH-2, DISPATCH-3, DISPATCH-4
import Foundation
import CoreGraphics
import AppKit

public final class InputDriver: @unchecked Sendable {
    public static let shared = InputDriver()

    public init() {}

    public func clickAt(x: Int, y: Int) {
        let pt = CGPoint(x: x, y: y)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(40000)
        up?.post(tap: .cghidEventTap)
    }

    public func typeText(_ text: String) {
        for char in text {
            let utf16 = Array(String(char).utf16)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down?.post(tap: .cghidEventTap)
            usleep(12000)
            up?.post(tap: .cghidEventTap)
            usleep(12000)
        }
    }

    public func pressKey(keyCode: CGKeyCode) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        down?.post(tap: .cghidEventTap)
        usleep(30000)
        up?.post(tap: .cghidEventTap)
    }

    public func replaceTextAt(x: Int, y: Int, text: String) {
        clickAt(x: x, y: y)
        usleep(80000)

        // Cmd + A (Select All)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(40000)
        up?.post(tap: .cghidEventTap)
        usleep(50000)

        typeText(text)
        usleep(50000)
        pressKey(keyCode: 36) // Return / Enter key
    }
}
