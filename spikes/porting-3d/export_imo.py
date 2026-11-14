#!/usr/bin/env python3
"""Export the game's raw `CharacterImasMotionAsset` (imo) data losslessly.

The Unity spike used to consume a 30 fps re-baked clip. That is not what the game
does: the game keeps every curve's `property_type` / `key_type` / key values and
evaluates them on a 1/60 grid (`CharacterImasMotionPlayer.SolveCurve`). This tool
writes the raw asset so the runtime can do the same.

The serialized `Curve` in the shipped bundles carries a string list `attribs`
(e.g. `["property_type AngleX", "key_type FullFrame"]`) plus a flat `values`
array; both are copied verbatim. Interpretation belongs to the runtime port
(`CharacterImasMotionNative.cs`, which mirrors `motion.py` / native addresses).

Usage:
    python3 export_imo.py --bundle ~/mltd-work/downloaded/v1078590/<imo>.unity3d \
        --out ~/mltd-work/motion
    python3 export_imo.py --bundle <dir-of-bundles> --out ... --name loveig

Output: one `<asset name>.imo.json` per asset + `index.json`:
    {"format":"eidolon.imo/1","name":...,"kind":"imo.chara","time_length":130.0,
     "source_bundle":..., "curves":[{"path":...,"attribs":[...],"values":[...]}]}
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import UnityPy


def iter_assets(path: Path):
    env = UnityPy.load(str(path))
    for obj in env.objects:
        if obj.type.name != "MonoBehaviour":
            continue
        try:
            tree = obj.read_typetree()
        except Exception:
            continue
        if "curves" not in tree or "kind" not in tree:
            continue
        curves = []
        for curve in tree.get("curves") or []:
            curves.append({
                "path": curve.get("path", ""),
                "attribs": list(curve.get("attribs") or []),
                "values": [float(v) for v in (curve.get("values") or [])],
            })
        yield {
            "format": "eidolon.imo/1",
            "name": tree.get("m_Name") or path.stem,
            "kind": tree.get("kind", ""),
            "time_length": float(tree.get("time_length", 0.0)),
            "date": tree.get("date", ""),
            "source_bundle": path.name,
            "curves": curves,
        }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bundle", required=True, help="one .unity3d or a directory of them")
    parser.add_argument("--out", required=True)
    parser.add_argument("--name", help="only bundles whose file name contains this")
    args = parser.parse_args(argv)

    source = Path(args.bundle).expanduser().resolve()
    out = Path(args.out).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    paths = [source] if source.is_file() else sorted(source.glob("*.unity3d"))

    index = []
    for path in paths:
        if args.name and args.name not in path.name:
            continue
        try:
            assets = list(iter_assets(path))
        except Exception as error:  # a bad bundle must not stop the batch
            print(f"! {path.name}: {error}", file=sys.stderr)
            continue
        for asset in assets:
            target = out / (safe(asset["name"]) + ".imo.json")
            target.write_text(json.dumps(asset, ensure_ascii=False, separators=(",", ":")))
            curves = asset["curves"]
            kinds = {
                "kind": asset["kind"],
                "time_length": asset["time_length"],
                "curves": len(curves),
            }
            index.append({"name": asset["name"], **kinds, "file": target.name,
                          "bytes": target.stat().st_size})
            print(f"+ {asset['name']} kind={asset['kind']} curves={len(curves)} -> {target.name}")
    (out / "index.json").write_text(json.dumps({"format": "eidolon.imo/index/1", "assets": index},
                                               ensure_ascii=False, indent=2))
    print(f"wrote {len(index)} assets -> {out}")
    return 0


def safe(name: str) -> str:
    return "".join(c if c.isalnum() or c in "-._" else "_" for c in name)


if __name__ == "__main__":
    raise SystemExit(main())
