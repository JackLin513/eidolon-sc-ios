#!/usr/bin/env python3
"""Describe what the local (or NAS) library holds, in one JSON file.

The library is meant to move to the NAS and later be served to the app, so the
app needs a single index that says which outfits exist, where their USDZ lives,
how big it is, and which pose clips are available. This walks the directories
and writes that index; nothing is copied or changed.

    V=build/mltd-spike/venv/bin/python
    $V spikes/porting-3d/build_library.py \\
        --corpus build/mltd-corpus --poses build/mltd-spike/out/poses \\
        --out build/mltd-library.json --base-url http://nas.local/mltd-library
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

FORMAT = "eidolon.library/1"


def model_entry(directory: Path) -> dict | None:
    """One outfit: `<idol>-<costume>/<same>.usdz` plus its sidecars."""
    usdz = directory / f"{directory.name}.usdz"
    if not usdz.exists():
        return None
    idol, _, costume = directory.name.partition("-")
    entry = {
        "id": directory.name,
        "idol": idol,
        "costume": costume,
        "usdz": f"{directory.name}/{usdz.name}",
        "bytes": usdz.stat().st_size,
    }
    for suffix, key in (("-materials.json", "materials"), ("-bounds.json", "bounds")):
        sidecar = directory / f"{directory.name}{suffix}"
        if sidecar.exists():
            entry[key] = f"{directory.name}/{sidecar.name}"
    return entry


def pose_entry(path: Path, seconds: float | None = None) -> dict | None:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return {
        "clip": path.name.removesuffix(".motion.json"),
        "file": path.name,
        "frames": data.get("frames"),
        "fps": data.get("fps"),
        "seconds": round(data.get("time_length", 0), 3),
        "bones": len(data.get("bones", [])),
    }


def build(corpus: Path, poses: Path, base_url: str | None) -> dict:
    models = []
    if corpus.exists():
        for directory in sorted(p for p in corpus.iterdir() if p.is_dir()):
            entry = model_entry(directory)
            if entry:
                models.append(entry)
    clips = []
    if poses.exists():
        for path in sorted(poses.glob("*.motion.json")):
            entry = pose_entry(path)
            if entry:
                clips.append(entry)
    library = {
        "format": FORMAT,
        "base_url": base_url,
        "models": models,
        "poses": clips,
    }
    return library


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--poses", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--base-url", help="前缀；以后从 NAS 取时填服务器地址")
    args = parser.parse_args(argv)

    library = build(args.corpus, args.poses, args.base_url)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(library, indent=1, ensure_ascii=False))
    size = sum(entry["bytes"] for entry in library["models"])
    print(f"{len(library['models'])} 套衣装（{size / 1e9:.2f} GB）、"
          f"{len(library['poses'])} 条动作 → {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
