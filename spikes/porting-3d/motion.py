#!/usr/bin/env python3
"""Decode and shrink MLTD dance curves (issue #27).

Semantics confirmed against the shipped UnityFramework build (IL2CPP), not by
trial and error:

- ``CharacterImasMotionPlayer.SolveCurves`` truncates ``current_time`` to a
  whole 1/60 s frame before evaluating every curve, so a pose only exists on
  the 60 fps grid.
- Key types, from the ``KeyType`` enum plus ``GetKeyTime`` / ``GetKeyValue``
  and the per-type branches of ``SolveCurve``:

  ===== ================ ====================================================
  code  name             layout
  ===== ================ ====================================================
  0     FullFrame        one sample per 1/60 s
  1     Discreate        flat (time, value) pairs, sparse
  2     Const            one value
  3     FCurve           (time, value, inTangent, outTangent)
  4     Step             (time, value) pairs, hold the previous value
  5     Step_3Values     not evaluated by SolveCurve (returns 0)
  6     FullFrameOffset  values[0] is the start time, then 1/60 s samples
  7     DeltaFrame       values[0] is the frame length in seconds, then samples
  ===== ================ ====================================================

- FullFrame, Discreate, FullFrameOffset and DeltaFrame interpolate linearly
  between keys; FCurve uses a cubic Hermite whose tangents are scaled by the
  key spacing; Const and Step do not interpolate. Out-of-range times clamp to
  the first or last key.
- Rotations are ``Quaternion.Euler(angle)`` with the raw degrees (no negation,
  no axis swap), written with ``Transform.set_localRotation``; positions are
  written with ``Transform.set_localPosition`` only when the curve set has at
  least one Position curve.

Everything here is pure: it takes numbers and returns numbers.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

SOURCE_FPS = 60
SOURCE_FRAME = 1.0 / SOURCE_FPS

TARGET_FPS = 30

# 1/100 degree, so the deltas between adjacent 30 fps frames stay inside int16.
ANGLE_SCALE = 100

# 1/4000 Unity unit (0.25 mm), enough for positions that max out near 1 unit.
POSITION_SCALE = 4000

KEY_TYPES = {
    -1: "None",
    0: "FullFrame",
    1: "Discreate",
    2: "Const",
    3: "FCurve",
    4: "Step",
    5: "Step_3Values",
    6: "FullFrameOffset",
    7: "DeltaFrame",
}

ROTATION_CHANNELS = ("AngleX", "AngleY", "AngleZ")
POSITION_CHANNELS = ("PositionX", "PositionY", "PositionZ")

FORMAT = "eidolon.motion/1"


@dataclass(frozen=True)
class Curve:
    path: str
    property_type: str
    key_type: str
    values: list[float]


def curve_from_asset(entry: dict) -> Curve:
    """Build a curve from one ``CharacterImasMotionAsset`` entry."""
    attribs = dict(attrib.split(" ", 1) for attrib in entry["attribs"])
    return Curve(
        path=entry["path"],
        property_type=attribs["property_type"],
        key_type=attribs["key_type"],
        values=list(entry["values"]),
    )


# ---------------------------------------------------------------------------
# Decoding
# ---------------------------------------------------------------------------


def sample(curve: Curve, time: float) -> float:
    """Evaluate one curve at ``time`` seconds, as the player does."""
    values = curve.values
    if not values:
        return 0.0
    kind = curve.key_type
    if kind == "Const":
        return values[0]
    if kind == "FullFrame":
        return _uniform(values, start=0.0, frame=SOURCE_FRAME, time=time)
    if kind == "FullFrameOffset":
        return _uniform(values, start=values[0], frame=SOURCE_FRAME, time=time, offset=1)
    if kind == "DeltaFrame":
        return _uniform(values, start=0.0, frame=values[0], time=time, offset=1)
    if kind == "Discreate":
        return _pairs(values, time, hold=False)
    if kind == "Step":
        return _pairs(values, time, hold=True)
    if kind == "FCurve":
        return _hermite(values, time)
    return 0.0


def _uniform(
    values: list[float],
    start: float,
    frame: float,
    time: float,
    offset: int = 0,
) -> float:
    count = len(values) - offset
    if count <= 0 or frame <= 0.0:
        return 0.0
    position = (time - start) / frame
    index = math.floor(position)
    if index < 0:
        return values[offset]
    if index >= count - 1:
        return values[offset + count - 1]
    fraction = min(max(position - index, 0.0), 1.0)
    low = values[offset + index]
    high = values[offset + index + 1]
    return low + (high - low) * fraction


def _pairs(values: list[float], time: float, hold: bool) -> float:
    count = len(values) // 2
    if count == 0:
        return 0.0
    if time <= values[0]:
        return values[1]
    last = count - 1
    if time >= values[2 * last]:
        return values[2 * last + 1]
    low, high = 0, last
    while low < high:
        middle = (low + high + 1) // 2
        if values[2 * middle] <= time:
            low = middle
        else:
            high = middle - 1
    if hold:
        return values[2 * low + 1]
    start = values[2 * low]
    end = values[2 * (low + 1)]
    fraction = 0.0 if end == start else (time - start) / (end - start)
    fraction = min(max(fraction, 0.0), 1.0)
    return values[2 * low + 1] + (values[2 * (low + 1) + 1] - values[2 * low + 1]) * fraction


def _hermite(values: list[float], time: float) -> float:
    count = len(values) // 4
    if count == 0:
        return 0.0
    if time <= values[0]:
        return values[1]
    last = count - 1
    if time >= values[4 * last]:
        return values[4 * last + 1]
    low, high = 0, last
    while low < high:
        middle = (low + high + 1) // 2
        if values[4 * middle] <= time:
            low = middle
        else:
            high = middle - 1
    base = 4 * low
    start = values[base]
    end = values[base + 4]
    span = end - start
    u = 0.0 if span == 0.0 else min(max((time - start) / span, 0.0), 1.0)
    u2 = u * u
    u3 = u2 * u
    value0 = values[base + 1]
    out_tangent = values[base + 3]
    value1 = values[base + 5]
    in_tangent = values[base + 6]
    return (
        (2.0 * u3 - 3.0 * u2 + 1.0) * value0
        + (u3 - 2.0 * u2 + u) * span * out_tangent
        + (-2.0 * u3 + 3.0 * u2) * value1
        + (u3 - u2) * span * in_tangent
    )


# ---------------------------------------------------------------------------
# Compression
# ---------------------------------------------------------------------------


def fold_constants(curves: list[Curve]) -> tuple[list[tuple[str, str, float]], list[Curve]]:
    """Split curves that never change away from the ones that animate."""
    constants: list[tuple[str, str, float]] = []
    animated: list[Curve] = []
    for curve in curves:
        if curve.values and len(set(curve.values)) == 1:
            constants.append((curve.path, curve.property_type, curve.values[0]))
        else:
            animated.append(curve)
    return constants, animated


def downsample(values: list[float], source_fps: int, target_fps: int) -> list[float]:
    """Keep every n-th sample, always preserving the final pose."""
    step = source_fps // target_fps
    if step <= 1 or not values:
        return list(values)
    kept = values[::step]
    if kept[-1] != values[-1]:
        kept.append(values[-1])
    return kept


def quantise(values: list[float], scale: int = ANGLE_SCALE) -> tuple[int, list[int]]:
    """Pack values into int16-sized integers so JSON stays compact."""
    return scale, [round(value * scale) for value in values]


def dequantise(packed: list[int], scale: int) -> list[float]:
    return [value / scale for value in packed]


def build_motion(asset: dict, fps: int = TARGET_FPS) -> dict:
    """Turn a decoded dance into the compact on-device format.

    Every animated channel is resampled onto a uniform ``fps`` grid, quantised,
    and delta-encoded; a channel that never changes collapses to one integer.
    """
    curves = [curve_from_asset(entry) for entry in asset["curves"]]
    time_length = float(asset["time_length"])
    frames = int(round(time_length * fps)) + 1
    times = [index / fps for index in range(frames)]

    by_path: dict[str, dict[str, Curve]] = {}
    for curve in curves:
        by_path.setdefault(curve.path, {})[curve.property_type] = curve

    bones = []
    for path, channels in by_path.items():
        bone = {
            "path": path,
            "rot": _triple(channels, ROTATION_CHANNELS, times, ANGLE_SCALE),
        }
        if any(name in channels for name in POSITION_CHANNELS):
            bone["pos"] = _triple(channels, POSITION_CHANNELS, times, POSITION_SCALE)
        bones.append(bone)

    return {
        "format": FORMAT,
        "fps": fps,
        "frames": frames,
        "time_length": time_length,
        "angle_scale": ANGLE_SCALE,
        "position_scale": POSITION_SCALE,
        "bones": bones,
    }


def _triple(
    channels: dict[str, Curve],
    names: tuple[str, str, str],
    times: list[float],
    scale: int,
) -> list[int | list[int]]:
    return [_pack(channels[name], times, scale) if name in channels else 0 for name in names]


def _pack(curve: Curve, times: list[float], scale: int) -> int | list[int]:
    packed = [int(round(sample(curve, time) * scale)) for time in times]
    if not packed:
        return 0
    if len(set(packed)) == 1:
        return packed[0]
    return [packed[0]] + [high - low for low, high in zip(packed, packed[1:])]


def decode_channel(channel: int | list[int], frame: int) -> int:
    """Read one quantised channel value at ``frame`` from the packed form."""
    if isinstance(channel, int):
        return channel
    if not channel:
        return 0
    index = min(max(frame, 0), len(channel) - 1)
    total = channel[0]
    for delta in channel[1 : index + 1]:
        total += delta
    return total


def unpack_curve(channel: int | list[int], scale: float, frames: int) -> list[float]:
    """Expand a packed channel back to one value per frame."""
    if isinstance(channel, int):
        return [channel / scale] * frames
    return [decode_channel(channel, frame) / scale for frame in range(frames)]
