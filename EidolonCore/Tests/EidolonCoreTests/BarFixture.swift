import Foundation
import GRDB
import XCTest
@testable import EidolonCore

/// A chat model whose answers the test scripts: each call takes the next answer, and what
/// the calls asked is kept for the test to read (upstream's `ChatLLM` stand-in).
final class ScriptedChat: ChatProvider, @unchecked Sendable {
    enum Answer {
        case chunks([String])
        case failure(Error)
    }

    private let lock = NSLock()
    private var answers: [Answer]
    private var recorded: [[PromptMessage]] = []

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    /// One answer saying these lines, as the model would write them.
    convenience init(lines: [String]) {
        self.init([.chunks(lines)])
    }

    /// Every prompt asked, in order.
    var prompts: [[PromptMessage]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// How many calls were made, answers or none left.
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        recorded.append(messages)
        let answer = answers.isEmpty ? nil : answers.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            switch answer {
            case .failure(let error):
                continuation.finish(throwing: error)
            case .chunks(let chunks):
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            case nil:
                continuation.finish(throwing: ChatProviderError.notConfigured)
            }
        }
    }
}

/// A chat model that answers as its instructions say, given the prompt it is asked: for
/// what a test needs answered by what was asked, rather than in a fixed order.
final class AnsweringChat: ChatProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[PromptMessage]] = []
    private let answer: @Sendable ([PromptMessage]) -> Result<[String], Error>

    init(_ answer: @escaping @Sendable ([PromptMessage]) -> Result<[String], Error>) {
        self.answer = answer
    }

    var prompts: [[PromptMessage]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        recorded.append(messages)
        lock.unlock()
        let result = answer(messages)
        return AsyncThrowingStream { continuation in
            switch result {
            case let .success(lines):
                for line in lines { continuation.yield(line) }
                continuation.finish()
            case let .failure(error):
                continuation.finish(throwing: error)
            }
        }
    }
}

/// A bar's worth of content, written into a directory the way the exporter writes it: the
/// original's drinks in miniature, two characters configured for the bar, and enough
/// reasons and topics that each has more than `BarVisits.recentVisits` of each.
enum BarFixture {
    /// The drinks: three mixed and one bottled, none of two recipes alike.
    static var drinks: JSONValue {
        func drink(
            _ id: String, _ name: String, _ nameJa: String, _ flavor: String, _ kind: String,
            parts: [Int], karmotrine: JSONValue?, ice: Bool = false, method: String = "mix",
            page: Int? = nil
        ) -> JSONValue {
            var object: [String: JSONValue] = [
                "id": .string(id),
                "name": .string(name),
                "name_ja": .string(nameJa),
                "short_name": .string(name),
                "flavor": .string(flavor),
                "kind": .string(kind),
                "method": .string(method),
                "description": .string("\(name)的描述"),
            ]
            if !parts.isEmpty {
                object["adelhyde"] = .int(parts[0])
                object["bronson_extract"] = .int(parts[1])
                object["powdered_delta"] = .int(parts[2])
                object["flanergide"] = .int(parts[3])
                object["karmotrine"] = karmotrine ?? .string("optional")
                object["ice"] = .bool(ice)
                object["aged"] = .bool(false)
                if let page { object["page"] = .int(page) }
            } else {
                object["karmotrine"] = karmotrine ?? .int(0)
            }
            return .object(object)
        }
        return .object(["drinks": .array([
            drink("adelhyde-flavor", "Adelhyde Flavor", "アデルハイドフレーバー", "sweet", "girly",
                  parts: [2, 0, 1, 0], karmotrine: nil, page: 1),
            drink("bronson-aged", "Bronson Aged", "ブロンソンエイジ", "bitter", "manly",
                  parts: [0, 2, 1, 0], karmotrine: .int(2), page: 2),
            drink("flanergide-on-ice", "Flanergide On Ice", "フラナジドオンアイス", "spicy", "promo",
                  parts: [0, 0, 3, 2], karmotrine: .int(1), ice: true, page: 3),
            drink("mulan-tea", "Mulan Tea", "ムーランティー", "sweet", "girly",
                  parts: [], karmotrine: .int(1), method: "bottle", page: 4),
        ])])
    }

    /// Reasons and topics: four each, so that avoiding the latest three still leaves one.
    static var visits: JSONValue {
        func entry(_ prefix: String, _ n: Int, mood: String? = nil) -> JSONValue {
            var object: [String: JSONValue] = [
                "id": .string("\(prefix)-\(n)"),
                "note": .string("\(prefix) \(n) 的说明"),
            ]
            if let mood { object["mood"] = .string(mood) }
            return .object(object)
        }
        return .object([
            "reasons": .array((1...4).map { entry("reason", $0, mood: "calm") }),
            "topics": .array((1...4).map { entry("topic", $0) }),
        ])
    }

    static var lines: JSONValue {
        func line(_ ja: String, _ zh: String, emotion: String = "calm") -> JSONValue {
            .object(["ja": .string(ja), "zh": .string(zh), "emotion": .string(emotion)])
        }
        var orders: [String: JSONValue] = [:]
        for phrasing in Phrasing.allCases {
            let fields: [String]
            switch phrasing {
            case .name, .nameBig: fields = ["{name_ja}", "{name}"]
            case .flavor: fields = ["{flavor}", "{flavor}"]
            case .kind: fields = ["{kind}", "{kind}"]
            case .conditions, .analogy: fields = ["{conditions}", "{conditions}"]
            case .myFavorite, .yourCall, .usual: fields = ["いつもの", "老样子"]
            }
            orders[phrasing.rawValue] = .array([line(fields[0], fields[1])])
        }
        var reactions: [String: JSONValue] = [:]
        for tier in Tier.allCases {
            reactions[tier.rawValue] = .array([line("\(tier.rawValue) 的反应", "\(tier.rawValue) 的反应")])
        }
        return .object([
            "enjoy": .array([.string("请慢用。"), .string("这杯给你。")]),
            "orders": .object(orders),
            "no_alcohol": .array([line("アルコール抜きで。", "不要酒精。")]),
            "reactions": .object(reactions),
            "farewells": .object([
                Sobriety.sober.rawValue: .array([line("また来ますね。", "我还会再来的。")]),
                Sobriety.drunk.rawValue: .array([line("……もう帰るね。", "……我该回去了。")]),
            ]),
        ])
    }

    /// Two characters: one who holds her drink weakly and loves the sweet one, one who
    /// holds it strongly.
    static var characters: [JSONValue] {
        [
            .object([
                "id": .string("mano"),
                "name": .string("櫻木真乃"),
                "name_zh": .string("樱木真乃"),
                "sheet": .string("characters/sheets/mano.md"),
                "birthday": .string("04-25"),
                "bar_flavors": .array([.string("sweet")]),
                "bar_kind": .string("girly"),
                "bar_favorites": .array([.string("adelhyde-flavor")]),
                "bar_disliked_flavor": .string("spicy"),
                "bar_tolerance": .string("weak"),
            ]),
            .object([
                "id": .string("hiori"),
                "name": .string("風野灯織"),
                "sheet": .string("characters/sheets/hiori.md"),
                "birthday": .string("03-04"),
                "bar_flavors": .array([.string("bitter")]),
                "bar_kind": .string("manly"),
                "bar_favorites": .array([.string("bronson-aged")]),
                "bar_disliked_flavor": .string("sweet"),
                "bar_tolerance": .string("strong"),
            ]),
        ]
    }

    /// Writes the content a bar visit reads into `directory`, and returns it as the bar's
    /// source reads it.
    @discardableResult
    static func write(to directory: URL) throws -> BarContentSource {
        let characters = directory.appendingPathComponent("characters", isDirectory: true)
        let sheets = characters.appendingPathComponent("sheets", isDirectory: true)
        try FileManager.default.createDirectory(at: sheets, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        try encoder.encode(drinks).write(to: characters.appendingPathComponent("drinks.json"))
        try encoder.encode(visits).write(to: characters.appendingPathComponent("bar_visits.json"))
        try encoder.encode(lines).write(to: characters.appendingPathComponent("bar_lines.json"))
        try encoder.encode(charactersJSON).write(to: characters.appendingPathComponent("characters.json"))
        try "# 真乃\n".write(to: sheets.appendingPathComponent("mano.md"), atomically: true, encoding: .utf8)
        try "# 灯織\n".write(to: sheets.appendingPathComponent("hiori.md"), atomically: true, encoding: .utf8)
        return BarContentSource(content: try BarContent(directory: directory), directory: directory)
    }

    private static var charactersJSON: [JSONValue] { characters }

    /// A random that answers with the same number below every bound: the first of each
    /// pool, or the last where it is `high`.
    static func constantRandom(_ pick: @escaping @Sendable (Int) -> Int) -> BarRandom {
        { count in max(0, min(pick(count), count - 1)) }
    }

    static let first = constantRandom { _ in 0 }
}

/// The time, as a test moves it and the bar reads it.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 0)

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return time
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            time = newValue
        }
    }
}

/// What a bar test shares with the closures the bar runs on, without the test itself (which
/// XCTest's sendability rules keep from crossing into them).
final class BarHome: @unchecked Sendable {
    let root: URL
    let queue: DatabaseQueue
    var content: BarContentSource { source() }

    init(root: URL, queue: DatabaseQueue, content: @escaping @Sendable () -> BarContentSource) {
        self.root = root
        self.queue = queue
        self.source = content
    }

    private let source: @Sendable () -> BarContentSource
}

/// A bar test's home: a temporary directory, a user library migrated to the current schema,
/// a clock the test moves, and the content the bar reads.
class BarTestCase: XCTestCase {
    var root: URL!
    var queue: DatabaseQueue!
    var now: Date!
    var content: BarContentSource!
    /// What the bar is given: the library, the clock and the content, shared without the test.
    let clock = Clock()
    /// The bar's days in the tests are Tokyo's, so they do not depend on the machine's zone.
    static let timeZone = TimeZone(identifier: "Asia/Tokyo")!
    private var home: BarHome!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonBar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = try DatabaseQueue(path: root.appendingPathComponent("user.sqlite").path)
        try UserSchema.migrate(queue)
        // Nine at night in Beijing.
        now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-28T13:00:00Z"))
        clock.now = now
        content = try BarFixture.write(to: root.appendingPathComponent("content", isDirectory: true))
        let source = content!
        home = BarHome(root: root, queue: queue, content: { source })
    }

    override func tearDownWithError() throws {
        queue = nil
        content = nil
        home = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// The time now, as the bar and the test keep it.
    func tick(_ seconds: TimeInterval = 0) {
        now = now.addingTimeInterval(seconds)
        clock.now = now
    }

    /// A bar over this test's content and library.
    func room(
        _ chat: any ChatProvider,
        random: @escaping BarRandom = BarFixture.first,
        world: WorldSetting? = nil,
        open: @escaping BarOpen = { true }
    ) -> BarRoom {
        let home = home!
        let clock = self.clock
        return BarRoom(
            userQueue: home.queue, clock: { clock.now }, timeZone: { Self.timeZone },
            source: {
                var content = home.content
                content.world = world
                return content
            },
            open: open, random: random
        )
    }

    /// What a visit's calls run on: the model and the clock.
    func setup(_ chat: any ChatProvider, clock: Clock? = nil) -> BarRoom.Setup {
        let clock = clock ?? self.clock
        return BarRoom.Setup(chat: chat, clock: { clock.now })
    }

    /// Every event of a call, collected.
    func collect(_ call: BarCall) async throws -> [BarEvent] {
        var events: [BarEvent] = []
        for try await event in call { events.append(event) }
        return events
    }

    /// The lines a call wrote, in order.
    func lines(_ events: [BarEvent]) -> [BarLine] {
        events.compactMap {
            if case let .line(line) = $0 { return line }
            return nil
        }
    }

    /// Her set of lines writing `count` lines, the last of which orders.
    func herLines(_ count: Int, emotion: String = "happy") -> [String] {
        (0..<count).map { index in
            let order = index == count - 1 ? " order=\"true\"" : ""
            return "<her emotion=\"\(emotion)\"\(order)><ja>한\(index)</ja><zh>句\(index)</zh></her>"
        }
    }

}
