import EidolonCore
import SwiftUI
import UIKit

/// The debug entry (tickets #30, #31): see one of her outfits on screen and drive her by
/// hand. The buttons feed the call's events to the same `StandDirector` and animation table
/// the call screen will use (#32), so what they show is what a call will show. When there is
/// no runtime, the page fails or her files are missing, it says 「没有立绘」; opening the
/// preview again retries.
struct StandPreviewView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var characters: [CharacterConfig] = []
    @State private var selectedID: String?
    @State private var outfitID: String?
    @State private var stand: CharacterStand?
    @State private var renderer: (any StandRenderer)?
    @State private var phase = Phase.loading
    @State private var showsOutfits = false

    /// The call's events as the buttons give them; her look comes out of it.
    @State private var director = StandDirector()
    /// What the loaded outfit can play, as the player reported it.
    @State private var animations: [String: Double] = [:]
    /// The segment the buttons are on; each new segment gets the next number.
    @State private var segment = StandSegment(reply: 0, segment: 0)
    /// This segment has been started and her voice has not stopped yet.
    @State private var playing = false
    /// The call is over: she fades, as the call screen will show her.
    @State private var over = false

    private enum Phase: Equatable {
        case loading
        case shown
        case missing(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            caption
            controls
        }
        .navigationTitle("立绘预览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(characters, id: \.id) { character in
                        Button(character.name) { select(character.id) }
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .disabled(characters.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsOutfits = true
                } label: {
                    Image(systemName: "tshirt.fill")
                }
                .disabled(stand == nil)
                .accessibilityLabel("换衣装")
            }
        }
        .task {
            await start()
            #if DEBUG
            if ProcessInfo.processInfo.environment["EIDOLON_OPEN_OUTFITS"] == "1" {
                showsOutfits = true
            }
            #endif
        }
        .sheet(isPresented: $showsOutfits) {
            if let stand, let character = characters.first(where: { $0.id == selectedID }) {
                OutfitPickerView(
                    character: character,
                    stand: stand,
                    contentRoot: stand.root ?? app.core.location.contentDirectory,
                    contentVersion: app.standInfo?.installedAt
                        ?? app.bundleInfo?.installedAt ?? "current",
                    onWear: { outfit in
                        previewWear(outfit)
                    },
                    onClose: {
                        showsOutfits = false
                    }
                )
            }
        }
        .onChange(of: scenePhase) { _, value in
            renderer?.setPaused(value != .active)
        }
        .onDisappear { renderer?.setPaused(true) }
    }

    /// The stand over a dark backdrop so a transparent canvas is visible.
    private var stage: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.10), Color(white: 0.26)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                if let renderer, !hasFailed {
                    StandView(renderer: renderer)
                        .id(ObjectIdentifier(renderer as AnyObject))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .opacity(over ? 0.4 : 1)
                        .onAppear { renderer.setViewportSize(proxy.size) }
                        .onChange(of: proxy.size) { _, size in renderer.setViewportSize(size) }
                }
                switch phase {
                case .loading:
                    ProgressView("正在载入立绘…")
                        .tint(.white)
                        .foregroundStyle(.white)
                case .shown:
                    EmptyView()
                case .missing(let reason):
                    ContentUnavailableView {
                        Label("没有立绘", systemImage: "person.crop.rectangle")
                    } description: {
                        Text(reason)
                    }
                    .foregroundStyle(.white)
                }
            }
        }
    }

    private var hasFailed: Bool {
        if case .missing = phase { true } else { false }
    }

    private var caption: some View {
        VStack(spacing: 2) {
            if let character = characters.first(where: { $0.id == selectedID }) {
                Text(character.name)
                    .font(.headline)
            }
            Text(stateLine)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let outfitID {
                Text("衣装 \(outfitID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// The direction the buttons have driven her to, as words, so the state is checkable
    /// even where the stand cannot draw.
    private var stateLine: String {
        let direction = director.direction
        var parts = [
            "情绪 \(Self.moodName(direction.mood))",
            direction.speaking ? "张嘴" : "闭嘴",
            direction.looking ? "看镜头" : "不看",
        ]
        if let nod = direction.nod {
            parts.append("\(nod.kind == .yes ? "点头" : "摇头") \(nod.id)")
        }
        if over { parts.append("通话结束") }
        return parts.joined(separator: " · ")
    }

    /// The events of a call, by hand. Laid out in a grid; they are a debug tool, not a
    /// design.
    private var controls: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                Group {
                    button("她开始说话") { sheStartsSpeaking() }
                    button("她停止说话") { sheStopsSpeaking() }
                    button("我开始说话") { iStartSpeaking() }
                    button("我停止说话") { iStopSpeaking() }
                }
                ForEach(StandEmotion.allCases, id: \.self) { mood in
                    button(Self.moodName(mood)) { feel(mood) }
                }
                button("点头") { nod(.yes) }
                button("摇头") { nod(.no) }
                button("通话结束") { endCall() }
            }
            .padding(12)
        }
        .frame(maxHeight: 240)
        .background(.bar)
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private static func moodName(_ mood: StandEmotion) -> String {
        switch mood {
        case .calm: "平静"
        case .happy: "开心"
        case .shy: "害羞"
        case .surprised: "惊讶"
        case .sad: "难过"
        case .angry: "生气"
        case .thinking: "思考"
        }
    }

    // MARK: - Driving her

    private func sheStartsSpeaking() {
        resume()
        startSegmentIfNeeded()
        director.apply(.botStartedSpeaking)
        render()
    }

    private func sheStopsSpeaking() {
        resume()
        director.apply(.botStoppedSpeaking)
        // Her voice stopped: this segment is said, so the next button starts the next one.
        segment = StandSegment(reply: segment.reply, segment: segment.segment + 1)
        playing = false
        render()
    }

    private func iStartSpeaking() {
        resume()
        director.apply(.userStartedSpeaking)
        render()
    }

    private func iStopSpeaking() {
        resume()
        director.apply(.userStoppedSpeaking)
        render()
    }

    /// Give the segment she is on an emotion, judged as the call's judge would.
    private func feel(_ mood: StandEmotion) {
        resume()
        startSegmentIfNeeded()
        director.apply(.segmentJudged(StandJudgement(segment: segment, emotion: mood)))
        render()
    }

    /// A nod or shake of the head, which the judge sends along with an emotion.
    private func nod(_ kind: StandNod.Kind) {
        resume()
        startSegmentIfNeeded()
        director.apply(
            .segmentJudged(
                StandJudgement(segment: segment, emotion: director.direction.mood, nod: kind)
            )
        )
        render()
    }

    private func endCall() {
        director.apply(.callOver)
        segment = StandSegment(reply: 0, segment: 0)
        playing = false
        over = true
        render()
    }

    /// Pressing any button after the call is over starts the next call.
    private func resume() {
        over = false
    }

    /// Nothing is playing: start this segment, so an emotion or nod has somewhere to go.
    private func startSegmentIfNeeded() {
        guard !playing else { return }
        director.apply(.segmentStarted(segment))
        playing = true
    }

    /// Ask the animation table what the current direction looks like on this outfit.
    private func render() {
        guard let renderer else { return }
        renderer.direct(
            StandAnimator.pose(
                for: director.direction,
                reducedMotion: reduceMotion,
                animations: animations
            )
        )
    }

    // MARK: - Loading her

    private func start() async {
        var withStands: [CharacterConfig] = []
        for character in app.characters {
            if await app.core.stand(for: character.id) != nil {
                withStands.append(character)
            }
        }
        characters = withStands
        guard let first = characters.first else {
            phase = .missing("这份内容包里没有带立绘的角色")
            return
        }
        await show(first.id)
    }

    private func select(_ id: String) {
        Task { await show(id) }
    }

    /// Load her default outfit into a fresh renderer; a new renderer is also the retry
    /// after a failure.
    private func show(_ id: String) async {
        selectedID = id
        outfitID = nil
        stand = nil
        phase = .loading
        renderer?.setPaused(true)
        renderer = nil
        animations = [:]
        director = StandDirector()
        segment = StandSegment(reply: 0, segment: 0)
        playing = false
        over = false

        guard let found = await app.core.stand(for: id) else {
            phase = .missing("内容包里没有她的立绘")
            return
        }
        stand = found
        let worn = found.worn(
            choice: StandOutfitChoiceStore().choice(for: id)
        )
        outfitID = worn.id
        loadRenderer(worn, root: found.root ?? app.core.location.contentDirectory)
    }

    /// Put the outfit chosen in the picker on the preview without losing the action it
    /// was showing: the renderer is replaced, but the director and segment stay.
    private func previewWear(_ outfit: StandOutfit) {
        guard let stand else { return }
        outfitID = outfit.id
        phase = .loading
        loadRenderer(outfit, root: stand.root ?? app.core.location.contentDirectory)
    }

    private func loadRenderer(_ outfit: StandOutfit, root: URL) {
        renderer?.setPaused(true)
        let renderer = StandWebRenderer(
            contentRoot: root,
            framing: StandFraming(compactWidth: sizeClass != .regular)
        )
        renderer.onLoaded = { report in
            animations = report.animations
            phase = .shown
            render()
        }
        renderer.onFailure = { failure in
            phase = .missing(Self.reason(failure))
        }
        renderer.setPaused(scenePhase != .active)
        // What she can play is not known until the page reports it; the first pose is
        // sent again as soon as it does.
        renderer.direct(
            StandAnimator.pose(
                for: director.direction,
                reducedMotion: reduceMotion,
                animations: animations
            )
        )
        self.renderer = renderer
        renderer.load(outfit)
    }

    private static func reason(_ failure: StandRenderFailure) -> String {
        switch failure {
        case .page(let message): "立绘页面打不开：\(message)"
        case .runtime(let message): "没有 Spine 运行时：\(message)"
        case .outfit(let message): "立绘素材读不出：\(message)"
        }
    }
}

/// Hosts whichever stand renderer the interface was given; it never sees WebKit.
private struct StandView: UIViewRepresentable {
    let renderer: any StandRenderer

    func makeUIView(context: Context) -> UIView {
        renderer.view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
