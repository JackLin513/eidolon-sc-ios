"""Pull the game's `<model>_sway.txt` TextAssets out of its Unity bundles.

`sway.py` turns those texts into the per-model sidecar the app's spring solver
reads. The texts live as TextAssets inside the character bundles, and the only
extractor the corpus was originally built with lived in a Blender venv that is
not part of the repo, so this script re-does that one step with the standard
library alone: it parses the UnityFS container (block table, LZ4 blocks) and
slices the plain text out.

Usage:
  # by bundle path, when the index already said which ones
  python3 spikes/porting-3d/extract_sway.py --out build/mltd-spike/out/sway \
      <body bundle> <head bundle>

  # or let the index resolve the idol and costume
  python3 spikes/porting-3d/extract_sway.py \
      --index build/mltd-index.jsonl --idol 014mir --costume ss002 \
      --out build/mltd-spike/out/sway

The game's files are read in place and never written.
"""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path


def _be32(data: bytes, offset: int) -> int:
    return struct.unpack_from(">I", data, offset)[0]


def _be64(data: bytes, offset: int) -> int:
    return struct.unpack_from(">Q", data, offset)[0]


def _cstr(data: bytes, offset: int) -> tuple[str, int]:
    end = data.index(0, offset)
    return data[offset:end].decode("utf-8", "replace"), end + 1


def lz4_block(source: bytes, size: int) -> bytes:
    """Decode one raw LZ4 block; Unity does not wrap its blocks in a frame."""
    out = bytearray()
    i = 0
    while i < len(source) and len(out) < size:
        token = source[i]
        i += 1
        literals = token >> 4
        if literals == 15:
            while True:
                extra = source[i]
                i += 1
                literals += extra
                if extra != 255:
                    break
        out += source[i : i + literals]
        i += literals
        if i >= len(source):
            break
        offset = source[i] | (source[i + 1] << 8)
        i += 2
        length = token & 0x0F
        if length == 15:
            while True:
                extra = source[i]
                i += 1
                length += extra
                if extra != 255:
                    break
        length += 4
        start = len(out) - offset
        for step in range(length):
            out.append(out[start + step])
    return bytes(out[:size])


def unpack(path: Path) -> bytes:
    """Return the serialized-file payload of one UnityFS bundle."""
    data = path.read_bytes()
    if data[:7] != b"UnityFS":
        raise ValueError(f"{path} is not a UnityFS bundle")
    offset = 8
    version = _be32(data, offset)
    offset += 4
    _unity_version, offset = _cstr(data, offset)
    _revision, offset = _cstr(data, offset)
    offset += 8  # total size
    info_size = _be32(data, offset)
    offset += 4
    info_unpacked = _be32(data, offset)
    offset += 4
    flags = _be32(data, offset)
    offset += 4
    if version >= 7:
        offset = (offset + 15) & ~15
    at_end = bool(flags & 0x80)
    kind = flags & 0x3F
    if at_end:
        info = data[len(data) - info_size :]
        blocks_at = offset
    else:
        info = data[offset : offset + info_size]
        blocks_at = offset + info_size
    if kind in (2, 3):
        info = lz4_block(info, info_unpacked)
    elif kind == 1:
        raise ValueError("LZMA block info is not supported")
    cursor = 16  # the block table starts after its hash
    count = _be32(info, cursor)
    cursor += 4
    blocks = []
    for _ in range(count):
        unpacked = _be32(info, cursor)
        packed = _be32(info, cursor + 4)
        flags16 = struct.unpack_from(">H", info, cursor + 8)[0]
        cursor += 10
        blocks.append((unpacked, packed, flags16 & 0x3F))
    out = bytearray()
    for unpacked, packed, block_kind in blocks:
        chunk = data[blocks_at : blocks_at + packed]
        blocks_at += packed
        out += chunk if block_kind == 0 else lz4_block(chunk, unpacked)
    return bytes(out)


def sway_text(payload: bytes) -> str | None:
    """The `<model>_sway.txt` body, found by its first stanza."""
    start = payload.find(b"SwayManager:")
    if start < 0:
        return None
    end = start
    while end < len(payload) and (payload[end] in (9, 10, 13) or 32 <= payload[end] < 127):
        end += 1
    return payload[start:end].decode("utf-8")


def resolve(index: Path, idol: str, costume: str) -> list[Path]:
    """Every cached bundle whose index entry names that idol and costume."""
    found = []
    for line in index.read_text("utf-8").splitlines():
        entry = json.loads(line)
        objects = entry.get("objects", {})
        if not objects.get("TextAsset") or not objects.get("SkinnedMeshRenderer"):
            continue
        if idol not in entry.get("idols", []) or costume not in entry.get("costumes", []):
            continue
        found.append(Path(entry["file"]))
    return found


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("bundles", nargs="*", type=Path)
    parser.add_argument("--index", type=Path)
    parser.add_argument("--idol")
    parser.add_argument("--costume")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    bundles = list(args.bundles)
    if args.index and args.idol and args.costume:
        bundles += resolve(args.index, args.idol, args.costume)
    if not bundles:
        parser.error("give bundle paths, or --index with --idol and --costume")

    args.out.mkdir(parents=True, exist_ok=True)
    written = 0
    for path in bundles:
        text = sway_text(unpack(path))
        if text is None:
            print(f"{path.name}: no sway text")
            continue
        stem = text.splitlines()[0].split(":", 1)[1].strip().replace("/", "_") or path.name
        destination = args.out / f"{stem}.sway.txt"
        destination.write_text(text + "\n", encoding="utf-8")
        print(f"{path.name} -> {destination.name} ({text.count(chr(10)) + 1} lines)")
        written += 1
    print(f"{written} sway text(s) in {args.out}")


if __name__ == "__main__":
    main()
