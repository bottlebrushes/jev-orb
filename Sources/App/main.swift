// @acid: OVERLAY-1, OVERLAY-2, OVERLAY-3, OVERLAY-4, HOTKEY-1
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Prompt for Accessibility permission if not yet trusted
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        NSLog("[JevOrb] Accessibility isTrusted: %@", isTrusted ? "YES" : "NO")

        let contentView = ContentView()
        let hostingView = NSHostingView(rootView: contentView)

        let panelRect = NSRect(x: 0, y: 0, width: 250, height: 250)
        let floatingPanel = FloatingPanel(contentRect: panelRect)
        floatingPanel.contentView = hostingView
        floatingPanel.orderFrontRegardless()

        self.panel = floatingPanel

        // Verify screen capture immediately on launch
        Task {
            do {
                let path = try await ScreenCaptureHelper.shared.captureVisibleScreen(outputPath: "/tmp/jev_screen.png")
                NSLog("[JevOrb Startup Capture] SUCCESS! Wrote to %@", path)
            } catch {
                NSLog("[JevOrb Startup Capture] ERROR: %@", error.localizedDescription)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel?.close()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
