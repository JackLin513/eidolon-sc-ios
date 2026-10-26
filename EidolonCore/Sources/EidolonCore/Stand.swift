import Foundation

/// The optional `stand` entry on a character (ADR-0018): her default outfit and the
/// path of her outfit list, both relative to the content bundle root.
public struct StandConfig: Sendable, Hashable {
    public var defaultOutfitID: String
    public var defaultOutfitPath: String
    public var outfitListPath: String

    public init(defaultOutfitID: String, defaultOutfitPath: String, outfitListPath: String) {
        self.defaultOutfitID = defaultOutfitID
        self.defaultOutfitPath = defaultOutfitPath
        self.outfitListPath = outfitListPath
    }

    init(json: JSONValue, characterID: String) throws {
        guard let object = json.objectValue,
              let defaultOutfit = object["default_outfit"]?.objectValue,
              let id = defaultOutfit["id"]?.stringValue, !id.isEmpty,
              let path = defaultOutfit["path"]?.stringValue, !path.isEmpty,
              let outfits = object["outfits"]?.stringValue, !outfits.isEmpty
        else {
            throw EidolonError.invalidContent(
                "角色 \(characterID) 的 stand 应包含默认衣装（编号与路径）和衣装清单路径"
            )
        }
        self.init(defaultOutfitID: id, defaultOutfitPath: path, outfitListPath: outfits)
    }
}

/// One outfit of hers, resolved under the installed content bundle.
public struct StandOutfit: Sendable, Hashable {
    /// The upstream outfit number, for example `stand/1030010010`.
    public var id: String
    /// The directory holding `data.json`, `data.atlas` and `data.png`.
    public var directory: URL

    public init(id: String, directory: URL) {
        self.id = id
        self.directory = directory
    }
}

/// A card in her outfit list; either side may be missing.
public struct OutfitCard: Sendable, Hashable {
    /// The card's upstream number.
    public var id: String
    public var name: String
    /// The card's rarity or kind, for example `P_SR`.
    public var type: String
    /// Her everyday clothes on the card.
    public var everyday: StandOutfit?
    /// The card's stage costume.
    public var stage: StandOutfit?

    public init(
        id: String,
        name: String,
        type: String,
        everyday: StandOutfit? = nil,
        stage: StandOutfit? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.everyday = everyday
        self.stage = stage
    }
}

/// `stand/outfits/<idol_id>.json`, decoded from the upstream shape the exporter
/// rewrites into the bundle (ADR-0018).
public struct OutfitList: Sendable, Hashable {
    public var idolID: Int
    public var cards: [OutfitCard]

    public init(idolID: Int, cards: [OutfitCard]) {
        self.idolID = idolID
        self.cards = cards
    }

    /// An outfit whose three files are not all in the bundle is left out, so a
    /// partially fetched outfit never makes it into the picker.
    static let files = ["data.json", "data.atlas", "data.png"]

    /// Decode a list as it sits in the bundle. `url` is relative to the list file.
    /// A list that cannot be read returns nil: the app then has no list, only the
    /// default outfit.
    public init?(data: Data, at listURL: URL, fileManager: FileManager = .default) {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue,
              let idolID = root["idol_id"]?.intValue,
              let cards = root["cards"]?.arrayValue
        else { return nil }

        let base = listURL.deletingLastPathComponent()
        var decoded: [OutfitCard] = []
        for card in cards {
            guard let object = card.objectValue,
                  let id = object["id"]?.stringValue,
                  let name = object["name"]?.stringValue,
                  let type = object["type"]?.stringValue
            else { return nil }
            decoded.append(
                OutfitCard(
                    id: id,
                    name: name,
                    type: type,
                    everyday: Self.outfit(object["everyday"], base: base, fileManager: fileManager),
                    stage: Self.outfit(object["stage"], base: base, fileManager: fileManager)
                )
            )
        }
        self.init(idolID: idolID, cards: decoded)
    }

    private static func outfit(
        _ value: JSONValue?,
        base: URL,
        fileManager: FileManager
    ) -> StandOutfit? {
        guard let object = value?.objectValue,
              let id = object["id"]?.stringValue, !id.isEmpty,
              let path = object["url"]?.stringValue, !path.isEmpty
        else { return nil }
        let directory = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        guard files.allSatisfy({
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) else { return nil }
        return StandOutfit(id: id, directory: directory)
    }
}

/// What the call screen reads for one character: the default outfit and, when her
/// list can be read, the outfits she can change into.
public struct CharacterStand: Sendable, Hashable {
    public var defaultOutfit: StandOutfit
    public var outfitList: OutfitList?

    public init(defaultOutfit: StandOutfit, outfitList: OutfitList? = nil) {
        self.defaultOutfit = defaultOutfit
        self.outfitList = outfitList
    }
}
