"""Tests for tools/export_content_bundle.py's stand packaging.

Run offline from the repository root:

    python3 -m unittest discover -s tools/tests

The tests build a miniature stand sync directory (the upstream `stand fetch` /
`stand outfits` layout) and inspect what the exporter would put in the bundle.
"""

from __future__ import annotations

import json
import sqlite3
import struct
import sys
import tempfile
import unittest
import zipfile
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import export_content_bundle as exporter  # noqa: E402


OUTFIT_FILES = ("data.json", "data.atlas", "data.png")


def outfit(category: str, enza_id: str) -> dict:
    outfit_id = f"{category}/{enza_id}"
    return {
        "id": outfit_id,
        "url": f"../spine/idols/{outfit_id}/",
        "thumbnail": f"../thumbnails/{outfit_id}.png",
    }


def card(enza_id: str, name: str = "カード", kind: str = "P_SR", *, everyday=True, stage=True) -> dict:
    return {
        "id": enza_id,
        "name": name,
        "type": kind,
        "everyday": outfit("stand", enza_id) if everyday else None,
        "stage": outfit("stand_costume", enza_id) if stage else None,
    }


class StandSource:
    """A miniature `EIDOLON_STAND_BUILD_PATH` directory."""

    def __init__(self, root: Path):
        self.root = root
        self.source = root / "source"
        self.outfits = root / "outfits"
        self.outfits.mkdir(parents=True)

    def add_outfit(self, outfit_id: str, payload: bytes | None = None) -> None:
        directory = self.source / "assets" / "spine" / "idols" / outfit_id
        directory.mkdir(parents=True, exist_ok=True)
        for name in OUTFIT_FILES:
            (directory / name).write_bytes(payload or f"{outfit_id}/{name}".encode())

    def write_list(self, idol_id: int, cards: list[dict]) -> None:
        (self.outfits / f"{idol_id}.json").write_text(
            json.dumps({"idol_id": idol_id, "cards": cards}, ensure_ascii=False),
            encoding="utf-8",
        )

    def add_card(self, idol_id: int, entry: dict, *, files: bool = True) -> None:
        if files:
            for key in ("everyday", "stage"):
                if entry.get(key):
                    self.add_outfit(entry[key]["id"])

    def write_full_list(self, idol_id: int, cards: list[dict]) -> None:
        for entry in cards:
            self.add_card(idol_id, entry)
        self.write_list(idol_id, cards)


def character(**overrides) -> dict:
    item = {
        "id": "mano",
        "name": "櫻木真乃",
        "idol_id": 1,
        "default_outfit": "stand/1030010010",
    }
    item.update(overrides)
    return item


class BuildStandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.stand = StandSource(self.root / "stand")
        self.stand.add_outfit("stand/1030010010")
        self.stand.add_outfit("stand_costume/1030010010")

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def build(self, characters=None, *, cards=1, all_outfits=False):
        return exporter.build_stand(
            characters if characters is not None else [character()],
            self.stand.root,
            cards=cards,
            all_outfits=all_outfits,
        )

    def test_character_gets_default_outfit_and_list_paths(self) -> None:
        self.stand.write_full_list(1, [card("1030010010")])

        assets = self.build()

        self.assertEqual(
            assets.characters[0]["stand"],
            {
                "default_outfit": {
                    "id": "stand/1030010010",
                    "path": "stand/idols/stand/1030010010/",
                },
                "outfits": "stand/outfits/1.json",
            },
        )

    def test_every_packed_outfit_has_three_files_and_the_list(self) -> None:
        self.stand.write_full_list(1, [card("1030010010")])

        assets = self.build()

        self.assertEqual(
            set(assets.files),
            {
                "stand/idols/stand/1030010010/data.json",
                "stand/idols/stand/1030010010/data.atlas",
                "stand/idols/stand/1030010010/data.png",
                "stand/idols/stand_costume/1030010010/data.json",
                "stand/idols/stand_costume/1030010010/data.atlas",
                "stand/idols/stand_costume/1030010010/data.png",
            },
        )
        self.assertEqual(set(assets.lists), {"stand/outfits/1.json"})
        self.assertEqual(assets.file_count, 7)

    def test_list_urls_are_rewritten_relative_to_the_packaged_list_and_thumbnails_dropped(self) -> None:
        self.stand.write_full_list(1, [card("1030010010")])

        assets = self.build()

        entry = assets.lists["stand/outfits/1.json"]["cards"][0]
        self.assertEqual(entry["everyday"]["url"], "../idols/stand/1030010010/")
        self.assertEqual(entry["stage"]["url"], "../idols/stand_costume/1030010010/")
        self.assertIsNone(entry["everyday"]["thumbnail"])
        self.assertIsNone(entry["stage"]["thumbnail"])
        self.assertEqual(entry["id"], "1030010010")
        self.assertEqual(entry["name"], "カード")
        self.assertEqual(entry["type"], "P_SR")

    def test_first_cards_are_kept_and_the_rest_are_left_out(self) -> None:
        self.stand.write_full_list(
            1,
            [card("1030010010"), card("1030010020"), card("1030010030")],
        )

        assets = self.build(cards=2)

        listed = assets.lists["stand/outfits/1.json"]["cards"]
        self.assertEqual([entry["id"] for entry in listed], ["1030010010", "1030010020"])
        self.assertTrue(all("1030010030" not in path for path in assets.files))

    def test_default_outfit_on_a_later_card_is_always_packed(self) -> None:
        self.stand.add_outfit("stand/1030010030")
        self.stand.add_outfit("stand_costume/1030010030")
        self.stand.write_list(
            1,
            [
                card("1030010010"),
                card("1030010020"),
                card("1030010030", everyday=False),
            ],
        )

        assets = self.build(cards=1, characters=[character(default_outfit="stand_costume/1030010030")])

        listed = assets.lists["stand/outfits/1.json"]["cards"]
        self.assertEqual([entry["id"] for entry in listed], ["1030010010", "1030010030"])
        self.assertIn("stand/idols/stand_costume/1030010030/data.json", assets.files)
        self.assertIn("stand/idols/stand/1030010010/data.json", assets.files)

    def test_all_outfits_keeps_every_card(self) -> None:
        self.stand.write_full_list(
            1,
            [card("1030010010"), card("1030010020"), card("1030010030")],
        )

        assets = self.build(cards=1, all_outfits=True)

        listed = assets.lists["stand/outfits/1.json"]["cards"]
        self.assertEqual([entry["id"] for entry in listed], ["1030010010", "1030010020", "1030010030"])

    def test_chibi_outfits_are_left_out(self) -> None:
        chibi = {
            "id": "1030010090",
            "name": "ちび",
            "type": "P_SR",
            "everyday": {
                "id": "cb/1030010090",
                "url": "../spine/idols/cb/1030010090/",
                "thumbnail": None,
            },
            "stage": None,
        }
        self.stand.write_full_list(1, [card("1030010010"), chibi])

        assets = self.build(cards=5)

        listed = assets.lists["stand/outfits/1.json"]["cards"]
        self.assertEqual([entry["id"] for entry in listed], ["1030010010"])
        self.assertFalse(any("cb/" in path for path in assets.files))

    def test_one_missing_outfit_stops_the_export(self) -> None:
        self.stand.write_full_list(1, [card("1030010010")])
        # The list still references the stage costume, but its files never arrived.
        (self.stand.source / "assets" / "spine" / "idols" / "stand_costume" / "1030010010" / "data.png").unlink()

        with self.assertRaises(SystemExit):
            self.build()

    def test_character_without_idol_default_or_assets_is_skipped(self) -> None:
        self.stand.write_full_list(1, [card("1030010010")])
        characters = [
            character(id="no-idol", idol_id=None),
            character(id="no-default", default_outfit=None),
            character(id="no-art", default_outfit="stand/1099999999"),
            character(id="no-list", idol_id=99),
        ]

        assets = self.build(characters=characters)

        self.assertTrue(all("stand" not in item for item in assets.characters))
        self.assertEqual(assets.files, {})
        self.assertEqual(assets.lists, {})
        self.assertEqual(assets.file_count, 0)

    def test_no_stand_directory_leaves_characters_alone(self) -> None:
        character_before = character()
        assets = exporter.build_stand([character_before], None, cards=3, all_outfits=False)

        self.assertEqual(assets.characters, [character_before])
        self.assertEqual(assets.file_count, 0)


class BundleManifestTests(unittest.TestCase):
    """The packaged archive: manifest books, CRC records and the stand count."""

    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.stand = StandSource(self.root / "stand")
        self.stand.add_outfit("stand/1030010010")
        self.stand.add_outfit("stand_costume/1030010010")
        self.stand.write_full_list(1, [card("1030010010")])

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def make_content_db(self) -> Path:
        path = self.root / "eidolon.db"
        connection = sqlite3.connect(path)
        connection.executescript(exporter.CONTENT_SCHEMA)
        connection.execute(
            "INSERT INTO episodes(id, category, source, title, imported_from, imported_at)"
            " VALUES ('e1', 'P卡剧情', 'cards/mano/1', '第一话', 'csv', '2026-01-01T00:00:00Z')"
        )
        connection.execute("INSERT INTO episode_cast(episode_id, character_id) VALUES ('e1', 'mano')")
        connection.execute(
            "INSERT INTO episode_lines(episode_id, seq, speaker, ja, zh)"
            " VALUES ('e1', 1, '真乃', 'ほわっ', '呼哇')"
        )
        connection.execute(
            "INSERT INTO episode_passages(episode_id, seq, text, model, embedding)"
            " VALUES ('e1', 1, '真乃的段落', 'test-embed', ?)",
            (struct.pack("<f", 0.25),),
        )
        connection.commit()
        connection.close()
        return path

    def test_archive_books_every_stand_file_and_counts_them(self) -> None:
        characters = [character()]
        assets = exporter.build_stand(characters, self.stand.root, cards=1, all_outfits=False)
        original_holidays = exporter.build_holidays
        exporter.build_holidays = lambda: {"2026-01-01": "元日"}
        try:
            out = self.root / "bundle.eidolonpkg"
            exporter.write_bundle(
                out,
                self.make_content_db(),
                assets.characters,
                set(),
                self.root,
                assets,
            )
        finally:
            exporter.build_holidays = original_holidays

        with zipfile.ZipFile(out) as archive:
            names = set(archive.namelist())
            manifest = json.loads(archive.read("manifest.json"))
            stand_files = {name for name in names if name.startswith("stand/")}
            for name in stand_files:
                data = archive.read(name)
                record = manifest["files"][name]
                self.assertEqual(record["size"], len(data))
                self.assertEqual(record["crc32"], f"{zlib.crc32(data):08x}")
            self.assertIn("stand/idols/stand/1030010010/data.json", stand_files)
            self.assertIn("stand/outfits/1.json", stand_files)
            self.assertFalse(any(name.startswith("stand/thumbnails/") for name in stand_files))
            packaged_list = json.loads(archive.read("stand/outfits/1.json"))
            self.assertIsNone(packaged_list["cards"][0]["everyday"]["thumbnail"])
            self.assertEqual(manifest["format_version"], 2)
            self.assertEqual(manifest["content"]["stand"], assets.file_count)
            self.assertEqual(manifest["content"]["episodes"], 1)
            entry = json.loads(archive.read("characters/characters.json"))[0]
            self.assertEqual(entry["stand"]["default_outfit"]["id"], "stand/1030010010")
            self.assertEqual(entry["stand"]["outfits"], "stand/outfits/1.json")

    def test_archive_without_stand_keeps_the_old_shape(self) -> None:
        original_holidays = exporter.build_holidays
        exporter.build_holidays = lambda: {"2026-01-01": "元日"}
        try:
            out = self.root / "plain.eidolonpkg"
            exporter.write_bundle(
                out,
                self.make_content_db(),
                [character()],
                set(),
                self.root,
                None,
            )
        finally:
            exporter.build_holidays = original_holidays

        with zipfile.ZipFile(out) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            names = archive.namelist()
        self.assertNotIn("stand", manifest["content"])
        self.assertFalse(any(name.startswith("stand/") for name in names))


if __name__ == "__main__":
    unittest.main()
