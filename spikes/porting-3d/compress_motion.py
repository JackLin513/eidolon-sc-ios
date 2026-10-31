#!/usr/bin/env python3
"""Write the compact on-device dance curve file (issue #27).

    V=build/mltd-spike/venv/bin/python
    $V spikes/porting-3d/compress_motion.py \
       --input  build/mltd-spike/out/il2cpp/loveig-curves.json \
       --output build/mltd-spike/out/curves/loveig.motion.json \
       --verify

``--verify`` re-samples every source curve on the output grid and compares it
with the packed channel, so the reported error is the real end-to-end loss
(interpolation + 30 fps + quantisation), not a guess.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import motion


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--fps", type=int, default=motion.TARGET_FPS)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()

    asset = json.loads(args.input.read_text())
    packed = motion.build_motion(asset, fps=args.fps)
    text = json.dumps(packed, separators=(",", ":"), ensure_ascii=False)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text)

    print(f"{args.output}: {len(text) / 1_000_000:.2f} MB, "
          f"{len(packed['bones'])} bones, {packed['frames']} frames at {packed['fps']} fps")

    if args.verify:
        verify(asset, packed)
    return 0


def verify(asset: dict, packed: dict) -> None:
    fps = packed["fps"]
    frames = packed["frames"]
    times = [index / fps for index in range(frames)]

    by_path: dict[str, dict[str, motion.Curve]] = {}
    for entry in asset["curves"]:
        curve = motion.curve_from_asset(entry)
        by_path.setdefault(curve.path, {})[curve.property_type] = curve

    worst_angle = 0.0
    worst_position = 0.0
    seed_max = 0
    delta_max = 0
    animated = 0
    for bone in packed["bones"]:
        channels = by_path[bone["path"]]
        for names, key, scale, counter in (
            (motion.ROTATION_CHANNELS, "rot", motion.ANGLE_SCALE, "angle"),
            (motion.POSITION_CHANNELS, "pos", motion.POSITION_SCALE, "position"),
        ):
            if key not in bone:
                continue
            for name, channel in zip(names, bone[key]):
                source = channels.get(name)
                if source is None:
                    # Absent channel: the game leaves this axis at zero, which
                    # is what the packed channel already stores.
                    assert channel == 0, (bone["path"], name, channel)
                    continue
                restored = motion.unpack_curve(channel, scale, frames)
                error = max(
                    abs(motion.sample(source, time) - value)
                    for time, value in zip(times, restored)
                )
                if counter == "angle":
                    worst_angle = max(worst_angle, error)
                else:
                    worst_position = max(worst_position, error)
                if isinstance(channel, list):
                    animated += 1
                    seed_max = max(seed_max, abs(channel[0]))
                    delta_max = max(delta_max, max(abs(delta) for delta in channel[1:]))

    print(f"animated channels: {animated}")
    print(f"worst angle error:    {worst_angle:.6f} deg")
    print(f"worst position error: {worst_position:.6f} units")
    print(f"largest seed: {seed_max}, largest delta: {delta_max} "
          f"(int16 limit {32767})")
    if delta_max > 32767 or seed_max > 32767:
        print("warning: a channel exceeds the int16 range")


if __name__ == "__main__":
    raise SystemExit(main())
