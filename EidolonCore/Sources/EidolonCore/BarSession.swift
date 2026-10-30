import CryptoKit
import Foundation
import GRDB

/// What the bar is like now (upstream `Bar.read`): its drinks in catalog order, and whether a
/// visit done today would be rewarded — none done yet, and rewards are given.
public struct BarStatus: Sendable, Hashable {
    public var drinks: [Drink]
    public var rewardToday: Bool

    public init(drinks: [Drink], rewardToday: Bool) {
        self.drinks = drinks
        self.rewardToday = rewardToday
    }
}

/// A call of a visit under way: its events as they come (upstream `BarCall`), and leaving the
/// page, which leaves the visit while her lines are still being written.
public final class BarCall: AsyncSequence, @unchecked Sendable {
    public typealias Element = BarEvent
    public typealias AsyncIterator = AsyncThrowingStream<BarEvent, Error>.AsyncIterator

    private let stream: AsyncThrowingStream<BarEvent, Error>
    private let stopped: @Sendable () -> Void
    private let cancel: Cancel
    private let lock = NSLock()
    private var isLeft = false

    init(
        _ stream: AsyncThrowingStream<BarEvent, Error>,
        stopped: @escaping @Sendable () -> Void,
        cancel: Cancel = Cancel()
    ) {
        self.stream = stream
        self.stopped = stopped
        self.cancel = cancel
    }

    public func makeAsyncIterator() -> AsyncIterator { stream.makeAsyncIterator() }

    /// The page is gone: the visit is left, if her lines are still being written.
    public func left() {
        lock.lock()
        defer { lock.unlock() }
        guard !self.isLeft else { return }
        self.isLeft = true
        stopped()
    }

    deinit {
        // Read by no one, or not to the end: what it was writing is no longer wanted.
        cancel.cancel()
        left()
    }
}

/// Whether a call's work is cancelled: a call no longer read must reach its end even where it
/// would have gone on, and must not finish its stream as done.
final class Cancel: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
    }
}

/// Everything a visit needs from the content bundle: the bar's files and characters, the
/// installed bundle's directory (her sheet and facts are read from it), the world setting and
/// the holidays — all as they were when the visit came in.
public struct BarContentSource: Sendable {
    public var content: BarContent
    public var directory: URL
    public var world: WorldSetting?
    public var holidays: HolidayTable?

    public init(
        content: BarContent, directory: URL, world: WorldSetting? = nil,
        holidays: HolidayTable? = nil
    ) {
        self.content = content
        self.directory = directory
        self.world = world
        self.holidays = holidays
    }

    /// Her sheet's text, as the prompt has it.
    public func sheet(of character: CharacterConfig) throws -> String {
        try BarContent.sheet(of: character, in: directory)
    }
}

/// Whether the bar is open now (upstream `is_on`, the deployment's switch). This app has no
/// switch behind it; the app passes the default, `true`.
public typealias BarOpen = @Sendable () -> Bool

/// The bar, and the visit under way at it (ADR-0021; upstream `Bar`, without the server).
///
/// One visit at a time, named by an id; coming in again does away with the one before, and
/// one untouched for `BarRules.idle` is done away with as it is next touched. Who comes in,
/// why, what about, her facts, how many drinks she has and each of her orders is drawn as she
/// comes in and as each drink is served; what is said is written by the chat model, in as many
/// calls as she has drinks and one more.
///
/// The bar reads its content through `source`, so a visit under way keeps what it came in on
/// even as another bundle is installed; it is open while `open` says so.
public actor BarRoom {
    /// How a visit's calls run and what draws it.
    public struct Setup: Sendable {
        public var chat: any ChatProvider
        public var embedder: (any EmbeddingProvider)?
        public var reranker: (any RerankProvider)?
        /// What was last saved of the producer (upstream `producer_prompt(read_profile(…))`).
        public var aboutProducer: String
        /// Now, as the bar keeps the time: what it reads at first, as the visit runs.
        public var clock: @Sendable () -> Date

        public init(
            chat: any ChatProvider,
            embedder: (any EmbeddingProvider)? = nil,
            reranker: (any RerankProvider)? = nil,
            aboutProducer: String = "",
            clock: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.chat = chat
            self.embedder = embedder
            self.reranker = reranker
            self.aboutProducer = aboutProducer
            self.clock = clock
        }
    }

    let userQueue: DatabaseQueue
    let clock: @Sendable () -> Date
    /// The device's time zone, for the bar's day: 「当天」 is the producer's day here, not the
    /// server's (ADR-0021). Injected so tests do not depend on the machine's zone.
    let timeZone: @Sendable () -> TimeZone
    /// The content the bar reads, and what it was read from: thrown when the installed
    /// bundle cannot be read, which the bar reports as a failed call.
    let source: @Sendable () throws -> BarContentSource
    let open: BarOpen
    let random: BarRandom
    /// The visit under way, if any.
    private var current: BarVisit?

    public init(
        userQueue: DatabaseQueue,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: @escaping @Sendable () -> TimeZone = { .current },
        source: @escaping @Sendable () throws -> BarContentSource,
        open: @escaping BarOpen = { true },
        random: @escaping BarRandom = { Int.random(in: 0..<max($0, 1)) }
    ) {
        self.userQueue = userQueue
        self.clock = clock
        self.timeZone = timeZone
        self.source = source
        self.open = open
        self.random = random
    }

    // MARK: - Reading

    /// The bar as it is now, and whether a visit done today would be rewarded: none done yet,
    /// and rewards are given. Open or not, what it is is read all the same (upstream
    /// `Bar.read`, which says only that it is off, the app showing the door then).
    public func status() throws -> BarStatus {
        let today = BarRecords.day(clock(), in: timeZone())
        let content = try source().content
        let done = try userQueue.read { try BarRecords.doneOn($0, day: today) }
        return BarStatus(drinks: content.catalog.drinks, rewardToday: !done)
    }

    /// The visits done, oldest first.
    public func records() throws -> [VisitRecord] {
        try userQueue.read { try BarRecords.all($0) }
    }

    /// Forgets every visit done, and what was looked up for them.
    public func clearRecords() throws {
        try userQueue.write { try BarRecords.clear($0) }
    }

    /// The visit under way, as the page catches up on it after being away; nil if none, or
    /// if it was untouched for `BarRules.idle` and so over.
    public func catchUp() throws -> BarVisit? {
        guard let visit = current else { return nil }
        if idle(visit) {
            self.current = nil
            return nil
        }
        return visit
    }

    // MARK: - Entering

    /// A visit begun (upstream `Bar.enter`), doing away with any under way: its events, from
    /// her coming in on.
    ///
    /// Who she is is the character of the day — by the day alone — until there is a visit done
    /// that day, and from then on anyone, each as likely. Her reason and topic are none of her
    /// latest visits' here; her facts are those the topic finds.
    @discardableResult
    public func enter(_ setup: Setup) async throws -> BarCall {
        guard open() else {
            throw EidolonError.barClosed
        }
        // She comes in: the one before is done away with, over short of done.
        current = nil
        let bar = try source()
        let everyone = bar.content.characters
        guard !everyone.isEmpty else {
            throw EidolonError.invalidContent("内容包里没有可以来酒吧的角色")
        }
        let now = clock()
        let today = BarRecords.day(now, in: timeZone())
        let before = try await userQueue.read { try BarRecords.before($0, today: today) }
        let indexed = before.doneToday ? pick(everyone.count) : Self.ofTheDay(today, everyone.count)
        let character = everyone[indexed]
        let hers = try await userQueue.read { db in
            (history: try BarRecords.history(db, characterID: character.id),
             affinity: try Eidolon.readAffinity(db, characterID: character.id, now: now))
        }
        let listed = Self.reason(
            character, bar.content.visits, recent: Set(hers.history.reasons), random
        )
        let reason = VisitReason(listed)
        let topic = Self.topic(character, bar.content.visits, recent: Set(hers.history.topics))
        let facts = await BarFacts(
            contentDirectory: bar.directory, userQueue: userQueue, character: character
        ).about(topic, embedder: setup.embedder, reranker: setup.reranker)

        let cups = BarRules.cups(random)
        let known = Known(
            novice: before.visitsDone < BarRules.noviceVisits,
            usual: Set(hers.history.remembered.lastOrders.map(\.wanted))
        )
        let first = try BarRules.drawOrder(
            character, bar.content.catalog, random, ordered: [], known: known
        )
        let todayLines = TodayPrompt.lines(
            now: now, character: character, characters: everyone,
            unitMates: bar.world?.unitMates(of: character.name) ?? [],
            herLives: bar.world?.livesOf(character.name) ?? [],
            holidays: bar.holidays
        )
        let drafted = BarVisit(
            character: character,
            enteredAt: now,
            reason: reason,
            topic: topic,
            cups: cups,
            known: known,
            shared: BarPrompt.shared(
                sheet: try bar.sheet(of: character),
                birthday: character.birthdayPrompt,
                world: bar.world?.prompt(name: character.name, today: today)
            ),
            about: try BarPrompt.visit(
                aboutProducer: setup.aboutProducer,
                reason: listed,
                topic: topic,
                cups: cups,
                affinityLines: AffinityPrompt.lines(tier: hers.affinity.tier, judged: nil),
                today: todayLines,
                remembered: hers.history.remembered,
                now: now,
                character: character,
                catalog: bar.content.catalog,
                facts: facts
            ),
            facts: facts,
            today: todayLines,
            remembered: hers.history.remembered,
            orders: [first]
        )
        return called(
            drafted, ask: BarPrompt.openingAsk(drafted.orders[0]), first: .visit(visitID: drafted.id, characterID: character.id),
            setup: setup, bar: bar
        )
    }

    // MARK: - Serving

    /// Serves her what the bar counter holds, or a bottled drink by its identifier: the events
    /// of the call after it, from the producer saying one of the fixed lines on. Raises
    /// `barNotWaiting` unless she waits for a drink, and `barBrokenDrink`, changing nothing,
    /// if what is served is none of the drinks.
    @discardableResult
    public func serve(_ served: Mixture?, bottle: String? = nil, setup: Setup) async throws
        -> BarCall
    {
        let bar = try source()
        var visit = try underWayNow()
        guard visit.step == .waiting else {
            throw EidolonError.barNotWaiting
        }
        let glass = served.flatMap { bar.content.catalog.match($0) }
            ?? bottle.flatMap { bar.content.catalog.match(bottle: $0) }
        guard let glass, let order = visit.orders.last else {
            throw EidolonError.barBrokenDrink
        }
        let serving = try BarRules.judged(order, glass, visit.character)
        visit.touched = clock()
        visit.servings.append(serving)
        visit.drunk = try BarRules.drunk(visit.character, servings: visit.servings)
        visit.step = .writing
        let enjoy = bar.content.lines.enjoy[pick(bar.content.lines.enjoy.count)]
        let ask: String
        if visit.servings.count < visit.cups && !visit.drunk {
            let ordered = visit.orders.map(\.target.id)
            let next = try BarRules.drawOrder(
                visit.character, bar.content.catalog, random, ordered: ordered, known: visit.known
            )
            visit.orders.append(next)
            ask = BarPrompt.servingAsk(serving, enjoy: enjoy, next)
        } else {
            ask = BarPrompt.farewellAsk(serving, enjoy: enjoy, servings: visit.servings, drunk: visit.drunk)
        }
        return called(
            visit, ask: ask, first: .line(BarLine(speaker: .producer, zh: enjoy)), setup: setup,
            bar: bar
        )
    }

    /// The call the visit stopped before, failing, tried again, on the same order.
    @discardableResult
    public func retry(_ setup: Setup) async throws -> BarCall {
        var visit = try underWayNow()
        guard visit.step == .failed else {
            throw EidolonError.barNotFailed
        }
        visit.touched = clock()
        visit.step = .writing
        return called(visit, ask: visit.asking, first: nil, setup: setup, bar: try source())
    }

    /// The page's call is cut off by the app going under (ADR-0021): the visit stops before
    /// that call, to be tried again, rather than being left. Answers whether there was a call
    /// being written to cut off: a call already finished (she waits for her drink) is not one,
    /// and the page keeps what it has on screen instead of showing a failure.
    @discardableResult
    public func cutOff() -> Bool {
        guard var visit = current, visit.step == .writing else { return false }
        visit.step = .failed
        self.current = visit
        return true
    }

    /// The page leaves: the visit is over, and gives nothing.
    public func leave() throws {
        _ = try underWayNow()
        current = nil
    }

    /// Every visit untouched for `BarRules.idle` done away with. There is one at a time, and
    /// it is swept as it is next read or touched.
    public func sweep() {
        guard let visit = current, idle(visit) else { return }
                self.current = nil
    }

    // MARK: - Drawing

    /// Which character is the visit's of the day: the first 8 bytes of the SHA-256 of the
    /// day, big-endian, modulo how many there are (upstream `_of_the_day`, without a user —
    /// the bar has one, who is the only one upstream would have).
    static func ofTheDay(_ day: String, _ characters: Int) -> Int {
        guard characters > 0 else { return 0 }
        let digest = SHA256.hash(data: Data("/\(day)".utf8))
        let head = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Int(head % UInt64(characters))
    }

    /// Her reason for coming: one of the list's for her, none of the `recent` unless that
    /// leaves none. The device has no schedule, so none is the job of hers that day.
    static func reason(
        _ character: CharacterConfig, _ listed: BarVisits, recent: Set<String>, _ random: BarRandom
    ) -> BarReason {
        let reasons = listed.reasons(for: character.id)
        guard let one = fresh(reasons, recent, random) else {
            return BarReason(id: "", note: "", mood: .calm)
        }
        return one
    }

    /// What she is to talk about: one of the list's topics for her, none of the `recent`
    /// unless that leaves none.
    static func topic(
        _ character: CharacterConfig, _ listed: BarVisits, recent: Set<String>
    ) -> BarTopic {
        topic(character, listed, recent: recent) { Int.random(in: 0..<max($0, 1)) }
    }

    static func topic(
        _ character: CharacterConfig, _ listed: BarVisits, recent: Set<String>, _ random: BarRandom
    ) -> BarTopic {
        let topics = listed.topics(for: character.id)
        guard let one = fresh(topics, recent, random) else { return BarTopic(id: "", note: "") }
        return one
    }

    /// One of `entries`, none of the `recent` unless that leaves none (upstream `_fresh`).
    private static func fresh<T: Identifiable>(
        _ entries: [T], _ recent: Set<String>, _ random: BarRandom
    ) -> T? where T.ID == String {
        let unused = entries.filter { !recent.contains($0.id) }
        let pool = unused.isEmpty ? entries : unused
        guard !pool.isEmpty else { return nil }
        return pool[Self.pick(pool.count, random)]
    }

    /// One of `count`, by `random` (which may answer the count itself).
    func pick(_ count: Int) -> Int {
        Self.pick(count, random)
    }

    static func pick(_ count: Int, _ random: BarRandom) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(random(count), count - 1))
    }

    // MARK: - The visit under way

    /// The visit under way; `barVisitGone` if there is none, or it was untouched for
    /// `BarRules.idle`, done away with first then.
    private func underWayNow() throws -> BarVisit {
        guard let visit = try catchUp() else { throw EidolonError.barVisitGone }
        return visit
    }

    /// Whether it was untouched for `BarRules.idle`.
    private func idle(_ visit: BarVisit) -> Bool {
        clock().timeIntervalSince(visit.touched) >= BarRules.idle
    }

    // MARK: - The calls

    /// A call of `visit` asking for `ask`, sending `first` before it if any: its events.
    private func called(
        _ visit: BarVisit, ask: String, first: BarEvent?, setup: Setup, bar: BarContentSource
    ) -> BarCall {
        var visit = visit
        visit.asking = ask
        visit.calls += 1
        self.current = visit
        let call = visit.calls
        // What it was opened as: `visit`, with the call it is the `call`th of.
        var opened = visit
        opened.calls = call
        let (stream, continuation) = AsyncThrowingStream<BarEvent, Error>.makeStream()
        let cancel = Cancel()
        let task = Task { [weak self] in
            await self?.run(
                opened, call: call, first: first, setup: setup, bar: bar, into: continuation,
                cancel: cancel
            )
        }
        continuation.onTermination = { _ in task.cancel() }
        return BarCall(stream, stopped: { [weak self] in
            Task { await self?.left(call: call) }
        }, cancel: cancel)
    }

    /// The page is gone while the call `call` of the visit is being read: the visit is left
    /// if it is still that call's, and still being written (upstream `_left_off`). A call
    /// stopping once another is made, as it closes, leaves it be.
    private func left(call: Int) {
        guard let visit = current, visit.calls == call, visit.step == .writing else { return }
        self.current = nil
    }

    /// Whether the visit under way is still that call's.
    private func stillUnderWay(_ call: Int) -> Bool {
        current?.calls == call
    }

    /// A call of the visit, its `call`th: its lines as they close, held back from the line she
    /// orders in on, if she is to order; then the memo and that she waits, or that the visit
    /// is done (upstream `Bar._call`).
    ///
    /// Failing, it is made again once, after telling the page to clear what it sent; failing
    /// again, the visit stops before it — but for her farewell, said in fixed lines instead,
    /// and the visit is done all the same.
    private func run(
        _ visit: BarVisit,
        call: Int,
        first: BarEvent?,
        setup: Setup,
        bar: BarContentSource,
        into continuation: AsyncThrowingStream<BarEvent, Error>.Continuation,
        cancel: Cancel
    ) async {
        if let first { continuation.yield(first) }
        let ordering = visit.ordering
        // What the latest try wrote: what is sent, and — failing — whether the page is to be
        // told to clear it, which it is only if the try said something before it failed.
        var said: [BarLine] = []
        var failure = BarRules.failed
        var tried = false
        for attempt in 0..<BarRules.attempts {
            if Task.isCancelled || cancel.cancelled { return continuation.finish() }
            if attempt != 0 {
                continuation.yield(.retrying)
            }
            said = []
            do {
                said = try await self.attempt(
                    visit, call: call, setup: setup, bar: bar, into: continuation
                )
                tried = true
                break
            } catch is CancellationError {
                return continuation.finish()
            } catch {
                failure = (error as? EidolonError)?.errorDescription ?? BarRules.failed
            }
            if cancel.cancelled || !stillUnderWay(call) { return continuation.finish() }
        }
        guard !cancel.cancelled, stillUnderWay(call) else { return continuation.finish() }
        guard tried else {
            // Both tries failed. Where she is to order, the visit stops before the call; her
            // farewell, said in fixed lines instead, is done all the same, the page told to
            // clear what it sent first if the last try said anything (upstream's `else`).
            guard !ordering else {
                refresh(call) {
                    $0.step = .failed
                    $0.touched = setup.clock()
                }
                continuation.yield(.failed(failure))
                return continuation.finish()
            }
            await farewellInFixedLines(
                visit, call: call, clearing: !said.isEmpty, setup: setup, bar: bar,
                into: continuation
            )
            return continuation.finish()
        }
        guard var done = self.current else { return continuation.finish() }
        done.written.append((ask: done.asking, lines: said))
        if ordering {
            done.step = .waiting
            done.touched = setup.clock()
            self.current = done
            let subtitle = said.filter(\.order).map(\.zh).joined()
            continuation.yield(.memo(done.orders[done.orders.count - 1].memo(subtitle: subtitle)))
            continuation.yield(.waiting)
            return continuation.finish()
        }
        // Done: too late to leave it now.
        self.current = done
        guard !cancel.cancelled else {
            // Read by no one any more: done it is, but nothing more is said on a stream no
            // one reads.
            _ = try? await finish(done, bar: bar, at: setup.clock())
            return continuation.finish()
        }
        do {
            let reward = try await finish(done, bar: bar, at: setup.clock())
            continuation.yield(.done(reward))
        } catch {
            continuation.yield(.failed(BarRules.failed))
        }
        continuation.finish()
    }

    /// One try at the call: each line as it is to be sent. Ends early, short, if the visit is
    /// no longer this call's; raises if it fails or writes no line it needs.
    private func attempt(
        _ visit: BarVisit,
        call: Int,
        setup: Setup,
        bar: BarContentSource,
        into continuation: AsyncThrowingStream<BarEvent, Error>.Continuation
    ) async throws -> [BarLine] {
        let ordering = visit.ordering
        var said: [BarLine] = []
        var held: [BarLine] = []
        var parser = BarParser()
        let stream = setup.chat.stream(messages: messages(visit.prompt))
        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                guard stillUnderWay(call) else { return said }
                for line in parser.feed(chunk) {
                    for shown in Self.holding(line, &held, ordering) {
                        said.append(shown)
                        continuation.yield(.line(shown))
                    }
                }
            }
            for line in parser.finish() {
                for shown in Self.holding(line, &held, ordering) {
                    said.append(shown)
                    continuation.yield(.line(shown))
                }
            }
        } catch {
            throw error
        }
        if ordering {
            guard !held.isEmpty else { throw BarRules.unwritten }
            if !held.contains(where: \.order) {
                held[0].order = true
            }
            held = try await named(visit, call: call, held: held, said: said, setup: setup, bar: bar)
            guard stillUnderWay(call) else { return said }
            for line in held {
                said.append(line)
                continuation.yield(.line(line))
            }
        }
        guard !said.isEmpty else { throw BarRules.unwritten }
        return said
    }

    /// `held`, her order and what follows it in a call she orders in, after `said`, with her
    /// order naming drinks as it should: as written, rewritten in another call, or else said
    /// in a fixed line (upstream `Bar._named`).
    private func named(
        _ visit: BarVisit,
        call: Int,
        held: [BarLine],
        said: [BarLine],
        setup: Setup,
        bar: BarContentSource
    ) async throws -> [BarLine] {
        guard let order = visit.orders.last else { return held }
        let rest = held.filter { !$0.order }
        let orders = held.filter(\.order)
        if BarRules.namesRightly(order, orders, bar.content.catalog) {
            return held
        }
        let ask = BarPrompt.rewriteAsk(visit.asking, order, before: said)
        let rewritten = await meet(visit, ask: ask, setup: setup)
        if !rewritten.isEmpty, BarRules.namesRightly(order, rewritten, bar.content.catalog) {
            return rewritten + rest
        }
        let (fixed, lines) = BarRules.fixedOrder(order, bar.content.lines, random)
        refresh(call) { visit in
            if !visit.orders.isEmpty { visit.orders[visit.orders.count - 1] = fixed }
        }
        return lines + rest
    }

    /// Her order as a call asking for `ask` writes it: her lines marked as her order, or else
    /// her last; none if it writes none of hers, or fails.
    private func meet(_ visit: BarVisit, ask: String, setup: Setup) async -> [BarLine] {
        var parser = BarParser()
        var lines: [BarLine] = []
        do {
            for try await chunk in setup.chat.stream(
                messages: messages(BarPrompt.prompt(
                    shared: visit.shared, visit: visit.about, written: visit.written, ask: ask
                ))
            ) {
                try Task.checkCancellation()
                lines += parser.feed(chunk)
            }
            lines += parser.finish()
        } catch {
            return []
        }
        let hers = lines.filter { $0.speaker == .her }
        if let marked = hers.first(where: \.order) {
            return [marked]
        }
        guard var last = hers.last else { return [] }
        last.order = true
        return [last]
    }

    /// The farewell the call could not write: her reaction to her last drink and her
    /// farewell, in fixed lines, and the visit done all the same (upstream `Bar._call`'s).
    private func farewellInFixedLines(
        _ visit: BarVisit,
        call: Int,
        clearing: Bool,
        setup: Setup,
        bar: BarContentSource,
        into continuation: AsyncThrowingStream<BarEvent, Error>.Continuation
    ) async {
        guard stillUnderWay(call), let serving = visit.servings.last else {
            return continuation.finish()
        }
        if clearing {
            continuation.yield(.retrying)
        }
        let said = BarRules.fixedFarewell(serving, visit.drunk, bar.content.lines, random)
        var done = self.current!
        for line in said { continuation.yield(.line(line)) }
        done.written.append((ask: done.asking, lines: said))
        self.current = done
        do {
            continuation.yield(.done(try await finish(done, bar: bar, at: setup.clock())))
        } catch {
            continuation.yield(.failed(BarRules.failed))
        }
        continuation.finish()
    }

    /// The visit done: written down, rewarded if it is to be, and over (upstream `_done`).
    private func finish(_ visit: BarVisit, bar: BarContentSource, at now: Date) async throws
        -> Reward?
    {
        self.current = nil
        let day = BarRecords.day(visit.enteredAt, in: timeZone())
        return try await userQueue.write { db in
            try BarRecords.writeDown(
                visit, leftAt: now, day: day, rewarding: open(),
                catalog: bar.content.catalog, db
            )
        }
    }

    /// Changes the visit, if it is still that call's, as `change` says.
    private func refresh(_ call: Int, _ change: (inout BarVisit) -> Void) {
        guard var visit = current, visit.calls == call else { return }
        change(&visit)
        self.current = visit
    }

    /// The lines to send now that `line` has closed, `held` keeping those not to be sent yet:
    /// in a call she orders in, her latest line and what follows it, which may be her order,
    /// and anything from a line marked as her order on (upstream `_holding`).
    static func holding(_ line: BarLine, _ held: inout [BarLine], _ ordering: Bool) -> [BarLine] {
        guard ordering else { return [line] }
        if held.contains(where: \.order) {
            held.append(line)
            return []
        }
        if line.speaker == .her {
            let sent = held
            held = [line]
            return sent
        }
        if !held.isEmpty {
            held.append(line)
            return []
        }
        return [line]
    }

    private func messages(_ prompt: [BarChatMessage]) -> [PromptMessage] {
        prompt.map { message in
            switch message.role {
            case "system": PromptMessage(.system, message.content)
            case "assistant": PromptMessage(.assistant, message.content)
            default: PromptMessage(.user, message.content)
            }
        }
    }
}

/// The bar's numbers that upstream keeps beside the rules, and what it tells the page.
extension BarRules {
    /// How long a visit lasts untouched: from then on it is gone (upstream `IDLE`).
    public static let idle: TimeInterval = 30 * 60

    /// How many times a call of a visit is tried: once, and once more should it fail
    /// (upstream `ATTEMPTS`).
    public static let attempts = 2

    /// What the page is told when a call could not be written (upstream `FAILED`).
    public static let failed = "出了点问题，这次光顾没能接着写下去，请稍后再来"
}

/// The model wrote no line a call needs (upstream `_Unwritten`).
struct Unwritten: LocalizedError, Equatable {
    var errorDescription: String? { "这次没有写出该写的台词" }
}

extension BarRules {
    static let unwritten = Unwritten()
}
