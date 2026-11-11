import Foundation

/// A franchise-scoped identity for a character. The local id is only unique inside its
/// package/franchise, so it must never be used as a global user-library key by itself.
public struct CharacterKey: Codable, Sendable, Hashable, CustomStringConvertible {
    public var franchise: String
    public var localID: String

    public init(franchise: String, localID: String) {
        self.franchise = franchise
        self.localID = localID
    }

    public var description: String { "\(franchise):\(localID)" }
}

/// The installed content package record for one franchise. The content root is derived
/// from the franchise, not stored here, so a package remains portable.
public struct InstalledContentPackage: Codable, Sendable, Hashable {
    public var franchise: String
    public var kind: String
    public var info: ContentBundleInfo

    public init(franchise: String, kind: String = ContentKind.content.rawValue, info: ContentBundleInfo) {
        self.franchise = franchise
        self.kind = kind
        self.info = info
    }
}

/// The app-state keys and small pure helpers for the multi-franchise content registry.
enum ContentRegistryState {
    static let packagesKey = "content.packages"
    static let activeFranchiseKey = "content.activeFranchise"
    static let legacyFranchise = "shiny"
    static let legacyDirectoryName = "shiny"

    static func normalizedFranchise(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? legacyFranchise : value
    }

    static func normalizedKind(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? ContentKind.content.rawValue : value
    }
}
