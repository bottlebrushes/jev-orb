// @acid: OVERLAY-1, OVERLAY-2, OVERLAY-3, PERMISSIONS-1, PERMISSIONS-2, PERMISSIONS-4
import AppKit
import ApplicationServices
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Remain outside the regular-app AX catalog and preserve the user's target.
        NSApp.setActivationPolicy(.accessory)

        // AX navigation is owned by this process; request Accessibility trust only.
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel?.close()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
