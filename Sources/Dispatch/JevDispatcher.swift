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

                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = outPipe

                let logPath = "/tmp/jevorb.log"
                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil)
                }

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }

                    // Log to /tmp/jevorb.log
                    if let logHandle = FileHandle(forWritingAtPath: logPath) {
                        logHandle.seekToEndOfFile()
                        logHandle.write(data)
                    }

                    // Parse dispatch commands in real time
                    if let str = String(data: data, encoding: .utf8) {
                        for line in str.split(separator: "\n") {
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            if trimmed.contains("DISPATCH: ") {
                                let jsonStr = trimmed.components(separatedBy: "DISPATCH: ").last ?? ""
                                if let jData = jsonStr.data(using: .utf8),
                                   let obj = try? JSONSerialization.jsonObject(with: jData) as? [String: Any] {
                                    self.executeNativeAction(obj)
                                }
                            }
                        }
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()

                    outPipe.fileHandleForReading.readabilityHandler = nil
                    let success = process.terminationStatus == 0
                    continuation.resume(returning: success)
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func executeNativeAction(_ obj: [String: Any]) {
        let type = obj["type"] as? String ?? ""
        let x = obj["x"] as? Int ?? 0
        let y = obj["y"] as? Int ?? 0
        let text = obj["text"] as? String ?? ""

        NSLog("[JevDispatcher Native Execution] Executing action: %@ at (%d, %d)", type, x, y)

        if type == "replace_text" || type == "type_text" {
            InputDriver.shared.replaceTextAt(x: x, y: y, text: text)
        } else if type == "click" {
            InputDriver.shared.clickAt(x: x, y: y)
        }
    }
}
