#!/usr/bin/env python3
"""Build the app's 3D-stand content directory from the game's own assets.

The iOS app embeds a Unity runtime (ADR-0034). That runtime needs, per MLTD idol:

* the costume bundles the game itself ships (``cb_<outfit>_<idol>`` body and
  ``ch_<outfit>_<idol>`` head) — 常服 ``pr001`` and 演出服 ``ss003`` for now;
* the shared native tables (facial expression table, ``chara_soul``,
  ``chara_shadow``);
* the day-motion state clips (``act/lop/yes/noo/str/swt/end``) decoded from the
  game's own streamed AnimationClips at the native 60 fps grid and written as
  flat TSV, which the Unity stand player reads without a JSON parser;
* a small ``emotion-map.json`` (seven app emotions → MLTD ``facialMenu`` index).

Everything is derived from the version-pinned asset manifest and the
license-free-to-derive local decode pipeline in ``spikes/porting-3d``. Nothing
produced here is committed: the output defaults to ``build/unity3d-content``
which ``.gitignore`` already covers.

Usage
-----
    ~/mltd-work/venv/bin/python tools/fetch_unity3d_content.py
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SPIKE = REPO / "spikes" / "porting-3d"
DEFAULT_WORK = Path(os.path.expanduser("~/mltd-work"))
DEFAULT_SERVER = "http://192.168.0.6:2830"
DEFAULT_TOKEN_FILE = Path("/tmp/mltd-token.txt")
OUTFITS = ("pr001", "ss003")
ACTIONS = ("act", "lop", "yes", "noo", "str", "swt", "end")

# 28 facialMenu entries, in native index order (spike migration-progress.md).
FACIAL_MENU = (
    "通常", "明るい", "興味", "安堵", "照れる", "微笑み", "泣き笑い", "困り笑い",
    "真剣", "不敵な笑い", "企み", "考える", "きょとん", "驚き", "超驚き", "呆れ",
    "不機嫌", "怒り", "不安", "哀しみ", "泣き", "痛い", "拗ねる", "嫌そう",
    "つまらない", "がっかり", "右ウィンク", "左ウィンク",
)

# StandEmotion (app) → (facialMenu index, name, cheek level, lip style).
EMOTION_MAP = {
    "calm": {"face": 0, "name": "通常", "cheek": 0, "lip": "calm"},
    "happy": {"face": 5, "name": "微笑み", "cheek": 0, "lip": "happy"},
    "shy": {"face": 4, "name": "照れる", "cheek": 2, "lip": "shy"},
    "surprised": {"face": 13, "name": "驚き", "cheek": 0, "lip": "surprised"},
    "sad": {"face": 19, "name": "哀しみ", "cheek": 0, "lip": "sad"},
    "angry": {"face": 17, "name": "怒り", "cheek": 0, "lip": "angry"},
    "thinking": {"face": 11, "name": "考える", "cheek": 0, "lip": "thinking"},
}


def log(message: str) -> None:
    print(f"[content] {message}", flush=True)


def load_names(manifest: Path) -> dict[str, tuple[str, str, int]]:
    """asset name → (sha1, cdn file name, size)."""
    import msgpack

    raw = msgpack.unpackb(manifest.read_bytes(), raw=False)
    names: dict[str, tuple[str, str, int]] = {}
    for record in raw:
        for name, info in record.items():
            if isinstance(info, list) and len(info) >= 3:
                names[name] = (str(info[0]), str(info[1]), int(info[2]))
    if not names:
        raise SystemExit(f"{manifest}: no asset names")
    return names


def token(args: argparse.Namespace) -> str:
    value = args.token or os.environ.get("EIDOLON_ASSET_TOKEN")
    if not value and DEFAULT_TOKEN_FILE.exists():
        value = DEFAULT_TOKEN_FILE.read_text().strip()
    if not value:
        raise SystemExit("no asset-server token: pass --token or EIDOLON_ASSET_TOKEN")
    return value


def download(
    name: str,
    dest: Path,
    args: argparse.Namespace,
    names: dict[str, tuple[str, str, int]],
    auth: str,
) -> bool:
    """Fetch one bundle unless it is already cached with the expected size."""
    if name not in names:
        return False
    _sha1, _cdn, size = names[name]
    if dest.exists() and dest.stat().st_size == size:
        return False
    if args.dry_run:
        log(f"would download {name} ({size} B)")
        return False
    dest.parent.mkdir(parents=True, exist_ok=True)
    url = f"{args.server}/v1/assets/{name}"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {auth}"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                payload = response.read()
            break
        except (urllib.error.URLError, TimeoutError) as error:
            if attempt == 2:
                log(f"FAILED {name}: {error}")
                return False
            time.sleep(1 + attempt)
    if size and len(payload) != size:
        log(f"size mismatch {name}: got {len(payload)} want {size}")
    dest.write_bytes(payload)
    return True


def find_local(work: Path, name: str) -> Path | None:
    """Reuse bundles that the spike already downloaded."""
    for directory in (
        work / "chranim-com",
        work / "chranim-scene",
        work / "characters",
        work / "bundles",
        work / "assets",
    ):
        if not directory.is_dir():
            continue
        candidate = directory / name
        if candidate.is_file():
            return candidate
    if (work / "assets").is_dir():
        for candidate in (work / "assets").rglob(name):
            if candidate.is_file():
                return candidate
    return None


def obtain(
    work: Path,
    out: Path,
    name: str,
    relative: str,
    args: argparse.Namespace,
    names: dict[str, tuple[str, str, int]],
    auth: str,
) -> Path | None:
    dest = out / relative
    local = find_local(work, name)
    if local is not None:
        if not args.dry_run:
            dest.parent.mkdir(parents=True, exist_ok=True)
            if not dest.exists() or dest.stat().st_size != local.stat().st_size:
                shutil.copyfile(local, dest)
        return dest
    if download(name, dest, args, names, auth):
        return dest
    return dest if dest.exists() else None


def character_ids(names: dict[str, tuple[str, str, int]]) -> list[str]:
    pattern = re.compile(r"^cb_pr001_([0-9]{3}[a-z]{3})\.unity3d$")
    ids = sorted({m.group(1) for name in names if (m := pattern.match(name))})
    return ids


def motion_index(work: Path) -> dict[str, dict]:
    path = work / "motion-daily-merged" / "index.json"
    if not path.exists():
        raise SystemExit(f"{path}: missing merged motion index (run export_daily_motions.py)")
    data = json.loads(path.read_text())
    return {row["character"]: row for row in data.get("characters", [])}


def emit_flat(work: Path, out: Path, char: str, action: str, entry: dict, args: argparse.Namespace) -> bool:
    """Decode one game clip at 60 fps and write the flat TSV the runtime reads."""
    sys.path.insert(0, str(SPIKE))
    import motion as motion_module  # noqa: PLC0415
    import photo_pose  # noqa: PLC0415
    import export_daily_motions  # noqa: PLC0415

    dest = out / "motions" / char / f"{action}.tsv"
    if dest.exists() and dest.stat().st_size > 0 and not args.force:
        return True
    clip_name = entry.get("clip")
    pack = entry.get("pack")
    if not clip_name or not pack:
        return False
    local = find_local(work, pack)
    if local is None:
        log(f"{char}/{action}: bundle {pack} not available locally; skipping")
        return False
    if args.dry_run:
        log(f"would decode {char}/{action} from {pack}")
        return True
    try:
        clips = photo_pose.load_bundle(local)
    except Exception as error:  # noqa: BLE001 - one broken bundle must not stop the run
        log(f"{char}/{action}: cannot open {pack}: {error}")
        return False
    selected = [clip for clip in clips if clip.name == clip_name]
    if not selected:
        log(f"{char}/{action}: clip {clip_name} not in {pack}")
        return False
    asset = photo_pose.to_motion_asset(selected[0])
    packed = motion_module.build_motion(asset, fps=args.fps)
    dest.parent.mkdir(parents=True, exist_ok=True)
    export_daily_motions.write_flat(dest, packed)
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--work", type=Path, default=DEFAULT_WORK)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_WORK / "asset-manifest" / "manifest.msgpack")
    parser.add_argument("--out", type=Path, default=REPO / "build" / "Unity3DContent")
    parser.add_argument("--server", default=os.environ.get("EIDOLON_ASSET_SERVER", DEFAULT_SERVER))
    parser.add_argument("--token", default="")
    parser.add_argument("--fps", type=int, default=60)
    parser.add_argument("--only", default="", help="comma separated character ids (debug)")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    if not args.manifest.exists():
        raise SystemExit(f"{args.manifest}: missing asset manifest")
    names = load_names(args.manifest)
    auth = "" if args.dry_run else token(args)
    log(f"{len(names)} asset names in manifest; output {args.out}")

    index = motion_index(args.work)
    ids = character_ids(names)
    if args.only:
        wanted = {piece.strip() for piece in args.only.split(",") if piece.strip()}
        ids = [character for character in ids if character in wanted]
    log(f"{len(ids)} idols: {ids[0]} … {ids[-1]}")

    characters = []
    downloads = 0
    for number, character in enumerate(ids, 1):
        row = index.get(character, {})
        family = row.get("family") or ""
        body_bundles: dict[str, dict[str, str | None]] = {}
        for outfit in OUTFITS:
            cb_name = f"cb_{outfit}_{character}.unity3d"
            ch_name = f"ch_{outfit}_{character}.unity3d"
            if ch_name not in names:
                ch_name = f"ch_pr001_{character}.unity3d"
            if cb_name not in names:
                body_bundles[outfit] = {"cb": None, "ch": None}
                continue
            before = sum(1 for path in args.out.rglob("*.unity3d")) if args.out.exists() else 0
            cb_path = obtain(args.work, args.out, cb_name, f"models/{character}/{outfit}/cb_{outfit}_{character}.unity3d", args, names, auth)
            ch_path = None
            if ch_name in names:
                ch_path = obtain(args.work, args.out, ch_name, f"models/{character}/{outfit}/ch_{outfit}_{character}.unity3d", args, names, auth)
            after = sum(1 for path in args.out.rglob("*.unity3d")) if args.out.exists() else 0
            downloads += max(0, after - before)
            body_bundles[outfit] = {
                "cb": None if cb_path is None else f"models/{character}/{outfit}/cb_{outfit}_{character}.unity3d",
                "ch": None if ch_path is None else f"models/{character}/{outfit}/ch_{outfit}_{character}.unity3d",
            }
        motions: dict[str, str | None] = {}
        for action in ACTIONS:
            entry = (row.get("actions") or {}).get(action)
            if not entry:
                motions[action] = None
                continue
            ok = emit_flat(args.work, args.out, character, action, entry, args)
            motions[action] = f"motions/{character}/{action}.tsv" if ok else None
        characters.append({
            "id": character,
            "family": family,
            "category": row.get("category"),
            "outfits": body_bundles,
            "motions": motions,
            "avatar": None,
        })
        log(f"[{number}/{len(ids)}] {character} family={family or '?'} "
            f"bundles={sum(1 for outfit in body_bundles.values() for value in outfit.values() if value)} "
            f"motions={sum(1 for value in motions.values() if value)}")

    shared: dict[str, str | None] = {"facial_chara": None, "chara_soul": None, "chara_shadow": None}
    for name, relative in (
        ("facial_chara.json", "shared/facial_chara.json"),
        ("chara_soul.unity3d", "shared/chara_soul.unity3d"),
        ("chara_shadow.unity3d", "shared/chara_shadow.unity3d"),
    ):
        local = find_local(args.work, name)
        dest = args.out / relative
        if local is not None:
            if not args.dry_run:
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(local, dest)
            shared[relative.split("/")[-1].split(".")[0]] = relative
            continue
        if name in names:
            if obtain(args.work, args.out, name, relative, args, names, auth):
                shared[relative.split("/")[-1].split(".")[0]] = relative
    if shared["facial_chara"] is None:
        # The decoded expression table can be produced by the spike tools; accept it
        # from the work directory when the bundle itself is not cached here.
        local_json = args.work / "out" / "facial_chara.json"
        if local_json.exists():
            if not args.dry_run:
                (args.out / "shared").mkdir(parents=True, exist_ok=True)
                shutil.copyfile(local_json, args.out / "shared" / "facial_chara.json")
            shared["facial_chara"] = "shared/facial_chara.json"

    emotion_map = {
        "format": "eidolon.emotion-map/1",
        "facial_menu": list(FACIAL_MENU),
        "emotions": EMOTION_MAP,
        "nod": {"yes": "yes", "no": "noo"},
        "blink": {"min_interval": 3.2, "max_interval": 6.0},
        "speaking": {"lip_cycle": ["A", "I", "U", "E", "O"], "frames_per_lip": 4},
        "idle": {"action": "act", "loop": True},
    }
    if not args.dry_run:
        (args.out / "shared").mkdir(parents=True, exist_ok=True)
        (args.out / "emotion-map.json").write_text(json.dumps(emotion_map, ensure_ascii=False, indent=2))

    manifest = {
        "format": "eidolon.unity3d-content/1",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "fps": args.fps,
        "outfits": list(OUTFITS),
        "characters": characters,
        "shared": shared,
        "emotion_map": "emotion-map.json",
    }
    if not args.dry_run:
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
        total = sum(path.stat().st_size for path in args.out.rglob("*") if path.is_file())
        log(f"done: characters={len(characters)} downloads={downloads} "
            f"bundle_files={sum(1 for _ in args.out.rglob('*.unity3d'))} "
            f"motions={sum(1 for _ in args.out.rglob('*.tsv'))} total={total / 1e6:.1f} MB")
    else:
        log(f"dry run: {len(characters)} characters")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
