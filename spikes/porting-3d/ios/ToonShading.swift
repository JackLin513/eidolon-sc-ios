import Metal
import RealityKit

/// Replaces every loaded material with a two-step toon ramp.
///
/// The game shades characters with a ramp plus a rim light rather than a
/// physical BRDF. Under a single directional light a PBR material crushes every
/// surface facing away from it, which reads as damage on limbs.
@MainActor
enum ToonShading {
    private static let surface: CustomMaterial.SurfaceShader? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary()
        else { return nil }
        return CustomMaterial.SurfaceShader(named: "toonSurface", in: library)
    }()

    static func apply(to entity: Entity) {
        guard let surface else { return }
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                guard let physical = material as? PhysicallyBasedMaterial,
                      let texture = physical.baseColor.texture
                else { return material }
                guard var toon = try? CustomMaterial(
                    surfaceShader: surface,
                    lightingModel: .lit
                ) else { return material }
                if let customTexture = try? CustomMaterial.Texture(texture) {
                    toon.custom.texture = customTexture
                }
                return toon
            }
            entity.components[ModelComponent.self] = model
        }
        for child in entity.children {
            apply(to: child)
        }
    }
}
