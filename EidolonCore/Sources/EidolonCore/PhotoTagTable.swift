import Foundation

/// The categories the local photo tag table blocks (upstream `photo_tags.json`).
public enum PhotoTagCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case nudity
    case underwear
    case exposure
    case bathing
    case pose
    case expression
    case appearance
    case style
    case people
}

/// The tag table the exporter copies from upstream: known tags, rewrites, the allowed
/// list, and the blocked tags and words by category. The app only looks tags up here; it
/// never asks NovelAI's suggestion service at runtime.
public struct PhotoTagTable: Sendable {
    public struct Blocked: Sendable, Hashable {
        public var tags: Set<String>
        public var words: Set<String>
    }

    public var model: String
    public var known: Set<String>
    public var rewrites: [String: String]
    public var allowed: Set<String>
    public var blocked: [PhotoTagCategory: Blocked]

    public init(
        model: String,
        known: Set<String>,
        rewrites: [String: String],
        allowed: Set<String>,
        blocked: [PhotoTagCategory: Blocked]
    ) {
        self.model = model
        self.known = known
        self.rewrites = rewrites
        self.allowed = allowed
        self.blocked = blocked
    }

    public init(data: Data) throws {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw EidolonError.invalidBundle(
                "照片 tag 表 characters/photo_tags.json 无法解析：\(error.localizedDescription)"
            )
        }
        guard let object = root.objectValue else {
            throw EidolonError.invalidBundle("照片 tag 表应当是对象")
        }
        guard let model = object["model"]?.stringValue, !model.isEmpty else {
            throw EidolonError.invalidBundle("照片 tag 表缺少 model")
        }
        let known = try Self.stringSet(object["known"], field: "known")
        guard !known.isEmpty else {
            throw EidolonError.invalidBundle("照片 tag 表的 known 是空的")
        }
        let allowed = try Self.stringSet(object["allowed"], field: "allowed")
        let rewrites = try Self.stringMap(object["rewrites"], field: "rewrites")
        guard let blockedObject = object["blocked"]?.objectValue else {
            throw EidolonError.invalidBundle("照片 tag 表缺少 blocked")
        }
        var blocked: [PhotoTagCategory: Blocked] = [:]
        for (raw, value) in blockedObject {
            guard let category = PhotoTagCategory(rawValue: raw) else {
                throw EidolonError.invalidBundle("照片 tag 表有不认识的 blocked 类别：\(raw)")
            }
            guard let entry = value.objectValue else {
                throw EidolonError.invalidBundle("照片 tag 表的 blocked.\(raw) 应当是对象")
            }
            blocked[category] = Blocked(
                tags: try Self.stringSet(entry["tags"], field: "blocked.\(raw).tags"),
                words: try Self.stringSet(entry["words"], field: "blocked.\(raw).words")
            )
        }
        self.init(
            model: model,
            known: known,
            rewrites: rewrites,
            allowed: allowed,
            blocked: blocked
        )
    }

    public static func load(in directory: URL) throws -> PhotoTagTable? {
        let url = directory.appendingPathComponent("characters/photo_tags.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try PhotoTagTable(data: Data(contentsOf: url))
        } catch let error as EidolonError {
            throw error
        } catch {
            throw EidolonError.invalidBundle(
                "读不到 characters/photo_tags.json：\(error.localizedDescription)"
            )
        }
    }

    public func isBlocked(_ tag: String, in category: PhotoTagCategory) -> Bool {
        guard let entry = blocked[category] else { return false }
        if entry.tags.contains(tag) { return true }
        return entry.words.contains { tag == $0 || tag.contains($0) }
    }

    /// Whether any blocked category catches the tag, or nil when it is clean. A tag on
    /// the allowed list never crosses the line, even when a blocked word is inside it
    /// (upstream `_TagTable.crossing`).
    public func blockingCategory(of tag: String) -> PhotoTagCategory? {
        if allowed.contains(tag) { return nil }
        return PhotoTagCategory.allCases.first { isBlocked(tag, in: $0) }
    }

    private static func stringSet(_ value: JSONValue?, field: String) throws -> Set<String> {
        guard let value, value != .null else { return [] }
        guard let items = value.arrayValue else {
            throw EidolonError.invalidBundle("照片 tag 表的 \(field) 应当是字符串列表")
        }
        return try Set(items.map { item in
            guard let text = item.stringValue else {
                throw EidolonError.invalidBundle("照片 tag 表的 \(field) 里有非字符串")
            }
            return text
        })
    }

    private static func stringMap(_ value: JSONValue?, field: String) throws -> [String: String] {
        guard let value, value != .null else { return [:] }
        guard let object = value.objectValue else {
            throw EidolonError.invalidBundle("照片 tag 表的 \(field) 应当是对象")
        }
        var result: [String: String] = [:]
        for (key, item) in object {
            guard let text = item.stringValue else {
                throw EidolonError.invalidBundle("照片 tag 表的 \(field).\(key) 应当是字符串")
            }
            result[key] = text
        }
        return result
    }
}
