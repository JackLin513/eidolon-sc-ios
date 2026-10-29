import Metal
import RealityKit

/// Replaces every loaded material with a two-step toon ramp.
///
/// The game shades characters with a ramp plus a rim light rather than a
/// physical BRDF. Under a single directional light a PBR material crushes every
/// surface facing away from it, which reads as damage on limbs.
@MainActor
enum ToonShading {
    private static let library: MTLLibrary? = {
        MTLCreateSystemDefaultDevice()?.makeDefaultLibrary()
    }()

    private static func shader(named name: String) -> CustomMaterial.SurfaceShader? {
        guard let library else { return nil }
        return CustomMaterial.SurfaceShader(named: name, in: library)
    }

    static func apply(to entity: Entity) {
        guard let surface = shader(named: "toonSurface"),
              let eye = shader(named: "eyeSurface")
        else { return }
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                guard let physical = material as? PhysicallyBasedMaterial,
                      let texture = physical.baseColor.texture
                else { return material }
                let isEye = (physical.baseColor.texture != nil)
                    && (material.name ?? "").contains("eye")
                guard var toon = try? CustomMaterial(
                    surfaceShader: isEye ? eye : surface,
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
