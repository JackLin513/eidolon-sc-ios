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
        // Unlit by default: the surface shader already produces the final
        // colour, and a lit model would run RealityKit's own PBR on top of it.
        // `EIDOLON_3D_LIT` is kept as the A/B escape hatch.
        let lightingModel: CustomMaterial.LightingModel =
            environment["EIDOLON_3D_LIT"] != nil ? .lit : .unlit
        guard let surface = shader(named: "toonSurface") else { return }
        // Thickness is a model-space distance, and the USD models arrive at all
        // kinds of authored scales, so derive it from the mesh rather than
        // hard-coding a number that only suited one asset.
        let height = entity.visualBounds(relativeTo: nil).extents.y
        let thickness = max(height * 0.003, 0.000_001)
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
                let mipmaps = environment["EIDOLON_3D_MIPMAPS"] != nil
                var custom = CustomMaterial.Custom(
                    value: SIMD4(
                        Float(row ?? 0),
                        row == nil ? 0 : 1,
                        debug ? 1 : (noSheen ? -1 : 0),
                        normals ? 2 : (mipmaps ? 1 : (constant ? -1 : 0))
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

    /// A black inverted hull behind the model, matching the game's outline pass.
    ///
    /// `lightingModel: .unlit` is what makes this cheap: RealityKit binds no
    /// textures for an unlit custom material, so it renders a flat silhouette —
    /// exactly the fill an outline wants. Front faces are culled so only the
    /// pushed-out back shell is drawn.
    static func applyOutline(to entity: Entity) {
        guard let surface = shader(named: "outlineSurface"),
              let vertex = geometryModifier(named: "outlineVertex")
        else { return }
        // Thickness is a model-space distance, and the USD models arrive at all
        // kinds of authored scales, so derive it from the mesh rather than
        // hard-coding a number that only suited one asset.
        let height = entity.visualBounds(relativeTo: nil).extents.y
        let thickness = max(height * 0.003, 0.000_001)
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                guard var outline = try? CustomMaterial(
                    surfaceShader: surface,
                    geometryModifier: vertex,
                    lightingModel: .unlit
                ) else { return material }
                outline.faceCulling = .front
                outline.custom.value = SIMD4(thickness, 0, 0, 0)
                return outline
            }
            entity.components[ModelComponent.self] = model
        }
        for child in entity.children {
            applyOutline(to: child)
        }
    }

    private static func geometryModifier(named name: String) -> CustomMaterial.GeometryModifier? {
        guard let library else { return nil }
        return CustomMaterial.GeometryModifier(named: name, in: library)
    }
}
