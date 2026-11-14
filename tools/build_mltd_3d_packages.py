#!/usr/bin/env python3
"""Build a clean 57-character MLTD content package and its 3D model package.

The old `eidolon-content-3dtest.eidolonpkg` was an SC content bundle with a
patched-in `haruka3d`; it is not an MLTD bundle. This script takes the separate
model3d package (57 MLTD characters, one duplicate id removed) and builds:
  - build/eidolon-model3d-mltd.eidolonpkg
  - build/eidolon-content-mltd.eidolonpkg

The content package is intentionally test-only: it uses the model ids as local
ids, placeholder one-line sheets and the synthetic sakura DB schema. It is
enough to exercise the 3D runtime and roster; real MLTD writing is separate.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import tempfile
import zipfile
import zlib
from pathlib import Path

NAMES = {
    "001har": "天海春香", "002chi": "如月千早", "003mik": "星井美希",
    "004yuk": "萩原雪歩", "005yay": "高槻やよい", "006mak": "菊地真",
    "007ior": "水瀬伊織", "008tak": "四条貴音", "009rit": "秋月律子",
    "010azu": "三浦あずさ", "011ami": "双海亜美", "012mam": "双海真美",
    "013hib": "我那覇響", "014mir": "春日未来", "015siz": "最上静香",
    "016tsu": "箱崎星梨花", "017kth": "高坂海美", "018ele": "エレナ",
    "019min": "大神環", "020meg": "高森藍子", "021mat": "松田亜利沙",
    "022ser": "佐竹美奈子", "023aka": "所恵美", "024ann": "徳川まつり",
    "025roc": "ロコ", "026yur": "真壁瑞希", "027say": "白石紬",
    "028ari": "有栖川夏葉", "029umi": "青羽美咲", "030iku": "伊吹翼",

}


def read_zip(path: Path, root: Path) -> None:
    with zipfile.ZipFile(path) as archive:
        archive.extractall(root)


def write_zip(root: Path, path: Path) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for item in sorted(root.rglob("*")):
            if item.is_file():
                archive.write(item, item.relative_to(root))


def manifest_files(root: Path) -> dict[str, dict[str, object]]:
    files: dict[str, dict[str, object]] = {}
    for item in sorted(root.rglob("*")):
        if not item.is_file():
            continue
        rel = item.relative_to(root).as_posix()
        if rel == "manifest.json":
            continue
        data = item.read_bytes()
        files[rel] = {"size": len(data), "crc32": format(zlib.crc32(data) & 0xFFFFFFFF, "08x")}
    return files


def build_model_package(src: Path, dst: Path) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        read_zip(src, root)
        manifest = json.loads((root / "manifest.json").read_text())
        seen: set[str] = set()
        characters = []
        for character in manifest["characters"]:
            local_id = character["localID"]
            if local_id == "haruka3d" or local_id in seen:
                continue
            seen.add(local_id)
            characters.append(character)
        manifest["characters"] = characters
        manifest["franchise"] = "mltd"
        manifest["contentSetID"] = "mltd.model3d.v1"
        manifest["created_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
        write_zip(root, dst)
    return [c["localID"] for c in characters]


def build_content_package(base: Path, ids: list[str], dst: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        read_zip(base, root)
        old_sheet = root / "characters/sheets/sakura.md"
        if old_sheet.exists():
            old_sheet.unlink()
        characters = []
        for local_id in ids:
            name = NAMES.get(local_id, f"MLTD {local_id}")
            sheet_rel = f"characters/sheets/{local_id}.md"
            sheet = root / sheet_rel
            sheet.parent.mkdir(parents=True, exist_ok=True)
            sheet.write_text(
                f"# 人设：{name}（MLTD 3D 测试）\n\n"
                f"你是《偶像大师 百万现场》的{name}，开朗、努力，正在和制作人说话。\n"
                "这是 3D 测试内容包，正式人设、声音与剧情后续替换。\n",
                encoding="utf-8",
            )
            characters.append({
                "id": local_id,
                "name": name,
                "name_zh": name,
                "intro": f"MLTD 3D 测试角色（{local_id}）",
                "unit": "MLTD",
                "color": "#7ec8e3",
                "sheet": sheet_rel,
                "speakers": [name],
            })
        (root / "characters/characters.json").write_text(
            json.dumps(characters, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        manifest = json.loads((root / "manifest.json").read_text())
        manifest["franchise"] = "mltd"
        manifest["engineFamily"] = "mltd"
        manifest["contentSetID"] = "mltd.content.3dtest.v1"
        manifest["created_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        manifest.setdefault("characters", {})
        manifest["characters"]["ids"] = ids
        manifest["characters"]["count"] = len(ids)
        manifest["characters"]["characterKeys"] = [f"mltd:{i}" for i in ids]
        manifest["files"] = manifest_files(root)
        (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
        write_zip(root, dst)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-source", required=True)
    parser.add_argument("--content-base", required=True)
    parser.add_argument("--out-model", required=True)
    parser.add_argument("--out-content", required=True)
    args = parser.parse_args()
    ids = build_model_package(Path(args.model_source), Path(args.out_model))
    build_content_package(Path(args.content_base), ids, Path(args.out_content))
    print(f"model: {args.out_model} characters={len(ids)}")
    print(f"content: {args.out_content} characters={len(ids)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
