#!/usr/bin/env python3
"""Bake every material's shading constants into one small texture.

A `CustomMaterial` exposes about a dozen scalar slots, but a faithful port needs
every colour and float the game's shader reads. The values go in the **alpha**
channel: colour channels are colour managed on the way into the renderer (a PNG
tagged sRGB comes back linearised), while alpha is passed through untouched. The
shader reads `.a` with nearest sampling, so a byte lands as `value / 255`.

Channels whose range does not fit in [0, 1] are rescaled on the way in and back
on the way out — `_ShadingBorder` is 5.0, `_SpecTex_Rotate_Offset` is -0.35.

The order below is the contract with `ToonShading.metal`'s `kParam*` constants.
"""

from __future__ import annotations

from PIL import Image

# (property, channel). Channels: r/g/b/a and x/y/z/w read a colour component
# (x/y/z/w additionally remap -1..1 into 0..1); "-" is a plain float; "u2"/"u4"/
# "u8" divide by that factor first; "s2" is a signed float divided by two;
# "kind" is the shader discriminator.
LAYOUT: list[tuple[str, str]] = [
    ("_Color", "r"), ("_Color", "g"), ("_Color", "b"),
    ("_AmbientColor", "r"), ("_AmbientColor", "g"), ("_AmbientColor", "b"),
    ("_DiffuseColor", "r"), ("_DiffuseColor", "g"), ("_DiffuseColor", "b"),
    ("_Light", "x"), ("_Light", "y"), ("_Light", "z"),
    ("_RimColor", "r"), ("_RimColor", "g"), ("_RimColor", "b"),
    ("_ShadingOffset", "-"), ("_ShadingBorder", "u8"),
    ("_RimOffset", "-"), ("_RimBorder", "u4"),
    ("_VColWeight", "-"), ("_VColMin", "-"),
    ("_RimLightOn", "-"), ("_SubAdd", "-"),
    ("_SpecTex_Center_X", "-"), ("_SpecTex_Center_Y", "-"),
    ("_SpecTex_Scale_X", "u2"), ("_SpecTex_Scale_Y", "-"),
    ("_SpecTex_Zoom", "u2"), ("_SpecTex_Fade", "-"),
    ("_SpecTex_Vector_X", "s2"), ("_SpecTex_Vector_Y", "s2"),
    ("shaderKind", "kind"),
    # --- second block: what `research-mltd-shading-math.md` needs ---
    ("_GlowColor", "r"), ("_GlowColor", "g"), ("_GlowColor", "b"),
    ("_WhityCol", "r"), ("_WhityCol", "g"), ("_WhityCol", "b"),
    ("_ColorBlendRate", "-"),
    ("_Luminance", "-"),
    ("_IrisColor", "a"),
    ("_IrisColor", "r"), ("_IrisColor", "g"), ("_IrisColor", "b"),
    ("_SpecTex_Lens_Zoom", "u2"),
    ("_SpecTex_Lens_AngleField", "-"),
    ("_SpecTex_Offset_X", "s2"), ("_SpecTex_Offset_Y", "s2"),
    ("_SpecTex_Rotate_Z", "-"), ("_SpecTex_Rotate_Offset", "s2"),
    ("_SpecTex_Move", "-"), ("_SpecTex_Move2", "-"),
    ("_SubColor", "r"),
    ("_IsBihaku", "-"),
    ("_BihakuCenterX", "-"), ("_BihakuCenterY", "-"),
    ("_BihakuWidth", "-"), ("_BihakuHeight", "-"),
    ("_BihakuBorder", "-"),
    # `_IllumiColor` is neutral at 0.5 like `_Color`, so it is doubled back
    # wherever it is applied; the three channels have to stay adjacent.
    ("_IllumiColor", "r"), ("_IllumiColor", "g"), ("_IllumiColor", "b"),
    ("_ExtraBihaku", "-"),
    ("_Whitish", "-"),
    ("_Freq", "-"),
    # The outline pass tints the hull with `2 * _IllumiColor * _OutlineColor`,
    # which is a dark brown in every character material, not black.
    ("_OutlineColor", "r"), ("_OutlineColor", "g"), ("_OutlineColor", "b"),
    # The alpha-cut `02alp` ribbons are the only cutout materials; the flag
    # matters because the texture's alpha does not survive the USD trip.
    ("_IsCutOff", "-"),
    # `_Up` is the object-space "up" the hair sheen slides along; the artist
    # authored (-1, 0, 0), not +Y.
    ("_Up", "r"), ("_Up", "g"), ("_Up", "b"),
    # The outline pass widens with depth: `k * _Outline` in clip space, where k
    # is rebuilt from the projection matrix in the shader. `_Outline` is 0.0005,
    # far below one byte's resolution, so it is stored x1000.
    ("_Outline", "x1000"),
    ("_TanFov", "-"),
]

# Rows the atlas is sized for. The shader's V coordinate is
# `(row + 0.5) / CAPACITY`, a compile-time constant.
CAPACITY = 64

SHADER_KINDS = {
    "Custom/Chr_Basic": 1,
    "Custom/Chr_Basic_NoOutline": 1,
    # `Chr_CutOff` is `Chr_Basic` plus
    # `if (mainTex.a * _Color.a < _AlphaTestValue) discard;`.
    "Custom/Chr_CutOff": 1,
    # `Chr_Alpha` is the blended sibling of the same family; until its blend
    # maths is ported it draws through the Basic branch.
    "Custom/Chr_Alpha": 1,
    #  tints the base colour; until its maths is ported it draws
    # through the Basic branch.
    "Custom/Chr_Color": 1,
    # `Chr_Span` draws flat decorative pieces; Basic branch until ported.
    "Custom/Chr_Span": 1,
    "Custom/Chr_Glow": 2,
    "Custom/Chr_Face": 3,
    "Custom/Chr_Face_NoOutline": 3,
    "Custom/Chr_Hair": 4,
    "Custom/Chr_Hair_NoOutline": 4,
    "Custom/BultIn/Bi_CharEye": 5,
}

_COLOUR_CHANNELS = {"r": 0, "g": 1, "b": 2, "a": 3,
                    "x": 0, "y": 1, "z": 2, "w": 3}
_SIGNED_COLOUR = {"x", "y", "z", "w"}


def value_of(material: dict, property_name: str, channel: str) -> float:
    if channel == "kind":
        # Scaled by ten so the byte carries the kind exactly.
        return SHADER_KINDS.get(material.get("shader", ""), 0) / 10.0
    if property_name == "_IsCutOff":
        # The flag is not stored on these materials; the shader name is the
        # statement that they clip. `Chr_Alpha` clips too — its blend maths is
        # not ported yet, and without the cutout its transparent field (painted
        # black by the exporter) shows up as a solid black patch.
        shader = material.get("shader", "")
        if shader.endswith("Chr_CutOff") or shader.endswith("Chr_Alpha"):
            return 1.0
    colours = material.get("colours", {})
    floats = material.get("floats", {})
    if channel in _COLOUR_CHANNELS:
        colour = colours.get(property_name, [0.0, 0.0, 0.0, 1.0])
        return float(colour[_COLOUR_CHANNELS[channel]])
    return float(floats.get(property_name, 0.0))


def encode(channel: str, value: float) -> int:
    """One byte per parameter."""
    if channel in _SIGNED_COLOUR or channel == "s2":
        value = value / 2.0 + 0.5 if channel == "s2" else (value + 1.0) / 2.0
    elif channel == "x1000":
        value = value * 1000.0
    elif channel in ("u2", "u4", "u8"):
        value = value / float(channel[1])
    return max(0, min(255, round(value * 255)))


def parameter_atlas(materials: dict[str, dict]) -> tuple[Image.Image, list[str]]:
    """The atlas image plus the material order its rows are in."""
    order = sorted(materials)
    if len(order) > CAPACITY:
        raise ValueError(f"{len(order)} materials, atlas only holds {CAPACITY}")

    image = Image.new("RGBA", (len(LAYOUT), CAPACITY), (0, 0, 0, 0))
    pixels = image.load()
    for row, name in enumerate(order):
        material = materials[name]
        for column, (property_name, channel) in enumerate(LAYOUT):
            byte = encode(channel, value_of(material, property_name, channel))
            pixels[column, row] = (0, 0, 0, byte)
    return image, order
