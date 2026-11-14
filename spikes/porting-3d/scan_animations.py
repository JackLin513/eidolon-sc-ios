#!/usr/bin/env python3
"""Find every bundle in the cache that carries AnimationClips.

The cache names files by hash, so the only way to know what a bundle holds is to
open it. This walks the cache, records the AnimationClip names it finds, and
appends one JSON line per bundle so an interrupted run can be resumed.

    uv run --with UnityPy python scan_animations.py \\
        --root ~/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents \\
        --out build/mltd-animations.jsonl

Read-only: nothing in the cache is modified.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def clips_in(path: Path) -> dict:
    import UnityPy

    environment = UnityPy.load(str(path))
    clips = [o.read().m_Name for o in environment.objects if o.type.name == "AnimationClip"]
    avatars = sum(1 for o in environment.objects if o.type.name == "Avatar")
    meshes = sum(1 for o in environment.objects if o.type.name == "Mesh")
    return {"clips": clips, "avatars": avatars, "meshes": meshes}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--max-size", type=int, default=4_000_000)
    args = parser.parse_args(argv)

    done: set[str] = set()
    if args.out.exists():
        for line in args.out.read_text().splitlines():
            try:
                done.add(json.loads(line)["file"])
            except (ValueError, KeyError):
                continue

    paths = sorted(
        p for p in args.root.rglob("*")
        if p.is_file() and p.stat().st_size <= args.max_size and p not in done
    )
    hits = 0
    with args.out.open("a") as out:
        for index, path in enumerate(paths, 1):
            if str(path) in done:
                continue
            try:
                with path.open("rb") as handle:
                    header = handle.read(7)
            except OSError:
                continue
            if header[:7] != b"UnityFS":
                continue
            try:
                found = clips_in(path)
            except Exception:
                continue
            if not found["clips"]:
                continue
            hits += 1
            out.write(json.dumps({"file": str(path), **found}, ensure_ascii=False) + "\n")
            out.flush()
            print(f"[{index}/{len(paths)}] {path.name}: {len(found['clips'])} clips", flush=True)
    print(f"done: {hits} bundles with clips")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
