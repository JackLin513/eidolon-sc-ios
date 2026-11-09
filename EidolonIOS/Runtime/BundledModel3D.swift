import EidolonCore
import Foundation

/// The 3D build ships its generated `Unity3DContent` folder as a convenience until the
/// producer imports a `model3d` package through the UI. The package remains the source of
/// truth; this is a local fallback for the 3D smoke build only.
enum BundledModel3D {
    private struct RawManifest: Decodable {
        struct Character: Decodable {
            let id: String
            let outfits: [String: [String: String]]
        }
        let characters: [Character]
        let emotionMap: String

        enum CodingKeys: String, CodingKey {
            case characters
            case emotionMap = "emotion_map"
        }
    }

    private struct RawEmotionMap: Decodable {
        struct Emotion: Decodable { let name: String }
        let emotions: [String: Emotion]
    }

    static func load() -> (manifest: Model3DManifest, root: URL)? {
        guard let root = Bundle.main.url(forResource: "Unity3DContent", withExtension: nil),
              let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let raw = try? JSONDecoder().decode(RawManifest.self, from: data)
        else { return nil }

        var emotionMap: [String: String] = [:]
        if let emotionData = try? Data(
            contentsOf: root.appendingPathComponent(raw.emotionMap)
        ), let emotions = try? JSONDecoder().decode(RawEmotionMap.self, from: emotionData) {
            for (key, value) in emotions.emotions {
                emotionMap[key] = value.name
            }
        }

        let characters = raw.characters.map { character in
            Model3DCharacter(
                localID: character.id,
                model: character.id,
                outfits: character.outfits.keys.sorted(),
                emotionMap: emotionMap
            )
        }
        // The prototype content bundle uses `haruka3d`; the native model is `001har`.
        var withAlias = characters
        if let first = characters.first,
           !characters.contains(where: { $0.localID == "haruka3d" }) {
            withAlias.append(
                Model3DCharacter(
                    localID: "haruka3d",
                    model: first.model,
                    outfits: first.outfits,
                    emotionMap: first.emotionMap
                )
            )
        }

        let manifest = Model3DManifest(
            franchise: "mltd",
            runtime: RuntimeRequirement(
                preferred: .unityUaaL,
                fallbacks: [.spineWebGL, .avatar]
            ),
            files: [],
            characters: withAlias
        )
        return (manifest, root)
    }
}
