#!/usr/bin/env python3
"""Batch-export every MLTD character in a corpus directory.

Two modes:

    batch_export.py scan   --root <bundle dir> --manifest manifest.json
    batch_export.py export --manifest manifest.json --out build/mltd-corpus

`scan` only *proposes* pairings — it groups Unity bundles by the character id in
their file name and guesses which one is the head. Look at the manifest before
exporting; a wrong guess shows up as a character wearing someone else's face.

`export` runs `export_character.py` per entry, which writes the glTF, the
material table and the parameter atlas. The Blender and `pack_usd` steps are
separate tools; their command is printed for each character rather than run,
because that path depends on a Blender install this script cannot assume.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
UNITY_SIGNATURE = b"UnityFS"

# `ch_pr001_014mir_hair_m` and friends carry a five-character costume id.
COSTUME = re.compile(r"\b([a-z]{2}\d{3})\b")
HEAD_HINTS = ("head", "kao", "face")


def is_bundle(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(8).startswith(UNITY_SIGNATURE)
    except OSError:
        return False


def scan(root: Path) -> list[dict]:
    """Group bundles into candidate head/body pairs."""
    groups: dict[str, list[Path]] = {}
    for path in root.rglob("*"):
        if not path.is_file() or not is_bundle(path):
            continue
        match = COSTUME.search(path.name)
        if not match:
            continue
        groups.setdefault(match.group(1), []).append(path)

    entries = []
    for costume, paths in sorted(groups.items()):
        paths.sort(key=lambda p: p.name)
        head = next(
            (p for p in paths if any(h in p.name.lower() for h in HEAD_HINTS)),
            None,
        )
        bodies = [p for p in paths if p is not head]
        if not bodies:
            continue
        entries.append({
            "name": costume,
            "body": str(bodies[0]),
            "head": str(head) if head else None,
            "candidates": [str(p) for p in paths],
        })
    return entries


def export(manifest: Path, out: Path) -> int:
    entries = json.loads(manifest.read_text())
    failures = 0
    for entry in entries:
        name = entry["name"]
        target = out / name
        target.mkdir(parents=True, exist_ok=True)
        command = [
            sys.executable, str(HERE / "export_character.py"),
            "--body", entry["body"],
            "--out", str(target),
            "--name", name,
        ]
        if entry.get("head"):
            command += ["--head", entry["head"]]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            failures += 1
            print(f"[FAIL] {name}\n{result.stderr.strip()[-800:]}")
            continue
        print(f"[ok]   {name} -> {target}")
        print(f"       接着跑：blender --background --python gltf_to_usdz.py -- "
              f"{target}/{name}.glb {target}/{name}.usdc")
        print(f"               python3 pack_usd.py {target}/{name}.usdc "
              f"{target}/{name}.usdz")
    print(f"\n{len(entries)} 套，{failures} 套导出失败")
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("scan", "export"))
    parser.add_argument("--root", type=Path)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args(argv)

    if args.mode == "scan":
        if not args.root:
            parser.error("scan 需要 --root")
        entries = scan(args.root)
        args.manifest.write_text(json.dumps(entries, ensure_ascii=False, indent=2))
        print(f"{len(entries)} 组候选写到 {args.manifest}")
        for entry in entries:
            picked = entry["body"]
            print(f"  {entry['name']}: body={Path(picked).name} "
                  f"head={(Path(entry['head']).name if entry['head'] else '无')} "
                  f"({len(entry['candidates'])} 个候选)")
        return 0

    if not args.out:
        parser.error("export 需要 --out")
    return export(args.manifest, args.out)


if __name__ == "__main__":
    raise SystemExit(main())
