import Foundation
import GRDB
import ZIPFoundation
@testable import EidolonCore

/// Builds small, complete content bundles for the import tests.
enum Fixture {
    /// The holiday table the exporter writes, in miniature.
    static let holidays = [
        "2026-01-01": "元日",
        "2026-02-11": "建国記念の日",
    ]

    /// What `characters/world.json` holds, when the bundle carries one.
    enum WorldJSON {
        case none
        case valid
        /// A truncated file, as a bad export leaves it.
        case broken
    }

    struct Options {
        var formatVersion = ContentManifest.supportedFormatVersion
        var schemaVersion = 1
        var model = "test-embed"
        var dimensions = 4
        var embedPassages = true
        var corruptCRC = false
        /// Corrupts the CRC recorded for a stand file, leaving the database alone.
        var corruptStandCRC = false
        var manifestModel: String? = nil
        var includeHolidays = true
        /// One vector per passage, in order; the default is all-equal vectors.
        var vectors: [[Float]]? = nil
        /// Adds her default outfit and outfit list under `stand/`, and a `stand` entry.
        var includeStand = false
        /// Leaves the second card's everyday outfit incomplete on disk.
        var missingStandOutfitFiles = false
        /// Writes a broken outfit list, which the app reads as "no list".
        var unreadableOutfitList = false
        /// Extra `content` counts, e.g. a key that is not a database table.
        var extraContentCounts: [String: Int] = [:]
        var world: WorldJSON = .none
        /// Gives mano a facts file whose headings skip a level.
        var facts = false
        /// Adds an episode in mano's card source that only hiori is cast in.
        var siblingEpisode = false
        /// Writes `characters/readings.json` with the fixture's names.
        var includeReadings = false
    }

    static func makeBundle(in parent: URL, options: Options = Options()) throws -> URL {
        let staging = parent.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let databaseDirectory = staging.appendingPathComponent("content", isDirectory: true)
        let charactersDirectory = staging.appendingPathComponent("characters", isDirectory: true)
        let sheetsDirectory = charactersDirectory.appendingPathComponent("sheets", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sheetsDirectory, withIntermediateDirectories: true)

        let counts = try writeDatabase(
            at: databaseDirectory.appendingPathComponent("eidolon.db"),
            options: options
        )

        var mano: [String: JSONValue] = [
            "id": .string("mano"),
            "name": .string("櫻木真乃"),
            "name_zh": .string("樱木真乃"),
            "name_kana": .string("さくらぎ まの"),
            "name_romaji": .string("Sakuragi Mano"),
            "unit": .string("illumination STARS"),
            "intro": .string("illumination STARS 的中心。"),
            "color": .string("#ffbad6"),
            "voice_id": .string("voice-mano"),
            "sheet": .string("characters/sheets/mano.md"),
            "avatar": .string("characters/avatars/mano.jpg"),
            "speakers": .array([.string("真乃")]),
            "idol_id": .int(1),
            "birthday": .string("04-25"),
        ]
        if options.facts {
            mano["facts"] = .string("characters/facts/mano.md")
        }
        if options.includeStand {
            mano["stand"] = .object([
                "default_outfit": .object([
                    "id": .string("stand/1030010010"),
                    "path": .string("stand/idols/stand/1030010010/"),
                ]),
                "outfits": .string("stand/outfits/1.json"),
            ])
        }
        let characters: [JSONValue] = [
            .object(mano),
            .object([
                "id": .string("hiori"),
                "name": .string("風野灯織"),
                "sheet": .string("characters/sheets/hiori.md"),
                "speakers": .array([.string("灯織")]),
                "idol_id": .int(2),
                "birthday": .string("03-04"),
            ]),
        ]
        let charactersData = try JSONEncoder().encode(characters)
        try charactersData.write(to: charactersDirectory.appendingPathComponent("characters.json"))
        switch options.world {
        case .none:
            break
        case .valid:
            let world: [String: JSONValue] = [
                "as_of": .string("2026-01-01"),
                "office": .object([
                    "name": .string("283プロ"),
                    "staff": .array([]),
                ]),
                "units": .array([]),
                "idols": .array([]),
                "releases": .array([]),
                "songs": .array([]),
                "lives": .array([]),
            ]
            try JSONEncoder().encode(world)
                .write(to: charactersDirectory.appendingPathComponent("world.json"))
        case .broken:
            try Data("{".utf8)
                .write(to: charactersDirectory.appendingPathComponent("world.json"))
        }
        if options.includeHolidays {
            let holidays = try JSONEncoder().encode(Fixture.holidays)
            try holidays.write(to: databaseDirectory.appendingPathComponent("holidays.json"))
        }
        if options.includeReadings {
            let readings: [JSONValue] = [
                .object([
                    "written": .string("櫻木真乃"),
                    "kana": .string("さくらぎ まの"),
                    "phonemes": .string("sa0ku1ra1gi0ma1no0"),
                ]),
                .object([
                    "written": .string("櫻木"),
                    "kana": .string("さくらぎ"),
                    "phonemes": .string("sa0ku1ra1gi0"),
                ]),
                .object([
                    "written": .string("真乃"),
                    "kana": .string("まの"),
                    "phonemes": .string("ma1no0"),
                ]),
                .object([
                    "written": .string("風野灯織"),
                    "kana": .string("かざの ひおり"),
                    "phonemes": .string("kazano0hio0ri1"),
                ]),
                .object([
                    "written": .string("風野"),
                    "kana": .string("かざの"),
                    "phonemes": .string("kazano0"),
                ]),
            ]
            try JSONEncoder().encode(JSONValue.object(["readings": .array(readings)]))
                .write(to: charactersDirectory.appendingPathComponent("readings.json"))
        }
        try "# 真乃\n".write(
            to: sheetsDirectory.appendingPathComponent("mano.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# 灯織\n".write(
            to: sheetsDirectory.appendingPathComponent("hiori.md"),
            atomically: true,
            encoding: .utf8
        )
        if options.facts {
            let factsDirectory = charactersDirectory.appendingPathComponent("facts", isDirectory: true)
            try FileManager.default.createDirectory(at: factsDirectory, withIntermediateDirectories: true)
            try """
                # 人物关系
                ### 風野灯織
                她认真又固执。
                """.write(
                to: factsDirectory.appendingPathComponent("mano.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        let avatarsDirectory = charactersDirectory.appendingPathComponent("avatars", isDirectory: true)
        try FileManager.default.createDirectory(at: avatarsDirectory, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: avatarsDirectory.appendingPathComponent("mano.jpg"))

        if options.includeStand {
            try writeStand(in: staging, options: options)
        }

        let manifest = makeManifest(
            in: staging,
            counts: counts,
            options: options,
            characterIDs: ["mano", "hiori"]
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))

        return try zip(staging, to: parent.appendingPathComponent("bundle.eidolonpkg"))
    }

    private static func writeDatabase(at url: URL, options: Options) throws -> [String: Int] {
        let queue = try DatabaseQueue(path: url.path)
        func vector(_ index: Int) -> Data {
            let values = options.vectors?[index]
                ?? Array(repeating: Float(0.25), count: options.dimensions)
            return values.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        try queue.write { db in
            try db.execute(sql: ContentSchema.ddl)
            try db.execute(sql: "PRAGMA user_version = \(options.schemaVersion)")

            try db.execute(
                sql: """
                    INSERT INTO episodes(id, category, source, title, imported_from, imported_at)
                    VALUES ('e1', 'P卡剧情', 'cards/mano/1', '第一话', 'csv', '2026-01-01T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO episodes(id, category, source, title, imported_from, imported_at)
                    VALUES ('e2', 'P卡剧情', 'cards/hiori/1', '第一话', 'csv', '2026-01-01T00:00:00Z')
                    """
            )
            try db.execute(sql: "INSERT INTO episode_cast(episode_id, character_id) VALUES ('e1', 'mano')")
            try db.execute(sql: "INSERT INTO episode_cast(episode_id, character_id) VALUES ('e2', 'hiori')")
            if options.siblingEpisode {
                try db.execute(
                    sql: """
                        INSERT INTO episodes(id, category, source, title, imported_from, imported_at)
                        VALUES ('e3', 'P卡剧情', 'cards/mano/1', '别人的一话', 'csv', '2026-01-01T00:00:00Z')
                        """
                )
                try db.execute(sql: "INSERT INTO episode_cast(episode_id, character_id) VALUES ('e3', 'hiori')")
            }
            try db.execute(
                sql: """
                    INSERT INTO episode_lines(episode_id, seq, speaker, ja, zh)
                    VALUES ('e1', 1, '真乃', 'ほわっ', '呼哇')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO episode_lines(episode_id, seq, speaker, ja, zh)
                    VALUES ('e2', 1, '灯織', 'はい', '嗯')
                    """
            )

            let embedding = options.embedPassages ? vector(0) : Data()
            try db.execute(
                sql: """
                    INSERT INTO episode_passages(episode_id, seq, text, model, embedding)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: ["e1", 1, "真乃的段落", options.model, embedding]
            )
            try db.execute(
                sql: """
                    INSERT INTO episode_passages(episode_id, seq, text, model, embedding)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: ["e1", 2, "真乃的段落二", options.model, options.embedPassages ? vector(1) : Data()]
            )
            try db.execute(
                sql: """
                    INSERT INTO episode_passages(episode_id, seq, text, model, embedding)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: ["e2", 1, "灯織的段落", options.model, options.embedPassages ? vector(2) : Data()]
            )
        }
        let counts = [
            "episodes": options.siblingEpisode ? 3 : 2,
            "episode_cast": options.siblingEpisode ? 3 : 2,
            "episode_lines": 2,
            "episode_passages": 3,
        ]
        return counts
    }

    /// A stand tree shaped like the exporter writes it: two outfits with three files
    /// each, plus a list whose second card points at an outfit.
    private static func writeStand(in staging: URL, options: Options) throws {
        let standRoot = staging.appendingPathComponent("stand", isDirectory: true)
        let outfits = standRoot.appendingPathComponent("idols", isDirectory: true)
        let complete = [
            "stand/1030010010",
            "stand_costume/1030010010",
        ]
        for outfit in complete {
            let directory = outfits.appendingPathComponent(outfit, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["data.json", "data.atlas", "data.png"] {
                try "\(outfit)/\(name)".write(
                    to: directory.appendingPathComponent(name),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        let second = outfits.appendingPathComponent("stand/1030010020", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try "stand/1030010020/data.json".write(
            to: second.appendingPathComponent("data.json"),
            atomically: true,
            encoding: .utf8
        )
        if !options.missingStandOutfitFiles {
            for name in ["data.atlas", "data.png"] {
                try "stand/1030010020/\(name)".write(
                    to: second.appendingPathComponent(name),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        let lists = standRoot.appendingPathComponent("outfits", isDirectory: true)
        try FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
        let list: [String: JSONValue] = [
            "idol_id": .int(1),
            "cards": .array([
                .object([
                    "id": .string("1030010010"),
                    "name": .string("ナチュラルモード"),
                    "type": .string("P_SR"),
                    "everyday": .object([
                        "id": .string("stand/1030010010"),
                        "url": .string("../idols/stand/1030010010/"),
                        "thumbnail": .null,
                    ]),
                    "stage": .object([
                        "id": .string("stand_costume/1030010010"),
                        "url": .string("../idols/stand_costume/1030010010/"),
                        "thumbnail": .null,
                    ]),
                ]),
                .object([
                    "id": .string("1030010020"),
                    "name": .string("ぐうぜんBOOKS"),
                    "type": .string("P_SR"),
                    "everyday": .object([
                        "id": .string("stand/1030010020"),
                        "url": .string("../idols/stand/1030010020/"),
                        "thumbnail": .null,
                    ]),
                    "stage": .null,
                ]),
            ]),
        ]
        let data = options.unreadableOutfitList
            ? Data("{".utf8)
            : try JSONEncoder().encode(list)
        try data.write(to: lists.appendingPathComponent("1.json"))
    }

    private static func makeManifest(
        in directory: URL,
        counts: [String: Int],
        options: Options,
        characterIDs: [String]
    ) -> ContentManifest {
        var files: [String: ContentManifest.FileRecord] = [:]
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { continue }
            let relative = relativePath(of: url, in: directory)
            let data = (try? Data(contentsOf: url)) ?? Data()
            var crc = CRC32.hex(data)
            if options.corruptCRC, relative.hasPrefix("content/") {
                crc = "deadbeef"
            }
            if options.corruptStandCRC, relative.hasPrefix("stand/") {
                crc = "deadbeef"
            }
            files[relative] = ContentManifest.FileRecord(size: data.count, crc32: crc)
        }

        var content = counts
        if options.includeStand {
            content["stand"] = 10
        }
        for (key, value) in options.extraContentCounts {
            content[key] = value
        }

        return ContentManifest(
            formatVersion: options.formatVersion,
            contentSchemaVersion: options.schemaVersion,
            createdAt: "2026-10-23T00:00:00Z",
            embedding: .init(model: options.manifestModel ?? options.model, dimensions: options.dimensions),
            content: content,
            characters: .init(count: characterIDs.count, ids: characterIDs),
            files: files
        )
    }

    private static func relativePath(of url: URL, in directory: URL) -> String {
        let base = directory.resolvingSymlinksInPath().pathComponents
        let full = url.resolvingSymlinksInPath().pathComponents
        return full.dropFirst(base.count).joined(separator: "/")
    }

    static func zip(_ directory: URL, to destination: URL) throws -> URL {
        try? FileManager.default.removeItem(at: destination)
        let archive = try Archive(url: destination, accessMode: .create)
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { continue }
            let relative = relativePath(of: url, in: directory)
            try archive.addEntry(with: relative, fileURL: url)
        }
        return destination
    }
}
