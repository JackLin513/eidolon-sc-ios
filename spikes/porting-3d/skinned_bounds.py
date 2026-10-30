"""Skinned bounding box of an exported character, in glTF world space.

`Entity.visualBounds` in RealityKit reports the *bind* box of a skinned mesh:
the box of the mesh points before the skeleton is applied. The game models are
not authored with the drawn pose at the origin — the root joint carries a
translation (and sometimes a rotation) — so the box RealityKit reports can sit a
whole body height away from the figure that is actually drawn. Framing a camera
on it puts the character behind the Dynamic Island.

This computes the box the skeleton actually produces: the same transform chain
RealityKit uses, `global(joint) * inverseBind * point`, weighted per vertex.

    python3 spikes/porting-3d/skinned_bounds.py <model.gltf> [--json]

Writes `<stem>-bounds.json` next to the glTF with `min`/`max` in glTF world
units. Exported assets are local-only; nothing here is committed.
"""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

IDENTITY = [
    1.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 1.0,
]


def mat_mul(a, b):
    """Column-major 4x4 multiply, matching glTF's layout."""
    out = [0.0] * 16
    for col in range(4):
        for row in range(4):
            out[col * 4 + row] = sum(a[k * 4 + row] * b[col * 4 + k] for k in range(4))
    return out


def mat_from_trs(translation, rotation, scale):
    tx, ty, tz = translation
    qx, qy, qz, qw = rotation
    sx, sy, sz = scale
    x2, y2, z2 = qx + qx, qy + qy, qz + qz
    xx, xy, xz = qx * x2, qx * y2, qx * z2
    yy, yz, zz = qy * y2, qy * z2, qz * z2
    wx, wy, wz = qw * x2, qw * y2, qw * z2
    return [
        (1 - (yy + zz)) * sx, (xy + wz) * sx, (xz - wy) * sx, 0.0,
        (xy - wz) * sy, (1 - (xx + zz)) * sy, (yz + wx) * sy, 0.0,
        (xz + wy) * sz, (yz - wx) * sz, (1 - (xx + yy)) * sz, 0.0,
        tx, ty, tz, 1.0,
    ]


def local_matrix(node):
    if "matrix" in node:
        return list(node["matrix"])
    return mat_from_trs(
        node.get("translation", [0.0, 0.0, 0.0]),
        node.get("rotation", [0.0, 0.0, 0.0, 1.0]),
        node.get("scale", [1.0, 1.0, 1.0]),
    )


def world_matrices(gltf):
    nodes = gltf["nodes"]
    parents = {}
    for index, node in enumerate(nodes):
        for child in node.get("children", []):
            parents[child] = index
    roots = [i for i in range(len(nodes)) if i not in parents]
    scene = gltf.get("scenes", [{}])[gltf.get("scene", 0)]
    if "nodes" in scene:
        roots = list(scene["nodes"])
    out = {}
    stack = [(root, IDENTITY) for root in roots]
    while stack:
        index, parent = stack.pop()
        world = mat_mul(parent, local_matrix(nodes[index]))
        out[index] = world
        for child in nodes[index].get("children", []):
            stack.append((child, world))
    return out


COMPONENTS = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
WIDTH = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def read_accessor(gltf, blob, index):
    accessor = gltf["accessors"][index]
    view = gltf["bufferViews"][accessor["bufferView"]]
    fmt, size = COMPONENTS[accessor["componentType"]]
    width = WIDTH[accessor["type"]]
    stride = view.get("byteStride", size * width)
    base = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    out = []
    for i in range(accessor["count"]):
        offset = base + i * stride
        out.append(struct.unpack_from("<" + fmt * width, blob, offset))
    return out


def transform(matrix, point):
    x, y, z = point
    return (
        matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12],
        matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13],
        matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14],
    )


def skinned_bounds(gltf, blob):
    worlds = world_matrices(gltf)
    nodes = gltf["nodes"]
    lows = [float("inf")] * 3
    highs = [float("-inf")] * 3
    for mesh in gltf["meshes"]:
        for primitive in mesh["primitives"]:
            attributes = primitive["attributes"]
            node = primitive.get("_node")
            skin_index = 0
            for index, candidate in enumerate(nodes):
                if candidate.get("mesh") == gltf["meshes"].index(mesh) and "skin" in candidate:
                    node = index
                    skin_index = candidate["skin"]
                    break
            skin = gltf["skins"][skin_index]
            ibm = read_accessor(gltf, blob, skin["inverseBindMatrices"])
            joints = skin["joints"]
            mesh_world = worlds[node] if node is not None else IDENTITY
            palette = [
                mat_mul(worlds[joints[j]], ibm[j]) if j < len(ibm) else IDENTITY
                for j in range(len(joints))
            ]
            positions = read_accessor(gltf, blob, attributes["POSITION"])
            joint_sets = read_accessor(gltf, blob, attributes["JOINTS_0"])
            weights = read_accessor(gltf, blob, attributes["WEIGHTS_0"])
            for point, joint_ids, joint_weights in zip(positions, joint_sets, weights):
                total = sum(joint_weights) or 1.0
                x = y = z = 0.0
                for joint_id, weight in zip(joint_ids, joint_weights):
                    if weight == 0.0:
                        continue
                    jx, jy, jz = transform(palette[joint_id], point)
                    x += jx * weight
                    y += jy * weight
                    z += jz * weight
                wx, wy, wz = transform(mesh_world, (x / total, y / total, z / total))
                lows[0] = min(lows[0], wx)
                lows[1] = min(lows[1], wy)
                lows[2] = min(lows[2], wz)
                highs[0] = max(highs[0], wx)
                highs[1] = max(highs[1], wy)
                highs[2] = max(highs[2], wz)
    return lows, highs


def bounds_for(gltf_path: Path) -> dict:
    """The sidecar body for one exported glTF."""
    gltf = json.loads(gltf_path.read_text())
    blob = (gltf_path.parent / gltf["buffers"][0]["uri"]).read_bytes()
    lows, highs = skinned_bounds(gltf, blob)
    return {
        "min": [round(v, 5) for v in lows],
        "max": [round(v, 5) for v in highs],
        "space": "glTF world, skinned",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("gltf", type=Path)
    parser.add_argument("--json", action="store_true", help="print the box instead of writing it")
    args = parser.parse_args()

    box = bounds_for(args.gltf)
    if args.json:
        print(json.dumps(box))
        return
    stem = args.gltf.name[: -len(".gltf")]
    out = args.gltf.parent / f"{stem}-bounds.json"
    out.write_text(json.dumps(box, indent=1) + "\n")
    print(out)


if __name__ == "__main__":
    main()
