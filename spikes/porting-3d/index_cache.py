#!/usr/bin/env python3
"""Index the game's asset cache by content, not by file name.

The downloaded bundles are stored under SHA-1 names, so there is nothing in a
path that says which idol or costume it holds. This walks the cache, opens each
bundle and records the character ids it finds in its material names
(`cb_pr001_014mir_01_m` → costume `pr001`, idol `014mir`), writing one JSON line
per bundle so an interrupted run can be resumed.

    uv run --with UnityPy python index_cache.py \\
        --root ~/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents \\
        --out build/mltd-index.jsonl

Read-only: nothing in the cache is modified.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import UnityPy

# `ch_pr001_014mir_hair_m`: the costume id and the idol id sit side by side.
COSTUME = re.compile(r"_([a-z]{2}\d{3})_(\d{3}[a-z]{3})_")


def describe(path: Path) -> dict | None:
    try:
        env = UnityPy.load(str(path))
    except Exception:
        return None

    ids: set[tuple[str, str]] = set()
    kinds: dict[str, int] = {}
    for obj in env.objects:
        kind = obj.type.name
        kinds[kind] = kinds.get(kind, 0) + 1
        if kind != "Material":
            continue
        if m := COSTUME.search(obj.read().m_Name or ""):
            ids.add((m.group(1), m.group(2)))

    if not ids:
        return None
    return {
        "file": str(path),
        "size": path.stat().st_size,
        "costumes": sorted({c for c, _ in ids}),
        "idols": sorted({i for _, i in ids}),
        "objects": kinds,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--limit", type=int, help="只看前 N 个文件，用来验速度")
    args = parser.parse_args(argv)

    done: set[str] = set()
    if args.out.exists():
        for line in args.out.read_text().splitlines():
            try:
                done.add(json.loads(line)["file"])
            except (ValueError, KeyError):
                continue

    paths = [p for p in sorted(args.root.rglob("*")) if p.is_file()]
    if args.limit:
        paths = paths[: args.limit]

    hits = 0
    with args.out.open("a") as out:
        for index, path in enumerate(paths, 1):
            if str(path) in done:
                continue
            record = describe(path)
            if record:
                out.write(json.dumps(record, ensure_ascii=False) + "\n")
                out.flush()
                hits += 1
            if index % 200 == 0:
                print(f"{index}/{len(paths)} 扫过，{hits} 个含角色", flush=True)

    print(f"完成：{len(paths)} 个文件，{hits} 个含角色，写到 {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
