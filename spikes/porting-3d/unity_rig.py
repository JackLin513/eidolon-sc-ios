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

# Unity channel indices. The offsets differ per mesh, so they are read from the
# mesh's own channel table rather than assumed: `cb_pr001` carries a vertex
# colour in stream 1 and therefore puts UV at offset 4, while `cb_ss003` has no
# colour and puts UV at offset 0.
CHANNEL_POSITION = 0
CHANNEL_NORMAL = 1
CHANNEL_TEXCOORD0 = 4
CHANNEL_TEXCOORD1 = 5
CHANNEL_WEIGHTS = 12
CHANNEL_BONE_INDICES = 13


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
    uvs1: list
    colors: list
    weights: list
    joints: list
    triangles: list


def _texture_image(environment):
    try:
        return environment.m_Texture.read().image
    except Exception:
        return None


def read_material(env, pointer) -> MaterialInfo:
    """The two texture slots the game's character shaders actually use.

    `_MainTex` is the albedo atlas. `_SubTex` is an additive glow layer, not an
    alpha mask: ss003's is a black field with neon outlines, the hair's is a few
    transparent strokes, the eyes' is the catch-light. It has to be added at
    shading time, so it travels as its own texture.
    """
    material = pointer.read()
    image = None
    glow = None
    for entry in material.m_SavedProperties.m_TexEnvs or []:
        name, environment = entry[0], entry[1]
        if name == "_MainTex":
            image = _texture_image(environment)
        elif name == "_SubTex":
            glow = _texture_image(environment)
    return MaterialInfo(name=material.m_Name, image=image, glow=glow)


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


@dataclass(frozen=True)
class MaterialInfo:
    name: str | None
    image: object | None
    glow: object | None = None


@dataclass
class SkinnedMesh:
    name: str
    primitive: Primitive
    bone_paths: list[int]
    bindposes: list[tuple[float, ...]] = field(default_factory=list)
    materials: list[MaterialInfo] = field(default_factory=list)
    shapes: list[tuple[str, list[tuple[float, float, float]]]] = field(default_factory=list)
    # (first triangle, triangle count) per submesh, in material order.
    submeshes: list[tuple[int, int]] = field(default_factory=list)


def _vec(value) -> tuple[float, float, float]:
    return (value.x, value.y, value.z)


def matrix_tuple(matrix) -> tuple[float, ...]:
    """Unity's eRC fields, flattened column-major the way glTF wants them."""
    return tuple(
        getattr(matrix, f"e{row}{column}")
        for column in range(4)
        for row in range(4)
    )


def _padded(rows):
    """Pad each per-vertex tuple to the four components glTF requires."""
    return [
        tuple(row) + (0,) * (4 - len(row)) if len(row) < 4 else tuple(row)
        for row in rows
    ]


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
        def channel(index: int, fallback: Channel) -> Channel:
            found = channels[index] if index < len(channels) else None
            return found if found and found.dimension else fallback

        position_channel = channel(CHANNEL_POSITION, Channel(3, 0, 0, 0))
        normal_channel = channel(CHANNEL_NORMAL, Channel(3, 0, 12, 0))
        uv_channel = channel(CHANNEL_TEXCOORD0, Channel(2, 0, 0, 1))
        uv1_channel = channel(CHANNEL_TEXCOORD1, Channel(0, 0, 0, 1))
        weight_channel = channel(CHANNEL_WEIGHTS, Channel(4, 0, 0, 2))
        bone_channel = channel(CHANNEL_BONE_INDICES, Channel(4, 11, 16, 2))

        strides = stream_strides(channels)
        offsets = stream_offsets(channels, data.m_VertexCount)
        count = data.m_VertexCount
        buffer = data.m_DataSize

        def stream(offset: int) -> bytes:
            return buffer[offset:]

        primitive = Primitive(
            positions=decode_channel(
                stream(offsets[position_channel.stream]),
                strides[position_channel.stream],
                count,
                position_channel,
            ),
            normals=decode_channel(
                stream(offsets[normal_channel.stream]),
                strides[normal_channel.stream],
                count,
                normal_channel,
            ),
            uvs=decode_channel(
                stream(offsets[uv_channel.stream]),
                strides[uv_channel.stream],
                count,
                uv_channel,
            ),
            uvs1=(
                decode_channel(
                    stream(offsets[uv1_channel.stream]),
                    strides[uv1_channel.stream],
                    count,
                    uv1_channel,
                )
                if uv1_channel.dimension
                else []
            ),
            colors=[],
            # Unity writes as many weight/index slots as the mesh needs: four for
            # a normal character, two for a two-bone prop, none at all for a
            # rigid one (which then stores a single 32-bit index). glTF is fixed
            # at four per vertex, so pad every layout up to four here instead of
            # teaching each caller about the variants.
            weights=_padded(
                decode_channel(
                    stream(offsets[weight_channel.stream]),
                    strides[weight_channel.stream],
                    count,
                    weight_channel,
                )
                if len(channels) > CHANNEL_WEIGHTS
                and channels[CHANNEL_WEIGHTS].dimension
                else [(1.0, 0.0, 0.0, 0.0)] * count
            ),
            joints=_padded(
                decode_channel(
                    stream(offsets[bone_channel.stream]),
                    strides[bone_channel.stream],
                    count,
                    bone_channel,
                )
            ),
            triangles=decode_triangles(bytes(mesh.m_IndexBuffer), True),
        )
        materials = [read_material(env, pointer) for pointer in renderer.m_Materials]
        submeshes = [
            (submaterial.firstByte // 2 // 3, submaterial.indexCount // 3)
            for submaterial in mesh.m_SubMeshes
        ]
        meshes.append(
            SkinnedMesh(
                name=mesh.m_Name,
                primitive=primitive,
                bone_paths=[bone.path_id for bone in renderer.m_Bones],
                bindposes=[matrix_tuple(matrix) for matrix in mesh.m_BindPose],
                materials=materials,
                submeshes=submeshes,
                shapes=read_shape_keys(mesh, data.m_VertexCount),
            )
        )
    return meshes


SHAPE_NAME_PREFIX = "blendShape1."


def read_shape_keys(mesh, vertex_count: int) -> list[tuple[str, list[tuple[float, float, float]]]]:
    """Full-length position deltas per blend shape.

    MLTD stores the shape names on the channels, not on the shapes themselves;
    UnityPy reports `shapes[i].name` as None, which is why the names look absent.
    """
    shapes = mesh.m_Shapes
    if not shapes or not shapes.shapes:
        return []
    entries: list[tuple[str, list[tuple[float, float, float]]]] = []
    channels = list(shapes.channels or [])
    for order, shape in enumerate(shapes.shapes):
        name = None
        if order < len(channels):
            name = channels[order].name
        if name and name.startswith(SHAPE_NAME_PREFIX):
            name = name[len(SHAPE_NAME_PREFIX) :]
        deltas = [(0.0, 0.0, 0.0)] * vertex_count
        for vertex in shapes.vertices[shape.firstVertex : shape.firstVertex + shape.vertexCount]:
            deltas[vertex.index] = (vertex.vertex.x, vertex.vertex.y, vertex.vertex.z)
        entries.append((name or f"shape_{order:02d}", deltas))
    return entries


def load(path: str):
    return UnityPy.load(path)
