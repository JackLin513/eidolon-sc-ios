import AVFoundation
import EidolonCore
import Foundation

/// The bar's sound (upstream `useBarSound.ts`): the tracks the jukebox plays, the sound effects
/// the screen plays, and the settings for how loud each is. The music is a queue the player
/// walks; a preview plays a track a little and goes back to what was playing.
@MainActor
@Observable
final class BarSound {
    /// The package's audio, or nothing where there is none.
    private(set) var audio = BarAudio(tracks: [], playlist: [Int](), sfx: [String]())
    /// What the player is playing: the track's id, or nil.
    private(set) var playing: Int?
    /// A track being listened to from the setup.
    private(set) var previewing: Int?
    /// The jukebox's state, kept as it was last set.
    var state: BarJukebox.State
    var settings: BarSettings.Stored

    /// The track the player was on before a preview.
    private var before: (slots: [Int?], playing: Int?)?

    private var music: AVAudioPlayer?
    private var preview: AVAudioPlayer?
    private var players: [String: AVAudioPlayer] = [String: AVAudioPlayer]()
    private var directory: URL?
    private var slot = 0
    /// Called as a track ends: the jukebox goes on to the next.
    var onTrackEnded: (() -> Void)?

    init(state: BarJukebox.State, settings: BarSettings.Stored) {
        self.state = state
        self.settings = settings
    }

    /// The catalog's sound effects: the file each name plays.
    private var effects: [String: String] = [:]

    /// Reads the package's audio, keeping the jukebox as it was where the tracks are still there.
    func load(_ audio: BarAudio, catalog: BarAudioCatalog?, in directory: URL?) {
        self.audio = audio
        effects = [:]
        for effect in catalog?.sfx ?? [] where audio.sfx.contains(effect.name) {
            effects[effect.name] = effect.file
        }
        self.directory = directory
        state = BarJukebox.read(state, audio)
        stop()
        slot = 0
        if state.isPaused || !hasJukebox { return }
        playFrom(state.slots.firstIndex { $0 == audio.tracks.first?.id } ?? 0)
    }

    var hasJukebox: Bool { audio.hasJukebox }
    /// Whether the music can be played: the device can set its volume.
    var canSetMusic: Bool { true }

    var title: String {
        guard let playing else { return "" }
        return audio.track(playing)?.title ?? ""
    }

    // MARK: - Playing

    /// Plays the queue from `index` on.
    func playFrom(_ index: Int) {
        activateSession()
        let slots = state.slots
        guard !slots.isEmpty else { return }
        slot = ((index % slots.count) + slots.count) % slots.count
        guard let id = slots[slot], let track = audio.track(id) else {
            // 空槽跳过。
            let filled = slots.indices.filter { slots[$0] != nil }
            guard let next = filled.first(where: { $0 >= slot }) ?? filled.first else { return }
            playFrom(next)
            return
        }
        playing = id
        state.isPaused = false
        let player = make(track.file, in: "audio/tracks")
        player?.volume = Float(BarSettings.gain(of: settings.music))
        player?.play()
        music?.stop()
        music = player
    }

    func togglePause() {
        guard hasJukebox else { return }
        state.isPaused.toggle()
        pausedByApp = false
        if state.isPaused {
            music?.pause()
        } else if playing == nil {
            playFrom(0)
        } else {
            music?.play()
        }
    }

    func next() {
        guard hasJukebox else { return }
        playFrom(BarJukebox.slotAfter(state.mode, slot))
    }

    func previous() {
        guard hasJukebox else { return }
        playFrom(BarJukebox.previousSlot(slot))
    }

    func changeMode(_ mode: BarJukebox.Mode) {
        state.mode = BarJukebox.toggleMode(state.mode, mode)
    }

    /// The twelve picked: a new rack, played from its first.
    func pick(_ slots: [Int?]) {
        state.slots = slots
        state.isPaused = false
        stopPreview()
        playFrom(0)
    }

    /// Plays `id` a little from the setup; `nil` stops what was previewed and goes back.
    func hear(_ id: Int?) {
        guard let id, let track = audio.track(id) else {
            stopPreview()
            return
        }
        if previewing == nil {
            before = (state.slots, playing)
            music?.pause()
        }
        previewing = id
        let player = make(track.file, in: "audio/tracks")
        player?.volume = Float(BarSettings.gain(of: settings.music))
        player?.play()
        preview?.stop()
        preview = player
    }

    func stopPreview() {
        guard previewing != nil || preview != nil else { return }
        preview?.stop()
        preview = nil
        previewing = nil
        before = nil
        if !state.isPaused { music?.play() }
    }

    /// Plays a sound effect by its name, at the effect volume.
    func play(_ name: String) {
        activateSession()
        guard let file = effects[name] else { return }
        let player: AVAudioPlayer
        if let kept = players[name] {
            kept.currentTime = 0
            player = kept
        } else {
            guard let made = make(file, in: "audio/sfx") else { return }
            players[name] = made
            player = made
        }
        player.volume = Float(BarSettings.gain(of: settings.sfx))
        player.play()
    }

    /// The app went away: the music pauses, the track it was on kept.
    func playersPause() {
        guard music?.isPlaying == true else { return }
        music?.pause()
        pausedByApp = true
    }

    /// The app is back: the music goes on where it was.
    func playersResume() {
        guard pausedByApp else { return }
        pausedByApp = false
        guard !state.isPaused else { return }
        music?.play()
    }

    /// The volume as the settings now have it.
    func applyVolume() {
        music?.volume = Float(BarSettings.gain(of: settings.music))
        preview?.volume = Float(BarSettings.gain(of: settings.music))
    }

    func stop() {
        deactivateSession()
        music?.stop()
        preview?.stop()
        music = nil
        preview = nil
        playing = nil
    }

    /// The bar's sound mixes with whatever else is playing (ADR-0021), and does not follow the
    /// silent switch: it goes out as `.playback` with `.mixWithOthers`. `.ambient`, which the
    /// bar first used, follows the switch — a phone left on silent played the whole bar with no
    /// sound at all — and the bar's sound is content, not an alert.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func make(_ file: String, in folder: String) -> AVAudioPlayer? {
        guard let directory else { return nil }
        // 原声是从游戏里提出来的 Ogg，iOS 的 Core Audio 没有 Vorbis 解码器，一个都放不了；
        // 酒吧素材包把同一首转成 AAC 放着，名字不变、只换扩展名。先按清单里的名字找，再试 AAC。
        let stem = (file as NSString).deletingPathExtension
        for name in [file, stem + ".m4a"] {
            let url = directory.appending(path: "\(folder)/\(name)")
            guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            if ended == nil {
                ended = TrackEnded { [weak self] in
                    Task { @MainActor in self?.onTrackEnded?() }
                }
            }
            player.delegate = ended
            player.prepareToPlay()
            return player
        }
        return nil
    }

    private var ended: TrackEnded?
    /// Whether the player was paused by the app going away, to be played again on coming back.
    private var pausedByApp = false
}

/// Told when a track ends, on the main run loop.
private final class TrackEnded: NSObject, AVAudioPlayerDelegate {
    private let then: () -> Void

    init(_ then: @escaping () -> Void) {
        self.then = then
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        then()
    }
}
