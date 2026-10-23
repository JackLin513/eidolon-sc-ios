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

    enum CodingKeys: String, CodingKey {
        case characterID = "character_id"
        case timezone
        case start
        case now
        case history
        case message
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
        tracing: .off
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
