#!/usr/bin/env python3
"""Rebuild the derived 3D workspace from the game's read-only bundle cache.

Layer 2 of the isolation plan in `docs/3d-branch-handoff-2026-11-07.md` §5: the
game install (layer 1) is only read, the repo (layer 3) holds code, and
everything derived from the game lives in `$MLTD_WORK` (default `~/mltd-work`),
which can be deleted and rebuilt with this one command.

    python3 spikes/porting-3d/prepare_work.py \
        --cache ~/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents \
        --costume ss003 --character 001har \
        --imo-bundle ~/mltd-work/assets/1078590/files/<dan_loveig_01>.unity3d         --imo-name dan_loveig_01

Steps, all idempotent (existing outputs are reused unless `--force`):

    1. index the cache by content (`index_cache.py`) unless `--index` names an
       existing index; cache files are hash-named, so content is the only key
    2. copy every bundle for that costume/idol into `$WORK/bundles`, named by the
       AssetBundle's own embedded name (`cb_ss003_001har.unity3d`, ...)
    3. export the face expression table -> `$WORK/out/facial_chara.json`
    4. export the raw CharacterImasMotionAsset -> `$WORK/motion/*.imo.json`
       (only when `--imo-bundle` is given; ADR-0033 B1 replaced the packed 30 fps
       EULR clip, so `--motion` is no longer used)
    5. write `$WORK/scene.json`, which `Assets/Editor/PlayMotion.cs` reads when it
       builds the playable scene, so no path is ever typed into the Editor by hand

Afterwards, in the Unity project:

    unity open <project>
    unity command eval 'PlayMotion.BuildAndSaveScene()'   # once, or after switching costume
    unity command eval 'PlayMotion.Play()'

Requires UnityPy (`$WORK/venv` per the handoff, or `uv run --with UnityPy`).
Read-only with respect to the game install.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def work_root(argument: str | None) -> Path:
    if argument:
        return Path(argument).expanduser().resolve()
    return Path(os.environ.get("MLTD_WORK") or (Path.home() / "mltd-work")).resolve()


def run(command: list[str], label: str) -> None:
    print(f"== {label}", flush=True)
    step = subprocess.run(command, text=True, capture_output=True)
    tail = (step.stdout or step.stderr).strip().splitlines()[-2:]
    for line in tail:
        print("   " + line, flush=True)
    if step.returncode != 0:
        raise SystemExit(f"{label} failed with exit {step.returncode}")


def ensure_index(args, work: Path) -> Path:
    """Indexing is ~10 minutes on a cold cache; reuse whatever exists."""
    if args.index:
        index = Path(args.index).expanduser().resolve()
        if not index.exists():
            raise SystemExit(f"--index does not exist: {index}")
        return index
    index = work / "mltd-index.jsonl"
    if index.exists() and not args.force:
        print(f"== 复用缓存索引 {index}（{sum(1 for _ in index.open())} 行）")
        return index
    run([sys.executable, str(HERE / "index_cache.py"),
         "--root", str(Path(args.cache).expanduser()), "--out", str(index)], "索引游戏缓存")
    return index


def matching_bundles(index: Path, costume: str, character: str) -> list[Path]:
    hits: list[Path] = []
    for line in index.read_text().splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if costume not in record.get("costumes", ()) or character not in record.get("idols", ()):
            continue
        path = Path(record["file"])
        if path.exists():
            hits.append(path)
    return hits


def embedded_name(path: Path) -> str | None:
    """The cache stores hash names; the AssetBundle carries the real one."""
    try:
        import UnityPy
    except ImportError:
        raise SystemExit(
            "UnityPy is not importable by this Python. Use the workspace venv "
            "(see handoff §1) or: uv run --with UnityPy python3 prepare_work.py ...")
    environment = UnityPy.load(str(path))
    for obj in environment.objects:
        if obj.type.name == "AssetBundle":
            name = obj.read().m_Name
            if name:
                return name
    return None


def copy_bundles(sources: list[Path], bundles: Path, force: bool) -> dict[str, Path]:
    """Copy each source bundle to $WORK/bundles under its embedded name."""
    copied: dict[str, Path] = {}
    for source in sources:
        name = embedded_name(source)
        if not name:
            print(f"   ! {source.name}: no AssetBundle name, skipped")
            continue
        target = bundles / (name if name.endswith(".unity3d") else name + ".unity3d")
        if target.exists() and not force and target.stat().st_size == source.stat().st_size:
            print(f"   = {target.name}（已存在，{target.stat().st_size} 字节）")
        else:
            shutil.copy2(source, target)
            print(f"   + {target.name} <- {source.name}（{target.stat().st_size} 字节）")
        copied[target.name] = target
    return copied


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", required=True, help="game install Documents dir (read-only)")
    parser.add_argument("--work", help="derived workspace, default $MLTD_WORK or ~/mltd-work")
    parser.add_argument("--costume", required=True, help="costume code, e.g. ss003")
    parser.add_argument("--character", required=True, help="idol code, e.g. 001har")
    parser.add_argument("--index", help="reuse an existing mltd-index*.jsonl instead of rescanning")
    parser.add_argument("--imo-bundle", help="bundle (or dir) containing CharacterImasMotionAsset; exported to $WORK/motion")
    parser.add_argument("--imo-name", help="only export bundles whose file name contains this")
    parser.add_argument("--optional-imo-bundle", help="optional-imo bundle (kind=optional) exported alongside")
    parser.add_argument("--soul-bundle", default="", help="chara_soul.unity3d path written into scene.json")
    parser.add_argument("--shadow-bundle", default="", help="chara_shadow.unity3d path written into scene.json")
    parser.add_argument("--motion", help="DEPRECATED: packed EULR clip; use --imo-bundle (ADR-0033 B1)")
    parser.add_argument("--start", type=int, default=0, help="deprecated (EULR path only)")
    parser.add_argument("--frames", type=int, default=0, help="deprecated (EULR path only)")
    parser.add_argument("--skip-facial", action="store_true", help="do not export facial_chara.json")
    parser.add_argument("--force", action="store_true", help="recreate existing outputs")
    args = parser.parse_args(argv)

    cache = Path(args.cache).expanduser()
    if not cache.is_dir():
        raise SystemExit(f"game cache not found: {cache}")
    work = work_root(args.work)
    bundles = work / "bundles"
    out = work / "out"
    for directory in (work, bundles, out):
        directory.mkdir(parents=True, exist_ok=True)

    index = ensure_index(args, work)
    sources = matching_bundles(index, args.costume, args.character)
    if not sources:
        raise SystemExit(f"index has no bundle for costume={args.costume} character={args.character}")

    print(f"== 复制 {args.costume}_{args.character} 的 {len(sources)} 个 bundle -> {bundles}")
    copied = copy_bundles(sources, bundles, args.force)
    body = next((n for n in copied if n.startswith("cb_")), None)
    head = next((n for n in copied if n.startswith("ch_")), None)
    if body is None or head is None:
        raise SystemExit(f"expected cb_/ch_ bundles, got: {sorted(copied)}")

    facial = out / "facial_chara.json"
    if args.skip_facial:
        print("== 跳过表情表")
    elif facial.exists() and not args.force:
        print(f"== 复用表情表 {facial}")
    else:
        run([sys.executable, str(HERE / "extract_facial_params.py"),
             "--cache", str(cache), "--output", str(facial)], "导出表情表")

    if args.motion:
        raise SystemExit("--motion（EULR 30fps）已被 ADR-0033 B1 废弃；请改用 --imo-bundle 导出原始 imo")

    motion_dir = work / "motion"
    imo_file = ""
    optional_imo_file = ""
    if args.imo_bundle:
        motion_dir.mkdir(parents=True, exist_ok=True)
        if args.force:
            for stale in motion_dir.glob("*.imo.json"):
                stale.unlink()
        export = [sys.executable, str(HERE / "export_imo.py"),
                  "--bundle", str(Path(args.imo_bundle).expanduser()),
                  "--out", str(motion_dir)]
        if args.imo_name:
            export += ["--name", args.imo_name]
        run(export, "导出原始 imo")
        for json_path in sorted(motion_dir.glob("*.imo.json")):
            try:
                meta = json.loads(json_path.read_text())
            except ValueError:
                continue
            kind = meta.get("kind", "")
            if kind == "optional" and not optional_imo_file:
                optional_imo_file = json_path.name
            elif kind != "optional" and not imo_file:
                imo_file = json_path.name
        if not imo_file:
            raise SystemExit(f"export_imo 没有在 {motion_dir} 里产出可用的 imo JSON")
        print(f"== 原始 imo: {imo_file}" + (f"（optional: {optional_imo_file}）" if optional_imo_file else ""))
    else:
        print("== 没有 --imo-bundle，跳过原始动作（Unity 里会保持静止姿势）")

    scene = {
        "bundleDirectory": str(bundles),
        "bodyBundle": body,
        "headBundle": head,
        "facialParamsPath": str(facial) if facial.exists() else "",
        "motionDirectory": str(motion_dir),
        "imoFile": imo_file,
        "optionalImoFile": optional_imo_file,
        "characterSoulBundle": args.soul_bundle,
        "shadowBundlePath": args.shadow_bundle,
    }
    (work / "scene.json").write_text(json.dumps(scene, ensure_ascii=False, indent=2) + "\n")
    print(f"== 写入 {work / 'scene.json'}")
    print(json.dumps(scene, ensure_ascii=False, indent=2))
    print("\n接着在 Unity 里：")
    print("  unity command eval 'PlayMotion.BuildAndSaveScene()'   # 首次/换衣装")
    print("  unity command eval 'PlayMotion.Play()'")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
