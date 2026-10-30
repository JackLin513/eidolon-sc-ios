#!/usr/bin/env python3
"""Export every idol's default outfit from the indexed asset cache.

Runs the three stages per character — glTF (this process), `.usdc` (Blender),
`.usdz` (`pack_usd` under `uv`) — and skips characters that already have a
packed `.usdz`, so an interrupted run resumes where it stopped.

    venv/bin/python export_corpus.py --index build/mltd-index.jsonl \\
        --out build/mltd-corpus --blender .../Blender42.app/Contents/MacOS/Blender

Pairing is by content, not file name: a bundle is a body when it carries
`cb_pr001_<idol>_01_m`, and a head when it carries `ch_pr001_<idol>_face_m` and
no body material. The head with the fewest materials wins — the bigger ones
carry another costume's accessory.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

import UnityPy

HERE = Path(__file__).resolve().parent


def materials_in(path: str) -> set[str]:
    try:
        env = UnityPy.load(path)
    except Exception:
        return set()
    return {o.read().m_Name for o in env.objects if o.type.name == "Material"} - {""}


def pair(idol: str, files: list[str], args_costume: str = "pr001") -> tuple[str | None, str | None]:
    body: str | None = None
    heads: list[tuple[int, str]] = []
    for path in files:
        mats = materials_in(path)
        if f"cb_{args_costume}_{idol}_01_m" in mats and body is None:
            body = path
        if f"ch_pr001_{idol}_face_m" in mats and not any(m.startswith("cb_") for m in mats):
            # A head bundle can carry an accessory belonging to another costume
            # (`ex007_acc01`, `ss010_acc01`). Those meshes are single-bone props
            # and have no place on the model, so prefer a bundle whose parts all
            # belong to the costume being exported.
            foreign = [m for m in mats if m.startswith("ch_") and f"_{args_costume}_" not in m]
            heads.append((len(foreign), len(mats), path))
    head = min(heads)[2] if heads else None
    return body, head


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--blender", required=True)
    parser.add_argument("--costume", default="pr001")
    parser.add_argument("--limit", type=int)
    args = parser.parse_args(argv)

    by_idol: dict[str, list[str]] = {}
    for line in args.index.read_text().splitlines():
        record = json.loads(line)
        if args.costume in record["costumes"]:
            for idol in record["idols"]:
                by_idol.setdefault(idol, []).append(record["file"])

    idols = sorted(by_idol)
    if args.limit:
        idols = idols[: args.limit]

    done = skipped = failed = 0
    for index, idol in enumerate(idols, 1):
        name = f"{idol}-{args.costume}"
        target = args.out / name
        if (target / f"{name}.usdz").exists():
            skipped += 1
            continue
        body, head = pair(idol, by_idol[idol], args.costume)
        if not (body and head):
            print(f"[{index}/{len(idols)}] {idol} 缺{'本体' if not body else '头部'}，跳过")
            failed += 1
            continue
        target.mkdir(parents=True, exist_ok=True)

        step = subprocess.run(
            [sys.executable, str(HERE / "export_character.py"),
             "--body", body, "--head", head, "--out", str(target), "--name", name],
            capture_output=True, text=True,
        )
        if step.returncode != 0:
            print(f"[{index}/{len(idols)}] {idol} glTF 失败 {step.stderr.strip()[-200:]}")
            failed += 1
            continue

        subprocess.run(
            [args.blender, "--background", "--python", str(HERE / "gltf_to_usdz.py"),
             "--", str(target / f"{name}.gltf"), str(target / f"{name}.usdc")],
            capture_output=True, text=True,
        )
        step = subprocess.run(
            ["uv", "run", "--quiet", "--with", "usd-core",
             "python", str(HERE / "pack_usd.py"), "--",
             str(target / f"{name}.usdc"), str(target / f"{name}.usdz")],
            capture_output=True, text=True,
        )
        if step.returncode != 0:
            print(f"[{index}/{len(idols)}] {idol} 打包失败 {step.stderr.strip()[-200:]}")
            failed += 1
            continue
        done += 1
        print(f"[{index}/{len(idols)}] {name} ok", flush=True)

    print(f"\n完成 {done}，跳过 {skipped}，失败 {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
