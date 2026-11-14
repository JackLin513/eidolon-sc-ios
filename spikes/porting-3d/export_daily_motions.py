#!/usr/bin/env python3
"""Build the per-character "daily action" library from the game's own data.

Background
----------
MLTD ships the daily/commu actions in **two** layers, and which one carries a
given character's motion changed over the game's life:

1. **Per-idol clips** in `chr_anim_com_<idol>.unity3d`:
   `com_<idol>_<age>_<action>` (`18y`, `18a`, ...). Haruka has all seven
   (`act/noo/yes/str/swt/lop/end`); most other characters only ship a subset in
   this version (often just `act`, or `act/end/lop/noo/str/yes`).

2. **Commu pose sets** in `chr_anim_com_<cat>_<variant>_<pose>.unity3d`:
   clip `com_<cat>_<pose><variant>_<action>`. `<cat>` is the first three letters
   of the character's category from the shipped master data
   `chara_commu_pose_set` (Cute→`cut`, Cool→`col`, Passion→`pas`), `<pose>` is
   a pose-set id (02, 03, ... 114), and `<variant>` is the per-character letter
   that master table gives for that pose id. Reaction sets carry
   `noo/yes/str/lop/end`, "act" sets carry `act/swt`.
   The game-cache inventory (`cache_anims.jsonl`, from a scan of the running
   game's Cache00) contains exactly the packs this table predicts — that is the
   evidence that these are the packs the game actually loads.

The merge below prefers the per-idol clip when it exists (that is what we
decoded from the current CDN for Haruka etc.) and fills the rest from the
pose-set mapping, so every character ends up with all seven actions.

Inputs (all outside the repo, in `$MLTD_WORK`):
  motion-daily/index.json          decoded per-idol clips (photo_pose.py output)
  motion-scene/<clip>.motion.json  decoded pose-set clips
  chara_commu_pose_set.json        master data (TextAsset unpacked as JSON)
  cache_anims.jsonl                cache scan: {"file":..., "clips":[names]}
  asset-manifest/manifest.msgpack  asset name list (body/head bundle names)

Outputs (in `$MLTD_WORK/motion-daily-merged`):
  <idol>_<action>.motion.json      `eidolon.motion/1`, per character/action
  index.json                       provenance: native vs commu, pack, clip, column
  flat/<idol>_<action>.txt         30fps TSV (quaternion in every frame) for Unity
  flat/catalog.tsv                 idol / action / body bundle / head bundle / category

Usage:
  $V spikes/porting-3d/export_daily_motions.py
  $V spikes/porting-3d/export_daily_motions.py --work ~/mltd-work
"""

from __future__ import annotations

import argparse
import collections
import glob
import json
import math
import os
import re
import shutil
import sys
from pathlib import Path

ACTIONS = ["act", "noo", "yes", "str", "swt", "lop", "end"]
REACTIONS = ["noo", "yes", "str", "lop", "end"]
ACT_SET = ["act", "swt"]
CATEGORY_FAMILY = {"Cute": "cut", "Cool": "col", "Passion": "pas"}
NATIVE_RE = re.compile(r"^com_(\d{3}[a-z]{3})_(\d+[a-z])_(act|noo|yes|str|swt|lop|end)$")
POSE_RE = re.compile(r"^com_(cut|col|pas|sit)_([0-9]{2,3})([a-z])_([a-z]+)$")
COLUMN_RE = re.compile(r"^([ap])(\d+)$")


def load_cache_inventory(path: Path) -> dict[tuple[str, str, str], set[str]]:
    """(family, variant, pose id) -> set(actions) observed in the game cache."""
    inventory: dict[tuple[str, str, str], set[str]] = collections.defaultdict(set)
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        for name in json.loads(line)["clips"]:
            match = POSE_RE.match(name)
            if match:
                inventory[(match.group(1), match.group(3), match.group(2))].add(match.group(4))
    return inventory


def load_native(motion_daily: Path) -> dict[str, dict[str, dict]]:
    """char -> action -> {age, file}; prefers the 18y variant when it exists."""
    index = json.loads((motion_daily / "index.json").read_text())
    native: dict[str, dict[str, dict]] = collections.defaultdict(dict)
    for entry in index["entries"]:
        if entry["bones"] == 0:
            continue
        match = NATIVE_RE.match(entry["name"])
        if not match:
            continue
        char, age, action = match.groups()
        current = native[char].get(action)
        if current is None or (age == "18y" and current["age"] != "18y"):
            native[char][action] = {"age": age, "file": entry["file"], "pack": entry.get("source_bundle")}
    return native


def pick_pose_set(row: list[str], columns: list[str], family: str, inventory, wanted: list[str]):
    """Lowest pose id whose per-character variant pack carries every wanted action."""
    candidates = []
    for i, column in enumerate(columns):
        if i < 2:
            continue
        match = COLUMN_RE.match(column)
        if not match:
            continue
        pose = match.group(2)
        variant = row[i]
        if variant not in "abcd":
            continue
        actions = inventory.get((family, variant, pose))
        if actions and set(wanted) <= actions:
            candidates.append((int(pose), column, variant, pose))
    candidates.sort()
    return candidates[0] if candidates else None


def load_asset_names(manifest_path: Path) -> set[str]:
    import msgpack

    raw = msgpack.unpackb(manifest_path.read_bytes(), raw=False)
    names: set[str] = set()
    for record in raw:
        names.update(record.keys())
    return names


def body_head_bundles(char: str, names: set[str]) -> tuple[str, str]:
    body = f"cb_pr001_{char}.unity3d"
    head = f"ch_pr001_{char}.unity3d"
    if body not in names:
        fallback = sorted(n for n in names if n.startswith("cb_ss001_") and n.endswith(f"_{char}.unity3d"))
        body = fallback[0] if fallback else ""
    if head not in names:
        fallback = sorted(n for n in names if n.startswith("ch_ss001_") and n.endswith(f"_{char}.unity3d"))
        head = fallback[0] if fallback else ""
    return body, head


# ---------------------------------------------------------------------------
# Unity helper: 30 fps TSV with quaternions precomputed (Euler ZXY like Unity)
# ---------------------------------------------------------------------------


def unpack_channel(channel, frames: int) -> list[float]:
    if isinstance(channel, int):
        return [channel] * frames
    total = channel[0]
    values = [total]
    for delta in channel[1:]:
        total += delta
        values.append(total)
    return values[:frames]


def euler_to_quaternion(x: float, y: float, z: float) -> tuple[float, float, float, float]:
    """Unity's Quaternion.Euler: rotate around Z, then X, then Y."""
    rx, ry, rz = math.radians(x) / 2, math.radians(y) / 2, math.radians(z) / 2
    qx = (math.sin(rx), 0.0, 0.0, math.cos(rx))
    qy = (0.0, math.sin(ry), 0.0, math.cos(ry))
    qz = (0.0, 0.0, math.sin(rz), math.cos(rz))

    def mul(a, b):
        ax, ay, az, aw = a
        bx, by, bz, bw = b
        return (
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz,
        )

    return mul(qy, mul(qx, qz))


def write_flat(path: Path, motion: dict) -> None:
    frames = motion["frames"]
    fps = motion["fps"]
    angle_scale = motion["angle_scale"]
    position_scale = motion["position_scale"]
    lines = [f"fps\t{fps}", f"frames\t{frames}"]
    for bone in motion["bones"]:
        path_name = bone["path"]
        if not path_name:
            continue
        rotation = bone.get("rot")
        if rotation is not None:
            xs = unpack_channel(rotation[0], frames)
            ys = unpack_channel(rotation[1], frames)
            zs = unpack_channel(rotation[2], frames)
            for frame in range(frames):
                q = euler_to_quaternion(xs[frame] / angle_scale, ys[frame] / angle_scale, zs[frame] / angle_scale)
                lines.append(
                    f"R\t{path_name}\t{frame}\t{q[0]:.6f}\t{q[1]:.6f}\t{q[2]:.6f}\t{q[3]:.6f}"
                )
        position = bone.get("pos")
        if position is not None and any(not isinstance(position[axis], int) for axis in range(3)):
            px = unpack_channel(position[0], frames)
            py = unpack_channel(position[1], frames)
            pz = unpack_channel(position[2], frames)
            for frame in range(frames):
                lines.append(
                    f"P\t{path_name}\t{frame}\t{px[frame]/position_scale:.6f}\t"
                    f"{py[frame]/position_scale:.6f}\t{pz[frame]/position_scale:.6f}"
                )
    path.write_text("\n".join(lines))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--work", type=Path, default=Path(os.path.expanduser("~/mltd-work")))
    args = parser.parse_args(argv)
    work = args.work

    motion_daily = work / "motion-daily"
    motion_scene = work / "motion-scene"
    out = work / "motion-daily-merged"
    flat = out / "flat"
    flat.mkdir(parents=True, exist_ok=True)
    for stale in out.glob("*.motion.json"):
        stale.unlink()

    pose_master = json.loads((work / "chara_commu_pose_set.json").read_text())
    columns = pose_master["sets"]["means"]
    rows = {row["vals"][0]: row["vals"] for row in pose_master["sets"]["sets"]}
    assigns = [row["vals"] for row in pose_master["assigns"]["assigns"]]
    inventory = load_cache_inventory(work / "cache_anims.jsonl")
    native = load_native(motion_daily)
    names = load_asset_names(work / "asset-manifest/manifest.msgpack")

    index = []
    missing: list[tuple] = []
    origins = collections.Counter()
    for char, stand_set, _sit_set in assigns:
        row = rows.get(stand_set)
        if row is None:
            missing.append((char, "no pose-set row"))
            continue
        family = CATEGORY_FAMILY.get(row[1])
        if family is None:
            missing.append((char, f"unknown category {row[1]}"))
            continue
        reaction = pick_pose_set(row, columns, family, inventory, REACTIONS)
        act_set = pick_pose_set(row, columns, family, inventory, ACT_SET)
        if reaction is None or act_set is None:
            missing.append((char, "no complete pose-set packs"))
            continue
        body, head = body_head_bundles(char, names)
        entry = {
            "character": char,
            "set": stand_set,
            "category": row[1],
            "family": family,
            "body_bundle": body,
            "head_bundle": head,
            "actions": {},
        }
        for action in ACTIONS:
            donor = native.get(char, {}).get(action)
            if donor is not None:
                source = motion_daily / donor["file"]
                if source.exists():
                    target = out / f"{char}_{action}.motion.json"
                    shutil.copyfile(source, target)
                    entry["actions"][action] = {
                        "file": target.name,
                        "origin": "native",
                        "clip": f"com_{char}_{donor['age']}_{action}",
                        "age": donor["age"],
                        "pack": donor.get("pack"),
                    }
                    origins["native"] += 1
                    continue
            pose = reaction if action in REACTIONS else act_set
            _priority, column, variant, pose_id = pose
            clip = f"com_{family}_{pose_id}{variant}_{action}"
            source = motion_scene / f"{clip}.motion.json"
            if not source.exists():
                missing.append((char, action, clip))
                continue
            target = out / f"{char}_{action}.motion.json"
            shutil.copyfile(source, target)
            entry["actions"][action] = {
                "file": target.name,
                "origin": "commu",
                "clip": clip,
                "column": column,
                "pack": f"chr_anim_com_{family}_{variant}_{pose_id}.unity3d",
            }
            origins["commu"] += 1
        index.append(entry)

    (out / "index.json").write_text(
        json.dumps(
            {"format": "eidolon.daily-motion/3", "count": len(index), "actions": ACTIONS, "characters": index},
            ensure_ascii=False,
            indent=1,
        )
    )

    # Flat TSV for the Unity browser (Unity has no JSON parser here).
    catalog = []
    for entry in index:
        for action in ACTIONS:
            info = entry["actions"].get(action)
            if info is None:
                continue
            motion = json.loads((out / info["file"]).read_text())
            write_flat(flat / f"{entry['character']}_{action}.txt", motion)
            catalog.append((entry["character"], action, entry["body_bundle"], entry["head_bundle"], entry["category"]))
    (flat / "catalog.tsv").write_text("\n".join("\t".join(row) for row in catalog))

    print(
        f"characters={len(index)} actions={sum(len(e['actions']) for e in index)} "
        f"native={origins['native']} commu={origins['commu']} missing={len(missing)}"
    )
    for item in missing[:10]:
        print("  MISSING", item)
    incomplete = [e["character"] for e in index if len(e["actions"]) != len(ACTIONS)]
    if incomplete:
        print("chars with incomplete actions:", incomplete)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
