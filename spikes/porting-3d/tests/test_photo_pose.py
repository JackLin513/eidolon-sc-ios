"""Pose-clip decoding, checked against synthetic container data.

Nothing here reads a game bundle: the point is the container layout and the
resampling, both of which are pure numbers. The one constant that does come
from the game is the path hash, pinned below because every binding depends on
it.
"""

import struct
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import photo_pose
from photo_pose import (
    BONE_PATHS,
    Key,
    decode_clip,
    path_hash,
    sample,
    to_motion_asset,
    _dense_curves,
    _streamed_curves,
)


def f32(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def i32(value: int) -> int:
    return value & 0xFFFFFFFF


def frame(time: float, keys: list[tuple[int, float]]) -> list[int]:
    words = [f32(time), i32(len(keys))]
    for index, value in keys:
        words += [i32(index), f32(0.0), f32(0.0), f32(0.0), f32(value)]
    return words


class PathHashTests(unittest.TestCase):
    def test_path_hash_matches_unity(self) -> None:
        # Animator.StringToHash("MODEL_00") on the shipped clips.
        self.assertEqual(path_hash("MODEL_00"), 782113489)
        self.assertEqual(path_hash("POSITION"), (-2145421127) & 0xFFFFFFFF)


class StreamedTests(unittest.TestCase):
    def test_frames_split_into_curves(self) -> None:
        words = frame(-3.4028234663852886e38, [(0, 1.0)]) + frame(0.0, [(0, 1.0), (1, 2.0)])
        curves = _streamed_curves(words)
        self.assertEqual([k.value for k in curves[0]], [1.0, 1.0])
        self.assertEqual([k.time for k in curves[0]], [-3.4028234663852886e38, 0.0])
        self.assertEqual([k.value for k in curves[1]], [2.0])

    def test_a_truncated_frame_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            _streamed_curves([f32(0.0), i32(3), i32(0), f32(0.0), f32(0.0), f32(0.0)])

    def test_sentinel_frame_is_the_first_key(self) -> None:
        # Unity writes -3.4e38 as the first frame's time so the Bezier slope of
        # the real first key has something before it; the value is the pose at
        # time zero, so sampling before the clip returns it.
        curves = _streamed_curves(
            frame(-3.4028234663852886e38, [(0, 5.0)]) + frame(0.5, [(0, 9.0)])
        )
        self.assertEqual(sample(curves[0], -3.4028234663852886e38), 5.0)
        self.assertEqual(sample(curves[0], 0.5), 9.0)


class DenseTests(unittest.TestCase):
    def test_table_is_indexed_by_frame_and_curve(self) -> None:
        curves = _dense_curves(2, 2, 60.0, 0.0, [1.0, 2.0, 3.0, 4.0], offset=3)
        self.assertEqual([(k.time, k.value) for k in curves[3]], [(0.0, 1.0), (1 / 60, 3.0)])
        self.assertEqual([(k.time, k.value) for k in curves[4]], [(0.0, 2.0), (1 / 60, 4.0)])

    def test_shape_mismatch_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            _dense_curves(2, 2, 60.0, 0.0, [1.0, 2.0], offset=0)


class SampleTests(unittest.TestCase):
    def test_interpolates_and_clamps(self) -> None:
        keys = [Key(0.0, 0.0), Key(1.0, 10.0)]
        self.assertEqual(sample(keys, -1.0), 0.0)
        self.assertEqual(sample(keys, 0.5), 5.0)
        self.assertEqual(sample(keys, 2.0), 10.0)
        self.assertEqual(sample([], 0.5), 0.0)


def fake_clip(
    bindings: list[tuple[int, int]], stop: float, words: list[int], curve_count: int | None = None,
):
    """A duck-typed stand-in for the UnityPy AnimationClip subtree."""
    streamed = SimpleNamespace(
        data=words, curveCount=curve_count if curve_count is not None else len(bindings) * 3
    )
    dense = SimpleNamespace(
        m_FrameCount=0, m_CurveCount=0, m_SampleRate=60.0,
        m_BeginTime=0.0, m_SampleArray=[],
    )
    constant = SimpleNamespace(data=[])
    container = SimpleNamespace(
        m_StreamedClip=streamed, m_DenseClip=dense, m_ConstantClip=constant
    )
    return SimpleNamespace(
        m_Name="fake",
        m_ClipBindingConstant=SimpleNamespace(
            genericBindings=[SimpleNamespace(path=p & 0xFFFFFFFF, attribute=a) for p, a in bindings]
        ),
        m_MuscleClip=SimpleNamespace(m_StopTime=stop, m_Clip=SimpleNamespace(data=container)),
    )


class DecodeClipTests(unittest.TestCase):
    def test_euler_and_position_land_on_their_bones(self) -> None:
        path = "MODEL_00/BODY_SCALE/BASE/MUNE1"
        bindings = [(path_hash("POSITION"), 1), (path_hash(path), 4)]
        words = (
            frame(-3.4028234663852886e38, [(0, 1.0), (1, 0.0), (2, -0.5), (3, 10.0), (4, 20.0), (5, 30.0)])
            + frame(0.0, [(0, 1.0), (1, 0.0), (2, -0.5), (3, 10.0), (4, 20.0), (5, 30.0)])
        )
        clip = decode_clip(fake_clip(bindings, 1 / 30, words))
        self.assertEqual(clip.length, 1 / 30)
        # One sample per 1/60 s frame, plus the pose at t=0.
        self.assertEqual(len(clip.curves["POSITION"]["PositionY"]), 3)
        self.assertEqual(set(clip.curves["POSITION"]["PositionY"]), {0.0})
        self.assertEqual(set(clip.curves[path]["AngleZ"]), {30.0})
        self.assertNotIn("AngleW", clip.curves[path])

    def test_unknown_paths_are_reported_not_guessed(self) -> None:
        clip = decode_clip(fake_clip([(12345, 4)], 0.0, frame(0.0, [(0, 1.0), (1, 2.0), (2, 3.0)])))
        self.assertEqual(clip.curves, {})

    def test_curve_count_must_match_the_bindings(self) -> None:
        with self.assertRaises(ValueError):
            decode_clip(
                fake_clip([(path_hash("MODEL_00"), 4)], 0.0, frame(0.0, [(0, 1.0)]), curve_count=2)
            )


class MotionAssetTests(unittest.TestCase):
    def test_every_curve_becomes_a_full_frame_entry(self) -> None:
        clip = photo_pose.PoseClip(
            name="x", length=1 / 30,
            curves={"A": {"AngleX": [1.0, 2.0], "AngleY": [0.0, 0.0], "AngleZ": [0.0, 0.0]}},
        )
        asset = to_motion_asset(clip)
        self.assertEqual(asset["time_length"], 1 / 30)
        entries = {entry["path"] + ":" + entry["attribs"][0] for entry in asset["curves"]}
        self.assertIn("A:property_type AngleX", entries)
        self.assertEqual(len(asset["curves"]), 3)
        self.assertTrue(all("key_type FullFrame" in e["attribs"] for e in asset["curves"]))


class PathTableTests(unittest.TestCase):
    def test_canonical_paths_are_unique_and_hash_without_collisions(self) -> None:
        self.assertEqual(len(BONE_PATHS), len(set(BONE_PATHS)))
        self.assertEqual(len({path_hash(p) for p in BONE_PATHS}), len(BONE_PATHS))


if __name__ == "__main__":
    unittest.main()
