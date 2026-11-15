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
import hashlib
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


def model3d_files(root: Path) -> list[dict[str, object]]:
    """`Model3DFile` shape: a list of {path, sha256, size} (not the content bundle's map)."""
    files: list[dict[str, object]] = []
    for item in sorted(root.rglob("*")):
        if not item.is_file():
            continue
        rel = item.relative_to(root).as_posix()
        if rel == "manifest.json":
            continue
        data = item.read_bytes()
        files.append({
            "path": rel,
            "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data),
        })
    return files


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


def build_model_package(src: Path, dst: Path, motions_dir: Path | None = None) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        read_zip(src, root)
        manifest = json.loads((root / "manifest.json").read_text())
        seen: set[str] = set()
        characters = []
        dropped: list[str] = []
        for character in manifest["characters"]:
            local_id = character["localID"]
            if local_id == "haruka3d" or local_id in seen:
                continue
            seen.add(local_id)
            # A localID the game never renders as a stand (no `ch_*` head bundle in
            # any outfit) cannot be displayed and has no `chr_anim`/`com_` motion.
            # The only such entry in the old package was `052tmg`: it is NOT a
            # CharacterID (the game enum stops at C051tmg=54 / C052kao=55), it only
            # owns `cb_pr001_052tmg.unity3d`, and that mesh is byte-identical to
            # `cb_pr001_052kao.unity3d` — a stale duplicate of 052kao's 常服 body.
            # Drop such ids instead of shipping a character that can never load.
            outfit_dirs = [root / "models" / local_id / outfit for outfit in character.get("outfits", [])]
            if not any(outfit.is_dir() and any(outfit.glob("ch_*.unity3d")) for outfit in outfit_dirs):
                dropped.append(local_id)
                for outfit in outfit_dirs:
                    if outfit.is_dir():
                        shutil.rmtree(outfit)
                if (root / "models" / local_id).is_dir():
                    shutil.rmtree(root / "models" / local_id)
                continue
            characters.append(character)
        if dropped:
            print(f"dropped card-only characters: {', '.join(sorted(dropped))}")
        manifest["characters"] = characters
        if motions_dir is not None:
            merge_motions(root, motions_dir, [c["localID"] for c in characters])
        manifest["franchise"] = "mltd"
        manifest["contentSetID"] = "mltd.model3d.v1"
        manifest["created_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        manifest["files"] = model3d_files(root)
        (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
        write_zip(root, dst)
    return [c["localID"] for c in characters]


def merge_motions(root: Path, motions_dir: Path, ids: list[str]) -> None:
    """Replace the package's motions with a freshly decoded daily set plus its catalog."""
    target = root / "motions"
    if target.exists():
        shutil.rmtree(target)
    source = motions_dir / "motions"
    catalog_source = source / "catalog.json"
    catalog = json.loads(catalog_source.read_text()) if catalog_source.exists() else None
    kept: dict[str, dict] = {}
    for local_id in ids:
        character_dir = source / local_id
        if not character_dir.is_dir():
            continue
        destination = target / local_id
        destination.mkdir(parents=True, exist_ok=True)
        for item in sorted(character_dir.glob("*.tsv")):
            shutil.copyfile(item, destination / item.name)
        if catalog is not None and local_id in catalog.get("characters", {}):
            kept[local_id] = catalog["characters"][local_id]
    if catalog is not None:
        target.mkdir(parents=True, exist_ok=True)
        catalog["characters"] = kept
        (target / "catalog.json").write_text(
            json.dumps(catalog, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    print(f"motions: {len(kept)} characters, "
          f"{sum(len(c['actions']) for c in kept.values())} actions")


def normalize_places(root: Path, ids: list[str]) -> None:
    """The test content shell inherits SC places whose idol lists name SC ids.

    The app validates every place idol against the roster, so remap the survivors to
    real MLTD ids instead of shipping a package that cannot import.
    """
    path = root / "characters" / "places.json"
    if not path.exists():
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return
    known = set(ids)
    changed = False
    for place in data.get("places", []):
        idols = [idol for idol in place.get("idols", []) if idol in known]
        if not idols:
            idols = [ids[0]]
        if idols != place.get("idols"):
            place["idols"] = idols
            changed = True
    if changed:
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


# Real Fish Audio reference ids already used by the Totsu-lover import tooling.
DEMO_VOICES = (
    "f55813e84ce44a6ea13a592a112458a7",
    "6123d976c0044789be9b6b79772723f0",
    "e8f7da8d0760440195fd812dcb3a7737",
    "2dab8607f82a4c8187d740c9583d21fb",
)


def build_content_package(base: Path, ids: list[str], dst: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        read_zip(base, root)
        old_sheet = root / "characters/sheets/sakura.md"
        if old_sheet.exists():
            old_sheet.unlink()
        characters = []
        for index, local_id in enumerate(ids):
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
                # The call page refuses a character without a voice (`CallSession`
                # throws "没有音色"). MLTD's own Fish voices are not mapped yet, so the
                # prototype borrows real Fish reference ids from the Totsu-lover pack.
                "voice_id": DEMO_VOICES[index % len(DEMO_VOICES)],
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
        normalize_places(root, ids)
        manifest["files"] = manifest_files(root)
        (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
        write_zip(root, dst)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-source", required=True)
    parser.add_argument("--content-base", required=True)
    parser.add_argument("--out-model", required=True)
    parser.add_argument("--out-content", required=True)
    parser.add_argument("--motions-dir", type=Path, default=None,
                        help="output of fetch_unity3d_content.py --motions-only")
    args = parser.parse_args()
    ids = build_model_package(Path(args.model_source), Path(args.out_model), args.motions_dir)
    build_content_package(Path(args.content_base), ids, Path(args.out_content))
    print(f"model: {args.out_model} characters={len(ids)}")
    print(f"content: {args.out_content} characters={len(ids)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
