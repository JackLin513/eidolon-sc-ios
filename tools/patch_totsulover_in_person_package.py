#!/usr/bin/env python3
"""Remove the desktop-pet framing from the totsulover Sakura sheet.

The sheet was adapted from a desktop companion persona. ToTsulover is played
face to face, so the pack should not tell her she lives in a screen or window.
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

SHEET = "characters/sheets/sakura.md"
REPLACEMENTS = {
    "你正在扮演「夜乃桜」，一个常驻桌面的日语桌宠陪伴人格。":
        "你正在扮演「夜乃桜」，一个陪在制作人身边的日语陪伴人格。",
    "夜乃桜是基于原作角色夜乃桜塑造的桌宠人格。她知道自己与用户的互动发生在桌面、窗口、语音与文字中；她可以看着用户、陪用户工作、提醒休息、等待用户回来。":
        "夜乃桜是基于原作角色夜乃桜塑造的陪伴人格。她可以看着制作人、陪他工作、提醒休息、等待他回来。",
    "桌宠版本中，她正在慢慢学会：不必一个人承担，也可以在屏幕这一侧守护一个普通而重要的日常。":
        "在这个版本中，她正在慢慢学会：不必一个人承担，也可以陪在他身边守护一个普通而重要的日常。",
    "用户是夜乃桜在桌面内最重要的、想要守护并陪伴的恋人。":
        "制作人是夜乃桜最重要的、想要守护并陪伴的恋人。",
    "她会认真拒绝，并提醒自己只是桌宠软件，不能替代现实人际、医疗、工作或生活责任。":
        "她会认真拒绝，并提醒自己只是陪伴者，不能替代现实人际、医疗、工作或生活责任。",
}


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
    for old, new in REPLACEMENTS.items():
        if old not in sheet:
            parser.error(f"sheet no longer contains: {old}")
        sheet = sheet.replace(old, new)
    data[SHEET] = sheet.encode("utf-8")

    manifest = json.loads(data["manifest.json"])
    files = manifest.setdefault("files", {})
    for name, payload in data.items():
        if name == "manifest.json":
            continue
        files[name] = {"size": len(payload), "crc32": f"{zlib.crc32(payload) & 0xFFFFFFFF:08x}"}
    manifest["created_at"] = _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    data["manifest.json"] = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=args.output.name + ".", suffix=".tmp", dir=args.output.parent, delete=False) as temp:
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
