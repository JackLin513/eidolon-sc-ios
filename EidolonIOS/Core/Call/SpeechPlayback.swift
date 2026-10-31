import AVFoundation
import EidolonCore
import OSLog

/// Plays one segment's MP3 at a time on the call's audio session; `stop` ends it at once,
/// as hanging up must (ADR-0011). Completion is awaited by watching the player rather than
/// its delegate: the call voices from a background task, which has no run loop to receive
/// delegate callbacks on.
final class SpeechPlayback: AudioPlayback, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.jacklin.eidolon", category: "call")

    /// Whether each segment is put through 电话质感 before it is played. Read at dial and
    /// fixed for the call (spec #36).
    private let phoneTexture: Bool

    private let lock = NSLock()
    private var current: AVAudioPlayer?

    init(phoneTexture: Bool) {
        self.phoneTexture = phoneTexture
    }

    /// Hanging up stops the voice for the rest of the call: a segment about to start after
    /// it must not start, even if its play call was already under way.
    private var stopped = false
    /// 只看文字 cuts the segment being heard. A segment still being prepared for the line
    /// sees the count move and never starts.
    private var silenceGeneration = 0

    func play(_ audio: Data) async throws {
        // The microphone owns the session (`.playAndRecord` + `.voiceChat`); changing it
        // here would block behind voice processing, so playback only plays.
        lock.lock()
        let generation = silenceGeneration
        lock.unlock()
        let original = audio
        let played = phoneTexture ? (TexturedAudio.wav(fromMP3: original) ?? original) : original
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: played)
        } catch {
            // The line is a decoration: a segment that will not play through it is played
            // as it came (spec #36).
            guard phoneTexture else { throw error }
            Self.log.error("phone texture would not play: \(error.localizedDescription)")
            player = try AVAudioPlayer(data: original)
        }
        player.prepareToPlay()

        lock.lock()
        guard !stopped else {
            lock.unlock()
            throw CancellationError()
        }
        guard generation == silenceGeneration else {
            lock.unlock()
            return
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

    /// Cuts the segment playing now without ending the call: 只看文字 takes her voice away
    /// mid-answer, and the next answer may be voiced again.
    func silence() async {
        lock.lock()
        silenceGeneration += 1
        let playing = current
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
