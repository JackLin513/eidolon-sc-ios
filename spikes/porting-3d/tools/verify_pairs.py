#!/usr/bin/env python3
"""拿 NAS 上的 MLTD 资产批量导出并做静态校验（#130/#131 验收流水线）。

流程：按配对清单 → 从 NAS 资产接口取 cb_/ch_ → export_character.py 导出
→ 记录每个组合的成功/失败与材质统计，可断点续跑。

    verify_pairs.py --pairs pairs.tsv --base http://192.168.0.6:2830 \
        --token xxx --work /tmp/mltd-verify --out verify.csv
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent


def fetch(base: str, token: str, name: str, target: Path) -> bool:
    if target.exists() and target.stat().st_size > 0:
        return True
    req = urllib.request.Request(
        f"{base}/v1/assets/{name}", headers={"Authorization": f"Bearer {token}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            data = response.read()
    except Exception:
        return False
    target.write_bytes(data)
    return data[:7] == b"UnityFS"


def bundle_kinds(path: Path) -> dict[str, int]:
    """看 bundle 里到底有什么对象：身体模型必须有 Mesh + SkinnedMeshRenderer。

    踩过的坑：`cb_ex023_001har` 这类名字看着像身体，实际只装了一张贴图，
    直接拿去导出只会得到一个"只有头"的角色。
    """
    try:
        import UnityPy
    except ImportError:
        return {}
    try:
        env = UnityPy.load(str(path))
    except Exception:
        return {}
    kinds: dict[str, int] = {}
    for obj in env.objects:
        kinds[obj.type.name] = kinds.get(obj.type.name, 0) + 1
    return kinds


def cost_textures(entry: Path) -> tuple[int, int]:
    """材质数 / 贴图数，用于"贴图数量与材质声明一致"这条校验。"""
    mats = list(entry.glob("*-materials.json"))
    if not mats:
        return 0, 0
    data = json.loads(mats[0].read_text())
    textures = list((entry / "textures").glob("*.png")) if (entry / "textures").exists() else []
    return len(data), len(textures)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pairs", required=True, help="costume\\tidol\\tbody_asset\\thead_asset")
    parser.add_argument("--base", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--work", default="/tmp/mltd-verify")
    parser.add_argument("--out", default="verify.csv")
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    work = Path(args.work)
    bundles = work / "bundles"
    corpus = work / "corpus"
    bundles.mkdir(parents=True, exist_ok=True)
    corpus.mkdir(parents=True, exist_ok=True)

    rows = []
    with open(args.pairs) as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 4:
                rows.append(parts)
    if args.limit:
        rows = rows[: args.limit]

    done = 0
    failures = 0
    with open(args.out, "w", newline="") as out:
        writer = csv.writer(out)
        writer.writerow(["costume", "idol", "export", "materials", "textures", "note"])
        for costume, idol, body, head in rows:
            key = f"{idol}-{costume}"
            target = corpus / key
            note = ""
            if (target / f"{key}.gltf").exists():
                status = "cached"
            else:
                ok_body = fetch(args.base, args.token, body, bundles / body)
                ok_head = fetch(args.base, args.token, head, bundles / head)
                if not (ok_body and ok_head):
                    writer.writerow([costume, idol, "no-bundle", 0, 0, "资产未下载"])
                    failures += 1
                    continue
                result = subprocess.run(
                    [sys.executable, str(HERE / "export_character.py"),
                     "--body", str(bundles / body), "--head", str(bundles / head),
                     "--out", str(target), "--name", key],
                    capture_output=True, text=True,
                )
                status = "ok" if result.returncode == 0 else "fail"
                if status == "fail":
                    note = (result.stderr or "").strip()[-200:]
            if status in ("ok", "cached"):
                body_path = bundles / body
                kinds = bundle_kinds(body_path) if body_path.exists() else {}
                if kinds and "Mesh" not in kinds:
                    status = "texture-only"
                    note = "身体 bundle 里没有 Mesh（只有 " + ", ".join(sorted(kinds)) + "）"
            mats, texs = cost_textures(target)
            # 贴图数量少于材质数：之前就是这类"贴图丢失"缺陷。
            if status in ("ok", "cached") and texs < mats:
                status = "tex-missing"
                note = f"材质 {mats} 张，贴图只有 {texs} 张"
            writer.writerow([costume, idol, status, mats, texs, note])
            out.flush()
            done += 1
            if status not in ("ok", "cached"):
                failures += 1
            if done % 20 == 0:
                print(f"progress {done}/{len(rows)} failures={failures}", flush=True)
    print(f"完成 {done} 套，问题 {failures} 套", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
