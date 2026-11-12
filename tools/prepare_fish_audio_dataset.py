#!/usr/bin/env python3
"""Prepare a local Fish Audio reference/PVC dataset from voice.pac.

This only selects and converts clips on the producer's machine; audio never enters the
repository. Use it for personal/local voice experiments only.

Example:
  python3 tools/prepare_fish_audio_dataset.py --prefix VO01 --minutes 15
"""
from __future__ import annotations

import argparse
import json
import shutil
import struct
import subprocess
from pathlib import Path

DEFAULT_PAC = Path.home() / "Developer/IdeaProjects/Galgame support/ディメンション凸ラバース!!/totsulover_dl/voice.pac"
DEFAULT_OUT = Path("build/sakura-voice")


def read_index(pac: Path):
    data = pac.read_bytes()
    if data[:4] != b"PAC ":
        raise SystemExit("not a PAC")
    count = struct.unpack_from("<I", data, 8)[0]
    entries = []
    for i in range(count):
        entry = data[0x804 + i * 0x28:0x804 + (i + 1) * 0x28]
        name = entry[:0x20].split(b"\0")[0].decode("cp932", errors="replace")
        size, offset = struct.unpack_from("<II", entry, 0x20)
        entries.append((name, data[offset:offset + size]))
    return entries


def duration(path: Path) -> float:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nk=1:nw=1", str(path)],
        capture_output=True, text=True,
    )
    try:
        return float(result.stdout.strip())
    except ValueError:
        return 0.0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pac", type=Path, default=DEFAULT_PAC)
    parser.add_argument("--prefix", default="VO01")
    parser.add_argument("--minutes", type=float, default=15)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--keep-ogg", action="store_true")
    args = parser.parse_args()
    entries = [(name, blob) for name, blob in read_index(args.pac) if name.upper().startswith(args.prefix.upper())]
    if not entries:
        raise SystemExit(f"no entries with prefix {args.prefix}")
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "wav").mkdir(exist_ok=True)
    total = 0.0
    chosen = []
    for name, blob in entries:
        if total >= args.minutes * 60:
            break
        if len(blob) < 8:
            continue
        temp = args.out / "tmp.ogg"
        temp.write_bytes(blob)
        d = duration(temp)
        if not (2.0 <= d <= 20.0):
            continue
        temp.unlink(missing_ok=True)
        target = args.out / "wav" / (name.replace("/", "_") + ".wav")
        source = args.out / (name.replace("/", "_") + ".ogg")
        source.write_bytes(blob)
        proc = subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-i", str(source), "-ac", "1", "-ar", "24000", str(target)],
            capture_output=True,
        )
        if proc.returncode != 0 or not target.exists():
            source.unlink(missing_ok=True)
            continue
        total += d
        chosen.append({"file": str(target.relative_to(args.out)), "duration": round(d, 3), "source": name})
        if not args.keep_ogg:
            source.unlink(missing_ok=True)
    (args.out / "manifest.json").write_text(
        json.dumps({"prefix": args.prefix, "minutes": round(total / 60, 2), "clips": chosen}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"{args.out}: {len(chosen)} clips, {total/60:.2f} min")
    print("Next: Fish Audio PVC needs >=10 min; upload the WAVs and use ASR or add transcripts.")


if __name__ == "__main__":
    main()
