import Foundation
import GRDB

/// What a service bills in (spec #96; upstream `billing.Unit`): a model's tokens, the
/// UTF-8 bytes or characters of text spoken, seconds of audio heard, or a picture.
public enum ServiceUnit: String, Codable, Sendable, CaseIterable, Hashable {
    case tokens
    case bytes
    case characters
    case seconds
    case images

    /// How many of the unit a price is for: a million tokens, bytes or characters, an
    /// hour of audio, one picture.
    public var per: Int {
        switch self {
        case .tokens, .bytes, .characters: 1_000_000
        case .seconds: 3_600
        case .images: 1
        }
    }

    public var title: String {
        switch self {
        case .tokens: "tokens"
        case .bytes: "字节"
        case .characters: "字符"
        case .seconds: "秒"
        case .images: "张"
        }
    }
}

/// The outside services the app calls, as the usage page groups them (spec #96).
public enum ServiceName: String, Codable, Sendable, CaseIterable, Hashable {
    case chat
    case judge
    case emotion
    case embedding
    case rerank
    case speech
    case recognition
    case image

    public var title: String {
        switch self {
        case .chat: "对话模型"
        case .judge: "判断模型"
        case .emotion: "情绪判断"
        case .embedding: "向量"
        case .rerank: "重排"
        case .speech: "语音合成"
        case .recognition: "语音识别"
        case .image: "生图"
        }
    }
}

/// What a call was for, under its service (spec #96). Title, memory, reach-out and the
/// bar are all the chat model, told apart by their operation.
public enum ServiceOperation: String, Codable, Sendable, CaseIterable, Hashable {
    case chatText = "chat_text"
    case chatCall = "chat_call"
    case reachOut = "reach_out"
    case title
    case memory
    case judge
    case emotion
    case embedding
    case rerank
    case speech
    case recognition
    case bar
    case image

    public var title: String {
        switch self {
        case .chatText: "文本回合"
        case .chatCall: "通话回合"
        case .reachOut: "搭话"
        case .title: "标题"
        case .memory: "记忆"
        case .judge: "判断"
        case .emotion: "情绪"
        case .embedding: "向量化"
        case .rerank: "重排"
        case .speech: "语音合成"
        case .recognition: "语音识别"
        case .bar: "酒吧"
        case .image: "生图"
        }
    }
}

/// One call to an outside service, written when it returns (spec #96). `input` and
/// `output` are in `unit`; `estimated` says the numbers are a local estimate rather than
/// what the service reported.
public struct ServiceCall: Sendable, Hashable {
    public var at: Date
    public var service: ServiceName
    /// The host the service is at, the key the price catalog uses: `api.deepseek.com`.
    public var provider: String
    public var model: String
    public var operation: ServiceOperation
    public var unit: ServiceUnit
    public var input: Int
    public var output: Int?
    public var cachedInput: Int?
    public var estimated: Bool
    public var latency: Double?
    public var error: String?
    public var conversationID: String?
    public var callID: String?

    public init(
        at: Date = Date(),
        service: ServiceName,
        provider: String,
        model: String,
        operation: ServiceOperation,
        unit: ServiceUnit,
        input: Int,
        output: Int? = nil,
        cachedInput: Int? = nil,
        estimated: Bool = false,
        latency: Double? = nil,
        error: String? = nil,
        conversationID: String? = nil,
        callID: String? = nil
    ) {
        self.at = at
        self.service = service
        self.provider = provider
        self.model = model
        self.operation = operation
        self.unit = unit
        self.input = input
        self.output = output
        self.cachedInput = cachedInput
        self.estimated = estimated
        self.latency = latency
        self.error = error
        self.conversationID = conversationID
        self.callID = callID
    }
}

/// The local token estimate used when a service does not report what it read (spec #96):
/// a CJK character counts as one token, other non-space text as its UTF-8 bytes over
/// four, and spaces count for nothing.
public enum UsageEstimate {
    public static func tokens(_ text: String) -> Int {
        var cjk = 0
        var otherBytes = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            if isCJK(scalar) {
                cjk += 1
            } else {
                otherBytes += String(scalar).utf8.count
            }
        }
        return cjk + Int((Double(otherBytes) / 4).rounded(.up))
    }

    public static func tokens(_ messages: [PromptMessage]) -> Int {
        tokens(messages.map(\.content).joined(separator: "\n"))
    }

    public static func tokens(_ texts: [String]) -> Int {
        tokens(texts.joined(separator: "\n"))
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana and katakana
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK unified ideographs
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xAC00...0xD7AF:   // Hangul syllables
            true
        default:
            false
        }
    }
}

// MARK: - Prices

/// A price for one provider, model and unit (spec #96; upstream `prices.Price`). The
/// amount is for `unit.per` units; a missing output price means output costs as input
/// does, and a missing cached-input price means cached input does too.
public struct PriceRate: Sendable, Hashable {
    public var input: Decimal
    public var output: Decimal?
    public var cachedInput: Decimal?
    public var currency: String
    /// When the price was gathered or set, as `yyyy-MM-dd`.
    public var asOf: String

    public init(
        input: Decimal,
        output: Decimal? = nil,
        cachedInput: Decimal? = nil,
        currency: String,
        asOf: String
    ) {
        self.input = input
        self.output = output
        self.cachedInput = cachedInput
        self.currency = currency
        self.asOf = asOf
    }

    /// What this usage costs at this price: cached input at its own price, the rest of the
    /// input at the input price, output at its own price or the input's.
    public func cost(
        input: Int,
        output: Int?,
        cachedInput: Int?,
        unit: ServiceUnit
    ) -> Decimal {
        let hit = min(max(cachedInput ?? 0, 0), max(input, 0))
        let rest = max(input, 0) - hit
        let outputRate = self.output ?? self.input
        let cacheRate = self.cachedInput ?? self.input
        let total = Decimal(rest) * self.input
            + Decimal(hit) * cacheRate
            + Decimal(max(output ?? 0, 0)) * outputRate
        return total / Decimal(unit.per)
    }
}

public struct PriceKey: Sendable, Hashable {
    public var provider: String
    public var model: String
    public var unit: ServiceUnit

    public init(provider: String, model: String, unit: ServiceUnit) {
        self.provider = provider
        self.model = model
        self.unit = unit
    }
}

/// A price in effect, and where it comes from: a price the producer set, a built-in
/// preset, or a local host that costs nothing.
public struct PriceListing: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable {
        case override
        case preset
        case local
    }

    public var key: PriceKey
    public var rate: PriceRate
    public var source: Source

    public init(key: PriceKey, rate: PriceRate, source: Source) {
        self.key = key
        self.rate = rate
        self.source = source
    }
}

/// One row of the price editor: a provider, model and unit, its price in effect if any,
/// and where that price comes from.
public struct PriceEditorRow: Sendable, Hashable, Identifiable {
    public var key: PriceKey
    public var listing: PriceListing?

    public var id: String { "\(key.provider)|\(key.model)|\(key.unit.rawValue)" }
    public var rate: PriceRate? { listing?.rate }
    public var source: PriceListing.Source? { listing?.source }

    public init(key: PriceKey, listing: PriceListing?) {
        self.key = key
        self.listing = listing
    }
}

/// The built-in catalog: upstream's presets gathered on 2026-10-07, plus DeepSeek's names,
/// Gemini's chat prices read from Google AI Studio on 2026-11-04, and Bailian's real-time
/// transcription from its billing page the same day. A price that changes later is what the
/// override page is for (spec #96).
public enum PriceCatalog {
    public static let gathered = "2026-10-07"

    public static let presets: [PriceKey: PriceRate] = {
        var prices: [PriceKey: PriceRate] = [:]
        func tokens(
            _ provider: String,
            _ models: [String: (Decimal, Decimal?, Decimal?)],
            _ currency: String,
            asOf: String = gathered
        ) {
            for (model, price) in models {
                prices[PriceKey(provider: provider, model: model, unit: .tokens)] = PriceRate(
                    input: price.0, output: price.1, cachedInput: price.2,
                    currency: currency, asOf: asOf
                )
            }
        }
        tokens("api.openai.com", [
            "gpt-6-astra": (10, 50, 1),
            "gpt-6.1-sol": (2, 10, Decimal(string: "0.1")!),
            "gpt-6-sol": (2, 10, Decimal(string: "0.2")!),
            "gpt-6-luna": (Decimal(string: "0.1")!, Decimal(string: "0.5")!, Decimal(string: "0.01")!),
            "gpt-5.6-sol": (4, 20, Decimal(string: "0.4")!),
            "gpt-5.4-mini": (Decimal(string: "0.75")!, Decimal(string: "4.5")!, Decimal(string: "0.075")!),
        ], "USD")
        tokens("api.anthropic.com", [
            "claude-fable-5-1": (10, 50, Decimal(string: "0.25")!),
            "claude-opus-5-5": (4, 20, Decimal(string: "0.2")!),
            "claude-sonnet-5-5": (2, 10, Decimal(string: "0.1")!),
            "claude-haiku-4-5": (1, 5, Decimal(string: "0.1")!),
            "claude-haiku-4-5-20251001": (1, 5, Decimal(string: "0.1")!),
        ], "USD")
        tokens("api.deepseek.com", [
            "deepseek-flash": (2, 8, Decimal(string: "0.04")!),
            "deepseek-v4-flash": (2, 8, Decimal(string: "0.04")!),
            "deepseek-v4-pro": (9, 27, Decimal(string: "0.3")!),
        ], "CNY")
        for (model, price) in ["s2.1-pro-free": 0, "s2.1-pro": 15, "s2-pro": 15, "s1": 15] {
            prices[PriceKey(provider: "api.fish.audio", model: model, unit: .bytes)] = PriceRate(
                input: Decimal(price), currency: "USD", asOf: gathered
            )
        }
        prices[PriceKey(provider: "api.fish.audio", model: "drama-3", unit: .characters)] =
            PriceRate(input: 50, currency: "USD", asOf: "2026-10-17")
        prices[PriceKey(provider: "stt-rt.soniox.com", model: "stt-rt-v5", unit: .seconds)] =
            PriceRate(input: Decimal(string: "0.12")!, currency: "USD", asOf: gathered)
        // Bailian's real-time transcription (checked 2026-11-04). 3.0 is billed per audio
        // second at ¥0.00033 (Beijing). 3.1 is billed in tokens at ¥6/¥4.5 per million;
        // with the audio rule of 25 tokens per second that is ¥0.00015 of input a second
        // (¥0.54 an hour), an estimate because the text output is not recorded here.
        prices[PriceKey(
            provider: "dashscope.aliyuncs.com",
            model: "qwen-audio-3.0-asr-flash-streaming",
            unit: .seconds
        )] = PriceRate(
            input: Decimal(string: "1.188")!, currency: "CNY", asOf: "2026-11-04"
        )
        prices[PriceKey(
            provider: "dashscope.aliyuncs.com",
            model: "qwen-audio-3.1-asr-flash-streaming",
            unit: .seconds
        )] = PriceRate(
            input: Decimal(string: "0.54")!, currency: "CNY", asOf: "2026-11-04"
        )
        tokens("openrouter.ai", [
            "typesafe/jev-1.13": (Decimal(string: "0.042")!, 0, nil),
            "cloudflare/clef": (Decimal(string: "0.24")!, 0, nil),
            "cloudflare/clef-flash": (Decimal(string: "0.09")!, 0, nil),
        ], "USD")
        tokens("api.cloudflare.com", [
            "clef": (Decimal(string: "0.24")!, nil, nil),
            "clef-flash": (Decimal(string: "0.09")!, nil, nil),
        ], "USD")
        tokens("cn-beijing.maas.aliyuncs.com", ["decision-model-preview": (0, nil, nil)], "CNY")
        tokens("ap-southeast-1.maas.aliyuncs.com", ["decision-model-preview": (0, nil, nil)], "USD")
        tokens("api.siliconflow.cn", [
            "Qwen/Qwen3-Embedding-0.6B": (Decimal(string: "0.07")!, nil, nil),
            "Qwen/Qwen3-Embedding-4B": (Decimal(string: "0.14")!, nil, nil),
            "Qwen/Qwen3-Embedding-8B": (Decimal(string: "0.28")!, nil, nil),
            "Qwen/Qwen3-Reranker-0.6B": (Decimal(string: "0.07")!, nil, nil),
            "Qwen/Qwen3-Reranker-4B": (Decimal(string: "0.14")!, nil, nil),
            "Qwen/Qwen3-Reranker-8B": (Decimal(string: "0.28")!, nil, nil),
        ], "CNY", asOf: "2026-10-07")
        prices[PriceKey(
            provider: "generativelanguage.googleapis.com",
            model: "gemini-embedding-2",
            unit: .tokens
        )] = PriceRate(input: Decimal(string: "0.2")!, currency: "USD", asOf: gathered)
        // Gemini's chat models, from Google AI Studio's pricing page (checked 2026-11-04):
        // standard (not batch) prices in USD per million tokens, for prompts up to 200k.
        // The introductory prices shown for 4-argon and 3.8/3.6-flash are the ones in
        // effect today; when a promotion ends, the producer changes the price on the
        // price page.
        tokens("generativelanguage.googleapis.com", [
            "gemini-4-argon": (2, 10, Decimal(string: "0.1")!),
            "gemini-3.8-flash": (Decimal(string: "0.75")!, Decimal(string: "3.75")!, Decimal(string: "0.075")!),
            "gemini-3.6-flash": (Decimal(string: "0.75")!, Decimal(string: "3.75")!, Decimal(string: "0.075")!),
            "gemini-3.5-flash-lite": (Decimal(string: "0.3")!, Decimal(string: "2.5")!, Decimal(string: "0.03")!),
            "gemini-3.1-flash-lite": (Decimal(string: "0.25")!, Decimal(string: "1.5")!, Decimal(string: "0.025")!),
            "gemini-3.1-pro-preview": (2, 12, Decimal(string: "0.2")!),
            "gemini-3.1-pro-preview-customtools": (2, 12, Decimal(string: "0.2")!),
            "gemini-3-flash-preview": (Decimal(string: "0.5")!, 3, Decimal(string: "0.05")!),
            "gemini-2.5-pro": (Decimal(string: "1.25")!, 10, Decimal(string: "0.125")!),
            "gemini-2.5-flash": (Decimal(string: "0.3")!, Decimal(string: "2.5")!, Decimal(string: "0.03")!),
            "gemini-2.5-flash-lite": (Decimal(string: "0.1")!, Decimal(string: "0.4")!, Decimal(string: "0.01")!),
        ], "USD", asOf: "2026-11-04")
        prices[PriceKey(
            provider: "image.novelai.net",
            model: "nai-diffusion-5-curated",
            unit: .images
        )] = PriceRate(input: Decimal(string: "0.036")!, currency: "USD", asOf: "2026-10-17")
        prices[PriceKey(provider: "api.openai.com", model: "gpt-image-2", unit: .images)] =
            PriceRate(input: Decimal(string: "0.041")!, currency: "USD", asOf: "2026-11-01")
        return prices
    }()

    /// A model recorded with its dimensions (`gemini-embedding-2@1536`) is the model.
    static func undimensioned(_ model: String) -> String {
        String(model.split(separator: "@", maxSplits: 1).first ?? "")
    }

    static func preset(for key: PriceKey) -> PriceRate? {
        let provider = canonicalHost(key.provider)
        let normalized = PriceKey(
            provider: provider, model: key.model, unit: key.unit
        )
        if let exact = presets[normalized] { return exact }
        let plain = undimensioned(key.model)
        guard plain != key.model else { return nil }
        return presets[PriceKey(provider: provider, model: plain, unit: key.unit)]
    }

    /// Bailian's judge is at a workspace host (`<workspace>.cn-beijing.maas.aliyuncs.com`),
    /// while its preset is keyed by the region's service host.
    static func canonicalHost(_ provider: String) -> String {
        for host in ["cn-beijing.maas.aliyuncs.com", "ap-southeast-1.maas.aliyuncs.com"]
        where provider.hasSuffix("." + host) {
            return host
        }
        return provider
    }

    /// A host on this phone or its own network costs nothing: the local 5090 model.
    static func isLocal(_ provider: String) -> Bool {
        let host = provider.lowercased()
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") { return true }
        if host.hasPrefix("172."), let second = host.split(separator: ".").dropFirst().first,
           let octet = Int(second), (16...31).contains(octet) {
            return true
        }
        // Tailscale's CGNAT range, where the user's 5090 is reached.
        if host.hasPrefix("100."), let second = host.split(separator: ".").dropFirst().first,
           let octet = Int(second), (64...127).contains(octet) {
            return true
        }
        return host.hasSuffix(".local") || host.hasSuffix(".ts.net")
    }
}

// MARK: - The ledger

extension Eidolon {
    /// Writes one outside call down. It never belongs to a conversation by reference: a
    /// deleted conversation keeps what it cost (spec #96).
    public func recordServiceCall(_ call: ServiceCall) throws {
        try Self.writeServiceCall(call, to: userQueue)
    }

    /// The same write without hopping onto the actor, for the call session's ending (spec
    /// #96): it records the recognizer's seconds before the call page goes away.
    public nonisolated func recordServiceCallNow(_ call: ServiceCall) {
        try? Self.writeServiceCall(call, to: userQueue)
    }

    private static func writeServiceCall(_ call: ServiceCall, to queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO service_calls(
                        at, service, provider, model, operation, unit,
                        input, output, cached_input, estimated, latency, error,
                        conversation_id, call_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    timestamp(call.at), call.service.rawValue, call.provider, call.model,
                    call.operation.rawValue, call.unit.rawValue, call.input, call.output,
                    call.cachedInput, call.estimated ? 1 : 0, call.latency, call.error,
                    call.conversationID, call.callID,
                ]
            )
        }
    }

    /// Every call written, newest first, for the tests that drive the instrumentation.
    func serviceCalls(limit: Int = 10_000) throws -> [ServiceCall] {
        try userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM service_calls ORDER BY at DESC, id DESC LIMIT ?",
                arguments: [limit]
            ).compactMap(Self.serviceCall(row:))
        }
    }

    /// Forgets every call. Prices and overrides stay (spec #96).
    public func clearServiceCalls() throws {
        try userQueue.write { db in
            try db.execute(sql: "DELETE FROM service_calls")
        }
    }

    static func serviceCall(row: Row) -> ServiceCall? {
        guard let at = parseTimestamp(row["at"]),
              let service = ServiceName(rawValue: row["service"]),
              let operation = ServiceOperation(rawValue: row["operation"]),
              let unit = ServiceUnit(rawValue: row["unit"])
        else { return nil }
        return ServiceCall(
            at: at,
            service: service,
            provider: row["provider"],
            model: row["model"],
            operation: operation,
            unit: unit,
            input: row["input"],
            output: row["output"],
            cachedInput: row["cached_input"],
            estimated: (row["estimated"] as Int) == 1,
            latency: row["latency"],
            error: row["error"],
            conversationID: row["conversation_id"],
            callID: row["call_id"]
        )
    }

    // MARK: Prices

    public func priceOverrides() throws -> [PriceKey: PriceRate] {
        try userQueue.read { db in try Self.priceOverrides(db) }
    }

    /// The price in effect for a provider, model and unit: the producer's override, else
    /// the built-in preset, else nothing (shown as 未设单价); a local host costs 0.
    public func price(for key: PriceKey) throws -> PriceListing? {
        try price(for: key, overrides: priceOverrides())
    }

    private func price(
        for key: PriceKey,
        overrides: [PriceKey: PriceRate]
    ) -> PriceListing? {
        if let rate = overrides[key] {
            return PriceListing(key: key, rate: rate, source: .override)
        }
        if let rate = PriceCatalog.preset(for: key) {
            return PriceListing(key: key, rate: rate, source: .preset)
        }
        if PriceCatalog.isLocal(key.provider) {
            return PriceListing(
                key: key,
                rate: PriceRate(input: 0, output: 0, cachedInput: 0, currency: "CNY", asOf: "本地"),
                source: .local
            )
        }
        return nil
    }

    /// Every price the editor can show: built-in, overridden, and the models actually used
    /// that have no price yet (so one can be set).
    public func priceEditorRows() throws -> [PriceEditorRow] {
        try userQueue.read { db in
            let overrides = try Self.priceOverrides(db)
            let usedRows = try Row.fetchAll(
                db,
                sql: "SELECT DISTINCT provider, model, unit FROM service_calls"
            )
            var keys = Set(PriceCatalog.presets.keys)
            keys.formUnion(overrides.keys)
            for row in usedRows {
                guard let unit = ServiceUnit(rawValue: row["unit"]) else { continue }
                keys.insert(PriceKey(provider: row["provider"], model: row["model"], unit: unit))
            }
            return keys.map { key -> PriceEditorRow in
                let listing = price(for: key, overrides: overrides)
                return PriceEditorRow(key: key, listing: listing)
            }.sorted {
                ($0.key.provider, $0.key.model, $0.key.unit.rawValue)
                    < ($1.key.provider, $1.key.model, $1.key.unit.rawValue)
            }
        }
    }

    public func setPriceOverride(
        _ key: PriceKey,
        input: Decimal,
        output: Decimal?,
        cachedInput: Decimal?,
        currency: String,
        now: Date = Date()
    ) throws {
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO price_overrides(
                        provider, model, unit, input, output, cached_input, currency, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider, model, unit) DO UPDATE SET
                        input = excluded.input,
                        output = excluded.output,
                        cached_input = excluded.cached_input,
                        currency = excluded.currency,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    key.provider, key.model, key.unit.rawValue, NSDecimalNumber(decimal: input),
                    output.map { NSDecimalNumber(decimal: $0) },
                    cachedInput.map { NSDecimalNumber(decimal: $0) },
                    currency, Self.timestamp(now),
                ]
            )
        }
    }

    public func clearPriceOverride(_ key: PriceKey) throws {
        try userQueue.write { db in
            try db.execute(
                sql: "DELETE FROM price_overrides WHERE provider = ? AND model = ? AND unit = ?",
                arguments: [key.provider, key.model, key.unit.rawValue]
            )
        }
    }

    static func priceOverrides(_ db: Database) throws -> [PriceKey: PriceRate] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM price_overrides")
        var prices: [PriceKey: PriceRate] = [:]
        for row in rows {
            guard let unit = ServiceUnit(rawValue: row["unit"]) else { continue }
            let key = PriceKey(provider: row["provider"], model: row["model"], unit: unit)
            prices[key] = PriceRate(
                input: Decimal(row["input"] as Double),
                output: (row["output"] as Double?).map { Decimal($0) },
                cachedInput: (row["cached_input"] as Double?).map { Decimal($0) },
                currency: row["currency"],
                asOf: String((row["updated_at"] as String).prefix(10))
            )
        }
        return prices
    }
}

// MARK: - Usage stats

/// The usage page reads the same spans as the stats page; one enum keeps their titles and
/// day counts from drifting apart.
public typealias UsageRange = StatsRange

public struct UsageMoney: Sendable, Hashable {
    public var currency: String
    public var amount: Decimal

    public init(currency: String, amount: Decimal) {
        self.currency = currency
        self.amount = amount
    }
}

public struct UsageModelSummary: Sendable, Hashable, Identifiable {
    public var provider: String
    public var model: String
    public var unit: ServiceUnit
    public var calls: Int
    public var input: Int
    public var output: Int
    public var cachedInput: Int
    public var estimatedCalls: Int
    public var price: PriceListing?
    public var amounts: [UsageMoney]

    public var id: String { "\(provider)|\(model)|\(unit.rawValue)" }

    public var isPriced: Bool { price != nil }
}

public struct UsageServiceSummary: Sendable, Hashable, Identifiable {
    public var service: ServiceName
    public var calls: Int
    public var input: Int
    public var output: Int
    public var cachedInput: Int
    public var estimatedCalls: Int
    public var unpricedCalls: Int
    public var amounts: [UsageMoney]
    public var models: [UsageModelSummary]

    public var id: String { service.rawValue }
    public var isPriced: Bool { unpricedCalls == 0 }
}

public struct UsageDay: Sendable, Hashable, Identifiable {
    public var day: CalendarDay
    public var calls: Int
    public var input: Int
    public var output: Int
    public var amounts: [UsageMoney]

    public var id: String { day.stamp }
}

/// What the usage page reads in one go (spec #96): every call in the range, grouped by
/// service and model and by day, priced at today's prices.
public struct UsageStats: Sendable, Hashable {
    public var range: UsageRange
    public var from: CalendarDay
    public var to: CalendarDay
    public var calls: Int
    public var estimatedCalls: Int
    public var unpricedCalls: Int
    public var amounts: [UsageMoney]
    public var services: [UsageServiceSummary]
    public var days: [UsageDay]
    /// The built-in catalog's gathering date, for the page's note.
    public var pricesAsOf: String
    /// Whether the range has calls.
    public var hasAny: Bool { calls > 0 }
    /// Whether the ledger has any calls at all, even outside the range.
    public var hasRecords: Bool

    public init(
        range: UsageRange,
        from: CalendarDay,
        to: CalendarDay,
        calls: Int,
        estimatedCalls: Int,
        unpricedCalls: Int,
        amounts: [UsageMoney],
        services: [UsageServiceSummary],
        days: [UsageDay],
        pricesAsOf: String,
        hasRecords: Bool
    ) {
        self.range = range
        self.from = from
        self.to = to
        self.calls = calls
        self.estimatedCalls = estimatedCalls
        self.unpricedCalls = unpricedCalls
        self.amounts = amounts
        self.services = services
        self.days = days
        self.pricesAsOf = pricesAsOf
        self.hasRecords = hasRecords
    }
}

extension Eidolon {
    public func usageStats(
        range: UsageRange,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> UsageStats {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = Self.calendarDay(now, in: timeZone)
        let start = range.days.map { days in
            Self.calendarDay(
                calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now,
                in: timeZone
            )
        }

        return try userQueue.read { db in
            let overrides = try Self.priceOverrides(db)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM service_calls ORDER BY at ASC, id ASC"
            ).compactMap(Self.serviceCall(row:))

            let earliest = rows.first.map {
                Self.calendarDay($0.at, in: timeZone)
            }
            guard let from = start ?? earliest else {
                return UsageStats(
                    range: range, from: today, to: today, calls: 0, estimatedCalls: 0,
                    unpricedCalls: 0, amounts: [], services: [], days: [],
                    pricesAsOf: PriceCatalog.gathered, hasRecords: false
                )
            }

            let within = rows.filter {
                let day = Self.calendarDay($0.at, in: timeZone)
                return day >= from && day <= today
            }

            var grouped: [GroupKey: Group] = [:]
            for call in within {
                let key = GroupKey(
                    service: call.service, provider: call.provider, model: call.model,
                    unit: call.unit
                )
                var group = grouped[key] ?? Group()
                group.calls += 1
                group.input += call.input
                group.output += call.output ?? 0
                group.cachedInput += call.cachedInput ?? 0
                if call.estimated { group.estimatedCalls += 1 }
                group.callsByDay[Self.calendarDay(call.at, in: timeZone), default: 0] += 1
                group.inputByDay[Self.calendarDay(call.at, in: timeZone), default: 0] += call.input
                group.outputByDay[Self.calendarDay(call.at, in: timeZone), default: 0] +=
                    call.output ?? 0
                group.cachedByDay[Self.calendarDay(call.at, in: timeZone), default: 0] +=
                    call.cachedInput ?? 0
                grouped[key] = group
            }

            // Resolve each model's price once; the service and daily loops both read it.
            var priceCache: [GroupKey: PriceListing] = [:]
            var unpricedKeys = Set<GroupKey>()
            func priceFor(_ key: GroupKey) -> PriceListing? {
                if let cached = priceCache[key] { return cached }
                if unpricedKeys.contains(key) { return nil }
                let listing = price(
                    for: PriceKey(
                        provider: key.provider, model: key.model, unit: key.unit
                    ),
                    overrides: overrides
                )
                if let listing { priceCache[key] = listing } else { unpricedKeys.insert(key) }
                return listing
            }

            var services: [UsageServiceSummary] = []
            var totals: [String: Decimal] = [:]
            var unpricedCalls = 0
            var estimatedCalls = 0

            for service in ServiceName.allCases {
                let groups = grouped.filter { $0.key.service == service }
                    .sorted { ($0.key.provider, $0.key.model, $0.key.unit.rawValue)
                        < ($1.key.provider, $1.key.model, $1.key.unit.rawValue) }
                guard !groups.isEmpty else { continue }
                var models: [UsageModelSummary] = []
                var serviceAmounts: [String: Decimal] = [:]
                var serviceCalls = 0
                var serviceInput = 0
                var serviceOutput = 0
                var serviceCached = 0
                var serviceEstimated = 0
                var serviceUnpriced = 0
                for (key, group) in groups {
                    let listing = priceFor(key)
                    var amounts: [String: Decimal] = [:]
                    if let listing {
                        let amount = listing.rate.cost(
                            input: group.input, output: group.output,
                            cachedInput: group.cachedInput, unit: key.unit
                        )
                        amounts[listing.rate.currency] = amount
                    } else {
                        serviceUnpriced += group.calls
                        unpricedCalls += group.calls
                    }
                    modelAmounts(amounts, into: &serviceAmounts)
                    models.append(
                        UsageModelSummary(
                            provider: key.provider, model: key.model, unit: key.unit,
                            calls: group.calls, input: group.input, output: group.output,
                            cachedInput: group.cachedInput,
                            estimatedCalls: group.estimatedCalls,
                            price: listing, amounts: Self.money(amounts)
                        )
                    )
                    serviceCalls += group.calls
                    serviceInput += group.input
                    serviceOutput += group.output
                    serviceCached += group.cachedInput
                    serviceEstimated += group.estimatedCalls
                }
                modelAmounts(serviceAmounts, into: &totals)
                estimatedCalls += serviceEstimated
                services.append(
                    UsageServiceSummary(
                        service: service, calls: serviceCalls, input: serviceInput,
                        output: serviceOutput, cachedInput: serviceCached,
                        estimatedCalls: serviceEstimated, unpricedCalls: serviceUnpriced,
                        amounts: Self.money(serviceAmounts), models: models
                    )
                )
            }

            var days: [UsageDay] = []
            var day = from
            while day <= today {
                let calls = grouped.values.reduce(0) { $0 + ($1.callsByDay[day] ?? 0) }
                let input = grouped.values.reduce(0) { $0 + ($1.inputByDay[day] ?? 0) }
                let output = grouped.values.reduce(0) { $0 + ($1.outputByDay[day] ?? 0) }
                var amounts: [String: Decimal] = [:]
                for (key, group) in grouped {
                    guard let count = group.callsByDay[day], count > 0 else { continue }
                    guard let listing = priceFor(key) else { continue }
                    let amount = listing.rate.cost(
                        input: group.inputByDay[day] ?? 0,
                        output: group.outputByDay[day] ?? 0,
                        cachedInput: group.cachedByDay[day] ?? 0, unit: key.unit
                    )
                    amounts[listing.rate.currency, default: 0] += amount
                }
                days.append(
                    UsageDay(
                        day: day, calls: calls, input: input, output: output,
                        amounts: Self.money(amounts)
                    )
                )
                day = day.adding(days: 1)
            }

            return UsageStats(
                range: range, from: from, to: today,
                calls: within.count,
                estimatedCalls: estimatedCalls,
                unpricedCalls: unpricedCalls,
                amounts: Self.money(totals),
                services: services,
                days: days,
                pricesAsOf: PriceCatalog.gathered,
                hasRecords: !rows.isEmpty
            )
        }
    }

    private struct GroupKey: Hashable {
        var service: ServiceName
        var provider: String
        var model: String
        var unit: ServiceUnit
    }

    private struct Group {
        var calls = 0
        var input = 0
        var output = 0
        var cachedInput = 0
        var estimatedCalls = 0
        var callsByDay: [CalendarDay: Int] = [:]
        var inputByDay: [CalendarDay: Int] = [:]
        var outputByDay: [CalendarDay: Int] = [:]
        var cachedByDay: [CalendarDay: Int] = [:]
    }

    private static func money(_ amounts: [String: Decimal]) -> [UsageMoney] {
        amounts.filter { $0.value != 0 }
            .map { UsageMoney(currency: $0.key, amount: $0.value) }
            .sorted { $0.currency < $1.currency }
    }

    private func modelAmounts(_ from: [String: Decimal], into totals: inout [String: Decimal]) {
        for (currency, amount) in from {
            totals[currency, default: 0] += amount
        }
    }

    static func calendarDay(_ date: Date, in timeZone: TimeZone) -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDay(
            year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1
        )
    }
}

// MARK: - Recording helpers

/// A provider that can say which host and model it is talking to, for the ledger when the
/// service does not report usage itself (spec #96).
public protocol ServiceMetadata: Sendable {
    var serviceHost: String? { get }
    var serviceModel: String? { get }
}

/// What an embedding or rerank service reported for its last request(s).
public protocol EmbeddingUsageReporting: Sendable {
    func takeEmbeddingUsage() async -> ChatUsage?
}

public protocol RerankUsageReporting: Sendable {
    func takeRerankUsage() async -> ChatUsage?
}

/// Builds the ledger row for one chat-model request, using what the service reported and
/// estimating only what it did not (spec #96). Shared with the bar, which records through
/// its setup rather than through the core actor.
public enum UsageRecording {
    public static func chatCall(
        provider: any ChatProvider,
        operation: ServiceOperation,
        prompts: [[PromptMessage]],
        output: String,
        latency: Double?,
        error: String?,
        conversationID: String? = nil,
        at: Date,
        service: ServiceName = .chat
    ) async -> ServiceCall {
        let reporter = provider as? any ChatUsageReporting
        let reported = await reporter?.takeUsage()
        let metadata = provider as? any ServiceMetadata
        return ServiceCall(
            at: at,
            service: service,
            provider: reporter?.usageProviderHost ?? metadata?.serviceHost ?? "",
            model: reporter?.usageModel ?? metadata?.serviceModel ?? "",
            operation: operation,
            unit: .tokens,
            input: reported?.input ?? UsageEstimate.tokens(prompts.flatMap { $0 }),
            output: reported?.output ?? UsageEstimate.tokens(output),
            cachedInput: reported?.cachedInput,
            estimated: reported == nil,
            latency: latency,
            error: error,
            conversationID: conversationID
        )
    }
}

extension Eidolon {
    /// Writes one chat-model request, using what the service reported and estimating only
    /// what it did not (spec #96).
    func recordChatCall(
        provider: any ChatProvider,
        operation: ServiceOperation,
        prompts: [[PromptMessage]],
        output: String,
        latency: Double?,
        error: String?,
        conversationID: String?,
        callID: String? = nil,
        at: Date,
        service: ServiceName = .chat
    ) async {
        var call = await UsageRecording.chatCall(
            provider: provider, operation: operation, prompts: prompts, output: output,
            latency: latency, error: error, conversationID: conversationID, at: at,
            service: service
        )
        call.callID = callID
        try? recordServiceCall(call)
    }

    /// Writes one judged turn. The judge reports its input tokens where the service does;
    /// the output is estimated from the answer it wrote.
    func recordJudgeCall(
        judge: any JudgeProvider,
        inputText: String,
        outputText: String?,
        inputTokens: Int?,
        latency: Double?,
        error: String?,
        conversationID: String?,
        at: Date
    ) async {
        let metadata = judge as? any ServiceMetadata
        let estimatedOutput = UsageEstimate.tokens(outputText ?? "")
        let input = inputTokens ?? UsageEstimate.tokens(inputText)
        let call = ServiceCall(
            at: at, service: .judge,
            provider: metadata?.serviceHost ?? "",
            model: judge.judgeModel.isEmpty ? (metadata?.serviceModel ?? "") : judge.judgeModel,
            operation: .judge, unit: .tokens,
            input: input, output: outputText == nil ? nil : estimatedOutput,
            cachedInput: nil,
            estimated: inputTokens == nil || outputText != nil,
            latency: latency, error: error, conversationID: conversationID
        )
        try? recordServiceCall(call)
    }

    func recordEmotionCall(
        judge: any SegmentEmotionJudge,
        segment: SegmentToJudge,
        judged: SegmentEmotion?,
        latency: Double?,
        conversationID: String?
    ) {
        let metadata = judge as? any ServiceMetadata
        let input = UsageEstimate.tokens(segment.segment.ja + "\n" + segment.segment.zh)
        let call = ServiceCall(
            at: Date(), service: .emotion,
            provider: metadata?.serviceHost ?? "",
            model: metadata?.serviceModel ?? "",
            operation: .emotion, unit: .tokens,
            input: input,
            output: judged == nil ? nil : UsageEstimate.tokens(segment.segment.zh),
            estimated: true, latency: latency, error: judged == nil ? "没有判断结果" : nil,
            conversationID: conversationID
        )
        try? recordServiceCall(call)
    }

    func recordEmbeddingCall(
        _ provider: any EmbeddingProvider,
        texts: [String],
        latency: Double?,
        error: String?
    ) async {
        let reporter = provider as? any EmbeddingUsageReporting
        let reported = await reporter?.takeEmbeddingUsage()
        let metadata = provider as? any ServiceMetadata
        let call = ServiceCall(
            at: Date(), service: .embedding,
            provider: metadata?.serviceHost ?? "", model: provider.model,
            operation: .embedding, unit: .tokens,
            input: reported?.input ?? UsageEstimate.tokens(texts),
            output: nil,
            estimated: reported == nil,
            latency: latency, error: error
        )
        try? recordServiceCall(call)
    }

    func recordRerankCall(
        _ provider: any RerankProvider,
        query: String,
        documents: [String],
        latency: Double?,
        error: String?
    ) async {
        let reporter = provider as? any RerankUsageReporting
        let reported = await reporter?.takeRerankUsage()
        let metadata = provider as? any ServiceMetadata
        let call = ServiceCall(
            at: Date(), service: .rerank,
            provider: metadata?.serviceHost ?? "", model: provider.model,
            operation: .rerank, unit: .tokens,
            input: reported?.input ?? UsageEstimate.tokens([query] + documents),
            output: nil,
            estimated: reported == nil,
            latency: latency, error: error
        )
        try? recordServiceCall(call)
    }
}

/// Wraps an embedding service so every public call is written down (spec #96); a provider
/// that reports input tokens is used as reported, everything else as an estimate.
public struct RecordingEmbedding: EmbeddingProvider {
    private let base: any EmbeddingProvider
    private let eidolon: Eidolon

    public init(base: any EmbeddingProvider, eidolon: Eidolon) {
        self.base = base
        self.eidolon = eidolon
    }

    public var model: String { base.model }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        let started = Date()
        do {
            let vectors = try await base.embed(texts)
            await eidolon.recordEmbeddingCall(
                base, texts: texts, latency: Date().timeIntervalSince(started), error: nil
            )
            return vectors
        } catch {
            await eidolon.recordEmbeddingCall(
                base, texts: texts, latency: Date().timeIntervalSince(started),
                error: error.localizedDescription
            )
            throw error
        }
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        let started = Date()
        do {
            let vector = try await base.embedQuery(text)
            await eidolon.recordEmbeddingCall(
                base, texts: [text], latency: Date().timeIntervalSince(started), error: nil
            )
            return vector
        } catch {
            await eidolon.recordEmbeddingCall(
                base, texts: [text], latency: Date().timeIntervalSince(started),
                error: error.localizedDescription
            )
            throw error
        }
    }
}

/// Wraps a reranker the same way.
public struct RecordingRerank: RerankProvider {
    private let base: any RerankProvider
    private let eidolon: Eidolon

    public init(base: any RerankProvider, eidolon: Eidolon) {
        self.base = base
        self.eidolon = eidolon
    }

    public var model: String { base.model }

    public func rerank(
        query: String, documents: [String]
    ) async throws -> [(index: Int, score: Double)] {
        let started = Date()
        do {
            let ranked = try await base.rerank(query: query, documents: documents)
            await eidolon.recordRerankCall(
                base, query: query, documents: documents,
                latency: Date().timeIntervalSince(started), error: nil
            )
            return ranked
        } catch {
            await eidolon.recordRerankCall(
                base, query: query, documents: documents,
                latency: Date().timeIntervalSince(started), error: error.localizedDescription
            )
            throw error
        }
    }
}

/// Wraps a text-to-speech service so every segment is written down in the unit Fish Audio
/// charges in: characters for drama-3, UTF-8 bytes for the other voices (spec #96).
public struct RecordingSpeech: SpeechSynthesis {
    private let base: any SpeechSynthesis
    private let providerHost: String
    private let record: @Sendable (ServiceCall) async -> Void

    public init(
        base: any SpeechSynthesis,
        providerHost: String = "api.fish.audio",
        record: @escaping @Sendable (ServiceCall) async -> Void
    ) {
        self.base = base
        self.providerHost = providerHost
        self.record = record
    }

    public var providesVoice: Bool { base.providesVoice }

    public func failure(_ error: any Error) -> VoiceServiceFailure? {
        base.failure(error)
    }

    public func synthesize(_ text: String, voice: CallVoice) async throws -> Data {
        let started = Date()
        let characters = voice.model == "drama-3"
        let usage = characters ? text.count : text.utf8.count
        do {
            let audio = try await base.synthesize(text, voice: voice)
            await record(
                ServiceCall(
                    at: Date(), service: .speech, provider: providerHost, model: voice.model,
                    operation: .speech, unit: characters ? .characters : .bytes,
                    input: usage, estimated: false,
                    latency: Date().timeIntervalSince(started)
                )
            )
            return audio
        } catch {
            await record(
                ServiceCall(
                    at: Date(), service: .speech, provider: providerHost, model: voice.model,
                    operation: .speech, unit: characters ? .characters : .bytes,
                    input: usage, estimated: false,
                    latency: Date().timeIntervalSince(started),
                    error: error.localizedDescription
                )
            )
            throw error
        }
    }
}
