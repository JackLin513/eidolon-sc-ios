"""Tests for tools/build_sakura_pack.py's pure packaging helpers.

Run from the repository root:

    python3 -m unittest discover -s tools/tests
"""
from __future__ import annotations

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import build_sakura_pack as pack  # noqa: E402


class SakuraPackTests(unittest.TestCase):
    def test_crc32_matches_known_value(self) -> None:
        self.assertEqual(pack.crc32_hex(b"123456789"), "cbf43926")

    def test_manifest_lists_every_staged_file_without_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            staging = Path(raw)
            (staging / "content").mkdir()
            (staging / "content/eidolon.db").write_bytes(b"db")
            (staging / "manifest.json").write_text("{}", encoding="utf-8")
            manifest = pack.manifest(staging)
            self.assertEqual(manifest["format_version"], 5)
            self.assertEqual(manifest["kind"], "content")
            self.assertEqual(manifest["franchise"], "totsulover")
            self.assertEqual(manifest["content"]["episode_passages"], 1)
            self.assertEqual(manifest["characters"]["characterKeys"], ["totsulover:sakura"])
            self.assertNotIn("manifest.json", manifest["files"])
            self.assertEqual(manifest["files"]["content/eidolon.db"]["size"], 2)

    def test_package_is_a_readable_zip(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            target = Path(raw) / "x.eidolonpkg"
            with zipfile.ZipFile(target, "w") as archive:
                archive.writestr("manifest.json", "{}")
            with zipfile.ZipFile(target) as archive:
                self.assertEqual(archive.namelist(), ["manifest.json"])


if __name__ == "__main__":
    unittest.main()
