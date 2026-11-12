"""Tests for tools/import_totsulover_story.py's pure text helpers."""
from __future__ import annotations

import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import import_totsulover_story as story  # noqa: E402


class StoryHelpersTests(unittest.TestCase):
    def test_normalize_strips_tags_and_spaces(self) -> None:
        self.assertEqual(story.normalize_text("「你好」<br>　世界"), "「你好」世界")

    def test_text_dat_records_are_id_keyed(self) -> None:
        def record(text: str, ident: int) -> bytes:
            return text.encode("cp932") + b"\0" + struct.pack("<I", ident)

        blob = b"_TEXT_LIST__" + struct.pack("<I", 3) + b"\0\0\0\0" + record("a", 1) + record("b", 2)
        rows = story.parse_text_dat(blob)
        self.assertEqual(rows, {1: "a", 2: "b"})

    def test_solid_png_is_a_png(self) -> None:
        payload = story.solid_png(4, (1, 2, 3))
        self.assertTrue(payload.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertIn(b"IEND", payload)


if __name__ == "__main__":
    unittest.main()


class StoryTextCleanupTests(unittest.TestCase):
    def test_controller_tags_do_not_reach_display_text(self) -> None:
        self.assertEqual(
            story.clean_for_text("你好<br><d0005>反现实</d>世界%0%10再见"),
            "你好反现实世界、、再见",
        )
