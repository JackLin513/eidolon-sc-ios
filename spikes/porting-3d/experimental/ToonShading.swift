import RealityKit
import SwiftUI

/// Replaces every loaded material with a two-step toon ramp.
///
/// The game shades its characters with a ramp plus a rim light rather than a
/// physical BRDF; under a single directional light a PBR material crushes every
/// face that points away from it, which is what made limbs look broken.
@MainActor
enum ToonShading {
    /// Direction the key light travels in view space, matching the light the
    /// preview puts on the model.
    private static let lightDirection = SIMD4<Float>(0.35, 0.55, 0.75, 0)

    static func apply(to entity: Entity) {
        applyRecursively(to: entity)
    }

    private static func applyRecursively(to entity: Entity) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                guard let physical = material as? PhysicallyBasedMaterial else {
                    return material
                }
                return toon(from: physical)
            }
            entity.components[ModelComponent.self] = model
        }
        for child in entity.children {
            applyRecursively(to: child)
        }
    }

    private static func toon(from physical: PhysicallyBasedMaterial) -> RealityKit.Material {
        var toon = CustomMaterial(
            surfaceShader: ShaderLibrary.default.toonSurface,
            lightingModel: .lit
        )
        toon.custom.value = lightDirection
        if let texture = physical.baseColor.texture {
            toon.custom.texture = .init(texture)
        } else {
            let tint = physical.baseColor.tint
            toon.custom.texture = .init(.init(color: UIColor(
                red: CGFloat(tint.x),
                green: CGFloat(tint.y),
                blue: CGFloat(tint.z),
                alpha: 1
            )))
        }
        return toon
    }
}
