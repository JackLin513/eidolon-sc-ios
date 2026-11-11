#!/usr/bin/env python3
"""Pure tests for `atlas_scale` — no Pillow, no numpy, no network.

    python3 tools/stand-superres/test_atlas_scale.py

The fixture is synthetic: one page, a normal region, a rotated one, and the
optional `pad`/`offsets` fields a texture packer may write. The important
assertions are that every page-pixel field doubles, that `rotate` and `index`
survive untouched, that the page header doubles, and that a half-scaled atlas is
rejected by `validate_atlas` (which is what makes the validator worth running on
real output).
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import atlas_scale  # noqa: E402

FIXTURE = """\n\
data.png
size: 64,64
format: RGBA8888
filter: Linear,Linear
repeat: none
body
  rotate: false
  xy: 8, 12
  size: 20, 30
  orig: 22, 32
  offset: -1, 2
  index: -1
arm
  rotate: true
  xy: 40, 8
  size: 12, 24
  orig: 12, 24
  offset: 0, 0
  index: 2
padded
  rotate: false
  xy: 48, 40
  size: 8, 8
  orig: 8, 8
  offset: 0, 0
  offsets: 1, 2, 3, 4
  pad: 1, 1, 1, 1
  index: -1
"""


class ScaleAtlasTest(unittest.TestCase):
    def test_page_header_doubles(self) -> None:
        scaled = atlas_scale.scale_atlas_text(FIXTURE, 2)
        self.assertIn("size: 128,128", scaled)

    def test_geometry_doubles(self) -> None:
        scaled = atlas_scale.scale_atlas_text(FIXTURE, 2)
        self.assertIn("  xy: 16, 24", scaled)
        self.assertIn("  size: 40, 60", scaled)
        self.assertIn("  orig: 44, 64", scaled)
        self.assertIn("  offset: -2, 4", scaled)
        self.assertIn("  offsets: 2, 4, 6, 8", scaled)
        self.assertIn("  pad: 2, 2, 2, 2", scaled)

    def test_rotate_and_index_untouched(self) -> None:
        scaled = atlas_scale.scale_atlas_text(FIXTURE, 2)
        self.assertIn("  rotate: true", scaled)
        self.assertIn("  rotate: false", scaled)
        self.assertIn("  index: -1", scaled)
        self.assertIn("  index: 2", scaled)

    def test_region_names_and_count_survive(self) -> None:
        parsed = atlas_scale.parse_atlas(atlas_scale.scale_atlas_text(FIXTURE, 2))
        self.assertEqual(len(parsed), 1)
        self.assertEqual([region.name for region in parsed[0].regions], ["body", "arm", "padded"])
        self.assertEqual(parsed[0].size, (128, 128))

    def test_leading_blank_line_and_trailing_newline_preserved(self) -> None:
        scaled = atlas_scale.scale_atlas_text(FIXTURE, 2)
        self.assertTrue(scaled.startswith("\n"))
        self.assertTrue(scaled.endswith("\n"))
        self.assertEqual(scaled.count("\n"), FIXTURE.count("\n"))

    def test_factor_one_is_identity(self) -> None:
        self.assertEqual(atlas_scale.scale_atlas_text(FIXTURE, 1), FIXTURE)

    def test_scaled_atlas_validates(self) -> None:
        self.assertEqual(atlas_scale.validate_atlas(atlas_scale.scale_atlas_text(FIXTURE, 2)), [])

    def test_region_past_page_is_rejected(self) -> None:
        # A region that no longer fits its page is the failure this validator
        # exists for; a wrongly scaled atlas usually produces exactly this.
        broken = atlas_scale.scale_atlas_text(FIXTURE, 2).replace(
            "  size: 40, 60", "  size: 140, 60"
        )
        problems = atlas_scale.validate_atlas(broken)
        self.assertTrue(problems, "a region past the page should be a problem")

    def test_rotated_region_occupies_swapped_extent(self) -> None:
        # The arm sits at x=40..64 on a 64-wide page only if a rotated region's
        # width on the page is its stored height.
        page = atlas_scale.parse_atlas(FIXTURE)[0]
        arm = next(region for region in page.regions if region.name == "arm")
        self.assertEqual(arm.bounds(), (40, 8, 24, 12))
        self.assertEqual(atlas_scale.validate_atlas(FIXTURE), [])

    def test_min_gap_and_region_count(self) -> None:
        self.assertEqual(atlas_scale.region_count(FIXTURE), 3)
        gap = atlas_scale.min_gap(atlas_scale.parse_atlas(FIXTURE)[0])
        self.assertIsNotNone(gap)
        self.assertGreaterEqual(gap, 0)


if __name__ == "__main__":
    unittest.main()
