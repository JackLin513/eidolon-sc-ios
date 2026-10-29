#!/usr/bin/env python3
"""Static health check for a corpus of exported MLTD characters.

Renders nothing: it reads each `*-materials.json` next to its `*-params.png`
and reports the things that silently break a character on the device — an
unknown shader variant, more materials than the atlas has rows, a texture slot
the shader needs but the bundle did not carry, and the atlas width drifting away
from the constant compiled into `ToonShading.metal`.

Usage:
    check_corpus.py --root build/mltd-corpus
    check_corpus.py --root build/mltd-corpus --json report.json

Exit code is 0 when every model passes, 1 when any model has an error, so it can
gate a batch run.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from material_atlas import CAPACITY, LAYOUT, SHADER_KINDS

HERE = Path(__file__).resolve().parent
METAL = HERE / "ios" / "ToonShading.metal"

# Slots the shader samples. `_MainTex` is the base colour, `_SubTex` the
# additive/glow layer; a material without the first one cannot be drawn at all.
REQUIRED_TEXTURES = ("_MainTex",)
OPTIONAL_TEXTURES = ("_SubTex",)


def shader_columns() -> int | None:
    """`kParamColumns` as compiled into the shader, or None if unreadable."""
    try:
        text = METAL.read_text()
    except OSError:
        return None
    match = re.search(r"constant uint kParamColumns = (\d+);", text)
    return int(match.group(1)) if match else None


def check_model(materials_path: Path) -> dict:
    name = materials_path.name.removesuffix("-materials.json")
    table = json.loads(materials_path.read_text())
    materials = table.get("materials", {})
    errors: list[str] = []
    warnings: list[str] = []

    if not materials:
        errors.append("materials 表是空的")

    rows = len(materials)
    if rows > CAPACITY:
        errors.append(f"{rows} 个材质，图集只有 {CAPACITY} 行")

    shaders = sorted({m.get("shader", "") for m in materials.values()})
    unknown = [s for s in shaders if s not in SHADER_KINDS and s]
    if unknown:
        errors.append("未知 shader：" + "、".join(s.split("/")[-1] for s in unknown))

    # Keyword variants we have not ported. They are not fatal — the default
    # branch still draws something — but the picture will be wrong.
    variants = set()
    for material in materials.values():
        for keyword in material.get("keywords", []) or []:
            if keyword in {"_USEREFLECT_ON", "MOSAIC_ON", "_ISREDDISH_ON",
                           "_ISCUTOFF_ON", "_REFLECTION_ON"}:
                variants.add(keyword)
    if variants:
        warnings.append("未实现的变体：" + "、".join(sorted(variants)))

    for material_name, material in materials.items():
        textures = material.get("textures", {})
        for slot in REQUIRED_TEXTURES:
            if slot not in textures:
                errors.append(f"{material_name} 缺少 {slot}")
        for slot in OPTIONAL_TEXTURES:
            if slot not in textures:
                warnings.append(f"{material_name} 没有 {slot}")

    atlas_path = materials_path.with_name(f"{name}-params.png")
    if not atlas_path.exists():
        errors.append("缺少 params.png")
    else:
        expected = shader_columns()
        if expected is not None:
            from PIL import Image

            width = Image.open(atlas_path).size[0]
            if width != expected:
                errors.append(
                    f"图集宽 {width}，shader 里 kParamColumns = {expected}"
                )
            if width != len(LAYOUT):
                errors.append(f"图集宽 {width}，LAYOUT 有 {len(LAYOUT)} 列")

    # A parameter no material sets anywhere still gets a row of zeroes, which is
    # legitimate; a parameter missing from *every* material is more likely a
    # renamed property and worth a look.
    unused = []
    for property_name, channel in LAYOUT:
        if channel in ("kind", "-"):
            continue
        if not any(
            property_name in material.get("colours", {})
            or property_name in material.get("floats", {})
            for material in materials.values()
        ):
            unused.append(property_name)
    if unused:
        warnings.append("所有材质都没有这些属性：" + "、".join(sorted(set(unused))))

    return {
        "model": name,
        "materials": rows,
        "shaders": [s.split("/")[-1] for s in shaders],
        "errors": errors,
        "warnings": warnings,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--json", type=Path, help="把明细写到这个文件")
    args = parser.parse_args(argv)

    paths = sorted(args.root.rglob("*-materials.json"))
    if not paths:
        print(f"{args.root} 下没有 *-materials.json", file=sys.stderr)
        return 1

    reports = [check_model(path) for path in paths]
    failed = 0
    for report in reports:
        status = "FAIL" if report["errors"] else ("WARN" if report["warnings"] else "ok  ")
        if report["errors"]:
            failed += 1
        print(f"[{status}] {report['model']:32s} 材质 {report['materials']:2d} "
              f"{'/'.join(report['shaders'])}")
        for item in report["errors"]:
            print(f"        error: {item}")
        for item in report["warnings"]:
            print(f"        warn : {item}")

    print(f"\n{len(reports)} 套，{failed} 套有错误")
    if args.json:
        args.json.write_text(json.dumps(reports, ensure_ascii=False, indent=2))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
