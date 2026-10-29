#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// Fixed key light: the preview framing never moves, so the ramp does not need a
// uniform. Passing it through uniforms() is not exposed to surface shaders on
// this SDK.
constant float3 kLightDirection = float3(-0.35, 0.55, 0.75);
constant float3 kViewDirection = float3(0.0, 0.0, 1.0);

// Shared body: atlas albedo, a soft two-tone ramp, and the game's rim light.
static half3 toonBase(realitykit::surface_parameters params, float rimStrength)
{
    // The card textures are atlases; sampling their mip chain bleeds neighbouring
    // islands into each other, which showed up as colour patches on the hair.
    // Clamp as well, so UVs a hair outside [0, 1] cannot wrap to the far edge.
    constexpr sampler textureSampler(
        filter::linear,
        mip_filter::none,
        address::clamp_to_edge
    );
    float2 uv = params.geometry().uv0();
    half3 albedo = params.textures().custom()
        .sample(textureSampler, float2(uv.x, 1.0 - uv.y)).rgb;

    float3 normal = normalize(params.geometry().normal());
    float3 light = normalize(kLightDirection);
    float lambert = saturate(dot(normal, light));

    // Two tones with a soft edge. Hard steps band badly on a low-poly face,
    // which reads as scars, so the transition is a smoothstep and the shadow
    // tone stays well above black.
    float ramp = mix(0.80, 1.0, smoothstep(0.15, 0.55, lambert));

    // `_RimLightOn` / `_RimBorder` / `_RimOffset` in the game's materials.
    float fresnel = pow(1.0 - saturate(dot(normal, kViewDirection)), 2.5);

    return albedo * half3(ramp) + half3(fresnel * rimStrength);
}

[[visible]]
void toonSurface(realitykit::surface_parameters params)
{
    half3 shaded = toonBase(params, 0.10);

    // Tightened highlight: broad specular made everything look wet.
    float3 normal = normalize(params.geometry().normal());
    float3 halfVector = normalize(normalize(kLightDirection) + kViewDirection);
    float specular = smoothstep(0.72, 0.80, pow(saturate(dot(normal, halfVector)), 48.0));
    shaded += half3(specular * 0.18);

    params.surface().set_base_color(shaded);
    params.surface().set_metallic(0.0);
    params.surface().set_roughness(1.0);
}

// Eyes carry `_SpecTex_*` parameters in the game: the catch-light is computed,
// not painted into the texture. A much tighter lobe gives that dot.
[[visible]]
void eyeSurface(realitykit::surface_parameters params)
{
    half3 shaded = toonBase(params, 0.06);

    float3 normal = normalize(params.geometry().normal());
    float3 halfVector = normalize(normalize(kLightDirection) + kViewDirection);
    float specular = smoothstep(0.55, 0.70, pow(saturate(dot(normal, halfVector)), 120.0));
    shaded += half3(specular * 0.85);

    params.surface().set_base_color(shaded);
    params.surface().set_metallic(0.0);
    params.surface().set_roughness(1.0);
}
