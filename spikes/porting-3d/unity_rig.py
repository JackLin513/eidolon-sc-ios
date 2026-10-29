#!/usr/bin/env python3
"""Read a Unity character bundle into a skeleton plus skinned meshes.

Deliberately thin: it walks UnityPy objects and returns plain values, so the
glTF writer never has to know about Unity's object graph.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import UnityPy

from unity_mesh import (
    Channel,
    decode_channel,
    decode_triangles,
    stream_offsets,
    stream_strides,
)

POSITION = Channel(dimension=3, format=0, offset=0, stream=0)
NORMAL = Channel(dimension=3, format=0, offset=12, stream=0)
TEXCOORD0 = Channel(dimension=2, format=0, offset=4, stream=1)
COLOR = Channel(dimension=4, format=2, offset=0, stream=1)
WEIGHTS = Channel(dimension=4, format=0, offset=0, stream=2)
BONE_INDICES = Channel(dimension=4, format=11, offset=16, stream=2)


@dataclass(frozen=True)
class Node:
    path_id: int
    name: str
    parent: int | None
    position: tuple[float, float, float]
    rotation: tuple[float, float, float, float]
    scale: tuple[float, float, float]


@dataclass
class Primitive:
    positions: list
    normals: list
    uvs: list
    colors: list
    weights: list
    joints: list
    triangles: list


def read_main_texture(env, renderer):
    """The `_MainTex` texture behind a renderer's first material, if any."""
    for material_pointer in renderer.m_Materials:
        material = material_pointer.read()
        for entry in material.m_SavedProperties.m_TexEnvs or []:
            name, environment = entry[0], entry[1]
            if name == "_MainTex":
                texture = environment.m_Texture.read()
                return material.m_Name, texture.image
    return None, None


@dataclass
class SkinnedMesh:
    name: str
    primitive: Primitive
    bone_paths: list[int]
    bindposes: list[tuple[float, ...]] = field(default_factory=list)
    material_name: str | None = None
    image: object | None = None


def _vec(value) -> tuple[float, float, float]:
    return (value.x, value.y, value.z)


def matrix_tuple(matrix) -> tuple[float, ...]:
    """Unity's eRC fields, flattened column-major the way glTF wants them."""
    return tuple(
        getattr(matrix, f"e{row}{column}")
        for column in range(4)
        for row in range(4)
    )


def read_nodes(env) -> dict[int, Node]:
    """Every Transform in the bundle, keyed by path id."""
    nodes: dict[int, Node] = {}
    for obj in env.objects:
        if obj.type.name != "Transform":
            continue
        transform = obj.read()
        father = transform.m_Father
        rotation = transform.m_LocalRotation
        nodes[obj.path_id] = Node(
            path_id=obj.path_id,
            name=transform.m_GameObject.read().m_Name,
            parent=father.path_id if father else None,
            position=_vec(transform.m_LocalPosition),
            rotation=(rotation.x, rotation.y, rotation.z, rotation.w),
            scale=_vec(transform.m_LocalScale),
        )
    return nodes


def read_skinned_meshes(env) -> list[SkinnedMesh]:
    meshes: list[SkinnedMesh] = []
    for obj in env.objects:
        if obj.type.name != "SkinnedMeshRenderer":
            continue
        renderer = obj.read()
        mesh = renderer.m_Mesh.read()
        data = mesh.m_VertexData
        channels = [
            Channel(c.dimension, c.format, c.offset, c.stream)
            for c in data.m_Channels
        ]
        strides = stream_strides(channels)
        offsets = stream_offsets(channels, data.m_VertexCount)
        count = data.m_VertexCount
        buffer = data.m_DataSize

        def stream(offset: int) -> bytes:
            return buffer[offset:]

        primitive = Primitive(
            positions=decode_channel(stream(offsets[0]), strides[0], count, POSITION),
            normals=decode_channel(stream(offsets[0]), strides[0], count, NORMAL),
            uvs=decode_channel(stream(offsets[1]), strides[1], count, TEXCOORD0),
            colors=decode_channel(stream(offsets[1]), strides[1], count, COLOR),
            weights=decode_channel(stream(offsets[2]), strides[2], count, WEIGHTS),
            joints=decode_channel(stream(offsets[2]), strides[2], count, BONE_INDICES),
            triangles=decode_triangles(bytes(mesh.m_IndexBuffer), True),
        )
        material_name, image = read_main_texture(env, renderer)
        meshes.append(
            SkinnedMesh(
                name=mesh.m_Name,
                primitive=primitive,
                bone_paths=[bone.path_id for bone in renderer.m_Bones],
                bindposes=[matrix_tuple(matrix) for matrix in mesh.m_BindPose],
                material_name=material_name,
                image=image,
            )
        )
    return meshes


def read_shape_keys(env) -> dict[str, list[tuple[str | None, list]]]:
    """Per mesh name: each shape's name (often None in MLTD) and its deltas."""
    out: dict[str, list[tuple[str | None, list]]] = {}
    for obj in env.objects:
        if obj.type.name != "Mesh":
            continue
        mesh = obj.read()
        shapes = mesh.m_Shapes
        if not shapes or not shapes.shapes:
            continue
        deltas = shapes.vertices
        out[mesh.m_Name] = [
            (shape.name, deltas[shape.firstVertex : shape.firstVertex + shape.vertexCount])
            for shape in shapes.shapes
        ]
    return out


def load(path: str):
    return UnityPy.load(path)
