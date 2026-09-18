// @acid: DISPATCH-1, DISPATCH-2, DISPATCH-3, DISPATCH-4
import Foundation

public final class JevDispatcher: @unchecked Sendable {
    public static let shared = JevDispatcher()

    private let jevExecutable: String

    public init(jevExecutable: String = "\(NSHomeDirectory())/Developer/jev-orb/vision/run_vision.sh") {
        self.jevExecutable = jevExecutable
    }

    public func dispatch(goal: String) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            let execPath = self.jevExecutable
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: execPath)
                process.arguments = [goal]
                var env = ProcessInfo.processInfo.environment
                let home = NSHomeDirectory()
                env["HOME"] = home
                env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                process.environment = env

                let logPath = "/tmp/jevorb.log"
                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil)
                }
                if let logHandle = FileHandle(forWritingAtPath: logPath) {
                    logHandle.seekToEndOfFile()
                    process.standardOutput = logHandle
                    process.standardError = logHandle
                }

                do {
                    try process.run()
                    process.waitUntilExit()

                    let success = process.terminationStatus == 0
                    continuation.resume(returning: success)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
