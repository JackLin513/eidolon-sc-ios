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
constant uint kParamColumns = 77;
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
constant uint kParamSpecTexFade = 28;
constant uint kParamSpecTexVectorY = 30;
constant uint kParamSpecTexMove = 50;
constant uint kParamSpecTexMove2 = 51;
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
constant uint kParamExtraBihaku = 62;
constant uint kParamWhitish = 63;
constant uint kParamFreq = 64;
constant uint kParamOutlineColor = 65;
constant uint kParamIsCutOff = 68;
constant uint kParamUp = 69;
constant uint kParamOutline = 72;
constant uint kParamTanFov = 73;

// Shader discriminator, matching `material_atlas.SHADER_KINDS`.
constant float kKindBasic = 1.0;
constant float kKindGlow = 2.0;
constant float kKindFace = 3.0;
constant float kKindHair = 4.0;
constant float kKindEye = 5.0;
constant float kKindAlpha = 6.0;

// `_USEREFLECT_ON`: a view-space matcap on mirror accessories and a few guest
// garments. The flag is the keyword; `_Reflection` is stored x100.
constant uint kParamUseReflect = 74;
constant uint kParamReflection = 75;
// `Chr_Span` perturbs the sparkle lookup by this much along the normal.
constant uint kParamNormMapMag = 76;
constant float kKindSpan = 7.0;

// The card textures are atlases; sampling their mip chain bleeds neighbouring
// islands into each other, which showed up as colour patches on the hair. Keep
// `mip_filter::none` for that reason. RealityKit hands the shader unflipped UVs
// for USD textures, hence the 1 - uv.y.
//
// `address::repeat`, not clamp: several decals are **tiled**, not unwrapped —
// every triangle of 052kao's lace is outside [0, 1] (u in [-1.61, 2.17]). The
// game's textures all import with `m_WrapU/V/W = 0` (Repeat), and our exporter
// carries them over unchanged, so the UVs still mean "tile this texture".
// Clamping them collected the texture border and smeared it into grey threads.
// For UVs inside [0, 1] repeat and clamp are identical, so nothing else moves.
constexpr sampler kAtlas(
    filter::linear,
    mip_filter::none,
    address::repeat
);

constexpr sampler kAtlasMipmapped(
    filter::linear,
    mip_filter::linear,
    address::repeat
);

constexpr sampler kPoint(filter::nearest, address::clamp_to_edge);

// The game shades in **gamma space**, not linear.
//
// Unity projects of this vintage default to Gamma colour space, so the shader's
// `_Color * tex - 0.02` subtracts from an sRGB value and barely darkens it. Done
// on linear values instead, that same subtraction crushes dark channels to zero:
// the hair lost its blue and came out at saturation 0.84 against the game's 0.45.
// RealityKit linearises textures on sample and expects linear output, so the
// maths is undone and redone around the curve here.
static float3 toGamma(float3 linearValue)
{
    return select(1.055f * pow(max(linearValue, 0.0f), 1.0f / 2.4f) - 0.055f,
                  linearValue * 12.92f,
                  linearValue <= 0.0031308f);
}

static float3 toLinear(float3 gammaValue)
{
    return select(pow((gammaValue + 0.055f) / 1.055f, 2.4f),
                  gammaValue / 12.92f,
                  gammaValue <= 0.04045f);
}

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

// The game draws its outline as an inverted hull: a second pass with `Cull
// Front` whose vertices are pushed out along the mesh's "hard" normals, which it
// keeps in the TANGENT channel. That channel does not survive the glTF/USD trip,
// so this uses the ordinary normal — close enough on the body, softer on the
// hair.
// Unlit custom materials ignore `set_base_color` and render `set_emissive_color`
// instead (`RealityKitSurfaceShader.h:484-494`). Writing zero to base and the
// result to emissive therefore produces the same picture under `.unlit` and
// `.lit`, so the lighting model becomes a switch rather than a rewrite.
static void writeColour(realitykit::surface_parameters params, float3 colour)
{
    params.surface().set_base_color(half3(0.0f));
    params.surface().set_emissive_color(half3(toLinear(saturate(colour))));
    params.surface().set_metallic(0.0f);
    params.surface().set_roughness(1.0f);
    params.surface().set_specular(0.0f);
}

/// The inverted hull is filled with the toon pass's own shading in the game's
/// shader, but the outline reads as a flat dark line, so this writes that
/// directly rather than binding the parameter atlas a second time.
[[visible]]
void outlineSurface(realitykit::surface_parameters params)
{
    uint row = uint(params.uniforms().custom_parameter().x);
    texture2d<half> lut = params.textures().specular();
    // Cutout materials keep their shape in the base pass only. Without the same
    // test here the hull still fills the whole rectangle, which reads as a solid
    // black patch sitting on top of the discarded base.
    if (param(lut, row, kParamIsCutOff) > 0.5f) {
        float2 uv = params.geometry().uv0();
        half4 base = params.textures().custom().sample(
            kAtlas, float2(uv.x, 1.0 - uv.y));
        if (base.a < 0.5h) {
            discard_fragment();
        }
    }
    // The game writes `2 * _IllumiColor * _OutlineColor` into the hull's colour
    // in the vertex shader, then multiplies by the toon ramp in the fragment
    // shader. `_IllumiColor` is neutral (0.5) in every character material, so
    // the doubling cancels out, and the ramp is 1 for the outline pass.
    float3 colour = paramColour(lut, row, kParamOutlineColor) * 2.0f
                  * paramColour(lut, row, kParamIllum);
    writeColour(params, colour);
}

[[visible]]
void outlineVertex(realitykit::geometry_parameters params)
{
    // The game pushes the hull out in CLIP space (`out.xy += nP * 0.7 * k *
    // _Outline`) with a depth-dependent k, which makes the line a constant number
    // of pixels at any distance. A model-space constant instead gets fatter the
    // closer the camera is, which is what a naive port looks like.
    float4x4 modelToView = params.uniforms().model_to_view();
    float4x4 viewToProjection = params.uniforms().view_to_projection();
    float4 view = modelToView * float4(params.geometry().model_position(), 1.0f);
    // NDC y = 1 sits `depth * tanHalfFov` from the axis, so a fraction of NDC is
    // a world length that grows with distance — exactly the game's k.
    float depth = max(-view.z, 0.001f);
    float tanHalfFov = 1.0f / max(viewToProjection[1][1], 0.0001f);
    float modelScale = max(length(float3(modelToView[0].xyz)), 0.000001f);

    // The game widens the hull with distance rather than keeping a fixed world
    // thickness: `out.xy += nP * k * _Outline`, with
    //   k = _OutlineZadj * (min(aspect,1) * (d + near) * tanActual / _TanFov - 1) + 1
    // Every constant in that chain is recoverable from the projection matrix, so
    // the Unity-only `_ProjectionParams` / `_ScreenParams` are not needed. The
    // `0.7` in older notes only applies to the OpenGL-style depth branch, which
    // Metal never takes.
    uint row = uint(params.uniforms().custom_parameter().x);
    texture2d<half> lut = params.textures().specular();
    float outlineWidth = param(lut, row, kParamOutline) / 1000.0f;
    float tanFov = max(param(lut, row, kParamTanFov), 0.0001f);
    float nearPlane = viewToProjection[3][2] / (viewToProjection[2][2] + 1.0f);
    float aspect = viewToProjection[1][1] / max(viewToProjection[0][0], 0.0001f);
    float k = min(aspect, 1.0f) * (depth + nearPlane) * tanHalfFov / tanFov;

    float3 normal = normalize(params.geometry().normal());
    float lengthInModel = k * outlineWidth * tanHalfFov * depth * tanHalfFov / modelScale;
    params.geometry().set_model_position_offset(normal * lengthInModel);
}

[[visible]]
void toonSurface(realitykit::surface_parameters params)
{
    float2 uv = params.geometry().uv0();
    float2 flipped = float2(uv.x, 1.0 - uv.y);

    // Sampled textures arrive linearised; the game's maths runs on the sRGB
    // values the artist painted.
    float4 custom = params.uniforms().custom_parameter();
    bool hasParams = custom.y > 0.5f;
    uint row = uint(custom.x);
    texture2d<half> lut = params.textures().specular();

    const bool mipmapped = custom.w > 0.5f;
    // `_MainTex` arrives as the model's base colour texture. `custom` is the
    // only slot RealityKit documents as "set on the CustomMaterial", so it is
    // reserved for the per-material effect maps (the span pack, the reflection
    // environment) and no longer carries the albedo.
    half4 mainTexRaw = params.textures().custom().sample(
        mipmapped ? kAtlasMipmapped : kAtlas, flipped);
    half4 subTexRaw = params.textures().emissive_color().sample(
        mipmapped ? kAtlasMipmapped : kAtlas, flipped);
    // `_IsCutOff` materials (the `02alp` ribbons) are a cutout shape painted on
    // a transparent field. The game tests `_MainTex.a` against 0.5; we used to
    // stand in "near black" for that because the alpha did not survive the USD
    // trip, which threw away dark pixels that are meant to be drawn. The
    // exporter now keeps the real alpha and marks the material `alphaMode:
    // MASK`, so test the same thing the game does.
    if (param(lut, row, kParamIsCutOff) > 0.5f && mainTexRaw.a < 0.5h) {
        discard_fragment();
    }
    if (custom.w < -1.5f) {
        // Alpha probe: grey means alpha reached the shader, white means it did
        // not (the texture loaded opaque) — the two need different fixes.
        writeColour(params, float3(mainTexRaw.a));
        // Half opacity on top of the alpha readout: if the blended materials
        // fade into the background, the opacity channel works and the fault is
        // in the blending mode; if nothing changes, `.unlit` ignores opacity.
        params.surface().set_opacity(0.25f);
        return;
    }
    if (custom.z < -199.5f) {
        // Material master: one flat colour per atlas row so a screenshot maps
        // pixels back to materials. The palette is spelled out rather than
        // derived so the colours stay far apart after the output curve.
        const float3 palette[16] = {
            float3(1.0, 0.0, 0.0),    // 0 red
            float3(0.0, 1.0, 0.0),    // 1 green
            float3(0.0, 0.0, 1.0),    // 2 blue
            float3(1.0, 1.0, 0.0),    // 3 yellow
            float3(0.0, 1.0, 1.0),    // 4 cyan
            float3(1.0, 0.0, 1.0),    // 5 magenta
            float3(1.0, 0.5, 0.0),    // 6 orange
            float3(0.5, 0.0, 1.0),    // 7 violet
            float3(0.5, 1.0, 0.0),    // 8 lime
            float3(0.0, 0.5, 0.5),    // 9 teal
            float3(1.0, 0.6, 0.6),    // 10 pink
            float3(0.0, 0.0, 0.5),    // 11 navy
            float3(0.5, 0.5, 0.0),    // 12 olive
            float3(0.7, 0.35, 0.1),   // 13 brown
            float3(1.0, 1.0, 1.0),    // 14 white
            float3(0.4, 0.4, 0.4),    // 15 grey
        };
        writeColour(params, palette[min(row, 15u)]);
        return;
    }
    if (custom.z < -99.5f) {
        // Isolate probe: everything but one atlas row is thrown away and the
        // survivor is drawn as flat albedo, so a single material can be seen on
        // its own without opening the exporter.
        if (float(row) != (-custom.z - 100.0f)) { discard_fragment(); }
        writeColour(params, float3(toGamma(float3(mainTexRaw.rgb))));
        return;
    }
    if (custom.z < -3.5f) {
        // Albedo probe: the atlas through this material's own UVs, with no
        // lighting, ramp, rim or sparkle. If the gold trim is missing here it
        // is a texture or UV fault; if it shows up here but not in the normal
        // render, something downstream is eating it.
        writeColour(params, float3(toGamma(float3(mainTexRaw.rgb))));
        return;
    }
    half4 mainTex = half4(half3(toGamma(float3(mainTexRaw.rgb))), mainTexRaw.a);
    half4 subTex = half4(half3(toGamma(float3(subTexRaw.rgb))), subTexRaw.a);

    // RealityKit already hands the shader a view-space normal; the game computes
    // in view space too, so no transform is needed. (Multiplying by
    // `model_to_view` here rotated the field by the rig's yaw and lit the wrong
    // side — confirmed with `EIDOLON_3D_DEBUG_NORMALS`.)
    float3 normal = normalize(params.geometry().normal());
    // `normal()` is world-space (verified by rotating the camera and comparing
    // against normals built from screen derivatives), but the game's light is a
    // view-space constant and its ramp is a view-space dot. At the default
    // camera the two coincide, which is why this only shows up once the model
    // is orbited.
    float3 normalView = normalize(
        (params.uniforms().world_to_view() * float4(normal, 0.0f)).xyz
    );
    float3 view = normalize(params.geometry().view_direction());

    if (custom.w < -0.5f) {
        // `EIDOLON_3D_DEBUG_CONST`: a flat, known linear value, to measure how
        // much RealityKit's own pass adds on top of the surface shader.
        writeColour(params, float3(0.5f));
        return;
    }

    if (custom.w > 1.5f) {
        // `EIDOLON_3D_DEBUG_NORMALS`: view-space normal as colour, so faceting
        // and a wrong space are both obvious.
        writeColour(params, saturate(normal * 0.5f + 0.5f));
        return;
    }

    if (custom.w > 2.5f && custom.w < 3.5f) {
        // cube/effect probe: paint the reflection environment, so an
        // unbound `base_color()` slot shows as black rather than as "subtle".
        float3 probe = reflect(-view, normalView);
        float2 probeUV = float2(
            atan2(probe.z, probe.x) / 6.283185307179586f + 0.5f,
            0.5f - asin(clamp(probe.y, -1.0f, 1.0f)) / 3.141592653589793f
        );
        writeColour(params, float3(params.textures().base_color().sample(kAtlas, probeUV).rgb));
        return;
    }

    if (custom.z > 0.5f) {
        // `EIDOLON_3D_LUT_DEBUG`: paint the parameter row instead of shading, so
        // a wrong atlas shows up as the wrong picture rather than bad lighting.
        float kind = hasParams ? param(lut, row, kParamShaderKind) * 10.0f : -1.0f;
        float colour = hasParams ? param(lut, row, kParamColor) : -1.0f;
        float lightX = hasParams ? abs(paramSigned(lut, row, kParamLight)) : -1.0f;
        writeColour(params, float3(kind / 10.0f, colour, lightX));
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
        float mask = edge * saturate(2.0f * (dot(normalView, light) - 0.25f));
        rim = saturate(mask * rimColour);
    }

    float3 result;

    // A blending material shades exactly like Basic; the only difference is that
    // it keeps its alpha instead of writing 1. Fold it back before the Eye test,
    // which would otherwise swallow anything above 5.
    // Both flags have to be read **before** either one resets `kind`: span's
    // kind is 7, which also satisfies the "blended" test (`kind > 5.5`), so the
    // blended branch used to fold it to Basic and swallow the sparkle.
    const bool span = kind > kKindSpan - 0.5f;
    const bool blended = !span && kind > kKindAlpha - 0.5f;
    // `Chr_Span` shades exactly like Basic and then adds a sparkle layer; fold
    // it back so the Basic branch runs and keep the flag for the additive term.
    if (span || blended) { kind = kKindBasic; }

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
        // The sheen lives in `_SubTex` and is sampled with the **second** UV
        // set, slid along the strands by the view angle: `_Up` defines "up", and
        // `_SpecTex_Move * _SpecTex_Move2` scales how far it travels.
        float3 base = float3(mainTex.rgb);
        if (hasParams) {
            float2 uv1 = params.geometry().uv1();
            // `_Up` is authored in object space and is not +Y for these meshes
            // (it is (-1, 0, 0)), so assuming up would slide the highlight along
            // the wrong axis.
            float3 upObject = float3(paramSigned(lut, row, kParamUp),
                                     paramSigned(lut, row, kParamUp + 1),
                                     paramSigned(lut, row, kParamUp + 2));
            float3 upView = normalize(
                (params.uniforms().model_to_view() * float4(upObject, 0.0f)).xyz
            );
            float slide = dot(view, upView);
            float2 sheenUV = float2(
                uv1.x,
                (param(lut, row, kParamSpecTexVectorY) * 0.1f)
                    - slide * (param(lut, row, kParamSpecTexMove)
                               * param(lut, row, kParamSpecTexMove2))
                    + uv1.y
            );
            half3 sheen = params.textures().emissive_color()
                .sample(kAtlas, float2(sheenUV.x, 1.0f - sheenUV.y)).rgb;
            // `nz³` keeps the sheen off the back of the head; `_SpecTex_Fade`
            // lifts the floor. The exporter premultiplied the mask into the
            // colour, so no separate alpha term is needed.
            float nz = normalView.z;
            float weight = clamp(min(nz * nz * nz + param(lut, row, kParamSpecTexFade), 1.0f),
                                 0.0f, 1.0f);
            // `EIDOLON_3D_NO_SHEEN` (custom.z < 0) turns it off for A/B: the
            // sheen adds a warm colour on top of brown, which is a saturation
            // source worth isolating.
            // Exactly -1, so the reflection (-2) and span (-3) probes do not
            // also switch the sheen off.
            if (custom.z > -1.5f && custom.z < -0.5f) { weight = 0.0f; }
            // `mainTex` was gamma-encoded before use; adding a linear sheen into
            // it made the highlight read orange and oversaturated.
            base += weight * toGamma(float3(sheen)) * 2.0f
                  * param(lut, row, kParamSubColor);
        }
        result = correctedBase(colour, base);
        float ramp = rampFactor(normalView, light, shadingOffset, shadingBorder);
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
            // The game only raises `_ExtraBihaku` inside three small UV patches
            // of the face atlas — the jaw and the two cheek edges. Using it for
            // every texel pinned the mask at 1, which flattened the shading on
            // the neck and the sides of the face.
            float extra = 0.0f;
            if (uv.x < 0.25f) {
                extra = uv.y < (121.0f / 512.0f)
                    ? param(lut, row, kParamExtraBihaku) : 0.0f;
            } else if (uv.x >= (375.0f / 512.0f) && uv.y < (145.0f / 512.0f)) {
                extra = param(lut, row, kParamExtraBihaku);
            }
            mask = saturate(max(extra, (0.5f + border - f) / border));
        }

        rim *= (1.0f - mask);
        float ramp = min(mask + rampFactor(normalView, light, shadingOffset, shadingBorder),
                         1.0f);
        result = correctedBase(colour, float3(mainTex.rgb));
        result = 2.0f * mix(ambient, diffuse, ramp) * result;
        result = result * (2.0f * illum) + rim;
    } else {
        // --- Chr_Glow / Chr_Basic --------------------------------------
        float ramp = rampFactor(normalView, light, 0.25f, 5.0f);
        result = correctedBase(colour, float3(mainTex.rgb));
        result = 2.0f * mix(ambient, diffuse, ramp) * result;
        result = result * (2.0f * illum) + rim;

        if (kind > kKindGlow - 0.5f && hasParams) {
            // In `Chr_Glow` a masked texel is replaced by the unshaded texture
            // colour, which is what makes ss003's trim look self-lit. The gate
            // is `_MainTex.a * _SubTex.g`, not the sub texture's brightness.
            float3 glowColour = paramColour(lut, row, kParamGlowColor);
            float3 whity = paramColour(lut, row, kParamWhityCol);
            // `_ColorBlendRate` is not a material value: `CharacterMaterials`
            // pushes it every frame from `GlowProperty`. For ss003's
            // `_WhiteMode = 2 / _Whitish = 1 / _Freq = 0.5` that is a two-second
            // triangle wave between the unshaded texture colour and `_WhityCol`.
            // A screenshot landed on the peak — the trim measured (174,118,165),
            // i.e. `_WhityCol` (176,123,157) — which is why the phase is offset
            // so the preview opens there instead of on the dull half.
            float period = max(1.0f / max(param(lut, row, kParamFreq), 0.0001f), 0.0001f);
            float phase = fract(params.uniforms().time() / period + 0.5f);
            float blend = param(lut, row, kParamWhitish)
                * (1.0f - abs(2.0f * phase - 1.0f));
            float3 glowTarget = mix(2.0f * correctedBase(colour, float3(mainTex.rgb)) * glowColour,
                                    whity, blend);
            float mask = step(0.5f, float(mainTex.a) * float(subTex.g));
            result = mix(result, glowTarget, param(lut, row, kParamLuminance) * mask);
        }
    }

    // `Chr_Span`: a noise normal perturbs the view-space normal, and the result
    // picks a texel out of a sparkle dot pattern. The two maps ride in one
    // 64x128 strip (bump on top, dot pattern below) because there is only one
    // custom slot. Additive, weighted by `_MainTex.a * _Reflection`.
    if (span && hasParams) {
        // The packed strip is bump on top, sparkle pattern below; the probe
        // showed the garment reading the top half, so no offset here.
        // `_Cube2D` is a field of soft bokeh glints, not fine grain. Driving the
        // lookup from the surface normal (what the game does with a *deviation*
        // vector) left it parked on one dark spot; painting it in the cloth's own
        // UV space keeps the glints glued to the fabric at the right density.
        float2 clothUV = float2(params.geometry().uv0().x,
                                1.0f - params.geometry().uv0().y);
        // Cloth UV places the glints on the fabric; the bump's noise then
        // jitters each lookup a little, which is what turns an even polka-dot
        // grid into something that reads as sparkle. The bump is a 32x32 tile,
        // so it has to be tiled hard to vary from pixel to pixel.
        half2 jitter = params.textures().base_color().sample(
            kAtlas, float2(clothUV.x * 32.0f, fract(clothUV.y * 32.0f) * 0.25f)
        ).xy * 2.0h - 1.0h;
        // The view-space normal is what makes the sparkle *move*: rotate the
        // model and every glint slides along the cloth. Kept small — at full
        // range it swept the whole atlas and turned into moire.
        float2 glintUV = clothUV * 6.0f + float2(jitter) * 0.12f
            + normalView.xy * 0.25f;
        half3 glint = params.textures().base_color().sample(
            kAtlas, float2(glintUV.x, fract(glintUV.y) * 0.5f + 0.5f)
        ).xyz;
        float sparkle = float(mainTexRaw.a) * param(lut, row, kParamReflection) * 4.0f;
        if (custom.z < -2.5f) { writeColour(params, float3(params.textures().base_color().sample(kAtlas, flipped).rgb)); return; }
        if (custom.z < -1.5f) { sparkle = 0.0f; }
        result += toGamma(float3(glint)) * sparkle;
    }

    // `_USEREFLECT_ON`. The game reflects `normalize(viewPos)` — the camera to
    // fragment direction — off the view-space normal and samples a cubemap; the
    // cube is folded into a lat-long strip at export time, so the lookup here is
    // two trig calls over the same vector. Added after the shading product and
    // before the flash/fog terms, additive, weighted by `_MainTex.a`.
    if (hasParams && param(lut, row, kParamUseReflect) > 0.5f) {
        float3 reflection = reflect(-view, normalView);
        float2 envUV = float2(
            atan2(reflection.z, reflection.x) / 6.283185307179586f + 0.5f,
            0.5f - asin(clamp(reflection.y, -1.0f, 1.0f)) / 3.141592653589793f
        );
        half3 env = params.textures().base_color().sample(kAtlas, envUV).rgb;
        float strength = float(mainTexRaw.a) * param(lut, row, kParamReflection) * 4.0f;
        // `EIDOLON_3D_NO_REFLECT` (custom.z == -2) turns it off for A/B: the
        // cube is mostly dark with one hotspot, so a wrong-space vector is easy
        // to mistake for "subtle".
        if (custom.z < -1.5f) { strength = 0.0f; }
        // The cube arrives in the same encoding as `_MainTex`, which is gamma.
        result += toGamma(float3(env)) * strength;
    }

    writeColour(params, result);
    if (blended) {
        // RealityKit multiplies opacity into the blended result by itself, so
        // this is the alpha and not a premultiplied colour.
        params.surface().set_opacity(mainTexRaw.a);
    }
}
