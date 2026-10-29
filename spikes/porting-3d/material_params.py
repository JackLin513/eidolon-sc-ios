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
        table[material.m_Name] = {
            "shader": shader_name(material),
            "floats": {
                name: float(value) for name, value in (properties.m_Floats or [])
            },
            "colours": {
                name: _colour(value) for name, value in (properties.m_Colors or [])
            },
            "textures": [entry[0] for entry in (properties.m_TexEnvs or [])],
        }
    return table
