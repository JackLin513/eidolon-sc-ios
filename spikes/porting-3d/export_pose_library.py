#!/usr/bin/env python3
"""Decode every pose-like AnimationClip found in the cache into motion files.

`scan_animations.py` records which bundles hold clips; this walks that record
and turns the clips we can play — photo poses, theater standbys, commu poses,
login actions — into the same `eidolon.motion/1` the dance player already
reads. Existing outputs are skipped, so a re-run only fills gaps.

    V=build/mltd-spike/venv/bin/python
    $V spikes/porting-3d/export_pose_library.py \\
        --index build/mltd-animations.jsonl --out build/mltd-spike/out/poses \\
        --catalog build/mltd-spike/out/poses.json

The catalogue keeps the source bundle for every clip (issue #9's provenance
rule) and is what a future sibling index on the device would be built from.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import motion
import photo_pose

#: Clip name prefixes that carry a body pose. `lt_*` and `2dp_*` are UI/theater
#: furniture, not character poses.
POSE_PREFIXES = ("pho_", "the_", "com_", "lgn_")


def is_pose(name: str) -> bool:
    return name.startswith(POSE_PREFIXES)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--fps", type=int, default=motion.TARGET_FPS)
    parser.add_argument("--prefix", action="append", help="只看这些前缀，可重复")
    args = parser.parse_args(argv)

    prefixes = tuple(args.prefix) if args.prefix else POSE_PREFIXES
    args.out.mkdir(parents=True, exist_ok=True)

    catalog: list[dict] = []
    written = skipped = failed = 0
    for line in args.index.read_text().splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue  # a scan still being written leaves a partial last line
        wanted = [name for name in record["clips"] if name.startswith(prefixes) and is_pose(name)]
        if not wanted:
            continue
        try:
            import UnityPy

            environment = UnityPy.load(record["file"])
            clips = {
                obj.read().m_Name: obj.read()
                for obj in environment.objects
                if obj.type.name == "AnimationClip"
            }
        except Exception as error:  # noqa: BLE001 - a bad bundle must not stop the run
            print(f"跳过 {Path(record['file']).name}: {error}", file=sys.stderr)
            failed += 1
            continue
        for name in wanted:
            target = args.out / f"{name}.motion.json"
            if target.exists():
                skipped += 1
                catalog.append({"clip": name, "bundle": record["file"], "file": str(target),
                                "state": "cached"})
                continue
            clip = clips.get(name)
            if clip is None:
                failed += 1
                continue
            try:
                decoded = photo_pose.decode_clip(clip)
                packed = motion.build_motion(photo_pose.to_motion_asset(decoded), fps=args.fps)
            except Exception as error:  # noqa: BLE001
                print(f"{name}: {error}", file=sys.stderr)
                failed += 1
                continue
            target.write_text(json.dumps(packed, separators=(",", ":"), ensure_ascii=False))
            written += 1
            catalog.append({"clip": name, "bundle": record["file"], "file": str(target),
                            "seconds": decoded.length, "bones": len(packed["bones"]),
                            "state": "written"})
            print(f"{name}  {decoded.length:.2f}s  {len(packed['bones'])} bones", flush=True)

    if args.catalog:
        args.catalog.parent.mkdir(parents=True, exist_ok=True)
        args.catalog.write_text(json.dumps(catalog, indent=1, ensure_ascii=False))
    print(f"写出 {written}，跳过 {skipped}，失败 {failed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
