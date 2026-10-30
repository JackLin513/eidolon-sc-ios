"""Tests for tools/export_bar_bundle.py's bar packaging.

Run offline from the repository root:

    python3 -m unittest discover -s tools/tests

The tests build a miniature upstream checkout (`frontend/public/bar/`), a
miniature extracted-audio directory and a `bar_audio.json`, then inspect what the
exporter would put in the bundle.
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import export_bar_bundle as exporter  # noqa: E402


def png_bytes(seed: int = 0) -> bytes:
    """A tiny PNG-shaped blob: the exporter copies bytes and never decodes them."""
    return b"\x89PNG\r\n\x1a\n" + bytes([seed % 256]) * 8


def stub_font_conversion(case: unittest.TestCase) -> None:
    """The tests' font files are not real faces. The woff2→ttf conversion is stood in for, so
    what the bundle carries is the same whether or not fontTools is installed."""
    original = exporter.convert_font
    case.addCleanup(setattr, exporter, "convert_font", original)

    def convert(source: Path, target: Path) -> Path:
        target.write_bytes(b"ttf")
        return target

    exporter.convert_font = convert


def stub_audio_conversion(case: unittest.TestCase) -> None:
    """The tests' audio files are not real Oggs. The Ogg→AAC step is stood in for, so what the
    bundle carries is the same whether or not ffmpeg is installed."""
    original = exporter.convert_audio
    case.addCleanup(setattr, exporter, "convert_audio", original)

    def convert(source: Path, target: Path) -> Path:
        target.write_bytes(b"m4a")
        return target

    exporter.convert_audio = convert


class BarSource:
    """A miniature upstream checkout plus an extracted-audio directory."""

    def __init__(self, root: Path):
        self.root = root
        self.upstream = root / "upstream"
        self.image_dir = self.upstream / "frontend" / "public" / "bar" / "img"
        self.font_dir = self.upstream / "frontend" / "public" / "bar" / "fonts"
        self.characters = self.upstream / "characters"
        self.audio = root / "valhalla" / "audio"
        for directory in (self.image_dir, self.font_dir, self.characters, self.audio):
            directory.mkdir(parents=True, exist_ok=True)

    def add_images(self, names=None, *, skip=()) -> None:
        for name in names or exporter.REQUIRED_IMAGES:
            if name in skip:
                continue
            (self.image_dir / name).write_bytes(png_bytes(len(name)))

    def add_fonts(self, skip=()) -> None:
        for name in exporter.FONT_FILES:
            if name in skip:
                continue
            (self.font_dir / name).write_bytes(f"font {name}".encode())

    def write_catalog(self, tracks, sfx, playlist=(1,)) -> exporter.AudioCatalog:
        (self.characters / "bar_audio.json").write_text(
            json.dumps(
                {
                    "tracks": tracks,
                    "default_playlist": list(playlist),
                    "sfx": sfx,
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        return exporter.AudioCatalog.load(self.characters / "bar_audio.json")

    def add_audio(self, files, *, skip=()) -> None:
        for name in files:
            if name in skip:
                continue
            (self.audio / name).write_bytes(f"audio {name}".encode())


TRACKS = [
    {"id": 32, "file": "032_hopes_and_dreams.ogg", "title": "Hopes and Dreams"},
    {"id": 2, "file": "002_a_neon_glow.ogg", "title": "A Neon Glow"},
]
SFX = [
    {"name": "addingredient", "file": "080_addingredient.ogg"},
    {"name": "iceadd", "file": "101_iceadd.ogg"},
]


class BuildAssetsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.source = BarSource(self.root)
        self.source.add_images()
        self.source.add_fonts()
        self.catalog = self.source.write_catalog(TRACKS, SFX)

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def test_collects_every_image_and_font(self) -> None:
        assets = exporter.build_assets(self.source.upstream, None, self.catalog)
        self.assertEqual(len(assets.images), len(exporter.REQUIRED_IMAGES))
        self.assertEqual(assets.missing_images, [])
        self.assertEqual(sorted(assets.fonts), sorted(exporter.FONT_FILES))

    def test_without_audio_every_track_is_missing(self) -> None:
        assets = exporter.build_assets(self.source.upstream, None, self.catalog)
        self.assertEqual(assets.tracks, [])
        self.assertEqual(assets.sfx, [])
        self.assertEqual(assets.missing_tracks, [t["file"] for t in TRACKS])
        self.assertEqual(assets.missing_sfx, [s["file"] for s in SFX])

    def test_audio_directory_fills_tracks_and_reports_the_rest(self) -> None:
        self.source.add_audio(
            [t["file"] for t in TRACKS] + [s["file"] for s in SFX],
            skip={SFX[1]["file"]},
        )
        assets = exporter.build_assets(self.source.upstream, self.source.audio, self.catalog)
        self.assertEqual([entry["id"] for entry, _ in assets.tracks], [32, 2])
        self.assertEqual([entry["name"] for entry, _ in assets.sfx], ["addingredient"])
        self.assertEqual(assets.missing_tracks, [])
        self.assertEqual(assets.missing_sfx, [SFX[1]["file"]])

    def test_an_extra_image_is_carried_too(self) -> None:
        self.source.add_images(names=["drink_srush.png"])
        assets = exporter.build_assets(self.source.upstream, None, self.catalog)
        self.assertIn("drink_srush.png", assets.images)
        self.assertEqual(assets.missing_images, [])

    def test_a_required_image_cannot_be_absent(self) -> None:
        for name in exporter.REQUIRED_IMAGES:
            if name != "frame.png":
                (self.source.image_dir / name).unlink()
        with redirect_stderr(io.StringIO()) as errors, self.assertRaises(SystemExit):
            exporter.build_assets(self.source.upstream, None, self.catalog)
        self.assertIn("frame.png", errors.getvalue())

    def test_no_images_at_all_is_fatal(self) -> None:
        for name in exporter.REQUIRED_IMAGES:
            (self.source.image_dir / name).unlink()
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            exporter.build_assets(self.source.upstream, None, self.catalog)

    def test_missing_fonts_are_reported_not_fatal(self) -> None:
        (self.source.font_dir / exporter.FONT_FILES[0]).unlink()
        assets = exporter.build_assets(self.source.upstream, None, self.catalog)
        self.assertEqual(assets.missing_fonts, [exporter.FONT_FILES[0]])
        self.assertEqual(assets.images != {}, True)


class WriteBundleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.source = BarSource(self.root)
        self.source.add_images()
        self.source.add_fonts()
        self.catalog = self.source.write_catalog(TRACKS, SFX)
        self.out = self.root / "build" / "eidolon-bar.eidolonpkg"
        stub_font_conversion(self)
        stub_audio_conversion(self)

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def write(self, *, audio: bool, stamp: str = "2026-01-01T00:00:00+00:00") -> dict:
        if audio:
            self.source.add_audio([t["file"] for t in TRACKS] + [s["file"] for s in SFX])
        audio_dir = self.source.audio if audio else None
        assets = exporter.build_assets(self.source.upstream, audio_dir, self.catalog)
        return exporter.write_bundle(self.out, assets, self.catalog, stamp=stamp)

    def test_manifest_says_bar_and_lists_files(self) -> None:
        manifest = self.write(audio=True)
        self.assertEqual(manifest["kind"], "bar")
        self.assertEqual(manifest["format_version"], exporter.FORMAT_VERSION)
        self.assertEqual(manifest["images"], len(exporter.REQUIRED_IMAGES))
        self.assertEqual(manifest["tracks"], [32, 2])
        self.assertEqual(manifest["sfx"], ["addingredient", "iceadd"])
        with zipfile.ZipFile(self.out) as archive:
            names = set(archive.namelist())
        self.assertIn("bar/img/frame.png", names)
        self.assertIn("bar/fonts/fusion-pixel-12px-zh_hans.ttf", names)
        self.assertIn("bar/audio/tracks/032_hopes_and_dreams.m4a", names)
        self.assertIn("bar/audio/sfx/101_iceadd.m4a", names)
        self.assertEqual(set(manifest["files"]), names - {"manifest.json"})
        self.assertEqual(
            sorted(manifest["fonts"]),
            ["bar/fonts/OFL-fusion-pixel.txt", "bar/fonts/fusion-pixel-12px-zh_hans.ttf"],
        )

    def test_a_font_that_cannot_be_converted_is_not_claimed(self) -> None:
        # 转不成 ttf 的那份就不进包，清单里也不写它：清单只说自己带了什么。
        exporter.convert_font = lambda source, target: None
        manifest = self.write(audio=False)
        with zipfile.ZipFile(self.out) as archive:
            names = archive.namelist()
        self.assertFalse([name for name in names if name.endswith(".ttf")])
        self.assertEqual(manifest["fonts"], ["bar/fonts/OFL-fusion-pixel.txt"])

    def test_without_audio_the_bundle_still_has_pictures_and_fonts(self) -> None:
        manifest = self.write(audio=False)
        self.assertEqual(manifest["tracks"], [])
        self.assertEqual(manifest["sfx"], [])
        with zipfile.ZipFile(self.out) as archive:
            names = set(archive.namelist())
        self.assertIn("bar/img/frame.png", names)
        self.assertFalse([name for name in names if name.startswith("bar/audio/")])

    def test_manifest_records_size_and_crc(self) -> None:
        manifest = self.write(audio=False)
        payload = png_bytes(len("frame.png"))
        entry = manifest["files"]["bar/img/frame.png"]
        self.assertEqual(entry["size"], len(payload))
        with zipfile.ZipFile(self.out) as archive:
            self.assertEqual(entry["crc32"], f"{archive.getinfo('bar/img/frame.png').CRC:08x}")

    def test_same_input_writes_the_same_bytes(self) -> None:
        self.write(audio=True)
        first = self.out.read_bytes()
        self.write(audio=True)
        self.assertEqual(first, self.out.read_bytes())

    def test_a_repeated_audio_file_is_stored_once(self) -> None:
        catalog = self.source.write_catalog(
            TRACKS,
            [
                {"name": "a", "file": TRACKS[0]["file"]},
                {"name": "b", "file": TRACKS[0]["file"]},
            ],
        )
        self.source.add_audio([TRACKS[0]["file"]])
        assets = exporter.build_assets(self.source.upstream, self.source.audio, catalog)
        exporter.write_bundle(self.out, assets, catalog, stamp="2026-01-01T00:00:00+00:00")
        with zipfile.ZipFile(self.out) as archive:
            names = archive.namelist()
        self.assertEqual(names.count("bar/audio/sfx/032_hopes_and_dreams.m4a"), 1)

    def test_audio_that_cannot_be_converted_is_not_claimed(self) -> None:
        # 手机上放不了 Ogg，转不出来就不进包；清单只写真的带进去的那几首。
        original = exporter.convert_audio
        self.addCleanup(setattr, exporter, "convert_audio", original)

        def convert(source: Path, target: Path) -> Path | None:
            if "neon" in source.name:
                return None
            target.write_bytes(b"m4a")
            return target

        exporter.convert_audio = convert
        manifest = self.write(audio=True)

        self.assertEqual(manifest["tracks"], [32])
        self.assertEqual(manifest["sfx"], ["addingredient", "iceadd"])
        with zipfile.ZipFile(self.out) as archive:
            names = set(archive.namelist())
        self.assertIn("bar/audio/tracks/032_hopes_and_dreams.m4a", names)
        self.assertFalse([name for name in names if "neon" in name])

    def test_catalog_reads_upstreams_toml(self) -> None:
        (self.source.characters / "bar_audio.toml").write_text(
            "\n".join(
                [
                    "default_playlist = [32]",
                    "",
                    "[[tracks]]",
                    'id = 32',
                    'file = "032_hopes_and_dreams.ogg"',
                    'title = "Hopes and Dreams"',
                    "",
                    "[[sfx]]",
                    'name = "addingredient"',
                    'file = "080_addingredient.ogg"',
                    "",
                    "default_playlist = [32]",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        catalog = exporter.AudioCatalog.load(self.source.characters / "bar_audio.toml")
        self.assertEqual(catalog.tracks[0]["id"], 32)
        self.assertEqual(catalog.sfx[0]["name"], "addingredient")
        self.assertEqual(catalog.default_playlist, [32])


class ReportTests(unittest.TestCase):
    def test_missing_audio_does_not_fail_the_export(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            source = BarSource(root)
            source.add_images()
            source.add_fonts()
            catalog = source.write_catalog(TRACKS, SFX)
            stub_font_conversion(self)
            assets = exporter.build_assets(source.upstream, None, catalog)
            out = root / "bar.eidolonpkg"
            manifest = exporter.write_bundle(out, assets, catalog, stamp="2026-01-01T00:00:00+00:00")
            stream = io.StringIO()
            with redirect_stdout(stream), redirect_stderr(stream):
                exporter.report(out, manifest, assets, catalog)
            self.assertIn("没有音频", stream.getvalue())
            self.assertIn("点唱机变灰", stream.getvalue())
            self.assertTrue(out.is_file())


if __name__ == "__main__":
    unittest.main()
