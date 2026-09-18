// @acid: VISION-1
import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

public final class ScreenCaptureHelper {
    public static let shared = ScreenCaptureHelper()

    public init() {}

    private func logToFile(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        let logPath = "/tmp/jevorb.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        }
    }

    public func captureVisibleScreen(outputPath: String = "/tmp/jev_screen.png") async throws -> String {
        do {
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
            logToFile("[SCREEN CAPTURE SUCCESS] Captured display (\(display.width)x\(display.height)) to \(outputPath)")
            return outputPath
        } catch {
            logToFile("[SCREEN RECORDING ALERT / POPUP ACTIVE] ScreenCaptureKit failed: \(error.localizedDescription). The macOS permission modal is currently open on screen.")
            throw error
        }
    }
}
