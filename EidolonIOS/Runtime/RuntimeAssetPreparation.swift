import EidolonCore
import Foundation

/// Fills a page's `RuntimeAssets` with the optional 3D mapping. Kept separate from
/// `AppModel` so the "prepare must see what the factory saw" seam is testable.
enum RuntimeAssetPreparation {
    static func fill(
        _ assets: RuntimeAssets,
        manifest: Model3DManifest?,
        root: URL?
    ) -> RuntimeAssets {
        var assets = assets
        guard let manifest, let root,
              let character = manifest.character(localID: assets.characterID)
        else { return assets }
        assets.model3D = character
        assets.model3DRoot = root
        return assets
    }
}
