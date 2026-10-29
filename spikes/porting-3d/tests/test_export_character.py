"""The glow texture has to lose its alpha before it can be added as emissive.

`_SubTex` uses alpha as a mask: the eye catch-light is a white blob on a
transparent field. An emissive texture is multiplied by its colour channels
alone, so the mask has to be folded into the colour first or the whole quad
lights up.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from PIL import Image

from export_character import premultiplied


class PremultipliedTests(unittest.TestCase):
    def test_alpha_becomes_brightness(self):
        image = Image.new("RGBA", (2, 1))
        image.putpixel((0, 0), (255, 255, 255, 255))
        image.putpixel((1, 0), (255, 255, 255, 0))

        result = premultiplied(image).convert("RGBA")

        self.assertEqual(result.getpixel((0, 0)), (255, 255, 255, 255))
        self.assertEqual(result.getpixel((1, 0))[:3], (0, 0, 0))

    def test_partial_alpha_scales_the_colour(self):
        image = Image.new("RGBA", (1, 1))
        image.putpixel((0, 0), (200, 100, 40, 128))

        red, green, blue, alpha = premultiplied(image).convert("RGBA").getpixel((0, 0))

        self.assertAlmostEqual(red, 100, delta=2)
        self.assertAlmostEqual(green, 50, delta=2)
        self.assertAlmostEqual(blue, 20, delta=2)
        self.assertEqual(alpha, 255)

    def test_fully_opaque_black_stays_black(self):
        image = Image.new("RGBA", (1, 1), (0, 0, 0, 255))

        self.assertEqual(premultiplied(image).convert("RGBA").getpixel((0, 0)), (0, 0, 0, 255))


if __name__ == "__main__":
    unittest.main()
