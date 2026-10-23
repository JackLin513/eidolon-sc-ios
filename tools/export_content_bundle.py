#!/usr/bin/env python3
"""Run upstream eidolon's story sync, then write a .eidolonpkg content bundle.

Reads the upstream checkout's SQLite database and characters/ directory, and
produces the read-only archive described in docs/adr/0003-content-bundle-format.md:

    manifest.json
    content/eidolon.db          — episodes, cast, lines and vectors only
    characters/characters.json  — characters.toml, paths rewritten package-relative
    characters/*.json|*.md|*.jpg

The user database (docs/adr/0002-content-and-user-databases.md) is never read.

Usage:
    python3 tools/export_content_bundle.py \
        --upstream ../eidolon-sc \
        --out build/eidolon-content.eidolonpkg
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys
import tempfile
import tomllib
import zipfile
from datetime import datetime, timezone
from pathlib import Path

FORMAT_VERSION = 1
CONTENT_SCHEMA_VERSION = 1

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
SHARED_FILES = ("world.json", "world-corrections.json", "readings.toml", "gifts.toml")


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


def write_bundle(
    out_path: Path,
    source_db: Path,
    characters: list[dict],
    character_files: set[Path],
    characters_dir: Path,
) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        content_db = Path(scratch) / "eidolon.db"
        report = build_content_db(source_db, content_db)

        manifest = {
            "format_version": FORMAT_VERSION,
            "content_schema_version": CONTENT_SCHEMA_VERSION,
            "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "embedding": {
                "model": report["embedding_model"],
                "dimensions": report["embedding_dimensions"],
            },
            "content": report["tables"],
            "characters": {
                "count": len(characters),
                "ids": [item["id"] for item in characters],
            },
        }

        with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.write(content_db, "content/eidolon.db")
            archive.writestr(
                "characters/characters.json",
                json.dumps(json_ready(characters), ensure_ascii=False, indent=2),
            )
            naming = {
                "world.json": "characters/world.json",
                "world-corrections.json": "characters/world-corrections.json",
                "readings.toml": "characters/readings.json",
                "gifts.toml": "characters/gifts.json",
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
        default=Path("build/eidolon-content.eidolonpkg"),
        help="输出文件（默认 build/eidolon-content.eidolonpkg）",
    )
    args = parser.parse_args()

    upstream = args.upstream.resolve()
    if not upstream.is_dir():
        die(f"找不到上游仓库 {upstream}")
    source_db = (args.db or upstream / "backend" / "data" / "eidolon.db").resolve()
    characters_dir = (args.characters or upstream / "characters").resolve()

    characters, character_files = load_characters(characters_dir)
    write_bundle(
        args.out.resolve(),
        source_db,
        characters,
        character_files,
        characters_dir,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
