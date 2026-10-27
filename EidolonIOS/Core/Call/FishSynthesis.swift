import EidolonCore
import Foundation
import OSLog

/// Her voice, made by Fish Audio over HTTP: one request per segment, MP3 back. The voice
/// is the character's `voice_id` from the content bundle; the model is the one chosen in
/// settings (`drama-3` is the only one that reads delivery cues). Every request carries the
/// bundle's readings as its pronunciation dictionary, so names are said as written
/// (upstream `call.FishTTS`).
struct FishSynthesis: SpeechSynthesis {
    var apiKey: String
    var readings: Readings = Readings()
    var endpoint = URL(string: "https://api.fish.audio/v1/tts")!

    func synthesize(_ text: String, voice: CallVoice) async throws -> Data {
        guard !apiKey.isEmpty else { throw FishSynthesisError.missingKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(voice.model, forHTTPHeaderField: "model")
        request.httpBody = try JSONEncoder().encode(
            FishSpeechRequest(text: text, referenceID: voice.id, readings: readings)
        )
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

    /// Whether Fish Audio itself cannot speak for this call: a key missing or refused, an
    /// account out of credit, a voice or model it does not serve, or audio it did not make.
    /// Retrying another segment will not help, so the call ends as upstream's does when its
    /// voice service is unusable. A timeout, a dropped connection or a 5xx is only this
    /// segment lost; the reply goes on (ADR-0011).
    func failure(_ error: any Error) -> VoiceServiceFailure? {
        switch error {
        case FishSynthesisError.missingKey:
            return VoiceServiceFailure(service: "Fish Audio", detail: "还没有填密钥")
        case FishSynthesisError.empty:
            return VoiceServiceFailure(service: "Fish Audio", detail: "返回的音频是空的")
        case let FishSynthesisError.status(code, detail):
            guard Self.refused.contains(code) else { return nil }
            return VoiceServiceFailure(service: "Fish Audio", detail: "\(code) \(detail)")
        default:
            return nil
        }
    }

    /// The statuses meaning the service will not work for this call at all: no key or a
    /// refused one, no credit, a voice or model it does not serve, a request it refuses.
    /// 408, 429 and 5xx are left for the next segment to try again.
    private static let refused: Set<Int> = [400, 401, 402, 403, 404, 422]
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
