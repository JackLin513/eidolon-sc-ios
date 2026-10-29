#!/usr/bin/env python3
"""Build a skinned glTF from MLTD head/body bundles.

The head and body ship as separate bundles with separate skeletons that share a
few bones by name (`KUBI`, `ATAMA`, ...). This merges them into one skeleton so
a single skin can drive every mesh.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gltf_export import (
    GltfDocument,
    _Chunks,
    column_major,
    flip_matrix,
    flip_quaternion,
    flip_vector,
    matrix_from_trs,
    matrix_inverse,
    matrix_multiply,
)
from unity_mesh import flip_handedness
from unity_rig import Node, load, read_nodes, read_skinned_meshes


@dataclass
class Merged:
    nodes: list[Node] = field(default_factory=list)
    parent_of: dict[int, int | None] = field(default_factory=dict)
    index_of_name: dict[str, int] = field(default_factory=dict)

    def add(self, node: Node, parent: int | None) -> int:
        index = len(self.nodes)
        self.nodes.append(node)
        self.parent_of[index] = parent
        self.index_of_name.setdefault(node.name, index)
        return index


def merge_skeleton(body_bundle: Path, head_bundle: Path | None) -> tuple[Merged, dict, dict]:
    """One skeleton for both bundles; returns the per-bundle path-id mappings."""
    body_nodes = read_nodes(load(str(body_bundle)))
    merged = Merged()

    body_map: dict[int, int] = {}

    def resolve_body(path_id: int) -> int:
        if path_id in body_map:
            return body_map[path_id]
        node = body_nodes[path_id]
        parent = resolve_body(node.parent) if node.parent is not None else None
        body_map[path_id] = merged.add(node, parent)
        return body_map[path_id]

    for path_id in body_nodes:
        resolve_body(path_id)

    head_map: dict[int, int] = {}
    if head_bundle is not None:
        head_nodes = read_nodes(load(str(head_bundle)))

        def resolve_head(path_id: int) -> int:
            if path_id in head_map:
                return head_map[path_id]
            node = head_nodes[path_id]
            if node.name in merged.index_of_name:
                head_map[path_id] = merged.index_of_name[node.name]
                return head_map[path_id]
            parent = resolve_head(node.parent) if node.parent is not None else None
            head_map[path_id] = merged.add(node, parent)
            return head_map[path_id]

        for path_id in head_nodes:
            resolve_head(path_id)

    return merged, body_map, head_map


def world_of(merged: Merged, index: int) -> list[list[float]]:
    node = merged.nodes[index]
    world = matrix_from_trs(node.position, node.rotation, node.scale)
    parent = merged.parent_of[index]
    while parent is not None:
        parent_node = merged.nodes[parent]
        world = matrix_multiply(
            matrix_from_trs(parent_node.position, parent_node.rotation, parent_node.scale),
            world,
        )
        parent = merged.parent_of[parent]
    return world


def primitive_colors(primitive) -> list[tuple[int, int, int, int]]:
    """Unity stores vertex colour as UNorm8x4 in RGBA order, same as glTF."""
    return [tuple(int(component) for component in value) for value in primitive.colors]


def build(body: Path, head: Path | None, arguments_out: Path) -> GltfDocument:
    merged, body_map, head_map = merge_skeleton(body, head)

    chunks = _Chunks()
    gltf_nodes = []
    for index, node in enumerate(merged.nodes):
        gltf_nodes.append(
            {
                "name": node.name,
                "translation": list(flip_vector(node.position)),
                "rotation": list(flip_quaternion(node.rotation)),
                "scale": list(node.scale),
            }
        )
    children: dict[int, list[int]] = {}
    for index, parent in merged.parent_of.items():
        if parent is not None:
            children.setdefault(parent, []).append(index)
    for parent, child_indices in children.items():
        gltf_nodes[parent]["children"] = child_indices

    sources: list[tuple[Path, dict[int, int]]] = [(body, body_map)]
    if head is not None:
        sources.append((head, head_map))

    joint_order: list[int] = []
    primitives = []
    materials: list[dict] = []
    images: list[dict] = []
    textures: list[dict] = []
    textures_dir = arguments_out / "textures"
    textures_dir.mkdir(parents=True, exist_ok=True)
    for bundle, mapping in sources:
        for mesh in read_skinned_meshes(load(str(bundle))):
            local_joints = [mapping[path_id] for path_id in mesh.bone_paths]
            for joint in local_joints:
                if joint not in joint_order:
                    joint_order.append(joint)
            material_index = None
            if mesh.image is not None:
                file_name = f"textures/{len(images):02d}_{mesh.name.split('(')[0]}.png"
                mesh.image.save(arguments_out / file_name)
                images.append({"uri": file_name})
                textures.append({"source": len(images) - 1, "sampler": 0})
                materials.append(
                    {
                        "name": mesh.material_name or mesh.name,
                        "pbrMetallicRoughness": {
                            "baseColorTexture": {"index": len(textures) - 1},
                            "metallicFactor": 0.0,
                            "roughnessFactor": 0.9,
                        },
                        "doubleSided": True,
                    }
                )
                material_index = len(materials) - 1
            primitives.append((mesh, local_joints, material_index))

    skin_of_joint = {joint: position for position, joint in enumerate(joint_order)}

    for mesh, local_joints, material_index in primitives:
        primitive = mesh.primitive
        positions, normals, triangles = flip_handedness(
            primitive.positions, primitive.normals, primitive.triangles
        )
        attributes = {
            "POSITION": chunks.floats(positions, 3, "VEC3"),
            "NORMAL": chunks.floats(normals, 3, "VEC3"),
            "TEXCOORD_0": chunks.floats(
                [(u, 1.0 - v) for u, v in primitive.uvs], 2, "VEC2"
            ),
            "JOINTS_0": chunks.bytes(
                [[skin_of_joint[local_joints[int(i)]] for i in value] for value in primitive.joints],
                "VEC4",
            ),
            "WEIGHTS_0": chunks.floats(
                [[max(0.0, float(w)) for w in value] for value in primitive.weights],
                4,
                "VEC4",
            ),
        }
        if any(any(component for component in value) for value in primitive.colors):
            attributes["COLOR_0"] = chunks.normalized_bytes(
                primitive_colors(primitive), "VEC4"
            )
        entry = {"attributes": attributes, "indices": chunks.indices(triangles)}
        if material_index is not None:
            entry["material"] = material_index
        chunks.primitives = getattr(chunks, "primitives", []) + [entry]

    inverse_bind = chunks.floats(
        [
            flip_matrix(column_major(matrix_inverse(world_of(merged, joint))))
            for joint in joint_order
        ],
        16,
        "MAT4",
    )

    mesh_index = len(gltf_nodes)
    gltf_nodes.append(
        {"name": "character", "mesh": 0, "skin": 0, "children": []}
    )
    roots = [index for index, parent in merged.parent_of.items() if parent is None]

    document = GltfDocument(
        chunks=chunks,
        nodes=gltf_nodes,
        meshes=[{"name": "character", "primitives": getattr(chunks, "primitives", [])}],
        skins=[
            {
                "joints": joint_order,
                "inverseBindMatrices": inverse_bind,
                "skeleton": joint_order[0],
            }
        ],
        root_nodes=roots + [mesh_index],
        materials=materials,
        images=images,
        textures=textures,
    )
    return document


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--body", type=Path, required=True)
    parser.add_argument("--head", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--name", default="character")
    arguments = parser.parse_args(argv)

    document = build(arguments.body, arguments.head, arguments.out)
    print(document.write(arguments.out, arguments.name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
