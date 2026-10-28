"""Convert the spike PMX to a static USDZ with Blender + MMD Tools."""
from __future__ import annotations

import argparse
import sys

import bpy


def parse_args() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--pmx", required=True)
    p.add_argument("--out", required=True)
    return p.parse_args(argv)


def find_image(nodes):
    for node in nodes:
        if node.type == "TEX_IMAGE" and node.image is not None:
            return node.image
        if node.type == "GROUP" and node.node_tree is not None:
            image = find_image(node.node_tree.nodes)
            if image is not None:
                return image
    return None


def convert_materials_for_usd() -> None:
    """MMD Tools uses custom shader groups that the USD exporter ignores.

    Replace each textured material with a minimal Principled + image graph so USDZ
    embeds the original texture instead of exporting a gray fallback.
    """
    for material in bpy.data.materials:
        if material.node_tree is None:
            continue
        image = find_image(material.node_tree.nodes)
        if image is None:
            continue
        material.use_nodes = True
        nodes = material.node_tree.nodes
        links = material.node_tree.links
        nodes.clear()
        output = nodes.new("ShaderNodeOutputMaterial")
        shader = nodes.new("ShaderNodeBsdfPrincipled")
        texture = nodes.new("ShaderNodeTexImage")
        texture.image = image
        links.new(texture.outputs["Color"], shader.inputs["Base Color"])
        links.new(texture.outputs["Alpha"], shader.inputs["Alpha"])
        links.new(shader.outputs["BSDF"], output.inputs["Surface"])
        shader.inputs["Roughness"].default_value = 0.65
        material.surface_render_method = "DITHERED"


def main() -> None:
    a = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.preferences.addon_enable(module="mmd_tools")
    bpy.ops.mmd_tools.import_model(filepath=a.pmx, scale=0.08, types={"MESH", "ARMATURE"})
    convert_materials_for_usd()
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.wm.usd_export(
        filepath=a.out,
        selected_objects_only=True,
        export_materials=True,
        export_textures=True,
        export_animation=False,
    )
    print(f"wrote {a.out}")


main()
