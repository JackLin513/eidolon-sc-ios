#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// The game's character shading, transcribed from the Metal the game itself
// compiles (see `spikes/porting-3d/research-mltd-shading-math.md`). Every
// formula below is the original: ramp `saturate(5*(N·L-0.25))`, `_Color` and
// `_IllumiColor` neutral at 0.5 and doubled back, `_SubTex` meaning a different
// thing per shader.
//
// Per-material constants arrive in an atlas texture, one byte per parameter in
// the alpha channel. The order is `material_atlas.py`'s `LAYOUT`.
constant uint kParamColumns = 62;
constant uint kParamCapacity = 64;

constant uint kParamColor = 0;
constant uint kParamAmbient = 3;
constant uint kParamDiffuse = 6;
constant uint kParamLight = 9;
constant uint kParamRimColor = 12;
constant uint kParamShadingOffset = 15;
constant uint kParamShadingBorder = 16;
constant uint kParamRimLightOn = 21;
constant uint kParamSpecTexCenterX = 23;
constant uint kParamSpecTexCenterY = 24;
constant uint kParamSpecTexScaleX = 25;
constant uint kParamSpecTexScaleY = 26;
constant uint kParamSpecTexZoom = 27;
constant uint kParamShaderKind = 31;
constant uint kParamGlowColor = 32;
constant uint kParamWhityCol = 35;
constant uint kParamColorBlendRate = 38;
constant uint kParamLuminance = 39;
constant uint kParamIrisAlpha = 40;
constant uint kParamIrisColor = 41;
constant uint kParamLensZoom = 44;
constant uint kParamLensAngleField = 45;
constant uint kParamSpecTexOffsetX = 46;
constant uint kParamSpecTexOffsetY = 47;
constant uint kParamSpecTexRotateZ = 48;
constant uint kParamSpecTexRotateOffset = 49;
constant uint kParamSubColor = 52;
constant uint kParamIsBihaku = 53;
constant uint kParamBihakuCenterX = 54;
constant uint kParamBihakuCenterY = 55;
constant uint kParamBihakuWidth = 56;
constant uint kParamBihakuHeight = 57;
constant uint kParamBihakuBorder = 58;
constant uint kParamIllum = 59;

// Shader discriminator, matching `material_atlas.SHADER_KINDS`.
constant float kKindBasic = 1.0;
constant float kKindGlow = 2.0;
constant float kKindFace = 3.0;
constant float kKindHair = 4.0;
constant float kKindEye = 5.0;

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

static float param(thread const texture2d<half> &lut, uint row, uint column)
{
    float2 uv = float2(float(column) + 0.5f, float(row) + 0.5f)
              / float2(float(kParamColumns), float(kParamCapacity));
    return float(lut.sample(kPoint, uv).a);
}

static float paramSigned(thread const texture2d<half> &lut, uint row, uint column)
{
    return param(lut, row, column) * 2.0f - 1.0f;
}

static float3 paramColour(thread const texture2d<half> &lut, uint row, uint first)
{
    return float3(param(lut, row, first), param(lut, row, first + 1),
                  param(lut, row, first + 2));
}

/// The contrast correction all four character shaders share.
///
/// `COLOR0.x = max(vertexColour.r, _VColMin)` is 1 in practice (every material
/// has `_VColMin = 1`) and `COLOR0.y = 0.8` (Glow/Basic hardcode it, Face/Hair
/// derive it from `_GradeOffset`), so this collapses to `_Color*tex - 0.02`.
static float3 correctedBase(float3 colour, float3 texel)
{
    float3 x = colour * texel;
    const float weight = 0.8f;
    const float k = 1.0f - (weight - 0.3f);
    float3 t = 1.0f - k * (1.0f - 2.0f * (x - 0.6f));
    return t + weight * (x - t);
}

/// The two-step ramp: `saturate((N·L - offset) * border)`.
static float rampFactor(float3 normal, float3 light, float offset, float border)
{
    return saturate((dot(normal, light) - offset) * border);
}

[[visible]]
void toonSurface(realitykit::surface_parameters params)
{
    float2 uv = params.geometry().uv0();
    float2 flipped = float2(uv.x, 1.0 - uv.y);

    half4 mainTex = params.textures().custom().sample(kAtlas, flipped);
    half4 subTex = params.textures().emissive_color().sample(kAtlas, flipped);

    float4 custom = params.uniforms().custom_parameter();
    bool hasParams = custom.y > 0.5f;
    uint row = uint(custom.x);
    texture2d<half> lut = params.textures().specular();

    // RealityKit already hands the shader a view-space normal; the game computes
    // in view space too, so no transform is needed. (Multiplying by
    // `model_to_view` here rotated the field by the rig's yaw and lit the wrong
    // side — confirmed with `EIDOLON_3D_DEBUG_NORMALS`.)
    float3 normal = normalize(params.geometry().normal());
    float3 view = normalize(params.geometry().view_direction());

    if (custom.w > 0.5f) {
        // `EIDOLON_3D_DEBUG_NORMALS`: view-space normal as colour, so faceting
        // and a wrong space are both obvious.
        params.surface().set_base_color(half3(saturate(normal * 0.5f + 0.5f)));
        params.surface().set_metallic(0.0);
        params.surface().set_roughness(1.0);
        return;
    }

    if (custom.z > 0.5f) {
        // `EIDOLON_3D_LUT_DEBUG`: paint the parameter row instead of shading, so
        // a wrong atlas shows up as the wrong picture rather than bad lighting.
        float kind = hasParams ? param(lut, row, kParamShaderKind) * 10.0f : -1.0f;
        float colour = hasParams ? param(lut, row, kParamColor) : -1.0f;
        float lightX = hasParams ? abs(paramSigned(lut, row, kParamLight)) : -1.0f;
        params.surface().set_base_color(half3(kind / 10.0f, colour, lightX));
        params.surface().set_metallic(0.0);
        params.surface().set_roughness(1.0);
        return;
    }

    // Defaults are the values every material in this character carries, so an
    // asset without a parameter table still renders sensibly.
    float3 light = normalize(float3(-0.3f, -0.4f, 1.0f));
    float3 colour = float3(0.5f);
    float3 ambient = float3(0.863f);
    float3 diffuse = float3(1.0f);
    float3 illum = float3(0.5f);
    float3 rimColour = float3(1.0f);
    float rimOn = 1.0f;
    float shadingOffset = 0.25f;
    float shadingBorder = 5.0f;
    float kind = kKindBasic;

    if (hasParams) {
        // `_Light` is a constant in camera axes: flip x and y only, keep z.
        float3 raw = float3(paramSigned(lut, row, kParamLight),
                            paramSigned(lut, row, kParamLight + 1),
                            paramSigned(lut, row, kParamLight + 2));
        if (length(raw) > 0.0001f) {
            light = normalize(float3(-raw.x, -raw.y, raw.z));
        }
        colour = paramColour(lut, row, kParamColor);
        ambient = paramColour(lut, row, kParamAmbient);
        diffuse = paramColour(lut, row, kParamDiffuse);
        illum = paramColour(lut, row, kParamIllum);
        rimColour = paramColour(lut, row, kParamRimColor);
        rimOn = param(lut, row, kParamRimLightOn);
        shadingOffset = param(lut, row, kParamShadingOffset);
        // Stored divided by eight; the material value is 5.0.
        shadingBorder = param(lut, row, kParamShadingBorder) * 8.0f;
        kind = param(lut, row, kParamShaderKind) * 10.0f;
    }

    // Rim light, vertex path: the `_RimCtrl` recalculation needs a uniform the
    // game pushes from C# and nobody has its value, but this branch is certain.
    float3 rim = float3(0.0f);
    if (rimOn > 0.5f) {
        float edge = pow(1.0f - abs(dot(normal, view)), 5.0f);
        float mask = edge * saturate(2.0f * (dot(normal, light) - 0.25f));
        rim = saturate(mask * rimColour);
    }

    float3 result;

    if (kind > kKindEye - 0.5f) {
        // --- Bi_CharEye -------------------------------------------------
        // The catch-light is a white lerp masked by `_SubTex`'s alpha. The game
        // computes a lens-distorted, view-dependent highlight UV from a
        // *second* UV set. `Bi_CharEye`'s own mesh has only uv0, so that channel
        // is (0,0) at runtime and the formula collapses to a constant — running
        // it here just floods the iris. MLTDTools documents the working
        // fallback: read the highlight at the base UV, which is valid because the
        // two textures are the same size.
        float3 iris = float3(1.0f);
        float irisAlpha = 1.0f;
        if (hasParams) {
            iris = paramColour(lut, row, kParamIrisColor);
            irisAlpha = param(lut, row, kParamIrisAlpha);
        }
        // The exporter premultiplied `_SubTex` because RealityKit's emissive
        // slot drops alpha, so the mask now lives in the red channel.
        float s = float(subTex.r) * irisAlpha;

        result = float3(mainTex.rgb);
        result = mix(result, iris, saturate(s));
        // 0.5 neutral is undone by the factor of four: 0.5*0.5*4 = 1.
        result *= colour * illum * diffuse * 4.0f;
    } else if (kind > kKindHair - 0.5f) {
        // --- Chr_Hair ---------------------------------------------------
        // Without a second UV set the sheen cannot be placed, so only the
        // corrected albedo survives.
        result = correctedBase(colour, float3(mainTex.rgb));
        float ramp = rampFactor(normal, light, shadingOffset, shadingBorder);
        result = 2.0f * mix(ambient, diffuse, ramp) * result;
        result = result * (2.0f * illum) + rim;
    } else if (kind > kKindFace - 0.5f) {
        // --- Chr_Face ---------------------------------------------------
        // `_Bihaku*`: an ellipse in UV space whose edge is a smooth S curve,
        // forced to full inside the atlas's edge patches. The constants
        // 0.25/0.236328125/0.283203125/0.732421875 are baked for a 512x512 face
        // atlas and would need re-deriving for another character.
        float mask = 0.0f;
        if (hasParams && param(lut, row, kParamIsBihaku) > 0.5f) {
            float2 half2 = float2(param(lut, row, kParamBihakuWidth),
                                  param(lut, row, kParamBihakuHeight));
            float2 delta = (uv - float2(param(lut, row, kParamBihakuCenterX),
                                        param(lut, row, kParamBihakuCenterY))) / half2;
            float d2 = dot(delta, delta);
            float f = 3.0227f * d2 - 4.4114f * d2 * d2 + 2.3887f * d2 * d2 * d2;
            float border = max(param(lut, row, kParamBihakuBorder), 1e-4f);
            // `_ExtraBihaku` is a uniform the game pushes from C# and its value
            // is unknown, so the atlas-edge override is left off rather than
            // guessed at full strength.
            const float extra = 0.0f;
            mask = saturate(max(extra, (0.5f + border - f) / border));
        }

        rim *= (1.0f - mask);
        float ramp = min(mask + rampFactor(normal, light, shadingOffset, shadingBorder),
                         1.0f);
        result = correctedBase(colour, float3(mainTex.rgb));
        result = 2.0f * mix(ambient, diffuse, ramp) * result;
        result = result * (2.0f * illum) + rim;
    } else {
        // --- Chr_Glow / Chr_Basic --------------------------------------
        float ramp = rampFactor(normal, light, 0.25f, 5.0f);
        result = correctedBase(colour, float3(mainTex.rgb));
        result = 2.0f * mix(ambient, diffuse, ramp) * result;
        result = result * (2.0f * illum) + rim;

        if (kind > kKindGlow - 0.5f && hasParams) {
            // In `Chr_Glow` a masked texel is replaced by the unshaded texture
            // colour, which is what makes ss003's trim look self-lit. The gate
            // is `_MainTex.a * _SubTex.g`, not the sub texture's brightness.
            float3 glowColour = paramColour(lut, row, kParamGlowColor);
            float3 whity = paramColour(lut, row, kParamWhityCol);
            // The material carries `_ColorBlendRate = 0`, but that is only the
            // placeholder: the game sets it at runtime. Measured against a
            // screenshot of the 3D viewer, ss003's trim averages (174,118,165),
            // which is `_WhityCol` (176,123,157) in 8-bit — so the runtime value
            // is 1, the "blown out" target, not the unshaded texture colour.
            // With 0 the trim renders as the atlas's raw magenta (255,78,249).
            const float blend = 1.0f;
            float3 glowTarget = mix(2.0f * correctedBase(colour, float3(mainTex.rgb)) * glowColour,
                                    whity, blend);
            float mask = step(0.5f, float(mainTex.a) * float(subTex.g));
            result = mix(result, glowTarget, param(lut, row, kParamLuminance) * mask);
        }
    }

    params.surface().set_base_color(saturate(half3(result)));
    params.surface().set_metallic(0.0);
    params.surface().set_roughness(1.0);
}
