import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from motion import (
    ANGLE_SCALE,
    FORMAT,
    POSITION_SCALE,
    SOURCE_FRAME,
    build_motion,
    decode_channel,
    downsample,
    fold_constants,
    quantise,
    dequantise,
    sample,
    unpack_curve,
    Curve,
)


def curve(property_type: str, key_type: str, values: list[float], path: str = "A") -> Curve:
    return Curve(path=path, property_type=property_type, key_type=key_type, values=values)


def entry(property_type: str, key_type: str, values: list[float], path: str = "A") -> dict:
    return {
        "path": path,
        "attribs": [f"property_type {property_type}", f"key_type {key_type}"],
        "values": values,
    }


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


class SampleFullFrameTests(unittest.TestCase):
    """One value per 1/60 s, linear between keys, clamped at both ends."""

    def setUp(self) -> None:
        self.curve = curve("AngleX", "FullFrame", [0.0, 10.0, 20.0, 30.0])

    def test_reads_exact_frames(self) -> None:
        self.assertEqual(sample(self.curve, 0.0), 0.0)
        self.assertEqual(sample(self.curve, SOURCE_FRAME), 10.0)
        self.assertEqual(sample(self.curve, 2 * SOURCE_FRAME), 20.0)

    def test_interpolates_between_frames(self) -> None:
        self.assertAlmostEqual(sample(self.curve, 1.5 * SOURCE_FRAME), 15.0)
        self.assertAlmostEqual(sample(self.curve, 0.5 * SOURCE_FRAME), 5.0)

    def test_clamps_outside_the_curve(self) -> None:
        self.assertEqual(sample(self.curve, 10.0), 30.0)
        self.assertEqual(sample(self.curve, -1.0), 0.0)


class SampleDiscreateTests(unittest.TestCase):
    """Sparse (time, value) pairs, linear between keys."""

    def setUp(self) -> None:
        self.curve = curve("AngleY", "Discreate", [0.0, 0.0, 2.0, 10.0])

    def test_interpolates_between_pairs(self) -> None:
        self.assertAlmostEqual(sample(self.curve, 1.0), 5.0)

    def test_hits_the_keys_exactly(self) -> None:
        self.assertEqual(sample(self.curve, 2.0), 10.0)

    def test_clamps_outside_the_pairs(self) -> None:
        self.assertEqual(sample(self.curve, -1.0), 0.0)
        self.assertEqual(sample(self.curve, 3.0), 10.0)


class SampleStepTests(unittest.TestCase):
    def test_holds_the_previous_value(self) -> None:
        curve_ = curve("AngleY", "Step", [0.0, 0.0, 2.0, 10.0])

        self.assertEqual(sample(curve_, 1.0), 0.0)
        self.assertEqual(sample(curve_, 1.999), 0.0)
        self.assertEqual(sample(curve_, 2.0), 10.0)


class SampleConstTests(unittest.TestCase):
    def test_returns_the_only_value_at_any_time(self) -> None:
        curve_ = curve("AngleZ", "Const", [7.5])

        self.assertEqual(sample(curve_, -100.0), 7.5)
        self.assertEqual(sample(curve_, 42.0), 7.5)


class SampleFCurveTests(unittest.TestCase):
    def test_matches_a_hand_computed_hermite(self) -> None:
        # (time, value, inTangent, outTangent): value 0 with tangent 1 at t=0,
        # value 10 with tangent 0 at t=1.
        curve_ = curve("AngleX", "FCurve", [0.0, 0.0, 0.0, 1.0, 1.0, 10.0, 0.0, 0.0])

        # u = 0.5: 0.125 * 1 + 0.5 * 10 = 5.125
        self.assertAlmostEqual(sample(curve_, 0.5), 5.125)

    def test_hits_the_keys_exactly(self) -> None:
        curve_ = curve("AngleX", "FCurve", [0.0, 0.0, 0.0, 1.0, 1.0, 10.0, 0.0, 0.0])

        self.assertEqual(sample(curve_, 0.0), 0.0)
        self.assertEqual(sample(curve_, 1.0), 10.0)

    def test_clamps_outside_the_keys(self) -> None:
        curve_ = curve("AngleX", "FCurve", [0.0, 0.0, 0.0, 1.0, 1.0, 10.0, 0.0, 0.0])

        self.assertEqual(sample(curve_, -1.0), 0.0)
        self.assertEqual(sample(curve_, 2.0), 10.0)


class SampleOffsetFrameTests(unittest.TestCase):
    def test_full_frame_offset_starts_at_values_zero(self) -> None:
        curve_ = curve("PositionX", "FullFrameOffset", [1.0, 5.0, 6.0, 7.0])

        self.assertEqual(sample(curve_, 1.0), 5.0)
        self.assertAlmostEqual(sample(curve_, 1.0 + SOURCE_FRAME), 6.0)
        self.assertEqual(sample(curve_, 0.5), 5.0)

    def test_delta_frame_uses_values_zero_as_the_frame_length(self) -> None:
        curve_ = curve("PositionX", "DeltaFrame", [0.5, 5.0, 6.0, 7.0])

        self.assertEqual(sample(curve_, 0.0), 5.0)
        self.assertAlmostEqual(sample(curve_, 0.25), 5.5)
        self.assertAlmostEqual(sample(curve_, 0.5), 6.0)


class SampleUnsupportedTests(unittest.TestCase):
    def test_step_3_values_is_not_evaluated(self) -> None:
        self.assertEqual(sample(curve("AngleX", "Step_3Values", [1.0, 2.0, 3.0]), 0.0), 0.0)

    def test_an_unknown_key_type_returns_zero(self) -> None:
        self.assertEqual(sample(curve("AngleX", "Mystery", [1.0]), 0.0), 0.0)

    def test_empty_values_return_zero(self) -> None:
        self.assertEqual(sample(curve("AngleX", "FullFrame", []), 0.0), 0.0)


class PackedChannelTests(unittest.TestCase):
    def test_a_constant_channel_collapses_to_the_first_frame(self) -> None:
        asset = {
            "time_length": 0.1,
            "curves": [entry("AngleY", "Const", [90.0])],
        }

        bone = build_motion(asset)["bones"][0]

        self.assertEqual(bone["rot"], [0, 9000, 0])

    def test_an_animated_channel_is_seed_plus_deltas(self) -> None:
        # 60 fps source sampled at 30 fps: frames 0, 2, 4, and the last value.
        asset = {
            "time_length": 0.1,
            "curves": [entry("AngleX", "FullFrame", [0.0, 10.0, 20.0, 30.0, 40.0, 50.0])],
        }

        bone = build_motion(asset)["bones"][0]

        self.assertEqual(bone["rot"][0], [0, 2000, 2000, 1000])

    def test_decode_channel_restores_every_frame(self) -> None:
        channel = [0, 2000, 2000, 1000]

        self.assertEqual(
            [decode_channel(channel, frame) for frame in range(4)], [0, 2000, 4000, 5000]
        )
        self.assertEqual(decode_channel(channel, -5), 0)
        self.assertEqual(decode_channel(channel, 99), 5000)

    def test_unpack_curve_dequantises_and_clamps(self) -> None:
        self.assertEqual(unpack_curve(9000, ANGLE_SCALE, 2), [90.0, 90.0])
        self.assertEqual(unpack_curve([0, 20, 20, 10], ANGLE_SCALE, 2), [0.0, 0.2])


class BuildMotionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.asset = {
            "time_length": 0.1,
            "curves": [
                entry("AngleX", "FullFrame", [0.0, 10.0, 20.0, 30.0, 40.0, 50.0]),
                entry("AngleY", "Const", [90.0]),
                entry("PositionX", "FullFrame", [0.0, 0.001, 0.002, 0.003, 0.004, 0.005]),
                entry("PositionY", "Const", [0.25]),
            ],
        }

    def test_header_describes_the_grid(self) -> None:
        motion = build_motion(self.asset)

        self.assertEqual(motion["format"], FORMAT)
        self.assertEqual(motion["fps"], 30)
        self.assertEqual(motion["frames"], 4)
        self.assertEqual(motion["time_length"], 0.1)
        self.assertEqual(motion["angle_scale"], ANGLE_SCALE)
        self.assertEqual(motion["position_scale"], POSITION_SCALE)

    def test_a_bone_keeps_its_path_and_three_channels(self) -> None:
        bone = build_motion(self.asset)["bones"][0]

        self.assertEqual(bone["path"], "A")
        self.assertEqual(len(bone["rot"]), 3)
        self.assertEqual(bone["rot"][1], 9000)

    def test_positions_are_quantised_separately(self) -> None:
        bone = build_motion(self.asset)["bones"][0]

        self.assertEqual(bone["pos"], [[0, 8, 8, 4], 1000, 0])

    def test_pos_is_omitted_when_the_dance_has_no_position_curves(self) -> None:
        asset = {"time_length": 0.1, "curves": [entry("AngleX", "Const", [1.0])]}

        bone = build_motion(asset)["bones"][0]

        self.assertNotIn("pos", bone)

    def test_the_packed_dance_survives_json(self) -> None:
        import json

        motion = build_motion(self.asset)

        self.assertEqual(json.loads(json.dumps(motion)), motion)


if __name__ == "__main__":
    unittest.main()
