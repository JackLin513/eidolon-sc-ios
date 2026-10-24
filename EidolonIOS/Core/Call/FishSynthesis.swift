import EidolonCore
import Foundation
import OSLog

/// Her voice, made by Fish Audio over HTTP: one request per segment, MP3 back. The voice
/// is the character's `voice_id` from the content bundle; the model is the one chosen in
/// settings (`drama-3` is the only one that reads delivery cues).
struct FishSynthesis: SpeechSynthesis {
    var apiKey: String
    var endpoint = URL(string: "https://api.fish.audio/v1/tts")!

    func synthesize(_ text: String, voice: CallVoice) async throws -> Data {
        guard !apiKey.isEmpty else { throw FishSynthesisError.missingKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(voice.model, forHTTPHeaderField: "model")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "reference_id": voice.id,
            "format": "mp3",
            "normalize": true,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FishSynthesisError.noResponse
        }
        guard http.statusCode == 200 else {
            throw FishSynthesisError.status(
                http.statusCode,
                String(decoding: data.prefix(200), as: UTF8.self)
            )
        }
        guard !data.isEmpty else { throw FishSynthesisError.empty }
        Logger(subsystem: "com.jacklin.eidolon", category: "call")
            .notice("synthesized \(text.count) chars -> \(data.count) bytes on \(voice.model)")
        return data
    }
}

enum FishSynthesisError: LocalizedError {
    case missingKey
    case noResponse
    case empty
    case status(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "还没有填 Fish Audio 的密钥"
        case .noResponse:
            "Fish Audio 没有回应"
        case .empty:
            "Fish Audio 没有说话"
        case let .status(code, detail):
            "Fish Audio 出错（\(code)）：\(detail)"
        }
    }
}
