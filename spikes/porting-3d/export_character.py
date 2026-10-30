#!/usr/bin/env python3
"""Build a skinned glTF from MLTD head/body bundles.

The head and body ship as separate bundles with separate skeletons that share a
few bones by name (`KUBI`, `ATAMA`, ...). This merges them into one skeleton so
a single skin can drive every mesh.
"""

from __future__ import annotations

import math

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image

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
from material_atlas import parameter_atlas
from material_params import read_material_table
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


def premultiplied(image):
    """Fold alpha into the colour channels.

    `_SubTex` uses alpha as a mask — the eye catch-light is a white blob on a
    transparent field — and RealityKit's emissive texture drops alpha on the way
    in. Premultiplying puts the mask in RGB where it survives. For ss003's glow
    the alpha is 255 everywhere, so this is the identity.
    """
    from PIL import ImageChops

    image = image.convert("RGBA")
    alpha = image.getchannel("A")
    rgb = ImageChops.multiply(image.convert("RGB"), alpha.convert("RGB"))
    rgb.putalpha(255)
    return rgb


# MLTD paints some pieces into texels the atlas marks as transparent: the gs001
# belt and the piping round its bustle sit at alpha 13 with perfectly good gold
# in RGB, because one 1024px sheet serves both the `Chr_Basic` pieces and the
# cutout overlay that masks them. An opaque `Chr_Basic` never tests alpha, so
# the game draws that gold — and the same alpha is the mask `Chr_Span` weights
# its sparkle by, which is why the trim does not glitter in the game.
#
# Both halves therefore have to survive the export untouched. Zeroing the
# colour under transparent texels (what this used to do) turned every gold trim
# black; forcing the alpha to 255 would have made the trim sparkle. The textures
# that do need a rewrite — `_SubTex` premultiplied into RGB, cutouts and blends
# keeping their alpha — are handled at the call site.


def _cube_face(direction):
    """Which face a direction lands on, and where inside it.

    Face order is Unity's `CubemapFace`: `+X -X +Y -Y +Z -Z`. The per-face
    `sc`/`tc` signs are the OpenGL cube map convention.
    """
    x, y, z = direction
    ax, ay, az = abs(x), abs(y), abs(z)
    if ax >= ay and ax >= az:
        face, sc, tc = (0, -z, -y) if x > 0 else (1, z, -y)
        major = ax
    elif ay >= az:
        face, sc, tc = (2, x, z) if y > 0 else (3, x, -z)
        major = ay
    else:
        face, sc, tc = (4, x, -y) if z > 0 else (5, -x, -y)
        major = az
    major = max(major, 1e-6)
    return face, (sc / major + 1.0) / 2.0, (tc / major + 1.0) / 2.0


def equirectangular(faces, width: int = 128) -> Image.Image:
    """Fold the six cube faces into a lat-long map.

    The shader has one `texture2d` to spare, not a cube map, so the game's
    reflection is resampled here. 32x32 faces become a 128x64 strip: enough for
    a matcap this soft, and the lookup on the other side is two trig calls.
    """
    size = faces[0].size[0]
    height = width // 2
    sources = [face.convert("RGB") for face in faces]
    out = Image.new("RGB", (width, height))
    pixels = out.load()
    for row in range(height):
        latitude = math.pi / 2 - (row + 0.5) / height * math.pi
        cos_lat = math.cos(latitude)
        sin_lat = math.sin(latitude)
        for column in range(width):
            longitude = (column + 0.5) / width * 2 * math.pi - math.pi
            direction = (
                cos_lat * math.cos(longitude),
                sin_lat,
                cos_lat * math.sin(longitude),
            )
            face, u, v = _cube_face(direction)
            x = min(size - 1, max(0, int(u * size)))
            y = min(size - 1, max(0, int(v * size)))
            pixels[column, row] = sources[face].getpixel((x, y))
    return out


def pack_span(bump, cube2d) -> Image.Image:
    """`_BumpMap` on top, `_Cube2D` below, in one 64x128 strip.

    `Chr_Span` samples two extra maps and RealityKit gives the shader only one
    slot it can fill itself, so they travel together and the shader halves the
    V coordinate to pick one out.
    """
    out = Image.new("RGB", (64, 128))
    out.paste(bump.convert("RGB").resize((64, 64), Image.LANCZOS), (0, 0))
    out.paste(cube2d.convert("RGB").resize((64, 64), Image.LANCZOS), (0, 64))
    return out


def sanitise(name: str) -> str:
    return "".join(
        character if character.isalnum() or character in "-_" else "_"
        for character in name
    )[:40]


def build(
    body: Path, head: Path | None, out: Path, name: str = "character"
) -> GltfDocument:
    merged, body_map, head_map = merge_skeleton(body, head)

    chunks = _Chunks()
    gltf_nodes = []
    for node in merged.nodes:
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
    meshes: list = []
    for bundle, mapping in sources:
        for mesh in read_skinned_meshes(load(str(bundle))):
            local_joints = [mapping[path_id] for path_id in mesh.bone_paths]
            for joint in local_joints:
                if joint not in joint_order:
                    joint_order.append(joint)
            meshes.append((mesh, local_joints))

    # A head bundle can carry another outfit's accessory, and those are named
    # after that outfit with no idol id at all (`ch_sra062_a_acc01_m`). They
    # render as a stray piece pinned to this character, so keep only renderers
    # that name this idol somewhere.
    idol = None
    for mesh, _ in meshes:
        for material in mesh.materials:
            match = re.search(r"_\d{3}[a-z]{3}_", material.name or "")
            if match:
                idol = match.group(0).strip("_")
                break
        if idol:
            break
    if idol:
        meshes = [
            (mesh, joints) for mesh, joints in meshes
            if any(f"_{idol}_" in (m.name or "") for m in mesh.materials)
        ]

    skin_of_joint = {joint: position for position, joint in enumerate(joint_order)}

    cube_files: dict[str, str] = {}
    images: list[dict] = []
    textures: list[dict] = []
    materials: list[dict] = []
    material_index: dict[tuple[str, int], int] = {}
    (out / "textures").mkdir(parents=True, exist_ok=True)

    def add_image(
        image, key: str, premultiply: bool = False, keep_alpha: bool = False
    ) -> int:
        file_name = f"textures/{len(images):02d}_{sanitise(key)}.png"
        if premultiply:
            image = premultiplied(image)
        elif not keep_alpha:
            # The shader reads this texture's alpha whatever the material is
            # (`Chr_Span`'s sparkle weight, `Chr_Glow`'s mask, the hair's sheen
            # gate), so there is nothing safe to normalise here.
            image = image.convert("RGBA")
        image.save(out / file_name)
        images.append({"uri": file_name})
        textures.append({"source": len(images) - 1, "sampler": 0})
        return len(textures) - 1

    def material_for(info, glow_uv: int) -> int | None:  # noqa: C901
        """glTF carries the game's two texture slots as base colour + emissive.

        `_SubTex` is additive glow, which is what `emissiveTexture` means, and
        `texCoord` picks the UV set: only the hair has a second one.
        """
        if info is None:
            return None
        key = info.name or "material"
        cache_key = (key, glow_uv)
        if cache_key in material_index:
            return material_index[cache_key]
        pbr: dict = {"metallicFactor": 0.0, "roughnessFactor": 0.9}
        # RealityKit drops a texture's alpha channel unless the material graph
        # actually samples `diffuse.a` (`pack_usd.wire_alpha_from_diffuse` says
        # so). `Chr_Span` multiplies its sparkle by `_MainTex.a` — the gold trim
        # sits at 13/255 and must not glitter — so its alpha has to be wired the
        # way a cutout's is, or the shader reads a constant 1.
        needs_alpha = (
            info.shader == "Custom/Chr_Alpha"
            or info.cutoff
            or info.shader == "Custom/Chr_Span"
        )
        if info.image is not None:
            pbr["baseColorTexture"] = {
                "index": add_image(info.image, key, keep_alpha=needs_alpha)
            }
        else:
            pbr["baseColorFactor"] = [0.85, 0.85, 0.85, 1.0]
        effect = None
        if info.cube:
            # Not a glTF texture: this one is only read by our own shader, so it
            # travels beside the USDZ and `MaterialParameters` hands it over.
            effect = equirectangular(info.cube)
        elif info.bump is not None and info.cube2d is not None:
            effect = pack_span(info.bump, info.cube2d)
        if effect is not None:
            effect_name = f"textures/{len(images):02d}_{sanitise(key)}_effect.png"
            effect.save(out / effect_name)
            cube_files[key] = effect_name
        entry: dict = {"name": key, "pbrMetallicRoughness": pbr, "doubleSided": True}
        if info.cutoff and info.shader != "Custom/Chr_Alpha":
            # Blender turns these into `opacity.connect` + `opacityThreshold`,
            # which is how the alpha survives into the USDZ.
            entry["alphaMode"] = "MASK"
            entry["alphaCutoff"] = 0.5
        elif info.shader == "Custom/Chr_Span":
            # Same wiring, different reason: nothing is meant to be clipped, we
            # only need the channel to exist. A cutoff of zero keeps every texel
            # even if something downstream does honour the threshold.
            entry["alphaMode"] = "MASK"
            entry["alphaCutoff"] = 0.0
        # The game reads `_SubTex` per shader: the green channel gates ss003's
        # glow, alpha masks the eye highlight and weights the hair sheen. Alpha
        # does not survive as alpha, so it is premultiplied into RGB; the gate
        # channel is untouched because that texture is opaque.
        #
        # `glow_uv` records which UV set the game samples `_SubTex` with. The
        # vertex attribute is written either way — TEXCOORD_1 for the hair — and
        # `pack_usd.py` lifts it into `primvars:st1` because Blender's USD export
        # only writes the first set.
        if info.glow is not None:
            entry["emissiveTexture"] = {
                "index": add_image(info.glow, f"{key}_glow", premultiply=True),
                "texCoord": glow_uv,
            }
            entry["emissiveFactor"] = [1.0, 1.0, 1.0]
        materials.append(entry)
        material_index[cache_key] = len(materials) - 1
        return material_index[cache_key]

    # Blender's glTF importer recomputes normals when the USD step clears the
    # custom split normals, and its guess is not the game's: on the hair, 30% of
    # vertices ended up more than 30 degrees off, some fully flipped. The mesh
    # points survive that round trip in their original order, so the originals
    # travel beside the file and `pack_usd.py` writes them straight back.
    attributes: dict[str, list] = {"points": [], "normals": []}

    primitive_entries: list[dict] = []
    for mesh, local_joints in meshes:
        primitive = mesh.primitive
        positions, normals, triangles = flip_handedness(
            primitive.positions, primitive.normals, primitive.triangles
        )
        attributes["points"].extend([[round(v, 5) for v in p] for p in positions])
        attributes["normals"].extend([[round(v, 5) for v in n] for n in normals])
        ranges = mesh.submeshes or [(0, len(triangles))]
        for submesh_index, (first, count) in enumerate(ranges):
            if submesh_index < len(mesh.materials):
                info = mesh.materials[submesh_index]
            elif mesh.materials:
                info = mesh.materials[0]
            else:
                info = None
            # Every primitive gets its own attribute accessors: Blender's glTF
            # importer deduplicates shared accessors across primitives and then
            # produces out-of-range indices for the second one.
            entry: dict = {
                "attributes": {
                    "POSITION": chunks.floats(positions, 3, "VEC3"),
                    "NORMAL": chunks.floats(normals, 3, "VEC3"),
                    "TEXCOORD_0": chunks.floats(
                        [(u, 1.0 - v) for u, v in primitive.uvs], 2, "VEC2"
                    ),
                    **(
                        {
                            "TEXCOORD_1": chunks.floats(
                                [(u, 1.0 - v) for u, v in primitive.uvs1],
                                2,
                                "VEC2",
                            )
                        }
                        if primitive.uvs1
                        else {}
                    ),
                    "JOINTS_0": chunks.bytes(
                        [
                            [skin_of_joint[local_joints[int(i)]] for i in value]
                            for value in primitive.joints
                        ],
                        "VEC4",
                    ),
                    "WEIGHTS_0": chunks.floats(
                        [
                            [max(0.0, float(w)) for w in value]
                            for value in primitive.weights
                        ],
                        4,
                        "VEC4",
                    ),
                },
                "indices": chunks.indices(triangles[first : first + count]),
            }
            index = material_for(info, 1 if primitive.uvs1 else 0)
            if index is not None:
                entry["material"] = index
            if mesh.shapes:
                entry["targets"] = [
                    {"POSITION": chunks.floats([flip_vector(delta) for delta in deltas], 3, "VEC3")}
                    for _, deltas in mesh.shapes
                ]
                entry["extras"] = {"targetNames": [name for name, _ in mesh.shapes]}
            primitive_entries.append(entry)

    # The glTF has no home for the game's two dozen shading scalars, so they
    # travel beside it: a JSON table for reference and one small atlas texture
    # the surface shader samples by row.
    materials_table: dict[str, dict] = {}
    for bundle, _ in sources:
        materials_table.update(read_material_table(load(str(bundle))))
    for material_name, cube_name in cube_files.items():
        if material_name in materials_table:
            materials_table[material_name]["effect"] = cube_name
    (out / f"{name}-attributes.json").write_text(
        json.dumps(attributes), encoding="utf-8"
    )
    atlas, atlas_rows = parameter_atlas(materials_table)
    atlas.save(out / f"{name}-params.png")
    (out / f"{name}-materials.json").write_text(
        json.dumps(
            {"rows": atlas_rows, "materials": materials_table},
            indent=1,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    inverse_bind = chunks.floats(
        [
            flip_matrix(column_major(matrix_inverse(world_of(merged, joint))))
            for joint in joint_order
        ],
        16,
        "MAT4",
    )

    mesh_index = len(gltf_nodes)
    gltf_nodes.append({"name": "character", "mesh": 0, "skin": 0})
    roots = [index for index, parent in merged.parent_of.items() if parent is None]

    return GltfDocument(
        chunks=chunks,
        nodes=gltf_nodes,
        meshes=[{"name": "character", "primitives": primitive_entries}],
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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--body", type=Path, required=True)
    parser.add_argument("--head", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--name", default="character")
    arguments = parser.parse_args(argv)

    document = build(arguments.body, arguments.head, arguments.out, arguments.name)
    print(document.write(arguments.out, arguments.name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
