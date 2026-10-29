#!/usr/bin/env python3
"""Write a skinned glTF 2.0 file from decoded Unity data.

Unity is left-handed, glTF is right-handed: every transform, position, normal,
bind matrix and triangle is converted here, so nothing downstream has to guess.
"""

from __future__ import annotations

import base64
import json
import struct
from dataclasses import dataclass, field
from pathlib import Path

FLOAT = 5126
UNSIGNED_BYTE = 5121
UNSIGNED_SHORT = 5123
ARRAY_BUFFER = 34962
ELEMENT_ARRAY_BUFFER = 34963


def flip_vector(vector: tuple) -> tuple:
    """(x, y, z) -> (x, y, -z)."""
    return (vector[0], vector[1], -vector[2])


def flip_quaternion(quaternion: tuple) -> tuple:
    """Conjugate by diag(1, 1, -1).

    The mirror sends the axis through (x, y, -z) *and* negates the angle, which
    works out to negating x and y while keeping z.
    """
    x, y, z, w = quaternion
    return (-x, -y, z, w)


def flip_matrix(matrix: tuple) -> tuple:
    """F * M * F for F = diag(1, 1, -1, 1), on a column-major 4x4."""
    return tuple(
        -value if ((index % 4 == 2) != (index // 4 == 2)) else value
        for index, value in enumerate(matrix)
    )


def flip_triangles(triangles: list[tuple[int, int, int]]) -> list[tuple[int, int, int]]:
    return [(a, c, b) for a, b, c in triangles]


@dataclass
class _Chunks:
    blob: bytearray = field(default_factory=bytearray)
    buffer_views: list = field(default_factory=list)
    accessors: list = field(default_factory=list)

    def _view(self, payload: bytes, target: int | None) -> int:
        while len(self.blob) % 4:
            self.blob.append(0)
        view = {"buffer": 0, "byteOffset": len(self.blob), "byteLength": len(payload)}
        if target is not None:
            view["target"] = target
        self.blob.extend(payload)
        self.buffer_views.append(view)
        return len(self.buffer_views) - 1

    def floats(self, values, component_count: int, kind: str = "VEC3") -> int:
        flat = [component for value in values for component in value]
        payload = struct.pack("<" + "f" * len(flat), *flat)
        view = self._view(payload, ARRAY_BUFFER)
        self.accessors.append(
            {
                "bufferView": view,
                "componentType": FLOAT,
                "count": len(values),
                "type": kind,
                "min": [min(v[i] for v in values) for i in range(component_count)],
                "max": [max(v[i] for v in values) for i in range(component_count)],
            }
        )
        return len(self.accessors) - 1

    def bytes(self, values, kind: str) -> int:
        flat = [component for value in values for component in value]
        payload = bytes(flat)
        view = self._view(payload, ARRAY_BUFFER)
        self.accessors.append(
            {
                "bufferView": view,
                "componentType": UNSIGNED_BYTE,
                "count": len(values),
                "type": kind,
            }
        )
        return len(self.accessors) - 1

    def indices(self, triangles: list[tuple[int, int, int]]) -> int:
        flat = [index for triangle in triangles for index in triangle]
        payload = struct.pack("<" + "H" * len(flat), *flat)
        view = self._view(payload, ELEMENT_ARRAY_BUFFER)
        self.accessors.append(
            {
                "bufferView": view,
                "componentType": UNSIGNED_SHORT,
                "count": len(flat),
                "type": "SCALAR",
            }
        )
        return len(self.accessors) - 1


@dataclass
class GltfDocument:
    chunks: _Chunks
    nodes: list
    meshes: list
    skins: list
    materials: list = field(default_factory=list)
    images: list = field(default_factory=list)
    textures: list = field(default_factory=list)
    root_nodes: list = field(default_factory=lambda: [0])

    def as_dict(self) -> dict:
        document = {
            "asset": {"version": "2.0", "generator": "eidolon-3d-spike"},
            "scene": 0,
            "scenes": [{"nodes": self.root_nodes}],
            "nodes": self.nodes,
            "meshes": self.meshes,
            "skins": self.skins,
            "bufferViews": self.chunks.buffer_views,
            "accessors": self.chunks.accessors,
            "buffers": [
                {"byteLength": len(self.chunks.blob), "uri": "character.bin"}
            ],
        }
        if self.materials:
            document["materials"] = self.materials
            document["images"] = self.images
            document["textures"] = self.textures
            document["samplers"] = [{"magFilter": 9729, "minFilter": 9987}]
        return document

    def write(self, directory: Path, name: str = "character") -> Path:
        (directory / f"{name}.bin").write_bytes(bytes(self.chunks.blob))
        path = directory / f"{name}.gltf"
        path.write_text(json.dumps(self.as_dict(), indent=2), "utf-8")
        return path


def matrix_from_trs(position, rotation, scale) -> list[list[float]]:
    """A row-major 4x4 from translation, unit quaternion (x, y, z, w) and scale."""
    x, y, z, w = rotation
    norm = (x * x + y * y + z * z + w * w) ** 0.5 or 1.0
    x, y, z, w = x / norm, y / norm, z / norm, w / norm
    sx, sy, sz = scale
    return [
        [
            (1 - 2 * (y * y + z * z)) * sx,
            (2 * (x * y - z * w)) * sx,
            (2 * (x * z + y * w)) * sx,
            position[0],
        ],
        [
            (2 * (x * y + z * w)) * sy,
            (1 - 2 * (x * x + z * z)) * sy,
            (2 * (y * z - x * w)) * sy,
            position[1],
        ],
        [
            (2 * (x * z - y * w)) * sz,
            (2 * (y * z + x * w)) * sz,
            (1 - 2 * (x * x + y * y)) * sz,
            position[2],
        ],
        [0.0, 0.0, 0.0, 1.0],
    ]


def matrix_multiply(left, right) -> list[list[float]]:
    return [
        [
            sum(left[row][k] * right[k][column] for k in range(4))
            for column in range(4)
        ]
        for row in range(4)
    ]


def matrix_inverse(matrix) -> list[list[float]]:
    """Gauss-Jordan inverse; the caller only ever feeds affine transforms."""
    augmented = [list(row) + [1.0 if i == j else 0.0 for j in range(4)] for i, row in enumerate(matrix)]
    for column in range(4):
        pivot = max(range(column, 4), key=lambda row: abs(augmented[row][column]))
        augmented[column], augmented[pivot] = augmented[pivot], augmented[column]
        scale = augmented[column][column]
        if abs(scale) < 1e-12:
            raise ZeroDivisionError("singular matrix")
        augmented[column] = [value / scale for value in augmented[column]]
        for row in range(4):
            if row == column:
                continue
            factor = augmented[row][column]
            if factor:
                augmented[row] = [
                    value - factor * pivot_value
                    for value, pivot_value in zip(augmented[row], augmented[column])
                ]
    return [row[4:] for row in augmented]


def column_major(rows) -> tuple:
    """glTF wants matrices flattened column by column."""
    return tuple(rows[row][column] for column in range(4) for row in range(4))
