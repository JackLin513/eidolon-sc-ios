#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// Two-step ramp: what the game gets from its toon lookup texture, without
// shipping the lookup itself.
[[visible]]
void toonSurface(realitykit::surface_parameters params)
{
    constexpr sampler textureSampler(filter::linear, mip_filter::linear, address::repeat);
    half3 albedo = params.textures().custom().sample(textureSampler, params.geometry().uv0()).rgb;

    float3 normal = normalize(params.geometry().normal());
    float3 light = normalize(params.uniforms().custom()[0].xyz);
    float lambert = saturate(dot(normal, light));

    // Lit, half-lit, shadow. The shadow step keeps the darkest tone well above
    // black so a single directional light cannot crush a whole limb.
    float ramp = lambert > 0.55 ? 1.0 : (lambert > 0.15 ? 0.82 : 0.66);

    params.surface().set_base_color(albedo * half3(ramp));
    params.surface().set_metallic(0.0);
    params.surface().set_roughness(1.0);
}
