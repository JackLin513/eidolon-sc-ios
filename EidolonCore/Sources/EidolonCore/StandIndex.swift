import Foundation

/// What is installed in the stand directory: every stand file's path, size and CRC32.
/// The exporter compares this with its source tree to build a delta bundle (ADR-0020).
public struct StandIndex: Codable, Sendable, Hashable {
    public static let supportedFormatVersion = 1

    public struct File: Codable, Sendable, Hashable {
        public var size: Int
        public var crc32: String?

        public init(size: Int, crc32: String? = nil) {
            self.size = size
            self.crc32 = crc32
        }
    }

    public var formatVersion: Int
    /// Paths relative to the stand directory, for example `stand/idols/.../data.json`.
    public var files: [String: File]

    public init(formatVersion: Int = StandIndex.supportedFormatVersion, files: [String: File]) {
        self.formatVersion = formatVersion
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case files
    }

    /// The index as the stand directory has it; nil when none was written yet.
    public static func read(at root: URL) -> StandIndex? {
        let url = root.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(StandIndex.self, from: data),
              index.formatVersion == supportedFormatVersion
        else { return nil }
        return index
    }

    /// Scan the stand directory, leaving the manifest and the index itself out.
    public static func scan(at root: URL, fileManager: FileManager = .default) throws -> StandIndex {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return StandIndex(files: [:])
        }
        let base = root.standardizedFileURL.pathComponents
        var files: [String: File] = [:]
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                ?? false
            if isDirectory { continue }
            let relative = url.standardizedFileURL.pathComponents
                .dropFirst(base.count)
                .joined(separator: "/")
            guard !relative.isEmpty, relative != "manifest.json", relative != "index.json",
                  let data = try? Data(contentsOf: url)
            else { continue }
            files[relative] = File(size: data.count, crc32: CRC32.hex(data))
        }
        return StandIndex(files: files)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func write(to root: URL) throws {
        try encoded().write(
            to: root.appendingPathComponent("index.json"),
            options: .atomic
        )
    }
}
