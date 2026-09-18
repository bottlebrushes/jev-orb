// @acid: OVERLAY-1, OVERLAY-2, OVERLAY-3, OVERLAY-4, OVERLAY-5
import AppKit
import SwiftUI

public final class FloatingPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.isMovableByWindowBackground = true

        // Center on the main display
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let x = screenRect.midX - contentRect.width / 2
            let y = screenRect.midY - contentRect.height / 2
            self.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    public override var canBecomeKey: Bool {
        return false
    }

    public override var canBecomeMain: Bool {
        return false
    }
}
