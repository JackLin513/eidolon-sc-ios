#!/usr/bin/env python3
"""Bake every material's shading constants into one small texture.

A `CustomMaterial` exposes about a dozen scalar slots, but a faithful port needs
every colour and float the game's shader reads. The values go in the **alpha**
channel: colour channels are colour managed on the way into the renderer (a PNG
tagged sRGB comes back linearised), while alpha is passed through untouched. The
shader reads `.a` with nearest sampling, so a byte lands as `value / 255`.

The order below is the contract with `ToonShading.metal`'s `kParam*` constants.
"""

from __future__ import annotations

from PIL import Image

# (property, channel). `channel` is "r"/"g"/"b" for a colour component,
# "x"/"y"/"z" for a signed vector component, "-" for a plain float, and
# "kind" for the shader discriminator.
LAYOUT: list[tuple[str, str]] = [
    ("_Color", "r"), ("_Color", "g"), ("_Color", "b"),
    ("_AmbientColor", "r"), ("_AmbientColor", "g"), ("_AmbientColor", "b"),
    ("_DiffuseColor", "r"), ("_DiffuseColor", "g"), ("_DiffuseColor", "b"),
    ("_Light", "x"), ("_Light", "y"), ("_Light", "z"),
    ("_RimColor", "r"), ("_RimColor", "g"), ("_RimColor", "b"),
    ("_ShadingOffset", "-"), ("_ShadingBorder", "-"),
    ("_RimOffset", "-"), ("_RimBorder", "-"),
    ("_VColWeight", "-"), ("_VColMin", "-"),
    ("_RimLightOn", "-"), ("_SubAdd", "-"),
    ("_SpecTex_Center_X", "-"), ("_SpecTex_Center_Y", "-"),
    ("_SpecTex_Scale_X", "-"), ("_SpecTex_Scale_Y", "-"),
    ("_SpecTex_Zoom", "-"), ("_SpecTex_Fade", "-"),
    ("_SpecTex_Vector_X", "-"), ("_SpecTex_Vector_Y", "-"),
    ("shaderKind", "kind"),
]

# Rows the atlas is sized for. The shader's V coordinate is
# `(row + 0.5) / CAPACITY`, a compile-time constant.
CAPACITY = 64

SHADER_KINDS = {
    "Custom/Chr_Basic": 1,
    "Custom/Chr_Basic_NoOutline": 1,
    "Custom/Chr_Glow": 2,
    "Custom/Chr_Face": 3,
    "Custom/Chr_Face_NoOutline": 3,
    "Custom/Chr_Hair": 4,
    "Custom/Chr_Hair_NoOutline": 4,
    "Custom/BultIn/Bi_CharEye": 5,
}

_SIGNED = {("_Light", "x"), ("_Light", "y"), ("_Light", "z")}


def value_of(material: dict, property_name: str, channel: str) -> float:
    if channel == "kind":
        # Scaled by ten so the byte carries the kind exactly.
        return SHADER_KINDS.get(material.get("shader", ""), 0) / 10.0
    colours = material.get("colours", {})
    floats = material.get("floats", {})
    if channel in ("r", "g", "b"):
        colour = colours.get(property_name, [0.0, 0.0, 0.0, 1.0])
        return float(colour["rgb".index(channel)])
    if channel in ("x", "y", "z"):
        colour = colours.get(property_name, [0.0, 0.0, 0.0, 1.0])
        return float(colour["xyz".index(channel)])
    return float(floats.get(property_name, 0.0))


def encode(property_name: str, channel: str, value: float) -> int:
    """One byte per parameter; signed components are remapped into the unit range."""
    if (property_name, channel) in _SIGNED:
        value = (value + 1.0) / 2.0
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
            byte = encode(property_name, channel, value_of(material, property_name, channel))
            pixels[column, row] = (0, 0, 0, byte)
    return image, order
