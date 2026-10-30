import EidolonCore
import Foundation

/// The prompt the iOS core assembles for the oracle scenario (ADR-0012), written as JSON
/// for `tools/oracle/compare.py` to diff against the upstream engine's. No model is
/// called: a scripted provider answers the history turns and records the final prompt.
struct Scenario: Decodable {
    struct Turn: Decodable {
        var user: String
        var ja: String
        var zh: String
    }

    var characterID: String
    var timezone: String
    var start: String
    var now: String
    var history: [Turn]
    var message: String
    var talking: String?
    var voiceModel: String?


    enum CodingKeys: String, CodingKey {
        case characterID = "character_id"
        case timezone
        case start
        case now
        case history
        case message
        case talking
        case voiceModel = "voice_model"
    }
}

final class ScriptedProvider: ChatProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [[String]]
    private var recorded: [[PromptMessage]] = []

    init(replies: [[String]]) {
        self.replies = replies
    }

    var prompts: [[PromptMessage]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        recorded.append(messages)
        let chunks = replies.isEmpty
            ? ["<ja>うん</ja><zh>嗯</zh>"]
            : replies.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

func main() async throws {
    let arguments = CommandLine.arguments
    if arguments.contains("--bar") { return try await barMain(arguments) }
    func value(_ flag: String, default fallback: String) -> String {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count
        else { return fallback }
        return arguments[index + 1]
    }

    let bundlePath = value("--bundle", default: "build/eidolon-content.eidolonpkg")
    let scenarioPath = value("--scenario", default: "tools/oracle/scenario.json")
    let outPath = value("--out", default: "build/oracle/app.json")

    let scenario = try JSONDecoder().decode(
        Scenario.self,
        from: Data(contentsOf: URL(fileURLWithPath: scenarioPath))
    )
    let formatter = ISO8601DateFormatter()
    guard let start = formatter.date(from: scenario.start),
          let now = formatter.date(from: scenario.now)
    else {
        throw NSError(domain: "oracle", code: 1, userInfo: [NSLocalizedDescriptionKey: "场景的时间无法解析"])
    }
    guard let zone = TimeZone(identifier: scenario.timezone) else {
        throw NSError(domain: "oracle", code: 1, userInfo: [NSLocalizedDescriptionKey: "未知时区 \(scenario.timezone)"])
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("eidolon-oracle-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
    try await eidolon.install(bundleAt: URL(fileURLWithPath: bundlePath))

    let provider = ScriptedProvider(
        replies: scenario.history.map { ["<ja>\($0.ja)</ja><zh>\($0.zh)</zh>"] }
    )
    for turn in scenario.history {
        for try await _ in eidolon.sendTurn(
            characterID: scenario.characterID,
            text: turn.user,
            provider: provider,
            now: start,
            timeZone: zone,
            tracing: .off
        ) {}
    }
    for try await _ in eidolon.sendTurn(
        characterID: scenario.characterID,
        text: scenario.message,
        provider: provider,
        now: now,
        timeZone: zone,
        tracing: .off,
        talking: scenario.talking == "inCall" ? .inCall : .typing,
        voicedBy: scenario.voiceModel
    ) {}

    let prompt = provider.prompts.last ?? []
    // A struct, not a dictionary: the file must be the same on every run.
    struct Encoded: Encodable {
        var role: String
        var content: String
    }
    let encoded = prompt.map { Encoded(role: $0.role.rawValue, content: $0.content) }
    let out = URL(fileURLWithPath: outPath)
    try FileManager.default.createDirectory(
        at: out.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    var data = try encoder.encode(encoded)
    data.append(0x0A)
    try data.write(to: out)
    print("wrote \(outPath) (\(encoded.count) messages)")
}

try await main()

// MARK: - The bar scenario

/// The bar's prompt as `bar_prompt.prompt` builds it, from the inputs the scenario fixes
/// (ADR-0021): the same messages `tools/oracle/upstream_bar_prompt.py` writes upstream.
struct BarScenario: Decodable {
    struct Remembered: Decodable {
        var visits: Int
        var lastLeftAt: String?
        var lastOrders: [Had]?
        var lastDrunk: Bool?

        enum CodingKeys: String, CodingKey {
            case visits
            case lastLeftAt = "last_left_at"
            case lastOrders = "last_orders"
            case lastDrunk = "last_drunk"
        }
    }

    struct Had: Decodable {
        var target: String
        var phrasing: String
        var served: String
        var big: Bool
        var tier: String
    }

    struct Written: Decodable {
        var ask: String
        var lines: [Line]
    }

    struct Line: Decodable {
        var speaker: String
        var zh: String
        var ja: String?
        var emotion: String?
        var order: Bool?
    }

    struct Order: Decodable {
        var target: String
        var phrasing: String
        var said: [String]?
        var usual: [String]?
    }

    struct Serving: Decodable {
        var order: Order
        var served: JSONValue
        var tier: String
        var wrong: String?
    }

    struct Ask: Decodable {
        var kind: String
        var order: Order?
        var enjoy: String?
        var serving: Serving?
        var servings: [Serving]?
        var drunk: Bool?
        var before: [Line]?
    }

    var characterID: String
    var reasonID: String
    var topicID: String
    var cups: Int
    var aboutProducer: String
    var affinityLines: [String]?
    var today: [String]?
    var world: String?
    var facts: [String]?
    var now: String
    var remembered: Remembered
    var written: [Written]?
    var ask: Ask
    /// Several calls' last parts, compared in one run; `ask` alone is one of them.
    var asks: [Ask]?

    enum CodingKeys: String, CodingKey {
        case characterID = "character_id"
        case reasonID = "reason_id"
        case topicID = "topic_id"
        case cups
        case aboutProducer = "about_producer"
        case affinityLines = "affinity_lines"
        case today
        case world
        case facts
        case now
        case remembered
        case written
        case ask
        case asks
    }
}

func barMain(_ arguments: [String]) async throws {
    func value(_ flag: String, default fallback: String) -> String {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count
        else { return fallback }
        return arguments[index + 1]
    }
    let bundlePath = value("--bundle", default: "build/eidolon-content.eidolonpkg")
    let scenarioPath = value("--scenario", default: "tools/oracle/scenario-bar.json")
    let outPath = value("--out", default: "build/oracle/app-scenario-bar.json")

    let scenario = try JSONDecoder().decode(
        BarScenario.self, from: Data(contentsOf: URL(fileURLWithPath: scenarioPath))
    )
    let (content, sheet) = try await BarContent.loadForOracle(bundleAt: URL(fileURLWithPath: bundlePath))
    let catalog = content.catalog
    guard let character = content.characters.first(where: { $0.id == scenario.characterID }) else {
        throw EidolonError.invalidContent("场景里的角色 \(scenario.characterID) 不在内容包里")
    }
    guard let listed = content.visits.reasons.first(where: { $0.id == scenario.reasonID }),
          let topic = content.visits.topics.first(where: { $0.id == scenario.topicID }) else {
        throw EidolonError.invalidContent("场景里的来意或话题不在内容包里")
    }
    let formatter = ISO8601DateFormatter()
    guard let now = formatter.date(from: scenario.now) else {
        throw EidolonError.invalidContent("场景的时间无法解析")
    }

    func order(_ fixed: BarScenario.Order) throws -> BarOrder {
        guard let drink = catalog.drink(id: fixed.target) else {
            throw EidolonError.invalidContent("场景里的饮品 \(fixed.target) 不在目录里")
        }
        return BarOrder(
            target: drink,
            phrasing: Phrasing(rawValue: fixed.phrasing) ?? .name,
            said: (fixed.said ?? []).compactMap(Condition.init(rawValue:)),
            usual: Set(fixed.usual ?? [])
        )
    }

    func serving(_ fixed: BarScenario.Serving) throws -> Serving {
        let served: Served?
        if let object = fixed.served.objectValue {
            func number(_ key: String) -> Int { object[key]?.intValue ?? 0 }
            served = catalog.match(Mixture(
                adelhyde: number("adelhyde"), bronsonExtract: number("bronson_extract"),
                powderedDelta: number("powdered_delta"), flanergide: number("flanergide"),
                karmotrine: number("karmotrine"),
                ice: object["ice"] == .bool(true), aged: object["aged"] == .bool(true),
                method: Method(rawValue: object["method"]?.stringValue ?? "mix") ?? .mix
            ))
        } else {
            served = catalog.match(bottle: fixed.served.stringValue ?? "")
        }
        guard let served else {
            throw EidolonError.invalidContent("场景里上的这杯不是任何饮品")
        }
        return Serving(
            order: try order(fixed.order), served: served,
            tier: Tier(rawValue: fixed.tier) ?? .right,
            wrong: fixed.wrong.flatMap(Wrong.init(rawValue:))
        )
    }

    func line(_ fixed: BarScenario.Line) -> BarLine {
        BarLine(
            speaker: fixed.speaker == "producer" ? .producer : .her,
            zh: fixed.zh,
            ja: fixed.ja ?? "",
            emotion: (fixed.emotion ?? "calm").flatMap(StandEmotion.init(rawValue:)) ?? .calm,
            order: fixed.order ?? false
        )
    }

    let rememberedOrders = (scenario.remembered.lastOrders ?? []).map { had in
        Had(
            target: had.target, phrasing: Phrasing(rawValue: had.phrasing) ?? .name,
            served: had.served, big: had.big, tier: Tier(rawValue: had.tier) ?? .right
        )
    }
    let remembered = BarPrompt.Remembered(
        visits: scenario.remembered.visits,
        lastLeftAt: scenario.remembered.lastLeftAt.flatMap(formatter.date(from:)),
        lastOrders: rememberedOrders,
        lastDrunk: scenario.remembered.lastDrunk ?? false
    )

    let shared = BarPrompt.shared(
        sheet: try BarContent.sheet(of: character, in: sheet),
        birthday: BarPrompt.birthday(character), world: scenario.world
    )
    let visit = try BarPrompt.visit(
        aboutProducer: scenario.aboutProducer,
        reason: listed,
        topic: topic,
        cups: scenario.cups,
        affinityLines: scenario.affinityLines ?? [],
        today: scenario.today ?? [],
        remembered: remembered,
        now: now,
        character: character,
        catalog: catalog,
        facts: scenario.facts ?? []
    )
    let written = (scenario.written ?? []).map { call in
        (ask: call.ask, lines: call.lines.map(line))
    }
    /// The last part of one call, as this kind of call writes it.
    func lastPart(_ ask: BarScenario.Ask) throws -> String {
        switch ask.kind {
        case "opening":
            return BarPrompt.openingAsk(try order(ask.order!))
        case "serving":
            return BarPrompt.servingAsk(
                try serving(ask.serving!), enjoy: ask.enjoy ?? "", try order(ask.order!)
            )
        case "farewell":
            return BarPrompt.farewellAsk(
                try serving(ask.serving!), enjoy: ask.enjoy ?? "",
                servings: try (ask.servings ?? []).map(serving), drunk: ask.drunk ?? false
            )
        case "rewrite":
            return BarPrompt.rewriteAsk(
                BarPrompt.openingAsk(try order(ask.order!)), try order(ask.order!),
                before: (ask.before ?? []).map(line)
            )
        default:
            throw EidolonError.invalidContent("场景里的最后一段 \(ask.kind) 不认识")
        }
    }

    let prompt = try (scenario.asks ?? [scenario.ask]).flatMap { ask in
        BarPrompt.prompt(shared: shared, visit: visit, written: written, ask: try lastPart(ask))
    }

    struct Encoded: Encodable {
        var role: String
        var content: String
        var cacheBreakpoint: Bool

        enum CodingKeys: String, CodingKey {
            case role, content
            case cacheBreakpoint = "cache_breakpoint"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
            try container.encode(cacheBreakpoint, forKey: .cacheBreakpoint)
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    let out = URL(fileURLWithPath: outPath)
    try FileManager.default.createDirectory(
        at: out.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    var data = try encoder.encode(prompt.map {
        Encoded(role: $0.role, content: $0.content, cacheBreakpoint: $0.cacheBreakpoint)
    })
    data.append(0x0A)
    try data.write(to: out)
    print("wrote \(outPath) (\(prompt.count) messages)")
}
