#!/usr/bin/env python3
"""Build side-by-side review images: current 1024 atlas vs the 2x super-res atlas.

Both columns are shown at the same display size, taken as the 2x page size, so
the left column is what the app samples today (the GPU's bilinear filter, stood
in for by Pillow BILINEAR) and the right column is the real 2x texture at 1:1.

    python3 tools/stand-superres/make_preview.py \\
        --source <1024 stand dir> --superres <2x stand dir> --out <preview dir>

Outputs per stand:
    region_<name>.png   one crop, dark + checkerboard, left/right
    sheet_<stand>.png   every requested region stacked
    fullpage.png        the whole page at 2048, current vs 2x
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

import atlas_scale
import upscale_stand

DEFAULT_REGIONS = (
    "face",
    "hair_U",
    "hair_F_L",
    "eye_L",
    "mouth_open",
    "body",
)

BACKGROUND = (28, 26, 32)
LABEL = (240, 240, 245)


def font(size: int = 26):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:  # Pillow < 10.1
        return ImageFont.load_default()


def checkerboard(size: tuple[int, int], cell: int = 16) -> Image.Image:
    board = Image.new("RGB", size, (86, 86, 92))
    draw = ImageDraw.Draw(board)
    for y in range(0, size[1], cell):
        for x in range(0, size[0], cell):
            if (x // cell + y // cell) % 2 == 0:
                draw.rectangle((x, y, x + cell - 1, y + cell - 1), fill=(140, 140, 148))
    return board


def compose(crop: Image.Image, background: str) -> Image.Image:
    if background == "dark":
        canvas = Image.new("RGB", crop.size, BACKGROUND)
    else:
        canvas = checkerboard(crop.size)
    canvas.paste(crop, (0, 0), crop)
    return canvas


def labeled(canvas: Image.Image, title: str) -> Image.Image:
    """Label strip above a crop, shrinking the type when the crop is narrow."""
    strip_height = 34
    strip = Image.new("RGB", (canvas.width, strip_height), BACKGROUND)
    draw = ImageDraw.Draw(strip)
    size = 26
    while size > 12 and draw.textlength(title, font=font(size)) > canvas.width - 12:
        size -= 2
    draw.text((8, 4), title, fill=LABEL, font=font(size))
    out = Image.new("RGB", (canvas.width, canvas.height + strip_height), BACKGROUND)
    out.paste(strip, (0, 0))
    out.paste(canvas, (0, strip_height))
    return out


def region_crop(page: Image.Image, region: atlas_scale.Region) -> tuple[int, int, int, int] | None:
    rect = upscale_stand.region_rect(region)
    if rect is None:
        return None
    x, y, w, h = rect
    x = max(0, min(x, page.width - 1))
    y = max(0, min(y, page.height - 1))
    w = max(1, min(w, page.width - x))
    h = max(1, min(h, page.height - y))
    return x, y, w, h


def build_region(
    source: Image.Image,
    superres: Image.Image,
    region: atlas_scale.Region,
    factor: int,
    background: str,
) -> Image.Image | None:
    rect = region_crop(source, region)
    if rect is None:
        return None
    x, y, w, h = rect
    target = (w * factor, h * factor)
    current = source.crop((x, y, x + w, y + h)).resize(target, Image.BILINEAR)
    upgraded = superres.crop((x * factor, y * factor, (x + w) * factor, (y + h) * factor))
    if upgraded.size != target:
        upgraded = upgraded.resize(target, Image.BILINEAR)
    # Narrow crops cannot carry the full legend; the sheet header says it once.
    wide = target[0] >= 140
    left = labeled(
        compose(current, background),
        f"current 1024 - {region.name}" if wide else "current",
    )
    right = labeled(
        compose(upgraded, background),
        f"2x super-res - {region.name}" if wide else "2x",
    )
    gap = 12
    canvas = Image.new("RGB", (left.width + right.width + gap, left.height), BACKGROUND)
    canvas.paste(left, (0, 0))
    canvas.paste(right, (left.width + gap, 0))
    return canvas


def build_sheet(
    source: Image.Image, superres: Image.Image, regions: list[atlas_scale.Region], factor: int
) -> Image.Image:
    rows = []
    for region in regions:
        row = build_region(source, superres, region, factor, "dark")
        if row:
            rows.append(row)
    if not rows:
        raise SystemExit("no comparable regions")
    width = max(row.width for row in rows)
    legend_height = 42
    height = legend_height + sum(row.height + 8 for row in rows)
    sheet = Image.new("RGB", (width, height), BACKGROUND)
    ImageDraw.Draw(sheet).text(
        (8, 10),
        "left: current 1024 atlas sampled at 2x    right: 2x super-res at 1:1",
        fill=LABEL,
        font=font(22),
    )
    y = legend_height
    for row in rows:
        sheet.paste(row, (0, y))
        y += row.height + 8
    return sheet


def build_fullpage(source: Image.Image, superres: Image.Image, factor: int) -> Image.Image:
    target = (source.width * factor, source.height * factor)
    left = labeled(source.resize(target, Image.BILINEAR), "current 1024 sampled at 2x")
    right = labeled(superres.convert("RGB"), "2x super-res at 1:1")
    gap = 16
    canvas = Image.new("RGB", (left.width + right.width + gap, left.height), BACKGROUND)
    canvas.paste(left, (0, 0))
    canvas.paste(right, (left.width + gap, 0))
    return canvas


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Side-by-side crops: 1x atlas vs 2x atlas.")
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--superres", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--factor", type=int, default=2)
    parser.add_argument("--regions", default=",".join(DEFAULT_REGIONS))
    parser.add_argument("--name", help="output prefix (default: source directory name)")
    args = parser.parse_args(argv)

    source = upscale_stand.load_rgba(args.source / "data.png")
    superres = upscale_stand.load_rgba(args.superres / "data.png")
    atlas = atlas_scale.parse_atlas((args.source / "data.atlas").read_text(encoding="utf-8"))
    by_name = {region.name: region for page in atlas for region in page.regions}
    wanted = [name.strip() for name in args.regions.split(",") if name.strip()]
    selected = [by_name[name] for name in wanted if name in by_name]
    missing = [name for name in wanted if name not in by_name]
    if missing:
        raise SystemExit(f"regions not in atlas: {missing}")

    args.out.mkdir(parents=True, exist_ok=True)
    name = args.name or args.source.name
    written = []
    for region in selected:
        for background in ("dark", "checker"):
            image = build_region(source, superres, region, args.factor, background)
            if image is None:
                continue
            path = args.out / f"region_{name}_{region.name}_{background}.png"
            image.save(path)
            written.append(path)
    sheet = args.out / f"sheet_{name}.png"
    build_sheet(source, superres, selected, args.factor).save(sheet)
    written.append(sheet)
    full = args.out / f"fullpage_{name}.png"
    build_fullpage(source, superres, args.factor).save(full)
    written.append(full)
    for path in written:
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
