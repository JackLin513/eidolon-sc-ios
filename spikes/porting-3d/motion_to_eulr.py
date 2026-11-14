#!/usr/bin/env python3
"""Pack an `eidolon.motion/1` clip into the flat `EULR` binary the Unity spike reads.

`EULR`: magic, int32 frames, int32 trackCount, then per track
uint16 nameLength, UTF-8 path, one byte hasPosition, and
frames x (3 | 6) little-endian float32 (Euler degrees, then optional local
position).

    $ python3 spikes/porting-3d/motion_to_eulr.py \
        --motion build/mltd-spike/out/curves/loveig.motion.json \
        --output /tmp/mltd-unity-out/dance.bin --start 0 --frames 900
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path


def unpack(channel, scale: float, frames: int) -> list[float]:
    """Expand a packed delta channel; one pass instead of one scan per frame."""
    if isinstance(channel, int):
        return [channel / scale] * frames
    if not channel:
        return [0.0] * frames
    values = []
    total = channel[0]
    values.append(total / scale)
    for delta in channel[1:]:
        total += delta
        values.append(total / scale)
    while len(values) < frames:
        values.append(values[-1] if values else 0.0)
    return values[:frames]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--motion", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--frames", type=int, default=0, help="0 = to the end")
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--skip-position", action="store_true")
    arguments = parser.parse_args(argv)

    clip = json.loads(Path(arguments.motion).read_text("utf-8"))
    if clip.get("format") != "eidolon.motion/1":
        print("not an eidolon.motion/1 file", file=sys.stderr)
        return 1

    source_frames = int(clip["frames"])
    angle_scale = float(clip["angle_scale"])
    position_scale = float(clip["position_scale"])
    source_fps = int(clip.get("fps", 30))
    if source_fps != arguments.fps:
        print(f"warning: motion is {source_fps} fps, writing {arguments.fps}", file=sys.stderr)

    start = max(0, arguments.start)
    count = source_frames - start if arguments.frames <= 0 else min(arguments.frames, source_frames - start)
    if count <= 0:
        print("empty range", file=sys.stderr)
        return 1

    out = Path(arguments.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    bones = [b for b in clip["bones"] if b["path"] != "POSITION"]

    with out.open("wb") as handle:
        handle.write(b"EULR")
        handle.write(struct.pack("<ii", count, len(bones)))
        for bone in bones:
            path = bone["path"].encode("utf-8")
            handle.write(struct.pack("<H", len(path)))
            handle.write(path)

            rotation = [unpack(bone["rot"][axis], angle_scale, source_frames) for axis in range(3)]
            position = None
            if not arguments.skip_position and bone.get("pos"):
                position = [unpack(bone["pos"][axis], position_scale, source_frames) for axis in range(3)]
                if all(abs(v) < 1e-6 for axis in position for v in axis):
                    position = None
            handle.write(b"\x01" if position else b"\x00")

            for frame in range(start, start + count):
                values = [rotation[axis][frame] for axis in range(3)]
                if position:
                    values += [position[axis][frame] for axis in range(3)]
                handle.write(struct.pack("<%df" % len(values), *values))

    print(f"{len(bones)} tracks x {count} frames -> {out} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
