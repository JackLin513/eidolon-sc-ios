#!/usr/bin/env python3
"""Write a `.eidolonpkg` bar bundle: the bar's pictures, its font and its sound.

The bar is a separate package beside the content and stand bundles
(`kind: bar`, docs/design/bar-room.md). It carries:

    manifest.json
    bar/img/*.png                 — the bar's sprites, as upstream draws them
    bar/fonts/fusion-pixel-12px-zh_hans.woff2  — 缝合像素 (OFL)
    bar/fonts/OFL-fusion-pixel.txt             — its licence
    bar/audio/tracks/<file>       — the jukebox's tracks, as characters/bar_audio.json lists them
    bar/audio/sfx/<file>          — the bar's sound effects, likewise

Pictures and fonts come from the upstream checkout's `frontend/public/bar/`
(upstream's `frontend/scripts/bar-assets.py` made them from the original's
extracted files and replaced the frame's logo with 「VA-283」). Audio comes from
the original's extracted directory, `--audio <原版提取目录>/audio`: the tracks
and effects are the original game's, so they are not in this repository. Without
`--audio` the bundle still installs; the app's jukebox then stays grey and the
bar plays no sound effect.

The manifest lists the tracks and effects actually packaged, which is what the
app compares against `characters/bar_audio.json` before playing anything. Audio
files the catalog names but the directory lacks are reported and skipped.

Usage:
    python3 tools/export_bar_bundle.py --upstream ../eidolon-sc \\
        --audio <原版提取目录>/audio --out build/eidolon-bar.eidolonpkg
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

FORMAT_VERSION = 1

# The pictures the bar cannot do without: the frame, the counter's bottles and the mixer's
# parts. A bundle missing any of them is a broken export, not a smaller bundle.
REQUIRED_IMAGES = (
    "frame.png",
    "barground.png",
    "fan.png",
    "scanlines.png",
    "shaker.png",
    "ice.png",
    "age.png",
    "reset.png",
    "mix_yes.png",
    "mix_no.png",
    "slot.png",
    "gauge.png",
    "gauge_on.png",
    "arrow_0.png",
    "intro_0.png",
    "recipe_intro.png",
    "recipe_bg.png",
    "recipe_1.png",
    "juke_frame.png",
    "juke_startup.png",
    "juke_slot_blue.png",
    "juke_slot_red.png",
    "juke_ready_red.png",
    "juke_ready_green.png",
    "juke_loop.png",
    "juke_shuffle.png",
    "juke_small_paused.png",
    "juke_small_playing.png",
    "set_frame.png",
    "set_bgm.png",
    "set_bgm_slide.png",
    "set_sfx.png",
    "set_sfx_slide.png",
    "set_knob.png",
    "set_scan_on.png",
    "set_scan_off.png",
) + tuple(f"ing_{code}.png" for code in "abdfk") + tuple(f"cell_{code}.png" for code in "abdfk")

# The font the bar draws every line with (upstream `bar.css`'s `@font-face`), and its licence.
FONT_FILES = ("fusion-pixel-12px-zh_hans.woff2", "OFL-fusion-pixel.txt")

TRACKS_DIRECTORY = "bar/audio/tracks/"
SFX_DIRECTORY = "bar/audio/sfx/"
AUDIO_FORMAT = ".m4a"
"""The audio goes into the bundle as AAC (`.m4a`), not as the extracted Ogg.

iOS's Core Audio has no Ogg Vorbis decoder: `AVAudioPlayer` refuses every `.ogg` and the bar
plays silent however complete the pack is. The catalog beside the character configuration
still names the original `.ogg` files; the app reads a track as the file it finds, so the same
stem with this extension is what it plays."""


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def warn(message: str) -> None:
    print(f"警告：{message}", file=sys.stderr)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def json_ready(value):
    """tomllib gives dates and arrays; JSON needs plain values."""
    if isinstance(value, dict):
        return {key: json_ready(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_ready(item) for item in value]
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return value


@dataclass
class AudioCatalog:
    """`characters/bar_audio.json`: the jukebox's tracks, the default playlist, the effects."""

    tracks: list[dict] = field(default_factory=list)
    default_playlist: list[int] = field(default_factory=list)
    sfx: list[dict] = field(default_factory=list)

    @classmethod
    def load(cls, path: Path) -> "AudioCatalog":
        """The catalog as the content bundle carries it, or upstream's `.toml` source."""
        if not path.is_file():
            die(f"找不到音频清单 {path}")
        if path.suffix == ".json":
            data = json.loads(path.read_text(encoding="utf-8"))
        else:
            import tomllib

            with path.open("rb") as handle:
                data = json_ready(tomllib.load(handle))
        tracks = [
            {"id": int(track["id"]), "file": str(track["file"]), "title": str(track["title"])}
            for track in data.get("tracks", [])
        ]
        sfx = [
            {"name": str(item["name"]), "file": str(item["file"])}
            for item in data.get("sfx", [])
        ]
        return cls(
            tracks=tracks,
            default_playlist=[int(item) for item in data.get("default_playlist", [])],
            sfx=sfx,
        )


@dataclass
class BarAssets:
    images: dict[str, Path] = field(default_factory=dict)
    fonts: dict[str, Path] = field(default_factory=dict)
    tracks: list[tuple[dict, Path]] = field(default_factory=list)
    sfx: list[tuple[dict, Path]] = field(default_factory=list)
    missing_images: list[str] = field(default_factory=list)
    missing_fonts: list[str] = field(default_factory=list)
    missing_tracks: list[str] = field(default_factory=list)
    missing_sfx: list[str] = field(default_factory=list)


def collect_images(bar_dir: Path) -> tuple[dict[str, Path], list[str]]:
    image_dir = bar_dir / "img"
    if not image_dir.is_dir():
        die(f"找不到酒吧素材 {image_dir}")
    images = {path.name: path for path in sorted(image_dir.glob("*.png"))}
    missing = [name for name in REQUIRED_IMAGES if name not in images]
    return images, missing


def collect_fonts(bar_dir: Path) -> tuple[dict[str, Path], list[str]]:
    font_dir = bar_dir / "fonts"
    fonts = {
        name: font_dir / name
        for name in FONT_FILES
        if (font_dir / name).is_file()
    }
    missing = [name for name in FONT_FILES if name not in fonts]
    return fonts, missing


def collect_audio(
    audio_dir: Path | None, catalog: AudioCatalog
) -> tuple[list[tuple[dict, Path]], list[tuple[dict, Path]], list[str], list[str]]:
    """The track and effect files the catalog lists and the directory has, and the rest."""
    if audio_dir is None:
        return [], [], [track["file"] for track in catalog.tracks], [
            item["file"] for item in catalog.sfx
        ]
    if not audio_dir.is_dir():
        die(f"找不到音频目录 {audio_dir}")

    def present(entries: list[dict]) -> tuple[list[tuple[dict, Path]], list[str]]:
        found, missing = [], []
        for entry in entries:
            path = audio_dir / entry["file"]
            if path.is_file():
                found.append((entry, path))
            else:
                missing.append(entry["file"])
        return found, missing

    tracks, missing_tracks = present(catalog.tracks)
    sfx, missing_sfx = present(catalog.sfx)
    return tracks, sfx, missing_tracks, missing_sfx


def build_assets(
    upstream: Path | None, audio_dir: Path | None, catalog: AudioCatalog
) -> BarAssets:
    assets = BarAssets()
    if upstream is not None:
        bar_dir = upstream / "frontend" / "public" / "bar"
        assets.images, assets.missing_images = collect_images(bar_dir)
        assets.fonts, assets.missing_fonts = collect_fonts(bar_dir)
    else:
        assets.missing_images = list(REQUIRED_IMAGES)
        assets.missing_fonts = list(FONT_FILES)
    assets.tracks, assets.sfx, assets.missing_tracks, assets.missing_sfx = collect_audio(
        audio_dir, catalog
    )
    if not assets.images:
        die("还没有画面素材：用 --upstream 指向上游 checkout（frontend/public/bar/）")
    absent = [name for name in REQUIRED_IMAGES if name not in assets.images]
    if absent:
        die("画面素材缺少 " + "、".join(absent) + "（上游 checkout 版本过旧？）")
    return assets


def write_bundle(
    out_path: Path,
    assets: BarAssets,
    catalog: AudioCatalog,
    *,
    stamp: str | None = None,
) -> dict:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    manifest = {
        "format_version": FORMAT_VERSION,
        "kind": "bar",
        "created_at": stamp or datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "images": len(assets.images),
        "fonts": sorted(assets.fonts),
        "tracks": [],
        "sfx": [],
    }

    with tempfile.TemporaryDirectory() as scratch:
        # A fixed timestamp on every entry makes two runs over the same files byte-identical.
        date_time = (1980, 1, 1, 0, 0, 0)
        with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            def add(source: Path, target: str) -> None:
                info = zipfile.ZipInfo(target, date_time=date_time)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                archive.writestr(info, source.read_bytes())

            for name, path in sorted(assets.images.items()):
                add(path, f"bar/img/{name}")
            packaged_fonts: list[str] = []
            for name, path in sorted(assets.fonts.items()):
                if name.endswith(".woff2"):
                    # iOS's Core Text does not read woff2; the same face goes in as a
                    # TrueType font, so the bar's text is the pixel font on the phone.
                    target = f"bar/fonts/{Path(name).stem}.ttf"
                    source = convert_font(path, Path(scratch) / f"{Path(name).stem}.ttf")
                    if source is not None:
                        add(source, target)
                        packaged_fonts.append(target)
                        continue
                    warn(f"{name} 转不成 ttf：酒吧文字改用等宽系统字体")
                    continue
                add(path, f"bar/fonts/{name}")
                packaged_fonts.append(f"bar/fonts/{name}")
            def convert_and_add(path: Path, folder: str, name: str) -> bool:
                target = folder + Path(name).stem + AUDIO_FORMAT
                if target in seen:
                    return True
                seen.add(target)
                converted = convert_audio(path, Path(scratch) / (Path(name).stem + AUDIO_FORMAT))
                if converted is None:
                    warn(f"{name} 转不成 {AUDIO_FORMAT}：包里不收这一份")
                    return False
                add(converted, target)
                return True

            seen: set[str] = set()
            packaged_tracks = [
                entry for entry, path in assets.tracks
                if convert_and_add(path, TRACKS_DIRECTORY, entry["file"])
            ]
            packaged_sfx = [
                entry for entry, path in assets.sfx
                if convert_and_add(path, SFX_DIRECTORY, entry["file"])
            ]
            manifest["tracks"] = [int(entry["id"]) for entry in packaged_tracks]
            manifest["sfx"] = [str(entry["name"]) for entry in packaged_sfx]

            manifest["files"] = {
                info.filename: {"size": info.file_size, "crc32": f"{info.CRC:08x}"}
                for info in archive.infolist()
            }
            # What is in the bundle, not what was upstream: a woff2 that could not be made a
            # ttf is not named here, so the manifest never claims a font it does not carry.
            manifest["fonts"] = packaged_fonts
            archive.writestr(
                "manifest.json",
                json.dumps(manifest, ensure_ascii=False, indent=2),
            )
    return manifest


def convert_font(source: Path, target: Path) -> Path | None:
    """``source`` as a TrueType font at ``target``, or None if it cannot be made one here.

    None covers both no converter at hand and a face that cannot be read: either way the
    bundle goes out without a pixel font rather than with a broken one.
    """
    try:
        from fontTools.ttLib import TTFont

        font = TTFont(source)
        font.flavor = None
        font.save(target)
    except Exception:
        return None
    return target


def convert_audio(source: Path, target: Path) -> Path | None:
    """``source`` as an AAC file at ``target``, or None if it cannot be made one here.

    None covers both no ffmpeg at hand and a file it cannot read: the bundle goes out without
    that track rather than with one the phone cannot play.
    """
    try:
        completed = subprocess.run(
            [
                "ffmpeg", "-v", "error", "-y", "-i", str(source),
                "-c:a", "aac", "-b:a", "160k", str(target),
            ],
            capture_output=True,
            timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0 or not target.is_file():
        return None
    return target


def report(out_path: Path, manifest: dict, assets: BarAssets, catalog: AudioCatalog) -> None:
    digest = sha256_of(out_path)
    print(
        f"已写出 {out_path} （{out_path.stat().st_size / 1e6:.1f} MB，sha256 {digest[:16]}…）"
    )
    print(f"  画面 {manifest['images']} 张，字体 {len(manifest['fonts'])} 份")
    print(f"  曲目 {len(manifest['tracks'])}/{len(catalog.tracks)} 首，音效 {len(manifest['sfx'])}/{len(catalog.sfx)} 个")
    if assets.missing_fonts:
        warn("缺字体 " + "、".join(assets.missing_fonts) + "：酒吧里的字会退成系统字体")
    if assets.missing_tracks:
        warn(f"缺 {len(assets.missing_tracks)} 首曲目（例如 {assets.missing_tracks[0]}）：点唱机只放有的")
    if assets.missing_sfx:
        warn(f"缺 {len(assets.missing_sfx)} 个音效（例如 {assets.missing_sfx[0]}）：酒吧不播这些")
    if not manifest["tracks"] and not manifest["sfx"]:
        print("  没有音频：包里只有画面和字体，App 里点唱机变灰、不播音效")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--upstream",
        type=Path,
        help="上游 checkout 的根目录，读 frontend/public/bar/（画面与字体）",
    )
    parser.add_argument(
        "--audio",
        type=Path,
        help="原版提取目录的 audio/，读 characters/bar_audio.json 里列出的曲目和音效",
    )
    parser.add_argument(
        "--catalog",
        type=Path,
        help="音频清单，默认 <upstream>/characters/bar_audio.toml",
    )
    parser.add_argument(
        "--out",
        type=Path,
        help="写出的包，默认 build/eidolon-bar.eidolonpkg",
    )
    parser.add_argument(
        "--stamp",
        help="写进 manifest 的创建时间（RFC 3339），测试用来复现同一份包",
    )
    args = parser.parse_args()

    upstream = args.upstream.resolve() if args.upstream else None
    if upstream is not None and not (upstream / "frontend" / "public" / "bar").is_dir():
        die(f"{upstream} 里没有 frontend/public/bar/，--upstream 要指向上游 checkout")
    catalog_path = args.catalog
    if catalog_path is None:
        if upstream is None:
            die("没有 --upstream 时要给 --catalog 指到 bar_audio.json（内容包里那份）")
        for candidate in ("bar_audio.json", "bar_audio.toml"):
            if (upstream / "characters" / candidate).is_file():
                catalog_path = upstream / "characters" / candidate
                break
        else:
            die(f"{upstream}/characters 里没有 bar_audio.json 或 bar_audio.toml")
    catalog = AudioCatalog.load(catalog_path.resolve())

    assets = build_assets(upstream, args.audio.resolve() if args.audio else None, catalog)
    out = (args.out or Path("build/eidolon-bar.eidolonpkg")).resolve()
    manifest = write_bundle(out, assets, catalog, stamp=args.stamp)
    report(out, manifest, assets, catalog)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
