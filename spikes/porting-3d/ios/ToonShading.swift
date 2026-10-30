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
                if logNames {
                    print("[blend] \(name) blended=\(parameters?.isBlended(name) == true)")
                }
                if parameters?.isBlended(name) == true {
                    // The shader already multiplies by its own alpha, so the
                    // blend stage must not scale by opacity again.
                    toon.blending = .transparent(opacity: 1.0)
                }
                let environment = ProcessInfo.processInfo.environment
                let debug = environment["EIDOLON_3D_LUT_DEBUG"] != nil
                let normals = environment["EIDOLON_3D_DEBUG_NORMALS"] != nil
                let constant = environment["EIDOLON_3D_DEBUG_CONST"] != nil
                let noSheen = environment["EIDOLON_3D_NO_SHEEN"] != nil
                let noReflect = environment["EIDOLON_3D_NO_REFLECT"] != nil
                let cubeProbe = environment["EIDOLON_3D_DEBUG_CUBE"] != nil
                let spanProbe = environment["EIDOLON_3D_DEBUG_SPAN"] != nil
                let albedoProbe = environment["EIDOLON_3D_DEBUG_ALBEDO"] != nil
                // `EIDOLON_3D_ISOLATE_ROW=4` draws one atlas row on its own, as
                // flat albedo. The row travels in `custom.z` as -100 - row so it
                // does not collide with the probes that already live there.
                let isolateRow = Float(environment["EIDOLON_3D_ISOLATE_ROW"] ?? "")
                // `EIDOLON_3D_DEBUG_MASTER=1` paints every material a flat,
                // distinct colour. One screenshot then says which atlas row owns
                // each piece of the costume — no guessing from silhouettes.
                let master = environment["EIDOLON_3D_DEBUG_MASTER"] != nil
                let mipmaps = environment["EIDOLON_3D_MIPMAPS"] != nil
                let alphaProbe = environment["EIDOLON_3D_DEBUG_ALPHA"] != nil
                var custom = CustomMaterial.Custom(
                    value: SIMD4(
                        Float(row ?? 0),
                        row == nil ? 0 : 1,
                        debug ? 1 : (master ? -200 : (isolateRow.map { -100 - $0 } ?? (albedoProbe ? -4 : (spanProbe ? -3 : (noReflect ? -2 : (noSheen ? -1 : 0)))))),
                        alphaProbe ? -2 : (normals ? 2 : (mipmaps ? 1 : (cubeProbe ? 3 : (constant ? -1 : 0))))
                    )
                )
                // `_MainTex` stays in `custom`, the slot it has always worked
                // in. The effect maps take `base_color`: a `CustomMaterial`
                // starts with a white, textureless base colour — the USD
                // `diffuseColor` binding does not survive — so that slot is
                // ours to fill. Binding both at once makes `custom()` read back
                // unbound, so exactly one of the two may be used per material.
                if let base = physical.baseColor.texture,
                   let baseTexture = try? CustomMaterial.Texture(base) {
                    custom.texture = baseTexture
                }
                if let effect = parameters?.effectTexture(for: name) {
                    toon.baseColor = CustomMaterial.BaseColor(tint: .white, texture: effect)
                    // `Chr_Span` is an overlay shell drawn on top of the plain
                    // material; its faces may wind the other way, and back-face
                    // culling then drops the whole layer.
                    toon.faceCulling = .none
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
    static func applyOutline(to entity: Entity, parameters: MaterialParameters?) {
        guard let surface = shader(named: "outlineSurface"),
              let vertex = geometryModifier(named: "outlineVertex")
        else { return }
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                // Blending materials have no OUTLINE pass in the game. Ask the
                // material's own blending, not the name table: `CustomMaterial`
                // exposes `name` as get-only, so anything `apply` builds is
                // nameless and `isBlended("")` answers false — which is how the
                // alpha materials ended up wearing a pure-black hull.
                if let toon = material as? CustomMaterial {
                    if case .transparent = toon.blending { return material }
                    // Only five shader variants have an OUTLINE pass. A decal,
                    // an eye or a cutout has a single pass, and the hull we
                    // built for it has no `_OutlineColor` to draw with — the
                    // black rectangle on 003mik's pendant was one of these.
                    let value = toon.custom.value
                    if value.y > 0.5, parameters?.hasOutline(row: Int(value.x)) == false {
                        return material
                    }
                }
                guard var outline = try? CustomMaterial(
                    surfaceShader: surface,
                    geometryModifier: vertex,
                    lightingModel: .unlit
                ) else { return material }
                outline.faceCulling = .front
                // Carry the parameter atlas and its row across: the outline pass
                // needs the same `_OutlineColor` as the material it stands
                // behind, and the atlas rides in the specular slot.
                if let source = material as? CustomMaterial {
                    outline.specular = source.specular
                    outline.custom = source.custom
                }
                return outline
            }
            entity.components[ModelComponent.self] = model
        }
        for child in entity.children {
            applyOutline(to: child, parameters: parameters)
        }
    }

    private static func geometryModifier(named name: String) -> CustomMaterial.GeometryModifier? {
        guard let library else { return nil }
        return CustomMaterial.GeometryModifier(named: name, in: library)
    }
}
