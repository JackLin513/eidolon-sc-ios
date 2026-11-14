#!/usr/bin/env python3
"""Give Sakura a canonical school-uniform tag set in the content package.

The photo prompt lets the roleplay model write the `outfit:` tags. For a school
uniform that is too loose: it can turn "black trim" into a black jacket. This
script adds the pack's canonical uniform tags and states them unambiguously in
her sheet. Other outfits are still written by the model.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import tempfile
import zipfile
import zlib
from pathlib import Path

UNIFORM = "white jacket, white shirt, dark blue collar, blue bow, blue skirt, yellow necktie"
OLD_SHEET = "她穿着以白色为主的学园制服，搭配黑色外套边饰、蓝色装饰、青蓝色裙摆和黄色领带"
NEW_SHEET = "她穿着以白色为主的长外套学园制服，配深蓝色领口、蓝色胸前蝴蝶结、青蓝色百褶裙和黄色领带"


def _crc32(data: bytes) -> str:
    return f"{zlib.crc32(data) & 0xFFFFFFFF:08x}"


def _json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error(f"{args.output} already exists")
    if not args.input.is_file():
        parser.error(f"{args.input} is not a file")

    with zipfile.ZipFile(args.input) as archive:
        names = archive.namelist()
        data = {name: archive.read(name) for name in names}

    characters = json.loads(data["characters/characters.json"])
    found = False
    for character in characters:
        if character.get("id") == "sakura":
            character["photo_uniform"] = UNIFORM
            found = True
    if not found:
        parser.error("characters/characters.json has no sakura")
    data["characters/characters.json"] = _json_bytes(characters)

    sheet = data["characters/sheets/sakura.md"].decode("utf-8")
    if OLD_SHEET not in sheet:
        parser.error("sakura sheet no longer contains the old uniform sentence")
    data["characters/sheets/sakura.md"] = sheet.replace(OLD_SHEET, NEW_SHEET).encode("utf-8")

    manifest = json.loads(data["manifest.json"])
    files = manifest.setdefault("files", {})
    for name, payload in data.items():
        if name != "manifest.json":
            files[name] = {"size": len(payload), "crc32": _crc32(payload)}
    manifest["created_at"] = (
        _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    )
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
            archive.writestr("manifest.json", data["manifest.json"])
        os.replace(temp_path, args.output)
    finally:
        if temp_path.exists():
            temp_path.unlink()

    print(f"wrote {args.output} ({args.output.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
