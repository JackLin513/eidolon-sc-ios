#!/usr/bin/env python3
"""Keep the local corpus in step with whatever the game has downloaded.

The asset CDN denies anonymous access, so bundles only reach this machine
through the game itself (photo studio, theater, costume select, or the in-game
bulk download). Everything it fetches lands in the cache, and this script runs
the offline steps over that cache, skipping anything already done:

    index_cache.py  →  scan_animations.py  →  export_pose_library.py
                    →  export_corpus.py (per costume code)

    V=build/mltd-spike/venv/bin/python
    $V spikes/porting-3d/sync_cache.py --root <Documents> --work build \\
        --blender .../Blender.app/Contents/MacOS/Blender --once
    $V spikes/porting-3d/sync_cache.py ... --loop 900

Read-only with respect to the game: it never writes into the cache.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def run(command: list[str], label: str) -> bool:
    print(f"== {label}", flush=True)
    step = subprocess.run(command, capture_output=True, text=True)
    tail = (step.stdout or step.stderr).strip().splitlines()[-3:]
    for line in tail:
        print("   " + line, flush=True)
    return step.returncode == 0


def costume_codes(index: Path) -> list[str]:
    codes: set[str] = set()
    if not index.exists():
        return []
    for line in index.read_text().splitlines():
        try:
            codes.update(json.loads(line)["costumes"])
        except (ValueError, KeyError):
            continue
    return sorted(codes)


def sync(args) -> None:
    index = args.work / "mltd-index.jsonl"
    animations = args.work / "mltd-animations.jsonl"

    run([sys.executable, str(HERE / "index_cache.py"), "--root", str(args.root),
         "--out", str(index)], "索引角色 bundle")
    run([sys.executable, str(HERE / "scan_animations.py"), "--root", str(args.root),
         "--out", str(animations)], "扫描动作 bundle")
    run([sys.executable, str(HERE / "export_pose_library.py"), "--index", str(animations),
         "--out", str(args.poses), "--catalog", str(args.poses.parent / "poses.json")],
        "导出姿势库")
    for code in costume_codes(index):
        if code.startswith("ex"):
            continue  # 活动/兑换衣装没有稳定的本体命名，先不自动导
        run([sys.executable, str(HERE / "export_corpus.py"), "--index", str(index),
             "--out", str(args.corpus), "--blender", str(args.blender), "--costume", code],
            f"导出衣装 {code}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True,
                        help="游戏容器的 Documents 目录（Cache00 在其下）")
    parser.add_argument("--work", type=Path, default=Path("build"))
    parser.add_argument("--corpus", type=Path, default=Path("build/mltd-corpus"))
    parser.add_argument("--poses", type=Path, default=Path("build/poses"))
    parser.add_argument("--blender", required=True)
    parser.add_argument("--loop", type=int, help="每隔这么多秒再跑一遍")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args(argv)

    if not args.loop or args.once:
        sync(args)
        return 0
    while True:
        sync(args)
        print(f"-- 睡 {args.loop}s", flush=True)
        time.sleep(args.loop)


if __name__ == "__main__":
    raise SystemExit(main())
