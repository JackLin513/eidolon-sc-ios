import EidolonCore
import SwiftUI
import UIKit

/// 选曲界面 (upstream `BarJukebox.tsx`, the prototype's `JukeboxSetup`): the whole 640×360 screen
/// over the bar, the boot controls after the wipe in. Five names a page on the left, twelve slots
/// in two columns of six on the right: a name goes into the first empty slot, tapping two slots
/// swaps them, a long press empties one. 「Ready!」 is green only when all twelve are filled.
struct BarJukeboxView: View {
    /// How long the wipe in takes: the controls come after it, with 「boot_up」.
    static let bootFor: TimeInterval = 1.13
    /// How long the pointer stays on a name before it plays (the original's).
    static let previewFor: TimeInterval = 2.5
    /// A slot, a name, the title box: the original's 191×25.
    static let row = (width: 191.0, height: 25.0)
    static func slotAt(_ i: Int) -> (x: Double, y: Double) {
        (i < 6 ? 225 : 425, 40 + Double(i % 6) * 30)
    }
    static let ready = (x: 358.0, y: 220.0, width: 58.0, height: 32.0)
    /// The help in the text box at the bottom left.
    static let help = (x: 26.0, width: 374.0)
    static let title = (x: 25.0, y: 38.0)

    let tracks: [BarTrack]
    let slots: [Int?]
    /// Plays a preview of a track, or stops the one playing.
    let preview: (Int?) -> Void
    let previewing: Int?
    let play: (String) -> Void
    /// Hands the choice over: the player plays it from there.
    let onReady: ([Int?]) -> Void

    @State private var isBooted = false
    @State private var choices: [Int?]
    @State private var page = 0
    @State private var picked: Int?
    @State private var halo: (slot: Int, n: Int)?
    /// The name waited on to preview, its wait shown.
    @State private var waiting: Int?
    @State private var frame = 0

    init(
        tracks: [BarTrack], slots: [Int?], previewing: Int?, preview: @escaping (Int?) -> Void,
        play: @escaping (String) -> Void, onReady: @escaping ([Int?]) -> Void
    ) {
        self.tracks = tracks
        self.slots = slots
        self.previewing = previewing
        self.preview = preview
        self.play = play
        self.onReady = onReady
        // 一进来就照上次的填好，这次选完前不再跟着存储走。
        _choices = State(initialValue: slots)
    }

    private var pages: Int { BarJukebox.pages(tracks) }
    private var isReady: Bool { BarJukebox.isReady(choices) }
    private var pageTracks: [BarTrack] { BarJukebox.page(tracks, page) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            BarSprite(name: "juke_frame", x: 0, y: 0, width: 640, height: 360)
            if !isBooted {
                BarSprite(name: "juke_startup", x: 189, y: 60, width: 263, height: 147)
            } else {
                titleBox
                names
                turnArrows
                if waiting != nil {
                    BarSprite(name: "juke_preview_\(frame % 4)", x: 235, y: 220, width: 95, height: 40)
                }
                slotsColumn
                readyButton
                BarPixelText(BarCopy.Jukebox.add, x: Self.help.x, y: 279, color: UIColor(BarInk.jukeHint))
                BarPixelText(runs: helpRuns, x: Self.help.x, y: 298)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(Self.bootFor))
            isBooted = true
            play("boot_up")
        }
        .task(id: waiting) {
            guard waiting != nil else { return }
            while !Task.isCancelled {
                frame = (frame + 1) % 4
                try? await Task.sleep(for: .seconds(0.133))
            }
        }
        .onDisappear { stopWaiting() }
    }

    /// The original lays the help out with its own measure, which keeps the browser's line breaks;
    /// the two lines are one each.
    private var helpRuns: [BarFont.Run] {
        [BarFont.Run(text: BarCopy.Jukebox.howToCoarse, color: BarInk.uiText)]
    }

    private var titleBox: some View {
        ZStack(alignment: .topLeading) {
            BarSprite(
                name: "juke_slot_blue", x: Self.title.x, y: Self.title.y,
                width: Self.row.width, height: Self.row.height
            )
            BarPixelText(
                BarCopy.Jukebox.title, x: Self.title.x, y: Self.title.y + 4,
                color: UIColor(BarInk.jukeTitle), width: Self.row.width, align: .center, mono: true
            )
        }
    }

    private var names: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(pageTracks.enumerated()), id: \.element.id) { index, track in
                let y = 78 + Double(index) * 30
                let isLit = waiting == track.id || previewing == track.id
                BarSprite(
                    name: isLit ? "juke_slot_yellow" : "juke_slot_blue", x: Self.title.x, y: y,
                    width: Self.row.width, height: Self.row.height
                )
                BarPixelText(
                    track.title, x: Self.title.x, y: y + 4, width: Self.row.width, align: .center,
                    mono: true
                )
                Color.clear
                    .frame(width: Self.row.width, height: Self.row.height)
                    .contentShape(Rectangle())
                    .onTapGesture { add(track.id) }
                    .onLongPressGesture(minimumDuration: 0.55) {
                        // 长按试听：等 2.5 秒再放，松手不放。
                        waiting = track.id
                        startPreview(track.id, after: 0.55)
                    }
                    .accessibilityElement()
                    .accessibilityLabel(track.title)
                    .offset(x: Self.title.x, y: y)
            }
        }
    }

    private var turnArrows: some View {
        ZStack(alignment: .topLeading) {
            BarSprite(
                name: "arrow", x: 0, y: 0, width: 24, height: 24, opacity: page == 0 ? 0.4 : 1,
                flipped: true
            )
            .offset(x: 26, y: 232)
            BarHitArea(x: 26, y: 232, width: 24, height: 24, label: BarCopy.Jukebox.prevPage) {
                turn(-1)
            }
            BarPixelText(
                "\(page + 1)/\(pages)", x: 95, y: 236, width: 60, align: .center, mono: true
            )
            BarSprite(
                name: "arrow", x: 0, y: 0, width: 24, height: 24,
                opacity: page == pages - 1 ? 0.4 : 1
            )
            .offset(x: 193, y: 232)
            BarHitArea(x: 193, y: 232, width: 24, height: 24, label: BarCopy.Jukebox.nextPage) {
                turn(1)
            }
        }
    }

    private var slotsColumn: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<BarJukebox.slots, id: \.self) { i in
                let at = Self.slotAt(i)
                let isPicked = picked == i
                let title = (choices[safe: i] ?? nil).flatMap(title(of:))
                ZStack(alignment: .topLeading) {
                    BarSprite(
                        name: isPicked ? "juke_slot_yellow" : "juke_slot_red", x: at.x, y: at.y,
                        width: Self.row.width, height: Self.row.height
                    )
                    BarPixelText(
                        "\(i + 1)", x: at.x + 4, y: at.y + 4,
                        color: isPicked ? UIColor(BarInk.lit) : UIColor(BarInk.jukeSlot),
                        width: 14, align: .center, mono: true
                    )
                    if let title {
                        BarPixelText(
                            title, x: at.x + 16, y: at.y + 4, width: 175, align: .center, mono: true
                        )
                    }
                    if halo?.slot == i {
                        Rectangle()
                            .strokeBorder(BarInk.text, lineWidth: 1)
                            .frame(width: Self.row.width, height: Self.row.height)
                            .id("halo-\(halo?.n ?? 0)")
                    }
                    Color.clear
                        .frame(width: Self.row.width, height: Self.row.height)
                        .contentShape(Rectangle())
                        .onTapGesture { tapSlot(i) }
                        .onLongPressGesture(minimumDuration: 0.55) { remove(i) }
                        .accessibilityElement()
                        .accessibilityLabel(BarCopy.Jukebox.slot(i + 1, title))
                        .accessibilityAddTraits(isPicked ? [.isButton, .isSelected] : .isButton)
                        .offset(x: at.x, y: at.y)
                }
            }
        }
    }

    private var readyButton: some View {
        ZStack(alignment: .topLeading) {
            BarSprite(
                name: isReady ? "juke_ready_green" : "juke_ready_red", x: Self.ready.x,
                y: Self.ready.y, width: Self.ready.width, height: Self.ready.height
            )
            BarHitArea(
                x: Self.ready.x, y: Self.ready.y, width: Self.ready.width, height: Self.ready.height,
                label: BarCopy.Jukebox.ready, action: ready
            )
        }
    }

    // MARK: - Acting

    private func title(of id: Int) -> String? {
        tracks.first { $0.id == id }?.title
    }

    private func add(_ id: Int) {
        guard !isReady else {
            play("buttonnoclick")
            return
        }
        play("jukeselect")
        let slot = choices.firstIndex { $0 == nil } ?? 0
        choices = BarJukebox.pickTrack(choices, id)
        halo = (slot, (halo?.n ?? 0) + 1)
    }

    private func tapSlot(_ i: Int) {
        guard choices[safe: i]?.flatMap({ $0 }) != nil else { return }
        guard let picked else {
            play("jukepick")
            self.picked = i
            return
        }
        play("jukechange")
        choices = BarJukebox.swapSlots(choices, picked, i)
        self.picked = nil
    }

    private func remove(_ i: Int) {
        guard choices[safe: i]?.flatMap({ $0 }) != nil else { return }
        play("prompt")
        choices = BarJukebox.clearSlot(choices, at: i)
        if picked == i { picked = nil }
    }

    private func turn(_ step: Int) {
        let to = page + step
        guard to >= 0, to < pages else {
            play("jukechange")
            return
        }
        play("jukepick")
        page = to
    }

    private func ready() {
        guard isReady else {
            play("buttonnoclick")
            return
        }
        play("mixdone")
        onReady(choices)
    }

    private func stopWaiting() {
        waiting = nil
    }

    /// Waits `after` more seconds, then previews `id`.
    private func startPreview(_ id: Int, after waited: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, Self.previewFor - waited)))
            guard waiting == id else { return }
            waiting = nil
            preview(id)
        }
    }
}

/// 店里的小播放器 (upstream `BarJukeboxPlayer`): over the logo at the top right, 188×63, the
/// buttons the original's places.
struct BarJukeboxPlayer: View {
    /// Where the original hits each button on the screen.
    static let buttons = (
        previous: (x: 446.0, y: 55.0, width: 30.0, height: 13.0),
        pause: (x: 482.0, y: 49.0, width: 17.0, height: 25.0),
        next: (x: 505.0, y: 55.0, width: 30.0, height: 13.0),
        shuffle: (x: 545.0, y: 51.0, width: 30.0, height: 21.0),
        loop: (x: 582.0, y: 54.0, width: 31.0, height: 15.0)
    )
    static let box = (x: 435.0, y: 27.0, width: 188.0, height: 63.0)

    let state: BarJukebox.State
    let title: String
    let play: (String) -> Void
    let onPrevious: () -> Void
    let onPause: () -> Void
    let onNext: () -> Void
    let onShuffle: () -> Void
    let onLoop: () -> Void

    @State private var flash: (which: String, n: Int)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            BarSprite(
                name: state.isPaused ? "juke_small_paused" : "juke_small_playing", x: Self.box.x,
                y: Self.box.y, width: Self.box.width, height: Self.box.height
            )
            if state.mode == .shuffle {
                BarSprite(name: "juke_shuffle", x: 438, y: 29, width: Self.box.width, height: Self.box.height)
            }
            if state.mode == .loop {
                BarSprite(name: "juke_loop", x: 438, y: 29, width: Self.box.width, height: Self.box.height)
            }
            if let flash {
                BarSprite(
                    name: "juke_\(flash.which)", x: 439, y: 29, width: Self.box.width,
                    height: Self.box.height
                )
                .id("flash-\(flash.n)")
            }
            BarPixelText(title, x: 442, y: 70, color: BarInk.uiSub, mono: true)
            BarPixelText(title, x: 442, y: 69, color: BarInk.uiText, mono: true)
            hit(BarCopy.Jukebox.Player.previous, Self.buttons.previous) {
                flash = ("back", (flash?.n ?? 0) + 1)
                onPrevious()
            }
            hit(state.isPaused ? BarCopy.Jukebox.Player.play : BarCopy.Jukebox.Player.pause, Self.buttons.pause, onPause)
            hit(BarCopy.Jukebox.Player.next, Self.buttons.next) {
                flash = ("next", (flash?.n ?? 0) + 1)
                onNext()
            }
            hit(
                BarCopy.Jukebox.Player.shuffle, Self.buttons.shuffle, onShuffle,
                pressed: state.mode == .shuffle
            )
            hit(BarCopy.Jukebox.Player.loop, Self.buttons.loop, onLoop, pressed: state.mode == .loop)
        }
    }

    private func hit(
        _ label: String, _ at: (x: Double, y: Double, width: Double, height: Double),
        _ action: @escaping () -> Void, pressed: Bool = false
    ) -> some View {
        BarHitArea(x: at.x, y: at.y, width: at.width, height: at.height, label: label) {
            play("buttonclick")
            action()
        }
    }
}

extension Array {
    /// The element at `index`, if there is one.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
