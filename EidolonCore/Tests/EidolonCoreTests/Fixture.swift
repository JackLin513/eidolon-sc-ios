import Foundation
import GRDB
import ZIPFoundation
@testable import EidolonCore

/// Builds small, complete content bundles for the import tests.
enum Fixture {
    struct Options {
        var formatVersion = 1
        var schemaVersion = 1
        var model = "test-embed"
        var dimensions = 4
        var embedPassages = true
        var corruptCRC = false
        var manifestModel: String? = nil
        /// One vector per passage, in order; the default is all-equal vectors.
        var vectors: [[Float]]? = nil
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

        let characters: [JSONValue] = [
            .object([
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
            ]),
            .object([
                "id": .string("hiori"),
                "name": .string("風野灯織"),
                "sheet": .string("characters/sheets/hiori.md"),
                "speakers": .array([.string("灯織")]),
                "idol_id": .int(2),
            ]),
        ]
        let charactersData = try JSONEncoder().encode(characters)
        try charactersData.write(to: charactersDirectory.appendingPathComponent("characters.json"))
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
        let avatarsDirectory = charactersDirectory.appendingPathComponent("avatars", isDirectory: true)
        try FileManager.default.createDirectory(at: avatarsDirectory, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: avatarsDirectory.appendingPathComponent("mano.jpg"))

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
        return [
            "episodes": 2,
            "episode_cast": 2,
            "episode_lines": 2,
            "episode_passages": 3,
        ]
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
            files[relative] = ContentManifest.FileRecord(size: data.count, crc32: crc)
        }

        return ContentManifest(
            formatVersion: options.formatVersion,
            contentSchemaVersion: options.schemaVersion,
            createdAt: "2026-10-23T00:00:00Z",
            embedding: .init(model: options.manifestModel ?? options.model, dimensions: options.dimensions),
            content: counts,
            characters: .init(count: characterIDs.count, ids: characterIDs),
            files: files
        )
    }

    private static func relativePath(of url: URL, in directory: URL) -> String {
        let base = directory.resolvingSymlinksInPath().pathComponents
        let full = url.resolvingSymlinksInPath().pathComponents
        return full.dropFirst(base.count).joined(separator: "/")
    }

    private static func zip(_ directory: URL, to destination: URL) throws -> URL {
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
