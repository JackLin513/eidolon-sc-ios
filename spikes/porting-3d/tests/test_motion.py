import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from motion import (
    downsample,
    fold_constants,
    quantise,
    dequantise,
    Curve,
)


class FoldConstantsTests(unittest.TestCase):
    def test_a_single_value_curve_becomes_one_entry(self) -> None:
        curves = [
            Curve(path="A", property_type="AngleX", key_type="Const", values=[12.5]),
            Curve(path="A", property_type="AngleY", key_type="FullFrame", values=[0.0, 1.0]),
        ]

        constants, animated = fold_constants(curves)

        self.assertEqual(constants, [("A", "AngleX", 12.5)])
        self.assertEqual([curve.path for curve in animated], ["A"])

    def test_a_constant_with_several_identical_values_is_still_folded(self) -> None:
        curves = [Curve(path="A", property_type="AngleZ", key_type="FullFrame", values=[3.0] * 4)]

        constants, animated = fold_constants(curves)

        self.assertEqual(constants, [("A", "AngleZ", 3.0)])
        self.assertEqual(animated, [])


class DownsampleTests(unittest.TestCase):
    def test_halving_60fps_to_30fps_keeps_every_other_sample(self) -> None:
        values = [float(i) for i in range(7801)]

        result = downsample(values, source_fps=60, target_fps=30)

        self.assertEqual(len(result), 3901)
        self.assertEqual(result[:4], [0.0, 2.0, 4.0, 6.0])

    def test_it_keeps_the_last_sample_of_a_long_curve(self) -> None:
        values = [float(i) for i in range(7801)]

        result = downsample(values, source_fps=60, target_fps=30)

        self.assertEqual(result[-1], 7800.0)

    def test_asking_for_the_same_rate_is_a_no_op(self) -> None:
        values = [1.0, 2.0, 3.0]

        self.assertEqual(downsample(values, source_fps=60, target_fps=60), values)


class QuantiseTests(unittest.TestCase):
    def test_round_trips_within_the_step_size(self) -> None:
        values = [-180.0, -90.0, 0.0, 37.25, 179.9]

        scale, packed = quantise(values)
        restored = dequantise(packed, scale)

        for original, result in zip(values, restored):
            self.assertLessEqual(abs(original - result), 1.0 / scale)

    def test_pack_survives_a_json_round_trip(self) -> None:
        import json

        scale, packed = quantise([0.0, 45.0, -45.0])

        restored = dequantise(json.loads(json.dumps(packed)), scale)

        self.assertEqual([round(value, 3) for value in restored], [0.0, 45.0, -45.0])


if __name__ == "__main__":
    unittest.main()
