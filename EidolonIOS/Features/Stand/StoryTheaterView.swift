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
            if let renderer {
                // The subtitle card owns the bottom third of the screen. Scale the
                // stand into the top two thirds instead of letting the card cover her
                // skirt and shoes (the Unity view keeps rendering full-screen).
                StandHostView(renderer: renderer)
                    .scaleEffect(0.72, anchor: .top)
                    .ignoresSafeArea()
                    .opacity(audioReady ? 1 : 0)
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
        lineIndex = 0
        playLine()
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
        // The game advances on the authored scenario window (`actor_text` frames at
        // 60 fps), not on the audio length: a voice longer than its window is simply
        // cut when the cut moves on.
        lineDurationMs = max(line.scriptMs, 200)
        Self.log.info("line \(line.key, privacy: .public) ms=\(self.lineDurationMs) voice=\(line.voice ?? "-", privacy: .public)")
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
