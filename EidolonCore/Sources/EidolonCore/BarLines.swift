import Foundation

/// How she orders (GLOSSARY.md「点单」).
public enum Phrasing: String, Sendable, CaseIterable, Hashable, Codable {
    case name
    case nameBig = "name_big"
    case flavor
    case kind
    case conditions
    case analogy
    case myFavorite = "my_favorite"
    case yourCall = "your_call"
    case usual

    /// The ways of ordering that name the drink.
    public var names: Bool { self == .name || self == .nameBig }
}

/// How well a drink was served (GLOSSARY.md「判定」).
public enum Tier: String, Sendable, CaseIterable, Hashable, Codable {
    case best, right, wrong

    /// In Chinese, as the prompt says it.
    public var zh: String {
        switch self {
        case .best: "上得最好"
        case .right: "上对了"
        case .wrong: "上错了"
        }
    }
}

/// What she may say of the drink she wants (GLOSSARY.md「点单」).
public enum Condition: String, Sendable, CaseIterable, Hashable {
    case flavor, kind, ice, big
    case noAlcohol = "no_alcohol"
}

/// Whether she is drunk, as the farewell lines tell it.
public enum Sobriety: String, Sendable, CaseIterable, Hashable {
    case sober, drunk
}

/// One of her fixed lines: in Japanese with its Chinese subtitle, and how she looks saying
/// it.
public struct BarLineText: Sendable, Hashable {
    public var ja: String
    public var zh: String
    /// Its Chinese subtitle.
    public var emotion: StandEmotion

    public init(ja: String, zh: String, emotion: StandEmotion = .calm) {
        self.ja = ja
        self.zh = zh
        self.emotion = emotion
    }
}

/// The bar's fixed lines (upstream `bar_lines.toml`), what is said at the bar without the
/// model writing it.
public struct BarLines: Sendable, Hashable {
    /// What the producer says as he serves each drink, in Chinese only.
    public var enjoy: [String]
    /// Her order for each way of ordering, said where hers names a drink it should not or
    /// does not name the one it should, even rewritten.
    public var orders: [Phrasing: [BarLineText]]
    /// What she adds where she wants it without alcohol, after such an order.
    public var noAlcohol: [BarLineText]
    /// Her reaction to a drink, by how well it was served.
    public var reactions: [Tier: [BarLineText]]
    /// Her farewell, sober or drunk.
    public var farewells: [Sobriety: [BarLineText]]

    public init(
        enjoy: [String],
        orders: [Phrasing: [BarLineText]],
        noAlcohol: [BarLineText],
        reactions: [Tier: [BarLineText]],
        farewells: [Sobriety: [BarLineText]]
    ) {
        self.enjoy = enjoy
        self.orders = orders
        self.noAlcohol = noAlcohol
        self.reactions = reactions
        self.farewells = farewells
    }

    /// The placeholders each way of ordering has in Japanese and in its subtitle:
    /// every one of them and no other.
    static let placeholders: [Phrasing: (ja: Set<String>, zh: Set<String>)] = [
        .name: (["name_ja"], ["name"]),
        .nameBig: (["name_ja"], ["name"]),
        .flavor: (["flavor"], ["flavor"]),
        .kind: (["kind"], ["kind"]),
        .conditions: (["conditions"], ["conditions"]),
        .analogy: (["conditions"], ["conditions"]),
    ]

    /// Reads `characters/bar_lines.json` (upstream `load_bar_lines`). Throws, naming the
    /// group, if a group is missing or broken.
    public init(json: JSONValue) throws {
        let enjoy = try Self.group(json, "enjoy")
        for (n, entry) in enjoy.enumerated() {
            guard let text = entry.stringValue else {
                throw EidolonError.invalidContent("enjoy 第 \(n + 1) 句应当是一行文字")
            }
            try Self.checkText(text, "enjoy", n + 1, placeholders: [])
        }
        let orders = try Self.table(json, "orders", Phrasing.allCases) { phrasing in
            Self.placeholders[phrasing] ?? ([], [])
        }
        let noAlcohol = try Self.lines(Self.group(json, "no_alcohol"), "no_alcohol")
        let reactions = try Self.table(json, "reactions", Tier.allCases) { _ in ([], []) }
        let farewells = try Self.table(json, "farewells", Sobriety.allCases) { _ in ([], []) }
        self.init(
            enjoy: enjoy.compactMap(\.stringValue), orders: orders, noAlcohol: noAlcohol,
            reactions: reactions, farewells: farewells
        )
    }

    /// Raises unless no line names a drink of `catalog`, in English or in Japanese,
    /// whatever its case, width or spacing (upstream `check_bar_lines`).
    public func check(catalog: DrinkCatalog) throws {
        for (label, n, text) in texts {
            if let said = BarNames.names(in: text, catalog: catalog).first {
                throw EidolonError.invalidContent("\(label) 第 \(n) 句提到了饮品 \(said)")
            }
        }
    }

    /// Every line's group, its place in it and its text: hers both in Japanese and in
    /// Chinese.
    var texts: [(String, Int, String)] {
        var result: [(String, Int, String)] = enjoy.enumerated().map { ("enjoy", $0.offset + 1, $0.element) }
        var groups: [(String, [BarLineText])] = [("no_alcohol", noAlcohol)]
        groups += orders.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { ("orders.\($0.key.rawValue)", $0.value) }
        groups += reactions.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { ("reactions.\($0.key.rawValue)", $0.value) }
        groups += farewells.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { ("farewells.\($0.key.rawValue)", $0.value) }
        for (label, group) in groups {
            for (n, line) in group.enumerated() {
                result.append((label, n + 1, line.ja))
                result.append((label, n + 1, line.zh))
            }
        }
        return result
    }

    private static func group(_ config: JSONValue, _ key: String) throws -> [JSONValue] {
        guard let value = config.objectValue?[key] else {
            throw EidolonError.invalidContent("写死的句子里没有 \(key) 这一组")
        }
        guard let group = value.arrayValue else {
            throw EidolonError.invalidContent("写死的句子里的 \(key) 应当是一组句子")
        }
        guard !group.isEmpty else {
            throw EidolonError.invalidContent("写死的句子里的 \(key) 这一组是空的")
        }
        return group
    }

    private static func table<Key: RawRepresentable & CaseIterable & Hashable>(
        _ config: JSONValue, _ key: String, _ groups: [Key],
        placeholders: (Key) -> (ja: Set<String>, zh: Set<String>)
    ) throws -> [Key: [BarLineText]] where Key.RawValue == String {
        guard let table = config.objectValue?[key]?.objectValue else {
            throw EidolonError.invalidContent("写死的句子里没有 [\(key)] 这一节")
        }
        let known = Set(groups.map(\.rawValue))
        let unknown = Set(table.keys).subtracting(known).sorted()
        guard unknown.isEmpty else {
            throw EidolonError.invalidContent(
                "写死的句子里的 " + unknown.map { "\(key).\($0)" }.joined(separator: "、") + " 不是认识的组")
        }
        var result: [Key: [BarLineText]] = [:]
        for group in groups {
            let label = "\(key).\(group.rawValue)"
            let value = try Self.group(.object(table), group.rawValue)
            result[group] = try Self.lines(value, label, placeholders: placeholders(group))
        }
        return result
    }

    private static func lines(
        _ group: [JSONValue], _ label: String,
        placeholders: (ja: Set<String>, zh: Set<String>) = ([], [])
    ) throws -> [BarLineText] {
        try group.enumerated().map { n, entry in
            guard let object = entry.objectValue else {
                throw EidolonError.invalidContent("\(label) 第 \(n + 1) 句应当是一个 [[\(label)]] 段")
            }
            let missing = ["ja", "zh"].filter { object[$0] == nil }
            guard missing.isEmpty else {
                throw EidolonError.invalidContent("\(label) 第 \(n + 1) 句缺少 \(missing.joined(separator: "、"))")
            }
            let ja = object["ja"]!.stringValue!
            let zh = object["zh"]!.stringValue!
            let emotionText = object["emotion"]?.stringValue ?? "calm"
            try checkText(ja, label, n + 1, placeholders: placeholders.ja)
            try checkText(zh, label, n + 1, placeholders: placeholders.zh)
            guard let emotion = StandEmotion(rawValue: emotionText) else {
                throw EidolonError.invalidContent(
                    "\(label) 第 \(n + 1) 句的表情 \(emotionText) 不在 "
                        + StandEmotion.allCases.map(\.rawValue).joined(separator: "、") + " 之中"
                )
            }
            return BarLineText(ja: ja, zh: zh, emotion: emotion)
        }
    }

    /// Raises unless `text` is a line with all of `placeholders` and no other.
    private static func checkText(
        _ text: String, _ label: String, _ n: Int, placeholders: Set<String>
    ) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.contains("\r"), !text.contains("\n") else {
            throw EidolonError.invalidContent("\(label) 第 \(n) 句应当是一行文字")
        }
        let used = Self.fields(of: text)
        guard let used else {
            throw EidolonError.invalidContent("\(label) 第 \(n) 句的花括号没有配对：\(text)")
        }
        for field in used where !placeholders.contains(field) {
            let allowed = placeholders.sorted().map { "{\($0)}" }.joined(separator: "、")
            throw EidolonError.invalidContent(
                "\(label) 第 \(n) 句用了不认识的占位 {\(field)}，"
                    + (allowed.isEmpty ? "这一组不能用占位" : "这一组只能用 \(allowed)")
            )
        }
        let missing = placeholders.subtracting(used).sorted()
        guard missing.isEmpty else {
            throw EidolonError.invalidContent(
                "\(label) 第 \(n) 句缺少占位 \(missing.map { "{\($0)}" }.joined(separator: "、"))：\(text)"
            )
        }
    }

    /// The `{name}`-style fields `text` uses, or nil if its braces do not pair. A field
    /// with a format spec or conversion (`{name!r}`, `{name:>3}`) counts as unknown by its
    /// whole text, so it is refused where it is not one.
    static func fields(of text: String) -> Set<String>? {
        var fields: Set<String> = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            if rest[rest.index(after: open)] == "{" {  // "{{" is a literal brace
                rest = rest[rest.index(after: rest.index(after: open))...]
                continue
            }
            guard let close = rest[open...].firstIndex(of: "}") else { return nil }
            let body = rest[rest.index(after: open)..<close]
            if !body.isEmpty { fields.insert(String(body)) }
            rest = rest[rest.index(after: close)...]
        }
        return fields
    }
}

/// `{field}` filling, as the fixed order lines use it.
extension String {
    /// This text with each placeholder filled from `values`. A placeholder that is not in
    /// `values` is left as it is (configuration validation refuses those before this runs).
    func filled(_ values: [String: String]) -> String {
        var result = ""
        var rest = Substring(self)
        while let open = rest.firstIndex(of: "{") {
            result += rest[rest.startIndex..<open].replacingOccurrences(of: "{{", with: "{")
            guard let close = rest[open...].firstIndex(of: "}") else {
                result += rest[open...]
                return result.replacingOccurrences(of: "}}", with: "}")
            }
            let body = String(rest[rest.index(after: open)..<close])
            result += values[body] ?? "{\(body)}"
            rest = rest[rest.index(after: close)...]
        }
        return result.replacingOccurrences(of: "{{", with: "{")
            .replacingOccurrences(of: "}}", with: "}")
    }
}
