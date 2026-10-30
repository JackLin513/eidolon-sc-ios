import Foundation

/// Everything the bar needs from the content bundle: the drink catalog, the reasons and
/// topics, her fixed lines and the characters whose bar columns they are checked against
/// (ADR-0021). Loading it validates the whole of it, so a bundle that would fail at the bar
/// is refused on the way in.
public struct BarContent: Sendable {
    public var catalog: DrinkCatalog
    public var visits: BarVisits
    public var lines: BarLines
    public var characters: [CharacterConfig]

    public init(
        catalog: DrinkCatalog, visits: BarVisits, lines: BarLines, characters: [CharacterConfig]
    ) {
        self.catalog = catalog
        self.visits = visits
        self.lines = lines
        self.characters = characters
    }

    /// Reads and validates the bar's three files (`characters/drinks.json`,
    /// `characters/bar_visits.json`, `characters/bar_lines.json`) and the bar columns of
    /// `characters/characters.json` from an installed content directory.
    public init(directory: URL) throws {
        let catalog = try DrinkCatalog(json: try Self.read(directory, "drinks.json"))
        let visits = try BarVisits(json: try Self.read(directory, "bar_visits.json"))
        let lines = try BarLines(json: try Self.read(directory, "bar_lines.json"))
        let characters = try Self.characters(directory)

        try BarTastesCheck.check(characters, catalog: catalog)
        try visits.check(characters: characters.map(\.id))
        try lines.check(catalog: catalog)
        self.init(catalog: catalog, visits: visits, lines: lines, characters: characters)
    }

    /// The bar content of the bundle installed at `bundle`, and the directory it was
    /// installed in — still there for the caller to read her sheet from (used by the
    /// oracle, which deletes it afterwards).
    public static func loadForOracle(bundleAt url: URL) async throws -> (BarContent, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eidolon-bar-\(UUID().uuidString)", isDirectory: true)
        let eidolon = try Eidolon(location: .init(root: root))
        try await eidolon.install(bundleAt: url)
        return (try BarContent(directory: eidolon.location.contentDirectory),
                eidolon.location.contentDirectory)
    }

    /// Her sheet's text, read from an installed content directory.
    public static func sheet(of character: CharacterConfig, in contentDirectory: URL) throws -> String {
        guard let path = character.sheet else {
            throw EidolonError.invalidBundle("角色 \(character.id) 没有配 sheet")
        }
        let url = contentDirectory.appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw EidolonError.invalidBundle("当前内容包缺少 \(path)")
        }
        // Upstream strips the sheet as it reads it (`characters.py`), so the prompt has it
        // without the file's trailing newline.
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func read(_ directory: URL, _ name: String) throws -> JSONValue {
        let url = directory.appendingPathComponent("characters/\(name)")
        guard let data = try? Data(contentsOf: url) else {
            throw EidolonError.invalidBundle(
                "当前内容包缺少 characters/\(name)，需要用新版导出脚本重新导出"
            )
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func characters(_ directory: URL) throws -> [CharacterConfig] {
        let url = directory.appendingPathComponent("characters/characters.json")
        guard let data = try? Data(contentsOf: url) else {
            throw EidolonError.invalidBundle("当前内容包缺少 characters/characters.json")
        }
        return try JSONDecoder().decode([JSONValue].self, from: data).map(CharacterConfig.init(json:))
    }
}

extension BarPrompt {
    /// Her birthday as she always knows it (upstream `her_birthday`).
    public static func birthday(_ character: CharacterConfig) -> String {
        guard let birthday = character.birthday else { return "" }
        return TodayPrompt.herBirthday(birthday)
    }
}
