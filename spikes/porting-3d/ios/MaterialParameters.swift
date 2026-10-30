import Foundation
import RealityKit

/// The game's per-material shading constants, carried beside the USDZ.
///
/// A `CustomMaterial` only exposes about a dozen scalar slots, but each MLTD
/// material carries eleven colours and up to thirty-eight floats. The exporter
/// bakes them into a small atlas texture whose alpha channel holds one byte per
/// parameter, and this type maps a material name onto its row.
///
/// Alpha, not RGB: colour channels are colour managed on the way to the GPU, so
/// a PNG value would come back linearised. The texel order is
/// `spikes/porting-3d/material_atlas.py`'s `LAYOUT`, mirrored by the `kParam*`
/// constants in `ToonShading.metal`.
@MainActor
struct MaterialParameters {
    /// Rows the atlas is sized for; the shader's V coordinate is a compile-time
    /// constant, so this matches `kParamCapacity` in `ToonShading.metal`.
    static let capacity = 64

    private let texture: TextureResource
    private let rows: [String: Int]
    /// Materials the game renders with alpha blending. They must keep their
    /// alpha on the device and must not be given an outline pass.
    private let blended: Set<String>
    /// Rows whose shader variant actually has an OUTLINE pass. The game builds
    /// it by putting a second pass on top of the `*_NoOutline` base, and only
    /// five shaders do that; everything else — decals, eyes, alpha — is a
    /// single pass, so a hull built for them is geometry the game never draws.
    private let outlined: Set<Int>

    static func load(atlas: URL, table: URL) async -> MaterialParameters? {
        guard let data = try? Data(contentsOf: table),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              let rows = rowIndices(document),
              let texture = try? await TextureResource(contentsOf: atlas)
        else { return nil }
        let blended = Set(document.materials.filter { $0.value.shader.hasSuffix("Chr_Alpha") }
            .map(\.key))
        let outlined = Set(document.rows.indices.filter {
            outlinedShaders.contains(document.materials[document.rows[$0]]?.shader ?? "")
        })
        return MaterialParameters(
            texture: texture, rows: rows, blended: blended, outlined: outlined
        )
    }

    private static func rowIndices(_ document: Document) -> [String: Int]? {
        // The exporter writes the row order; sorting here instead would be a
        // second source of truth for the same table.
        guard document.rows.count == document.materials.count,
              document.rows.allSatisfy({ document.materials[$0] != nil }),
              document.rows.count <= capacity
        else { return nil }
        return Dictionary(uniqueKeysWithValues: document.rows.enumerated().map { ($1, $0) })
    }

    /// The shader variants that carry a second, outline pass. Two independent
    /// tells from the game's own assets agree on this list: these are the
    /// `Custom/Chr_*` shaders with two passes in `m_ParsedForm`, and the ones
    /// that ship a `*_NoOutline` sibling. `Chr_CutOff` and `Chr_Alpha` have
    /// neither, so they never had a hull to lose.
    private static let outlinedShaders: Set<String> = [
        "Custom/Chr_Basic",
        "Custom/Chr_Color",
        "Custom/Chr_Face",
        "Custom/Chr_Glow",
        "Custom/Chr_Hair",
        "Custom/Chr_Span",
    ]

    func isBlended(_ material: String) -> Bool {
        blended.contains(material)
    }

    /// Whether the material in this atlas row gets an outline pass in the game.
    func hasOutline(row: Int) -> Bool {
        outlined.contains(row)
    }

    /// The row index for a material name, or `nil` when the table does not know it.
    func row(for material: String) -> Int? {
        rows[material]
    }

    var textureResource: TextureResource { texture }

    private struct Document: Decodable {
        let rows: [String]
        let materials: [String: Material]
    }

    private struct Material: Decodable {
        let shader: String
    }
}
