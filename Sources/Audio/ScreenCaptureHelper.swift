// @acid: VISION-1
import Foundation

public final class ScreenCaptureHelper {
    public static let shared = ScreenCaptureHelper()

    public init() {}

    public func captureVisibleScreen(outputPath: String = "/tmp/jev_screen.png") async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", outputPath]

                do {
                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: outputPath)
                    } else {
                        continuation.resume(throwing: NSError(domain: "ScreenCaptureHelper", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "screencapture exited with code \(process.terminationStatus)"]))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
