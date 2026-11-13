import Foundation

/// The original TIPS.CSV rows packaged with a totsulover content bundle. The app can use
/// the same ids as the `<dNNNN>` references in the story text.
public struct ContentTerm: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var row: Int
    public var term: String
    public var reading: String
    public var imageSmall: String
    public var imageLarge: String

    enum CodingKeys: String, CodingKey {
        case id, row, term, reading
        case imageSmall = "image_small"
        case imageLarge = "image_large"
    }
}

public struct StoryCatalogEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var route: String?
    public var chapter: String?
    public var category: String
    public var cast: [String]
}

extension Eidolon {
    /// The packaged Japanese term table; nil when an older bundle has no `terms.json`.
    public func terms(franchise: String? = nil) throws -> [ContentTerm]? {
        try loadContentPackagesIfNeeded()
        let franchise = ContentRegistryState.normalizedFranchise(franchise ?? activeContentFranchise)
        let url = location.contentRoot
            .appendingPathComponent(franchise, isDirectory: true)
            .appendingPathComponent("current/characters/terms.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode([ContentTerm].self, from: data)
    }

    /// A lightweight catalog over the existing episode rows, without loading embeddings.
    public func storyCatalog(franchise: String? = nil) throws -> [StoryCatalogEntry] {
        try loadContentPackagesIfNeeded()
        let database = try contentDatabase()
        return try database.storyCatalog()
    }
}
