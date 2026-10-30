import EidolonCore
import Combine
import SwiftUI

/// Whether the side menu's 「点唱机」 is open (lit), closed, or grey for want of a package's sound.
enum JukeboxCell {
    case open, closed, none
}

/// The bar's side menu (upstream `BarScreen.tsx` `SideMenu`): 「设置」 and, under it, 「点唱机」
/// (or 「跳过」 through the tutorial) and 「离开」, in the original's places, each a 72×20 cell
/// with its word 5 px in. A cell with nothing to do is grey and takes no tap.
struct BarSideMenu: View {
    /// The menu's cells, top left corner each: the original's `MENU_CELLS`.
    static let cells = (
        settings: (x: 445.0, y: 279.0),
        fullscreen: (x: 543.0, y: 279.0),
        jukebox: (x: 445.0, y: 312.0),
        leave: (x: 543.0, y: 312.0)
    )
    static let cell = (width: 72.0, height: 20.0)

    struct Cell {
        var label: String
        var color: Color = BarInk.text
        var pressed = false
        var action: (() -> Void)?
    }

    var settings: Cell?
    var jukebox: Cell?
    var leave: Cell

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let settings {
                item(settings, at: Self.cells.settings)
            }
            if let jukebox {
                item(jukebox, at: Self.cells.jukebox)
            }
            item(leave, at: Self.cells.leave)
        }
    }

    /// 「点唱机」 in the side menu: lit while the small player is open, grey with no audio.
    static func jukeboxCell(_ state: JukeboxCell, onToggle: @escaping () -> Void) -> Cell {
        return Cell(
            label: BarCopy.Jukebox.name,
            color: state == .open ? BarInk.lit : state == .closed ? BarInk.text : BarInk.off,
            pressed: state == .open,
            action: state == .none ? nil : onToggle
        )
    }

    private func item(_ cell: Cell, at place: (x: Double, y: Double)) -> some View {
        ZStack(alignment: .topLeading) {
            BarPixelText(cell.label, x: place.x + 5, y: place.y + 1, color: UIColor(cell.color))
            if let action = cell.action {
                BarHitArea(
                    x: place.x, y: place.y, width: Self.cell.width, height: Self.cell.height,
                    label: cell.label, action: action
                )
            }
        }
    }
}

/// 店门口 (upstream `BarDoor.tsx`): the original's intro screen, the 「VA-283」 sign blinking on
/// it, the notice under it and a tap anywhere to come in.
struct BarDoor: View {
    @Environment(\.barImages) private var images
    let notice: String?
    let isEntering: Bool
    /// Whether 「教程」 is offered beside the door's row.
    let onTutorial: (() -> Void)?
    let onEnter: () -> Void

    /// The sign over the door: the art's own neon is a parallelogram — its top edge sits four
    /// pixels higher on the right — and the box drawn over it while it blinks takes the same
    /// corners, so the two line up.
    static let sign = (
        x: 293.0, y: 30.0, width: 51.0, height: 28.0, lift: 4.0,
        corners: [
            CGPoint(x: 293, y: 34), CGPoint(x: 344, y: 30),
            CGPoint(x: 344, y: 54), CGPoint(x: 293, y: 58),
        ]
    )
    static let noticeY = 290.0
    /// Where 「教程」 sits: one cell left of where 「全屏」 would have been, on the bottom row
    /// (`fullscreenAt[0] - CELL.width`, `ROW_Y`). There is no 「全屏」 on iOS, so it is one left
    /// of 「离开」.
    static let tutorial = (
        x: BarSideMenu.cells.fullscreen.x - BarSideMenu.cell.width, y: BarSideMenu.cells.leave.y
    )

    @State private var frame = 0
    private let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 门口的图和店里一样从底上一层盖上（上游 `inset-0` 的黑底）：`intro_n` 四周是透明的。
            Rectangle()
                .fill(BarInk.black)
                .frame(width: Double(BarScreen.width), height: Double(BarScreen.height))
            BarSprite(name: "intro_\(frame)", x: 0, y: 0, width: 640, height: 360)
            Path { path in
                path.move(to: Self.sign.corners[0])
                for corner in Self.sign.corners.dropFirst() { path.addLine(to: corner) }
                path.closeSubpath()
            }
            .fill(frame == 0 ? BarInk.pink : BarInk.pinkDim)
            BarPixelText(
                "VA-283", x: Self.sign.x, y: Self.sign.y + 8, color: BarInk.uiText,
                width: Self.sign.width, align: .center
            )
            if !isEntering {
                BarPixelText(
                    notice ?? BarCopy.Door.enter, x: 0, y: Self.noticeY,
                    color: notice == nil ? BarInk.uiSub : BarInk.uiText,
                    width: Double(BarScreen.width), align: .center
                )
            }
            BarHitArea(
                x: 0, y: 0, width: Double(BarScreen.width), height: Double(BarScreen.height),
                label: BarCopy.Door.enter, action: onEnter
            )
            if let onTutorial, !isEntering {
                BarPixelText(
                    BarCopy.Door.tutorial,
                    x: Self.tutorial.x + 5, y: Self.tutorial.y + 1,
                    color: BarInk.uiText
                )
                BarHitArea(
                    x: Self.tutorial.x, y: Self.tutorial.y,
                    width: BarSideMenu.cell.width, height: BarSideMenu.cell.height,
                    label: BarCopy.Door.tutorial, action: onTutorial
                )
            }
        }
        .onReceive(timer) { _ in
            // 招牌的霓虹灯：每 120 ms 跳一下，偶尔连跳到下一帧。
            frame = Double.random(in: 0..<1) < 0.15 ? (frame + 1) % 3 : 0
        }
    }
}

/// 结束卡 (upstream `BarEndCard.tsx`, the prototype's `EndPanel`): what the day's first visit
/// got, or only that she left, and the card's two buttons.
struct BarEndCard: View {
    let affinityUp: Bool
    let herName: String?
    let herColor: Color
    let onAgain: () -> Void
    let onLeave: () -> Void

    static let card = (x: 220.0, y: 118.0, width: 200.0, height: 116.0)
    static let oneRowY = 150.0
    static let buttons = (y: 196.0, again: 236.0, leave: 332.0)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(BarInk.veil)
                .frame(width: Double(BarScreen.width), height: Double(BarScreen.height))
            Rectangle()
                .fill(BarInk.black)
                .frame(width: Self.card.width, height: Self.card.height)
                .offset(x: Self.card.x, y: Self.card.y)
            Rectangle()
                .strokeBorder(BarInk.pink, lineWidth: 1)
                .frame(width: Self.card.width, height: Self.card.height)
                .offset(x: Self.card.x, y: Self.card.y)
            centered
            BarButton(x: Self.buttons.again, y: Self.buttons.y, label: BarCopy.End.again, action: onAgain)
            BarButton(x: Self.buttons.leave, y: Self.buttons.y, label: BarCopy.leave, action: onLeave)
        }
    }

    @ViewBuilder private var centered: some View {
        if !affinityUp {
            BarPixelText(
                BarCopy.End.left(herName), x: Self.card.x, y: Self.oneRowY, color: BarInk.uiSub,
                width: Self.card.width, align: .center
            )
        } else {
            BarPixelText(
                runs: [
                    BarFont.Run(text: BarCopy.End.heart, color: UIColor(herColor)),
                    BarFont.Run(text: BarCopy.End.affinityUp, color: BarInk.uiText),
                ],
                x: Self.card.x, y: Self.oneRowY, width: Self.card.width, align: .center
            )
        }
    }

}

/// 竖屏时的提醒盖住整层 (upstream `PortraitGuard.tsx`): no 「全屏横过来」 button on iOS.
struct BarPortraitGuard: View {
    var body: some View {
        ZStack {
            BarInk.black
            Text(BarCopy.portrait)
                .font(.title3)
                .foregroundStyle(BarInk.sub)
        }
        .ignoresSafeArea()
    }
}
