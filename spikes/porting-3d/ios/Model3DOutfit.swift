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
        fileName: "mirai-pr001.usdz",
        materialsFileName: "mirai-pr001-materials.json",
        parametersFileName: "mirai-pr001-params.png"
    )

    /// The picker's default: the first model that actually resolved.
    static var initial: Model3DOutfit { all.first ?? fallback }

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
        var roots: [URL] = [URL.documentsDirectory]
        if let resources = Bundle.main.resourceURL {
            roots.append(resources)
            roots.append(resources.appending(path: "models"))
        }

        var found: [Model3DOutfit] = []
        var seen = Set<String>()
        for root in roots {
            for materials in files(under: root, suffix: "-materials.json") {
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
                        fileName: usdz.lastPathComponent,
                        materialsFileName: materials.lastPathComponent,
                        parametersFileName: "\(stem)-params.png"
                    )
                )
            }
        }
        return found.sorted { $0.id < $1.id }
    }

    /// Deliberately shallow: the app bundle carries thousands of framework
    /// files, and walking it at launch delayed the first model by seconds.
    /// Corpus models are dropped flat into the root or into a `models` folder.
    private static func files(under root: URL, suffix: String) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        return contents.filter { $0.lastPathComponent.hasSuffix(suffix) }
    }

    private static func title(for stem: String) -> String {
        switch stem {
        case "mirai-pr001": "私服"
        case "mirai-ss003": "演出服"
        default: stem
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
