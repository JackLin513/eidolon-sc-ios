import Foundation

/// How she is as she comes in (GLOSSARY.md「来意」).
public enum Mood: String, Sendable, CaseIterable, Hashable {
    case happy, annoyed, tired, down, calm

    /// In Chinese, as the prompt says it.
    public var zh: String {
        switch self {
        case .happy: "开心"
        case .annoyed: "烦躁"
        case .tired: "疲惫"
        case .down: "低落"
        case .calm: "平静"
        }
    }
}

/// Her reason for coming (GLOSSARY.md「来意」).
public struct BarReason: Sendable, Hashable, Identifiable {
    public var id: String
    /// One line saying what it is, for the model.
    public var note: String
    /// How she is as she comes in with it.
    public var mood: Mood
    /// The characters it is not for.
    public var notFor: Set<String>

    public init(id: String, note: String, mood: Mood, notFor: Set<String> = []) {
        self.id = id
        self.note = note
        self.mood = mood
        self.notFor = notFor
    }
}

/// What she is to talk about (GLOSSARY.md「话题」).
public struct BarTopic: Sendable, Hashable, Identifiable {
    public var id: String
    /// One line saying what it is, for the model.
    public var note: String
    /// The characters it is not for.
    public var notFor: Set<String>

    public init(id: String, note: String, notFor: Set<String> = []) {
        self.id = id
        self.note = note
        self.notFor = notFor
    }
}

/// Why she comes that night: one of the listed reasons, or — where there are schedules — the
/// job of hers the producer scheduled that day and she has done (upstream `bar_rules.Reason`).
public struct VisitReason: Sendable, Hashable {
    public var id: String
    public var note: String
    /// How she is as she comes in with it; none for a job.
    public var mood: Mood?
    /// Whether it is a job of hers, not one of the listed reasons.
    public var job: Bool

    public init(id: String, note: String, mood: Mood? = nil, job: Bool = false) {
        self.id = id
        self.note = note
        self.mood = mood
        self.job = job
    }

    /// The listed ones as she comes in with them.
    public init(_ reason: BarReason) {
        self.init(id: reason.id, note: reason.note, mood: reason.mood)
    }
}

/// The reasons for coming and the topics, in file order.
public struct BarVisits: Sendable, Hashable {
    /// How many of her latest visits with a user a visit's reason and topic are not drawn
    /// from again.
    public static let recentVisits = 3

    public var reasons: [BarReason]
    public var topics: [BarTopic]

    public init(reasons: [BarReason], topics: [BarTopic]) {
        self.reasons = reasons
        self.topics = topics
    }

    /// The reasons `character` may come with, in file order.
    public func reasons(for character: String) -> [BarReason] {
        reasons.filter { !$0.notFor.contains(character) }
    }

    /// The topics `character` may talk about, in file order.
    public func topics(for character: String) -> [BarTopic] {
        topics.filter { !$0.notFor.contains(character) }
    }

    /// Reads `characters/bar_visits.json` (upstream `load_bar_visits`). Throws unless both
    /// lists are there and every entry is well formed.
    public init(json: JSONValue) throws {
        let reasons = try Self.entries(json, "reasons", "来意").map { entry -> BarReason in
            let fields = try Self.parse(entry, "reasons", "来意", required: ["id", "note", "mood"])
            guard let mood = Mood(rawValue: fields.mood) else {
                throw EidolonError.invalidContent(
                    "来意 \(fields.id) 的基调 \(fields.mood) 不在 "
                        + Mood.allCases.map(\.rawValue).joined(separator: "、") + " 之中"
                )
            }
            return BarReason(id: fields.id, note: fields.note, mood: mood, notFor: fields.notFor)
        }
        let topics = try Self.entries(json, "topics", "话题").map { entry -> BarTopic in
            let fields = try Self.parse(entry, "topics", "话题", required: ["id", "note"])
            return BarTopic(id: fields.id, note: fields.note, notFor: fields.notFor)
        }
        for (what, ids) in [("来意", reasons.map(\.id)), ("话题", topics.map(\.id))] {
            let twice = Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })
            guard twice.isEmpty else {
                throw EidolonError.invalidContent(
                    "\(what)标识 \(twice.sorted().joined(separator: "、")) 重复"
                )
            }
        }
        self.init(reasons: reasons, topics: topics)
    }

    /// Raises unless every character a reason or topic is not for is one of `characters`,
    /// and every character has more than `recentVisits` of each for her (upstream
    /// `check_bar_visits`).
    public func check(characters: [String]) throws {
        for (what, entries) in [("来意", reasons.map { ($0.id, $0.notFor) }),
                                ("话题", topics.map { ($0.id, $0.notFor) })] {
            for (id, notFor) in entries {
                let unknown = notFor.subtracting(characters).sorted()
                guard unknown.isEmpty else {
                    throw EidolonError.invalidContent(
                        "\(what) \(id) 的 not_for 里的 \(unknown.joined(separator: "、")) 不是角色"
                    )
                }
            }
            for character in characters {
                let count = entries.filter { !$0.1.contains(character) }.count
                guard count > Self.recentVisits else {
                    throw EidolonError.invalidContent(
                        "角色 \(character) 能用的\(what)只有 \(count) 条，至少要 \(Self.recentVisits + 1) 条"
                    )
                }
            }
        }
    }

    private static func entries(_ json: JSONValue, _ table: String, _ what: String) throws -> [JSONValue] {
        guard let entries = json.objectValue?[table]?.arrayValue else {
            throw EidolonError.invalidContent("来意和话题清单里的 \(table) 应当是 [[\(table)]] 段")
        }
        guard !entries.isEmpty else {
            throw EidolonError.invalidContent("来意和话题清单里没有\(what)（[[\(table)]] 段）")
        }
        return entries
    }

    private struct Fields {
        var id: String
        var note: String
        var notFor: Set<String>
    }

    private static func parse(
        _ entry: JSONValue, _ table: String, _ what: String, required: [String]
    ) throws -> (id: String, note: String, mood: String, notFor: Set<String>) {
        guard let object = entry.objectValue else {
            throw EidolonError.invalidContent("来意和话题清单里的 \(entry) 应当是一个 [[\(table)]] 段")
        }
        let label = object["id"]?.stringValue ?? "（没有标识）"
        let missing = required.filter { object[$0] == nil }
        guard missing.isEmpty else {
            throw EidolonError.invalidContent("\(what) \(label) 缺少 \(missing.joined(separator: "、"))")
        }
        guard let id = object["id"]?.stringValue, isShortIdentifier(id) else {
            throw EidolonError.invalidContent(
                "\(what)标识 \(object["id"].map { "\($0)" } ?? "（没有标识）") 只能用小写字母、数字、- 和 _"
            )
        }
        guard let note = object["note"]?.stringValue, !note.trimmingCharacters(in: .whitespaces).isEmpty,
              !note.contains("\r"), !note.contains("\n") else {
            throw EidolonError.invalidContent("\(what) \(id) 的 note 应当是一行文字")
        }
        let notFor: [String]
        if let value = object["not_for"], value != .null {
            guard let list = value.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else {
                throw EidolonError.invalidContent("\(what) \(id) 的 not_for 应当是角色标识的列表")
            }
            notFor = list.compactMap(\.stringValue)
        } else {
            notFor = []
        }
        return (id, note, object["mood"]?.stringValue ?? "", Set(notFor))
    }
}
