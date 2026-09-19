// @acid: WHISPER-1, WHISPER-2, WHISPER-3, WHISPER-4
import Foundation

public final class WhisperClient {
    public let endpoint: URL

    private static let whisperExecutables = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli"
    ]

    private static let modelPaths = [
        "\(NSHomeDirectory())/Library/Application Support/openscreen/stt-models/whisper-ggml/ggml-small-q8_0.bin",
        "\(NSHomeDirectory())/.hermes/models/whisper/ggml-small.en.bin",
        "\(NSHomeDirectory())/.pi/voice/ggml-small.en.bin"
    ]

    public init(endpoint: URL = URL(string: "http://127.0.0.1:49868/inference")!) {
        self.endpoint = endpoint
    }

    public func transcribe(wavData: Data) async throws -> String {
        do {
            return try await transcribeUsingServer(wavData: wavData)
        } catch let error as URLError {
            guard [.cannotConnectToHost, .networkConnectionLost, .timedOut, .notConnectedToInternet].contains(error.code) else {
                throw error
            }
            return try await transcribeUsingLocalCLI(wavData: wavData)
        }
    }

    private func transcribeUsingServer(wavData: Data) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n".utf8))
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".utf8))
        body.append(Data("json\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errText = String(data: data, encoding: .utf8) ?? "Unknown"
            throw NSError(domain: "WhisperClient", code: status, userInfo: [NSLocalizedDescriptionKey: "Server error \(status): \(errText)"])
        }
        return try Self.decodeTranscription(data)
    }

    private func transcribeUsingLocalCLI(wavData: Data) async throws -> String {
        let executable = Self.whisperExecutables.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        let model = Self.modelPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
        guard let executable, let model else {
            throw NSError(
                domain: "WhisperClient",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "Whisper server is unavailable and no local whisper-cli model was found."]
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let id = UUID().uuidString
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jev-whisper-\(id)", isDirectory: true)
                let input = directory.appendingPathComponent("audio.wav")
                let output = directory.appendingPathComponent("transcript")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try wavData.write(to: input, options: .atomic)

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = [
                        "-m", model,
                        "-f", input.path,
                        "-l", "en",
                        "-otxt",
                        "-of", output.path,
                        "-np",
                        "-nt"
                    ]
                    let stderr = Pipe()
                    process.standardError = stderr
                    try process.run()
                    process.waitUntilExit()

                    let transcriptURL = URL(fileURLWithPath: "\(output.path).txt")
                    let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard process.terminationStatus == 0 else {
                        let diagnostics = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "whisper-cli failed"
                        throw NSError(domain: "WhisperClient", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: diagnostics])
                    }
                    continuation.resume(returning: transcript)
                } catch {
                    continuation.resume(throwing: error)
                }
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private static func decodeTranscription(_ data: Data) throws -> String {
        struct WhisperSegment: Decodable {
            let text: String?
        }
        struct WhisperResponse: Decodable {
            let text: String?
            let segments: [WhisperSegment]?
        }

        let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
        if let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return decoded.segments?.compactMap(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
