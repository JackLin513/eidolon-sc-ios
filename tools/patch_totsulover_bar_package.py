#!/usr/bin/env python3
"""Add the Dimension Lover bar content to a totsulover content package.

The bar is one global venue: this script only adds the content-package half
(drinks, visits, lines, audio list, prompt, and each heroine's bar tastes).
It does not touch the global bar asset bundle.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import tempfile
import zipfile
from pathlib import Path

BAR_FILES = (
    "characters/bar_prompt.json",
    "characters/bar_visits.json",
    "characters/bar_lines.json",
    "characters/bar_audio.json",
    "characters/drinks.json",
)
DATA_FILES = {
    "characters/bar_prompt.json": "bar_prompt.json",
    "characters/bar_visits.json": "bar_visits.json",
    "characters/bar_lines.json": "bar_lines.json",
    "characters/bar_audio.json": "bar_audio.json",
    "characters/drinks.json": "drinks.json",
}


def _crc32(data: bytes) -> str:
    import zlib

    return f"{zlib.crc32(data) & 0xFFFFFFFF:08x}"


def _json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bar-data", type=Path, default=Path("tools/totsulover_bar"))
    args = parser.parse_args()

    if args.output.exists():
        parser.error(f"{args.output} already exists")
    if not args.input.is_file():
        parser.error(f"{args.input} is not a file")

    data: dict[str, bytes] = {}
    with zipfile.ZipFile(args.input) as archive:
        names = archive.namelist()
        for name in names:
            data[name] = archive.read(name)

    if "manifest.json" not in data or "characters/characters.json" not in data:
        parser.error("input is missing manifest.json or characters/characters.json")

    for target, source in DATA_FILES.items():
        payload = (args.bar_data / source).read_bytes()
        json.loads(payload)  # fail before writing a package with broken JSON
        data[target] = payload

    characters = json.loads(data["characters/characters.json"])
    tastes = json.loads((args.bar_data / "characters_bar.json").read_text("utf-8"))
    seen: set[str] = set()
    for character in characters:
        character_id = character.get("id")
        if character_id in tastes:
            character.update(tastes[character_id])
            seen.add(character_id)
    missing = set(tastes) - seen
    if missing:
        parser.error(f"characters_bar.json has unknown character ids: {sorted(missing)}")
    data["characters/characters.json"] = _json_bytes(characters)

    manifest = json.loads(data["manifest.json"])
    files = manifest.setdefault("files", {})
    for name, payload in data.items():
        if name == "manifest.json":
            continue
        files[name] = {"size": len(payload), "crc32": _crc32(payload)}
    manifest["created_at"] = _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    data["manifest.json"] = _json_bytes(manifest)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix=args.output.name + ".", suffix=".tmp", dir=args.output.parent, delete=False
    ) as temp:
        temp_path = Path(temp.name)
    try:
        with zipfile.ZipFile(temp_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name in names:
                if name == "manifest.json":
                    continue
                archive.writestr(name, data[name])
            for name in BAR_FILES:
                if name not in names:
                    archive.writestr(name, data[name])
            archive.writestr("manifest.json", data["manifest.json"])
        os.replace(temp_path, args.output)
    finally:
        if temp_path.exists():
            temp_path.unlink()

    print(f"wrote {args.output} ({args.output.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
