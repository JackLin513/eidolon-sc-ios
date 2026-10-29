#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// Layout of one row of the parameter atlas built by `MaterialParameters.swift`.
// The two have to move together.
constant uint kParamColumns = 32;
// Rows the atlas is sized for. Fixed so every lookup is a compile-time UV.
constant uint kParamCapacity = 64;

// One parameter per texel, in `material_atlas.py`'s `LAYOUT` order.
constant uint kParamColorR = 0;
constant uint kParamAmbientR = 3;
constant uint kParamLightX = 9;
constant uint kParamShadingOffset = 15;
constant uint kParamShadingBorder = 16;
constant uint kParamRimOffset = 17;
constant uint kParamRimBorder = 18;
constant uint kParamRimLightOn = 21;
constant uint kParamSubAdd = 22;
constant uint kParamShaderKind = 31;

// The card textures are atlases; sampling their mip chain bleeds neighbouring
// islands into each other, which showed up as colour patches on the hair. Clamp
// as well, so UVs a hair outside [0, 1] cannot wrap to the far edge. RealityKit
// hands the shader unflipped UVs for USD textures, hence the 1 - uv.y.
constexpr sampler kAtlas(
    filter::linear,
    mip_filter::none,
    address::clamp_to_edge
);

constexpr sampler kPoint(filter::nearest, address::clamp_to_edge);

/// One parameter, read from the alpha channel.
///
/// The atlas is `kParamColumns` wide and `kParamCapacity` tall, so both
/// coordinates are compile-time constants. Alpha carries the value because the
/// colour channels are colour managed on the way in.
static float param(thread const texture2d<half> &lut, uint row, uint column)
{
    float2 uv = float2(float(column) + 0.5f, float(row) + 0.5f)
              / float2(float(kParamColumns), float(kParamCapacity));
    return float(lut.sample(kPoint, uv).a);
}

/// `_Light` is stored remapped into the unit range; undo that.
static float3 paramSigned3(thread const texture2d<half> &lut, uint row, uint first)
{
    return float3(param(lut, row, first), param(lut, row, first + 1),
                  param(lut, row, first + 2)) * 2.0f - 1.0f;
}

[[visible]]
void toonSurface(realitykit::surface_parameters params)
{
    float2 uv = params.geometry().uv0();
    float2 flipped = float2(uv.x, 1.0 - uv.y);

    half3 albedo = params.textures().custom().sample(kAtlas, flipped).rgb;

    // `_SubTex`: the additive highlight layer. The exporter premultiplied its
    // alpha into the colour, so a plain add is correct — the eye catch-light,
    // the hair shine and ss003's neon trim all live here.
    half3 glow = params.textures().emissive_color().sample(kAtlas, flipped).rgb;

    float4 custom = params.uniforms().custom_parameter();
    bool hasParams = custom.y > 0.5f;
    uint row = uint(custom.x);

    // EIDOLON_3D_LUT_DEBUG: paint the parameter row instead of shading, so a
    // wrong atlas shows up as the wrong picture rather than as bad lighting.
    if (custom.z > 0.5f) {
        // (0.2, 0.502, 0.3) means the row really is there: shader kind 2, the
        // body's `_Color.r`, and |`_Light.x`|.
        texture2d<half> lut = params.textures().specular();
        float kind = param(lut, row, kParamShaderKind) * 10.0f;
        float colour = param(lut, row, kParamColorR);
        float lightX = abs(paramSigned3(lut, row, kParamLightX).x);
        float3 paint = float3(kind / 10.0f, colour, lightX);
        params.surface().set_base_color(half3(paint));
        params.surface().set_metallic(0.0);
        params.surface().set_roughness(1.0);
        return;
    }

    // Falls back to the old fixed direction when a material has no row, so an
    // unknown asset still renders instead of going black.
    float3 light = normalize(float3(-0.268f, -0.358f, 0.894f));
    float rimStrength = 0.10f;
    if (hasParams) {
        float3 l = paramSigned3(params.textures().specular(), row, kParamLightX);
        if (length(l) > 0.0001f) {
            light = normalize(l);
        }
    }

    float3 normal = normalize(params.geometry().normal());
    float lambert = saturate(dot(normal, light));

    // Two tones with a soft edge. Hard steps band badly on a low-poly face,
    // which reads as scars, so the transition is a smoothstep and the shadow
    // tone stays well above black.
    float ramp = mix(0.80, 1.0, smoothstep(0.15, 0.55, lambert));

    float fresnel = pow(1.0 - saturate(dot(normal, float3(0, 0, 1))), 2.5);

    half3 shaded = albedo * half3(ramp) + half3(fresnel * rimStrength) + glow;

    params.surface().set_base_color(saturate(shaded));
    params.surface().set_metallic(0.0);
    params.surface().set_roughness(1.0);
}
