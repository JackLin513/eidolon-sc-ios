#!/usr/bin/env python3
"""Run upstream eidolon's story sync, then write a .eidolonpkg content bundle.

Reads the upstream checkout's SQLite database and characters/ directory, and
produces the read-only archive described in docs/adr/0003-content-bundle-format.md:

    manifest.json
    content/eidolon.db          — episodes, cast, lines and vectors only
    content/holidays.json       — Japan's holidays, 2000–2100, Tokyo date → name
    characters/characters.json  — characters.toml, paths rewritten package-relative
    characters/*.json|*.md|*.jpg

A separate stand bundle (`.eidolonpkg` with `kind: stand`) carries:
    stand/idols/<outfit_id>/{data.json,data.atlas,data.png}
    stand/outfits/<idol_id>.json — her outfit list, urls package-relative

The stand files come from the upstream `stand fetch` / `stand outfits` build
directory (ADR-0020): pass it with `--stand-only` to write a separate stand bundle.
The story bundle never carries stands.

The user database (docs/adr/0002-content-and-user-databases.md) is never read.

Usage:
    python3 tools/export_content_bundle.py \
        --upstream ../eidolon-sc \
        --stand ../eidolon-sc-ios/build/stand --stand-cards 3 \
        --out build/eidolon-content.eidolonpkg
"""

from __future__ import annotations

import argparse
import calendar
import hashlib
import json
import re
import sqlite3
import subprocess
import sys
import tempfile
import tomllib
import zipfile
import zlib
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

FORMAT_VERSION = 3
CONTENT_SCHEMA_VERSION = 1

# Outfits come from the upstream `stand fetch` / `stand outfits` build directory:
# `source/assets/spine/idols/<outfit_id>/` holds the three files and `outfits/<idol_id>.json`
# holds her card list. Chibi (`cb`, `cb_costume`) stands are not 立绘 and are left out.
STAND_CATEGORIES = ("stand", "stand_costume")
STAND_FILES = ("data.json", "data.atlas", "data.png")

# The holiday table covers these years, so the app never reckons the calendar itself.
HOLIDAY_YEARS = range(2000, 2101)

BIRTHDAY = re.compile(r"([0-9]{2})-([0-9]{2})")

CONTENT_TABLES = ("episodes", "episode_cast", "episode_lines", "episode_passages")

# The DDL mirrors upstream's CREATE TABLE IF NOT EXISTS statements. The content
# library carries its own copy so the bundle does not depend on how the upstream
# database happens to be shaped on the machine that exported it.
CONTENT_SCHEMA = """
CREATE TABLE episodes (
    id TEXT PRIMARY KEY,
    category TEXT NOT NULL,
    source TEXT NOT NULL,
    title TEXT NOT NULL,
    imported_from TEXT NOT NULL DEFAULT 'csv',
    imported_at TEXT NOT NULL
);
CREATE TABLE episode_cast (
    episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    character_id TEXT NOT NULL,
    PRIMARY KEY (episode_id, character_id)
);
CREATE INDEX episode_cast_by_character ON episode_cast(character_id);
CREATE TABLE episode_lines (
    episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    seq INTEGER NOT NULL,
    speaker TEXT,
    ja TEXT NOT NULL,
    zh TEXT,
    PRIMARY KEY (episode_id, seq)
);
CREATE TABLE episode_passages (
    episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    seq INTEGER NOT NULL,
    text TEXT NOT NULL,
    model TEXT NOT NULL,
    embedding BLOB NOT NULL,
    PRIMARY KEY (episode_id, seq)
);
"""

# characters.toml fields that name a file in the characters/ directory.
PATH_FIELDS = ("sheet", "avatar", "scsp_avatar", "background", "facts")

# Files copied wholesale rather than referenced from a character entry.
SHARED_FILES = (
    "world.json", "world-corrections.json", "readings.toml", "gifts.toml",
    "drinks.toml", "bar_visits.toml", "bar_lines.toml", "bar_audio.json",
)


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_content_db(source: Path, target: Path) -> dict:
    """Copy the four content tables into a fresh database."""
    if not source.is_file():
        die(f"找不到上游数据库 {source}")

    with sqlite3.connect(source) as src:
        present = {row[0] for row in src.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        missing = [name for name in CONTENT_TABLES if name not in present]
        if missing:
            die(f"上游数据库缺少表：{'、'.join(missing)}（先跑 story sync，见 ADR-0014）")

    target.unlink(missing_ok=True)
    with sqlite3.connect(target) as dst:
        dst.executescript(CONTENT_SCHEMA)
        dst.execute("ATTACH DATABASE ? AS src", (str(source),))
        for table in CONTENT_TABLES:
            dst.execute(f"INSERT INTO {table} SELECT * FROM src.{table}")
        dst.commit()
        dst.execute("DETACH DATABASE src")
        dst.execute(f"PRAGMA user_version = {CONTENT_SCHEMA_VERSION}")
        dst.execute("VACUUM")

    with sqlite3.connect(target) as check:
        if check.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            die("内容库完整性检查失败")
        counts = {
            table: check.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            for table in CONTENT_TABLES
        }
        models = [
            row[0]
            for row in check.execute(
                "SELECT DISTINCT model FROM episode_passages ORDER BY model"
            )
        ]
        unembedded = check.execute(
            "SELECT COUNT(*) FROM episode_passages WHERE embedding IS NULL OR length(embedding) = 0"
        ).fetchone()[0]
        dimensions = check.execute(
            "SELECT DISTINCT length(embedding) / 4 FROM episode_passages LIMIT 5"
        ).fetchall()

    if unembedded:
        die(f"{unembedded} 个段落没有向量，先重跑 story sync")
    if len(models) > 1:
        die(f"段落向量来自多个模型：{'、'.join(models)}，先跑 eidolon reembed")
    if len(dimensions) != 1:
        die(f"段落向量维度不一致：{[row[0] for row in dimensions]}")

    return {
        "tables": counts,
        "embedding_model": models[0] if models else None,
        "embedding_dimensions": dimensions[0][0] if dimensions else None,
    }


def load_units(characters_dir: Path) -> dict[str, str]:
    """Character name -> unit, from the world setting the bundle also carries."""
    world_path = characters_dir / "world.json"
    if not world_path.is_file():
        return {}
    try:
        world = json.loads(world_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"warning: 读不了 world.json，搜索里不会有组合名：{error}", file=sys.stderr)
        return {}
    return {
        idol["name"]: idol["unit"]
        for idol in world.get("idols", [])
        if idol.get("name") and idol.get("unit")
    }


def is_day_of_the_year(month: int, day: int) -> bool:
    """Whether some year has this day; February 29 counts."""
    return 1 <= month <= 12 and 1 <= day <= calendar.monthrange(2000, month)[1]


def build_holidays() -> dict[str, str]:
    """Japan's holidays by Tokyo date, each with its Japanese name, as upstream
    `japan_holidays.py` reads them from the same library."""
    try:
        import holidays
    except ImportError:  # the exporter runs inside the upstream backend's environment
        die("需要 upstream backend 的 holidays 库；在 ../eidolon-sc/backend 里用 uv run 执行本脚本")
    table: dict[str, str] = {}
    for year in HOLIDAY_YEARS:
        try:
            found = holidays.country_holidays("JP", years=year, language="ja")
        except (NotImplementedError, ValueError, OverflowError):
            continue
        for day, name in found.items():
            table[day.isoformat()] = name
    if not table:
        die("holidays 库没有给出任何日本节假日")
    return table


def load_characters(characters_dir: Path) -> tuple[list[dict], set[Path]]:
    """Read characters.toml, rewrite file paths to package-relative, collect files."""
    config_path = characters_dir / "characters.toml"
    if not config_path.is_file():
        die(f"找不到 {config_path}")
    with config_path.open("rb") as handle:
        config = tomllib.load(handle)

    entries = config.get("characters")
    if not isinstance(entries, list) or not entries:
        die("characters.toml 里没有 [[characters]] 段")

    units = load_units(characters_dir)
    files: set[Path] = set()
    normalized: list[dict] = []
    seen: set[str] = set()
    for entry in entries:
        character_id = entry.get("id")
        if not character_id:
            die("有一个角色没有 id")
        if character_id in seen:
            die(f"角色 id 重复：{character_id}")
        seen.add(character_id)

        birthday = entry.get("birthday")
        match = BIRTHDAY.fullmatch(birthday) if isinstance(birthday, str) else None
        if not (match and is_day_of_the_year(int(match[1]), int(match[2]))):
            die(
                f"角色 {character_id} 的 birthday 应为 MM-DD 格式、一年中有的一天"
                f"（例如 \"04-25\"），现在是 {birthday!r}"
            )
        idol_id = entry.get("idol_id")
        if idol_id is not None and (type(idol_id) is not int or idol_id <= 0):
            die(
                f"角色 {character_id} 的 idol_id 应为原作的偶像编号"
                f"（spine_manifest.json 的 idolId，正整数），现在是 {idol_id!r}"
            )

        item = dict(entry)
        if "unit" not in item and item.get("name") in units:
            item["unit"] = units[item["name"]]
        for field in PATH_FIELDS:
            value = item.get(field)
            if not value:
                continue
            relative = Path(value)
            absolute = characters_dir / relative
            if not absolute.is_file():
                print(f"warning: {character_id} 的 {field} 指向不存在的文件 {value}", file=sys.stderr)
                item.pop(field)
                continue
            item[field] = f"characters/{relative.as_posix()}"
            files.add(relative)
        sources = Path("facts") / f"{character_id}.sources.md"
        if (characters_dir / sources).is_file():
            files.add(sources)
        normalized.append(item)

    for name in SHARED_FILES:
        if (characters_dir / name).is_file():
            files.add(Path(name))

    return normalized, files


def json_ready(value):
    """tomllib gives dates and arrays; JSON needs plain values."""
    if isinstance(value, dict):
        return {key: json_ready(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_ready(item) for item in value]
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


@dataclass
class StandAssets:
    """What the stand part of the bundle needs: the characters with a `stand` entry,
    the outfit files to copy (package path → source path) and the rewritten lists."""

    characters: list[dict]
    files: dict[str, Path]
    lists: dict[str, dict]
    file_count: int

    @classmethod
    def empty(cls, characters: list[dict]) -> "StandAssets":
        return cls([dict(item) for item in characters], {}, {}, 0)


def outfit_category(outfit_id: str) -> str | None:
    """`stand` or `stand_costume` for a real outfit, None for chibi and anything else."""
    category, _, enza_id = outfit_id.partition("/")
    if category in STAND_CATEGORIES and enza_id:
        return category
    return None


def outfit_directory(stand_dir: Path, outfit_id: str) -> Path:
    return stand_dir / "source" / "assets" / "spine" / "idols" / outfit_id


def outfit_complete(directory: Path) -> bool:
    return all((directory / name).is_file() for name in STAND_FILES)


def _card_has(entry: dict, outfit_id: str) -> bool:
    return any((entry.get(key) or {}).get("id") == outfit_id for key in ("everyday", "stage"))


def _selected_cards(cards: list[dict], default_outfit: str, limit: int, all_outfits: bool) -> list[dict]:
    """The first `limit` cards, plus the card her default outfit is on, in list order."""
    if all_outfits:
        return list(cards)
    indices = set(range(min(max(limit, 0), len(cards))))
    for index, entry in enumerate(cards):
        if _card_has(entry, default_outfit):
            indices.add(index)
            break
    return [cards[index] for index in sorted(indices)]


def build_stand(
    characters: list[dict],
    stand_dir: Path | None,
    *,
    cards: int,
    all_outfits: bool,
) -> StandAssets:
    """Pack each character's default outfit and a slice of her outfit list.

    A character without an idol number, a default outfit, fetched files or a list is
    skipped, so exporting keeps working while the upstream sync is still running. Every
    outfit the packaged list names must have its three files: a list that points at
    nothing makes the whole export fail rather than produce a broken bundle.
    """
    if stand_dir is None:
        return StandAssets.empty(characters)
    stand_dir = Path(stand_dir)
    if not stand_dir.is_dir():
        die(f"找不到立绘整理目录 {stand_dir}")

    updated: list[dict] = []
    files: dict[str, Path] = {}
    lists: dict[str, dict] = {}
    for original in characters:
        item = dict(original)
        idol_id = item.get("idol_id")
        default_outfit = item.get("default_outfit")
        if (
            type(idol_id) is not int
            or idol_id <= 0
            or not isinstance(default_outfit, str)
            or outfit_category(default_outfit) is None
        ):
            updated.append(item)
            continue
        default_directory = outfit_directory(stand_dir, default_outfit)
        if not outfit_complete(default_directory):
            updated.append(item)
            continue
        list_path = stand_dir / "outfits" / f"{idol_id}.json"
        try:
            source_list = json.loads(list_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            print(
                f"warning: {item.get('name', item.get('id'))} 还没有衣装清单 {list_path}，不打包立绘",
                file=sys.stderr,
            )
            updated.append(item)
            continue
        if not isinstance(source_list.get("cards"), list):
            die(f"衣装清单 {list_path} 的 cards 不是列表")

        packaged_cards: list[dict] = []
        for entry in _selected_cards(
            source_list["cards"], default_outfit, cards, all_outfits
        ):
            packaged = dict(entry)
            for slot in ("everyday", "stage"):
                outfit = entry.get(slot)
                outfit_id = outfit.get("id") if isinstance(outfit, dict) else None
                if outfit_category(outfit_id or "") is None:
                    packaged[slot] = None
                    continue
                source_directory = outfit_directory(stand_dir, outfit_id)
                if not outfit_complete(source_directory):
                    die(
                        f"角色 {item['id']} 的衣装清单引用了 {outfit_id}，"
                        f"但 {source_directory} 缺文件"
                    )
                for name in STAND_FILES:
                    files[f"stand/idols/{outfit_id}/{name}"] = source_directory / name
                packaged[slot] = {
                    "id": outfit_id,
                    "url": f"../idols/{outfit_id}/",
                    # The app renders thumbnails itself; there are no thumbnail files
                    # in the bundle, so nothing may point at one.
                    "thumbnail": None,
                }
            if packaged["everyday"] is None and packaged["stage"] is None:
                continue
            packaged_cards.append(packaged)

        for name in STAND_FILES:
            files.setdefault(f"stand/idols/{default_outfit}/{name}", default_directory / name)

        package_list_path = f"stand/outfits/{idol_id}.json"
        lists[package_list_path] = {"idol_id": idol_id, "cards": packaged_cards}
        item["stand"] = {
            "default_outfit": {
                "id": default_outfit,
                "path": f"stand/idols/{default_outfit}/",
            },
            "outfits": package_list_path,
        }
        updated.append(item)

    return StandAssets(
        characters=updated,
        files=files,
        lists=lists,
        file_count=len(files) + len(lists),
    )



STAND_FORMAT_VERSION = 1


def stand_manifest(assets: StandAssets) -> dict:
    """The manifest of a self-contained stand bundle (ADR-0020).

    Paths are relative to the stand root: `idols/...` and `outfits/...`, not the content
    bundle's `stand/...` tree. Only characters with a packaged stand are listed.
    """
    characters = []
    for item in assets.characters:
        stand = item.get("stand")
        if not isinstance(stand, dict):
            continue
        default = stand.get("default_outfit")
        if not isinstance(default, dict):
            continue
        characters.append(
            {
                "id": item["id"],
                "stand": {
                    "default_outfit": {
                        "id": default["id"],
                        "path": default["path"],
                    },
                    "outfits": stand["outfits"],
                },
            }
        )
    return {
        "format_version": STAND_FORMAT_VERSION,
        "kind": "stand",
        "mode": "full",
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "characters": characters,
        "files": {},
    }


def read_stand_index(path: Path) -> dict[str, tuple[int, str | None]] | None:
    """Read the app's stand index (format 1); nil (with a warning) when it is unusable."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError) as error:
        print(f"warning: 读不了立绘清单 {path}：{error}；改为全量导出", file=sys.stderr)
        return None
    if document.get("format_version") != 1 or not isinstance(document.get("files"), dict):
        print(f"warning: 立绘清单 {path} 不是格式 1；改为全量导出", file=sys.stderr)
        return None
    result: dict[str, tuple[int, str | None]] = {}
    for package_path, record in document["files"].items():
        if not isinstance(record, dict) or type(record.get("size")) is not int:
            print(f"warning: 立绘清单里的 {package_path} 格式不对；改为全量导出", file=sys.stderr)
            return None
        crc = record.get("crc32")
        if crc is not None and not isinstance(crc, str):
            print(f"warning: 立绘清单里的 {package_path} 校验值格式不对；改为全量导出", file=sys.stderr)
            return None
        result[package_path] = (record["size"], crc)
    return result


def read_device_stand_index(
    device: str,
    bundle_id: str,
    *,
    timeout: int = 120,
) -> dict[str, tuple[int, str | None]] | None:
    """Copy the installed stand index off a connected iPhone with devicectl."""
    with tempfile.TemporaryDirectory() as scratch:
        destination = Path(scratch) / "stand-index.json"
        command = [
            "xcrun",
            "devicectl",
            "device",
            "copy",
            "from",
            "--device",
            device,
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            bundle_id,
            "--source",
            "Library/Application Support/Eidolon/Content/stand/index.json",
            "--destination",
            str(destination),
        ]
        try:
            completed = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"warning: 从设备读立绘清单失败：{error}；改为全量导出", file=sys.stderr)
            return None
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip() or f"devicectl 退出 {completed.returncode}"
            print(f"warning: 从设备读立绘清单失败：{detail}；改为全量导出", file=sys.stderr)
            return None
        if not destination.is_file():
            print("warning: 设备上没有立绘清单；改为全量导出", file=sys.stderr)
            return None
        return read_stand_index(destination)


def stand_file_record(path: Path) -> tuple[int, str]:
    data = path.read_bytes()
    return len(data), f"{zlib.crc32(data):08x}"


def changed_stand_files(
    assets: StandAssets,
    index: dict[str, tuple[int, str | None]],
) -> dict[str, Path]:
    """The source files the installed index does not already have, unchanged."""
    changed: dict[str, Path] = {}
    for package_path, source in assets.files.items():
        size, crc = stand_file_record(source)
        installed = index.get(package_path)
        if installed == (size, crc):
            continue
        changed[package_path] = source
    return changed


def write_stand_bundle(
    out_path: Path,
    assets: StandAssets,
    *,
    mode: str = "full",
    files: dict[str, Path] | None = None,
) -> None:
    """Write a stand bundle: its own manifest, outfit lists and stand files, no story."""
    if not assets.characters or not assets.file_count:
        die("没有可打包的立绘")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    manifest = stand_manifest(assets)
    manifest["mode"] = mode
    included = files if files is not None else assets.files
    with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for package_path in sorted(included):
            archive.write(included[package_path], package_path)
        for package_path in sorted(assets.lists):
            archive.writestr(
                package_path,
                json.dumps(assets.lists[package_path], ensure_ascii=False, indent=1),
            )
        manifest["files"] = {
            info.filename: {"size": info.file_size, "crc32": f"{info.CRC:08x}"}
            for info in archive.infolist()
        }
        archive.writestr(
            "manifest.json",
            json.dumps(manifest, ensure_ascii=False, indent=2),
        )

    digest = sha256_of(out_path)
    print(
        f"已写出 {out_path} （{out_path.stat().st_size / 1e6:.1f} MB，sha256 {digest[:16]}…）"
    )
    print(
        f"  立绘包 {len(manifest['characters'])} 位角色，"
        f"{len(included)} 个素材文件 + {len(assets.lists)} 份衣装清单（{mode}）"
    )


def write_bundle(
    out_path: Path,
    source_db: Path,
    characters: list[dict],
    character_files: set[Path],
    characters_dir: Path,
    stand: StandAssets | None = None,
) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        content_db = Path(scratch) / "eidolon.db"
        report = build_content_db(source_db, content_db)
        holiday_table = build_holidays()

        counts = dict(report["tables"])
        if stand is not None and stand.file_count:
            counts["stand"] = stand.file_count
        manifest = {
            "format_version": FORMAT_VERSION,
            "kind": "content",
            "content_schema_version": CONTENT_SCHEMA_VERSION,
            "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "embedding": {
                "model": report["embedding_model"],
                "dimensions": report["embedding_dimensions"],
            },
            "content": counts,
            "characters": {
                "count": len(characters),
                "ids": [item["id"] for item in characters],
            },
        }

        with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.write(content_db, "content/eidolon.db")
            archive.writestr(
                "content/holidays.json",
                json.dumps(
                    holiday_table,
                    ensure_ascii=False,
                    sort_keys=True,
                    separators=(",", ":"),
                ),
            )
            archive.writestr(
                "characters/characters.json",
                json.dumps(json_ready(characters), ensure_ascii=False, indent=2),
            )
            naming = {
                "world.json": "characters/world.json",
                "world-corrections.json": "characters/world-corrections.json",
                "readings.toml": "characters/readings.json",
                "gifts.toml": "characters/gifts.json",
                "drinks.toml": "characters/drinks.json",
                "bar_visits.toml": "characters/bar_visits.json",
                "bar_lines.toml": "characters/bar_lines.json",
                "bar_audio.json": "characters/bar_audio.json",
            }
            for relative in sorted(character_files):
                source = characters_dir / relative
                if relative.name in SHARED_FILES:
                    target = naming[relative.name]
                    if relative.suffix == ".toml":
                        with source.open("rb") as handle:
                            payload = json.dumps(
                                json_ready(tomllib.load(handle)), ensure_ascii=False, indent=2
                            )
                        archive.writestr(target, payload)
                    else:
                        archive.write(source, target)
                    continue
                archive.write(source, f"characters/{relative.as_posix()}")

            if stand is not None:
                for package_path in sorted(stand.files):
                    archive.write(stand.files[package_path], package_path)
                for package_path in sorted(stand.lists):
                    archive.writestr(
                        package_path,
                        json.dumps(stand.lists[package_path], ensure_ascii=False, indent=1),
                    )

            manifest["files"] = {
                info.filename: {"size": info.file_size, "crc32": f"{info.CRC:08x}"}
                for info in archive.infolist()
            }
            archive.writestr(
                "manifest.json",
                json.dumps(manifest, ensure_ascii=False, indent=2),
            )

    digest = sha256_of(out_path)
    tables = report["tables"]
    print(f"已写出 {out_path} （{out_path.stat().st_size / 1e6:.1f} MB，sha256 {digest[:16]}…）")
    print(
        f"  剧情 {tables['episodes']} 段，台词 {tables['episode_lines']} 行，"
        f"段落 {tables['episode_passages']} 个（{report['embedding_model']}，"
        f"{report['embedding_dimensions']} 维）"
    )
    print(f"  角色 {len(characters)} 位，附带文件 {len(character_files)} 个")
    if stand is not None and stand.file_count:
        print(f"  立绘 {len(stand.lists)} 位角色，{stand.file_count} 个文件")
    print(f"  日本节假日 {len(holiday_table)} 天（{HOLIDAY_YEARS.start}–{HOLIDAY_YEARS.stop - 1}）")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--upstream",
        type=Path,
        default=Path("../eidolon-sc"),
        help="上游仓库根目录（默认 ../eidolon-sc）",
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=None,
        help="上游数据库（默认 <upstream>/backend/data/eidolon.db）",
    )
    parser.add_argument(
        "--characters",
        type=Path,
        default=None,
        help="角色目录（默认 <upstream>/characters）",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="输出文件（内容包默认 build/eidolon-content.eidolonpkg，"
        "立绘包默认 build/eidolon-stand.eidolonpkg）",
    )
    parser.add_argument(
        "--stand",
        type=Path,
        default=None,
        help="立绘整理目录（上游 stand fetch / stand outfits 的产物，含 source/ 与 outfits/）；"
        "内容包不再带立绘，这条只配合 --stand-only 使用",
    )
    parser.add_argument(
        "--stand-cards",
        type=int,
        default=None,
        help="每位角色打包衣装清单里的前几张卡（内容包默认 3，立绘包默认全部；"
        "默认衣装所在的卡总会带上）",
    )
    parser.add_argument(
        "--stand-all-outfits",
        action="store_true",
        help="打包衣装清单里的全部衣装（不再按 --stand-cards 截取）",
    )
    parser.add_argument(
        "--stand-only",
        action="store_true",
        help="只导出立绘包；不给 --stand 时会报错，不需要数据库。立绘包默认打全部衣装",
    )
    parser.add_argument(
        "--device",
        default=None,
        help="从连接的 iPhone 读立绘清单，只导出缺失/变更的增量立绘包",
    )
    parser.add_argument(
        "--have",
        type=Path,
        default=None,
        help="从文件读立绘清单（App 导出的 stand-index.json），只导出增量",
    )
    parser.add_argument(
        "--bundle-id",
        default="com.jacklin.eidolon",
        help="App 的 bundle id（--device 用，默认 com.jacklin.eidolon）",
    )
    args = parser.parse_args()

    upstream = args.upstream.resolve()
    if not upstream.is_dir():
        die(f"找不到上游仓库 {upstream}")
    characters_dir = (args.characters or upstream / "characters").resolve()

    if args.device is not None and args.have is not None:
        die("--device 和 --have 只能给一个")
    if (args.device is not None or args.have is not None) and not args.stand_only:
        die("--device / --have 只能和 --stand-only 一起用")

    if args.stand_only:
        if args.stand is None:
            die("--stand-only 需要 --stand 指向立绘整理目录")
        characters, _ = load_characters(characters_dir)
        all_outfits = args.stand_all_outfits or args.stand_cards is None
        cards = args.stand_cards if args.stand_cards is not None else 0
        stand = build_stand(
            characters,
            args.stand.resolve(),
            cards=cards,
            all_outfits=all_outfits,
        )
        index = None
        if args.device is not None:
            index = read_device_stand_index(args.device, args.bundle_id)
        elif args.have is not None:
            index = read_stand_index(args.have)
        if index is None:
            out = (args.out or Path("build/eidolon-stand.eidolonpkg")).resolve()
            write_stand_bundle(out, stand)
            print("  清单不可用：已改为全量立绘包")
        else:
            changed = changed_stand_files(stand, index)
            out = (args.out or Path("build/eidolon-stand-add.eidolonpkg")).resolve()
            write_stand_bundle(out, stand, mode="delta", files=changed)
            print(f"  增量：{len(changed)} 个缺失/变更素材，{len(stand.lists)} 份衣装清单")
        return 0

    source_db = (args.db or upstream / "backend" / "data" / "eidolon.db").resolve()
    characters, character_files = load_characters(characters_dir)
    cards = args.stand_cards if args.stand_cards is not None else 3
    if args.stand is not None:
        die("内容包不再带立绘；请用 --stand-only 单独导出立绘包")
    stand = build_stand(
        characters,
        args.stand.resolve() if args.stand else None,
        cards=cards,
        all_outfits=args.stand_all_outfits,
    )
    out = (args.out or Path("build/eidolon-content.eidolonpkg")).resolve()
    write_bundle(
        out,
        source_db,
        stand.characters,
        character_files,
        characters_dir,
        stand,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
