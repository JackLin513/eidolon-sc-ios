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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var session: CallSession?
    @State private var state: CallState = .connecting
    /// The line she is saying now; older ones are in the conversation.
    @State private var line: HerLine?
    @State private var hearing: String?
    @State private var failure: String?
    @State private var startError: String?
    @State private var started = false
    /// When the call connected, for the status line; nil until it does.
    @State private var connectedAt: Date?
    /// When it ended, for how long it lasted.
    @State private var endedAt: Date?
    /// Her backdrop image, when the bundle carries one.
    @State private var backdrop: UIImage?

    /// Her stand, driven by the call's events. Nothing is drawn without one.
    @State private var callStand = CallStandDirector()
    @State private var renderer: (any StandRenderer)?
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
    @State private var showsOutfits = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background(size: geometry.size)
                    .ignoresSafeArea()
                if let renderer, !standFailed {
                    standStage(renderer, size: geometry.size)
                }
                bottomShade(size: geometry.size)
                content
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .task {
            guard !started else { return }
            started = true
            loadBackdrop()
            // Her stand does not wait on the call: it is there even when the call cannot be
            // made (no keys yet), and her outfit can still be looked at.
            await loadStand()
            standChecked = true
            await dial()
        }
        .fullScreenCover(isPresented: $showsOutfits) {
            if let stand {
                OutfitPickerView(
                    character: character,
                    stand: stand,
                    contentRoot: app.core.location.contentDirectory,
                    contentVersion: app.bundleInfo?.installedAt ?? "current",
                    onWear: { outfit in
                        outfitChosen(outfit)
                    },
                    onClose: {
                        showsOutfits = false
                    }
                )
            }
        }
        .interactiveDismissDisabled(session != nil && !isEnded)
        .onChange(of: scenePhase) { _, phase in
            renderer?.setPaused(phase != .active)
            // Back from a phone call or the background: the system may have stopped the
            // microphone, so ask it to open again (spec「通话健壮性」).
            if phase == .active, session != nil {
                Task { await session?.recoverAudio() }
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
    private var canRedial: Bool {
        guard case let .ended(reason) = state else { return false }
        if case let .sheHungUp(until) = reason, until != nil { return false }
        return true
    }

    private var isCompactWidth: Bool { sizeClass != .regular }

    // MARK: - Start

    /// Start the call; a redial starts it again from a clean screen.
    private func dial() async {
        resetCallState()
        do {
            let call = try await app.beginCall(for: character)
            session = call
            let events = call.events()
            await call.start()
            autoHangUpIfRequested(call)
            for await event in events {
                handle(event)
            }
        } catch {
            startError = error.localizedDescription
        }
    }

    /// What belongs to one call, cleared before a redial so nothing of the last one shows.
    private func resetCallState() {
        session = nil
        state = .connecting
        line = nil
        hearing = nil
        failure = nil
        startError = nil
        connectedAt = nil
        endedAt = nil
        callStand = CallStandDirector()
    }

    private func redial() {
        guard canRedial else { return }
        Task { await dial() }
    }

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
            contentRoot: app.core.location.contentDirectory,
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
        renderer.setPaused(scenePhase != .active)
        if standViewport != .zero {
            renderer.setViewportSize(standViewport)
        }
        self.renderer = renderer
        renderer.load(outfit)
    }

    /// Put the outfit she just chose on her: the same renderer loads it in place, so the
    /// camera, her direction and the call all stay; if this one cannot load, her default
    /// takes over. The choice stays remembered either way.
    private func outfitChosen(_ outfit: StandOutfit) {
        guard let renderer, !standFailed else { return }
        let fallback = outfit.id == stand?.defaultOutfit.id
            ? []
            : [stand?.defaultOutfit].compactMap { $0 }
        fallbackOutfits = fallback
        renderer.load(outfit)
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_CALL_HANGUP_MS` ends the call by itself,
    /// so the record it leaves can be seen without tapping.
    private func autoHangUpIfRequested(_ call: CallSession) {
        #if DEBUG
        guard let text = ProcessInfo.processInfo.environment["EIDOLON_CALL_HANGUP_MS"],
              let milliseconds = Int(text), milliseconds >= 0
        else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(milliseconds))
            await call.hangUp()
        }
        #endif
    }

    private func handle(_ event: CallEvent) {
        switch event {
        case let .state(next):
            state = next
            // The call is connected when the recognizer can hear, not when the microphone
            // opens (spec「接通」): listening is the first state that means that. A call
            // that never connects stays without a clock.
            if connectedAt == nil, case .listening = next {
                connectedAt = Date()
            }
            if isEnded, endedAt == nil { endedAt = Date() }
        case let .hearing(text):
            hearing = text.isEmpty ? nil : text
        case .recognized:
            hearing = nil
            failure = nil
        case let .segment(_, _, ja, zh):
            line = HerLine(ja: ja, zh: zh)
        case .segmentStarted, .segmentStopped, .emotion:
            break
        case let .failed(message):
            failure = message
        }
        callStand.apply(event)
        renderPose()
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
                    if let failure {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 24)
                    }
                    lineCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
            footer
        }
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    private var header: some View {
        ZStack {
            if hasStand {
                VStack(spacing: 2) {
                    Text(character.name)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    status
                }
                .frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                if showsOutfitButton {
                    Button {
                        showsOutfits = true
                    } label: {
                        Image(systemName: "tshirt.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.white.opacity(0.16), in: Circle())
                    }
                    .accessibilityLabel("换衣装")
                }
            }
        }
        .padding(.horizontal, 20)
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

    /// Only a character whose bundle carries a stand, and whose stand can draw, can be
    /// changed: otherwise there is nothing to preview or put on her (spec「退化」).
    private var showsOutfitButton: Bool {
        stand != nil && renderer != nil && !standFailed
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
    /// producer is saying at the foot while they are saying it (upstream `LineCard`).
    private var lineCard: some View {
        VStack(spacing: 4) {
            if let line {
                Text(line.ja)
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                if !line.zh.isEmpty {
                    Text(line.zh)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
            } else {
                Text("直接说话就好")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            if let hearing {
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

    /// The end card: why it ended, when she will talk again if she is cooling down, and
    /// 「返回」/「重拨」 (upstream `Ended`). While the call is on, it is the hang-up key.
    private func endedCard(_ reason: CallEnd) -> some View {
        VStack(spacing: 12) {
            Text(reason.message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            if case let .sheHungUp(until) = reason, let until {
                Text(cooldownText(until))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("返回") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.25))
                if canRedial {
                    Button {
                        redial()
                    } label: {
                        Label("重拨", systemImage: "phone.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.35))
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: 578)
        .frame(maxWidth: .infinity)
        .background {
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(.white.opacity(0.12)))
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if !isEnded {
                Button {
                    Task {
                        await session?.hangUp()
                        dismiss()
                    }
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.red, in: Circle())
                }
                .accessibilityLabel("挂断")
                .disabled(session == nil)
            }
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
            Button("返回") { dismiss() }
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct HerLine {
    let ja: String
    let zh: String
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
