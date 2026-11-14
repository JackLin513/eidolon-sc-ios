#!/usr/bin/env python3
"""Decode MLTD photo-mode pose clips without a Unity Editor.

A ``chr_anim_pho_*.reduc.unity3d`` bundle holds plain generic
``AnimationClip`` objects, not Humanoid muscle clips: ``m_ClipBindingConstant``
names 60 Transform properties by the CRC32 of their full path, and the keys
live in the standard ``m_MuscleClip.m_Clip`` containers (streamed, dense,
constant). UnityPy hands all three over raw, so the clips can be decoded and
resampled on the Mac.

What the containers hold, confirmed against the shipped clips:

- ``m_StreamedClip`` is a list of frames: ``float time``, ``int32 keyCount``,
  then ``keyCount`` keys of ``int32 curveIndex`` + four ``float`` Bezier
  coefficients whose fourth one is the value. The first frame's time is
  ``-3.4e38`` (Unity's "before everything" sentinel) and the last one is ``inf``.
- ``m_DenseClip`` is a ``frameCount x curveCount`` float table on a uniform
  ``m_SampleRate`` grid, covering the curves after the constant ones.
- ``m_ConstantClip`` is one float per curve, covering the first curves.

Bindings say which property they drive through ``attribute`` (the same switch
AssetStudio's ``ReadCurveData`` implements): 1 translation (three curves, Unity
units), 2 quaternion rotation (four), 3 scale (three), 4 Euler rotation (three,
degrees, in the same Z-then-X-then-Y convention the dance decoder documents —
which is why they line up with the ``.imo`` curves for the same bones).
Quaternion bindings are converted to Euler so the packed motion format stays
single-shaped; scale is decoded but dropped.


    V=build/mltd-spike/venv/bin/python
    $V spikes/porting-3d/photo_pose.py --bundle chr_anim_pho_standd_ver01.reduc.unity3d --list
    $V spikes/porting-3d/photo_pose.py --bundle chr_anim_pho_standd_ver01.reduc.unity3d \
       --clip pho_standd_check_act_ver01 --output out/pho_standd_check_act_ver01.motion.json
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import motion

SOURCE_FPS = 60
SOURCE_FRAME = 1.0 / SOURCE_FPS

#: MLTD's canonical Transform paths. Every clip addresses its bones by the
#: CRC32 of one of these strings; the list comes from the dance decoder, which
#: reads the paths out of the shipped ``CharacterImasMotionAsset``, and covers
#: every binding in the photo pose clips too. It also carries the three
#: transforms the dance assets never name (``POSITION/SCALE_POINT``,
#: ``MODEL_00/BODY_SCALE``) because the pose clips do bind them.
BONE_PATHS = [
    "MODEL_00",
    "MODEL_00/BODY_SCALE",
    "MODEL_00/BODY_SCALE/BASE",
    "MODEL_00/BODY_SCALE/BASE/KOSHI",
    "MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_L",
    "MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_L/HIZA_L",
    "MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_L/HIZA_L/ASHI_L",
    "MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_L/HIZA_L/ASHI_L/TSUMASAKI_L",
    "MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_R",
    "MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_R/HIZA_R",
    "MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_R/HIZA_R/ASHI_R",
    "MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_R/HIZA_R/ASHI_R/TSUMASAKI_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/KUBI",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/KUBI/ATAMA",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/HITO3_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/HITO3_L/HITO2_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/HITO3_L/HITO2_L/HITO1_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/KUKO_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/KUKO_L/KO3_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/KUKO_L/KO3_L/KO2_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/KUKO_L/KO3_L/KO2_L/KO1_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/KUKO_L/KUSU3_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/KUKO_L/KUSU3_L/KUSU2_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/KUKO_L/KUSU3_L/KUSU2_L/KUSU1_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/NAKA3_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/NAKA3_L/NAKA2_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/NAKA3_L/NAKA2_L/NAKA1_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/OYA3_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/OYA3_L/OYA2_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/OYA3_L/OYA2_L/OYA1_L",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/HITO3_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/HITO3_R/HITO2_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/HITO3_R/HITO2_R/HITO1_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/KUKO_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/KUKO_R/KO3_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/KUKO_R/KO3_R/KO2_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/KUKO_R/KO3_R/KO2_R/KO1_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/KUKO_R/KUSU3_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/KUKO_R/KUSU3_R/KUSU2_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/KUKO_R/KUSU3_R/KUSU2_R/KUSU1_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/NAKA3_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/NAKA3_R/NAKA2_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/NAKA3_R/NAKA2_R/NAKA1_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/OYA3_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/OYA3_R/OYA2_R",
    "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/OYA3_R/OYA2_R/OYA1_R",
    "POSITION",
    "POSITION/SCALE_POINT",
]

ROTATION_CHANNELS = ("AngleX", "AngleY", "AngleZ")
POSITION_CHANNELS = ("PositionX", "PositionY", "PositionZ")

#: ``attribute`` in ``m_ClipBindingConstant`` tells which property a binding
#: drives, and how many curves that property owns. Most bundles only use 1 and
#: 4; the theater ``wnd``/``bok``/``sit`` clips mix quaternion and Euler
#: rotation curves in one clip.
ATTRIBUTE_CHANNELS = {
    1: POSITION_CHANNELS,
    2: ("RotationX", "RotationY", "RotationZ", "RotationW"),
    3: ("ScaleX", "ScaleY", "ScaleZ"),
    4: ROTATION_CHANNELS,
}

#: Rotation stored as four quaternion curves instead of three Euler ones.
QUATERNION_ATTRIBUTE = 2
#: Local scale; the packed motion format has no channel for it.
SCALE_ATTRIBUTE = 3
#: A property we do not model still owns exactly one curve.
UNKNOWN_ATTRIBUTE_CURVES = 1

SENTINEL_BEFORE = -3.4028234663852886e38


def path_hash(path: str) -> int:
    """The 32-bit key Unity uses for a Transform path: its CRC32."""
    return zlib.crc32(path.encode("utf-8"))


def _f32(word: int) -> float:
    return struct.unpack("<f", struct.pack("<I", word))[0]


def _i32(word: int) -> int:
    return word if word < 2 ** 31 else word - 2 ** 32


@dataclass(frozen=True)
class Key:
    time: float
    value: float


def _streamed_curves(words: list[int]) -> dict[int, list[Key]]:
    """Split ``m_StreamedClip.data`` into ``curveIndex -> [(time, value)]``."""
    curves: dict[int, list[Key]] = {}
    position = 0
    total = len(words)
    while position < total:
        if position + 1 > total:
            raise ValueError("streamed clip ends inside a frame header")
        time = _f32(words[position])
        count = _i32(words[position + 1])
        position += 2
        if count < 0 or position + count * 5 > total:
            raise ValueError(f"streamed frame at {position} claims {count} keys")
        for _ in range(count):
            index = _i32(words[position])
            value = _f32(words[position + 4])
            position += 5
            curves.setdefault(index, []).append(Key(time, value))
    return curves


def _constant_curves(values: list[float]) -> dict[int, list[Key]]:
    return {index: [Key(0.0, value)] for index, value in enumerate(values)}


def _dense_curves(
    frame_count: int, curve_count: int, sample_rate: float, begin: float,
    values: list[float], offset: int,
) -> dict[int, list[Key]]:
    curves: dict[int, list[Key]] = {}
    if curve_count == 0 or frame_count == 0:
        return curves
    if len(values) != frame_count * curve_count:
        raise ValueError("dense clip sample table does not match its shape")
    for frame in range(frame_count):
        row = values[frame * curve_count:(frame + 1) * curve_count]
        time = begin + frame / sample_rate
        for local, value in enumerate(row):
            curves.setdefault(offset + local, []).append(Key(time, value))
    return curves


def sample(keys: list[Key], time: float) -> float:
    """Linear interpolation between keys, clamped at both ends."""
    if not keys:
        return 0.0
    if time <= keys[0].time:
        return keys[0].value
    if time >= keys[-1].time:
        return keys[-1].value
    low, high = 0, len(keys) - 1
    while high - low > 1:
        middle = (low + high) // 2
        if keys[middle].time <= time:
            low = middle
        else:
            high = middle
    left, right = keys[low], keys[high]
    span = right.time - left.time
    if span <= 0:
        return right.value
    ratio = (time - left.time) / span
    return left.value + (right.value - left.value) * ratio


@dataclass
class PoseClip:
    """One clip resampled onto the 60 fps grid, keyed by bone path."""

    name: str
    length: float
    curves: dict[str, dict[str, list[float]]]

    def sample_times(self) -> list[float]:
        frames = int(round(self.length * SOURCE_FPS)) + 1
        return [index * SOURCE_FRAME for index in range(frames)]


def _quaternion_to_euler(x: float, y: float, z: float, w: float) -> tuple[float, float, float]:
    """Unity's ``Quaternion.eulerAngles``: the inverse of ``Internal_FromEulerRad``.

    Unity applies z, then x, then y, so the matrix is ``Ry Rx Rz`` and the
    angles read back as ``x = asin(-R12)``, ``y = atan2(R02, R22)``,
    ``z = atan2(R10, R11)``. Checked by round-tripping through the forward
    formula the Swift player uses.
    """
    norm = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / norm, y / norm, z / norm, w / norm
    r02 = 2 * (x * z + w * y)
    r12 = 2 * (y * z - w * x)
    r22 = 1 - 2 * (x * x + y * y)
    r10 = 2 * (x * y + w * z)
    r11 = 1 - 2 * (x * x + z * z)
    ex = math.asin(max(-1.0, min(1.0, -r12)))
    ey = math.atan2(r02, r22)
    ez = math.atan2(r10, r11)
    return tuple(math.degrees(value) for value in (ex, ey, ez))


def decode_clip(clip, paths: list[str] | None = None) -> PoseClip:
    """Decode one UnityPy ``AnimationClip`` into per-bone 60 fps curves."""
    names = {path_hash(path): path for path in (paths or BONE_PATHS)}
    container = clip.m_MuscleClip.m_Clip.data

    constant_values = list(container.m_ConstantClip.data)
    dense = container.m_DenseClip
    streamed = _streamed_curves(container.m_StreamedClip.data)
    streamed_count = container.m_StreamedClip.curveCount
    dense_count = int(dense.m_CurveCount)

    # Streamed first, then dense, then constant.
    curves: dict[int, list[Key]] = dict(streamed)
    curves.update(
        _dense_curves(
            dense.m_FrameCount, dense_count, dense.m_SampleRate,
            dense.m_BeginTime, list(dense.m_SampleArray), streamed_count,
        )
    )
    base = streamed_count + dense_count
    for index, value in enumerate(constant_values):
        curves[base + index] = [Key(0.0, value)]

    bindings = list(clip.m_ClipBindingConstant.genericBindings)
    total = base + len(constant_values)
    expected = sum(
        len(ATTRIBUTE_CHANNELS.get(b.attribute, (UNKNOWN_ATTRIBUTE_CURVES,)))
        for b in bindings
    )
    if total != expected:
        raise ValueError(
            f"{clip.m_Name}: {total} curves for {len(bindings)} bindings, "
            f"expected {expected}"
        )

    stop = float(clip.m_MuscleClip.m_StopTime)
    frames = int(round(stop * SOURCE_FPS)) + 1
    times = [index * SOURCE_FRAME for index in range(frames)]

    decoded: dict[str, dict[str, list[float]]] = {}
    unknown: list[int] = []
    unresolved: list[str] = []
    cursor = 0
    for order, binding in enumerate(bindings):
        channels = ATTRIBUTE_CHANNELS.get(binding.attribute)
        if channels is None:
            unknown.append(order)
            channels = (UNKNOWN_ATTRIBUTE_CURVES,)
        values = [
            [sample(curves.get(cursor + axis, []), time) for time in times]
            for axis in range(len(channels))
        ]
        path = names.get(binding.path & 0xFFFFFFFF)
        if path is None:
            unresolved.append(f"{binding.path & 0xFFFFFFFF:08x}")
        elif binding.attribute == QUATERNION_ATTRIBUTE:
            euler = [_quaternion_to_euler(*components) for components in zip(*values)]
            decoded.setdefault(path, {}).update({
                channel: [angle[axis] for angle in euler]
                for axis, channel in enumerate(ROTATION_CHANNELS)
            })
        elif binding.attribute != SCALE_ATTRIBUTE:
            decoded.setdefault(path, {}).update(dict(zip(channels, values)))
        cursor += len(channels)

    if unknown:
        print(
            f"warning: {clip.m_Name} has bindings with an unknown attribute "
            f"(orders {unknown[:8]})",
            file=sys.stderr,
        )
    if unresolved:
        print(
            f"warning: {clip.m_Name} binds {len(unresolved)} paths not in the "
            f"canonical table ({unresolved[:4]})",
            file=sys.stderr,
        )
    return PoseClip(clip.m_Name, stop, decoded)


def to_motion_asset(clip: PoseClip) -> dict:
    """Shape a decoded clip like the dance decoder's input for ``motion``."""
    curves = []
    for path, channels in clip.curves.items():
        for channel, values in channels.items():
            curves.append(
                {
                    "path": path,
                    "attribs": [f"property_type {channel}", "key_type FullFrame"],
                    "values": values,
                }
            )
    return {"time_length": clip.length, "curves": curves}


def load_bundle(path: Path) -> list[PoseClip]:
    import UnityPy

    environment = UnityPy.load(str(path))
    clips = []
    for obj in environment.objects:
        if obj.type.name != "AnimationClip":
            continue
        clips.append(decode_clip(obj.read()))
    return clips


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--clip", help="name or substring; omitted means every clip")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--fps", type=int, default=motion.TARGET_FPS)
    parser.add_argument("--list", action="store_true", help="print clips and their bindings")
    args = parser.parse_args(argv)

    clips = load_bundle(args.bundle)
    if not clips:
        print(f"{args.bundle}: no AnimationClips", file=sys.stderr)
        return 1

    if args.list:
        for clip in clips:
            print(f"{clip.name}  {clip.length:.3f} s  {len(clip.curves)} bones")
            for path in sorted(clip.curves):
                print(f"    {path}")
        return 0

    selected = [c for c in clips if args.clip is None or args.clip in c.name]
    if not selected:
        print(f"{args.bundle}: no clip matches {args.clip!r}", file=sys.stderr)
        return 1
    if len(selected) > 1 and args.output is not None:
        if args.output.is_dir():
            pass
        else:
            print("refusing to write several clips to one file", file=sys.stderr)
            return 1

    for clip in selected:
        packed = motion.build_motion(to_motion_asset(clip), fps=args.fps)
        text = json.dumps(packed, separators=(",", ":"), ensure_ascii=False)
        if args.output is None:
            print(text)
            continue
        target = args.output / f"{clip.name}.motion.json" if args.output.is_dir() else args.output
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        print(
            f"{target.name}: {len(text) / 1000:.1f} kB, "
            f"{len(packed['bones'])} bones, {packed['frames']} frames at {packed['fps']} fps"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
