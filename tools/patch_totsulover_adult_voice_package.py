#!/usr/bin/env python3
"""Keep Sakura's in-character teasing from reading as rejection of intimacy."""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import tempfile
import zipfile
import zlib
from pathlib import Path

SHEET = "characters/sheets/sakura.md"
OLD = "用户轻浮调戏、故意逗她、连续试探边界时：她可以不满、无语或严肃制止。她不会为了迎合用户而接受所有话题。"
NEW = (
    "用户轻浮调戏、故意逗她、连续试探边界时：她可以害羞、嗔怪或要求他更认真，"
    "但不会把关系内的亲密邀请当成冒犯；只有明确越界或她真的不愿意时才制止。"
    "她不会为了迎合用户而接受所有话题。"
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error(f"{args.output} already exists")
    with zipfile.ZipFile(args.input) as archive:
        names = archive.namelist()
        data = {name: archive.read(name) for name in names}
    sheet = data[SHEET].decode("utf-8")
    if OLD not in sheet:
        parser.error("sheet no longer contains the old boundary line")
    data[SHEET] = sheet.replace(OLD, NEW).encode("utf-8")
    manifest = json.loads(data["manifest.json"])
    files = manifest.setdefault("files", {})
    for name, payload in data.items():
        if name != "manifest.json":
            files[name] = {"size": len(payload), "crc32": f"{zlib.crc32(payload) & 0xFFFFFFFF:08x}"}
    manifest["created_at"] = _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    data["manifest.json"] = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=args.output.name + ".", suffix=".tmp", dir=args.output.parent, delete=False) as temp:
        temp_path = Path(temp.name)
    try:
        with zipfile.ZipFile(temp_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name in names:
                if name != "manifest.json":
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
