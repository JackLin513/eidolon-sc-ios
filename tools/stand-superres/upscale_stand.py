#!/usr/bin/env python3
"""2x a Spine 3.6 stand atlas with an alpha-aware upscaler, and scale its atlas to match.

The stand packs (`data.json`, `data.atlas`, `data.png`) are Spine 3.6. `data.png`
is 1024x1024 with alpha; `data.atlas` is text and carries page pixels; `data.json`
carries normalized UVs and is copied untouched.

The image is never handed to the upscaler as straight RGBA: transparent pixels
hold junk colour that bleeds into the sprite edge. Three colour modes exist:

    bleed          fill transparent pixels from their nearest solid neighbour,
                   then upscale straight colour (default: measured cleanest
                   silhouette, no dark fringe where alpha is partial)
    premultiplied  multiply colour by alpha, upscale, divide back out. Kept for
                   A/B: the divide uses a separately upscaled alpha, so partial
                   alpha pixels keep a dark fringe (see README measurements)
    straight       upscale the stored RGB as-is (junk colour under alpha=0
                   bleeds into the edge; kept for A/B)

Alpha itself is upscaled separately, either by the same model (`--alpha-mode
model`) or by Lanczos (`--alpha-mode lanczos`, default: sprite alpha is smooth
and the model tends to ring on hard masks).

Engines:

    realesrgan  `realesrgan-ncnn-vulkan` (Real-ESRGAN, BSD-3-Clause). Not part of
                this repository; point at a local copy with `--bin`/`--models` or
                `REALESRGAN_BIN`/`REALESRGAN_MODELS`. The `realesr-animevideov3`
                model upscales 2x natively; the x4 models run 4x and are boxed
                down to the requested factor.
    lanczos     Pillow LANCZOS + a mild unsharp mask. Not AI, labelled as such.

Usage, one stand:

    python3 tools/stand-superres/upscale_stand.py \\
        --src /tmp/stand/1030010010 --out tools/stand-superres/out/stand_1030010010 \\
        --bin /tmp/resrgan/realesrgan-ncnn-vulkan --models /tmp/resrgan/models

Batch (every directory under the source tree that has the three files):

    python3 tools/stand-superres/upscale_stand.py --batch <root> --out <dest> [...]

The output directory gets `data.png` (2x), `data.atlas` (scaled), `data.json`
(byte copy) and `superres.json` (engine, timings, validation). Nothing here
writes into the app bundle; assets are meant to stay out of git.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

import atlas_scale

# Native scale of each Real-ESRGAN ncnn model shipped in the 20220424 release.
MODEL_NATIVE_SCALE = {
    "realesr-animevideov3": 2,
    "realesrgan-x4plus": 4,
    "realesrgan-x4plus-anime": 4,
    "realesrnet-x4plus": 4,
}

DEFAULT_MODEL = "realesr-animevideov3"


class EngineError(RuntimeError):
    pass


@dataclass
class Stage:
    name: str
    seconds: float


# ---------------------------------------------------------------- image maths


def load_rgba(path: Path) -> Image.Image:
    with Image.open(path) as source:
        return source.convert("RGBA")


def premultiply(rgba: Image.Image) -> tuple[Image.Image, Image.Image]:
    """Return (premultiplied RGB, alpha) as 8-bit images."""
    array = np.asarray(rgba, dtype=np.float32)
    alpha = array[..., 3:4] / 255.0
    rgb = np.clip(np.rint(array[..., :3] * alpha), 0, 255).astype(np.uint8)
    alpha_u8 = np.asarray(rgba, dtype=np.uint8)[..., 3]
    return Image.fromarray(rgb, "RGB"), Image.fromarray(alpha_u8, "L")


def unpremultiply(rgb: Image.Image, alpha: Image.Image) -> Image.Image:
    rgb_array = np.asarray(rgb, dtype=np.float32)
    alpha_array = np.asarray(alpha, dtype=np.float32) / 255.0
    safe = alpha_array > (2.0 / 255.0)
    divisor = np.maximum(alpha_array[..., None], 1e-4)
    straight = np.clip(np.rint(rgb_array / divisor), 0, 255)
    straight = np.where(safe[..., None], straight, 0).astype(np.uint8)
    alpha_u8 = np.clip(np.rint(alpha_array * 255), 0, 255).astype(np.uint8)
    return Image.fromarray(np.dstack([straight, alpha_u8[..., None]]), "RGBA")


def bleed_fill(rgba: Image.Image, iterations: int = 6, min_alpha: int = 32) -> Image.Image:
    """Extend solid colour into transparent and near-transparent pixels.

    Each pass copies known colour into adjacent unknown pixels (8-connected),
    which gives the upscaler real colour to interpolate at the silhouette
    instead of the junk that straight-alpha textures store there. Pixels below
    `min_alpha` are treated as unknown even when their alpha is non-zero: the
    source atlases carry stray palette entries (an opaque red pixel at alpha 1,
    for instance) whose colour would otherwise be spread into the edge.
    """
    array = np.asarray(rgba, dtype=np.uint8).copy()
    known = array[..., 3] >= min_alpha
    colour = array[..., :3].astype(np.float32)
    for _ in range(iterations):
        if known.all():
            break
        fill = np.zeros_like(colour)
        weight = np.zeros(known.shape, dtype=np.float32)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                shifted_known = np.roll(np.roll(known, dy, axis=0), dx, axis=1)
                shifted_colour = np.roll(np.roll(colour, dy, axis=0), dx, axis=1)
                fill += np.where(shifted_known[..., None], shifted_colour, 0)
                weight += shifted_known
        grow = (~known) & (weight > 0)
        if not grow.any():
            break
        mean = np.divide(fill, np.maximum(weight[..., None], 1))
        colour = np.where(grow[..., None], mean, colour)
        known = known | grow
    out = np.dstack([np.clip(np.rint(colour), 0, 255), array[..., 3:4]]).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def lanczos(img: Image.Image, factor: float, sharpen: bool = True) -> Image.Image:
    size = (max(1, round(img.width * factor)), max(1, round(img.height * factor)))
    out = img.resize(size, Image.LANCZOS)
    if sharpen:
        out = out.filter(ImageFilter.UnsharpMask(radius=1.2, percent=45, threshold=2))
    return out


# ------------------------------------------------------------------- engines


class Engine:
    name = "?"
    is_ai = False

    def upscale_rgb(self, img: Image.Image, factor: float) -> Image.Image:
        raise NotImplementedError

    def describe(self) -> dict:
        return {"engine": self.name, "ai": self.is_ai}


class LanczosEngine(Engine):
    name = "lanczos"
    is_ai = False

    def upscale_rgb(self, img: Image.Image, factor: float) -> Image.Image:
        return lanczos(img, factor)


class RealesrganEngine(Engine):
    name = "realesrgan-ncnn-vulkan"
    is_ai = True

    def __init__(self, binary: Path, models: Path, model: str, tiles: int = 0):
        self.binary = binary
        self.models = models
        self.model = model
        self.tiles = tiles
        self.native_scale = MODEL_NATIVE_SCALE.get(model, 4)
        self.calls = 0

    def describe(self) -> dict:
        return {
            "engine": self.name,
            "ai": True,
            "model": self.model,
            "binary": str(self.binary),
            "models": str(self.models),
            "native_scale": self.native_scale,
        }

    def _run(self, rgb: Image.Image) -> Image.Image:
        with tempfile.TemporaryDirectory(prefix="sr-") as work:
            src = Path(work) / "in.png"
            dst = Path(work) / "out.png"
            rgb.save(src)
            command = [
                str(self.binary),
                "-i", str(src),
                "-o", str(dst),
                "-s", str(self.native_scale),
                "-n", self.model,
                "-m", str(self.models),
                "-f", "png",
                "-j", "1:2:2",
            ]
            if self.tiles:
                command += ["-t", str(self.tiles)]
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode != 0 or not dst.exists():
                raise EngineError(
                    f"{self.name} failed ({result.returncode}): "
                    f"{result.stderr.strip()[-600:]}"
                )
            self.calls += 1
            with Image.open(dst) as produced:
                return produced.convert("RGB")

    def upscale_rgb(self, img: Image.Image, factor: float) -> Image.Image:
        out = self._run(img)
        target = (round(img.width * factor), round(img.height * factor))
        if out.size != target:
            # 4x model asked for 2x: box-filter the extra factor. BOX averages
            # evenly, which suits premultiplied colour.
            out = out.resize(target, Image.BOX)
        return out


def find_engine(args: argparse.Namespace) -> Engine:
    choice = args.engine
    binary = args.bin or os.environ.get("REALESRGAN_BIN")
    models = args.models or os.environ.get("REALESRGAN_MODELS")
    here = Path(__file__).resolve().parent
    if not binary:
        local = here / ".tools" / "realesrgan-ncnn-vulkan"
        if local.exists():
            binary = str(local)
        else:
            binary = shutil.which("realesrgan-ncnn-vulkan")
    if not models and binary:
        candidate = Path(binary).parent / "models"
        models = str(candidate) if candidate.is_dir() else None
    if choice in ("auto", "realesrgan") and binary:
        if not models or not Path(models).is_dir():
            if choice == "realesrgan":
                raise SystemExit("--models is required (or REALESRGAN_MODELS)")
        else:
            return RealesrganEngine(Path(binary), Path(models), args.model, args.tiles)
    if choice == "realesrgan":
        raise SystemExit(
            "no realesrgan-ncnn-vulkan found; pass --bin/--models or use --engine lanczos"
        )
    return LanczosEngine()


# ------------------------------------------------------------------ pipeline


def upscale_stand_image(
    rgba: Image.Image,
    engine: Engine,
    factor: float,
    color_mode: str,
    alpha_mode: str,
) -> tuple[Image.Image, dict]:
    timings: list[float] = []

    start = time.perf_counter()
    alpha = rgba.getchannel("A")
    if color_mode == "premultiplied":
        rgb, _ = premultiply(rgba)
    elif color_mode == "bleed":
        rgb = bleed_fill(rgba).convert("RGB")
    elif color_mode == "straight":
        rgb = rgba.convert("RGB")
    else:
        raise SystemExit(f"unknown --color-mode {color_mode}")
    timings.append(time.perf_counter() - start)

    start = time.perf_counter()
    rgb_big = engine.upscale_rgb(rgb, factor)
    timings.append(time.perf_counter() - start)

    start = time.perf_counter()
    if alpha_mode == "model":
        alpha_big = engine.upscale_rgb(alpha.convert("RGB"), factor).getchannel("R")
    else:
        alpha_big = lanczos(alpha, factor, sharpen=False)
    timings.append(time.perf_counter() - start)

    start = time.perf_counter()
    if color_mode == "premultiplied":
        out = unpremultiply(rgb_big, alpha_big)
    else:
        out = Image.merge("RGBA", (*rgb_big.split(), alpha_big))
    timings.append(time.perf_counter() - start)

    meta = {
        "color_mode": color_mode,
        "alpha_mode": alpha_mode,
        "stage_seconds": {
            "premix": round(timings[0], 3),
            "colour_upscale": round(timings[1], 3),
            "alpha_upscale": round(timings[2], 3),
            "compose": round(timings[3], 3),
        },
    }
    return out, meta


def region_rect(region: atlas_scale.Region) -> tuple[int, int, int, int] | None:
    """Page-space rectangle a region occupies, as (x, y, w, h) in page pixels."""
    bounds = region.bounds()
    if bounds is None:
        return None
    x, y, w, h = bounds
    return int(round(x)), int(round(y)), int(round(w)), int(round(h))


def verify_regions(
    source_rgba: Image.Image,
    out_rgba: Image.Image,
    source_atlas: str,
    factor: float,
) -> dict:
    """Compare each region's scaled crop with the source crop, downscaled back.

    A geometry mistake (a coordinate left unscaled, or scaled twice) shows up as
    a large difference here, so this checks the atlas as much as the pixels.
    """
    worst = {"region": None, "mae": 0.0}
    total = 0
    count = 0
    for page in atlas_scale.parse_atlas(source_atlas):
        for region in page.regions:
            rect = region_rect(region)
            if rect is None:
                continue
            x, y, w, h = rect
            if w <= 0 or h <= 0:
                continue
            src = source_rgba.crop((x, y, x + w, y + h))
            bx, by = round(x * factor), round(y * factor)
            big = out_rgba.crop((bx, by, bx + round(w * factor), by + round(h * factor)))
            small = big.resize(src.size, Image.BOX)
            a = np.asarray(src, dtype=np.float32)
            b = np.asarray(small, dtype=np.float32)
            mae = float(np.abs(a - b).mean())
            total += mae
            count += 1
            if mae > worst["mae"]:
                worst = {"region": region.name, "mae": round(mae, 2)}
    return {
        "regions_compared": count,
        "mean_mae": round(total / count, 2) if count else None,
        "worst": worst,
    }


def alpha_outside_regions(rgba: Image.Image, atlas_text: str, factor: float) -> float:
    """Fraction of pixels with alpha>=8 that no scaled region covers."""
    mask = np.zeros((rgba.height, rgba.width), dtype=bool)
    for page in atlas_scale.parse_atlas(atlas_text):
        for region in page.regions:
            rect = region_rect(region)
            if rect is None:
                continue
            x, y, w, h = rect
            x0, y0 = round(x * factor), round(y * factor)
            x1, y1 = round((x + w) * factor), round((y + h) * factor)
            mask[max(0, y0):min(mask.shape[0], y1), max(0, x0):min(mask.shape[1], x1)] = True
    alpha = np.asarray(rgba.getchannel("A"))
    visible = alpha >= 8
    if not visible.any():
        return 0.0
    return float((visible & ~mask).sum()) / float(visible.sum())


def process_stand(
    source: Path,
    destination: Path,
    engine: Engine,
    factor: float,
    color_mode: str,
    alpha_mode: str,
    overwrite: bool,
) -> dict:
    png = source / "data.png"
    atlas_path = source / "data.atlas"
    json_path = source / "data.json"
    for required in (png, atlas_path, json_path):
        if not required.exists():
            raise SystemExit(f"{source}: missing {required.name}")
    if destination.exists() and not overwrite:
        raise SystemExit(f"{destination}: exists (pass --overwrite)")

    started = time.perf_counter()
    source_rgba = load_rgba(png)
    out_rgba, image_meta = upscale_stand_image(
        source_rgba, engine, factor, color_mode, alpha_mode
    )

    atlas_text = atlas_path.read_text(encoding="utf-8")
    scaled_atlas = atlas_scale.scale_atlas_text(atlas_text, factor)
    problems = atlas_scale.validate_atlas(scaled_atlas)

    destination.mkdir(parents=True, exist_ok=True)
    out_png = destination / "data.png"
    out_rgba.save(out_png, optimize=True, compress_level=9)
    (destination / "data.atlas").write_text(scaled_atlas, encoding="utf-8")
    shutil.copyfile(json_path, destination / "data.json")

    source_alpha = np.asarray(source_rgba.getchannel("A"))
    out_alpha = np.asarray(out_rgba.getchannel("A"))
    report = {
        "source": str(source),
        "output": str(destination),
        "factor": factor,
        "engine": engine.describe(),
        "image": {
            "source_size": list(source_rgba.size),
            "output_size": list(out_rgba.size),
            "source_mode": "RGBA",
            "source_alpha_extrema": [int(source_alpha.min()), int(source_alpha.max())],
            "output_alpha_extrema": [int(out_alpha.min()), int(out_alpha.max())],
            "semi_transparent_fraction_source": round(
                float(((source_alpha > 0) & (source_alpha < 255)).mean()), 4
            ),
            "semi_transparent_fraction_output": round(
                float(((out_alpha > 0) & (out_alpha < 255)).mean()), 4
            ),
            "content_bbox_source": list(source_rgba.getchannel("A").getbbox() or ()),
            "content_bbox_output": list(out_rgba.getchannel("A").getbbox() or ()),
        },
        "atlas": {
            "source_size": list(atlas_scale.parse_atlas(atlas_text)[0].size or ()),
            "scaled_size": list(atlas_scale.parse_atlas(scaled_atlas)[0].size or ()),
            "regions": atlas_scale.region_count(scaled_atlas),
            "validation_problems": problems,
            "min_region_gap_source": atlas_scale.min_gap(
                atlas_scale.parse_atlas(atlas_text)[0]
            ),
            "filter_header": next(
                (
                    line.strip()
                    for line in atlas_text.splitlines()
                    if line.strip().startswith("filter:")
                ),
                None,
            ),
            "region_check": verify_regions(
                source_rgba, out_rgba, atlas_text, factor
            ),
            "visible_alpha_outside_regions": round(
                alpha_outside_regions(out_rgba, atlas_text, factor), 5
            ),
        },
        "files": {
            "source_png_bytes": png.stat().st_size,
            "output_png_bytes": out_png.stat().st_size,
            "ratio": round(out_png.stat().st_size / max(1, png.stat().st_size), 2),
        },
        "timings": {
            **image_meta["stage_seconds"],
            "total_seconds": round(time.perf_counter() - started, 2),
        },
        "color_mode": color_mode,
        "alpha_mode": alpha_mode,
    }
    (destination / "superres.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return report


def find_stands(root: Path) -> list[Path]:
    found = []
    for png in sorted(root.rglob("data.png")):
        folder = png.parent
        if (folder / "data.atlas").exists() and (folder / "data.json").exists():
            found.append(folder)
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Upscale Spine 3.6 stand atlases 2x (alpha-aware) and scale their metadata."
    )
    parser.add_argument("--src", type=Path, help="directory with data.png/atlas/json")
    parser.add_argument("--batch", type=Path, help="root to scan for stand directories")
    parser.add_argument("--out", type=Path, required=True, help="output directory")
    parser.add_argument("--factor", type=float, default=2.0)
    parser.add_argument("--engine", choices=["auto", "realesrgan", "lanczos"], default="auto")
    parser.add_argument("--bin", type=Path, help="realesrgan-ncnn-vulkan binary")
    parser.add_argument("--models", type=Path, help="model directory")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--tiles", type=int, default=0)
    parser.add_argument(
        "--color-mode",
        choices=["bleed", "premultiplied", "straight"],
        default="bleed",
    )
    parser.add_argument("--alpha-mode", choices=["lanczos", "model"], default="lanczos")
    parser.add_argument("--limit", type=int, help="only the first N stands in batch mode")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args(argv)

    if bool(args.src) == bool(args.batch):
        parser.error("pass exactly one of --src or --batch")

    engine = find_engine(args)
    print(f"engine: {json.dumps(engine.describe())}", file=sys.stderr)

    if args.src:
        report = process_stand(
            args.src,
            args.out,
            engine,
            args.factor,
            args.color_mode,
            args.alpha_mode,
            args.overwrite,
        )
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0

    stands = find_stands(args.batch)
    if args.limit:
        stands = stands[: args.limit]
    if not stands:
        raise SystemExit(f"{args.batch}: no data.png/data.atlas/data.json found")
    failures = []
    for index, stand in enumerate(stands, 1):
        relative = stand.relative_to(args.batch)
        destination = args.out / relative
        print(f"[{index}/{len(stands)}] {relative}", file=sys.stderr)
        try:
            report = process_stand(
                stand,
                destination,
                engine,
                args.factor,
                args.color_mode,
                args.alpha_mode,
                args.overwrite,
            )
            print(
                f"    {report['image']['output_size']} "
                f"{report['files']['output_png_bytes']} bytes "
                f"({report['files']['ratio']}x) "
                f"{report['timings']['total_seconds']}s "
                f"problems={len(report['atlas']['validation_problems'])} "
                f"meanMAE={report['atlas']['region_check']['mean_mae']}",
                file=sys.stderr,
            )
        except (EngineError, SystemExit) as error:
            failures.append((str(relative), str(error)))
            print(f"    FAILED: {error}", file=sys.stderr)
    print(
        json.dumps({"processed": len(stands) - len(failures), "failed": failures}, indent=2)
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
