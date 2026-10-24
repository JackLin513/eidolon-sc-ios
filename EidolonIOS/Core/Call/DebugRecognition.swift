#if DEBUG
import EidolonCore
import Foundation

/// Development aid: says one line as if the microphone had heard it, then stays open like
/// a live recognizer, so the call screen can be seen and driven without a voice.
struct DebugRecognition: SpeechRecognition {
    let said: String

    func listen(_ audio: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
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
}

/// Development aid: a microphone that is always open and always silent, so the simulated
/// call needs no microphone permission.
final class SilentCapture: AudioCapture, @unchecked Sendable {
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Data.self)
    }

    func start() async throws {}

    func stop() async {
        continuation.finish()
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
