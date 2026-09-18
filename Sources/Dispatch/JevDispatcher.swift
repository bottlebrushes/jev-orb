// @acid: DISPATCH-1, DISPATCH-2, DISPATCH-3, DISPATCH-4
import Foundation

public final class JevDispatcher: @unchecked Sendable {
    public static let shared = JevDispatcher()

    private let jevExecutable: String

    public init(jevExecutable: String = "\(NSHomeDirectory())/.local/bin/jev") {
        self.jevExecutable = jevExecutable
    }

    public func dispatch(goal: String) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            let execPath = self.jevExecutable
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: execPath)
                process.arguments = [goal]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

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
