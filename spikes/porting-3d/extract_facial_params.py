#!/usr/bin/env python3
"""Export the game's face expression table (`FaceScrObj.charaParams`).

The table lives in the downloaded bundle `facial_chara.unity3d`: one
MonoBehaviour whose script class is `Imas.FaceScrObj`, holding

    FaceBlendParam { string cid; MeshBlendParam[] expressions; }
    MeshBlendParam { float[] param32open; float[] param32close; }

`param32open` is the eyes-open form of an expression and `param32close` the
eyes-closed one, one weight per blend shape channel (0..100), which is why
blinking is a straight lerp between the two.

The game cache stores bundles under hashed names, so the bundle is found by
content: scan the cache for the bundle whose MonoScript list names FaceScrObj.
The CDN no longer serves these files anonymously, so this reads the copy the
game itself downloaded.

    $ python3 spikes/porting-3d/extract_facial_params.py \
        --cache ~/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents \
        --output /tmp/mltd-unity-out/facial_chara.json
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys

import UnityPy

SEARCH_ROOTS = ("Cache00", "Cache01", "Cache02", "Cache05")


def find_bundle(cache: str) -> str | None:
    for root in SEARCH_ROOTS:
        base = os.path.join(cache, root)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirnames, filenames in os.walk(base):
            for name in filenames:
                path = os.path.join(dirpath, name)
                try:
                    if not 4096 < os.path.getsize(path) < 8_000_000:
                        continue
                    with open(path, "rb") as handle:
                        if handle.read(7) != b"UnityFS":
                            continue
                except OSError:
                    continue
                try:
                    environment = UnityPy.load(path)
                    for obj in environment.objects:
                        if obj.type.name != "MonoScript":
                            continue
                        if obj.read().m_ClassName == "FaceScrObj":
                            return path
                except Exception:
                    continue
    return None


def parse_payload(raw: bytes) -> list[dict]:
    """Unity's serialized MonoBehaviour: header, then `charaParams`."""
    offset = 0

    def align() -> None:
        nonlocal offset
        offset = (offset + 3) & ~3

    def i32() -> int:
        nonlocal offset
        value = struct.unpack_from("<i", raw, offset)[0]
        offset += 4
        return value

    def string() -> str:
        nonlocal offset
        length = i32()
        value = raw[offset:offset + length].decode("utf-8", "replace")
        offset += length
        align()
        return value

    offset += 4 + 8          # m_GameObject
    offset += 1
    align()                  # m_Enabled
    offset += 4 + 8          # m_Script
    string()                 # m_Name

    characters: list[dict] = []
    for _ in range(i32()):
        cid = string()
        expressions = []
        for _ in range(i32()):
            size = i32()
            opened = list(struct.unpack_from(f"<{size}f", raw, offset))
            offset += 4 * size
            size = i32()
            closed = list(struct.unpack_from(f"<{size}f", raw, offset))
            offset += 4 * size
            expressions.append({"param32open": opened, "param32close": closed})
        characters.append({"cid": cid, "expressions": expressions})
    return characters


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", required=True, type=str)
    parser.add_argument("--output", required=True, type=str)
    arguments = parser.parse_args(argv)

    bundle = find_bundle(arguments.cache)
    if bundle is None:
        print("facial_chara bundle not found in the cache", file=sys.stderr)
        return 1

    environment = UnityPy.load(bundle)
    payload = None
    for obj in environment.objects:
        if obj.type.name == "MonoBehaviour":
            payload = obj.get_raw_data()
            break
    if payload is None:
        print("no MonoBehaviour in " + bundle, file=sys.stderr)
        return 1

    characters = parse_payload(payload)
    with open(arguments.output, "w", encoding="utf-8") as handle:
        json.dump(characters, handle, ensure_ascii=False)
    print(f"{len(characters)} characters, "
          f"{len(characters[0]['expressions']) if characters else 0} expressions -> {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
