import Metal
import RealityKit

/// Replaces every loaded material with a two-step toon ramp.
///
/// The game shades characters with a ramp plus a rim light rather than a
/// physical BRDF. Under a single directional light a PBR material crushes every
/// surface facing away from it, which reads as damage on limbs.
///
/// Highlights come from the material's second texture slot, `_SubTex`: an
/// additive layer holding the eye catch-light, the hair shine and the costume's
/// neon trim. The exporter folds it into the glTF's emissive texture, so it
/// carries through USD and RealityKit adds it on top of whatever the surface
/// shader writes.
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
        let logNames = ProcessInfo.processInfo.environment["EIDOLON_3D_LOG_MATERIALS"] != nil
        guard let surface = shader(named: "toonSurface") else { return }
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                guard let physical = material as? PhysicallyBasedMaterial,
                      let texture = physical.baseColor.texture
                else { return material }
                if logNames {
                    print("[toon] material name=\(material.name ?? "nil") glow=\(physical.emissiveColor.texture != nil)")
                }
                guard var toon = try? CustomMaterial(
                    surfaceShader: surface,
                    lightingModel: .lit
                ) else { return material }
                if let customTexture = try? CustomMaterial.Texture(texture) {
                    toon.custom.texture = customTexture
                }
                // Binding the glow only; the surface shader adds it. A white
                // tint here would let the lit model add the same layer twice.
                if let glow = physical.emissiveColor.texture,
                   let glowTexture = try? CustomMaterial.Texture(glow) {
                    toon.emissiveColor = .init(color: .black, texture: glowTexture)
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
