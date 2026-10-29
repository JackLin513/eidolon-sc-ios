#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// Two-step ramp: what the game gets from its toon lookup texture, without
// shipping the lookup itself.
[[visible]]
void toonSurface(realitykit::surface_parameters params)
{
    // The card textures are atlases; sampling their mip chain bleeds neighbouring
    // islands into each other, which showed up as colour patches on the hair.
    // Clamp as well, so UVs a hair outside [0, 1] cannot wrap to the far edge.
    constexpr sampler textureSampler(
        filter::linear,
        mip_filter::none,
        address::clamp_to_edge
    );
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

    // Two tones with a soft edge. Hard steps band badly on a low-poly face,
    // which reads as scars, so the transition is a smoothstep and the shadow
    // tone stays well above black.
    float ramp = mix(0.80, 1.0, smoothstep(0.15, 0.55, lambert));

    params.surface().set_base_color(albedo * half3(ramp));
    params.surface().set_metallic(0.0);
    params.surface().set_roughness(1.0);
}
