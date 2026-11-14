import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from sway import mirror, plane_normal, tail_for


class FakeDocument:
    """Only the bits `tail_for` reads: the node table and a name per node."""

    def __init__(self, nodes):
        self.nodes = nodes

    def runtime_name(self, node):
        return self.nodes[node].get("name", "")


class TailForTests(unittest.TestCase):
    def test_tip_marker_child_is_the_tail(self):
        # A skirt bone's child is a plain transform (`skirt_RA1`), not a skin
        # joint; the game aims the bone at that point. Reading the vertex
        # centroid instead made every panel 3-10 cm short, so at rest the tips
        # sat inside the thigh capsules and the collision pushed the hem out.
        document = FakeDocument({
            0: {"name": "skirt_GP/skirt_RA0", "children": [1]},
            1: {"name": "skirt_GP/skirt_RA1", "translation": [-0.3091, 0.0, 0.0]},
        })
        centroids = {0: (-0.15, 0.003, 0.009)}
        self.assertEqual(
            tail_for(document, 0, {0}, centroids), mirror([-0.3091, 0.0, 0.0])
        )

    def test_chain_child_is_the_tail(self):
        document = FakeDocument({
            0: {"name": "hair_maeC0", "children": [1]},
            1: {"name": "hair_maeC1", "translation": [-0.1015, 0.0, 0.0]},
        })
        self.assertEqual(
            tail_for(document, 0, {0, 1}, {}), mirror([-0.1015, 0.0, 0.0])
        )

    def test_childless_leaf_falls_back_to_the_centroid(self):
        document = FakeDocument({0: {"name": "hair_ushiroA2"}})
        self.assertEqual(
            tail_for(document, 0, {0}, {0: (-0.04, 0.0, 0.0)}),
            mirror([-0.04, 0.0, 0.0]),
        )


class PlaneNormalTests(unittest.TestCase):
    def test_unrotated_plane_pushes_away_from_its_named_side(self):
        # `CheckPlane` keeps the tip on the far side of a `minusY` plane, i.e.
        # it pushes towards +Y; the exporter stores that push direction.
        self.assertEqual(
            plane_normal({"planeAxis": "minusY", "planeRotOn": "False"}),
            mirror([0.0, 1.0, 0.0]),
        )
        # A `plusZ` plane pushes towards −Z in game space, which the usual
        # mirror turns into +Z in the app's frame.
        self.assertEqual(
            plane_normal({"planeAxis": "plusZ", "planeRotOn": "False"}),
            (0.0, 0.0, 1.0),
        )

    def test_rotated_plane_follows_the_euler(self):
        normal = plane_normal({
            "planeAxis": "minusZ", "planeRotOn": "True",
            "planeRotEuler": "30,0,0",
        })
        # (0,0,1) turned 30° about X, then mirrored on Z.
        self.assertAlmostEqual(normal[1], -0.5, places=4)
        self.assertAlmostEqual(abs(normal[2]), 0.866, places=3)



if __name__ == "__main__":
    unittest.main()
