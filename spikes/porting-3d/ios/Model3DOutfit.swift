import Foundation

/// One exported character model on disk: a USDZ plus the shading constants the
/// exporter wrote beside it.
///
/// The spike started with two hard-coded outfits. Once the corpus is being
/// batch-exported a model is just three files sharing a stem, so the list is
/// discovered instead: `Resources` in the bundle for anything shipped, and
/// Documents for a model dropped in without rebuilding.
struct Model3DOutfit: Identifiable, Hashable {
    /// File stem, unique per model: `mirai-pr001`, or the costume id the batch
    /// exporter used.
    let id: String
    /// Shown on the button.
    let title: String
    /// Idol the materials belong to, parsed from the material names
    /// (`cb_pr001_014mir_01_m` → `014mir`). Grouping by it is what turns one flat
    /// list into a character picker.
    let character: String
    /// Folder the three files live in. The batch corpus gives every outfit its
    /// own directory, so the sidecars cannot be found by name alone.
    let directory: URL
    let fileName: String
    let materialsFileName: String
    let parametersFileName: String

    /// Everything found on disk, stable-sorted so the buttons do not dance
    /// between launches.
    static let all: [Model3DOutfit] = discover()

    static let fallback = Model3DOutfit(
        id: "mirai-pr001",
        title: "私服",
        character: "014mir",
        directory: URL.documentsDirectory,
        fileName: "mirai-pr001.usdz",
        materialsFileName: "mirai-pr001-materials.json",
        parametersFileName: "mirai-pr001-params.png"
    )

    /// The picker's default: the first model that actually resolved.
    static var initial: Model3DOutfit { all.first ?? fallback }

    /// What the preview opens on. `EIDOLON_3D_START` picks another one by id
    /// prefix (`003mik`), so a screenshot run can land on a character without
    /// driving the picker.
    static var starting: Model3DOutfit {
        guard let prefix = ProcessInfo.processInfo.environment["EIDOLON_3D_START"],
              let match = all.first(where: { $0.id.hasPrefix(prefix) })
        else { return initial }
        return match
    }

    static func characters(_ outfits: [Model3DOutfit]) -> [String] {
        outfits.reduce(into: [String]()) { list, outfit in
            if !list.contains(outfit.character) { list.append(outfit.character) }
        }
    }

    static func outfits(of character: String, in outfits: [Model3DOutfit]) -> [Model3DOutfit] {
        outfits.filter { $0.character == character }
    }

    // MARK: - Discovery

    private static func discover() -> [Model3DOutfit] {
        // Documents is ours alone, so it is walked recursively: the batch
        // corpus puts every outfit in its own folder. The bundle is not — it
        // carries thousands of framework files and walking it delayed the
        // first model by seconds.
        var roots: [(root: URL, recursive: Bool)] = [
            (URL.documentsDirectory, true),
            (URL.documentsDirectory.appending(path: "models"), true),
        ]
        if let resources = Bundle.main.resourceURL {
            roots.append((resources, false))
            roots.append((resources.appending(path: "models"), false))
        }

        var found: [Model3DOutfit] = []
        var seen = Set<String>()
        for (root, recursive) in roots {
            for materials in files(under: root, suffix: "-materials.json", recursive: recursive) {
                let stem = materials.lastPathComponent
                    .replacingOccurrences(of: "-materials.json", with: "")
                guard seen.insert(stem).inserted else { continue }
                let usdz = materials.deletingLastPathComponent()
                    .appending(path: "\(stem).usdz")
                guard FileManager.default.fileExists(atPath: usdz.path) else { continue }
                found.append(
                    Model3DOutfit(
                        id: stem,
                        title: title(for: stem),
                        character: character(in: materials),
                        directory: materials.deletingLastPathComponent(),
                        fileName: usdz.lastPathComponent,
                        materialsFileName: materials.lastPathComponent,
                        parametersFileName: "\(stem)-params.png"
                    )
                )
            }
        }
        return found.sorted { $0.id < $1.id }
    }

    /// Shallow by default: the app bundle carries thousands of framework files,
    /// and walking it at launch delayed the first model by seconds. Corpus
    /// models are dropped flat into the root, into a `models` folder, or — for
    /// a batch export — into one folder per outfit.
    private static func files(under root: URL, suffix: String, recursive: Bool) -> [URL] {
        if recursive {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey]
            ) else { return [] }
            return walker.compactMap { $0 as? URL }
                .filter { $0.lastPathComponent.hasSuffix(suffix) }
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        return contents.filter { $0.lastPathComponent.hasSuffix(suffix) }
    }

    private static func title(for stem: String) -> String {
        switch stem {
        case "mirai-pr001": return "私服"
        case "mirai-ss003": return "演出服"
        default:
            // The corpus names a model `<idol>-<costume>`; the picker already
            // groups by idol, so the button only has to say which outfit.
            guard let costume = stem.split(separator: "-").last.map(String.init) else {
                return stem
            }
            switch costume.prefix(2) {
            case "pr": return "私服"
            case "ss": return "演出服 \(costume)"
            case "gs": return "衣装 \(costume)"
            default: return costume
            }
        }
    }

    /// Reads the idol id out of the material table. Every character bundle names
    /// its materials `<kind>_<costume>_<idol>_<part>_m`, so one material is
    /// enough — and the table is more reliable than the file name the exporter
    /// happened to choose.
    private static func character(in materials: URL) -> String {
        guard let data = try? Data(contentsOf: materials),
              let table = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = table["materials"] as? [String: Any],
              let sample = rows.keys.sorted().first
        else { return "unknown" }
        let parts = sample.split(separator: "_")
        return parts.count >= 3 ? String(parts[2]) : "unknown"
    }
}
