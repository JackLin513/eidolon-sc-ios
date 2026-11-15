#if DEBUG
import AVFoundation
import EidolonCore
import OSLog
import SwiftUI
import UIKit

/// Development-only story theatre: plays one extracted MLTD commu story on the 3D
/// stand — the scene script's own 60 fps timeline drives the body pose, face and
/// gestures, and each line's decoded voice plays under a Japanese subtitle.
///
/// Content comes from `tools/build_story_demo.py` (`Unity3DContent/stories/`):
/// `index.json`, `<story>/story.json`, `<story>/audio/<key>.m4a`, shared
/// `motions/<clip>.tsv` (flat 30 fps). Open with `EIDOLON_STORY=<storyId>` or
/// `EIDOLON_STORY=1` for the first story.
struct StoryTheaterView: View {
    @Environment(AppModel.self) private var app
    @State private var renderer: (any CharacterRenderer)?
    @State private var player: StoryPlayer?
    @State private var status = "正在读取剧情…"
    @State private var audioReady = false

    private static let log = Logger(subsystem: "com.jacklin.eidolon", category: "story")

    /// Settings only offers the theatre when the app actually carries a story pack.
    static var hasBundledStories: Bool { root() != nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // `actor_2d_bg` is drawn by Unity behind the stand. Rendering it here as
            // well produced two differently scaled copies of the same image and the
            // seam the operator saw, so the theatre keeps the Unity pass only.
            if let renderer {
                // The subtitle card owns the bottom third of the screen. The shot is
                // panned inside Unity (`SetCameraBias`) rather than scaling this view:
                // scaling would also scale the authored backdrop and leave a seam.
                // The explicit frame matters: without it the Unity view keeps its own
                // full-window size inside the ZStack and the shot renders zoomed in.
                GeometryReader { geo in
                    StandHostView(renderer: renderer)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
                .opacity(audioReady ? 1 : 0)
                .allowsHitTesting(false)
            }
            // `actor_fade_screen`: black/white fade over the whole scene.
            if let player {
                StoryStageFade(player: player)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            VStack(spacing: 12) {
                Spacer()
                if let player {
                    StoryPanel(player: player)
                } else {
                    Text(status)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(10)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 24)
                }
            }
        }
        .task { start() }
        .onDisappear { player?.stop() }
    }

    static func root() -> URL? {
        if let raw = ProcessInfo.processInfo.environment["EIDOLON_STORY_ROOT"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Unity3DContent", isDirectory: true)
            .appendingPathComponent("stories", isDirectory: true)
        return FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.json").path)
            ? bundled : nil
    }

    @MainActor
    private func start() {
        guard let root = Self.root() else {
            status = "没有剧情数据（EIDOLON_STORY_ROOT 或 bundle Unity3DContent/stories）"
            return
        }
        let indexURL = root.appendingPathComponent("index.json")
        guard let indexData = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(StoryIndex.self, from: indexData),
              !index.stories.isEmpty
        else {
            status = "index.json 读不出来：\(indexURL.path)"
            return
        }
        let requested = ProcessInfo.processInfo.environment["EIDOLON_STORY"] ?? ""
        let summary = index.stories.first { $0.id == requested }
            ?? index.stories.first!
        guard let storyData = try? Data(contentsOf: root.appendingPathComponent(summary.story)),
              let story = try? JSONDecoder().decode(Story.self, from: storyData)
        else {
            status = "story.json 读不出来：\(summary.story)"
            return
        }
        guard let outfit = app.first3DOutfit(for: story.character) else {
            status = "没有 \(story.character) 的 3D 映射（先导入 model3d 包）"
            return
        }
        let assets = app.preparedAssets(RuntimeAssets(
            contentRoot: app.core.location.contentDirectory,
            characterID: story.character,
            outfit: outfit,
            framing: .full
        ))
        guard let made = app.makeRenderer(assets, allow3D: true) else {
            status = "没有可用的 3D 渲染器"
            return
        }
        (made as? UnityCharacterRenderer)?.performsEmotionActions = false
        made.onReady = { [self] _ in
            audioReady = true
            status = ""
            // Pan the shot up so the subtitle card never covers the skirt.
            (made as? UnityCharacterRenderer)?.probeSway()
            (made as? UnityCharacterRenderer)?.setCameraZoom(1.42)
            (made as? UnityCharacterRenderer)?.setCameraBias(0.16)
            // Script scenes stand in the game's own `p01` idle, not the daily loop.
            let neutral = root.appendingPathComponent("motions/cut_01z_lop.tsv")
            if FileManager.default.fileExists(atPath: neutral.path) {
                (made as? UnityCharacterRenderer)?.setIdleClip(atPath: neutral.path)
            }
            let player = StoryPlayer(story: story, root: root, renderer: made)
            self.player = player
            player.start()
        }
        made.onFailure = { [self] failure in
            audioReady = false
            status = "3D 失败：\(failure)"
        }
        made.setViewport(UIScreen.main.bounds.size)
        renderer = made
        made.prepare(assets)
    }
}

/// Observes the player for the background id: the theatre view owns the player as
/// `@State`, so it has to hand it to a child that declares the dependency.
private struct StoryStageBackground: View {
    @ObservedObject var player: StoryPlayer
    let root: URL?

    var body: some View {
        if let name = player.backgroundID {
            StoryBackgroundImage(name: name, root: root)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }
}

/// `actor_fade_screen` overlay.
private struct StoryStageFade: View {
    @ObservedObject var player: StoryPlayer

    var body: some View {
        (player.fadeIsBlack ? Color.black : Color.white)
            .opacity(player.fadeAlpha)
            .allowsHitTesting(false)
    }
}

/// One ADV background from the story pack.
private struct StoryBackgroundImage: View {
    let name: String
    let root: URL?

    var body: some View {
        if let root,
           let image = UIImage(contentsOfFile: root.appendingPathComponent("backgrounds/\(name).jpg").path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipped()
                .transition(.opacity)
        } else {
            Color.black
        }
    }
}

/// The subtitle card and transport. It observes the player directly: the player is
/// created after Unity reports its first character, so it cannot be a `@StateObject`
/// of the theatre view itself.
private struct StoryPanel: View {
    @ObservedObject var player: StoryPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(player.story.situation.isEmpty ? player.story.id : player.story.situation)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(player.progress)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.55))
            }
            Text(player.speakerLabel)
                .font(.caption2)
                .foregroundStyle(.cyan.opacity(0.85))
            Text(player.subtitle)
                .font(.body)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            #if DEBUG
            Text(player.debugHUD)
                .font(.caption2.monospaced())
                .foregroundStyle(.yellow.opacity(0.8))
            #endif
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 14)

        HStack(spacing: 18) {
            Button("上一句") { player.previous() }
            Button(player.isPlaying ? "暂停" : "继续") { player.togglePause() }
            Button("下一句") { player.next() }
            Button("重播") { player.restart() }
        }
        .buttonStyle(.borderedProminent)
        .tint(.gray.opacity(0.5))
        .padding(.bottom, 8)
    }
}

// MARK: - Package models

struct StoryIndex: Decodable {
    struct Summary: Decodable {
        let id: String
        let character: String
        let situation: String
        let lines: Int
        let story: String
    }

    let stories: [Summary]
}

struct Story: Decodable {
    struct Pose: Decodable {
        let ms: Int
        let clip: String
        let pose: String
        /// ADV pose type: the game skips the `_start` clip and enters the loop directly.
        let loopDirect: Bool?
        /// Authored walk-in clip: `str` normally, `swt` for switch poses (`a16_p17`)
        /// and `act` for private one-shot actions.
        let enter: String?
    }

    struct Face: Decodable {
        let ms: Int
        let emotion: String?
        let menu: Int?
    }

    struct Gesture: Decodable {
        let ms: Int
        let kind: String
    }

    struct Cheek: Decodable {
        let ms: Int
        let level: Int
    }

    /// The ADV script's own eye commands (`actor_eye_blink`): `close`, `open` or
    /// `blink`, mirroring CharacterActorBase.SetEyeMode(CharacterEyeMode).
    struct Eye: Decodable {
        let ms: Int
        let mode: String
    }

    /// `actor_eye_direction`: horizontal / vertical gaze rate (-100…100).
    struct Gaze: Decodable {
        let ms: Int
        let h: Int
        let v: Int
    }

    /// `actor_visible_character`: hide/show a staged character.
    struct Visibility: Decodable {
        let ms: Int
        let idol: String?
        let on: Bool
    }

    /// `actor_camera_set_position_preset`: named camera setup (`solo`, …).
    struct CameraPreset: Decodable {
        let ms: Int
        let preset: String
    }

    /// `actor_character_set_position_preset`: named floor position for one character.
    struct PlacePreset: Decodable {
        let ms: Int
        let idol: String?
        let preset: String
        let location: Int?
    }

    /// `actor_2d_bg`: the authored ADV background, optionally faded in.
    struct Background: Decodable {
        let ms: Int
        let id: String
        let fadeIn: Bool?
        let fadeOut: Bool?
    }

    /// `actor_load_character` / `actor_change_costume`.
    struct LoadCharacter: Decodable {
        let ms: Int
        let idol: String?
        let model: String?
        let costume: String?
        let setId: Int?
    }

    /// `actor_chara_dorotate` / `actor_set_rotation`: rotation in degrees.
    struct Rotation: Decodable {
        let ms: Int
        let endMs: Int?
        let idol: String?
        let x: Double
        let y: Double
        let z: Double
        let ease: String?
        let mode: String?
    }

    /// `actor_set_position`: explicit stage offset in metres.
    struct Offset: Decodable {
        let ms: Int
        let endMs: Int?
        let idol: String?
        let x: Double
        let y: Double
        let z: Double
    }

    /// `actor_fade_screen`: `black_fadein_ex_ui` / `black_fadeout_ex_ui` etc.
    struct Fade: Decodable {
        let ms: Int
        let endMs: Int?
        let type: String
    }

    /// `actor_in_out`: walk in from / out to the side of the stage.
    struct InOut: Decodable {
        let ms: Int
        let endMs: Int?
        let idol: String?
        let name: String
        let speed: Double?
    }

    /// `actor_lip`: `Close` or `Fomalhout`.
    struct LipMode: Decodable {
        let ms: Int
        let mode: String
    }

    /// `actor_sound`: BGM / ambience cue from the game's ADX2 cue sheets.
    struct SoundCue: Decodable {
        let ms: Int
        let kind: String
        let op: String
        let sheet: String
        let name: String
    }

    struct Line: Decodable {
        let cut: String
        let speaker: String
        let speakerName: String?
        let key: String
        let ja: String
        let startFrame: Int
        let endFrame: Int
        let scriptMs: Int
        let voiceMs: Int
        let voice: String?
        let lipFps: Int?
        let lip: [Double]?
        let poses: [Pose]
        let faces: [Face]
        let gestures: [Gesture]
        let cheeks: [Cheek]
        let eyes: [Eye]?
        let gazes: [Gaze]?
        let visibility: [Visibility]?
        let cameras: [CameraPreset]?
        let places: [PlacePreset]?
        let backgrounds: [Background]?
        let loads: [LoadCharacter]?
        let costumes: [LoadCharacter]?
        let rotations: [Rotation]?
        let offsets: [Offset]?
        let fades: [Fade]?
        let inouts: [InOut]?
        let sits: [Sit]?
        let lips: [LipMode]?
        let sounds: [SoundCue]?
    }

    /// `actor_sit_pose`: sits are resolved into pose events by the pack builder; the raw
    /// command is kept so the log can show why the pose changed.
    struct Sit: Decodable {
        let ms: Int
        let endMs: Int?
        let idol: String?
        let pose: String
        let direct: Bool?
    }

    let id: String
    let character: String
    let situation: String
    let place: String
    let fps: Int
    let lines: [Line]
}

// MARK: - Playback

/// Walks one story: each line owns its audio and its scene-script events. Events are
/// dispatched from the script's own frame→millisecond numbers, so the body follows the
/// authored cut instead of any single looping action.
@MainActor
final class StoryPlayer: ObservableObject {
    private static let log = Logger(subsystem: "com.jacklin.eidolon", category: "story")

    let story: Story
    private let root: URL
    private weak var renderer: UnityCharacterRenderer?
    private var audio: AVAudioPlayer?
    private var ticker: Timer?
    private var startedAt: Date?
    private var lineIndex = 0
    private var poseCursor = 0
    private var faceCursor = 0
    private var gestureCursor = 0
    private var cheekCursor = 0
    private var eyeCursor = 0
    private var stagingCursor = [String: Int]()
    private var activeFade: (from: Double, to: Double, start: Int, end: Int)?
    private var gazeCursor = 0
    private var lineDurationMs = 0
    private var paused = false

    @Published private(set) var subtitle = ""
    @Published private(set) var speaker = ""

    /// Display label for the current line: the pack ships the Chinese character name,
    /// and the script's `p` speaker is the producer.
    var speakerLabel: String {
        if speaker == "p" { return "制作人" }
        return story.lines.indices.contains(lineIndex)
            ? (story.lines[lineIndex].speakerName ?? speaker)
            : speaker
    }
    @Published private(set) var progress = ""
    @Published private(set) var isPlaying = false

    /// Scene staging output consumed by the view: the ADV background and screen fade.
    @Published private(set) var backgroundID: String?
    @Published private(set) var fadeAlpha: Double = 0
    @Published private(set) var fadeIsBlack = true

    #if DEBUG
    @Published private(set) var debugPose = "-"
    @Published private(set) var debugGesture = "-"
    @Published private(set) var debugFace = "-"

    var debugHUD: String {
        "L\(lineIndex + 1) pose=\(debugPose) g=\(debugGesture) face=\(debugFace)"
    }
    #endif

    init(story: Story, root: URL, renderer: any CharacterRenderer) {
        self.story = story
        self.root = root
        self.renderer = renderer as? UnityCharacterRenderer
    }

    func start() {
        configureAudioSession()
        // Debug shortcut so a long story can be checked at a specific beat
        // (sit poses, lip-mode changes, fades) without sitting through it.
        let jump = ProcessInfo.processInfo.environment["EIDOLON_STORY_START"].flatMap(Int.init) ?? 0
        lineIndex = min(max(jump, 0), max(story.lines.count - 1, 0))
        playLine()
        // Debug: hold on the jumped line so a specific pose can be inspected.
        if ProcessInfo.processInfo.environment["EIDOLON_STORY_HOLD"] != nil {
            paused = true
            isPlaying = false
        }
    }

    func stop() {
        stop(keepPose: false)
    }

    /// `keepPose` is for 重播: the story's standing pose must survive the reset,
    /// otherwise the character falls back to her own daily `act` loop and the
    /// restart looks like she started doing her personal idle instead of the scene.
    func stop(keepPose: Bool) {
        ticker?.invalidate()
        ticker = nil
        audio?.stop()
        audio = nil
        isPlaying = false
        renderer?.setLipEnvelope(fps: 30, values: [])
        renderer?.setSpeaking(false)
        if !keepPose { renderer?.resetPose() }
    }

    func restart() {
        stop(keepPose: true)
        start()
    }

    func next() {
        guard lineIndex + 1 < story.lines.count else {
            finish()
            return
        }
        lineIndex += 1
        playLine()
    }

    func previous() {
        lineIndex = max(0, lineIndex - 1)
        playLine()
    }

    func togglePause() {
        paused.toggle()
        isPlaying = !paused
        if paused {
            audio?.pause()
            ticker?.invalidate()
            ticker = nil
        } else {
            audio?.play()
            scheduleTicker()
        }
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Self.log.error("audio session failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Lines

    private func playLine() {
        ticker?.invalidate()
        ticker = nil
        audio?.stop()
        audio = nil
        guard lineIndex < story.lines.count else {
            finish()
            return
        }
        let line = story.lines[lineIndex]
        subtitle = line.ja
        speaker = line.speaker
        progress = "\(lineIndex + 1)/\(story.lines.count)"
        poseCursor = 0
        faceCursor = 0
        gestureCursor = 0
        cheekCursor = 0
        eyeCursor = 0
        gazeCursor = 0
        stagingCursor = [:]
        // Only lines with an authored voice move the mouth. The producer / narration
        // lines (`speaker == "p"`) have no recording, and the game keeps the character
        // still while they are on screen — talking along with them is what made the
        // stand look like it was lip-syncing to nothing.
        if let voice = line.voice {
            renderer?.setSpeaking(true)
            // The authored `fhout` envelope makes the mouth follow this line's voice
            // instead of the placeholder vowel cycle.
            renderer?.setLipEnvelope(fps: line.lipFps ?? 30, values: line.lip ?? [])
            let url = root.appendingPathComponent(voice)
            audio = try? AVAudioPlayer(contentsOf: url)
            audio?.prepareToPlay()
            audio?.play()
        } else {
            renderer?.setLipEnvelope(fps: 30, values: [])
            renderer?.setSpeaking(false)
        }
        // The scenario window (`actor_text` frames at 60 fps) is the minimum, but the
        // game lets the line finish: a voice longer than its window keeps the line on
        // screen until the recording ends (plus the short tail before the next cut).
        let voicedMs = Int((audio?.duration ?? 0) * 1000)
        lineDurationMs = max(max(line.scriptMs, voicedMs + 300), 200)
        Self.log.info("line \(line.key, privacy: .public) ms=\(self.lineDurationMs) voice=\(line.voice ?? "-", privacy: .public)")
        #if DEBUG
        print("[story] line \(lineIndex + 1) \(line.key) ms=\(lineDurationMs) script=\(line.scriptMs) voiceMs=\(voicedMs)")
        #endif
        startedAt = Date()
        paused = false
        isPlaying = true
        dispatchDueEvents(elapsedMs: 0, line: line)
        scheduleTicker()
    }

    private func scheduleTicker() {
        ticker?.invalidate()
        let start = startedAt ?? Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.tick(reference: start)
            }
        }
    }

    private func tick(reference: Date) {
        guard !paused else { return }
        // Resuming restarts the clock so paused time does not skip a line's events.
        if startedAt == nil { startedAt = reference }
        let elapsed = Int(Date().timeIntervalSince(startedAt ?? reference) * 1000)
        guard lineIndex < story.lines.count else { return }
        let line = story.lines[lineIndex]
        dispatchDueEvents(elapsedMs: elapsed, line: line)
        if elapsed >= lineDurationMs {
            ticker?.invalidate()
            ticker = nil
            if lineIndex + 1 < story.lines.count {
                lineIndex += 1
                playLine()
            } else {
                finish()
            }
        }
    }

    private func dispatchDueEvents(elapsedMs: Int, line: Story.Line) {
        while poseCursor < line.poses.count, line.poses[poseCursor].ms <= elapsedMs {
            let pose = line.poses[poseCursor]
            let path = root.appendingPathComponent("motions/\(pose.clip).tsv").path
            renderer?.playPose(atPath: path, loopDirect: pose.loopDirect ?? false, enter: pose.enter)
            Self.log.info("pose \(pose.pose, privacy: .public) -> \(pose.clip, privacy: .public) @\(pose.ms)ms direct=\(pose.loopDirect ?? false, privacy: .public) enter=\(pose.enter ?? "str", privacy: .public)")
            #if DEBUG
            debugPose = "\(pose.clip)@\(elapsedMs)"
            #endif
            poseCursor += 1
        }
        while faceCursor < line.faces.count, line.faces[faceCursor].ms <= elapsedMs {
            let face = line.faces[faceCursor]
            if let menu = face.menu {
                renderer?.setFacialMenu(menu)
            } else if let raw = face.emotion {
                present(emotion: StandEmotion(rawValue: raw) ?? .calm, speaking: true)
            }
            #if DEBUG
            debugFace = "\(face.menu.map(String.init) ?? face.emotion ?? "-")@\(elapsedMs)"
            #endif
            faceCursor += 1
        }
        while gestureCursor < line.gestures.count, line.gestures[gestureCursor].ms <= elapsedMs {
            let gesture = line.gestures[gestureCursor]
            renderer?.setNod(yes: gesture.kind == "yes")
            Self.log.info("gesture \(gesture.kind, privacy: .public) @\(gesture.ms)ms")
            #if DEBUG
            debugGesture = "\(gesture.kind)@\(elapsedMs)"
            #endif
            gestureCursor += 1
        }
        while cheekCursor < line.cheeks.count, line.cheeks[cheekCursor].ms <= elapsedMs {
            let cheek = line.cheeks[cheekCursor]
            renderer?.setCheek(cheek.level)
            cheekCursor += 1
        }
        while eyeCursor < (line.eyes?.count ?? 0), line.eyes![eyeCursor].ms <= elapsedMs {
            let eye = line.eyes![eyeCursor]
            renderer?.setEyeMode(eye.mode)
            Self.log.info("eye \(eye.mode, privacy: .public) @\(eye.ms)ms")
            eyeCursor += 1
        }
        while gazeCursor < (line.gazes?.count ?? 0), line.gazes![gazeCursor].ms <= elapsedMs {
            let gaze = line.gazes![gazeCursor]
            renderer?.setGaze(h: gaze.h, v: gaze.v)
            Self.log.info("gaze \(gaze.h, privacy: .public),\(gaze.v, privacy: .public) @\(gaze.ms)ms")
            gazeCursor += 1
        }
        dispatchStaging(elapsedMs: elapsedMs, line: line)
    }

    /// The remaining ADV actor commands: background, visibility, rotation, offset,
    /// screen fade, lip mode, in/out and sound cues.
    private func dispatchStaging(elapsedMs: Int, line: Story.Line) {
        var cursor = stagingCursor["background", default: 0]
        let backgrounds = line.backgrounds ?? []
        while cursor < backgrounds.count, backgrounds[cursor].ms <= elapsedMs {
            let event = backgrounds[cursor]
            let url = root.appendingPathComponent("backgrounds/\(event.id).jpg")
            backgroundID = FileManager.default.fileExists(atPath: url.path) ? event.id : nil
            renderer?.setBackground(fileURL: backgroundID == nil ? nil : url)
            Self.log.info("background \(event.id, privacy: .public) @\(event.ms)ms")
            cursor += 1
        }
        stagingCursor["background"] = cursor

        cursor = stagingCursor["camera", default: 0]
        let cameras = line.cameras ?? []
        while cursor < cameras.count, cameras[cursor].ms <= elapsedMs {
            let event = cameras[cursor]
            renderer?.setCameraPreset(event.preset)
            Self.log.info("camera preset \(event.preset, privacy: .public) @\(event.ms)ms")
            cursor += 1
        }
        stagingCursor["camera"] = cursor

        cursor = stagingCursor["place", default: 0]
        let places = line.places ?? []
        while cursor < places.count, places[cursor].ms <= elapsedMs {
            let event = places[cursor]
            renderer?.setPlacePreset(event.preset)
            Self.log.info("place preset \(event.preset, privacy: .public) location=\(event.location ?? 0) @\(event.ms)ms")
            cursor += 1
        }
        stagingCursor["place"] = cursor

        cursor = stagingCursor["load", default: 0]
        let loads = line.loads ?? []
        while cursor < loads.count, loads[cursor].ms <= elapsedMs {
            let event = loads[cursor]
            Self.log.info("load character \(event.idol ?? "-", privacy: .public) model=\(event.model ?? "-", privacy: .public) costume=\(event.costume ?? "-", privacy: .public)")
            cursor += 1
        }
        stagingCursor["load"] = cursor

        cursor = stagingCursor["costume", default: 0]
        let costumes = line.costumes ?? []
        while cursor < costumes.count, costumes[cursor].ms <= elapsedMs {
            let event = costumes[cursor]
            Self.log.info("costume \(event.idol ?? "-", privacy: .public) set=\(event.setId ?? 0) @\(event.ms)ms")
            cursor += 1
        }
        stagingCursor["costume"] = cursor

        cursor = stagingCursor["visibility", default: 0]
        let visibility = line.visibility ?? []
        while cursor < visibility.count, visibility[cursor].ms <= elapsedMs {
            let event = visibility[cursor]
            renderer?.setVisible(event.on)
            Self.log.info("visible \(event.on, privacy: .public) @\(event.ms)ms")
            cursor += 1
        }
        stagingCursor["visibility"] = cursor

        cursor = stagingCursor["rotation", default: 0]
        let rotations = line.rotations ?? []
        while cursor < rotations.count, rotations[cursor].ms <= elapsedMs {
            let event = rotations[cursor]
            if let endMs = event.endMs, endMs > event.ms {
                renderer?.rotateCharacter(
                    x: event.x, y: event.y, z: event.z,
                    durationMs: endMs - event.ms, ease: event.ease ?? "linear"
                )
            } else {
                renderer?.setCharacterRotation(x: event.x, y: event.y, z: event.z)
            }
            Self.log.info("rotate \(event.x, privacy: .public),\(event.y, privacy: .public),\(event.z, privacy: .public) @\(event.ms)ms")
            cursor += 1
        }
        stagingCursor["rotation"] = cursor

        cursor = stagingCursor["offset", default: 0]
        let offsets = line.offsets ?? []
        while cursor < offsets.count, offsets[cursor].ms <= elapsedMs {
            let event = offsets[cursor]
            renderer?.setCharacterOffset(x: event.x, y: event.y, z: event.z)
            cursor += 1
        }
        stagingCursor["offset"] = cursor

        cursor = stagingCursor["fade", default: 0]
        let fades = line.fades ?? []
        while cursor < fades.count, fades[cursor].ms <= elapsedMs {
            let event = fades[cursor]
            let fadingOut = event.type.contains("fadeout")
            fadeIsBlack = !event.type.lowercased().contains("white")
            activeFade = (
                from: fadingOut ? 0 : 1,
                to: fadingOut ? 1 : 0,
                start: event.ms,
                end: max(event.endMs ?? event.ms, event.ms + 1)
            )
            Self.log.info("fade \(event.type, privacy: .public) @\(event.ms)ms")
            cursor += 1
        }
        stagingCursor["fade"] = cursor

        cursor = stagingCursor["lip", default: 0]
        let lips = line.lips ?? []
        while cursor < lips.count, lips[cursor].ms <= elapsedMs {
            let event = lips[cursor]
            renderer?.setLipMode(event.mode)
            Self.log.info("lip mode \(event.mode, privacy: .public) @\(event.ms)ms")
            cursor += 1
        }
        stagingCursor["lip"] = cursor

        cursor = stagingCursor["inout", default: 0]
        let inouts = line.inouts ?? []
        while cursor < inouts.count, inouts[cursor].ms <= elapsedMs {
            let event = inouts[cursor]
            renderer?.playInOut(
                name: event.name,
                speed: event.speed ?? 0,
                durationMs: max((event.endMs ?? event.ms) - event.ms, 1)
            )
            Self.log.info("inout \(event.name, privacy: .public) @\(event.ms)ms")
            cursor += 1
        }
        stagingCursor["inout"] = cursor

        cursor = stagingCursor["sound", default: 0]
        let sounds = line.sounds ?? []
        while cursor < sounds.count, sounds[cursor].ms <= elapsedMs {
            let event = sounds[cursor]
            // The game streams BGM from its own ADX2 cue sheets; the pack only carries
            // the cue name, so log it until the cue audio is extracted.
            Self.log.info("sound \(event.kind, privacy: .public)/\(event.op, privacy: .public) \(event.sheet, privacy: .public):\(event.name, privacy: .public) @\(event.ms)ms")
            cursor += 1
        }
        stagingCursor["sound"] = cursor

        if let fade = activeFade {
            let span = Double(max(fade.end - fade.start, 1))
            let t = min(max(Double(elapsedMs - fade.start) / span, 0), 1)
            let eased = t * t * (3 - 2 * t)
            fadeAlpha = fade.from + (fade.to - fade.from) * eased
            if t >= 1 { activeFade = nil }
        }
    }

    private func present(emotion: StandEmotion, speaking: Bool) {
        renderer?.present(PresentationFrame(
            emotion: emotion,
            speaking: speaking,
            looking: true,
            framing: .knees
        ))
    }

    private func finish() {
        ticker?.invalidate()
        ticker = nil
        audio?.stop()
        audio = nil
        isPlaying = false
        renderer?.setLipEnvelope(fps: 30, values: [])
        renderer?.setSpeaking(false)
        renderer?.resetExpression()
        // Play the pose's authored `_end` clip (that is the animator's own
        // `_end -> idle` transition, see docs/research/mltd-motion-reverse-engineering-2026-11-15.md)
        // and settle into the neutral `p01` idle the theatre installed on load.
        renderer?.resetPose()
        subtitle = "— 完 —\n\(story.situation)"
        speaker = story.character
        Self.log.info("story finished: \(self.story.id, privacy: .public)")
        // Debug hook: prove 重播 keeps the scene's standing pose instead of falling
        // back to the character's own daily action loop.
        if ProcessInfo.processInfo.environment["EIDOLON_STORY_AUTORESTART"] != nil {
            Self.log.info("auto restart in 2.5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.restart()
            }
        }
    }
}
#endif
