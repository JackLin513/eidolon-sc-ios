#!/usr/bin/env python3
"""Build a full Totsulover story content bundle from the game + CHS v1.1 patch.

The game and patch stay read-only. Text is extracted from `data.pac` and the patch's
`totsulover.dll`; Chinese comes from the public Can/need strings. No translated text is
written into this repository; the output zip lives under `build/` and is local-only.

Usage:
  python3 tools/import_totsulover_story.py --out build/eidolon-totsulover-full.eidolonpkg
  python3 tools/import_totsulover_story.py --max-units 3 --embedding-mode zeros --out /tmp/test.pkg
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sqlite3
import struct
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path

DEFAULT_GAME = Path.home() / "Developer/IdeaProjects/Galgame support/ディメンション凸ラバース!!/totsulover_dl"
DEFAULT_CHS = Path.home() / "Developer/IdeaProjects/Galgame support/totsulover_CHS_v1.1"
DEFAULT_ENV = Path.home() / "Developer/IdeaProjects/eidolon-sc-ios/.env"
DEFAULT_OUT = Path("build/eidolon-totsulover-full.eidolonpkg")
FRANCHISE = "totsulover"
CONTENT_SET_ID = "totsulover.full.v1"

HEROINES = {
    "sakura": ("夜乃桜", "夜乃樱", "よの さくら", "Yono Sakura", "桜", "#b9d9ff"),
    "katan": ("海漫華淡", "海漫华淡", "かいまん かたん", "Kaiman Katan", "華淡", "#ffc7dd"),
    "sophia": ("ソフィア・ランカスター", "索菲娅·兰卡斯特", "そふぃあ らんかすたー", "Sophia Lancaster", "ソフィア", "#d9c7ff"),
    "suisen": ("崩月水仙", "崩月水仙", "くずつき すいせん", "Kuzutsuki Suisen", "水仙", "#c7f0e8"),
}
SPEAKER_TO_HEROINE = {
    "樱": "sakura", "桜": "sakura",
    "华淡": "katan", "華淡": "katan",
    "索菲娅": "sophia", "ソフィア": "sophia",
    "水仙": "suisen",
}
PROTAGONIST_NAMES = {"槐", "制作人", "主人公"}
ROUTE_HEROINE = {
    "0共通": None,
    "1樱": "sakura",
    "2华淡": "katan",
    "3索菲亚": "sophia",
    "4水仙": "suisen",
    "5真结局": None,
}


def crc32_hex(data: bytes) -> str:
    return f"{zlib.crc32(data) & 0xFFFFFFFF:08x}"


def normalize_text(value: str) -> str:
    value = re.sub(r"<[^>]*>", "", value or "")
    value = value.replace("\u3000", " ").replace("\r", " ").replace("\n", " ")
    return re.sub(r"\s+", "", value)


def read_pac_entry(pac: Path, wanted: str) -> bytes:
    data = pac.read_bytes()
    if data[:4] != b"PAC ":
        raise SystemExit(f"not a PAC archive: {pac}")
    count = struct.unpack_from("<I", data, 8)[0]
    index = data[0x804:0x804 + count * 0x28]
    for i in range(count):
        entry = index[i * 0x28:(i + 1) * 0x28]
        name = entry[:0x20].split(b"\0")[0].decode("cp932", errors="replace")
        if name.upper() != wanted.upper():
            continue
        size, offset = struct.unpack_from("<II", entry, 0x20)
        return data[offset:offset + size]
    raise SystemExit(f"{wanted} not found in {pac}")


def parse_text_dat(blob: bytes) -> dict[int, str]:
    if not blob.startswith(b"_TEXT_LIST__"):
        raise SystemExit("unexpected TEXT.DAT header")
    pos, rows = 20, {}
    while pos + 4 < len(blob):
        end = blob.find(b"\0", pos)
        if end < 0 or end + 5 > len(blob):
            break
        rows[struct.unpack_from("<I", blob, end + 1)[0]] = blob[pos:end].decode(
            "cp932", errors="replace"
        )
        pos = end + 5
    return rows


# ---- PE resource + RPCK extraction (patch DLL) ---------------------------------


def pe_rva_to_offset(data: bytes, rva: int) -> int:
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    sections = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    section_table = pe + 24 + opt_size
    for i in range(sections):
        base = section_table + i * 40
        virtual_size, virtual_address, raw_size, raw_ptr = struct.unpack_from("<IIII", data, base + 8)
        if virtual_address <= rva < virtual_address + max(virtual_size, raw_size):
            return raw_ptr + (rva - virtual_address)
    raise SystemExit(f"unmapped RVA {rva:#x}")


def extract_rcdata(dll: Path) -> bytes:
    data = dll.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    sections = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    section_table = pe + 24 + opt_size
    rsrc_rva = rsrc_size = None
    for i in range(sections):
        base = section_table + i * 40
        name = data[base:base + 8].rstrip(b"\0")
        vsize, va, raw_size, raw_ptr = struct.unpack_from("<IIII", data, base + 8)
        if name == b".rsrc":
            rsrc_rva, rsrc_size = va, max(vsize, raw_size)
            break
    if rsrc_rva is None:
        raise SystemExit("no .rsrc in patch DLL")

    def directory_at(rva: int) -> tuple[int, int, int]:
        off = pe_rva_to_offset(data, rsrc_rva + rva)
        return off, struct.unpack_from("<HH", data, off + 12)[0], struct.unpack_from("<H", data, off + 14)[0]

    def find_id(rva: int, wanted: int) -> int | None:
        off, named, ids = directory_at(rva)
        for i in range(named + ids):
            name, ptr = struct.unpack_from("<II", data, off + 16 + i * 8)
            if name == wanted:
                return ptr
        return None

    type_ptr = find_id(0, 10)  # RCDATA
    if type_ptr is None:
        raise SystemExit("no RCDATA type")
    name_ptr = find_id(type_ptr & 0x7FFFFFFF, 1001)
    if name_ptr is None:
        raise SystemExit("no RCDATA 1001")
    lang_ptr = find_id(name_ptr & 0x7FFFFFFF, 0)
    if lang_ptr is None:
        raise SystemExit("no RCDATA language")
    data_off = pe_rva_to_offset(data, rsrc_rva + (lang_ptr & 0x7FFFFFFF))
    data_rva, data_size, _ = struct.unpack_from("<III", data, data_off)
    return data[pe_rva_to_offset(data, data_rva):pe_rva_to_offset(data, data_rva) + data_size]


def zstd_decompress(payload: bytes) -> bytes:
    if not payload.startswith(b"\x28\xb5\x2f\xfd"):
        return payload
    proc = subprocess.run(["zstd", "-q", "-d", "-c"], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0 and not proc.stdout:
        raise SystemExit("zstd failed: " + proc.stderr.decode(errors="replace")[:200])
    # The patch's frames carry trailing bytes; zstd decodes the full frame and then
    # reports an unsupported trailing chunk. The decoded bytes are still exact.
    return proc.stdout


def extract_strings_json(dll: Path) -> dict[int, str]:
    raw = extract_rcdata(dll)
    if raw[:4] != b"RPCK":
        raise SystemExit("RCDATA is not RPCK")
    version, count = struct.unpack_from("<II", raw, 4)
    index = raw[12:12 + count * 12]
    name_base = 12 + count * 12
    wanted = None
    for i in range(count):
        name_off, kind, data_off = struct.unpack_from("<III", index, i * 12)
        end = raw.find(b"\0", name_off)
        name = raw[name_off:end].decode("ascii", errors="replace")
        if name == "STRINGS.JSON":
            wanted = (kind, data_off)
            break
    if wanted is None:
        raise SystemExit("STRINGS.JSON not found in RPCK")
    kind, data_off = wanted
    if kind == 1:
        payload = raw[data_off:]
    else:
        size = struct.unpack_from("<I", raw, data_off)[0]
        payload = zstd_decompress(raw[data_off + 4:data_off + 4 + size])
    strings = json.loads(payload.decode("utf-8"))
    return {int(k): v for k, v in strings.items() if k.isdigit() and 1 <= int(k) <= 70111}


# ---- Story synthesis -----------------------------------------------------------


@dataclass
class Unit:
    name: str
    route: str
    source: Path
    start: int
    end: int
    entries: list[dict]


def load_units(game: Path, chs: Path, max_units: int | None = None):
    text = parse_text_dat(read_pac_entry(game / "data.pac", "TEXT.DAT"))
    strings = extract_strings_json(chs / "Mod本体/totsulover.dll")
    json_files = sorted((chs / "canneed-oss/Project008Totsulover").glob("**/*.json"))
    by_name = {p.stem: p for p in json_files}
    unit_ids = sorted((ident, name) for ident, name in text.items() if name in by_name)
    if not unit_ids:
        raise SystemExit("no unit anchors found")
    if max_units:
        unit_ids = unit_ids[:max_units]
    units = []
    for i, (start, name) in enumerate(unit_ids):
        end = unit_ids[i + 1][0] if i + 1 < len(unit_ids) else max(text) + 1
        source = by_name[name]
        route = source.relative_to(chs / "canneed-oss/Project008Totsulover").parts[0]
        entries = json.loads(source.read_text(encoding="utf-8"))
        units.append(Unit(name, route, source, start, end, entries))
    return text, strings, units


def make_lines(text, strings, unit: Unit):
    records = [(ident, text[ident], strings.get(ident - 1, "")) for ident in range(unit.start + 1, unit.end)]
    lines, cursor = [], 0
    for entry in unit.entries:
        zh = (entry.get("message") or "").strip()
        target = normalize_text(zh)
        found = None
        for i in range(cursor, len(records)):
            if normalize_text(records[i][1]) == target or normalize_text(records[i][2]) == target:
                found = i
                break
        if found is None:
            if cursor >= len(records):
                continue
            found = cursor
        ident, ja, translated = records[found]
        cursor = found + 1
        if not translated:
            translated = zh
        name = (entry.get("name") or "").strip()
        if name in PROTAGONIST_NAMES:
            speaker = "__producer__"
        elif name in SPEAKER_TO_HEROINE:
            speaker = SPEAKER_TO_HEROINE[name]
        else:
            speaker = name or None
        lines.append({"seq": len(lines) + 1, "speaker": speaker, "ja": ja, "zh": translated})
    return lines


def write_database(path: Path, lines_by_unit, embeddings):
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.execute("PRAGMA user_version = 1")
    db.executescript(
        """
        CREATE TABLE episodes (id TEXT PRIMARY KEY, category TEXT NOT NULL, source TEXT NOT NULL,
          title TEXT NOT NULL, imported_from TEXT NOT NULL DEFAULT 'csv', imported_at TEXT NOT NULL);
        CREATE TABLE episode_cast (episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
          character_id TEXT NOT NULL, PRIMARY KEY (episode_id, character_id));
        CREATE INDEX episode_cast_by_character ON episode_cast(character_id);
        CREATE TABLE episode_lines (episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
          seq INTEGER NOT NULL, speaker TEXT, ja TEXT NOT NULL, zh TEXT,
          PRIMARY KEY (episode_id, seq));
        CREATE TABLE episode_passages (episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
          seq INTEGER NOT NULL, text TEXT NOT NULL, model TEXT NOT NULL, embedding BLOB NOT NULL,
          PRIMARY KEY (episode_id, seq));
        """
    )
    passage_index = 0
    for unit, lines in lines_by_unit:
        episode_id = unit.name
        db.execute("INSERT INTO episodes VALUES (?, '本編', ?, ?, 'totsulover', '2026-11-12T00:00:00Z')",
                   (episode_id, str(unit.source), unit.name))
        cast = set()
        for line in lines:
            if line["speaker"] in HEROINES:
                cast.add(line["speaker"])
            db.execute("INSERT INTO episode_lines VALUES (?, ?, ?, ?, ?)",
                       (episode_id, line["seq"], line["speaker"], line["ja"], line["zh"]))
        if unit.route == "0共通" or not cast:
            cast = set(HEROINES)
        elif unit.route in ROUTE_HEROINE and ROUTE_HEROINE[unit.route]:
            cast.add(ROUTE_HEROINE[unit.route])
        for character_id in sorted(cast):
            db.execute("INSERT INTO episode_cast VALUES (?, ?)", (episode_id, character_id))
        for start in range(0, len(lines), 3):
            chunk = lines[start:start + 3]
            text_value = "\n".join((line["zh"] or line["ja"]) for line in chunk).strip()
            if not text_value:
                continue
            embedding = embeddings[passage_index]
            passage_index += 1
            db.execute("INSERT INTO episode_passages(episode_id, seq, text, model, embedding) VALUES (?, ?, ?, ?, ?)",
                       (episode_id, start // 3 + 1, text_value, EMBEDDING_MODEL, embedding))
    db.commit()
    db.close()


def solid_png(size: int, rgb: tuple[int, int, int]) -> bytes:
    def chunk(kind: bytes, payload: bytes):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    row = b"\x00" + bytes(rgb) * size
    raw = row * size
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def write_assets(staging: Path, sakura_source: Path):
    chars = staging / "characters"
    (chars / "sheets").mkdir(parents=True)
    (chars / "avatars").mkdir(parents=True)
    (chars / "facts").mkdir(parents=True)
    entries = []
    for index, (cid, (name, name_zh, kana, romaji, speaker, color)) in enumerate(HEROINES.items(), start=1):
        sheet = f"characters/sheets/{cid}.md"
        facts = f"characters/facts/{cid}.md"
        avatar = f"characters/avatars/{cid}.png"
        text = f"# {name}\n\n"
        if cid == "sakura" and (sakura_source / "card.md").exists():
            text = (sakura_source / "card.md").read_text(encoding="utf-8")
        (staging / sheet).write_text(text, encoding="utf-8")
        (staging / facts).write_text(f"# {name}\n", encoding="utf-8")
        if cid == "sakura" and (sakura_source / "portraits/A020.png").exists():
            (staging / avatar).write_bytes((sakura_source / "portraits/A020.png").read_bytes())
        else:
            (staging / avatar).write_bytes(solid_png(256, (40 + index * 30, 70, 120)))
        entries.append({
            "id": cid, "name": name, "name_zh": name_zh, "name_kana": kana, "name_romaji": romaji,
            "unit": "学園", "intro": f"{name}，本作的女主角之一。", "color": color,
            "voice_id": cid, "sheet": sheet, "facts": facts, "avatar": avatar,
            "speakers": [speaker], "idol_id": index, "birthday": "01-01",
            "photo_tag": romaji.lower(), "photo_appearance": [f"{name} character"],
            "place_likes": ["cafe", "park"],
        })
    (chars / "characters.json").write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")
    (chars / "world.json").write_text(json.dumps({
        "as_of": "2026-11-12",
        "office": {"name": "学園", "staff": []},
        "units": [], "idols": [], "releases": [], "songs": [], "lives": [],
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    (chars / "places.json").write_text(json.dumps({"places": [
        {"id": "cafe", "name": "カフェ", "area": "横浜", "lat": 35.4657, "lon": 139.6222, "category": "cafe", "note": "街角的咖啡馆。", "checked": "2026-11-12"},
        {"id": "park", "name": "公園", "area": "横浜", "lat": 35.4700, "lon": 139.6300, "category": "park", "note": "有长椅的公园。", "checked": "2026-11-12"},
    ]}, ensure_ascii=False, indent=2), encoding="utf-8")
    (chars / "photo_tags.json").write_text(json.dumps({
        "model": "test-image", "known": ["smile", "cafe", "indoors"], "rewrites": {},
        "allowed": ["smile"], "blocked": {"nudity": {"tags": ["nude"], "words": []}},
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    (staging / "content/holidays.json").parent.mkdir(parents=True, exist_ok=True)
    (staging / "content/holidays.json").write_text(json.dumps({
        "2026-01-01": "元日", "2026-02-11": "建国記念の日", "2026-03-20": "春分の日",
        "2026-05-03": "憲法記念日", "2026-12-25": "クリスマス",
    }, ensure_ascii=False, indent=2), encoding="utf-8")


def load_env(path: Path) -> dict[str, str]:
    values = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip()
    return values


def embed_texts(texts: list[str], env: dict[str, str], model: str) -> list[bytes]:
    key = env.get("SILICONFLOW_API_KEY")
    if not key:
        raise SystemExit("SILICONFLOW_API_KEY missing; use --embedding-mode zeros for a structural test")
    base = (env.get("SILICONFLOW_BASE_URL") or "https://api.siliconflow.cn/v1").rstrip("/")
    results: list[list[float]] = []
    for start in range(0, len(texts), 32):
        batch = texts[start:start + 32]
        request = urllib.request.Request(
            base + "/embeddings",
            data=json.dumps({"model": model, "input": batch}).encode(),
            headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
        )
        for attempt in range(3):
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    payload = json.load(response)
                results.extend(item["embedding"] for item in payload["data"])
                break
            except Exception:
                if attempt == 2:
                    raise
        print(f"embedded {min(start + 32, len(texts))}/{len(texts)}", file=sys.stderr)
    return [struct.pack("<" + "f" * len(vector), *vector) for vector in results]


def write_zip(staging: Path, out: Path):
    out.parent.mkdir(parents=True, exist_ok=True)
    files = {}
    for path in sorted(staging.rglob("*")):
        if path.is_file() and path.name != "manifest.json":
            rel = path.relative_to(staging).as_posix()
            data = path.read_bytes()
            files[rel] = {"size": len(data), "crc32": crc32_hex(data)}
    manifest = {
        "format_version": 5, "kind": "content", "franchise": FRANCHISE,
        "engineFamily": "t-script", "contentSetID": CONTENT_SET_ID,
        "content_schema_version": 1, "created_at": "2026-11-12T00:00:00Z",
        "embedding": {"model": EMBEDDING_MODEL, "dimensions": EMBEDDING_DIM},
        "content": {"episodes": 0, "episode_cast": 0, "episode_lines": 0, "episode_passages": 0},
        "characters": {"count": len(HEROINES), "ids": list(HEROINES), "characterKeys": [f"{FRANCHISE}:{c}" for c in HEROINES]},
        "files": files,
    }
    db = sqlite3.connect(staging / "content/eidolon.db")
    for table in manifest["content"]:
        manifest["content"][table] = db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
    db.close()
    (staging / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(staging.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(staging).as_posix())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game", type=Path, default=DEFAULT_GAME)
    parser.add_argument("--chs", type=Path, default=DEFAULT_CHS)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--env-file", type=Path, default=DEFAULT_ENV)
    parser.add_argument("--embedding-mode", choices=("api", "zeros"), default="api")
    parser.add_argument("--max-units", type=int)
    args = parser.parse_args()
    if not args.game.exists() or not args.chs.exists():
        raise SystemExit("game/patch path missing")
    env = load_env(args.env_file)
    global EMBEDDING_MODEL, EMBEDDING_DIM
    EMBEDDING_MODEL = env.get("EMBEDDING_MODEL") or "Qwen/Qwen3-Embedding-0.6B"
    EMBEDDING_DIM = int(env.get("EMBEDDING_DIMENSIONS") or "1024")

    text, strings, units = load_units(args.game, args.chs, args.max_units)
    lines_by_unit = [(unit, make_lines(text, strings, unit)) for unit in units]
    passage_texts = []
    for unit, lines in lines_by_unit:
        for start in range(0, len(lines), 3):
            chunk = lines[start:start + 3]
            value = "\n".join((line["zh"] or line["ja"]) for line in chunk).strip()
            if value:
                passage_texts.append(value)
    if args.embedding_mode == "api":
        embeddings = embed_texts(passage_texts, env, EMBEDDING_MODEL)
    else:
        embeddings = [struct.pack("<" + "f" * EMBEDDING_DIM, *([0.0] * EMBEDDING_DIM)) for _ in passage_texts]
    staging = Path(tempfile.mkdtemp(prefix="totsulover-content-"))
    try:
        (staging / "content").mkdir(parents=True)
        write_database(staging / "content/eidolon.db", lines_by_unit, embeddings)
        write_assets(staging, DEFAULT_CHS.parent / "sakura")
        write_zip(staging, args.out)
    finally:
        import shutil
        shutil.rmtree(staging, ignore_errors=True)
    print(args.out)
    print(f"{args.out.stat().st_size} bytes, {len(units)} units, {len(passage_texts)} passages")


if __name__ == "__main__":
    main()
