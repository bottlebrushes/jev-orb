// @acid: VISION-1
import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

public final class ScreenCaptureHelper {
    public static let shared = ScreenCaptureHelper()

    public init() {}

    public func captureVisibleScreen(outputPath: String = "/tmp/jev_screen.png") async throws -> String {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "ScreenCaptureHelper", code: 404, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let bitmapRep = NSBitmapImageRep(cgImage: image)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ScreenCaptureHelper", code: 500, userInfo: [NSLocalizedDescriptionKey: "PNG compression failed"])
        }

        try pngData.write(to: URL(fileURLWithPath: outputPath))
        return outputPath
    }
}
