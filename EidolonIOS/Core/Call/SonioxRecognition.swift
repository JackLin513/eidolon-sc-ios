import EidolonCore
import Foundation

/// Real-time recognition over Soniox's websocket API (ADR-0007): the call's audio goes up
/// as 16 kHz PCM16, and the end of what was said comes from Soniox's own endpoint, not a
/// local voice detector.
final class SonioxRecognition: SpeechRecognition, @unchecked Sendable {
    private let apiKey: String
    private let model: String
    /// The names said in a call that the recognizer should write as the story does.
    private let terms: [String]
    private let url = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!

    init(apiKey: String, model: String, terms: [String] = []) {
        self.apiKey = apiKey
        self.model = model
        self.terms = terms
    }

    func listen(_ audio: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(audio: audio, emit: continuation) }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func run(
        audio: AsyncThrowingStream<Data, Error>,
        emit: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    ) async {
        guard !apiKey.isEmpty else {
            emit.finish(throwing: SonioxError.service("", "还没有填 Soniox 的密钥"))
            return
        }
        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        do {
            let configuration = SonioxConfiguration(
                apiKey: apiKey,
                model: model,
                terms: terms
            )
            try await socket.send(.string(try configuration.message()))
        } catch {
            emit.finish(throwing: error)
            return
        }

        let pump = Task {
            do {
                for try await chunk in audio {
                    if Task.isCancelled { break }
                    try await socket.send(.data(chunk))
                }
            } catch {
                // The microphone ended or failed; the receive loop ends too.
            }
            socket.cancel(with: .normalClosure, reason: nil)
        }
        defer { pump.cancel() }

        var transcript = SonioxTranscript()
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data?
                switch message {
                case let .data(bytes): data = bytes
                case let .string(text): data = Data(text.utf8)
                @unknown default: data = nil
                }
                guard let data else { continue }
                for update in try transcript.feed(data) {
                    switch update {
                    case let .partial(text):
                        emit.yield(.partial(text))
                    case let .final(text):
                        emit.yield(.final(text))
                    case .ended:
                        emit.finish()
                        return
                    }
                }
            }
            emit.finish()
        } catch is CancellationError {
            emit.finish()
        } catch {
            emit.finish(throwing: error)
        }
    }
}

/// Until #16 wires Fish Audio (ADR-0007), her words are subtitles only: each segment
/// cannot be voiced, and the call shows it and goes on.
struct UnvoicedSynthesis: SpeechSynthesis {
    func synthesize(_ text: String, voice: CallVoice) async throws -> Data {
        throw URLError(.unsupportedURL)
    }
}

/// Nothing is played yet.
struct SilentPlayback: AudioPlayback {
    func play(_ audio: Data) async throws {}
    func stop() async {}
}
