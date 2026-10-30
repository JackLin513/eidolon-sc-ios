import EidolonCore
import Foundation
import SwiftUI

/// 酒吧 (ADR-0021; upstream `/play/bar`): one visit at the bar, on the 640×360 screen the
/// original draws. Tapping the door comes in; her lines come into the text box; when she
/// orders, the bar counter and the recipe book open; what is served is sent, and her farewell
/// ends the visit at the end card. 点唱机, 设置 and the tutorial are the side menu's.
///
/// The tutorial walks the same screen over `BarTutorial`, fed a tap at a time and sending
/// nothing; everything else over `BarRoom`, whose call's events come in as they are written.
struct BarRoomView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.barOrientation) private var barOrientation

    /// The block the screen is fitted into, and where it lands in it. Kept in a reference box:
    /// a `@State` pair written from the geometry reader would be one change too many while the
    /// screen is being laid out.
    /// Whether 「请横过来」 is up. It follows the geometry with a moment's delay: the page asks
    /// for landscape on its way in, so a phone held upright is upright for a frame or two, and
    /// the guard would flash over the picture each time. Written from the layout callbacks,
    /// after the size is known, so it does not feed back into the layout.
    @State private var showsGuard = false
    @State private var guardTask: Task<Void, Never>?
    @State private var placement = BarScreen.placement(
        BarScreen.Viewport(width: 1, height: 1, pointer: .coarse)
    )
    @State private var isLoaded = false
    @State private var images = BarImages.none
    @State private var sound: BarSound?
    @State private var settings: BarSettings.Stored
    @State private var jukebox = BarJukebox.State(slots: [])
    @State private var tutorialWalked = true
    @State private var drinks: [Drink] = []

    /// The visit's own state, and the tutorial's while it walks.
    @State private var visit = BarVisitState()
    @State private var tutorial: BarTutorial?
    /// When the player last did something here, for the 30 minutes a visit survives in the
    /// background (ADR-0021: 切后台不算离开，超过 30 分钟才算).
    @State private var lastActionAt = Date().timeIntervalSince1970
    @State private var call: BarCall?
    @State private var callTask: Task<Void, Never>?

    @State private var isSettingsOpen = false
    @State private var isJukeboxOpen = false
    @State private var isChoosingTracks = false
    /// What the door says when coming in did not work.
    @State private var notice: String?
    @State private var error: String?
    @State private var her: CharacterConfig?
    @State private var stand: CharacterStand?
    @State private var now: TimeInterval = Date().timeIntervalSince1970
    @State private var ticking = false

    /// What is being dragged off the counter or the recipe book. `@State`, not a plain `let`:
    /// the screen is rebuilt whenever what is around it changes, and a drag made anew each time
    /// would forget the placement `fit` read and lose the bottle mid-drag.
    @State private var drag = BarDrag()

    @Environment(\.dismiss) private var dismiss

    init(settings: BarSettings.Stored, jukebox: BarJukebox.State, tutorialWalked: Bool) {
        _settings = State(initialValue: settings)
        _jukebox = State(initialValue: jukebox)
        _tutorialWalked = State(initialValue: tutorialWalked)
    }

    var body: some View {
        // 这一层整个铺到窗口上：`.ignoresSafeArea()` 把扩展后的尺寸作为 proposal 传下来，
        // 里面的 `GeometryReader` 量到的就是整个窗口——它的尺寸来自 proposal、不随内容
        // 变化，所以不会再出现「量出来的数越推越大」；它的左上角也就是窗口的左上角，
        // 不需要任何安全区或窗口边界的补偿。
        ZStack(alignment: .topLeading) {
            BarInk.ground
            if isLoaded {
                GeometryReader { proxy in
                    BarStage(placement: Self.placed(in: proxy.size)) {
                        screen
                    }
                    .layoutPriority(-1)
                    .environment(\.barImages, images)
                    .coordinateSpace(name: BarDrag.space)
                    .frame(
                        width: proxy.size.width, height: proxy.size.height,
                        alignment: .topLeading
                    )
                    .onAppear { adopt(proxy.size) }
                    .onChange(of: proxy.size) { _, size in adopt(size) }
                    .overlay {
                        if showsGuard { BarPortraitGuard() }
                    }
                }
            } else {
                ProgressView().tint(BarInk.sub)
            }
        }
        .ignoresSafeArea()
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .task {
            barOrientation.landscape()
            await load()
            await tick()
        }
        .onDisappear {
            // 页面不在了：这一趟就算走了，手机也转回去。
            left()
            voidVisit()
            sound?.stop()
            barOrientation.portrait()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                sound?.playersResume()
                resumed()
            case .background:
                // 切后台、锁屏不算离开：音乐停下，光顾留着。正在写的那次调用会被系统
                // 掐断，按这次调用失败留下（ADR-0021）。
                sound?.playersPause()
                backgrounded()
            default:
                sound?.playersPause()
            }
        }
        .onChange(of: isSettingsShown) { _, isShown in
            // 走到门口或到了结尾卡，设置自己关上（上游同一句）。
            if !isShown { isSettingsOpen = false }
        }
    }

    /// The page is the whole window, so the picture is placed from its size alone: the largest
    /// scale that fits, centred, which in landscape fills the height and letterboxes the sides.
    /// The drag reads its points through the same placement.
    private func adopt(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        adoptGuard(isUpright: size.height > size.width)
        let placed = Self.placed(in: size)
        if placement != placed { placement = placed }
        drag.placement = placed
    }

    /// The guard goes up only once the phone has stayed upright for a while, and comes down at
    /// once when it turns: on the way in the page is portrait for a frame or two before the
    /// rotation it asked for lands.
    private func adoptGuard(isUpright: Bool) {
        guard isUpright != (guardTask != nil || showsGuard) else { return }
        guardTask?.cancel()
        guardTask = nil
        if !isUpright {
            showsGuard = false
            return
        }
        guardTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            showsGuard = true
            guardTask = nil
        }
    }

    private static func placed(in size: CGSize) -> BarScreen.Placement {
        BarScreen.placement(BarScreen.Viewport(
            width: Double(size.width), height: Double(size.height), pointer: .coarse
        ))
    }

    // MARK: - The screen

    /// The original's layers, bottom to top (`BarScreen.tsx`): the room, her, the recipe book,
    /// the frame picture, then what sits in it — the door or the counter and the text box, the
    /// side menu, the small player, the settings box, the end card, the jukebox setup — and the
    /// scanlines over all of it. The frame is opaque: anything drawn before it is hidden.
    @ViewBuilder private var screen: some View {
        BarRoomBackground()
        if let her, isInside, !isChoosingTracks {
            BarGuest(
                character: her, stand: stand, mood: mood,
                isSpeaking: isSpeaking
            )
            .opacity(1)
        }
        if scene.isMixing {
            recipeBook
        }
        BarSprite(name: "frame", x: 0, y: 0, width: 640, height: 360)
        if isInside {
            counterView
            textBox
        } else {
            BarDoor(
                notice: notice,
                isEntering: scene.isEntering,
                onTutorial: app.characters.isEmpty ? nil : { startTutorial() },
                onEnter: { enter() }
            )
        }
        sideMenu
        player
        if isSettingsShown {
            settingsBox
        }
        if scene.endCard {
            endCard
        }
        if isChoosingTracks {
            jukeboxSetup
        }
        if settings.scanlines {
            BarSprite(name: "scanlines", x: 0, y: 0, width: 640, height: 360)
        }
        if let message = error {
            errorBox(message)
        }
    }

    /// What went wrong, said in the text box's place; tapped away.
    private func errorBox(_ message: String) -> some View {
        let page = BarTextPage(rows: [BarTextRow(name: nil, text: message, subtitle: true)])
        return BarTextBox(
            text: page,
            speaker: BarLine.Speaker.producer,
            herColor: herColor,
            isArrowShown: false,
            memo: nil,
            failure: nil,
            onTap: { dismissError() }
        )
    }

    private func dismissError() {
        error = nil
    }

    /// 菜谱, over her window but under the frame's counter side (upstream `book`, drawn inside).
    private var recipeBook: some View {
        BarRecipeBookView(
            drinks: drinks,
            isCounterOpen: scene.isCounterOpen,
            drag: drag,
            put: { put($0) },
            play: { play($0) },
            onPage: { _ in play("jukepick") }
        )
    }

    /// 调酒台: drawn the whole time we are inside; it answers taps only once the counter opens
    /// (`isLive`, and `counter(_:)` here).
    private var counterView: some View {
        BarCounter(
            mixer: scene.mixer,
            isCounterOpen: scene.isCounterOpen,
            drinks: drinks,
            actions: counterActions
        )
    }

    @ViewBuilder private var textBox: some View {
        BarTextBox(
            text: typedPage,
            speaker: scene.shown?.page.line.speaker ?? .producer,
            herColor: herColor,
            isArrowShown: scene.isArrowShown(now),
            memo: scene.isMixing ? scene.memo : nil,
            failure: failureBox,
            onTap: { tap() }
        )
    }

    @ViewBuilder private var endCard: some View {
        BarEndCard(
            affinityUp: scene.reward?.affinityUp ?? false,
            herName: her?.name,
            herColor: herColor,
            onAgain: { again() },
            onLeave: { exitBar() }
        )
    }

    /// 店里的小播放器, over the logo at the top right (upstream: `isInside && !isTutorial &&
    /// jukebox.isOpen`).
    @ViewBuilder private var player: some View {
        if isInside, !isTutorial, let sound, sound.hasJukebox, isJukeboxOpen {
            BarJukeboxPlayer(
                state: sound.state,
                title: sound.title,
                play: { play($0) },
                onPrevious: { sound.previous() },
                onPause: { sound.togglePause() },
                onNext: { sound.next() },
                onShuffle: { sound.changeMode(.shuffle) },
                onLoop: { sound.changeMode(.loop) }
            )
        }
    }

    private var settingsBox: some View {
        BarSettingsBox(
            settings: settings,
            hasAudio: sound?.hasJukebox ?? false,
            play: { play($0) },
            onChange: { next in
                settings = next
                sound?.settings = next
                sound?.applyVolume()
                Task { await app.saveBarSettings(BarSettings(stored: next)) }
            },
            onClose: { isSettingsOpen = false }
        )
    }

    /// 侧边菜单: 「设置」 only inside; 「点唱机」是照原样随时给格子，店门口不给。教程里那一格是
    /// 「跳过」。
    private var sideMenu: some View {
        BarSideMenu(
            settings: isInside
                ? BarSideMenu.Cell(
                    label: BarCopy.Settings.name, pressed: isSettingsShown
                ) { isSettingsOpen.toggle() }
                : nil,
            jukebox: jukeboxCell,
            leave: BarSideMenu.Cell(label: BarCopy.leave) { exitBar() }
        )
    }

    private var jukeboxCell: BarSideMenu.Cell? {
        if isTutorial {
            return BarSideMenu.Cell(label: BarCopy.skip) { skipTutorial() }
        }
        guard isInside else { return nil }
        guard let sound, sound.hasJukebox else { return BarSideMenu.jukeboxCell(.none) {} }
        return BarSideMenu.jukeboxCell(isJukeboxOpen ? .open : .closed) {
            isJukeboxOpen.toggle()
            play("buttonclick")
        }
    }

    @ViewBuilder private var jukeboxSetup: some View {
        if let sound {
            BarJukeboxView(
                tracks: sound.audio.tracks,
                slots: jukebox.slots,
                previewing: sound.previewing,
                preview: { sound.hear($0) },
                play: { play($0) },
                onReady: { slots in
                    // 选完就是店门口: the tutorial that sent the player here is already over,
                    // so closing the setup shows the door (upstream: Ready! → the door).
                    isChoosingTracks = false
                    if slots == jukebox.slots {
                        sound.pick(jukebox.slots)
                    } else {
                        sound.pick(slots)
                        jukebox = sound.state
                        Task { await app.saveBarJukebox(sound.state) }
                    }
                }
            )
        }
    }

    // MARK: - The visit's state

    private enum Stage {
        case door, visit
    }

    private var stage: Stage { scene.visit == nil && !isTutorial ? .door : .visit }

    /// 在店里: the tutorial counts as inside from its first tap (upstream
    /// `isInside = isTutorial || stage === "visit" || stage === "next"`).
    private var isInside: Bool { stage == .visit }

    /// 设置 opens only inside, and closes itself at the end card (upstream
    /// `isSettingsShown = isSettingsOpen && isInside && !card`).
    private var isSettingsShown: Bool { isSettingsOpen && isInside && !scene.endCard }

    private var isTutorial: Bool { tutorial != nil }

    /// What the screen draws: the tutorial's while it walks, the visit's otherwise.
    private var scene: Scene {
        if let tutorial { return Scene(tutorial.screen) }
        return Scene(visit)
    }

    /// The visit's state or the tutorial's screen, as the screen reads it.
    @MainActor
    private struct Scene {
        var shown: BarVisitScreen.ShownPage?
        var queue: [BarVisitScreen.LinePage]
        var isAwaitingLine: Bool
        var isMixing: Bool
        var memo: String?
        var failure: String?
        var isRetrying: Bool
        var mixer: BarMixer.State
        var visit: BarVisitScreen.Visit?
        var reward: Reward?
        var endCard: Bool
        var isCounterOpen: Bool
        var mood: StandEmotion
        /// 进来中: the door was tapped and her call has not said she is in yet.
        var isEntering: Bool

        init(_ state: BarVisitState) {
            shown = state.shown
            queue = state.queue
            isAwaitingLine = state.isAwaitingLine
            isMixing = state.isMixing
            memo = state.memo
            failure = state.failure
            isRetrying = state.isRetrying
            mixer = state.mixer
            visit = state.visit
            reward = state.reward
            endCard = state.endCard
            isCounterOpen = state.isCounterOpen
            mood = state.mood
            isEntering = state.stage == .entering
        }

        init(_ screen: BarVisitScreen) {
            shown = screen.shown
            queue = screen.queue
            isAwaitingLine = screen.isAwaitingLine
            isMixing = screen.isMixing
            memo = screen.memo
            failure = nil
            isRetrying = false
            mixer = screen.mixer
            visit = screen.visit
            reward = nil
            endCard = false
            isCounterOpen = screen.isMixing
            mood = screen.mood
            isEntering = false
        }

        func isArrowShown(_ now: TimeInterval) -> Bool {
            guard let shown else { return false }
            return !isAwaitingLine && !isMixing && failure == nil
                && BarText.isTypedOut(shown.page.page, shown.typing, now: now)
        }
    }

    private var failureBox: (message: String, isRetrying: Bool, retry: () -> Void)? {
        guard let message = scene.failure else { return nil }
        let isRetrying = scene.isRetrying
        return (message: message, isRetrying: isRetrying, retry: { retryAgain() })
    }

    private var typedPage: BarTextPage? {
        guard let shown = scene.shown else { return nil }
        let typed = BarText.typedChars(shown.page.page, shown.typing, now: now)
        return BarTextPage(rows: BarText.shownRows(shown.page.page, typed: typed))
    }

    private var isSpeaking: Bool {
        guard let shown = scene.shown, shown.page.line.speaker == .her else { return false }
        return !BarText.isTypedOut(shown.page.page, shown.typing, now: now)
    }

    private var mood: StandEmotion { scene.mood }

    private var herColor: Color {
        her?.color.map { Color(hex: $0) } ?? BarInk.text
    }

    // MARK: - The counter and the book

    private var counterActions: BarCounter.Actions {
        BarCounter.Actions(
            act: { _, action, _, _ in counter(action) },
            drinkImage: { BarDrinkSprites.name($0) },
            serve: { serve() },
            put: { put($0) },
            drag: drag
        )
    }

    /// 拖到摇酒器上松手：配料加一份，瓶装饮料放进去就算做好了。配方书里的瓶子和调酒台
    /// 上的配料都走这一个入口——早先配方书那头传的是空回调，瓶装单根本交不上去。
    private func put(_ item: BarDragged) {
        guard scene.isCounterOpen else { return }
        switch item {
        case let .ingredient(ingredient):
            counter(.add(ingredient))
        case let .bottle(id):
            guard let drink = drinks.first(where: { $0.id == id }) else { return }
            counter(.bottle(drink))
        }
    }

    private func counter(_ action: BarMixer.Action) {
        // 台子一直画着，只有开了才认点击（上游把它整个交给 `isCounterOpen`）。
        guard scene.isCounterOpen, let sound else { return }
        if isTutorial {
            guard let tutorial else { return }
            self.tutorial = tutorial.applying(.mix(action))
            sound.play(effect(of: action))
            return
        }
        visit.mix(action)
        sound.play(effect(of: action))
    }

    private func effect(of action: BarMixer.Action) -> String {
        switch action {
        case .add: return "addingredient"
        case .remove: return "removingredient"
        case .ice: return "iceadd"
        case .aged: return "ageadd"
        case .shake: return "shaking"
        case .stop: return "mixdone"
        case .reset: return "emptyshaker"
        case .bottle: return "addingredient"
        case let .broken(garble): return garble
        }
    }

    private func serve() {
        if let tutorial {
            self.tutorial = tutorial.applying(.serve(now: now))
            if let shown = tutorial.screen.shown {
                play(shown.page.line.speaker == .her ? "bleep_high" : "bleep_low")
            }
            return
        }
        guard let setup = app.barSetup, let served = visit.serve() else { return }
        visit.beginCall()
        Task {
            do {
                let room = await app.barRoom()
                // 这一趟的调用要接着读：不读，事件没人收，框就一直等下一句；调用本身也会
                // 在被丢掉的那一刻取消（上游 `runCall` 分开处理「受理了」和「送来事件」）。
                let call = try await room.serve(served, setup: setup)
                visit.served()
                play("glassserve")
                read(call)
            } catch {
                visit.served()
                self.error = error.localizedDescription
            }
        }
    }

    /// 「再试一次」 at the text box: the failed call made again, the scene kept (upstream
    /// `retry` / `retried` — what the failed call wrote is dropped once the new one is taken).
    private func retryAgain() {
        lastActionAt = now
        guard !isTutorial, !visit.isRetrying, let setup = app.barSetup else { return }
        visit.isRetrying = true
        Task {
            do {
                let room = await app.barRoom()
                let call = try await room.retry(setup)
                visit.retried()
                read(call)
            } catch {
                visit.isRetrying = false
                visit.failure = error.localizedDescription
            }
        }
    }

    // MARK: - The visit

    /// The text box tapped.
    private func tap() {
        lastActionAt = now
        if isTutorial {
            guard let tutorial else { return }
            let before = tutorial.screen.shown?.page.line
            self.tutorial = tutorial.applying(.tap(now: now))
            if let line = tutorial.screen.shown?.page.line, line != before {
                play(line.speaker == .her ? "bleep_high" : "bleep_low")
            }
            if tutorial.screen.isMixing, !tutorialWasMixing(before) { play("boot_up") }
            if let end = tutorial.end { endTutorial(end) }
            return
        }
        let wasTyped = typedPage != nil && scene.isArrowShown(now)
        visit.tap(now: now)
        if wasTyped, let shown = visit.shown {
            play(shown.page.line.speaker == .her ? "bleep_high" : "bleep_low")
        }
        if visit.isMixing, !scene.isMixing { play("boot_up") }
    }

    /// Whether the tutorial was opening the counter before the tap being handled.
    private func tutorialWasMixing(_ before: BarTextLine?) -> Bool { before == nil }

    /// 「跳过」: the tutorial ended at once, to where it says it ends — the jukebox setup
    /// with audio to choose for, the door without (upstream `useBarTutorial`'s `skip` and
    /// `barTutorial.ts`). Asking the tutorial, not the button, keeps the two in step.
    private func skipTutorial() {
        guard let end = tutorial?.applying(.skip).end else { return }
        endTutorial(end)
    }

    /// The door tapped: in, unless the visit is already coming in (upstream `useBarVisit`'s
    /// `enter`, which only acts at the door).
    private func enter() {
        lastActionAt = now
        guard !scene.isEntering else { return }
        guard tutorialWalked else {
            startTutorial()
            return
        }
        comeIn()
    }

    /// A visit begun (upstream `comeIn`): the door says it is coming in straight away, and the
    /// visit's call is followed. Refused, the door says why and the visit is not begun.
    private func comeIn() {
        guard let setup = app.barSetup else {
            notice = BarCopy.Door.failed
            play("buttonnoclick")
            return
        }
        notice = nil
        play("door")
        visit.begin()
        Task {
            do {
                let room = await app.barRoom()
                read(try await room.enter(setup))
            } catch {
                visit.reset()
                notice = error.localizedDescription
                play("buttonnoclick")
            }
        }
    }

    /// Reads a call's events as they come into the visit.
    private func read(_ call: BarCall) {
        left()
        self.call = call
        visit.beginCall()
        callTask = Task { @MainActor in
            do {
                for try await event in call {
                    now = Date().timeIntervalSince1970
                    if case let .visit(_, characterID) = event {
                        await arriving(characterID)
                    }
                    visit.received(event, now: now)
                }
            } catch {
                // 页面走了取消的这次调用不算失败：光顾已经由 `left()` 说过。
                guard !Task.isCancelled else { return }
                visit.isRetrying = false
                visit.failure = error.localizedDescription
            }
        }
    }

    /// She is in: her stand and name, before her first line is drawn.
    private func arriving(_ characterID: String) async {
        guard her?.id != characterID else { return }
        guard let character = app.characters.first(where: { $0.id == characterID }) else { return }
        her = character
        visit.names = BarTextNames(her: character.name)
        await loadStand(for: character)
    }

    private func loadStand(for character: CharacterConfig) async {
        guard let found = await app.core.stand(for: character.id) else {
            stand = nil
            return
        }
        stand = found
    }

    /// 「再营业」 on the end card: the next guest comes in from the door (upstream `again`).
    private func again() {
        lastActionAt = now
        left()
        sound?.stopPreview()
        comeIn()
    }

    /// 离开: the visit is over and the page goes back to the roster (upstream `leaveBar`:
    /// `leave()` 之后 `router.push(playHref())` —— 只清光顾、不退页面，人就困在酒吧里了).
    private func exitBar() {
        leaveBar()
        dismiss()
    }

    private func leaveBar() {
        left()
        voidVisit()
        visit.end()
        visit.clearVisit()
        her = nil
        stand = nil
        isJukeboxOpen = false
        notice = nil
    }

    /// Back on screen: a visit left for more than 30 minutes is over (ADR-0021); a shorter
    /// stay in the background keeps it, and a call the system cut off shows as failed, to be
    /// tried again.
    private func resumed() {
        guard stage != .door, !isTutorial else { return }
        now = Date().timeIntervalSince1970
        guard now - lastActionAt > BarRules.idle else { return }
        leaveBar()
        notice = BarCopy.awayGone
    }

    /// The app goes under while a call is being made: the system cuts it off. The visit stops
    /// before that call and is kept, to be tried again when the player comes back (ADR-0021:
    /// 切后台不算离开). A call already finished — she waits for her drink — has nothing to cut
    /// off, and the visit goes on as it was, with no failure on screen.
    private func backgrounded() {
        guard call != nil, !isTutorial else { return }
        Task {
            let cut = await app.barRoom().cutOff()
            left()
            guard cut else { return }
            visit.isRetrying = false
            visit.failure = BarVisitState.failed
        }
    }

    /// The page is gone, or the visit over as far as calls go: the visit is left while her
    /// lines are still being written.
    private func left() {
        callTask?.cancel()
        callTask = nil
        call?.left()
        call = nil
    }

    /// 页面离开而这次光顾还停在等上酒：没有在写的调用，告诉酒吧这一趟走了（上游
    /// `DELETE /api/bar/visits/{id}`）。有调用时它的 `left()` 已经说过。
    private func voidVisit() {
        guard call == nil, !isTutorial, visit.isInside, visit.visit != nil else { return }
        Task { try? await app.barRoom().leave() }
    }

    // MARK: - The tutorial

    private func startTutorial() {
        guard let character = app.characters.first else {
            notice = "内容包里还没有角色。"
            return
        }
        her = character
        play("door")
        let names = BarTextNames(her: character.name)
        let hasJukebox = sound?.hasJukebox ?? false
        let now = Date().timeIntervalSince1970
        tutorial = BarTutorial.begin(
            characterID: character.id,
            hasJukebox: hasJukebox,
            layout: { BarText.paginate($0, names: names) { Int(images.face.width($0)) } },
            now: now
        )
        Task { await loadStand(for: character) }
    }

    private func endTutorial(_ end: BarTutorial.End) {
        tutorial = nil
        Task { await app.markBarTutorialWalked() }
        tutorialWalked = true
        // 教程里的她不是来光顾的: whoever a visit brings comes in again at the door.
        her = nil
        stand = nil
        if end == .jukebox, sound?.hasJukebox ?? false {
            isChoosingTracks = true
            return
        }
        leaveBar()
    }

    // MARK: - Loading

    private func load() async {
        guard !isLoaded else { return }
        await app.loadBar()
        settings = BarSettings.stored(app.barSettingsValue)
        jukebox = app.barJukeboxState
        tutorialWalked = app.barTutorialDone
        images = app.barPackage.map { BarImages(directory: $0.directory) } ?? .none
        visit.face = images.face
        let catalog = (try? BarAudioCatalog.read(in: app.core.location.contentDirectory)) ?? nil
        let made = BarSound(state: jukebox, settings: settings)
        made.onTrackEnded = { made.next() }
        made.load(app.barAudio, catalog: catalog, in: app.barPackage?.directory)
        sound = made
        drinks = (try? await app.barRoom().status())?.drinks ?? []
        isLoaded = true
        // 上一次没走完的那趟：接着看。
        if let underWay = try? await app.barRoom().catchUp() {
            await resume(underWay)
        }
    }

    private func resume(_ underWay: BarVisit) async {
        her = underWay.character
        visit.names = BarTextNames(her: underWay.character.name)
        visit.visit = BarVisitScreen.Visit(id: underWay.id, characterID: underWay.character.id)
        visit.mood = underWay.written.last?.lines.last?.emotion ?? .calm
        if underWay.step == .failed { visit.failure = BarVisitState.failed }
        await loadStand(for: underWay.character)
    }

    /// The page's clock, ticking while anything is typing.
    private func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            now = Date().timeIntervalSince1970
        }
    }

    private func play(_ name: String) {
        sound?.play(name)
    }
}
