#!/usr/bin/env python3
"""Find materials wearing an outline hull the game never gave them.

The 003mik pendant bug looked like an alpha problem for a whole session. It was
a solid black rectangle — a duplicate mesh pushed out along the normals, drawn
with an `_OutlineColor` of zero. The giveaway is that it *vanishes* when the
outline pass is switched off, so this compares two screenshots of the same
model, one with `EIDOLON_3D_NO_OUTLINE=1`.

A healthy model differs only along silhouettes: thin, one-pixel-wide lines that
a morphological erosion wipes out. A defect survives erosion, because it is a
filled area rather than an edge.

Usage:
    audit_outline.py --root /tmp/sweep
    audit_outline.py --root /tmp/sweep --json report.json

Screenshots are named `<model>.on.png` and `<model>.off.png`.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageFilter

# A pixel counts as changed when any channel moves by more than this. The two
# renders differ by a few levels everywhere from shot noise.
CHANGE = 16
# Erosion radius that a silhouette line cannot survive but a filled patch can.
EROSION = 9
# Share of the frame that may survive erosion before it is called a defect.
BLOB_SHARE = 0.0005
# Rows at the top of the frame that are never the model. The Dynamic Island
# opens and closes between shots and is a large filled shape, so without this
# every model "fails" with the same suspiciously round number.
SKIP_TOP = 150


def analyse(on: Path, off: Path) -> dict:
    a = Image.open(on).convert("RGB")
    b = Image.open(off).convert("RGB")
    if a.size != b.size:
        return {"model": on.name, "error": f"尺寸不一致 {a.size} vs {b.size}"}

    difference = ImageChops.difference(a, b).convert("L")
    mask = difference.point(lambda value: 255 if value > CHANGE else 0)
    mask.paste(0, (0, 0, mask.width, SKIP_TOP))
    changed = sum(mask.histogram()[255:]) / (a.size[0] * a.size[1])

    # Erode: anything narrower than the kernel disappears. What is left is a
    # filled region, which is exactly what a stray hull looks like.
    survived = mask.filter(ImageFilter.MinFilter(EROSION))
    blob = sum(survived.histogram()[255:]) / (a.size[0] * a.size[1])

    return {
        "model": on.name.removesuffix(".on.png"),
        "changed": changed,
        "blob": blob,
        "verdict": "defect" if blob > BLOB_SHARE else "ok",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--dump", type=Path, help="把有问题的掩码写到这个目录")
    args = parser.parse_args(argv)

    pairs = [
        (path, path.with_name(path.name.replace(".on.png", ".off.png")))
        for path in sorted(args.root.glob("*.on.png"))
    ]
    pairs = [(on, off) for on, off in pairs if off.exists()]
    if not pairs:
        print(f"{args.root} 下没有成对的 *.on.png / *.off.png", file=sys.stderr)
        return 1

    reports = [analyse(on, off) for on, off in pairs]
    broken = [r for r in reports if r.get("verdict") == "defect" or r.get("error")]
    for report in broken:
        if "error" in report:
            print(f"[FAIL] {report['model']}: {report['error']}")
        else:
            print(f"[HULL] {report['model']}: 变化 {report['changed']:.2%}，"
                  f"腐蚀后仍剩 {report['blob']:.3%}")
            if args.dump:
                args.dump.mkdir(parents=True, exist_ok=True)
                on = args.root / f"{report['model']}.on.png"
                off = args.root / f"{report['model']}.off.png"
                difference = ImageChops.difference(
                    Image.open(on).convert("RGB"), Image.open(off).convert("RGB")
                ).convert("L")
                mask = difference.point(lambda value: 255 if value > CHANGE else 0)
                mask.save(args.dump / f"{report['model']}-mask.png")

    worst = sorted(
        (r for r in reports if "blob" in r), key=lambda r: r["blob"], reverse=True
    )[:3]
    print(f"\n{len(reports)} 套，{len(broken)} 套有描边壳嫌疑")
    if worst:
        print("腐蚀后残留最多的三套：" + "、".join(
            f"{r['model']}({r['blob']:.3%})" for r in worst
        ))
    if args.json:
        args.json.write_text(json.dumps(reports, ensure_ascii=False, indent=2))
    return 1 if broken else 0


if __name__ == "__main__":
    raise SystemExit(main())
