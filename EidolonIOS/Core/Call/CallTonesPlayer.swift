import AVFoundation
import EidolonCore
import OSLog

/// The phone's own sounds, made real with AVFoundation (spec #35). One player for the whole
/// app, held by `AppModel`, so a hang-up tone outlives the call page and a redial can cut
/// whatever the last call left playing.
///
/// During a call the microphone owns a `.playAndRecord` + `.voiceChat` session, and the
/// tones play on it as it is — the current route, the call's volume, the silent switch
/// ignored. A call that ended before the microphone ever opened (a denied permission, say)
/// has no session to play on: the hang-up tone opens a temporary `.playback` session and
/// leaves it once the tone is done.
final class CallTonesPlayer: CallTones, @unchecked Sendable {
    /// How long a hang-up tone may hold the call open (upstream releases the microphone
    /// after two seconds at most).
    static let hangUpWait: Duration = .seconds(2)

    private static let log = Logger(subsystem: "com.jacklin.eidolon", category: "call")

    private let lock = NSLock()
    private var current: AVAudioPlayer?
    /// A `.playback` session opened just for a tone, to be left once it ends.
    private var usesTemporarySession = false

    func ring() -> (any Ringback)? {
        stopEverything()
        guard let player = tonePlayer("ringback", "mp3") else { return nil }
        player.numberOfLoops = -1
        guard player.play() else {
            Self.log.error("铃声放不出来")
            return nil
        }
        let ring = Ringing(player: player, length: Duration.seconds(player.duration))
        hold(player)
        Self.log.notice("ringing")
        return ring
    }

    func connect() {
        stopEverything()
        guard let player = tonePlayer("connect", "m4a") else { return }
        guard player.play() else {
            Self.log.error("tone connect.m4a will not play")
            return
        }
        hold(player)
    }

    func hangUp() async {
        stopEverything()
        // The session is settled before the player is made: preparing a player can activate
        // the audio session itself, which would fight the category change below.
        await openTemporarySessionIfNeeded()
        guard let player = tonePlayer("hang-up", "mp3") else {
            await leaveTemporarySession()
            return
        }
        guard player.play() else {
            Self.log.error("挂断音放不出来")
            await leaveTemporarySession()
            return
        }
        hold(player)
        await waitFor(player, upTo: Self.hangUpWait)
        release(player)
        await leaveTemporarySession()
    }

    func silence() {
        stopEverything()
        Task { await leaveTemporarySession() }
    }

    // MARK: - Playing

    private func tonePlayer(_ name: String, _ ext: String) -> AVAudioPlayer? {
        guard let url = toneURL(name, ext), let player = try? AVAudioPlayer(contentsOf: url) else {
            Self.log.error("tone \(name).\(ext) missing or unreadable")
            return nil
        }
        player.prepareToPlay()
        return player
    }

    private func toneURL(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
    }

    private func hold(_ player: AVAudioPlayer) {
        lock.lock()
        current = player
        lock.unlock()
    }

    private func release(_ player: AVAudioPlayer) {
        lock.lock()
        if current === player { current = nil }
        lock.unlock()
    }

    /// Stops whichever tone is sounding. A new tone always cuts the old one: they never
    /// overlap.
    private func stopEverything() {
        lock.lock()
        let playing = current
        current = nil
        lock.unlock()
        playing?.stop()
    }

    /// Waits for the tone to end on its own, but never longer than the call allows: a
    /// player that hangs must not keep the microphone open.
    private func waitFor(_ player: AVAudioPlayer, upTo limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while player.isPlaying, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if player.isPlaying {
            Self.log.error("tone did not finish in time; cutting it")
            player.stop()
        }
    }

    // MARK: - The audio session

    /// A call's session is `.playAndRecord`, and it stays that way until the microphone lets
    /// go — which happens after the hang-up tone has had its say — so the category says
    /// whether there is a session to play on. Only a call that ended before the microphone
    /// opened (a denied permission, say) needs one made for the tone alone.
    /// `.playback` ignores the silent switch, and mixing keeps it from stopping whatever
    /// else the phone was playing.
    private func openTemporarySessionIfNeeded() async {
        let session = AVAudioSession.sharedInstance()
        // There is no public `isActive` to ask; the category is the honest signal we have.
        guard session.category != .playAndRecord else { return }
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            if #available(iOS 27.0, *) {
                try await session.activate(options: [])
            } else {
                try session.setActive(true)
            }
            lock.lock()
            usesTemporarySession = true
            lock.unlock()
        } catch {
            Self.log.error("tone session could not open: \(error.localizedDescription)")
        }
    }

    private func leaveTemporarySession() async {
        lock.lock()
        let opened = usesTemporarySession
        usesTemporarySession = false
        lock.unlock()
        guard opened else { return }
        let session = AVAudioSession.sharedInstance()
        // A redial may have taken the session back for a call since the tone opened it;
        // deactivating then would cut that call's audio.
        guard session.category == .playback else { return }
        if #available(iOS 27.0, *) {
            _ = try? await session.deactivate(options: .notifyOthersOnDeactivation)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// One ring, as the call holds it: how much of the first loop is left, counted from when it
/// first began to play — not where the loop has got to (spec #35).
private final class Ringing: Ringback, @unchecked Sendable {
    private let lock = NSLock()
    private let player: AVAudioPlayer
    private let length: Duration
    private let startedAt = ContinuousClock.now
    private var stopped = false

    init(player: AVAudioPlayer, length: Duration) {
        self.player = player
        self.length = length
    }

    func left() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, player.isPlaying else { return .zero }
        let left = length - (ContinuousClock.now - startedAt)
        return left > .zero ? left : .zero
    }

    func stop() {
        lock.lock()
        let wasPlaying = !stopped
        stopped = true
        lock.unlock()
        if wasPlaying { player.stop() }
    }
}
