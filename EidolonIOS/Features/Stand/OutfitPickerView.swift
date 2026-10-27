import EidolonCore
import SwiftUI
import UIKit

/// Her outfits on the call screen (spec「衣装与换衣装」, upstream `OutfitPicker`): a big
/// preview on top, then a grid of her cards — each with a thumbnail drawn from her own
/// stand, its name, and a 私服 / 演出 switch (「只有一套」 when it has one). Tapping a
/// card only previews it; 「穿这套」 remembers it for this character on this device, puts
/// it on her at once and closes. Only the content bundle's own outfits are ever listed, so
/// what can be chosen is what can be worn.
struct OutfitPickerView: View {
    let character: CharacterConfig
    let stand: CharacterStand
    let contentRoot: URL
    /// Put it on her in the call that is going on; the call itself is not interrupted.
    let onWear: (StandOutfit) -> Void
    /// Close the sheet. The caller closes it by name: inside nested covers the environment's
    /// dismiss can reach past this sheet to the call (and the chat under it).
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The outfit she has on: the one remembered for her, or her default.
    @State private var wornID: String
    /// The outfit the preview is showing; tapping and the switches only change this.
    @State private var pickedID: String
    @State private var renderer: StandWebRenderer?
    /// The outfit the renderer was last told to show, so tapping the same one does not
    /// reload her.
    @State private var loadedID: String?
    @State private var phase = PreviewPhase.loading
    @State private var rendererFailed = false
    /// The preview box's size, so a renderer made after a failure frames her the same.
    @State private var previewSize = CGSize.zero

    private enum PreviewPhase: Equatable {
        case loading
        case shown
        case failed
    }

    init(
        character: CharacterConfig,
        stand: CharacterStand,
        contentRoot: URL,
        onWear: @escaping (StandOutfit) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.character = character
        self.stand = stand
        self.contentRoot = contentRoot
        self.onWear = onWear
        self.onClose = onClose
        let worn = stand.worn(choice: StandOutfitChoiceStore().choice(for: character.id))
        _wornID = State(initialValue: worn.id)
        _pickedID = State(initialValue: worn.id)
    }

    var body: some View {
        ZStack {
            background
            // Where the thumbnail renderer draws: on screen so WebKit paints, behind the
            // sheet's own background and invisibly small in effect.
            ThumbnailBench(view: OutfitThumbnailStore.shared.bench)
                .frame(
                    width: OutfitThumbnailStore.size.width,
                    height: OutfitThumbnailStore.size.height
                )
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                titleBar
                ScrollView {
                    VStack(spacing: 22) {
                        preview
                        cardGrid
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { showPicked() }
        .onChange(of: pickedID) { _, _ in showPicked() }
        .onChange(of: scenePhase) { _, next in
            renderer?.setPaused(next != .active)
            OutfitThumbnailStore.shared.setPaused(next != .active)
        }
        .onDisappear {
            renderer?.setPaused(true)
            OutfitThumbnailStore.shared.setPaused(true)
        }
    }

    // MARK: - What is previewed

    /// Where the previewed outfit sits in her list; nil when it is her default and the list
    /// does not carry it.
    private var found: (card: OutfitCard, look: OutfitLook, outfit: StandOutfit)? {
        stand.outfitList?.find(pickedID)
    }

    /// The outfit she has on now, remembered choice and fallback resolved.
    private var wornOutfit: StandOutfit {
        stand.worn(choice: wornID)
    }

    /// What the big preview shows: the picked outfit, or — as upstream — the one she wears
    /// when the list cannot place it.
    private var previewedOutfit: StandOutfit {
        found?.outfit ?? wornOutfit
    }

    private var isWorn: Bool { previewedOutfit.id == wornOutfit.id }

    private var cards: [OutfitCard] {
        // A card whose outfits are all missing from the bundle is not shown at all; when
        // nothing is left (or the list could not be read), her default outfit is all there
        // is, and it is already on her.
        if let list = stand.outfitList {
            let listed = list.cards.filter { !$0.looks.isEmpty }
            if !listed.isEmpty { return listed }
        }
        return [
            OutfitCard(
                id: stand.defaultOutfit.id,
                name: "默认衣装",
                type: "",
                everyday: stand.defaultOutfit
            )
        ]
    }

    // MARK: - The sheet

    private var background: some View {
        ZStack {
            Color(white: 0.07)
            LinearGradient(
                colors: [herColor.opacity(0.22), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    private var titleBar: some View {
        VStack(spacing: 4) {
            HStack {
                Text("换衣装")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("关闭")
            }
            Text("打电话时她会穿这一套；只存在这台设备上。")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var preview: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(previewWall)
                    if let renderer {
                        StandHostView(renderer: renderer)
                            // A renderer replaced after a failure is a new view; without
                            // this SwiftUI would keep showing the old one.
                            .id(ObjectIdentifier(renderer as AnyObject))
                            .onAppear {
                                previewSize = proxy.size
                                renderer.setViewportSize(proxy.size)
                            }
                            .onChange(of: proxy.size) { _, size in
                                previewSize = size
                                renderer.setViewportSize(size)
                            }
                    }
                    switch phase {
                    case .loading:
                        ProgressView()
                            .tint(.white)
                    case .shown:
                        EmptyView()
                    case .failed:
                        Text("这套没能载入")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .frame(height: 360)

            VStack(spacing: 3) {
                Text(found.map { "【\($0.card.name)】" } ?? "默认衣装")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(previewSubtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }

            Button {
                wear()
            } label: {
                Text("穿这套")
                    .font(.headline)
                    .frame(minWidth: 140)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(herColor)
            // Never wear what is already on, and never wear something not drawn yet: what
            // she is about to wear has to be what the preview shows.
            .disabled(isWorn || phase != .shown)
        }
    }

    private var previewWall: LinearGradient {
        LinearGradient(
            colors: [herColor.opacity(0.45), herColor.opacity(0.12)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 「私服 · P_SR · 正在穿」, as upstream puts it under the preview.
    private var previewSubtitle: String {
        var parts: [String] = []
        if let found {
            parts.append(found.look == .everyday ? "私服" : "演出服")
            if !found.card.type.isEmpty { parts.append(found.card.type) }
        }
        if isWorn { parts.append("正在穿") }
        if phase == .failed { parts.append("这套没能载入") }
        return parts.joined(separator: " · ")
    }

    private var cardGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
            spacing: 14
        ) {
            ForEach(cards, id: \.id) { card in
                OutfitCardTile(
                    card: card,
                    pickedID: pickedID,
                    contentRoot: contentRoot,
                    herColor: herColor
                ) { outfitID in
                    pickedID = outfitID
                }
            }
        }
    }

    private var herColor: Color {
        Color(hex: character.color ?? "#e08fb0")
    }

    // MARK: - Previewing and wearing

    /// Load whatever is picked now into the preview renderer. A renderer that failed is
    /// replaced, so one bad outfit does not leave the sheet with no preview at all.
    private func showPicked() {
        let outfit = previewedOutfit
        guard outfit.id != loadedID || phase == .failed else { return }
        loadedID = outfit.id
        phase = .loading
        if renderer == nil || rendererFailed {
            renderer?.setPaused(true)
            let created = StandWebRenderer(contentRoot: contentRoot, framing: .full)
            created.onLoaded = { [weak created] report in
                guard let created else { return }
                created.direct(calmPose(report.animations))
                phase = .shown
            }
            created.onFailure = { _ in
                phase = .failed
                rendererFailed = true
            }
            created.setPaused(scenePhase != .active)
            if previewSize != .zero {
                created.setViewportSize(previewSize)
            }
            renderer = created
            rendererFailed = false
        }
        renderer?.load(outfit)
    }

    /// The calm pose, from what this outfit can play (upstream passes `CALM`).
    private func calmPose(_ animations: [String: Double]) -> StandPose {
        StandAnimator.pose(for: .calm, reducedMotion: reduceMotion, animations: animations)
    }

    private func wear() {
        let outfit = previewedOutfit
        StandOutfitChoiceStore().remember(outfit.id, for: character.id)
        wornID = outfit.id
        onWear(outfit)
        onClose()
    }
}

/// One card: the thumbnail (a button that previews it), its name, and the switch between
/// her everyday clothes and its stage costume. A card with one outfit shows 「只有一套」
/// greyed out instead. The thumbnail follows whichever of its outfits is showing.
private struct OutfitCardTile: View {
    let card: OutfitCard
    let pickedID: String
    let contentRoot: URL
    let herColor: Color
    let onPick: (String) -> Void

    @State private var chosen: OutfitLook

    init(
        card: OutfitCard,
        pickedID: String,
        contentRoot: URL,
        herColor: Color,
        onPick: @escaping (String) -> Void
    ) {
        self.card = card
        self.pickedID = pickedID
        self.contentRoot = contentRoot
        self.herColor = herColor
        self.onPick = onPick
        _chosen = State(initialValue: card.looks.first ?? .everyday)
    }

    /// The outfit of this card that is being previewed, if any: the switch then follows it.
    private var pickedLook: OutfitLook? {
        card.looks.first { card.outfit(for: $0)?.id == pickedID }
    }

    private var look: OutfitLook { pickedLook ?? chosen }
    private var outfit: StandOutfit? { card.outfit(for: look) }
    private var isPicked: Bool { pickedLook != nil }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                if let outfit { onPick(outfit.id) }
            } label: {
                ZStack {
                    Color.white.opacity(0.07)
                    if let outfit {
                        OutfitThumbnailView(outfit: outfit, contentRoot: contentRoot)
                    }
                }
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if isPicked {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(herColor, lineWidth: 2)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("预览\(card.name)")
            .accessibilityAddTraits(isPicked ? .isSelected : [])

            Text(card.name)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 32, alignment: .top)

            if card.hasOnlyOneLook {
                Text("只有一套")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            } else {
                switchControl
            }
        }
        .padding(4)
        .background {
            if isPicked {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.08))
            }
        }
    }

    /// Upstream's segmented toggle: 私服 / 演出, the current one lit.
    private var switchControl: some View {
        HStack(spacing: 0) {
            ForEach(card.looks, id: \.self) { item in
                Button {
                    chosen = item
                    if let outfit = card.outfit(for: item) { onPick(outfit.id) }
                } label: {
                    Text(item == .everyday ? "私服" : "演出")
                        .font(.caption2)
                        .fontWeight(item == look ? .semibold : .regular)
                        .foregroundStyle(.white.opacity(item == look ? 1 : 0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if item == look {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(.white.opacity(0.2))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == look ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A card's thumbnail: her stand drawn off screen in `full` framing, from the process-wide
/// cache, with a placeholder until it is there.
private struct OutfitThumbnailView: View {
    let outfit: StandOutfit
    let contentRoot: URL

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.05)
            Image(systemName: "figure.stand")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.22))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipped()
        .task(id: outfit.id) {
            image = nil
            image = await OutfitThumbnailStore.shared.thumbnail(
                for: outfit,
                contentRoot: contentRoot
            )
        }
    }
}

/// Hosts the off-screen renderer's view. It is behind the sheet's own background: in the
/// window so WebKit paints, never seen or touched.
private struct ThumbnailBench: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
