import AVFoundation
import EidolonCore
import Observation

/// 朗读 (spec #32, upstream `read_aloud.py`): her line of the conversation, voiced on demand
/// — the whole line in one request at Fish Audio's best quality, played as soon as it
/// arrives, kept in memory for this run only. A call voices her as she writes; this asks
/// after the fact, so it touches neither the turn, the affinity nor the record.
///
/// One for the whole app (`AppModel` owns it): only one line is ever read aloud, so opening
/// another conversation or a call stops the one playing here.
@MainActor
@Observable
final class ChatReadAloud {
    /// What is being read and what it is doing; the rules are `ReadAloudPlayback`'s. Its
    /// identity is the message's, not the words': she can say the same thing twice.
    private(set) var playback = ReadAloudPlayback()

    /// Lines already voiced this run, by their words: asking again is instant, and two
    /// messages that say the same thing share one recording.
    private var made: [String: Data] = [:]
    private var player: AVAudioPlayer?
    /// The message whose audio `player` is playing.
    private var playing: String?
    private var delegate: PlayerDelegate?
    private var voicing: Task<Void, Never>?
    /// The interruption observer; written once on the main actor, read once in `deinit`.
    nonisolated(unsafe) private var interrupted: NSObjectProtocol?
    /// Whether this run left the session active for reading a line. Only a session it took
    /// is given back: a call's `.playAndRecord` session is not this feature's to close.
    private var borrowedSession = false

    init() {
        // A phone call or another app taking the session pauses the player without
        // finishing it; without this the button would stay on 停止朗读 over silence.
        interrupted = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began
            else { return }
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    deinit {
        if let interrupted { NotificationCenter.default.removeObserver(interrupted) }
    }

    func phase(of line: String) -> ReadAloudPlayback.Phase? {
        playback.phase(of: line)
    }

    /// 点一下：读这条；正在读的就是这条，就停下。合成过的直接放。
    func tap(
        _ line: String,
        speech: String,
        voice: CallVoice,
        synthesize: @escaping @MainActor (String, CallVoice) async throws -> Data
    ) {
        player?.stop()
        player = nil
        playing = nil
        delegate = nil
        voicing?.cancel()
        voicing = nil
        switch playback.tap(line, isCached: made[speech] != nil) {
        case let .play(line):
            play(line, speech: speech)
        case let .synthesize(line):
            beginVoicing(line, speech: speech, voice: voice, synthesize: synthesize)
        case .stop, .none:
            break
        }
    }

    /// 进通话、离开聊天页、切到别的对话：正在放的、正在合成的一起停.
    func stop() {
        voicing?.cancel()
        voicing = nil
        player?.stop()
        player = nil
        playing = nil
        delegate = nil
        playback.stop()
        deactivate()
    }

    private func beginVoicing(
        _ line: String,
        speech: String,
        voice: CallVoice,
        synthesize: @escaping @MainActor (String, CallVoice) async throws -> Data
    ) {
        voicing?.cancel()
        voicing = Task { [weak self] in
            do {
                let data = try await synthesize(speech, voice)
                guard let self, !Task.isCancelled else { return }
                self.made[speech] = data
                if case let .play(line) = self.playback.voiced(line) {
                    self.play(line, speech: speech)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.playback.unvoiced(line)
            }
        }
    }

    private func play(_ line: String, speech: String) {
        guard let data = made[speech] else {
            playback.unvoiced(line)
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try session.setActive(true)
            borrowedSession = true
            let player = try AVAudioPlayer(data: data)
            player.prepareToPlay()
            let delegate = PlayerDelegate { [weak self, weak player] in
                guard let self, let player else { return }
                self.finished(player)
            }
            player.delegate = delegate
            guard player.play() else { throw PlayerError.willNotPlay }
            self.player = player
            self.playing = line
            self.delegate = delegate
        } catch {
            // Bytes it cannot play stay out of the cache: retrying asks Fish again instead
            // of replaying the same bad recording for the rest of the run.
            made[speech] = nil
            playback.unvoiced(line)
            deactivate()
        }
    }

    private func finished(_ player: AVAudioPlayer) {
        guard player === self.player else { return }
        let line = playing
        self.player = nil
        self.playing = nil
        delegate = nil
        if let line { playback.finished(line) }
        deactivate()
    }

    /// The session was only borrowed to read this line; give the microphone back at once.
    /// A session this feature never took — a call is using it — is left alone, or leaving
    /// the chat page would close the microphone of a call that is still going.
    private func deactivate() {
        guard borrowedSession else { return }
        borrowedSession = false
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    private enum PlayerError: Error {
        case willNotPlay
    }
}

/// Where a line's playing ends. One per play, so a late callback can only belong to the
/// player it was made for.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    private let finished: () -> Void

    init(finished: @escaping () -> Void) {
        self.finished = finished
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finished()
    }
}
