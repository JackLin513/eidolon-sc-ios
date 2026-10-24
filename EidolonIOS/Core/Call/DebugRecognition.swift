#if DEBUG
import AVFoundation
import EidolonCore
import Foundation

/// Development aid: says one line as if the microphone had heard it, then stays open like
/// a live recognizer, so the call screen can be seen and driven without a voice.
/// `EIDOLON_CALL_DROP_ONCE=1` drops the first listening connection, to see a reconnect.
final class DebugRecognition: SpeechRecognition, @unchecked Sendable {
    let said: String
    let dropFirst: Bool

    private let lock = NSLock()
    private var calls = 0

    init(said: String, dropFirst: Bool = false) {
        self.said = said
        self.dropFirst = dropFirst
    }

    func listen(_ audio: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<SpeechEvent, Error> {
        let shouldDrop = markCall()
        return AsyncThrowingStream { continuation in
            let task = Task {
                if shouldDrop {
                    continuation.yield(.partial(said))
                    try? await Task.sleep(for: .milliseconds(500))
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                    return
                }
                try? await Task.sleep(for: .milliseconds(1500))
                continuation.yield(.partial(said))
                continuation.yield(.final(said))
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func markCall() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return dropFirst && calls == 1
    }
}

/// Development aid: a microphone that is always open and always silent, so the simulated
/// call needs no microphone permission.
final class SilentCapture: AudioCapture, @unchecked Sendable {
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Data.self)
    }

    func start() async throws {
        // No microphone is opened, so the session is a plain playback one.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        if #available(iOS 27.0, *) {
            try? await session.activate(options: [])
        } else {
            try? session.setActive(true)
        }
    }

    func stop() async {
        continuation.finish()
        if #available(iOS 27.0, *) {
            try? await AVAudioSession.sharedInstance()
                .deactivate(options: .notifyOthersOnDeactivation)
        } else {
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func chunks() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for await _ in stream { continuation.yield(Data(repeating: 0, count: 640)) }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
#endif
