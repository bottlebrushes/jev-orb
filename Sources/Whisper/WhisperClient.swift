// @acid: WHISPER-1, WHISPER-2, WHISPER-3, WHISPER-4
import Foundation

public final class WhisperClient {
    public let endpoint: URL

    public init(endpoint: URL = URL(string: "http://127.0.0.1:49868/inference")!) {
        self.endpoint = endpoint
    }

    public func transcribe(wavData: Data) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0

        var body = Data()

        // file field
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n".utf8))

        // response_format field
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

        struct WhisperSegment: Decodable {
            let text: String?
        }

        struct WhisperResponse: Decodable {
            let text: String?
            let segments: [WhisperSegment]?
        }

        let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
        if let text = decoded.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let segments = decoded.segments {
            let combined = segments.compactMap { $0.text }.joined(separator: " ")
            return combined.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}
