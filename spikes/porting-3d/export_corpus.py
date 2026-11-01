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
import re
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


def choose_pair(
    idol: str, costume: str, materials: dict[str, set[str]]
) -> tuple[str | None, str | None]:
    """Pick the body and head bundle for one costume out of the idol's bundles.

    Bodies are unambiguous: `cb_<costume>_<idol>_01_m` only appears in that
    costume's body. Heads are not — the eye materials are always named
    `ch_pr001_*`, and accessory bundles can carry another costume's parts — so
    a head is ranked by (does it carry this costume's face, how many foreign
    parts, how many parts) and the best one wins. A base `pr001` head is the
    fallback when the costume has no head of its own.
    """
    body: str | None = None
    heads: list[tuple[int, int, int, str]] = []
    for path, mats in materials.items():
        if f"cb_{costume}_{idol}_01_m" in mats and body is None:
            body = path
        faces = {m for m in mats if m.endswith("_face_m")}
        exact = f"ch_{costume}_{idol}_face_m" in faces
        base = f"ch_pr001_{idol}_face_m" in faces
        if not (exact or base):
            continue
        foreign = [
            m for m in mats
            if m.startswith("ch_") and f"_{costume}_" not in m
            and not re.match(r"ch_pr001_\w+_eye[lr]_m$", m)
        ]
        heads.append((0 if exact else 1, len(foreign), len(mats), path))
    return body, (min(heads)[3] if heads else None)


def pair(idol: str, files: list[str], args_costume: str = "pr001") -> tuple[str | None, str | None]:
    return choose_pair(idol, args_costume, {path: materials_in(path) for path in files})


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--blender", required=True)
    parser.add_argument("--costume", default="pr001")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--idols",
                        help="只导这些角色，逗号分隔；用来给每个角色挑一套演出服")
    parser.add_argument("--force", action="store_true",
                        help="重导已有的模型（换了导出逻辑时需要）")
    args = parser.parse_args(argv)

    # Files may only supply the body of the costume being exported, or the
    # base `pr001` head/bundle a costume without its own head falls back to.
    wanted_costs = {args.costume, "pr001"}
    by_idol: dict[str, list[str]] = {}
    for line in args.index.read_text().splitlines():
        record = json.loads(line)
        if wanted_costs & set(record["costumes"]):
            for idol in record["idols"]:
                by_idol.setdefault(idol, []).append(record["file"])

    idols = sorted(by_idol)
    if args.idols:
        wanted = {name.strip() for name in args.idols.split(",") if name.strip()}
        unknown = wanted - set(idols)
        if unknown:
            print(f"这些角色在 {args.costume} 里没有本体：{'、'.join(sorted(unknown))}")
        idols = [name for name in idols if name in wanted]
    if args.limit:
        idols = idols[: args.limit]

    done = skipped = failed = 0
    for index, idol in enumerate(idols, 1):
        name = f"{idol}-{args.costume}"
        target = args.out / name
        if (target / f"{name}.usdz").exists() and not args.force:
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
