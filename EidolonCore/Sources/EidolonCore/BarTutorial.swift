import Foundation

/// Her mood, what the text box says, and the bar counter, as a visit's screen keeps them
/// (upstream `lib/barVisit.ts`, the part the tutorial walks): reduced from her lines and the
/// player's taps. The tutorial is not a visit — nothing is sent, no model is called — but the
/// text box, her mood and the counter are the visit's, fed a section at a time.
///
/// - Lines are queued in order, each laid out in pages. A page types out at 30 characters a
///   second, a tap types it out at once; a tap on a page typed out turns to the next. With no
///   page left, the box waits for the next line to come.
/// - Her mood is that of the last line of hers shown.
/// - The counter opens with the section's memo once the section's last page is tapped past.
/// - Served, the reaction's lines follow; the counter closes and the shaker is poured out.
public struct BarVisitScreen: Sendable, Hashable {
    /// A page of a line queued for the text box.
    public struct LinePage: Sendable, Hashable {
        public var line: BarTextLine
        public var mood: StandEmotion
        public var page: BarTextPage
        public var isLast: Bool
        /// The last page of a line she orders in: tapped past, the bar counter opens.
        public var orderLast = false

        public init(
            line: BarTextLine,
            mood: StandEmotion,
            page: BarTextPage,
            isLast: Bool,
            orderLast: Bool = false
        ) {
            self.line = line
            self.mood = mood
            self.page = page
            self.isLast = isLast
            self.orderLast = orderLast
        }
    }

    /// Who came in, and under what id.
    public struct Visit: Sendable, Hashable {
        public var id: String
        public var characterID: String

        public init(id: String, characterID: String) {
            self.id = id
            self.characterID = characterID
        }
    }

    /// A page on the text box, and how far it has typed.
    public struct ShownPage: Sendable, Hashable {
        public var page: LinePage
        public var typing: BarText.Typing

        public init(page: LinePage, typing: BarText.Typing) {
            self.page = page
            self.typing = typing
        }
    }

    /// Who is in, and who.
    public var visit: Visit?
    /// The page on the text box, and how far it has typed.
    public var shown: ShownPage?
    /// Pages come and not yet shown, in order.
    public var queue: [LinePage] = []
    /// The player tapped past the last page: the next to come shows at once.
    public var isAwaitingLine = false
    /// Her mood: of the last line of hers on the box; calm as she comes in.
    public var mood: StandEmotion = .calm
    /// The bar counter is open (mixing her drink).
    public var isMixing = false
    /// The order memo of the drink being mixed: the text box says it while the counter is open.
    public var memo: String?
    /// The counter's shaker.
    public var mixer: BarMixer.State = .init()

    public init() {}

    /// She came in: everything else as before her.
    public static func comingIn(visitID: String, characterID: String) -> BarVisitScreen {
        var screen = BarVisitScreen()
        screen.visit = Visit(id: visitID, characterID: characterID)
        return screen
    }

    public var isVisiting: Bool { visit != nil }
}

/// The tutorial (`BarTutorialLines` for what it says): its lines, which section they are of,
/// and where it ends. Pure: the screen draws it and keeps the time (`now`, in seconds).
///
/// - A section that opens the bar counter opens it once its last page is tapped past (the
///   lesson told and read), with the lesson's memo for the text box to say.
/// - Served, what the shaker made picks her reaction: the drink by its id, or the section's
///   `other`. A broken one cannot be served, as in a visit.
/// - Its lines done, the tutorial ends: to the jukebox setup, or straight to the door with no
///   jukebox (no audio), the jukebox section left out. 「跳过」 ends it at once the same way.
public struct BarTutorial: Sendable, Hashable {
    /// Where the tutorial ends: the jukebox setup, or the door (no jukebox).
    public enum End: String, Sendable, Hashable {
        case jukebox, door
    }

    /// The section whose lines are on the box.
    public var section: BarTutorialSectionID
    /// There is a jukebox to choose for (audio to play): its section is said, the setup ends it.
    public var hasJukebox: Bool
    /// Each line of each section, laid out in pages.
    public var laidOut: [BarTutorialSectionID: [BarVisitScreen.LinePage]]
    /// The text box, her mood and the bar counter.
    public var screen: BarVisitScreen
    /// Ended (done or skipped), and to where.
    public var end: End?

    /// What a line of the tutorial is laid out with: the names at row heads.
    public typealias Layout = (BarTextLine) -> [BarTextPage]

    /// The tutorial from its first line, her (`characterID`) come in.
    public static func begin(
        characterID: String,
        hasJukebox: Bool,
        layout: Layout,
        now: TimeInterval
    ) -> BarTutorial {
        var laidOut: [BarTutorialSectionID: [BarVisitScreen.LinePage]] = [:]
        for id in BarTutorialSectionID.allCases {
            let lines = BarTutorialLines.section(id).lines
            laidOut[id] = lines.flatMap { line -> [BarVisitScreen.LinePage] in
                let pages = layout(line.text)
                return pages.enumerated().map { index, page in
                    BarVisitScreen.LinePage(
                        line: line.text, mood: line.emotion, page: page,
                        isLast: index == pages.count - 1
                    )
                }
            }
        }
        var tutorial = BarTutorial(
            section: BarTutorialLines.start,
            hasJukebox: hasJukebox,
            laidOut: laidOut,
            screen: .comingIn(visitID: Self.visitID, characterID: characterID),
            end: nil
        )
        return tutorial.say(BarTutorialLines.start, now: now)
    }

    /// The tutorial's screen has no id sent anywhere: nothing to leave.
    static let visitID = "tutorial"

    /// What the text box, the counter and her mood do with an action; one that changes
    /// nothing is the state it was given.
    public func applying(_ action: Action) -> BarTutorial {
        guard end == nil else { return self }
        switch action {
        case let .tap(now):
            return onward(screen.tapped(at: now), now: now)
        case let .mix(action):
            var next = self
            guard screen.isMixing else { return self }
            let mixer = BarMixer.apply(screen.mixer, action)
            guard mixer != screen.mixer else { return self }
            next.screen.mixer = mixer
            return next
        case let .serve(now):
            guard case let .mixer(_, reactions, other) = BarTutorialLines.section(section).then,
                  screen.isMixing, BarMixer.canServe(screen.mixer)
            else { return self }
            let reaction = screen.mixer.made.flatMap { reactions[$0.drink.id] } ?? other
            // 上了酒：调酒台收起、杯子倒掉，她的反应马上打。
            var next = self
            next.screen.isMixing = false
            next.screen.isAwaitingLine = true
            next.screen.mixer = .init()
            return next.say(reaction, now: now)
        case .skip:
            return .init(
                section: section, hasJukebox: hasJukebox, laidOut: laidOut, screen: screen,
                end: hasJukebox ? .jukebox : .door
            )
        }
    }

    public enum Action: Sendable, Hashable {
        /// The text box tapped.
        case tap(now: TimeInterval)
        /// Something done at the open bar counter.
        case mix(BarMixer.Action)
        /// What is in the shaker served.
        case serve(now: TimeInterval)
        /// 「跳过」 tapped.
        case skip
    }

    /// The lines of `section` queued for the box (the first shown at once if the box awaits one).
    private func say(_ section: BarTutorialSectionID, now: TimeInterval) -> BarTutorial {
        var next = self
        next.screen.isAwaitingLine = true
        for page in laidOut[section] ?? [] {
            next.screen = next.screen.queuing(page)
        }
        next.section = section
        // 框上没东西、或者正等下一句时，第一页马上开始打。
        if next.screen.shown == nil || next.screen.isAwaitingLine {
            next.screen = next.screen.isAwaitingLine
                ? next.screen.showingNext(at: now)
                : next.screen
        }
        return next
    }

    /// After a tap: a section's last page tapped past, on to what follows it.
    private func onward(_ screen: BarVisitScreen, now: TimeInterval) -> BarTutorial {
        guard !screen.isMixing, screen.queue.isEmpty, screen.isAwaitingLine else {
            var next = self
            next.screen = screen
            return next
        }
        switch BarTutorialLines.section(section).then {
        case let .mixer(memo, _, _):
            var next = self
            next.screen = screen
            next.screen.isMixing = true
            next.screen.mixer = .init()
            next.screen.memo = memo
            return next
        case .done:
            return .init(
                section: section, hasJukebox: hasJukebox, laidOut: laidOut, screen: screen,
                end: .jukebox
            )
        case let .section(following):
            guard following != .jukebox || hasJukebox else {
                return .init(
                    section: section, hasJukebox: hasJukebox, laidOut: laidOut, screen: screen,
                    end: .door
                )
            }
            var next = self
            next.screen = screen
            return next.say(following, now: now)
        }
    }
}

extension BarVisitScreen {
    /// `page` put at the end of what is queued for the box.
    func queuing(_ page: LinePage) -> BarVisitScreen {
        var next = self
        next.queue.append(page)
        return next
    }

    /// The next page queued put on the box, typing from `now`; nothing queued, as it was.
    func showingNext(at now: TimeInterval) -> BarVisitScreen {
        guard let first = queue.first else { return self }
        return showing(first, at: now)
    }

    /// The next page queued put on the box, typing from `now`.
    func showing(_ page: LinePage, at now: TimeInterval) -> BarVisitScreen {
        var next = self
        next.shown = ShownPage(page: page, typing: .init(startedAt: now))
        next.queue = Array(queue.dropFirst())
        next.isAwaitingLine = false
        if page.line.speaker == .her { next.mood = page.mood }
        return next
    }

    /// The text box tapped at `now`: a page typing out is typed out at once; one typed out
    /// turns to the next, or the box waits for a line to come.
    func tapped(at now: TimeInterval) -> BarVisitScreen {
        guard let shown, !BarText.isTypedOut(shown.page.page, shown.typing, now: now) else {
            guard !queue.isEmpty else {
                var next = self
                next.isAwaitingLine = true
                return next
            }
            return showingNext(at: now)
        }
        var next = self
        next.shown?.typing.finished = true
        return next
    }
}
