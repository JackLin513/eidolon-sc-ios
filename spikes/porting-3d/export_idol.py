#!/usr/bin/env python3
"""Export every outfit one idol has, pairing bodies and heads by naming.

`export_corpus.py` pairs through the cache index, which only knows about
costumes that happened to be indexed. This script starts from the downloaded
asset names instead: every `cb_<costume>_<idol>.unity3d` is a body, and the head
is `ch_<costume>_<idol>.unity3d` when that bundle carries a face material,
otherwise the base `ch_pr001_<idol>` head.

    V=build/mltd-spike/venv/bin/python
    $V spikes/porting-3d/export_idol.py --assets build/mltd-spike/assets \\
        --idol 001har --out build/mltd-corpus --blender .../Blender
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import export_corpus

BODY = re.compile(r"^cb_([a-z]{2}\d{3})_(\d{3}[a-z]{3})\.unity3d$")


def has_face(path: Path) -> bool:
    if not path.exists():
        return False
    return any(
        material.endswith("_face_m")
        for material in export_corpus.materials_in(str(path))
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--idol", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--blender", required=True)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)

    base_head = args.assets / f"ch_pr001_{args.idol}.unity3d"
    costumes = sorted(
        match.group(1)
        for path in args.assets.iterdir()
        if (match := BODY.match(path.name)) and match.group(2) == args.idol
    )
    if not costumes:
        print(f"{args.idol}: 没有本体")
        return 1

    done = skipped = failed = 0
    for index, costume in enumerate(costumes, 1):
        name = f"{args.idol}-{costume}"
        target = args.out / name
        if (target / f"{name}.usdz").exists() and not args.force:
            skipped += 1
            continue
        body = args.assets / f"cb_{costume}_{args.idol}.unity3d"
        own_head = args.assets / f"ch_{costume}_{args.idol}.unity3d"
        head = own_head if has_face(own_head) else base_head
        if not has_face(head):
            print(f"[{index}/{len(costumes)}] {name} 缺头部")
            failed += 1
            continue
        target.mkdir(parents=True, exist_ok=True)
        ok, message = export_corpus.export_one(name, str(body), str(head), target, args.blender)
        if not ok:
            print(f"[{index}/{len(costumes)}] {name} {message}")
            failed += 1
            continue
        done += 1
        print(f"[{index}/{len(costumes)}] {name} ok", flush=True)

    print(f"\n完成 {done}，跳过 {skipped}，失败 {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
