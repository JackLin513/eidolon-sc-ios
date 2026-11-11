# Stand atlas 2× super-resolution

Offline experiment for issue #139: can the Spine 3.6 stand atlases be upscaled 2×
so the stands look sharper on a Retina iPad? Nothing here runs in the app; the
scripts read a stand directory, write a 2× copy somewhere else, and leave the
repository's assets alone.

Each stand is three files. `data.png` is a 1024×1024 RGBA (palette-encoded) atlas
with alpha, `data.atlas` is the text atlas that places every part in page pixels,
and `data.json` is the Spine skeleton whose attachment UVs are normalized 0..1.

The output keeps that shape:

```
data.png     2048×2048, alpha-aware 2× upscale
data.atlas   every page coordinate doubled (rotate/index untouched)
data.json    byte-for-byte copy
superres.json engine, timings, and the validation numbers below
```

## Requirements

* Python 3.11+ with Pillow and numpy (a throwaway venv is fine).
* Optional but recommended: `realesrgan-ncnn-vulkan` (Real-ESRGAN, BSD-3-Clause)
  with its models. It is **not** vendored here; the macOS release is a universal
  binary that runs natively on Apple Silicon through MoltenVK.

```bash
python3 -m venv /tmp/srvenv
/tmp/srvenv/bin/pip install pillow numpy

curl -L -o /tmp/realesrgan.zip \
  https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip
unzip -q /tmp/realesrgan.zip -d /tmp/resrgan
```

Without the binary, `--engine lanczos` still produces samples, but they are
plain Lanczos + unsharp mask and the report labels them `"ai": false`.

## Usage

One stand (assets from the community CDN, matching the local package byte for
byte):

```bash
mkdir -p /tmp/stand/1030010010 && cd /tmp/stand
for f in data.png data.atlas data.json; do
  curl -O "https://cf-static.shinycolors.moe/spine/idols/stand/1030010010/$f"
done

cd - && /tmp/srvenv/bin/python tools/stand-superres/upscale_stand.py \
  --src /tmp/stand/1030010010 \
  --out tools/stand-superres/out/stand \
  --bin /tmp/resrgan/realesrgan-ncnn-vulkan \
  --models /tmp/resrgan/models
```

A whole extracted tree (any directory with all three files is picked up):

```bash
/tmp/srvenv/bin/python tools/stand-superres/upscale_stand.py \
  --batch <extracted-package>/stand --out tools/stand-superres/out/batch \
  --bin /tmp/resrgan/realesrgan-ncnn-vulkan --models /tmp/resrgan/models \
  --limit 5
```

Review images (both columns at the same display size: the current 1024 atlas
sampled at 2× on the left, the real 2× texture at 1:1 on the right):

```bash
/tmp/srvenv/bin/python tools/stand-superres/make_preview.py \
  --source /tmp/stand/1030010010 \
  --superres tools/stand-superres/out/stand \
  --out tools/stand-superres/out/previews --name default \
  --regions face,hair_U,eye_L,body
```

Atlas scaling is pure and tested without Pillow or the network:

```bash
python3 tools/stand-superres/test_atlas_scale.py
```

## What gets scaled

`atlas_scale.scale_atlas_text` multiplies the page header `size:` and each
region's `xy`, `size`, `orig`, `offset`, `offsets` and `pad`. `rotate` and
`index` are copied verbatim; `format`, `filter`, `repeat`, `pma` and the page
file name are untouched. Formatting (indentation, `, ` separators, a leading
blank line, the trailing newline) is preserved, so a scaled atlas diffs cleanly
against the original. `data.json` is copied, never rewritten.

`validate_atlas` re-parses the result and rejects regions that fall outside the
doubled page, duplicate region names, and overlapping rectangles. It applies
Spine's convention that a rotated region occupies swapped width/height on the
page.

## Design notes, with measurements

**Colour: fill the transparent pixels (`--color-mode bleed`, default).** The
source atlases store junk colour under `alpha == 0`, and even a few stray solid
pixels at `alpha == 1` (one is `#FF0000`). Everything that touches those pixels
picks the junk up at the silhouette. Three modes were compared on the default
outfit:

| mode | what it does | edge luminance delta vs current* |
| --- | --- | --- |
| `premultiplied` | colour × alpha, upscale, divide back by a separately upscaled alpha | −39.6 |
| `straight` | upscale stored RGB as-is | −16.9 |
| `bleed` | flood solid colour into transparent pixels, then upscale | **−14.6** |

\* mean luminance difference from the bilinear baseline at pixels with partial
alpha (more negative = darker fringe). `premultiplied` looks tidy in theory but
the divide uses an alpha from a different pass, so partial-alpha pixels keep a
dark fringe; on a white background that is a visible grey contour line.
`bleed` treats pixels below `alpha == 32` as unknown, so the red-at-alpha-1
pixel cannot seed a colour, and the resulting edge composites to the artwork's
own colour.

**Alpha: Lanczos, not the model (`--alpha-mode lanczos`, default).** Running the
alpha mask through Real-ESRGAN gives hard, stair-stepped silhouettes; Lanczos
keeps the anti-aliased edge smooth. The model is only used for colour.

**The atlas filter stays `Linear,Linear`.** Doubling the texture does not change
how the runtime samples it; it changes how many texels are available. Regions in
both samples are separated by at least 2 page pixels (4 at 2×), so plate bleed
across parts is not a new risk. Visible alpha outside any region rectangle is
confined to ≤4 px (2×) of a region edge and never exceeds alpha 10, i.e. the
silhouette grows by less than half a source pixel.

## Results on the two samples (2026-11-11, M1 Pro)

| stand | source px | output px | output bytes | ×source | seconds |
| --- | --- | --- | --- | --- | --- |
| `stand/1030010010` (default) | 1024² | 2048² | 2,649,231 | 23.1× | 5.5 |
| `stand_costume/1030010010` | 1024² | 2048² | 3,265,173 | 21.9× | 5.2 |

* Atlas validation: 66 and 68 regions, page 2048², no problems.
* Region fidelity (scaled crop, box-downscaled, compared with the source crop):
  mean MAE 10.1 / 10.1 of 255. The worst regions are the tiny semi-transparent
  ones (`mouth_close4` 6×19, `mouse` 7×24, eyebrows), where the model redraws
  rather than resamples; large parts stay at MAE 4–7.
* Alpha: 0..255 in and out; content bbox within 1–2 px of the doubled source
  bbox (Lanczos ringing can move the outermost near-invisible row by a pixel).
* Sharpness: mean gradient energy inside the silhouette rises 4.84 → 7.53
  (default) and 5.99 → 9.33 (costume), ≈1.55×. That matches the visual: line
  art, lace, hair tips and dress folds are visibly cleaner at 2× display.

**File size is the problem.** RGBA 2× costs 22–23× the source. Re-encoding the
same pixels as a 256-colour palette PNG (the source atlases are palette PNGs
too) drops the default sample to 312 KB (2.7× source) and the costume to 418 KB,
at the price of alpha changes >16/255 on 2.8–3.2% of visible pixels and mild
banding in soft shading. It was measured, not adopted for the review samples:
those are full RGBA so nothing in them is a palette artefact.

**Batch estimate.** The local package holds 2034 stands. At ~5.3 s and ~2.9 MB
each that is roughly 3 hours of GPU time and ~5.9 GB of PNGs (the current
package is 586 MB zipped). The palette variant would land around 700 MB but
needs a quality sign-off, and neither has been tried in the app.

## Limitations

* Only the atlas is upscaled; no Spine pose is rendered here, so the samples are
  judged per part, not as a composed stand on the call screen.
* Real-ESRGAN is a perceptual model: it sharpens and slightly recomposes small
  details. That is the point, but it is not a faithful resample and it is why
  the tiny mouth/eyebrow regions deviate most.
* The ncnn build is not part of this repository and its model weights are not
  either; the licence is Real-ESRGAN's BSD-3-Clause.
* 2× is the tested factor. `--factor` exists, but an x4 model asked for 2× is
  boxed down and the metadata has not been validated at other factors.

## Review artefacts

All under `tools/stand-superres/out/` (git-ignored):

* `stand/data.png`, `stand/data.atlas` — default outfit sample.
* `stand_costume/data.png`, `stand_costume/data.atlas` — costume sample.
* `previews/sheet_default.png`, `previews/sheet_costume.png` — per-region
  current-vs-2× sheets on a dark background.
* `previews/region_*_checker.png` — the same crops over a checkerboard for
  transparency.
* `previews/fullpage_default.png`, `previews/fullpage_costume.png` — whole page,
  current at 2× vs real 2×.
* `previews/ipad_review_screenshot.png` — iPad mini simulator screenshot of
  `previews/review_card_ipad.png` served at exactly two device pixels per card
  pixel (Safari downscales images otherwise, which produces moiré).
