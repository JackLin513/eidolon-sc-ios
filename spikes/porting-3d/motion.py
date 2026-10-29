#!/usr/bin/env python3
"""Shrink a decoded MLTD dance track without losing the pose.

Three key types turn up in `CharacterImasMotionAsset`:

- `Const`      one value for the whole dance (74 of the 180 curves).
- `FullFrame`  one value per frame at 60 fps (`time_length * 60 + 1` values).
- `Discreate`  a shorter, uneven list whose timing is not yet established.

Everything here is pure: it takes numbers and returns numbers.
"""

from __future__ import annotations

from dataclasses import dataclass

# 1/100 of a degree, which covers +-180 degrees inside an int16.
QUANTISATION_SCALE = 100


@dataclass(frozen=True)
class Curve:
    path: str
    property_type: str
    key_type: str
    values: list[float]


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


def quantise(values: list[float], scale: int = QUANTISATION_SCALE) -> tuple[int, list[int]]:
    """Pack degrees into int16-sized integers so JSON stays compact."""
    return scale, [round(value * scale) for value in values]


def dequantise(packed: list[int], scale: int) -> list[float]:
    return [value / scale for value in packed]
