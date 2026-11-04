import EidolonCore
import SwiftUI
import UIKit

/// The call screen, laid out as upstream's `CallLayer` (spec「通话层」): her blurred likeness
/// behind, her stand standing on the bottom, her name and status on top, the one line she is
/// saying in a card, and the hang-up key. It only shows what `CallSession` reports (ADR-0015)
/// and drives her stand from the same events (`CallStandDirector`).
struct CallView: View {
    let character: CharacterConfig

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// The one call, owned by the app so folding it away or changing pages loses nothing
    /// (spec #46). The view only draws it.
    private var call: CallController { app.call }
    private var session: CallSession? { call.session }
    private var state: CallState { call.state }
    private var line: HerLine? { call.line }
    private var previousLine: HerLine? { call.previousLine }
    private var hearing: String? { call.hearing }
    private var typed: String? { call.typed }
    private var textOnly: Bool { call.textOnly }
    private var muted: Bool { call.muted }
    private var failure: String? { call.failure }
    private var startError: String? { call.startError }
    private var connectedAt: Date? { call.connectedAt }
    private var endedAt: Date? { call.endedAt }
    private var callStand: CallStandDirector { call.stand }
    /// Her backdrop image, when the bundle carries one.
    @State private var backdrop: UIImage?

    /// Her stand, driven by the call's events. Nothing is drawn without one.
    @State private var renderer: (any StandRenderer)?
    /// Whether the producer is typing during the call (spec #47), and what they have typed.
    @State private var typing = false
    @State private var draft = ""
    @FocusState private var typingFocused: Bool
    /// Whether the app went to the background, so coming back replaces the audio and the
    /// recognizer's connection; a Control Center pull only makes it inactive.
    @State private var wasBackgrounded = false
    /// What the loaded outfit can play, as the player reported it.
    @State private var animations: [String: Double] = [:]
    @State private var standLoaded = false
    @State private var standFailed = false
    /// Her stand read from the bundle: the default outfit and, when it reads, her list.
    @State private var stand: CharacterStand?
    /// Whether the bundle has been asked for her stand yet: before that, the screen keeps
    /// the stand layout so a character who has one never flashes the avatar version.
    @State private var standChecked = false
    /// The outfits still to try if the one being loaded turns out to be unreadable: her
    /// default after the one she wears, so a broken outfit never leaves her without a stand.
    @State private var fallbackOutfits: [StandOutfit] = []
    /// The size the stand is laid out at, so a renderer made mid-call frames her the same.
    @State private var standViewport = CGSize.zero
    /// The picture opened full screen; nothing of it can be saved or shared (ticket #103).
    @State private var viewingPhoto: CallPhoto?

    var body: some View {
        ZStack {
            // Her likeness and stand keep the whole screen when the keyboard is up; only the
            // words and the bottom row rise above it.
            GeometryReader { geometry in
                ZStack {
                    background(size: geometry.size)
                        .ignoresSafeArea()
                    if let renderer, !standFailed {
                        standStage(renderer, size: geometry.size)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .ignoresSafeArea(.keyboard)
            GeometryReader { geometry in
                ZStack {
                    bottomShade(size: geometry.size)
                    content
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .background(Color.black)
        // Only the open layer is dark. Folded away, it must not drag the pages behind it
        // into dark mode: the tab pages keep the system's appearance, and the call bar is
        // dark on its own (spec #46).
        .preferredColorScheme(call.layer == .collapsed ? nil : .dark)
        .fullScreenCover(item: $viewingPhoto) { photo in
            PhotoViewer(id: photo.id)
        }
        .task {
            loadBackdrop()
            // Her stand does not wait on the call: it is there even when the call cannot be
            // made (no keys yet), and her outfit can still be looked at.
            await loadStand()
            standChecked = true
        }
        // Her events move her stand through the controller; the layer draws the pose.
        .onChange(of: call.stand.direction) {
            renderPose()
        }
        // VoiceOver says the loss once when it appears and once when it is over.
        .onChange(of: call.micNotice) { previous, notice in
            if let notice {
                UIAccessibility.post(notification: .announcement, argument: notice.message)
            } else if previous != nil {
                UIAccessibility.post(notification: .announcement, argument: "麦克风恢复了")
            }
        }
        // Folded away, her stand is off screen: keep it from drawing until it is back.
        .onChange(of: call.layer) {
            updatePause()
        }
        // Esc (iPad or an external keyboard) folds the layer away, as upstream does.
        .background {
            EscapeKey { call.collapse() }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onChange(of: isEnded) { _, ended in
            if ended {
                typing = false
                typingFocused = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            updatePause()
            if phase == .background { wasBackgrounded = true }
            // Back from a phone call or the background: the system may have stopped the
            // microphone, so ask it to open again (spec「通话健壮性」). After a real
            // background the recognizer's connection is replaced too: a websocket can die
            // while the app is suspended without reporting it, leaving the call looking
            // connected while nothing it hears arrives.
            if phase == .active, session != nil {
                let reconnect = wasBackgrounded
                wasBackgrounded = false
                Task {
                    if reconnect {
                        await call.appDidBecomeActive()
                    } else {
                        await call.recoverAudio()
                    }
                }
            }
        }
        .onDisappear { renderer?.setPaused(true) }
    }

    private var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    private var isConnecting: Bool {
        if case .connecting = state { return true }
        return false
    }

    /// Whether the bundle carries a stand for her at all. A character without one gets the
    /// large avatar and the dialling ripple instead (upstream `hasStand`). Until the bundle
    /// has been asked, the stand layout is kept so nothing flashes.
    private var hasStand: Bool { !standChecked || stand != nil }

    /// She hung up for a cooldown: there is no calling her until it ends, so no redial
    /// (upstream `endCard`).
    private var canRedial: Bool { call.canRedial }

    private var isCompactWidth: Bool { sizeClass != .regular }

    /// Her backdrop is only shown when the bundle has one; otherwise her avatar is blown up.
    private func loadBackdrop() {
        guard let path = character.background, !path.isEmpty else { return }
        let url = app.core.location.contentDirectory.appendingPathComponent(path)
        backdrop = UIImage(contentsOfFile: url.path)
    }

    /// A fresh renderer each call: one that failed last time gets another try now (spec
    /// 「退化」). No stand in the bundle means no renderer, and the call runs as it always did.
    /// She is put in the outfit remembered for her, or her default when that outfit is gone
    /// (spec「衣装与换衣装」); a fresh renderer is also the retry after a failure.
    private func loadStand() async {
        guard renderer == nil, let found = await app.core.stand(for: character.id) else { return }
        stand = found
        let outfits = found.outfitsToTry(
            choice: StandOutfitChoiceStore().choice(for: character.id)
        )
        guard let worn = outfits.first else { return }
        showStand(worn, fallback: Array(outfits.dropFirst()))
    }

    /// Put one outfit on her. A broken outfit falls back to the next one (her default); a
    /// page or runtime that cannot draw ends her stand for this call.
    private func showStand(_ outfit: StandOutfit, fallback: [StandOutfit]) {
        let previous = renderer
        previous?.setPaused(true)
        // The new renderer starts blank: keep her hidden until it reports, so a fallback
        // in mid-call fades her back in instead of showing an empty stage at full opacity.
        standLoaded = false
        let renderer = StandWebRenderer(
            contentRoot: stand?.root ?? app.core.location.contentDirectory,
            framing: StandFraming(compactWidth: isCompactWidth)
        )
        fallbackOutfits = fallback
        renderer.onLoaded = { report in
            animations = report.animations
            standLoaded = true
            renderPose()
        }
        renderer.onFailure = { failure in
            // The renderer logs why; losing her is never fatal, the call goes on.
            if case .outfit = failure, let next = fallbackOutfits.first {
                showStand(next, fallback: Array(fallbackOutfits.dropFirst()))
                return
            }
            standLoaded = false
            standFailed = true
        }
        if standViewport != .zero {
            renderer.setViewportSize(standViewport)
        }
        self.renderer = renderer
        updatePause()
        renderer.load(outfit)
    }

    /// Her stand draws only while the layer is on screen and the app is active.
    private func updatePause() {
        renderer?.setPaused(call.layer == .collapsed || scenePhase != .active)
    }

    /// Ask the animation table what the current direction looks like on this outfit.
    private func renderPose() {
        guard let renderer else { return }
        renderer.direct(
            StandAnimator.pose(
                for: callStand.direction,
                reducedMotion: reduceMotion,
                animations: animations
            )
        )
    }

    // MARK: - The bottom

    /// Her silhouette, blown up and blurred, under a gradient dark enough for white words
    /// (upstream `Backdrop`). A backdrop image, when there is one, is shown as it is.
    private func background(size: CGSize) -> some View {
        ZStack {
            if let backdrop {
                Image(uiImage: backdrop)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(1.25)
            } else if let image = app.avatar(for: character.id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(1.25)
                    .blur(radius: 64)
            } else {
                Color(hex: character.color ?? "#333333")
            }
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.25), location: 0),
                    .init(color: callShade, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
    }

    /// Her stand on the bottom 80% of the screen, under the words and the keys and taking no
    /// touches (spec「通话层」). It rises 12% and fades in when it arrives on a phone, only
    /// fades on wider screens and with reduced motion, and stays at 40% once the call is over.
    private func standStage(_ renderer: any StandRenderer, size: CGSize) -> some View {
        let height = size.height * 0.8
        let viewport = CGSize(width: size.width, height: height)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            StandHostView(renderer: renderer)
                // A fallback replaces the renderer with a new view; without this SwiftUI
                // would keep the failed one on screen.
                .id(ObjectIdentifier(renderer as AnyObject))
                .frame(width: viewport.width, height: viewport.height)
                .opacity(standLoaded ? 1 : 0)
                .animation(.linear(duration: 0.3), value: standLoaded)
                .offset(y: riseOffset(height: height))
                .animation(riseAnimation, value: standLoaded)
                .onAppear {
                    standViewport = viewport
                    renderer.setViewportSize(viewport)
                }
                .onChange(of: viewport) { _, next in
                    standViewport = next
                    renderer.setViewportSize(next)
                }
        }
        .frame(width: size.width, height: size.height, alignment: .bottom)
        .opacity(isEnded ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.5), value: isEnded)
        .allowsHitTesting(false)
        .ignoresSafeArea(edges: .bottom)
    }

    private func riseOffset(height: CGFloat) -> CGFloat {
        guard !standLoaded, isCompactWidth, !reduceMotion else { return 0 }
        return height * 0.12
    }

    /// Upstream's `ease-call`: 410 ms, `cubic-bezier(0.24, 1, 0.4, 1)`.
    private var riseAnimation: Animation {
        isCompactWidth && !reduceMotion
            ? .timingCurve(0.24, 1, 0.4, 1, duration: 0.41)
            : .linear(duration: 0.3)
    }

    /// The lower half darkens to her deep colour so the card and the keys read on clothes.
    private func bottomShade(size: CGSize) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: callDeep.opacity(0.88), location: 0.55),
                    .init(color: callDeep, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: size.height * 0.5)
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }

    /// Her call layer's deep colour: her image colour darkened hard, as upstream derives
    /// `--her-call-deep` in OKLCH. A plain darkening is close enough without the conversion.
    private var callDeep: Color { deepColor(0.3) }
    private var callShade: Color { deepColor(0.24) }

    private func deepColor(_ factor: Double) -> Color {
        let cleaned = (character.color ?? "").replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6 else { return Color(white: 0.16) }
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255 * factor,
            green: Double((value >> 8) & 0xFF) / 255 * factor,
            blue: Double(value & 0xFF) / 255 * factor
        )
    }

    // MARK: - Words

    private var content: some View {
        VStack(spacing: 0) {
            header
            if startError == nil, !hasStand {
                noStandIdentity
                    .padding(.top, 28)
            }
            Spacer(minLength: 0)
            if let startError {
                startFailure(startError)
            } else if case let .ended(reason) = state {
                // The end card replaces her line and what is being heard (upstream `Ended`).
                endedCard(reason)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            } else {
                VStack(spacing: 12) {
                    // The microphone went away and cannot come back: say so above her line,
                    // quietly enough to read as a status (spec #41).
                    if let notice = call.micNotice {
                        Text(notice.message)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    if let failure {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 24)
                    }
                    if let photo = call.photo {
                        photoChip(photo)
                    }
                    lineCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
            if startError == nil, !isEnded {
                bottomControls
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    /// Three slots, as upstream: 换衣装 on the left, her name and status in the middle,
    /// 只看文字 on the right. Both switches are gone once the call is over; both work while
    /// it dials.
    private var header: some View {
        HStack(spacing: 12) {
            HStack {
                if call.isLive {
                    Button {
                        call.collapse()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.white.opacity(0.16), in: Circle())
                    }
                    .accessibilityLabel("收起")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            if hasStand {
                VStack(spacing: 2) {
                    Text(character.name)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    status
                }
                .fixedSize()
            }
            HStack {
                Spacer(minLength: 0)
                if startError == nil, !isEnded {
                    textOnlyKey
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
    }

    /// Upstream's 只看文字 glass pill: icon and words, lit white with black words while it is
    /// on. Its state is remembered on this phone, so it reads the same on the next call.
    private var textOnlyKey: some View {
        Button {
            call.toggleTextOnly()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 15, weight: .semibold))
                Text("只看文字")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(textOnly ? Color.black : Color.white)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(Capsule().fill(textOnly ? Color.white : Color.white.opacity(0.15)))
        }
        .accessibilityLabel("只看文字")
        .accessibilityValue(textOnly ? "开" : "关")
        .accessibilityAddTraits(textOnly ? .isSelected : [])
    }

    /// Her without a stand: the large avatar, a dialling ripple while it connects, her name
    /// and the status line (upstream `MarkedAvatar` in `Ripple`).
    private var noStandIdentity: some View {
        VStack(spacing: 10) {
            ZStack {
                if isConnecting, !reduceMotion {
                    DialingRipple()
                }
                avatar
            }
            .frame(width: 112, height: 112)
            Text(character.name)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            status
        }
        .frame(maxWidth: .infinity)
    }

    private var avatar: some View {
        ZStack {
            if let image = app.avatar(for: character.id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(hex: character.color ?? "#333333")
                Text(String(character.name.prefix(1)))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
    }

    /// Upstream's `Status`: calling while it connects, how long it has lasted once connected,
    /// and that it is over when it is.
    @ViewBuilder
    private var status: some View {
        if case let .ended(reason) = state {
            HStack(spacing: 4) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 12))
                Text(endedText(reason))
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.8))
        } else if case .connecting = state {
            HStack(spacing: 4) {
                Text("正在呼叫")
                if !reduceMotion { DialingDots() }
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.8))
        } else if case .reconnecting = state {
            // Upstream does not show a reconnect; saying so is more useful than a clock
            // that looks like nothing is wrong.
            Text("重连中…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        } else if let cue = call.affinityCue, connectedAt != nil {
            // A turn just changed her affinity: the words take the clock's place for a
            // moment (upstream `Status`, spec #38).
            AffinityCueLabel(change: cue.change, name: character.name)
                .font(.subheadline)
                .foregroundStyle(.white)
        } else if let connectedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(CallClock.shown(CallClock.time(
                    since: connectedAt,
                    limit: session?.durationLimit,
                    now: context.date
                )))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func endedText(_ reason: CallEnd) -> String {
        _ = reason
        guard let connectedAt, let endedAt else { return "通话已结束" }
        return "通话已结束 · \(CallClock.clock(Int(endedAt.timeIntervalSince(connectedAt))))"
    }

    /// Her one line right now: Japanese first, the smaller Chinese under it, and what the
    /// producer is saying at the foot while they are saying it (upstream `LineCard`). While
    /// 只看文字 is on, the segment before it in the same reply stays faint above it.
    private var lineCard: some View {
        VStack(spacing: 4) {
            if let line {
                VStack(spacing: 4) {
                    if textOnly, let previousLine {
                        lineText(previousLine)
                            .opacity(0.45)
                            .padding(.bottom, 12)
                    }
                    lineText(line)
                }
            } else {
                Text(textOnly ? "她会用文字回复" : "直接说话就好")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            if let typed {
                Text("你说：\(typed)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 8)
            } else if let hearing {
                Text("正在听：\(hearing)…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(.white.opacity(0.12)))
        }
        .frame(maxWidth: 578)
        .frame(maxWidth: .infinity)
    }

    private func lineText(_ line: HerLine) -> some View {
        VStack(spacing: 4) {
            Text(line.ja)
                .font(.system(size: 17))
                .foregroundStyle(.white)
            if !line.zh.isEmpty {
                Text(line.zh)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    /// The end card: why it ended, when she will talk again if she is cooling down, and
    /// 「回到对话」 with 「重拨」 beside it (upstream `Ended`). No gift and no allowance here in
    /// version 1.
    private func endedCard(_ reason: CallEnd) -> some View {
        VStack(spacing: 12) {
            Text(reason.message)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if case let .sheHungUp(until) = reason, let until {
                Text(cooldownText(until))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button {
                    call.returnFromCall()
                } label: {
                    Text("返回")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .frame(height: 44)
                        .background {
                            let shape = Capsule()
                            shape
                                .fill(.ultraThinMaterial)
                                .overlay(shape.fill(.white.opacity(0.15)))
                        }
                }
                if canRedial {
                    Button {
                        call.redial()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 17))
                            Text("重拨")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 24)
                        .frame(height: 44)
                        .background(Capsule().fill(.white))
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: 578)
        .frame(maxWidth: .infinity)
        .background {
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(.white.opacity(0.12)))
        }
    }

    /// The bottom of the call: the typing row once it is open, else the dock, as upstream
    /// (`TypingBar` replaces `Dock`). The keyboard takes the space below; closing the row
    /// brings mute and 挂断 back.
    @ViewBuilder
    private var bottomControls: some View {
        if typing, !isEnded {
            typingRow
        } else {
            dock
        }
    }

    private var typingRow: some View {
        HStack(spacing: 8) {
            Button {
                typingFocused = false
                typing = false
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("收起键盘")
            .accessibilityIdentifier("call.closeTyping")
            TextField("打字给她…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .tint(.white)
                .lineLimit(1...4)
                .focused($typingFocused)
                .submitLabel(.send)
                .onSubmit(sendTyped)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(0.16))
                }
                .accessibilityIdentifier("call.typingField")
                .onAppear { typingFocused = true }
            Button(action: sendTyped) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("发送")
            .accessibilityIdentifier("call.send")
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(.white.opacity(0.12)))
        }
        .padding(.horizontal, 8)
    }

    private func sendTyped() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await call.say(text) }
    }

    /// The dock: one glass capsule holding the mute key, the typing key and the hang-up key
    /// (upstream `Dock`). 麦克风静音 is greyed out until the call connects; the whole dock is
    /// gone once it ends.
    private var dock: some View {
        HStack(spacing: 8) {
            Button {
                call.toggleMuted()
            } label: {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(muted ? Color.black : Color.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(muted ? Color.white : Color.white.opacity(0.15)))
            }
            .accessibilityLabel("麦克风静音")
            .accessibilityValue(muted ? "开" : "关")
            .accessibilityAddTraits(muted ? .isSelected : [])
            .disabled(isConnecting || session == nil)
            .opacity(isConnecting ? 0.35 : 1)
            if !typing {
                Button {
                    typing = true
                } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(.white.opacity(0.15)))
                }
                .accessibilityLabel("打字")
                .accessibilityIdentifier("call.openTyping")
                .disabled(isConnecting || session == nil)
                .opacity(isConnecting ? 0.35 : 1)
            }
            Button {
                // The end card comes up on its own when the call ends; the hang-up tone
                // belongs to the app's own player, so it still sounds behind the chat
                // (spec #35).
                Task { await call.hangUp() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 20))
                    Text("挂断")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .frame(height: 56)
                .background(Capsule().fill(Color(hex: "#c8283c")))
            }
            .accessibilityLabel("挂断")
            .accessibilityIdentifier("call.hangUp")
            .disabled(session == nil)
        }
        .padding(8)
        .background {
            let shape = Capsule()
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(.white.opacity(0.12)))
        }
        .padding(.bottom, 8)
    }

    private func cooldownText(_ until: Date) -> String {
        "她现在不想说话，\(CallEnd.moment(until)) 以后可以再找她。"
    }

    private func startFailure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "phone.down")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.7))
            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("返回") { call.returnFromCall() }
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - The picture

    /// The picture she is making or made in this call: a capsule over her words on a
    /// phone, a wider card on a tablet, above the line card so it covers neither her
    /// stand nor the keys (ticket #103).
    private func photoChip(_ photo: CallPhoto) -> some View {
        Button {
            if photo.status == .ready { viewingPhoto = photo }
        } label: {
            HStack(spacing: 10) {
                CallPhotoThumbnail(photo: photo)
                    .frame(width: sizeClass == .regular ? 56 : 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CallPhoto.saying(photo))
                        .font(sizeClass == .regular ? .subheadline : .footnote)
                        .foregroundStyle(.white)
                    if photo.status == .ready {
                        Text("点开看看")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                if sizeClass == .regular {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, sizeClass == .regular ? 16 : 12)
            .padding(.vertical, sizeClass == .regular ? 12 : 8)
            .background {
                let shape = RoundedRectangle(
                    cornerRadius: sizeClass == .regular ? 20 : 22,
                    style: .continuous
                )
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(.white.opacity(0.12)))
            }
            .frame(maxWidth: sizeClass == .regular ? 480 : .infinity)
        }
        .buttonStyle(.plain)
        .disabled(photo.status != .ready)
        .accessibilityIdentifier("call.photo")
        .accessibilityLabel(CallPhoto.saying(photo))
    }
}

/// Upstream's three pulsing dots while the call connects; still with reduced motion.
private struct DialingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.2) % 3
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(index == tick ? 0.85 : 0.35))
                        .frame(width: 4, height: 4)
                }
            }
        }
    }
}

extension CallPhoto {
    /// What the chip says without opening it.
    static func saying(_ photo: CallPhoto) -> String {
        switch photo.status {
        case .pending: return "正在拍照…"
        case .ready: return "照片"
        case .failed:
            guard let reason = photo.reason else { return "照片没发出来" }
            return "照片没发出来 · \(reason.shortText)"
        }
    }
}

/// The chip's picture, or its state while there is none.
private struct CallPhotoThumbnail: View {
    let photo: CallPhoto
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.16))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if photo.status == .pending {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.7)
            } else if photo.status == .failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .aspectRatio(PhotoGeometry.aspectRatio, contentMode: .fit)
        .task(id: photo.status) {
            guard photo.status == .ready else { return }
            image = await app.photoImage(photo.id)
        }
    }
}

/// One picture, full screen: tap or the close button puts it away. There is no save or
/// share — the picture exists only in this conversation (spec #98).
struct PhotoViewer: View {
    let id: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.4))
                    .padding(16)
            }
            .accessibilityLabel("关上照片")
            .accessibilityIdentifier("photo.close")
        }
        .task { image = await app.photoImage(id) }
        .onTapGesture { dismiss() }
    }
}

/// Two rings pulsing out from her avatar while it connects, 2 seconds each, offset by a
/// second (upstream `Ripple`). Not drawn with reduced motion.
private struct DialingRipple: View {
    @State private var animating = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .stroke(.white.opacity(0.22), lineWidth: 1.5)
                    .scaleEffect(animating ? 1.4 : 1)
                    .opacity(animating ? 0 : 1)
                    .animation(
                        .easeOut(duration: 2)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index)),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

/// A zero-size first responder that turns Esc into an action: SwiftUI's `onKeyPress`
/// only hears keys on a focused view, and the call layer has nothing to focus.
private struct EscapeKey: UIViewControllerRepresentable {
    let action: () -> Void

    func makeUIViewController(context: Context) -> EscapeResponder {
        EscapeResponder(action: action)
    }

    func updateUIViewController(_ controller: EscapeResponder, context: Context) {
        controller.action = action
    }
}

private final class EscapeResponder: UIViewController {
    var action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))]
    }

    @objc private func escape() {
        action()
    }
}
