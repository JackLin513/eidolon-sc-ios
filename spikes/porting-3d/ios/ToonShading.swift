import Metal
import RealityKit

/// Replaces every loaded material with the game's character shading.
///
/// MLTD does not use a physical BRDF: each material carries its own ambient
/// colour, light direction, shading thresholds and rim settings, and the shader
/// combines them with a two-step ramp plus an additive `_SubTex` highlight
/// layer. Those constants arrive in `MaterialParameters`; each material is told
/// its row through `custom.value.x` and the table itself rides in the otherwise
/// unused `specular` texture slot.
@MainActor
enum ToonShading {
    private static let library: MTLLibrary? = {
        MTLCreateSystemDefaultDevice()?.makeDefaultLibrary()
    }()

    private static func shader(named name: String) -> CustomMaterial.SurfaceShader? {
        guard let library else { return nil }
        return CustomMaterial.SurfaceShader(named: name, in: library)
    }

    static func apply(to entity: Entity, parameters: MaterialParameters?) {
        let environment = ProcessInfo.processInfo.environment
        let logNames = environment["EIDOLON_3D_LOG_MATERIALS"] != nil
        let lightingModel: CustomMaterial.LightingModel =
            environment["EIDOLON_3D_UNLIT"] != nil ? .unlit : .lit
        guard let surface = shader(named: "toonSurface") else { return }
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                guard let physical = material as? PhysicallyBasedMaterial,
                      let texture = physical.baseColor.texture
                else { return material }
                let name = material.name ?? ""
                let row = parameters?.row(for: name)
                if logNames {
                    let glow = physical.emissiveColor.texture != nil
                    print("[toon] material name=\(name) glow=\(glow) row=\(row.map(String.init) ?? "nil")")
                }
                // `.unlit` looks like the right model for a toon ramp, but it
                // stops binding `custom` and `emissive`: the character renders
                // as a black silhouette. Stay on `.lit` and tame its PBR pass
                // with roughness instead.
                guard var toon = try? CustomMaterial(
                    surfaceShader: surface,
                    lightingModel: lightingModel
                ) else { return material }
                let environment = ProcessInfo.processInfo.environment
                let debug = environment["EIDOLON_3D_LUT_DEBUG"] != nil
                let normals = environment["EIDOLON_3D_DEBUG_NORMALS"] != nil
                let constant = environment["EIDOLON_3D_DEBUG_CONST"] != nil
                let noSheen = environment["EIDOLON_3D_NO_SHEEN"] != nil
                var custom = CustomMaterial.Custom(
                    value: SIMD4(
                        Float(row ?? 0),
                        row == nil ? 0 : 1,
                        debug ? 1 : (noSheen ? -1 : 0),
                        normals ? 1 : (constant ? -1 : 0)
                    )
                )
                if let customTexture = try? CustomMaterial.Texture(texture) {
                    custom.texture = customTexture
                }
                toon.custom = custom
                // Binding the glow only; the surface shader adds it, so a white
                // tint here would apply the same layer twice.
                if let glow = physical.emissiveColor.texture,
                   let glowTexture = try? CustomMaterial.Texture(glow) {
                    toon.emissiveColor = .init(color: .black, texture: glowTexture)
                }
                if let parameters,
                   let lut = try? CustomMaterial.Texture(parameters.textureResource) {
                    toon.specular = .init(scale: 1, texture: lut)
                }
                return toon
            }
            entity.components[ModelComponent.self] = model
        }
        for child in entity.children {
            apply(to: child, parameters: parameters)
        }
    }
}
