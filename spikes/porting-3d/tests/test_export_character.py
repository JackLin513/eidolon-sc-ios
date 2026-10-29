"""`_SubTex` uses alpha as a mask and RealityKit's emissive texture drops alpha.

Premultiplying puts the mask into RGB where it survives; for an opaque sub
texture (ss003's glow, alpha 255) the operation is the identity.
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

    def test_opaque_texel_is_unchanged(self):
        image = Image.new("RGBA", (1, 1), (18, 140, 200, 255))

        self.assertEqual(premultiplied(image).convert("RGBA").getpixel((0, 0)),
                         (18, 140, 200, 255))


if __name__ == "__main__":
    unittest.main()
