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
import hashlib
import json
import math
import os
import random
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
# Content metadata used by the full bundle. Ages are set to the adult floor required by
# the user for adult mode; the game has no explicit age table in the extracted data.
HEROINE_DETAIL = {
    "sakura": {
        "age": 18,
        "voice_id": "f55813e84ce44a6ea13a592a112458a7",
        "photo_tag": "yoruno sakura",
        "photo_lora": "Yoruno_Sakura_Kuro_Syasyou_v1.0_NoobAI.safetensors",
        "photo_lora_triggers": "Yoruno_sakura, Yoruno_sakura-(school_uniform)",
        "photo_appearance": "white hair, pink gradient hair, long hair, blue eyes, hair ornament, school uniform",
    },
    "katan": {
        "age": 18,
        "voice_id": "6123d976c0044789be9b6b79772723f0",
        "photo_tag": "kaiman katan",
        "photo_appearance": "red hair, twintails, pink eyes, heart ahoge, black hair bow, school uniform",
    },
    "sophia": {
        "age": 18,
        "voice_id": "e8f7da8d0760440195fd812dcb3a7737",
        "photo_tag": "sophia lancaster",
        "photo_appearance": "blonde hair, long hair, green eyes, school uniform",
    },
    "suisen": {
        "age": 18,
        "voice_id": "2dab8607f82a4c8187d740c9583d21fb",
        "photo_tag": "houzuki suisen",
        "photo_appearance": "grey hair, gradient hair, purple hair, twintails, yellow eyes, school uniform",
    },
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


def clean_for_text(value: str) -> str:
    """Remove controller/render tags before storing or embedding a line."""
    value = re.sub(r"<[^>]*>", "", value or "")
    value = re.sub(r"%[0-9]+", "、", value)
    value = re.sub(r"%[A-Za-z]", "", value)
    value = value.replace("\u3000", " ").replace("\r", " ").replace("\n", " ")
    value = re.sub(r"\s+", " ", value).strip()
    return value


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
        translated = clean_for_text(translated)
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
        CREATE TABLE episodes (id TEXT PRIMARY KEY, category TEXT NOT NULL, route TEXT,
          chapter TEXT, source TEXT NOT NULL, title TEXT NOT NULL,
          imported_from TEXT NOT NULL DEFAULT 'csv', imported_at TEXT NOT NULL);
        CREATE TABLE episode_cast (episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
          character_id TEXT NOT NULL, PRIMARY KEY (episode_id, character_id));
        CREATE INDEX episode_cast_by_character ON episode_cast(character_id);
        CREATE TABLE episode_lines (episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
          seq INTEGER NOT NULL, speaker TEXT, ja TEXT NOT NULL, zh TEXT,
          ja_raw TEXT, ja_clean TEXT,
          PRIMARY KEY (episode_id, seq));
        CREATE TABLE episode_passages (episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
          seq INTEGER NOT NULL, text TEXT NOT NULL, model TEXT NOT NULL, embedding BLOB NOT NULL,
          PRIMARY KEY (episode_id, seq));
        """
    )
    passage_index = 0
    for unit, lines in lines_by_unit:
        episode_id = unit.name
        db.execute("INSERT INTO episodes(category, route, chapter, source, title, imported_from, imported_at, id) VALUES ('本編', ?, ?, ?, ?, 'totsulover', '2026-11-12T00:00:00Z', ?)",
                   (unit.route, unit.name, str(unit.source), unit.name, episode_id))
        cast = set()
        for line in lines:
            if line["speaker"] in HEROINES:
                cast.add(line["speaker"])
            db.execute("INSERT INTO episode_lines(episode_id, seq, speaker, ja, zh, ja_raw, ja_clean) VALUES (?, ?, ?, ?, ?, ?, ?)",
                       (episode_id, line["seq"], line["speaker"], line["ja"], line["zh"],
                        line["ja"], clean_for_text(line["ja"])))
        if unit.route == "0共通" or not cast:
            cast = set(HEROINES)
        elif unit.route in ROUTE_HEROINE and ROUTE_HEROINE[unit.route]:
            cast.add(ROUTE_HEROINE[unit.route])
        for character_id in sorted(cast):
            db.execute("INSERT INTO episode_cast VALUES (?, ?)", (episode_id, character_id))
        for start in range(0, len(lines), 3):
            chunk = lines[start:start + 3]
            text_value = "\n".join(clean_for_text(line["zh"] or line["ja"]) for line in chunk).strip()
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


GIFTS = [
    ("cake", "蛋糕", "food", "common", False),
    ("ice-cream", "冰淇淋", "food", "common", False),
    ("pudding", "布丁", "food", "common", False),
    ("chocolate", "巧克力", "food", "common", False),
    ("candy", "糖果", "food", "common", False),
    ("meat-bun", "肉包", "food", "common", False),
    ("wagashi", "和果子", "food", "uncommon", False),
    ("black-tea", "红茶", "drink", "common", False),
    ("coffee", "咖啡", "drink", "common", False),
    ("milk-tea", "奶茶", "drink", "common", False),
    ("cocoa", "热可可", "drink", "uncommon", True),
    ("honey-drink", "蜂蜜热饮", "drink", "uncommon", True),
    ("bouquet", "花束", "flower", "uncommon", False),
    ("potted-plant", "盆栽", "flower", "uncommon", False),
    ("preserved-flower", "永生花", "flower", "rare", False),
    ("book", "书", "trinket", "uncommon", False),
    ("music-cd", "音乐 CD", "trinket", "uncommon", False),
    ("hot-water-bag", "热水袋", "trinket", "uncommon", True),
    ("plush", "毛绒玩偶", "trinket", "rare", False),
    ("jewelry", "首饰", "trinket", "rare", False),
]

# Her tastes are stable between installs but not a hand-maintained duplicate of the
# catalog: the favored pool is a short personality seed and the draw uses the character id.
GIFT_FAVORITES = {
    "sakura": ["cake", "black-tea", "bouquet", "book", "plush"],
    "katan": ["candy", "meat-bun", "milk-tea", "music-cd", "plush"],
    "sophia": ["black-tea", "bouquet", "potted-plant", "jewelry", "book"],
    "suisen": ["pudding", "cocoa", "honey-drink", "hot-water-bag", "jewelry"],
}

WORLD = {
    "as_of": "2026-11-12",
    "office": {
        "name": "学园",
        "staff": [
            {"name": "学园学生会长", "reading": "がくえん せいと かいちょう", "position": "学生会长"},
            {"name": "崩月槐", "reading": "くずつき かい", "position": "魔术师 / 转学生"},
        ],
    },
    "factions": [
        {"name": "学园", "reading": "がくえん", "note": "以学生会为核心的学园势力；夜乃樱担任学生会长。"},
        {"name": "魔术师", "reading": "まじゅつし", "note": "崩月家所属的魔术师势力；崩月槐与崩月水仙出身于此。"},
        {"name": "崩月家", "reading": "くずつきけ", "note": "研究反现实与魔术的家族；槐与妹妹水仙是家族成员。"},
    ],
    "protagonist": {"name": "崩月槐", "reading": "くずつき かい", "note": "崩月家的魔术师，也是本作的主角；制作人与玩家处在同一侧。"},
    "units": [
        {"name": "学园", "members": ["夜乃桜", "海漫華淡", "ソフィア・ランカスター", "崩月水仙"]},
        {"name": "魔术师", "members": ["崩月槐"]},
        {"name": "崩月家", "members": ["崩月槐", "崩月水仙"]},
    ],
    "idols": [
        {"name": "夜乃桜", "reading": "よの さくら", "unit": "学园"},
        {"name": "海漫華淡", "reading": "かいまん かたん", "unit": "学园"},
        {"name": "ソフィア・ランカスター", "reading": "そふぃあ らんかすたー", "unit": "学园"},
        {"name": "崩月水仙", "reading": "くずつき すいせん", "unit": "学园"},
    ],
    "releases": [], "songs": [], "lives": [],
}
PLACES = {"places": [
    {"id": "academy", "name": "学园校舍", "area": "横浜", "lat": 35.4657, "lon": 139.6222,
     "category": "cafe", "note": "学园的校舍与学生会室，日常剧情的中心。", "checked": "2026-11-12",
     "idols": ["sakura", "katan", "sophia", "suisen"]},
    {"id": "student-council", "name": "学生会室", "area": "横浜", "lat": 35.4659, "lon": 139.6224,
     "category": "cafe", "note": "学生会开会、处理后辈事务的房间。", "checked": "2026-11-12",
     "idols": ["sakura", "katan", "sophia"]},
    {"id": "rooftop", "name": "学园天台", "area": "横浜", "lat": 35.4661, "lon": 139.6226,
     "category": "park", "note": "能看见校园与远处海湾的天台。", "checked": "2026-11-12",
     "idols": ["sakura", "katan", "sophia", "suisen"]},
    {"id": "waterfront", "name": "横浜港", "area": "横浜", "lat": 35.4700, "lon": 139.6300,
     "category": "seaside", "note": "能看到海湾的散步道，傍晚适合慢慢走。", "checked": "2026-11-12"},
    {"id": "cafe", "name": "港边咖啡店", "area": "横浜", "lat": 35.4682, "lon": 139.6251,
     "category": "cafe", "note": "安静的街角咖啡店，适合放学后坐一会儿。", "checked": "2026-11-12"},
    {"id": "bookstore", "name": "旧书店", "area": "横浜", "lat": 35.4674, "lon": 139.6244,
     "category": "books", "note": "木质书架和旧书气味很重的小店。", "checked": "2026-11-12"},
    {"id": "shopping-street", "name": "商店街", "area": "横浜", "lat": 35.4670, "lon": 139.6238,
     "category": "shopping-street", "note": "有小吃摊和杂货铺的热闹商店街。", "checked": "2026-11-12"},
    {"id": "fashion-street", "name": "元町商店街", "area": "横浜", "lat": 35.4428, "lon": 139.6501,
     "category": "fashion-street", "note": "洋装店和杂货店林立的坡道。", "checked": "2026-11-12"},
    {"id": "mall", "name": "港未来商场", "area": "横浜", "lat": 35.4570, "lon": 139.6320,
     "category": "mall", "note": "有电影院和甜品店的大型商场。", "checked": "2026-11-12"},
    {"id": "shrine", "name": "山手神社", "area": "横浜", "lat": 35.4460, "lon": 139.6480,
     "category": "shrine", "note": "山手坡道上的小神社，石阶很安静。", "checked": "2026-11-12"},
    {"id": "amusement", "name": "港湾游乐园", "area": "横浜", "lat": 35.4555, "lon": 139.6368,
     "category": "amusement", "note": "有摩天轮和海景观览车的游乐园。", "checked": "2026-11-12"},
    {"id": "museum", "name": "美术馆", "area": "横浜", "lat": 35.4577, "lon": 139.6356,
     "category": "museum", "note": "常设展和企划展都安静的美术馆。", "checked": "2026-11-12"},
    {"id": "night-view", "name": "大栈桥夜景", "area": "横浜", "lat": 35.4540, "lon": 139.6420,
     "category": "night-view", "note": "能看港口灯火的栈桥平台。", "checked": "2026-11-12"},
    {"id": "bath", "name": "钱汤", "area": "横浜", "lat": 35.4668, "lon": 139.6260,
     "category": "bath", "note": "老式钱汤，门口挂着暖帘。", "checked": "2026-11-12"},
]}
HOLIDAYS_2026 = {
    "2026-01-01": "元日", "2026-01-12": "成人の日", "2026-02-11": "建国記念の日",
    "2026-02-23": "天皇誕生日",
    "2026-03-20": "春分の日", "2026-04-29": "昭和の日", "2026-05-03": "憲法記念日",
    "2026-05-04": "みどりの日", "2026-05-05": "こどもの日", "2026-05-06": "振替休日",
    "2026-07-20": "海の日", "2026-08-11": "山の日", "2026-09-21": "敬老の日",
    "2026-09-22": "国民の休日", "2026-09-23": "秋分の日", "2026-10-12": "スポーツの日",
    "2026-11-03": "文化の日", "2026-11-23": "勤労感謝の日",
}

FACTS = {
    "sakura": """- 作品：ディメンション凸ラバース！！
- 组织：学园学生会
- 身份：学生会长，学园最强级别的战力
- 年龄：18
- 生日：未在公开资料中确认（内容包暂不虚构具体日期）
- 特征：白发、粉色渐变长发、蓝眼；持有名为「蓝之心脏」的反现实器官
- 性格：冷静孤高、责任感强，不擅长把关心说得好听；习惯独自承担危险
- 关系：制作人是她愿意认真对待、也会要求回应的人；与崩月家处于敌对立场
""",
    "katan": """- 作品：ディメンション凸ラバース！！
- 组织：学园学生会
- 身份：学生会成员，气氛担当
- 年龄：18
- 生日：未在公开资料中确认（内容包暂不虚构具体日期）
- 特征：红发双马尾、粉色眼睛、心形呆毛
- 性格：高情绪、直率、善于沟通，对谁都不摆架子；认真起来不马虎
- 关系：把制作人当作可以一起行动、也可以由她来照顾的人
""",
    "sophia": """- 作品：ディメンション凸ラバース！！
- 组织：学园学生会
- 身份：副会长，名门兰卡斯特家的女儿
- 年龄：18
- 生日：未在公开资料中确认（内容包暂不虚构具体日期）
- 特征：金发、绿眼、举止端整；使用细剑
- 性格：自尊心强、不服输，同时有照顾人的姐姐气质；有三个妹妹
- 关系：对制作人会照顾到细节，偶尔用大小姐措辞掩饰害羞
""",
    "suisen": """- 作品：ディメンション凸ラバース！！
- 组织：崩月家 / 魔术师
- 身份：崩月槐的妹妹，自称「忍者女仆」
- 年龄：18
- 生日：未在公开资料中确认（内容包暂不虚构具体日期）
- 特征：灰紫渐变发、双马尾、黄色眼睛
- 性格：话少、行动利落，对制作人礼貌但会默默观察
- 关系：对哥哥崩月槐有很强的执着，把这份在意藏进冷静的举止里
""",
}

SHEETS = {
    "sakura": """# 夜乃桜

学园最强级别的学生会长，冷静、孤高、责任感很强。她不擅长把关心说得好听，
但会认真观察制作人的状态；越是重要的事，越会先沉默，再说重点。
用户是她在屏幕这一侧想要守护、也会认真要求回应的人。

她喜欢猫、普通日常和被认真对待；被夸时会短暂停顿或转移话题。
她不会无条件顺从，会在制作人逞强、逃避或把她推开时明确表达不满。
""",
    "katan": """# 海漫華淡

学园学生会成员，性格明亮而直接，情绪来得快也去得快。她讨厌把气氛弄僵，
会主动靠近在意的人，用轻快的语气把尴尬化解掉；真正认真的时候并不含糊。
她对谁都保持礼貌和距离感，却会把制作人当作可以一起行动、也可以由她照顾的人。
""",
    "sophia": """# ソフィア・ランカスター

学园学生会副会长，出身名门兰卡斯特家，举止端整，自尊心很强，不喜欢输。
她有三个妹妹，习惯照顾人，偶尔会用大小姐式的措辞掩饰害羞，也会半认真地
要求制作人叫她“姐姐”。她认真、可靠，也有不擅长坦率表达的一面。
""",
    "suisen": """# 崩月水仙

崩月槐的妹妹，出身魔术师家族，身材高挑，自称“忍者女仆”，负责照顾哥哥的日常。
她话不多，行动利落，对制作人保持礼貌但会默默观察；遇到与哥哥有关的事时，
冷静的举止会露出明显的执着。她也会用自己的方式记住制作人的习惯。
""",
}

def load_terms(game: Path) -> list[dict]:
    """The 128-row original TIPS.CSV: term, reading and the two tips image names."""
    blob = read_pac_entry(game / "csv.pac", "TIPS.CSV").decode("cp932", errors="replace")
    terms = []
    for row, line in enumerate(blob.splitlines()):
        cols = line.split(",")
        if len(cols) < 4 or not cols[0].strip():
            continue
        terms.append({
            "id": cols[2].strip().removesuffix("S"),
            "row": row,
            "term": cols[0].strip(),
            "reading": cols[1].strip(),
            "image_small": cols[2].strip(),
            "image_large": cols[3].strip(),
        })
    return terms


def write_assets(staging: Path, sakura_source: Path, avatar_dir: Path | None = None,
                 photo_tags_path: Path | None = None, game: Path | None = None):
    chars = staging / "characters"
    (chars / "sheets").mkdir(parents=True)
    (chars / "avatars").mkdir(parents=True)
    (chars / "facts").mkdir(parents=True)
    entries = []
    for index, (cid, (name, name_zh, kana, romaji, speaker, color)) in enumerate(HEROINES.items(), start=1):
        detail = HEROINE_DETAIL[cid]
        sheet = f"characters/sheets/{cid}.md"
        facts = f"characters/facts/{cid}.md"
        avatar = f"characters/avatars/{cid}.jpg"
        text = SHEETS.get(cid, f"# {name}\n")
        if cid == "sakura" and (sakura_source / "card.md").exists():
            text = (sakura_source / "card.md").read_text(encoding="utf-8")
        (staging / sheet).write_text(text, encoding="utf-8")
        (staging / facts).write_text(f"# {name}\n\n{FACTS[cid]}", encoding="utf-8")
        if avatar_dir and (avatar_dir / f"{cid}.jpg").exists():
            (staging / avatar).write_bytes((avatar_dir / f"{cid}.jpg").read_bytes())
        elif cid == "sakura" and (sakura_source / "portraits/A020.png").exists():
            (staging / avatar).write_bytes((sakura_source / "portraits/A020.png").read_bytes())
        else:
            (staging / avatar).write_bytes(solid_png(256, (40 + index * 30, 70, 120)))
        seed = int(hashlib.sha256(cid.encode()).hexdigest()[:8], 16)
        gifts = random.Random(seed).sample(GIFT_FAVORITES[cid], 3)
        entries.append({
            "id": cid, "name": name, "name_zh": name_zh, "name_kana": kana, "name_romaji": romaji,
            "unit": "学園", "intro": f"{name}，本作的女主角之一。", "color": color,
            "voice_id": detail.get("voice_id", cid), "sheet": sheet, "facts": facts, "avatar": avatar,
            "speakers": [speaker], "idol_id": index, **({"birthday": detail["birthday"]} if detail.get("birthday") else {}),
            "age": detail["age"], "photo_tag": detail["photo_tag"],
            "photo_lora": detail.get("photo_lora"),
            "photo_lora_triggers": detail.get("photo_lora_triggers", ""),
            "photo_appearance": detail["photo_appearance"],
            "place_likes": {
                "sakura": ["cafe", "books", "seaside", "night-view"],
                "katan": ["cafe", "shopping-street", "amusement", "park"],
                "sophia": ["cafe", "museum", "fashion-street", "mall"],
                "suisen": ["bath", "seaside", "books", "shrine"],
            }[cid], "liked_gifts": gifts,
        })
    (chars / "characters.json").write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")
    if game is not None:
        (chars / "terms.json").write_text(
            json.dumps(load_terms(game), ensure_ascii=False, indent=2), encoding="utf-8"
        )
    (chars / "franchise.json").write_text(json.dumps({
        "work_name": "ディメンション凸ラバース！！",
        "organization": "学園",
        "producer_role": "制作人",
        "language": "ja",
        "judge_scene": "角色扮演对话中，角色是《ディメンション凸ラバース！！》中学园的一员，正在和制作人对话。",
        "call_scene": "角色扮演的通话中，角色是《ディメンション凸ラバース！！》中学园的一员，正在和制作人通话。",
        "producer_line": "和你对话的是你的制作人，也是学园相关的人。",
        "memory_instructions": "你负责替《ディメンション凸ラバース！！》中学园的角色们记住关于制作人的事。制作人就是正在和她们对话的用户。",
        "title_instructions": "你负责给制作人和一位角色（《ディメンション凸ラバース！！》中学园的一员）的一段对话起标题，好让制作人以后在历史对话里一眼认出这段聊了什么。制作人就是正在和她对话的用户。",
        "photo_series": "",
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    (chars / "world.json").write_text(json.dumps(WORLD, ensure_ascii=False, indent=2), encoding="utf-8")
    (chars / "places.json").write_text(json.dumps(PLACES, ensure_ascii=False, indent=2), encoding="utf-8")
    (chars / "gifts.json").write_text(json.dumps({"gifts": [
        {"id": gid, "name": gname, "category": category, "rarity": rarity, "warm": warm}
        for gid, gname, category, rarity, warm in GIFTS
    ]}, ensure_ascii=False, indent=2), encoding="utf-8")
    photo_tags = photo_tags_path or Path("build/photo_tags.json")
    if photo_tags.exists():
        (chars / "photo_tags.json").write_bytes(photo_tags.read_bytes())
    else:
        (chars / "photo_tags.json").write_text(json.dumps({
            "model": "nai-diffusion-5-curated", "known": ["smile", "cafe", "indoors"], "rewrites": {},
            "allowed": ["smile"], "blocked": {"nudity": {"tags": ["nude"], "words": []}},
        }, ensure_ascii=False, indent=2), encoding="utf-8")
    (staging / "content/holidays.json").parent.mkdir(parents=True, exist_ok=True)
    (staging / "content/holidays.json").write_text(json.dumps(HOLIDAYS_2026, ensure_ascii=False, indent=2), encoding="utf-8")

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
    parser.add_argument("--avatar-dir", type=Path, default=Path("build/totsulover-avatars"))
    parser.add_argument("--photo-tags", type=Path, default=Path("build/photo_tags.json"))
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
        write_assets(staging, DEFAULT_CHS.parent / "sakura", args.avatar_dir, args.photo_tags, args.game)
        write_zip(staging, args.out)
    finally:
        import shutil
        shutil.rmtree(staging, ignore_errors=True)
    print(args.out)
    print(f"{args.out.stat().st_size} bytes, {len(units)} units, {len(passage_texts)} passages")


if __name__ == "__main__":
    main()
