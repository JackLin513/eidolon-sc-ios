#!/usr/bin/env python3
"""Build a local-only Sakura (夜乃桜 / totsulover) content bundle for testing.

The game assets live outside this repository. This tool reads them from
`Galgame support/sakura`, writes a temporary package under `build/`, and uses only
synthetic episode text so nothing copyrighted is committed. Run it on the machine
that owns the assets; the result is not for redistribution.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import struct
import zipfile
import zlib
from pathlib import Path

DEFAULT_SOURCE = Path.home() / "Developer/IdeaProjects/Galgame support/sakura"
DEFAULT_OUT = Path("build/eidolon-totsulover-sakura.eidolonpkg")
DEFAULT_STAND_OUT = Path("build/eidolon-totsulover-sakura-stand.eidolonpkg")
CONTENT_SET_ID = "totsulover.sakura.v1"
FRANCHISE = "totsulover"
CHARACTER = "sakura"
EMBEDDING_MODEL = "Qwen/Qwen3-Embedding-0.6B"
EMBEDDING_DIM = 1024


def crc32_hex(data: bytes) -> str:
    return f"{zlib.crc32(data) & 0xFFFFFFFF:08x}"


def write_episode_database(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.execute("PRAGMA user_version = 1")
    db.executescript(
        """
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
    )
    db.execute(
        "INSERT INTO episodes VALUES (?, '角色序章', 'sakura/fixture-1', 'はじまり', 'fixture', '2026-11-11T00:00:00Z')",
        ("sakura-e1",),
    )
    db.execute("INSERT INTO episode_cast VALUES (?, ?)", ("sakura-e1", CHARACTER))
    lines = [
        "……起動した。用事があるなら、呼んで。",
        "今日は、ちゃんと休め。",
        "無理をしている顔をしている。",
        "……少し、こちらを見て。",
        "水を飲んで。話はそれからだ。",
        "遅くまで起きていたでしょう。",
        "私はここにいる。画面の中だけど。",
        "……おかえり。待っていた。",
        "焦らなくていい。一緒に片付けよう。",
        "明日のことは、明日の私が考える。",
    ]
    for index, line in enumerate(lines, start=1):
        db.execute(
            "INSERT INTO episode_lines(episode_id, seq, speaker, ja, zh) VALUES (?, ?, ?, ?, ?)",
            ("sakura-e1", index, "桜", line, ""),
        )
    vector = struct.pack("<" + "f" * EMBEDDING_DIM, *([0.0] * EMBEDDING_DIM))
    db.execute(
        "INSERT INTO episode_passages(episode_id, seq, text, model, embedding) VALUES (?, 1, ?, ?, ?)",
        (
            "sakura-e1",
            "夜乃桜が目を覚まし、静かにこちらを見ている。",
            EMBEDDING_MODEL,
            vector,
        ),
    )
    db.commit()
    db.close()


def write_files(source: Path, staging: Path) -> None:
    card = (source / "card.md").read_text(encoding="utf-8")
    (staging / "characters/sheets").mkdir(parents=True, exist_ok=True)
    (staging / "characters/sheets/sakura.md").write_text(card, encoding="utf-8")

    portraits = sorted((source / "portraits").glob("*.png"))
    if not portraits:
        raise SystemExit(f"no portraits under {source / 'portraits'}")
    (staging / "content").mkdir(parents=True, exist_ok=True)
    (staging / "characters/avatars").mkdir(parents=True, exist_ok=True)
    # The default portrait is the app's avatar; the rest are kept for a later stand pack.
    (staging / "characters/avatars/sakura.png").write_bytes((source / "portraits/A020.png").read_bytes())

    characters = [
        {
            "id": CHARACTER,
            "name": "夜乃桜",
            "name_zh": "夜乃樱",
            "name_kana": "よの さくら",
            "name_romaji": "Yono Sakura",
            "unit": "学園",
            "intro": "冷静、孤高、责任感很强的学園生徒会長。",
            "color": "#b9d9ff",
            "voice_id": "sakura",
            "sheet": "characters/sheets/sakura.md",
            "avatar": "characters/avatars/sakura.png",
            "speakers": ["桜"],
            "idol_id": 1,
            # The source card carries no birthday; this placeholder is fixture metadata.
            "birthday": "01-01",
            "photo_tag": "yono sakura",
            "photo_appearance": "long silver hair, light blue eyes, white school uniform",
            "place_likes": ["cafe", "park"],
        }
    ]
    (staging / "characters/characters.json").write_text(
        json.dumps(characters, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (staging / "characters/places.json").write_text(
        json.dumps(
            {
                "places": [
                    {
                        "id": "cafe",
                        "name": "テストカフェ",
                        "area": "神奈川県横浜市",
                        "lat": 35.4657,
                        "lon": 139.6222,
                        "category": "cafe",
                        "note": "街角的咖啡馆。",
                        "checked": "2026-11-11",
                        "idols": [CHARACTER],
                    },
                    {
                        "id": "park",
                        "name": "テスト公園",
                        "area": "神奈川県横浜市",
                        "lat": 35.4700,
                        "lon": 139.6300,
                        "category": "park",
                        "note": "有长椅的公园。",
                        "checked": "2026-11-11",
                        "idols": [CHARACTER],
                    }
                ]
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    (staging / "characters/photo_tags.json").write_text(
        json.dumps(
            {
                "model": "test-image",
                "known": ["smile", "cafe", "indoors"],
                "rewrites": {},
                "allowed": ["smile"],
                "blocked": {"nudity": {"tags": ["nude"], "words": []}},
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    tone_source = source / "voice/refs/tone_refs"
    if tone_source.is_dir():
        (staging / "voice/tone_refs").mkdir(parents=True, exist_ok=True)
        for tone in sorted(tone_source.iterdir()):
            if tone.is_file():
                (staging / "voice/tone_refs" / tone.name).write_bytes(tone.read_bytes())
    (staging / "content/holidays.json").write_text(
        json.dumps({"2026-01-01": "元日", "2026-02-11": "建国記念の日"}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def manifest(staging: Path) -> dict:
    files = {}
    for path in sorted(staging.rglob("*")):
        if not path.is_file() or path.name == "manifest.json":
            continue
        rel = path.relative_to(staging).as_posix()
        data = path.read_bytes()
        files[rel] = {"size": len(data), "crc32": crc32_hex(data)}
    return {
        "format_version": 5,
        "kind": "content",
        "franchise": FRANCHISE,
        "engineFamily": "t-script",
        "contentSetID": CONTENT_SET_ID,
        "content_schema_version": 1,
        "created_at": "2026-11-11T00:00:00Z",
        "embedding": {"model": EMBEDDING_MODEL, "dimensions": EMBEDDING_DIM},
        "content": {
            "episodes": 1,
            "episode_cast": 1,
            "episode_lines": 10,
            "episode_passages": 1,
        },
        "characters": {
            "count": 1,
            "ids": [CHARACTER],
            "characterKeys": [f"{FRANCHISE}:{CHARACTER}"],
        },
        "files": files,
    }


def write_static_stand(source: Path, staging: Path) -> None:
    images = staging / "images"
    images.mkdir(parents=True, exist_ok=True)
    # The agreed Sakura A/A 7-emotion set, decoded from the game's S assets.
    seven = Path("build/sakura-7")
    portraits = sorted((source / "portraits").glob("*.png"))
    if not seven.is_dir() and not portraits:
        raise SystemExit(f"no portraits under {source / 'portraits'} and no {seven}")
    if seven.is_dir():
        for png in seven.glob("*.png"):
            (images / png.name).write_bytes(png.read_bytes())
        expressions = {name: f"{name}.png" for name in
                       ("calm", "angry", "shy", "thinking", "sad", "surprised", "happy")}
        bases = [{
            "id": "A.A", "outfit": "A", "pose": "A", "source": "S",
            "expressions": expressions,
        }]
    else:
        for portrait in portraits:
            (images / portrait.name).write_bytes(portrait.read_bytes())
        expressions = {
            "calm": "A020.png", "angry": "A140.png", "shy": "A081.png",
            "thinking": "I180.png", "sad": "A070.png", "surprised": "A150.png",
        }
        bases = []

    files = {}
    for path in sorted(staging.rglob("*")):
        if not path.is_file() or path.name == "manifest.json":
            continue
        rel = path.relative_to(staging).as_posix()
        data = path.read_bytes()
        files[rel] = {"size": len(data), "crc32": crc32_hex(data)}
    manifest = {
        "format_version": 2 if bases else 1,
        "kind": "stand",
        "mode": "full",
        "renderer": "static",
        "franchise": FRANCHISE,
        "contentSetID": CONTENT_SET_ID,
        "created_at": "2026-11-12T00:00:00Z",
        "characters": [
            {
                "id": CHARACTER,
                "characterKey": f"{FRANCHISE}:{CHARACTER}",
                "expressions": {
                    emotion: f"images/{filename}"
                    for emotion, filename in expressions.items()
                    if (images / filename).exists()
                },
                **({"bases": bases} if bases else {}),
            }
        ],
        "files": files,
    }
    (staging / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def zip_directory(staging: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(staging.rglob("*")):
            if path.is_file():
                zf.write(path, path.relative_to(staging).as_posix())


def main() -> None:
    global CONTENT_SET_ID
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--stand-out", type=Path, default=DEFAULT_STAND_OUT)
    parser.add_argument("--content-set-id", default=CONTENT_SET_ID)
    args = parser.parse_args()
    CONTENT_SET_ID = args.content_set_id
    source = args.source
    if not (source / "character.json").exists() or not (source / "card.md").exists():
        raise SystemExit(f"not a Sakura source directory: {source}")
    if not str(source.resolve()).startswith(str(Path.home())):
        raise SystemExit("refusing to read assets outside the local user tree")
    staging = args.out.parent / f".sakura-staging-{hashlib.sha256(str(args.out).encode()).hexdigest()[:8]}"
    if staging.exists():
        import shutil
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    try:
        write_files(source, staging)
        write_episode_database(staging / "content/eidolon.db")
        (staging / "manifest.json").write_text(
            json.dumps(manifest(staging), ensure_ascii=False, indent=2), encoding="utf-8"
        )
        zip_directory(staging, args.out)
        import shutil
        shutil.rmtree(staging)
        staging.mkdir(parents=True)
        write_static_stand(source, staging)
        zip_directory(staging, args.stand_out)
    finally:
        import shutil
        shutil.rmtree(staging, ignore_errors=True)
    print(args.out)
    print(f"{args.out.stat().st_size} bytes")
    print(args.stand_out)
    print(f"{args.stand_out.stat().st_size} bytes")


if __name__ == "__main__":
    main()
