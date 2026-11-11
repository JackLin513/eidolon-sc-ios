"""Scale Spine 3.6 text-atlas geometry by an integer factor (stdlib only).

The stand packs are Spine 3.6 and carry a plain-text atlas:

    data.png
    size: 1024,1024
    format: RGBA8888
    filter: Linear,Linear
    repeat: none
    body
      rotate: false
      xy: 190, 313
      size: 60, 173
      orig: 60, 173
      offset: 0, 0
      index: -1

`data.json` stores attachment UVs as normalized 0..1 values, so only the atlas
mentions page pixels. Doubling the page therefore means doubling every page
coordinate and leaving `rotate` and `index` alone.

`xy`, `size`, `orig`, `offset`, `offsets` and `pad` are scaled; `rotate` and
`index` are copied verbatim. The `size:` line of every page header is scaled
too. Formatting (indentation, `, ` separators, line order, trailing newline) is
preserved so the result diffs cleanly against the original.

Run the pure tests with:

    python3 tools/stand-superres/test_atlas_scale.py
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable

# Region fields that hold page pixels. `rotate` and `index` are deliberately
# absent: rotation is a boolean and the index is a page slot, neither scales.
SCALED_REGION_FIELDS = frozenset({"xy", "size", "orig", "offset", "offsets", "pad"})

_NUMBER = re.compile(r"-?(?:\d+(?:\.\d*)?|\.\d+)")
_PAGE_HEADER_SIZE = re.compile(r"^size\s*:\s*(.+)$")


@dataclass(frozen=True)
class Region:
    name: str
    fields: dict[str, str]

    @property
    def rotated(self) -> bool:
        return self.fields.get("rotate", "false").strip().lower() == "true"

    def bounds(self) -> tuple[float, float, float, float] | None:
        """Page-space (x, y, w, h), honouring Spine's rotated-region swap."""
        try:
            x, y = _numbers(self.fields["xy"])
            w, h = _numbers(self.fields["size"])
        except (KeyError, ValueError):
            return None
        if self.rotated:
            w, h = h, w
        return x, y, w, h


@dataclass(frozen=True)
class Page:
    image: str
    size: tuple[int, int] | None
    regions: tuple[Region, ...]


def _numbers(value: str) -> list[float]:
    found = [float(token) for token in _NUMBER.findall(value)]
    if not found:
        raise ValueError(f"no numbers in {value!r}")
    return found


def _format(value: float) -> str:
    if float(value).is_integer():
        return str(int(value))
    return f"{value:.4f}".rstrip("0").rstrip(".")


def _scale_value(value: str, factor: float) -> str:
    return _NUMBER.sub(lambda m: _format(float(m.group(0)) * factor), value)


def parse_atlas(text: str) -> list[Page]:
    """Parse a text atlas into pages. Blank-first-line atlases are accepted."""
    lines = text.splitlines()
    pages: list[Page] = []
    image: str | None = None
    size: tuple[int, int] | None = None
    regions: list[Region] = []
    current: dict[str, str] | None = None
    current_name = ""

    def flush_region() -> None:
        nonlocal current
        if current is not None:
            regions.append(Region(current_name, dict(current)))
        current = None

    def flush_page() -> None:
        nonlocal image, size, regions
        flush_region()
        if image is not None:
            pages.append(Page(image, size, tuple(regions)))
        image, size, regions = None, None, []

    for line in lines:
        if not line.strip():
            continue
        if line.startswith(("  ", "\t")):
            if current is None:
                raise ValueError(f"property outside a region: {line!r}")
            key, _, value = line.strip().partition(":")
            current[key.strip()] = value.strip()
            continue
        if ":" in line:
            key, _, value = line.partition(":")
            key = key.strip()
            if key == "size":
                w, h = _numbers(value)[:2]
                size = (int(w), int(h))
            # Any other page header (`format`, `filter`, `repeat`, `pma`) is not
            # geometry and stays untouched.
            continue
        # A non-indented, colon-free line starts a new page or a new region.
        if line.endswith(".png") or line.endswith(".webp") or line.endswith(".jpg"):
            flush_page()
            image = line.strip()
            continue
        flush_region()
        current_name = line.strip()
        current = {}
    flush_page()
    return pages


def scale_atlas_text(text: str, factor: float) -> str:
    """Return the atlas with page and region geometry multiplied by `factor`."""
    if factor <= 0:
        raise ValueError("factor must be positive")
    out: list[str] = []
    region_indent: str | None = None
    for line in text.splitlines(keepends=False):
        if not line.strip():
            out.append(line)
            continue
        if line.startswith(("  ", "\t")):
            key, sep, value = line.strip().partition(":")
            key = key.strip()
            if key in SCALED_REGION_FIELDS:
                indent = line[: len(line) - len(line.lstrip())]
                out.append(f"{indent}{key}{sep}{_scale_value(value, factor)}")
            else:
                out.append(line)
            continue
        if ":" in line:
            key, sep, value = line.partition(":")
            if key.strip() == "size":
                out.append(f"{key}{sep}{_scale_value(value, factor)}")
            else:
                out.append(line)
            continue
        out.append(line)
    scaled = "\n".join(out)
    if text.endswith("\n"):
        scaled += "\n"
    return scaled


def validate_atlas(text: str) -> list[str]:
    """Return human-readable problems with an atlas's geometry (empty if sane).

    Checks page sizes, duplicate region names, regions falling outside their
    page (with spine's rotate-swap applied) and overlapping opaque rectangles.
    """
    problems: list[str] = []
    pages = parse_atlas(text)
    if not pages:
        problems.append("no pages parsed")
    for page in pages:
        if page.size is None:
            problems.append(f"{page.image}: missing page size")
            continue
        width, height = page.size
        names: set[str] = set()
        rects: list[tuple[float, float, float, float, str]] = []
        for region in page.regions:
            if region.name in names:
                problems.append(f"{page.image}: duplicate region {region.name}")
            names.add(region.name)
            bounds = region.bounds()
            if bounds is None:
                problems.append(f"{page.image}/{region.name}: unreadable geometry")
                continue
            x, y, w, h = bounds
            if x < 0 or y < 0 or x + w > width or y + h > height:
                problems.append(
                    f"{page.image}/{region.name}: {x},{y} {w}x{h} outside {width}x{height}"
                )
            rects.append((x, y, w, h, region.name))
        for i, (ax, ay, aw, ah, an) in enumerate(rects):
            for bx, by, bw, bh, bn in rects[i + 1 :]:
                if ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah:
                    problems.append(f"{page.image}: {an} overlaps {bn}")
    return problems


def min_gap(page: Page) -> float | None:
    """Smallest axis gap between two region rectangles (for bleed analysis)."""
    rects = [b for b in (r.bounds() for r in page.regions) if b]
    best: float | None = None
    for i, (ax, ay, aw, ah) in enumerate(rects):
        for bx, by, bw, bh in rects[i + 1 :]:
            dx = max(bx - (ax + aw), ax - (bx + bw))
            dy = max(by - (ay + ah), ay - (by + bh))
            gap = max(dx, dy)
            if best is None or gap < best:
                best = gap
    return best


def region_count(text: str) -> int:
    return sum(len(page.regions) for page in parse_atlas(text))


def iter_scaled_fields(text: str) -> Iterable[tuple[str, str]]:
    """Yield (region, field) for every field actually scaled (diagnostics)."""
    for page in parse_atlas(text):
        for region in page.regions:
            for field in SCALED_REGION_FIELDS & region.fields.keys():
                yield region.name, field
