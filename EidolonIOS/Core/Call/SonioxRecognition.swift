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

    /// Soniox reporting an error of its own — a missing or refused key, a rejected
    /// configuration — is the service failing, and ends the call; a dropped connection is
    /// reconnected (upstream `service_failed`).
    func failure(_ error: any Error) -> VoiceServiceFailure? {
        guard case let SonioxError.service(code, message) = error else { return nil }
        let detail = [code, message].filter { !$0.isEmpty }.joined(separator: " ")
        return VoiceServiceFailure(service: "Soniox", detail: detail)
    }

    private func run(
        audio: AsyncThrowingStream<Data, Error>,
        emit: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    ) async {
        guard !apiKey.isEmpty else {
            emit.finish(throwing: SonioxError.service("", "还没有填 Soniox 的密钥"))
            return
        }
        let configuration = URLSessionConfiguration.default
        // A connection that never opens must not sit in `send` forever: the call's own
        // connect timeout ends it, but this lets the attempt fail cleanly sooner.
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
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
        // The configuration is accepted: the recognizer can hear from here on, and the call
        // is connected (spec「接通」).
        emit.yield(.connected)

        let writer = SocketWriter(socket)
        let lastAudio = LastAudio()
        let pump = Task {
            do {
                for try await chunk in audio {
                    if Task.isCancelled { break }
                    try await writer.sendData(chunk)
                    lastAudio.mark()
                }
            } catch {
                // The microphone ended or failed; the receive loop ends too.
            }
            socket.cancel(with: .normalClosure, reason: nil)
        }
        // Her voice closes the microphone for as long as a segment plays; without this the
        // connection would see no traffic and Soniox would close it (pipecat's keepalive).
        let keepalive = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: SonioxKeepalive.interval)
                } catch {
                    break
                }
                guard SonioxKeepalive.isDue(now: Date(), lastAudio: lastAudio.value) else {
                    continue
                }
                do {
                    try await writer.sendText(SonioxKeepalive.message)
                    lastAudio.mark()
                } catch {
                    break
                }
            }
        }
        defer {
            pump.cancel()
            keepalive.cancel()
        }

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

/// Sends over one websocket one message at a time: the audio pump and the keepalive would
/// otherwise interleave sends on the same connection.
private actor SocketWriter {
    private let socket: URLSessionWebSocketTask

    init(_ socket: URLSessionWebSocketTask) {
        self.socket = socket
    }

    func sendData(_ data: Data) async throws {
        try await socket.send(.data(data))
    }

    func sendText(_ text: String) async throws {
        try await socket.send(.string(text))
    }
}

/// When audio last went up, shared by the pump that sends it and the keepalive that asks.
private final class LastAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var at = Date()

    func mark() {
        lock.lock()
        at = Date()
        lock.unlock()
    }

    var value: Date {
        lock.lock()
        defer { lock.unlock() }
        return at
    }
}

/// Without a Fish Audio key her words are subtitles only (ADR-0011): each segment cannot be
/// voiced, and the call shows every caption as it arrives.
struct UnvoicedSynthesis: SpeechSynthesis {
    /// No voice at all, so the line card follows her text rather than a voice that will
    /// never play.
    var providesVoice: Bool { false }

    func synthesize(_ text: String, voice: CallVoice) async throws -> Data {
        throw URLError(.unsupportedURL)
    }
}

/// Nothing is played yet.
struct SilentPlayback: AudioPlayback {
    func play(_ audio: Data) async throws {}
    func stop() async {}
}
