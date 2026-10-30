#!/usr/bin/env python3
"""Decode Unity vertex streams into plain values.

Unity stores a mesh as a byte buffer plus a channel table describing where each
attribute lives. `m_DataSize` holds that buffer; the streams are laid out back to
back, each aligned to 16 bytes. Nothing here knows about UnityPy or file formats —
it takes bytes and channel descriptions.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

STREAM_ALIGNMENT = 16

# Unity's VertexAttributeFormat for the subset MLTD meshes actually use.
_FLOAT32 = 0
_UNORM8 = 2
_UINT32 = 10
_SINT32 = 11

_FORMATS = {
    _FLOAT32: ("f", 4),
    _UNORM8: ("B", 1),
    _SINT32: ("i", 4),
    # Bone indices widened to 32 bits; older revisions of the exporter only
    # ever saw the 8-bit form.
    _UINT32: ("I", 4),
}


@dataclass(frozen=True)
class Channel:
    dimension: int
    format: int
    offset: int
    stream: int


def channel_size(channel: Channel) -> int:
    """Bytes one vertex occupies in this channel."""
    _, unit = _FORMATS[channel.format]
    return channel.dimension * unit


def stream_strides(channels: list[Channel]) -> dict[int, int]:
    """The stride of each stream, taken from the channel furthest into it."""
    strides: dict[int, int] = {}
    for channel in channels:
        if channel.dimension == 0:
            continue
        end = channel.offset + channel_size(channel)
        strides[channel.stream] = max(strides.get(channel.stream, 0), end)
    return strides


def stream_offsets(channels: list[Channel], vertex_count: int) -> dict[int, int]:
    """Where each stream starts inside `m_DataSize`, honouring 16-byte alignment."""
    strides = stream_strides(channels)
    offsets: dict[int, int] = {}
    cursor = 0
    for stream in sorted(strides):
        offsets[stream] = cursor
        size = strides[stream] * vertex_count
        cursor += size + (-size % STREAM_ALIGNMENT)
    return offsets


def decode_channel(
    data: bytes, stride: int, vertex_count: int, channel: Channel
) -> list[tuple]:
    """Read every vertex's value for one channel."""
    if channel.dimension == 0:
        return []
    code, unit = _FORMATS[channel.format]
    unpack = struct.Struct("<" + code * channel.dimension).unpack_from
    return [
        unpack(data, channel.offset + index * stride)
        for index in range(vertex_count)
    ]


def decode_triangles(index_buffer: bytes, use_16bit: bool) -> list[tuple[int, int, int]]:
    """Split an index buffer into triangles, restarting after the strip sentinel."""
    restart = 0xFFFF if use_16bit else 0xFFFFFFFF
    unit = 2 if use_16bit else 4
    count = len(index_buffer) // unit
    indices = struct.unpack_from("<" + ("H" if use_16bit else "I") * count, index_buffer)

    triangles: list[tuple[int, int, int]] = []
    run: list[int] = []
    for index in indices:
        if index == restart:
            run.clear()
            continue
        run.append(index)
        if len(run) == 3:
            triangles.append((run[0], run[1], run[2]))
            run.clear()
    return triangles


def flip_handedness(
    positions: list[tuple[float, float, float]],
    normals: list[tuple[float, float, float]],
    triangles: list[tuple[int, int, int]] | None = None,
) -> tuple[list[tuple[float, float, float]], list[tuple[float, float, float]], list[tuple[int, int, int]]]:
    """Unity is left-handed, USD and glTF are right-handed: negate Z, reverse winding."""
    flipped_positions = [(x, y, -z) for x, y, z in positions]
    flipped_normals = [(x, y, -z) for x, y, z in normals]
    flipped_triangles = [(a, c, b) for a, b, c in (triangles or [])]
    return flipped_positions, flipped_normals, flipped_triangles
