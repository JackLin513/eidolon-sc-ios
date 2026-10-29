#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// Two-step ramp: what the game gets from its toon lookup texture, without
// shipping the lookup itself.
[[visible]]
void toonSurface(realitykit::surface_parameters params)
{
    constexpr sampler textureSampler(filter::linear, mip_filter::linear, address::repeat);
    // RealityKit's built-in materials flip V for us; a custom surface shader gets
    // the raw UV, so flip it back before sampling.
    float2 uv = params.geometry().uv0();
    half3 albedo = params.textures().custom().sample(textureSampler, float2(uv.x, 1.0 - uv.y)).rgb;

    float3 normal = normalize(params.geometry().normal());
    // Fixed key light: the preview framing never moves, so the ramp does not
    // need a uniform. Passing it through uniforms() is not exposed to surface
    // shaders on this SDK.
    float3 light = normalize(float3(-0.35, 0.55, 0.75));
    float lambert = saturate(dot(normal, light));

    // Lit, half-lit, shadow. The shadow step keeps the darkest tone well above
    // black so a single directional light cannot crush a whole limb.
    float ramp = lambert > 0.55 ? 1.0 : (lambert > 0.15 ? 0.82 : 0.66);

    params.surface().set_base_color(albedo * half3(ramp));
    params.surface().set_metallic(0.0);
    params.surface().set_roughness(1.0);
}
