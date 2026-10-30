import EidolonCore
import SwiftUI

/// 客人窗 (upstream `BarGuest.tsx`): her standing behind the counter, in the window cut out of
/// the bar's frame picture. The stand is the call's own host, a WebView in the window, clipped;
/// she simply is not there until the stand loads, or if it cannot.
struct BarGuest: View {
    static let window = (x: 19.0, y: 27.0, width: 410.0, height: 241.0)
    /// The stand's own 280 wide place, its left edge inside the window.
    static let stand = (x: 45.0, width: 280.0)

    let character: CharacterConfig
    /// Her stand: the outfit remembered for her, or her default. nil until the visit says who
    /// she is, or when the content has no stand for her.
    let stand: CharacterStand?
    let mood: StandEmotion
    let isSpeaking: Bool

    @State private var renderer: (any StandRenderer)?
    @State private var fallbackOutfits: [StandOutfit] = []
    @State private var animations: [String: Double] = [:]
    @State private var loaded = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let renderer, loaded {
                StandHostView(renderer: renderer)
                    .id(ObjectIdentifier(renderer as AnyObject))
                    .frame(
                        width: Self.stand.width,
                        height: Self.window.height
                    )
                    .offset(x: Self.stand.x - Self.window.x, y: 0)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.window.width, height: Self.window.height, alignment: .topLeading)
        .clipped()
        .offset(x: Self.window.x, y: Self.window.y)
        // 客人的立绘要到她进门之后才找得到（`her` 先到、stand 后到），换人也换一套：按根源
        // 重来，不是按视图第一次出现算一次。
        .task(id: stand?.root) {
            await load()
        }
        .onChange(of: mood) { _, _ in render() }
        .onChange(of: isSpeaking) { _, _ in render() }
    }

    /// A fresh renderer for whoever is in the window now: one that failed is not reused, and
    /// the outfit she wore last time is not kept. No stand in the content means nothing is
    /// drawn, and the bar goes on.
    private func load() async {
        renderer = nil
        loaded = false
        animations = [:]
        guard let stand, let root = stand.root else { return }
        let outfits = stand.outfitsToTry(choice: StandOutfitChoiceStore().choice(for: character.id))
        guard let worn = outfits.first else { return }
        show(worn, root: root, fallback: Array(outfits.dropFirst()))
    }

    /// Her in `outfit`. A broken outfit falls back to the next one (her default); a page that
    /// cannot draw leaves the window as it was, and the bar goes on.
    private func show(_ outfit: StandOutfit, root: URL, fallback: [StandOutfit]) {
        let made = StandWebRenderer(contentRoot: root, framing: .waist)
        // The camera needs a size: the window's, as the original draws her at.
        made.setViewportSize(CGSize(width: Self.stand.width, height: Self.window.height))
        fallbackOutfits = fallback
        made.onLoaded = { report in
            animations = report.animations
            loaded = true
            render()
        }
        made.onFailure = { failure in
            // 站不出来，酒吧照开。
            if case .outfit = failure, let next = fallbackOutfits.first {
                show(next, root: root, fallback: Array(fallbackOutfits.dropFirst()))
                return
            }
            loaded = false
        }
        renderer = made
        render()
        made.load(outfit)
    }

    private func render() {
        let direction = StandDirection(
            mood: mood, speaking: isSpeaking, looking: true, nod: nil
        )
        guard let renderer else { return }
        let pose = StandAnimator.pose(for: direction, reducedMotion: false, animations: animations)
        renderer.direct(pose)
    }
}
