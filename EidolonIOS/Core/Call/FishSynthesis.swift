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
    /// Whether this call's Fish Audio has made any segment yet: a 400/404/422 is the
    /// service refusing the call only while it has not (ADR-0011, #35 no. 37).
    private let made = MadeSegment()

    init(
        apiKey: String,
        readings: Readings = Readings(),
        endpoint: URL = URL(string: "https://api.fish.audio/v1/tts")!
    ) {
        self.apiKey = apiKey
        self.readings = readings
        self.endpoint = endpoint
    }

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
        do {
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
            made.mark()
            Logger(subsystem: "com.jacklin.eidolon", category: "call")
                .notice("synthesized \(text.count) chars -> \(data.count) bytes on \(voice.model)")
            return data
        } catch {
            // A TLS failure, a timeout, a refused key: the call's line card falls back to her
            // words after a while (CallSession, upstream `linePacing.ts`), and this is what a
            // report needs to tell those reasons apart.
            Logger(subsystem: "com.jacklin.eidolon", category: "call").error(
                "Fish Audio could not voice \(text.count) chars on \(voice.model): \(error.localizedDescription)"
            )
            throw error
        }
    }

    /// Whether Fish Audio itself cannot speak for this call: a key missing or refused, an
    /// account out of credit, an empty answer, or — while this call has not voiced
    /// anything yet — a voice, model or request it does not serve. Retrying another
    /// segment will not help then, so the call ends as upstream's does when its voice
    /// service is unusable. A timeout, a dropped connection or a 5xx is only this segment
    /// lost, and so is a refused request after one segment has been made; the reply goes
    /// on (ADR-0011).
    func failure(_ error: any Error) -> VoiceServiceFailure? {
        guard let error = error as? FishSynthesisError else { return nil }
        return error.serviceFailure(hasSynthesized: made.any)
    }
}

/// What one call's synthesizer has made, shared by the copies of the `FishSynthesis` value
/// and the prefetch that runs beside the drain.
private final class MadeSegment: @unchecked Sendable {
    private let lock = NSLock()
    private var made = false

    func mark() {
        lock.lock()
        made = true
        lock.unlock()
    }

    var any: Bool {
        lock.lock()
        defer { lock.unlock() }
        return made
    }
}
