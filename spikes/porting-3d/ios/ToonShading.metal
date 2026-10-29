#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// Fixed key light: the preview framing never moves, so the ramp does not need a
// uniform. Passing it through uniforms() is not exposed to surface shaders on
// this SDK.
constant float3 kLightDirection = float3(-0.35, 0.55, 0.75);
constant float3 kViewDirection = float3(0.0, 0.0, 1.0);

// The card textures are atlases; sampling their mip chain bleeds neighbouring
// islands into each other, which showed up as colour patches on the hair. Clamp
// as well, so UVs a hair outside [0, 1] cannot wrap to the far edge. RealityKit
// hands the shader unflipped UVs for USD textures, hence the 1 - uv.y.
constexpr sampler kAtlas(
    filter::linear,
    mip_filter::none,
    address::clamp_to_edge
);

[[visible]]
void toonSurface(realitykit::surface_parameters params)
{
    float2 uv = params.geometry().uv0();
    float2 flipped = float2(uv.x, 1.0 - uv.y);

    half3 albedo = params.textures().custom().sample(kAtlas, flipped).rgb;

    float3 normal = normalize(params.geometry().normal());
    float lambert = saturate(dot(normal, normalize(kLightDirection)));

    // Two tones with a soft edge. Hard steps band badly on a low-poly face,
    // which reads as scars, so the transition is a smoothstep and the shadow
    // tone stays well above black.
    float ramp = mix(0.80, 1.0, smoothstep(0.15, 0.55, lambert));

    // `_RimLightOn` / `_RimBorder` / `_RimOffset` in the game's materials.
    float fresnel = pow(1.0 - saturate(dot(normal, kViewDirection)), 2.5);

    // `_SubTex`: the additive highlight layer. The exporter premultiplied its
    // alpha into the colour, so a plain add is correct — the eye catch-light,
    // the hair shine and ss003's neon trim all live here.
    half3 glow = params.textures().emissive_color().sample(kAtlas, flipped).rgb;

    half3 shaded = albedo * half3(ramp) + half3(fresnel * 0.10f) + glow;

    params.surface().set_base_color(saturate(shaded));
    params.surface().set_metallic(0.0);
    params.surface().set_roughness(1.0);
}
