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

    public func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        usleep(30000)
        // Cmd + V (virtualKey 9 is kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(40000)
        up?.post(tap: .cghidEventTap)
        usleep(40000)
    }

    public func typeText(_ text: String) {
        // Paste atomically to prevent browser autocomplete racing
        pasteText(text)
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

        // Cmd + A (Select All, virtualKey 0 is kVK_ANSI_A)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(40000)
        up?.post(tap: .cghidEventTap)
        usleep(50000)

        pasteText(text)
        usleep(60000)
        pressKey(keyCode: 36) // Return / Enter key
    }
}
