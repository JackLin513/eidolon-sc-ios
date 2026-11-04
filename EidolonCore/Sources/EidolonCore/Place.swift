import Foundation

/// One kind of place in the content bundle's place pool (upstream `places.toml`).
public enum PlaceCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case cafe
    case park
    case shrine
    case shoppingStreet = "shopping-street"
    case fashionStreet = "fashion-street"
    case books
    case mall
    case seaside
    case amusement
    case museum
    case nightView = "night-view"
    case bath
    case seasonal
    case venue

    /// The categories a rainy day may still use. Waterfront, parks and streets are not
    /// on the list, as upstream keeps them out of wet weather.
    public var isIndoor: Bool {
        switch self {
        case .cafe, .books, .mall, .museum, .bath, .venue: true
        default: false
        }
    }

    public var listedName: String { rawValue }
}

public enum PlaceSeason: String, Codable, Sendable, CaseIterable, Hashable {
    case spring
    case summer
    case autumn
    case winter
}

public enum PlaceSlot: String, Codable, Sendable, CaseIterable, Hashable {
    case morning
    case afternoon
    case evening
}

/// One real place from the content bundle's place pool. It is data, not a map lookup:
/// the app never asks a map service where it is.
public struct Place: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// The ward or city, for disambiguation and for her, never shown as the place name.
    public var area: String
    public var latitude: Double
    public var longitude: Double
    public var category: PlaceCategory
    /// One Chinese sentence telling her what kind of place this is.
    public var note: String
    /// The date the entry was checked, as `yyyy-MM-dd`.
    public var checked: String
    /// The idols this place is associated with; only shrines and documented places have
    /// any.
    public var idols: [String]
    /// The source line for a pilgrimage spot; having one marks the place as a pilgrimage
    /// spot rather than a category.
    public var source: String?
    public var seasons: [PlaceSeason]
    public var slots: [PlaceSlot]
    /// The venue names in the world setting a live venue answers to.
    public var venues: [String]

    public init(
        id: String,
        name: String,
        area: String,
        latitude: Double,
        longitude: Double,
        category: PlaceCategory,
        note: String,
        checked: String,
        idols: [String] = [],
        source: String? = nil,
        seasons: [PlaceSeason] = [],
        slots: [PlaceSlot] = [],
        venues: [String] = []
    ) {
        self.id = id
        self.name = name
        self.area = area
        self.latitude = latitude
        self.longitude = longitude
        self.category = category
        self.note = note
        self.checked = checked
        self.idols = idols
        self.source = source
        self.seasons = seasons
        self.slots = slots
        self.venues = venues
    }

    public init(json: JSONValue) throws {
        guard let object = json.objectValue else {
            throw EidolonError.invalidBundle("地点池里的条目应当是对象")
        }
        let label = object["id"]?.stringValue ?? "（没有标识）"
        guard let id = object["id"]?.stringValue, isShortIdentifier(id) else {
            throw EidolonError.invalidBundle("地点标识 \(label) 只能用小写字母、数字、- 和 _")
        }
        guard let name = object["name"]?.stringValue,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw EidolonError.invalidBundle("地点 \(id) 缺少 name")
        }
        guard let area = object["area"]?.stringValue,
              !area.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw EidolonError.invalidBundle("地点 \(id) 缺少 area")
        }
        guard let latitude = object["lat"]?.doubleValue, (-90...90).contains(latitude) else {
            throw EidolonError.invalidBundle("地点 \(id) 的 lat 不在 -90 到 90 之间")
        }
        guard let longitude = object["lon"]?.doubleValue, (-180...180).contains(longitude) else {
            throw EidolonError.invalidBundle("地点 \(id) 的 lon 不在 -180 到 180 之间")
        }
        guard let categoryText = object["category"]?.stringValue,
              let category = PlaceCategory(rawValue: categoryText)
        else {
            throw EidolonError.invalidBundle(
                "地点 \(id) 的类别 \(object["category"]?.stringValue ?? "（缺）") 不在 "
                    + PlaceCategory.allCases.map(\.rawValue).joined(separator: "、") + " 之中"
            )
        }
        guard let note = object["note"]?.stringValue, !note.isEmpty else {
            throw EidolonError.invalidBundle("地点 \(id) 缺少 note")
        }
        guard let checked = object["checked"]?.stringValue, Self.isDay(checked) else {
            throw EidolonError.invalidBundle("地点 \(id) 的 checked 应为 yyyy-MM-dd 格式")
        }
        let idols = try Self.strings(object["idols"], field: "idols", place: id)
        let source = try Self.optionalString(object["source"], field: "source", place: id)
        let seasons: [PlaceSeason] = try Self.enums(object["seasons"], field: "seasons", place: id)
        let slots: [PlaceSlot] = try Self.enums(object["slots"], field: "slots", place: id)
        let venues = try Self.strings(object["venues"], field: "venues", place: id)
        if !venues.isEmpty, category != .venue {
            throw EidolonError.invalidBundle("地点 \(id) 不是演出场馆，却写了 venues")
        }
        self.init(
            id: id,
            name: name,
            area: area,
            latitude: latitude,
            longitude: longitude,
            category: category,
            note: note,
            checked: checked,
            idols: idols,
            source: source,
            seasons: seasons,
            slots: slots,
            venues: venues
        )
    }

    private static func isDay(_ text: String) -> Bool {
        guard text.count == 10 else { return false }
        let pieces = text.split(separator: "-")
        guard pieces.count == 3,
              pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              pieces.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return false }
        return true
    }

    private static func strings(
        _ value: JSONValue?,
        field: String,
        place id: String
    ) throws -> [String] {
        guard let value, value != .null else { return [] }
        guard let values = value.arrayValue else {
            throw EidolonError.invalidBundle("地点 \(id) 的 \(field) 应当是字符串列表")
        }
        return try values.map { item in
            guard let text = item.stringValue, !text.isEmpty else {
                throw EidolonError.invalidBundle("地点 \(id) 的 \(field) 里有空值")
            }
            return text
        }
    }

    private static func optionalString(
        _ value: JSONValue?,
        field: String,
        place id: String
    ) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let text = value.stringValue, !text.isEmpty else {
            throw EidolonError.invalidBundle("地点 \(id) 的 \(field) 应当是一段文字")
        }
        return text
    }

    private static func enums<T: RawRepresentable & CaseIterable & Hashable>(
        _ value: JSONValue?,
        field: String,
        place id: String
    ) throws -> [T] where T.RawValue == String {
        guard let value, value != .null else { return [] }
        guard let values = value.arrayValue else {
            throw EidolonError.invalidBundle("地点 \(id) 的 \(field) 应当是字符串列表")
        }
        var seen: Set<T> = []
        return try values.map { item in
            guard let text = item.stringValue, let parsed = T(rawValue: text) else {
                throw EidolonError.invalidBundle(
                    "地点 \(id) 的 \(field) 里有不认识的 \(item.stringValue ?? "（空）")"
                )
            }
            guard seen.insert(parsed).inserted else {
                throw EidolonError.invalidBundle("地点 \(id) 的 \(field) 里有重复的 \(text)")
            }
            return parsed
        }
    }
}

/// The whole place pool, keyed by id.
public struct PlacePool: Sendable {
    public let places: [Place]
    public let byID: [String: Place]

    public init(places: [Place]) throws {
        var byID: [String: Place] = [:]
        for place in places {
            guard byID.updateValue(place, forKey: place.id) == nil else {
                throw EidolonError.invalidBundle("地点标识重复：\(place.id)")
            }
        }
        self.places = places
        self.byID = byID
    }

    public init(data: Data) throws {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw EidolonError.invalidBundle(
                "地点池 characters/places.json 无法解析：\(error.localizedDescription)"
            )
        }
        guard let entries = root.objectValue?["places"]?.arrayValue else {
            throw EidolonError.invalidBundle("地点池 characters/places.json 里的 places 应当是列表")
        }
        try self.init(places: entries.map(Place.init(json:)))
    }

    public static func load(in directory: URL) throws -> PlacePool? {
        let url = directory.appendingPathComponent("characters/places.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try PlacePool(data: Data(contentsOf: url))
        } catch let error as EidolonError {
            throw error
        } catch {
            throw EidolonError.invalidBundle("读不到 characters/places.json：\(error.localizedDescription)")
        }
    }

    /// Validates the cross references once the characters and jobs are known.
    public func validate(characters: [CharacterConfig], jobs: [ListedJob]) throws {
        let characterIDs = Set(characters.map(\.id))
        for place in places {
            let unknown = place.idols.filter { !characterIDs.contains($0) }
            guard unknown.isEmpty else {
                throw EidolonError.invalidBundle(
                    "地点 \(place.id) 的 idols 里有不存在的角色：\(unknown.joined(separator: "、"))"
                )
            }
        }
        for character in characters {
            guard !character.placeLikes.isEmpty else { continue }
            guard (2...4).contains(character.placeLikes.count) else {
                throw EidolonError.invalidBundle(
                    "角色 \(character.id) 的 place_likes 应为 2–4 个，现在是 \(character.placeLikes.count) 个"
                )
            }
            guard Set(character.placeLikes).count == character.placeLikes.count else {
                throw EidolonError.invalidBundle("角色 \(character.id) 的 place_likes 里有重复类别")
            }
            for raw in character.placeLikes {
                guard let category = PlaceCategory(rawValue: raw), category != .venue else {
                    throw EidolonError.invalidBundle(
                        "角色 \(character.id) 的 place_likes 里有不可用的类别：\(raw)"
                    )
                }
            }
        }
        let allowedJobPlaces = Set(PlaceCategory.allCases.map(\.rawValue)).union(["nearby"])
        for job in jobs {
            guard let listed = job.places else { continue }
            guard !listed.isEmpty else { continue }
            guard Set(listed).count == listed.count else {
                throw EidolonError.invalidBundle("工作 \(job.id) 的 places 里有重复类别")
            }
            for raw in listed where !allowedJobPlaces.contains(raw) {
                throw EidolonError.invalidBundle(
                    "工作 \(job.id) 的 places 里有不认识的类别：\(raw)"
                )
            }
        }
    }
}
