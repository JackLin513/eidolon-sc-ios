import Foundation

/// The two complete MLTD outfits validated by this spike.
enum Model3DOutfit: String, CaseIterable, Identifiable {
    case privateClothes = "pr001"
    case stageCostume = "ss003"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privateClothes: "私服"
        case .stageCostume: "演出服"
        }
    }

    var fileName: String { "mirai-\(rawValue).usdz" }
}
