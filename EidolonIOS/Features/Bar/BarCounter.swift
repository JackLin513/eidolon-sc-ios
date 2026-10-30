import EidolonCore
import Observation
import SwiftUI
import UIKit

/// What is dragged towards the shaker: a part of an ingredient off the counter, or a bottled
/// drink off the recipe book (upstream `Dragged`).
enum BarDragged: Hashable {
    case ingredient(Ingredient)
    case bottle(String)
}

/// 调酒台 (upstream `BarCounter.tsx`, the prototype's `MixStation`): the five bottles and their
/// cells, ice and ageing, the shaker with the gauge under it, and the reset and mix buttons.
/// The counter answers to the mixer's state only; what it does goes through `act`.
struct BarCounter: View {
    /// Each ingredient: its name on the counter (the original's, untranslated) and where it
    /// starts, its letter in the pictures' names, and where its bottle and its cells are.
    struct Bottle {
        var name: String
        var nameX: Double
        var letter: String
        var x: Double
        var y: Double
    }

    static let bottles: [Ingredient: Bottle] = [
        .adelhyde: Bottle(name: "Adelhyde", nameX: 405, letter: "a", x: 405, y: 140),
        .bronsonExtract: Bottle(name: "Bronson Ext", nameX: 477, letter: "b", x: 480, y: 140),
        .powderedDelta: Bottle(name: "Pwd Delta", nameX: 555, letter: "d", x: 555, y: 140),
        .flanergide: Bottle(name: "Flanergide", nameX: 405, letter: "f", x: 405, y: 200),
        .karmotrine: Bottle(name: "Karmotrine", nameX: 555, letter: "k", x: 555, y: 200),
    ]
    /// The cells of an ingredient start this far right of its bottle; ten of them, five a row.
    static let cellsDX = 23.0
    static let ice = (x: 362.0, y: 123.0, width: 33.0, height: 57.0)
    static let aged = (x: 362.0, y: 183.0, width: 33.0, height: 57.0)
    static let reset = (x: 402.0, y: 243.0, width: 71.0, height: 25.0)
    static let mix = (x: 553.0, y: 243.0, width: 71.0, height: 25.0)
    /// The shaker, where a drag lets go to put something in.
    static let shaker = (x: 477.0, y: 182.0, width: 72.0, height: 68.0)
    /// A drink made, in the shaker's place.
    static let glass = (x: 496.0, y: 190.0, width: 35.0, height: 53.0)

    /// What the screen does with what the counter asks: the state the mixer should take, and
    /// the sound to play.
    struct Actions {
        var act: (BarMixer.State, BarMixer.Action, String?, String?) -> Void
        var drinkImage: (String) -> String
        var serve: () -> Void
        var drag: BarDrag
    }

    let mixer: BarMixer.State
    let isCounterOpen: Bool
    let drinks: [Drink]
    let actions: Actions

    @State private var now: TimeInterval = 0
    @State private var float: (isMade: Bool, id: Int)?
    @State private var pulse: (letter: String, id: Int)?
    @State private var sequence = 0
    @State private var resetPressed = false

    private var stage: BarMixer.Stage { BarMixer.shakeStage(mixer, now: now) }
    private var isLive: Bool { isCounterOpen && BarMixer.isTakingIngredients(mixer) }
    private var total: Int { BarMixer.totalParts(mixer) }
    private var isMade: Bool { BarMixer.isFinished(mixer) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            iceAndAgeing
            ForEach(Ingredient.allCases, id: \.self, content: bottle)
            gauge
            shaker
            if let pulse {
                BarPulse(letter: pulse.letter).id("pulse-\(pulse.id)")
            }
            if let float {
                BarFloat(isMade: float.isMade).id("float-\(float.id)")
            }
            resetButton
            mixButtonView
            dragged
        }
        .task(id: mixer.shake == .shaking ? mixer.shakenAt : nil) {
            // 摇满 5 秒转快摇：到时候重画一次。
            guard mixer.shake == .shaking, let shakenAt = mixer.shakenAt else { return }
            now = Date().timeIntervalSince1970
            let wait = max(0, shakenAt + BarMixer.fastAfter - now)
            try? await Task.sleep(for: .seconds(wait))
            now = Date().timeIntervalSince1970
        }
    }

    // MARK: - Ice and ageing

    private var iceAndAgeing: some View {
        ZStack(alignment: .topLeading) {
            switchBox("ice", at: Self.ice, label: BarCopy.Counter.ice, isOn: mixer.ice)
            switchBox("age", at: Self.aged, label: BarCopy.Counter.aged, isOn: mixer.aged)
        }
    }

    private func switchBox(
        _ image: String, at: (x: Double, y: Double, width: Double, height: Double), label: String,
        isOn: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            BarPixelText(label, x: at.x, y: at.y + 1, width: at.width, align: .center)
            BarSprite(
                name: image, x: at.x, y: at.y, width: at.width, height: at.height,
                opacity: isOn ? 1 : 0.3
            )
            BarHitArea(
                x: at.x, y: at.y, width: at.width, height: at.height,
                label: label + (isOn ? "，开着" : "，关着")
            ) {
                let isIce = image == "ice"
                actions.act(
                    mixer, isIce ? .ice : .aged,
                    isOn ? "buttonnoclick" : (isIce ? "iceadd" : "ageadd"), "buttonnoclick"
                )
            }
        }
    }

    // MARK: - Bottles

    private func bottle(_ ingredient: Ingredient) -> some View {
        let bottle = Self.bottles[ingredient] ?? Bottle(name: "", nameX: 0, letter: "", x: 0, y: 0)
        let n = mixer.parts(ingredient)
        let isDragged = actions.drag.item == .ingredient(ingredient)
        return ZStack(alignment: .topLeading) {
            BarPixelText(bottle.name, x: bottle.nameX, y: bottle.y - 16, color: BarInk.uiText, mono: true)
            if !isDragged {
                BarSprite(
                    name: isLive ? "ing_\(bottle.letter)" : "ing_\(bottle.letter)_off",
                    x: bottle.x, y: bottle.y, width: 20, height: 38
                )
            }
            ForEach(0..<10, id: \.self) { j in
                BarSprite(
                    name: "cell_\(bottle.letter)",
                    x: bottle.x + Self.cellsDX + Double(j % 5) * 9,
                    y: bottle.y + Double(j / 5) * 18,
                    width: 8, height: 17,
                    opacity: j < min(n, 10) ? 1 : 0.3
                )
            }
            ForEach(0..<max(0, n - 10), id: \.self) { j in
                BarSprite(
                    name: "big_\(bottle.letter)",
                    x: bottle.x + Self.cellsDX + Double(j % 5) * 9,
                    y: bottle.y + Double(j / 5) * 18,
                    width: 8, height: 17
                )
            }
            Color.clear
                .frame(width: 75, height: 57)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(BarDrag.space))
                        .onChanged { value in
                            guard isLive else { return }
                            actions.drag.begin(.ingredient(ingredient), at: value.location)
                        }
                        .onEnded { value in
                            guard isLive else { return }
                            actions.drag.end(at: value.location, drop: drop)
                        }
                )
                .allowsHitTesting(isLive)
                .accessibilityElement()
                .accessibilityLabel(BarCopy.Counter.parts(bottle.name, n))
                .offset(x: bottle.x - 5, y: bottle.y - 17)
        }
    }

    private func drop(_ item: BarDragged) {
        switch item {
        case let .ingredient(ingredient):
            guard case let next = BarMixer.apply(mixer, .add(ingredient)), next != mixer else {
                actions.act(mixer, .add(ingredient), nil, "buttonnoclick")
                return
            }
            actions.act(mixer, .add(ingredient), "addingredient", "buttonnoclick")
            sequence += 1
            pulse = (Self.bottles[ingredient]?.letter ?? "", sequence)
        case let .bottle(id):
            guard let drink = drinks.first(where: { $0.id == id }) else { return }
            actions.act(mixer, .bottle(drink), "addingredient", "buttonnoclick")
        }
    }

    // MARK: - Gauge, shaker, buttons

    private var gauge: some View {
        ZStack(alignment: .topLeading) {
            BarSprite(name: "gauge", x: 478, y: 250, width: 70, height: 17)
            if stage == .still, mixer.bottle == nil {
                ForEach(0..<total, id: \.self) { i in
                    BarSprite(
                        name: i < 10 ? "gauge_on" : "gauge_big",
                        x: 486 + Double(i % 5) * 11,
                        y: 253 + Double((i / 5) % 2) * 6,
                        width: 10, height: 5
                    )
                }
            }
            if let slot = BarMixer.slotText(mixer) {
                BarPixelText(slot, x: 482, y: 251, color: BarInk.uiText, mono: true)
            }
        }
    }

    private var shaker: some View {
        ZStack(alignment: .topLeading) {
            // Where the shaker is, said for a screen reader; the picture itself is mute.
            Color.clear
                .frame(width: Self.shaker.width, height: Self.shaker.height)
                .offset(x: Self.shaker.x, y: Self.shaker.y)
                .accessibilityElement()
                .accessibilityLabel(BarCopy.Counter.shaker)
                .allowsHitTesting(false)
            if isMade {
                BarSprite(
                    name: mixer.made.map { actions.drinkImage($0.drink.id) } ?? "drink_glitch",
                    x: Self.glass.x, y: Self.glass.y, width: Self.glass.width, height: Self.glass.height
                )
                BarHitArea(
                    x: Self.shaker.x, y: Self.shaker.y, width: Self.shaker.width,
                    height: Self.shaker.height, label: BarCopy.Counter.serve,
                    action: mixButtonTapped
                )
            } else if stage == .still {
                BarSprite(
                    name: isOverShaker ? "shaker_hover" : "shaker",
                    x: Self.shaker.x, y: Self.shaker.y, width: Self.shaker.width, height: Self.shaker.height
                )
            } else {
                // 摇的时候一直在动：自己不重画，所以按帧问时间（上游是 CSS 无限循环的动画）。
                TimelineView(.periodic(from: .now, by: 1.0 / 30)) { context in
                    BarShaker(
                        name: "shaker_shake",
                        angle: .degrees(rockAngle(mixer, at: context.date.timeIntervalSince1970))
                    )
                }
            }
        }
    }

    private var isOverShaker: Bool {
        guard let point = actions.drag.point else { return false }
        return point.x >= Self.shaker.x && point.x <= Self.shaker.x + Self.shaker.width
            && point.y >= Self.shaker.y && point.y <= Self.shaker.y + Self.shaker.height
    }

    private var mixLabel: String {
        isMade ? BarCopy.Counter.serve : stage == .still ? BarCopy.Counter.mix : BarCopy.Counter.stop
    }

    private var isMixDead: Bool {
        isMade ? !BarMixer.canServe(mixer) : stage == .still && (total == 0 || !isLive)
    }

    private var resetButton: some View {
        ZStack(alignment: .topLeading) {
            BarSprite(
                name: isCounterOpen ? (resetPressed ? "reset_hover" : "reset") : "slot_out",
                x: Self.reset.x, y: Self.reset.y + (resetPressed && isCounterOpen ? 1 : 0),
                width: Self.reset.width, height: Self.reset.height
            )
            if isCounterOpen {
                BarPixelText(
                    BarCopy.Counter.reset, x: Self.reset.x, y: Self.reset.y + 4,
                    color: UIColor(BarInk.button), width: Self.reset.width, align: .center
                )
            }
            BarHitArea(
                x: Self.reset.x, y: Self.reset.y, width: Self.reset.width,
                height: Self.reset.height, label: BarCopy.Counter.reset
            ) {
                actions.act(mixer, .reset, "buttonclick", "buttonnoclick")
            }
        }
    }

    private var mixButtonView: some View {
        ZStack(alignment: .topLeading) {
            BarSprite(
                name: !isCounterOpen ? "slot_out" : isMixDead ? "mix_no" : "mix_yes",
                x: Self.mix.x, y: Self.mix.y, width: Self.mix.width, height: Self.mix.height
            )
            if isCounterOpen {
                BarPixelText(
                    mixLabel, x: Self.mix.x, y: Self.mix.y + 4, color: UIColor(BarInk.button),
                    width: Self.mix.width, align: .center
                )
            }
            BarHitArea(
                x: Self.mix.x, y: Self.mix.y, width: Self.mix.width, height: Self.mix.height,
                label: mixLabel, action: mixButtonTapped
            )
        }
    }

    /// 调制、停止、上酒，同一个按钮（点摇酒器里调好的也是上酒）。
    private func mixButtonTapped() {
        let at = Date().timeIntervalSince1970
        now = at
        if isMade {
            actions.serve()
            return
        }
        if stage == .still {
            actions.act(mixer, .shake(now: at), "mixdone", "buttonnoclick")
            return
        }
        let action = BarMixer.Action.stop(now: at, drinks: drinks, garble: BarMixer.garble())
        let next = BarMixer.apply(mixer, action)
        guard next != mixer else {
            actions.act(mixer, action, nil, "buttonnoclick")
            return
        }
        actions.act(mixer, action, "mixdone", "buttonnoclick")
        sequence += 1
        float = (next.made != nil, sequence)
    }

    /// The bottle (or bottled drink) following the finger, on top of everything.
    @ViewBuilder private var dragged: some View {
        if let drag = actions.drag.item, let point = actions.drag.point {
            switch drag {
            case let .ingredient(ingredient):
                BarSprite(
                    name: "ing_\(Self.bottles[ingredient]?.letter ?? "")_hover",
                    x: (point.x - 10).rounded(), y: (point.y - 19).rounded(), width: 20, height: 38
                )
            case let .bottle(id):
                BarSprite(
                    name: actions.drinkImage(id), x: (point.x - 17).rounded(),
                    y: (point.y - 26).rounded(), width: 35, height: 53
                )
            }
        }
    }
}

/// The splash where an ingredient lands in the shaker: it swells to 1.8× and fades out in ten
/// steps over a third of a second (upstream `bar-pulse`, scaled about the shaker's middle,
/// 36×34 of its 72×68). Drawn at the swollen size about that middle rather than scaled in place,
/// so the splash is not cut off by the shaker's own box.
private struct BarPulse: View {
    let letter: String
    @State private var step = 0
    private static let steps = 10
    private static let duration = 0.33

    var body: some View {
        let grown = 1 + 0.8 * Double(step) / Double(Self.steps)
        let width = BarCounter.shaker.width * grown
        let height = BarCounter.shaker.height * grown
        BarSprite(
            name: "pulse_\(letter)",
            x: BarCounter.shaker.x + (BarCounter.shaker.width - width) / 2,
            y: BarCounter.shaker.y + (BarCounter.shaker.height - height) / 2,
            width: width, height: height,
            opacity: 1 - Double(step) / Double(Self.steps)
        )
        .task { await play() }
    }

    private func play() async {
        for step in 1...Self.steps {
            try? await Task.sleep(for: .seconds(Self.duration / Double(Self.steps)))
            guard !Task.isCancelled else { return }
            self.step = step
        }
    }
}

/// 「成功」/「失败」 as the shaker stops: it rises forty pixels and fades out in twenty steps over
/// two thirds of a second (upstream `bar-float`). Without the rise it would sit still on top of
/// the bottles over the counter — 「失败」 reads as written across them.
private struct BarFloat: View {
    let isMade: Bool
    @State private var step = 0
    private static let steps = 20
    private static let duration = 0.67
    private static let rise = 40.0

    var body: some View {
        let fraction = Double(step) / Double(Self.steps)
        let picture = isMade
            ? (name: "success", x: 484.0, y: 166.0, width: 59.0, height: 12.0)
            : (name: "fail", x: 492.0, y: 164.0, width: 102.0, height: 15.0)
        BarSprite(
            name: picture.name, x: picture.x, y: picture.y - Self.rise * fraction,
            width: picture.width, height: picture.height, opacity: 1 - fraction
        )
        .task { await play() }
    }

    private func play() async {
        for step in 1...Self.steps {
            try? await Task.sleep(for: .seconds(Self.duration / Double(Self.steps)))
            guard !Task.isCancelled else { return }
            self.step = step
        }
    }
}

/// The shaker's turn while it is shaken: -30° to +30° and back about its middle, once every
/// 0.4 s slowly and every 0.13 s fast (upstream `bar-shake`, `bar-shake-slow`, `bar-shake-fast`).
///
/// At the thirty frames a second `TimelineView` asks for, 0.4 s comes out at twelve turns of the
/// angle and 0.13 s at four — the original's `steps(12)` and `steps(4)`.
private func rockAngle(_ mixer: BarMixer.State, at now: TimeInterval) -> Double {
    let period = BarMixer.shakeStage(mixer, now: now) == .fast ? 0.13 : 0.4
    let phase = ((now - (mixer.shakenAt ?? now)) / period).truncatingRemainder(dividingBy: 1)
    let progress = phase < 0.5 ? phase * 2 : 2 - phase * 2
    return -30 + 60 * progress
}

/// The shaker turned about its middle (upstream `transform-origin: 36px 34px`). Drawn in the box
/// the turn needs rather than clipped to the shaker's own, so the corners are not cut off.
private struct BarShaker: View {
    @Environment(\.barImages) private var images
    let name: String
    let angle: Angle

    var body: some View {
        let box = BarCounter.shaker
        let cos = abs(Foundation.cos(angle.radians))
        let sin = abs(Foundation.sin(angle.radians))
        let width = box.width * cos + box.height * sin
        let height = box.width * sin + box.height * cos
        BarPlace(
            x: box.x + (box.width - width) / 2, y: box.y + (box.height - height) / 2,
            width: width, height: height
        ) {
            if let image = images.image(name) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: box.width, height: box.height)
                    .rotationEffect(angle)
                    .frame(width: width, height: height)
            }
        }
        .allowsHitTesting(false)
    }
}

/// What is being dragged on the screen, in the 640×360 screen's own coordinates.
///
/// A drag's points come in the coordinate space it is given — the whole viewport the screen is
/// placed in (`BarRoomView` names it `space`) — so each one is read onto the screen with the
/// placement first. Read as they come, a press on the shaker's middle reads as x≈630 on a
/// landscape phone (past the screen's right edge): the bottle is drawn off to the right and the
/// drop misses the shaker.
///
/// It is the room's state, not a value carried along with the room's body: a room rebuilt by
/// the screen around it keeps its drag (and the placement `fit` gave it) instead of starting
/// again at 1× with no offset, and everything reading `item`/`point` redraws as it moves.
@Observable
@MainActor
final class BarDrag {
    /// The coordinate space a drag's points are in.
    static let space = "bar-stage"

    /// Where the screen sits in that space: what a point there is read through.
    var placement = BarScreen.Placement(scale: 1, left: 0, top: 0)

    var item: BarDragged?
    var point: CGPoint?

    func begin(_ item: BarDragged, at location: CGPoint) {
        self.item = item
        point = onScreen(location)
    }

    func end(at location: CGPoint, drop: (BarDragged) -> Void) {
        let location = onScreen(location)
        point = location
        let item = item
        self.item = nil
        point = nil
        if let item, isOverShaker(location) { drop(item) }
    }

    private func onScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: placement.screenX(point.x), y: placement.screenY(point.y))
    }

    private func isOverShaker(_ location: CGPoint) -> Bool {
        location.x >= BarCounter.shaker.x && location.x <= BarCounter.shaker.x + BarCounter.shaker.width
            && location.y >= BarCounter.shaker.y && location.y <= BarCounter.shaker.y + BarCounter.shaker.height
    }
}
