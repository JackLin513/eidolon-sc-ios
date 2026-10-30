#!/usr/bin/env python3
"""Static defect scan over an exported character corpus.

`check_corpus.py` asks whether a model will *load*. This asks whether it will
*look right*, and specifically for the two defect classes found on 2026-10-30:

  1. **透明贴图没被当成透明处理.** A material whose `_MainTex` carries
     transparent texels, but which is neither blended (`Chr_Alpha`) nor a
     cutout, draws those texels as opaque — and because `cutout_safe()`
     zeroes RGB under transparency, "opaque" means pure black. This is the
     003mik pendant bug at the data level, without needing a screenshot.

  2. **描边壳套错了材质.** A material whose shader variant has no OUTLINE
     pass in the game (`*_NoOutline`) still gets a hull, and any material with
     a missing/zero `_OutlineColor` gets a *black* hull.

It also reports the two things we chose to live with: the near-black stand-in
for real alpha cutout, and UVs outside [0, 1] (fine now that the sampler
repeats, but worth counting).

Usage:
    audit_materials.py --root build/mltd-corpus
    audit_materials.py --root build/mltd-corpus --json report.json --verbose
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from PIL import Image

from material_atlas import value_of

# The five shader variants that carry a second, outline pass — read off the
# game's own `m_ParsedForm` in the asset bundle. Everything else is a single
# pass, so a hull built for it is geometry the game never draws.
OUTLINED_SHADERS = {
    "Chr_Basic",
    "Chr_Color",
    "Chr_Face",
    "Chr_Glow",
    "Chr_Hair",
    "Chr_Span",
}
BLENDED_SHADER = "Chr_Alpha"
# Single-pass variants confirmed against the game's `m_ParsedForm`.
KNOWN_SINGLE_PASS = {
    "Chr_Alpha",
    "Chr_Basic_NoOutline",
    "Chr_Color_NoOutline",
    "Chr_CutOff",
    "Chr_Face_NoOutline",
    "Chr_Glow_NoOutline",
    "Chr_Hair_NoOutline",
    "Chr_Span_NoOutline",
    "Bi_CharEye",
}

# A texel is "transparent" the way the game's alpha test sees it, and "near
# black" the way our stand-in cutout test does.
ALPHA_CUTOFF = 0.5
NEAR_BLACK = 0.016  # 0.004 linear, roughly, on an sRGB-decoded channel
TRANSPARENT_SHARE = 0.002  # ignore a handful of stray texels
NEAR_BLACK_SHARE = 0.002


def load_texture(path: Path) -> Image.Image | None:
    try:
        return Image.open(path).convert("RGBA")
    except OSError:
        return None


def texture_stats(image: Image.Image) -> dict:
    """Share of transparent texels, and of opaque ones that read as black."""
    alpha = image.getchannel("A")
    rgb = image.convert("RGB")
    width, height = image.size
    total = width * height
    transparent = 0
    near_black_opaque = 0
    for a, (r, g, b) in zip(alpha.getdata(), rgb.getdata()):
        if a < ALPHA_CUTOFF * 255:
            transparent += 1
        elif max(r, g, b) < NEAR_BLACK * 255:
            near_black_opaque += 1
    return {
        "size": [width, height],
        "transparent": transparent / total,
        "near_black_opaque": near_black_opaque / total,
    }


def primitive_uv_ranges(gltf: dict) -> dict[str, list[float]]:
    """Per material name, the [min, max] of every UV channel on its primitives."""
    accessors = gltf.get("accessors", [])
    materials = [m.get("name", "") for m in gltf.get("materials", [])]
    ranges: dict[str, list[float]] = {}
    for mesh in gltf.get("meshes", []):
        for primitive in mesh.get("primitives", []):
            index = primitive.get("material")
            if index is None or index >= len(materials):
                continue
            name = materials[index]
            for attribute, handle in primitive.get("attributes", {}).items():
                if not attribute.startswith("TEXCOORD_"):
                    continue
                accessor = accessors[handle]
                low = accessor.get("min", [0])[0]
                high = accessor.get("max", [0])[0]
                slot = ranges.setdefault(name, [float("inf"), float("-inf")])
                slot[0] = min(slot[0], low)
                slot[1] = max(slot[1], high)
    return ranges


def audit_model(directory: Path) -> dict:
    name = directory.name
    materials_path = directory / f"{name}-materials.json"
    gltf_path = directory / f"{name}.gltf"
    table = json.loads(materials_path.read_text()).get("materials", {})
    gltf = json.loads(gltf_path.read_text()) if gltf_path.exists() else {}
    uv_ranges = primitive_uv_ranges(gltf)

    errors: list[str] = []
    warnings: list[str] = []
    notes: list[str] = []

    for material_name, material in sorted(table.items()):
        shader = material.get("shader", "").split("/")[-1]
        colours = material.get("colours") or {}
        floats = material.get("floats") or {}
        # `_IsCutOff` is not simply the material's own float: the exporter
        # derives it from the shader name too, and the atlas is what the shader
        # actually tests. Ask the atlas builder rather than re-deriving it.
        blended = shader == BLENDED_SHADER
        cutout = value_of(material, "_IsCutOff", "-") > 0.5

        candidates = sorted((directory / "textures").glob(f"*_{material_name}.png"))
        image = load_texture(candidates[0]) if candidates else None

        if image is not None:
            stats = texture_stats(image)
            # 1. Transparent texels on a material that has no way to drop them.
            if not blended and not cutout and stats["transparent"] > TRANSPARENT_SHARE:
                errors.append(
                    f"{material_name}（{shader}）贴图有 {stats['transparent']:.1%} 透明像素，"
                    f"但既不是 Chr_Alpha 也不是 cutout —— 会画成纯黑"
                )
            # 2. The stand-in test's collateral damage.
            if cutout and stats["near_black_opaque"] > NEAR_BLACK_SHARE:
                notes.append(
                    f"{material_name} 有 {stats['near_black_opaque']:.1%} 不透明近黑像素"
                    f"（会被近黑判据误丢）"
                )

        # 3. A hull where the game has no outline pass. After 2026-10-30 the
        #    app skips these by shader name; a warning here means a shader kind
        #    showed up that the allowlist has not been checked against.
        outlined = shader in OUTLINED_SHADERS
        if not outlined and not blended and shader not in KNOWN_SINGLE_PASS:
            errors.append(f"{material_name}（{shader}）没见过的 shader，判不出有没有描边 pass")

        # 4. A hull with no colour to draw with.
        if outlined:
            outline = colours.get("_OutlineColor")
            if outline is None:
                warnings.append(f"{material_name}（{shader}）没有 _OutlineColor，描边壳会是纯黑")
            elif max(outline[:3]) < 0.02:
                warnings.append(
                    f"{material_name}（{shader}）_OutlineColor 近似 0，描边壳几乎纯黑"
                )

        # 5. Tiled decals. Fine under `address::repeat`, counted for the record.
        if material_name in uv_ranges:
            low, high = uv_ranges[material_name]
            if low < -0.001 or high > 1.001:
                notes.append(f"{material_name} UV 越界 [{low:.2f}, {high:.2f}]（靠 repeat 采样）")

    return {
        "model": name,
        "materials": len(table),
        "errors": errors,
        "warnings": warnings,
        "notes": notes,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--verbose", action="store_true", help="连 notes 一起打出来")
    args = parser.parse_args(argv)

    directories = sorted({p.parent for p in args.root.rglob("*-materials.json")})
    if not directories:
        print(f"{args.root} 下没有 *-materials.json", file=sys.stderr)
        return 1

    reports = []
    for directory in directories:
        try:
            reports.append(audit_model(directory))
        except Exception as error:  # a broken model must not stop the sweep
            reports.append({
                "model": directory.name,
                "materials": 0,
                "errors": [f"读不出来：{error}"],
                "warnings": [],
                "notes": [],
            })

    clean = 0
    for report in reports:
        if not report["errors"] and not report["warnings"]:
            clean += 1
            continue
        status = "FAIL" if report["errors"] else "WARN"
        print(f"[{status}] {report['model']}（{report['materials']} 个材质）")
        for item in report["errors"]:
            print(f"        error: {item}")
        for item in report["warnings"]:
            print(f"        warn : {item}")
        if args.verbose:
            for item in report["notes"]:
                print(f"        note : {item}")

    errors = sum(len(r["errors"]) for r in reports)
    warnings = sum(len(r["warnings"]) for r in reports)
    print(f"\n{len(reports)} 套，{clean} 套干净，{errors} 条 error，{warnings} 条 warn")
    if args.json:
        args.json.write_text(json.dumps(reports, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
