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
            Text(player.speaker == "p" ? "制作人" : player.speaker)
                .font(.caption2)
                .foregroundStyle(.cyan.opacity(0.85))
            Text(player.subtitle)
                .font(.body)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
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

    struct Line: Decodable {
        let cut: String
        let speaker: String
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
    private var lineDurationMs = 0
    private var paused = false

    @Published private(set) var subtitle = ""
    @Published private(set) var speaker = ""
    @Published private(set) var progress = ""
    @Published private(set) var isPlaying = false

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
        ticker?.invalidate()
        ticker = nil
        audio?.stop()
        audio = nil
        isPlaying = false
        renderer?.resetPose()
    }

    func restart() {
        stop()
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
        // Only the mouth starts; the face keeps whatever the previous lines left,
        // because the script's own `actor_facial` events own the expression.
        renderer?.setSpeaking(true)
        // The authored `fhout` envelope makes the mouth follow this line's voice
        // instead of the placeholder vowel cycle.
        renderer?.setLipEnvelope(fps: line.lipFps ?? 30, values: line.lip ?? [])

        if let voice = line.voice {
            let url = root.appendingPathComponent(voice)
            audio = try? AVAudioPlayer(contentsOf: url)
            audio?.prepareToPlay()
            audio?.play()
        }
        let spoken = audio?.duration ?? 0
        lineDurationMs = max(max(line.voiceMs, line.scriptMs), Int(spoken * 1000)) + 350
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
            renderer?.playPose(atPath: path)
            Self.log.info("pose \(pose.pose, privacy: .public) -> \(pose.clip, privacy: .public) @\(pose.ms)ms")
            poseCursor += 1
        }
        while faceCursor < line.faces.count, line.faces[faceCursor].ms <= elapsedMs {
            let face = line.faces[faceCursor]
            if let menu = face.menu {
                renderer?.setFacialMenu(menu)
            } else if let raw = face.emotion {
                present(emotion: StandEmotion(rawValue: raw) ?? .calm, speaking: true)
            }
            faceCursor += 1
        }
        while gestureCursor < line.gestures.count, line.gestures[gestureCursor].ms <= elapsedMs {
            let gesture = line.gestures[gestureCursor]
            renderer?.setNod(yes: gesture.kind == "yes")
            Self.log.info("gesture \(gesture.kind, privacy: .public) @\(gesture.ms)ms")
            gestureCursor += 1
        }
        while cheekCursor < line.cheeks.count, line.cheeks[cheekCursor].ms <= elapsedMs {
            let cheek = line.cheeks[cheekCursor]
            renderer?.setCheek(cheek.level)
            cheekCursor += 1
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
        // The story ends on the neutral standing pose from the same motion pack,
        // not on the daily action loop: that is the "standing still" idle the script
        // scenes use between lines.
        let neutral = root.appendingPathComponent("motions/cut_01z_lop.tsv")
        if FileManager.default.fileExists(atPath: neutral.path) {
            renderer?.playPose(atPath: neutral.path)
        } else {
            renderer?.resetPose()
        }
        subtitle = "— 完 —\n\(story.situation)"
        speaker = story.character
        Self.log.info("story finished: \(self.story.id, privacy: .public)")
    }
}
#endif
