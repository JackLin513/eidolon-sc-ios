#!/usr/bin/env python3
"""Pick a diverse, duration-bounded voice-cloning set from the game's line→voice map.

The map and audio are local-only; outputs go under build/. This does not upload or
train anything; it only selects lines and extracts/converts Ogg clips.

Example:
  python3 tools/select_voice_training.py --character sakura --out build/training-sakura
"""
from __future__ import annotations

import argparse
import collections
import json
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_MAPPING = Path("/tmp/eidolon-re-full/ida2/mapping_raw.json")
DEFAULT_INDEX = Path("/tmp/eidolon-re-full/ida2/voice_index.json")
DEFAULT_PAC = Path.home() / "Developer/IdeaProjects/Galgame support/ディメンション凸ラバース!!/totsulover_dl/voice.pac"
DEFAULT_OUT = Path("build/voice-training")

CHARACTERS = {
    "sakura": ("桜", "VO01"),
    "katan": ("華淡", "VO02"),
    "sophia": ("ソフィア", "VO03"),
    "suisen": ("水仙", "VO04"),
}
LAUGH = ("ふふ", "くす", "あは", "はは", "呵呵", "ふっ")
CRY = ("泣", "うう", "ぐす", "涙", "呜", "嗚")
WHISPER = ("小声", "ひそ", "囁", "ささや")
SHOUT = ("！", "!")


def clean(value: str) -> str:
    value = re.sub(r"<[^>]*>", "", value or "")
    value = re.sub(r"%[0-9]+", "、", value)
    value = re.sub(r"%[A-Za-z]", "", value)
    return re.sub(r"\s+", " ", value.replace("\u3000", " ")).strip()


def features(text: str, name: str | None) -> tuple[str, ...]:
    value = clean(text)
    ending = "question" if "？" in value else "exclaim" if any(x in value for x in SHOUT) else "hesitate" if "…" in value else "statement"
    length = "short" if len(value) < 18 else "medium" if len(value) < 38 else "long"
    extra = []
    if any(x in value for x in LAUGH): extra.append("laugh")
    if any(x in value for x in CRY): extra.append("cry")
    if any(x in value for x in WHISPER): extra.append("whisper")
    if name and "？" in value and "！" in value: extra.append("mixed")
    return (ending, length, *extra)


def read_pac(path: Path) -> bytes:
    data = path.read_bytes()
    if data[:4] != b"PAC ":
        raise SystemExit("not a PAC")
    return data


def extract_and_convert(pac: bytes, index: dict, voice_name: str, target: Path) -> float:
    key = voice_name if voice_name in index else voice_name + ".OGG"
    if key not in index:
        return 0.0
    offset, size = index[key]
    ogg = pac[offset:offset + size]
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(ogg)
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(target)],
        capture_output=True, text=True,
    )
    try:
        duration = float(probe.stdout.strip())
    except ValueError:
        return 0.0
    flac = target.with_suffix(".flac")
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(target), "-c:a", "flac", str(flac)], check=True)
    target.unlink(missing_ok=True)
    return duration


def choose(rows, label: str, max_files: int, max_seconds: float, pac: bytes, index: dict, scratch: Path):
    # Primary buckets are sentence type × length. Extra cues (laugh/cry/whisper) are
    # recorded on the clip but do not split the primary buckets, otherwise rare cues
    # dominate the 20-file budget and calm/statement lines disappear.
    buckets = collections.defaultdict(list)
    for row in rows:
        text = row.get("text_str") or ""
        if not text or not row.get("voice_name"):
            continue
        buckets[features(text, row.get("name_str"))[:2]].append(row)
    for bucket in buckets.values():
        bucket.sort(key=lambda r: len(clean(r.get("text_str") or "")), reverse=True)
    chosen, used, total = [], set(), 0.0

    def take(row):
        nonlocal total
        voice = row.get("voice_name")
        if voice in used or (voice not in index and voice + ".OGG" not in index):
            return False
        scratch_file = scratch / f"{label}-{len(chosen):02d}.ogg"
        duration = extract_and_convert(pac, index, voice, scratch_file)
        if duration < 2.0 or duration > 14.0 or total + duration > max_seconds:
            scratch_file.with_suffix(".flac").unlink(missing_ok=True)
            return False
        chosen.append({**row, "duration": round(duration, 3), "features": list(features(row.get("text_str") or "", row.get("name_str")))})
        used.add(voice)
        total += duration
        return True

    # One from every primary bucket first, then fill the remaining budget with the
    # longest texts across buckets (still unique voices).
    for key in sorted(buckets, key=lambda k: len(buckets[k])):
        if len(chosen) >= max_files:
            break
        for row in buckets[key]:
            if take(row):
                break
    def voice_size(row):
        voice = row.get("voice_name") or ""
        key = voice if voice in index else voice + ".OGG"
        return index[key][1] if key in index else 0

    while len(chosen) < max_files:
        candidates = [r for bucket in buckets.values() for r in bucket if r.get("voice_name") not in used]
        # Longer source Ogg usually means more prosody to learn; probe those first so
        # the 20-file / 270 s budget is actually used instead of stopping at ~150 s.
        candidates.sort(key=voice_size, reverse=True)
        if not candidates:
            break
        if not any(take(r) for r in candidates):
            break
    return chosen, total


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mapping", type=Path, default=DEFAULT_MAPPING)
    parser.add_argument("--index", type=Path, default=DEFAULT_INDEX)
    parser.add_argument("--pac", type=Path, default=DEFAULT_PAC)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--character", choices=CHARACTERS, action="append")
    parser.add_argument("--max-files", type=int, default=20)
    parser.add_argument("--max-seconds", type=float, default=265)
    args = parser.parse_args()
    characters = args.character or list(CHARACTERS)
    mapping = json.loads(args.mapping.read_text())
    index = json.loads(args.index.read_text())
    pac = read_pac(args.pac)
    args.out.mkdir(parents=True, exist_ok=True)
    for label in characters:
        name, prefix = CHARACTERS[label]
        rows = [r for r in mapping if r.get("name_str") == name and (r.get("voice_name") or "").startswith(prefix)]
        scratch = args.out / f".{label}-tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        chosen, total = choose(rows, label, args.max_files, args.max_seconds, pac, index, scratch)
        target = args.out / label
        target.mkdir(parents=True, exist_ok=True)
        for old in target.glob("*.flac"):
            old.unlink()
        manifest = []
        for i, row in enumerate(chosen, 1):
            source = scratch / f"{label}-{i - 1:02d}.flac"
            dest = target / f"{i:02d}.flac"
            if not source.exists():
                continue
            source.replace(dest)
            manifest.append({
                "file": dest.name,
                "text_id": row.get("text_id"),
                "text": row.get("text_str"),
                "voice": row.get("voice_name"),
                "duration": row.get("duration"),
                "features": row.get("features"),
            })
        (target / "manifest.json").write_text(json.dumps({
            "character": label,
            "voice_prefix": prefix,
            "files": len(manifest),
            "seconds": round(sum(x["duration"] for x in manifest), 2),
            "clips": manifest,
        }, ensure_ascii=False, indent=2), encoding="utf-8")
        scratch.rmdir()
        print(f"{label}: {len(manifest)} files, {sum(x['duration'] for x in manifest):.2f}s")


if __name__ == "__main__":
    main()
