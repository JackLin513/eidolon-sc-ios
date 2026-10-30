import EidolonCore
import Foundation

/// One visit at the bar, as the screen keeps it (upstream `lib/barVisit.ts`): where it is, the
/// lines the text box has, what the bar counter is making, and how it ends. Reduced from her
/// lines and the player's taps; the visiting itself is `BarRoom`'s.
///
/// - She comes in through the door: tapped, 「进来中」 until the visit's call says she is in.
/// - Her lines queue in the box, each laid out in pages; a tap types a page out at once, or
///   turns to the next. With none left, the box waits for the next call to write.
/// - The order memo comes as she orders: the counter opens once the order's last page is
///   tapped past.
/// - Served, the counter closes and the shaker is poured out; her farewell's lines follow, and
///   once the box has nothing left the end card is shown.
///
/// The tutorial walks the same screen, fed a section at a time and nothing sent (`BarTutorial`).
@MainActor
@Observable
final class BarVisitState {
    enum Stage: Equatable {
        /// Before the door was tapped.
        case door
        /// The door was tapped; the visit is being made.
        case entering
        /// Someone is in.
        case visit
        /// Done at the door: the next visit from there.
        case next
    }

    /// What the door says under the sign when it is not the plain 「点一下进门」.
    var notice: String?
    var stage: Stage = .door
    var queue: [BarVisitScreen.LinePage] = []
    var shown: BarVisitScreen.ShownPage?
    var isAwaitingLine = false
    /// The order memo, while the counter is open.
    var memo: String?
    var failure: String?
    var isRetrying = false
    var isMixing = false
    var mixer = BarMixer.State()
    var visit: BarVisitScreen.Visit?
    var mood: StandEmotion = .calm
    /// What the visit was rewarded with, once done.
    var reward: Reward?
    var isDone = false
    /// She lives in this content bundle's characters, for her name and colour.
    var her: CharacterConfig?
    /// What the box says when a call could not be written: the same words the bar's own
    /// failure carries.
    static let failed = "出了点问题，这次光顾没能接着写下去，请稍后再来"

    /// The bar's sounds, played as the screen changes.
    var play: (String) -> Void = { _ in }
    /// Where the lines are laid out.
    var names = BarTextNames(her: "")
    /// The pixel face the lines are measured in: the screen's, once a package is in.
    var face = BarFont.Face.fallback

    /// Whether the bar counter is open under the book.
    var isCounterOpen: Bool { isMixing }
    /// Whether the call of the visit is being made again.
    var isInside: Bool { stage == .visit || stage == .next }

    private var serving = false
    /// The page on the box and her mood when this call began: what a `retrying` goes back to
    /// (upstream `lib/barScene`'s mark and resume).
    private var callStart: (shown: BarVisitScreen.ShownPage?, mood: StandEmotion)?

    init() {}

    /// A call is about to write: what the box shows now is what it goes back to if the call is
    /// made again.
    func beginCall() {
        callStart = (shown, mood)
    }

    /// Lays a line out in pages of the box's width with the pixel font's measure.
    func layout(_ line: BarTextLine) -> [BarTextPage] {
        BarText.paginate(line, names: names) { Int(face.width($0)) }
    }

    // MARK: - What the box shows

    /// Whether the page on the box is her order's last: the counter opens after it.
    var isOrderPage: Bool { shown?.page.orderLast ?? false }


    /// The page's text as far as it has typed, at `now`.
    func typedPage(_ now: TimeInterval) -> BarTextPage? {
        guard let shown else { return nil }
        let typed = BarText.typedChars(shown.page.page, shown.typing, now: now)
        return BarTextPage(rows: BarText.shownRows(shown.page.page, typed: typed))
    }

    func isTypedOut(_ now: TimeInterval) -> Bool {
        guard let shown else { return true }
        return BarText.isTypedOut(shown.page.page, shown.typing, now: now)
    }

    /// Whether the arrow hops at the box's corner: a page typed out with nothing waiting on the
    /// call, and no counter or failure over it.
    func isArrowShown(_ now: TimeInterval) -> Bool {
        shown != nil && !isAwaitingLine && !isMixing && failure == nil && isTypedOut(now)
    }

    // MARK: - The visit's events

    /// The lines of hers and the producer's, in order, each as a page.
    func say(_ line: BarTextLine) {
        say(line, mood: mood)
    }

    /// `line` queued, `mood` hers from the line on; `orders` the last page of one she orders a
    /// drink in.
    func say(_ line: BarTextLine, mood: StandEmotion, orders: Bool = false) {
        let pages = layout(line)
        for (index, page) in pages.enumerated() {
            queue.append(
                BarVisitScreen.LinePage(
                    line: line, mood: line.speaker == .her ? mood : self.mood, page: page,
                    isLast: index == pages.count - 1,
                    orderLast: orders && index == pages.count - 1
                )
            )
        }
        if shown == nil || isAwaitingLine { showNext() }
    }

    /// An event of the visit's call.
    func received(_ event: BarEvent, now: TimeInterval) {
        switch event {
        case let .visit(id, characterID):
            visit = BarVisitScreen.Visit(id: id, characterID: characterID)
            stage = .visit
        case let .line(line):
            say(Self.text(of: line), mood: line.emotion, orders: line.order)
        case let .memo(text):
            // 点单的这一句读完，调酒台才打开（`isOrderRead`）。
            memo = text
        case .waiting:
            isAwaitingLine = true
        case .retrying:
            // 再打一次：上一次写的不用了，框回到这次调用之前的那一页与心情。
            if let start = callStart {
                shown = start.shown
                mood = start.mood
            } else {
                shown = nil
            }
            clearCall()
        case let .done(won):
            reward = won
            isDone = true
        case let .failed(message):
            failure = message
        }
    }

    /// The text box's line for a line of hers or the producer's.
    static func text(of line: BarLine) -> BarTextLine {
        line.speaker == .her ? .her(ja: line.ja, zh: line.zh) : .producer(zh: line.zh)
    }

    /// Whether the memo is in and the order's last page was tapped past: the counter opens.
    var isOrderRead: Bool {
        guard memo != nil, isOrderPage, isAwaitingLine, queue.isEmpty else { return false }
        return true
    }

    /// 调酒台打开：memo 在框上，摇酒器空着。
    func openCounter() {
        guard memo != nil, !isMixing, !serving else { return }
        isMixing = true
        mixer = BarMixer.State()
    }

    // MARK: - Taps

    /// The text box tapped.
    func tap(now: TimeInterval) {
        guard stage == .visit || stage == .next else { return }
        guard failure == nil else { return }
        if isMixing { return }
        if let shown, !BarText.isTypedOut(shown.page.page, shown.typing, now: now) {
            self.shown?.typing.finished = true
            return
        }
        if !queue.isEmpty {
            showNext()
            return
        }
        isAwaitingLine = true
        if isOrderRead { openCounter() }
    }

    /// The next queued page on the box; none queued, the box waits.
    func showNext(now: TimeInterval = Date().timeIntervalSince1970) {
        guard !queue.isEmpty else {
            isAwaitingLine = true
            return
        }
        let page = queue.removeFirst()
        shown = BarVisitScreen.ShownPage(page: page, typing: .init(startedAt: now))
        isAwaitingLine = false
        mood = page.mood
    }

    /// 上一次写的不要了：没读的页面丢掉，框上那句留着。
    func clearCall() {
        queue = []
        isAwaitingLine = true
    }

    /// The failed call made again was taken (upstream `retried`): what it wrote is dropped
    /// and the box is free for the new call's lines.
    func retried() {
        guard isRetrying else { return }
        clearCall()
        failure = nil
        isRetrying = false
    }

    // MARK: - The counter

    /// Something done at the open bar counter.
    func mix(_ action: BarMixer.Action) {
        guard isMixing else { return }
        mixer = BarMixer.apply(mixer, action)
    }

    /// What the shaker holds served.
    func serve() -> Mixture? {
        guard isMixing, let mixture = BarMixer.served(mixer).mixture else { return nil }
        isMixing = false
        mixer = BarMixer.State()
        serving = true
        memo = nil
        isRetrying = false
        return mixture
    }

    /// The call after serving came.
    func served() {
        serving = false
    }

    // MARK: - The end

    /// Whether the end card is shown: done, and the box has nothing left to say.
    var endCard: Bool {
        isDone && queue.isEmpty && (shown == nil || isAwaitingLine)
    }

    /// A visit begun: everything cleared, the box waiting for her first line.
    func begin() {
        reset()
        stage = .entering
    }

    /// The visit over as far as calls go: from here 「再营业」 is the door again.
    func end() {
        stage = .next
        queue = []
        isAwaitingLine = true
        isMixing = false
        mixer = BarMixer.State()
        memo = nil
    }

    /// No one at the bar: back to the door, and who she was forgotten.
    func clearVisit() {
        reset()
        visit = nil
        her = nil
        names = BarTextNames(her: "")
    }

    /// 「再营业」: back to the door for another visit.
    func again() {
        stage = .next
        notice = nil
        shown = nil
        queue = []
        isAwaitingLine = false
        isDone = false
        reward = nil
        failure = nil
        memo = nil
        isMixing = false
        mixer = BarMixer.State()
        mood = .calm
        serving = false
        visit = nil
    }

    /// Back to the door, everything as it was before a visit.
    func reset() {
        again()
        stage = .door
    }
}
