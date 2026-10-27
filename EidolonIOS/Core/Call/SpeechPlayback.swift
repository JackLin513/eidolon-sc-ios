import AVFoundation
import EidolonCore
import OSLog

/// Plays one segment's MP3 at a time on the call's audio session; `stop` ends it at once,
/// as hanging up must (ADR-0011). Completion is awaited by watching the player rather than
/// its delegate: the call voices from a background task, which has no run loop to receive
/// delegate callbacks on.
final class SpeechPlayback: AudioPlayback, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.jacklin.eidolon", category: "call")

    private let lock = NSLock()
    private var current: AVAudioPlayer?
    /// Hanging up stops the voice for the rest of the call: a segment about to start after
    /// it must not start, even if its play call was already under way.
    private var stopped = false

    func play(_ audio: Data) async throws {
        // The microphone owns the session (`.playAndRecord` + `.voiceChat`); changing it
        // here would block behind voice processing, so playback only plays.
        let player = try AVAudioPlayer(data: audio)
        player.prepareToPlay()

        lock.lock()
        guard !stopped else {
            lock.unlock()
            throw CancellationError()
        }
        current = player
        lock.unlock()
        defer { clear(player) }

        guard player.play() else { throw PlaybackError.willNotPlay }
        Self.log.notice("playing \(String(format: "%.2f", player.duration))s")
        do {
            while player.isPlaying {
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            // The call was hung up while this segment played: it stops where it is rather
            // than finishing into a call that is over.
            player.stop()
            throw error
        }
        Self.log.notice("played, isPlaying=\(player.isPlaying) currentTime=\(player.currentTime)")
    }

    func stop() async {
        lock.lock()
        stopped = true
        let playing = current
        current = nil
        lock.unlock()
        playing?.stop()
    }

    private func clear(_ player: AVAudioPlayer) {
        lock.lock()
        if current === player { current = nil }
        lock.unlock()
    }

    enum PlaybackError: LocalizedError {
        case willNotPlay

        var errorDescription: String? { "这一段放不出来" }
    }
}
