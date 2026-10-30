#!/usr/bin/env python3
"""Dump every material property an MLTD character bundle carries.

The glTF hand-off only has room for two textures and a handful of scalars, but
the game's shaders are driven by a dozen colours and thirty floats each. This
module reads the whole `m_SavedProperties` block into plain JSON so the runtime
can hand the numbers to its surface shader, and the shader can do the same maths
the game does instead of guessing a global ramp.

`m_ParsedForm.m_Name` is the only place a bundle states its shader name;
`Material.m_Shader.m_Name` is empty in every bundle checked so far.
"""

from __future__ import annotations

from dataclasses import dataclass


def shader_name(material) -> str:
    """The shader's own name, read from its parsed form."""
    try:
        parsed = material.m_Shader.read().m_ParsedForm
    except Exception:
        return ""
    return getattr(parsed, "m_Name", "") or ""


def keywords(material) -> list[str]:
    """`m_ShaderKeywords` as a list, whichever shape UnityPy hands back."""
    raw = getattr(material, "m_ShaderKeywords", None)
    if not raw:
        return []
    if isinstance(raw, str):
        return [word for word in raw.split() if word]
    return [str(word) for word in raw]


def is_cutout(
    shader: str, name: str, shader_keywords: list[str], floats: dict[str, float]
) -> bool:
    """Whether the game alpha-tests this material.

    The switch is the `_ISCUTOFF_ON` keyword — `_IsCutOff` is not a uniform in
    any of the 1592 decompiled shaders, it is a saved property some materials
    happen to carry. `Chr_CutOff` states it in the shader name, and a few
    decals only say so in their material name. `Chr_Alpha` blends instead, so
    it must never be clipped.
    """
    if shader.endswith("Chr_Alpha"):
        return False
    if "_ISCUTOFF_ON" in shader_keywords:
        return True
    if shader.endswith("Chr_CutOff"):
        return True
    if floats.get("_IsCutOff", 0.0) == 1.0:
        return True
    lowered = (name or "").lower()
    return "cut" in lowered or "alp" in lowered


def _colour(value) -> list[float]:
    return [float(value.r), float(value.g), float(value.b), float(value.a)]


def read_material_table(env) -> dict[str, dict]:
    """Every `Material` in the bundle, keyed by name.

    Textures are listed by slot name only; the exporter owns where the pixel
    data ends up, so an absolute path here would go stale.
    """
    table: dict[str, dict] = {}
    for obj in env.objects:
        if obj.type.name != "Material":
            continue
        material = obj.read()
        properties = material.m_SavedProperties
        floats = {name: float(value) for name, value in (properties.m_Floats or [])}
        table[material.m_Name] = {
            "shader": shader_name(material),
            "keywords": keywords(material),
            "floats": floats,
            "colours": {
                name: _colour(value) for name, value in (properties.m_Colors or [])
            },
            "textures": [entry[0] for entry in (properties.m_TexEnvs or [])],
        }
    return table
