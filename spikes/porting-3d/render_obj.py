"""Render the spike OBJ exports in Blender (headless).

Usage:
  Blender --background --python spikes/porting-3d/render_obj.py -- \
    --obj-dir build/mltd-spike/out --texture-dir build/mltd-spike/out/textures \
    --out build/mltd-spike/out/mirai.png
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def parse_args() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--obj-dir", type=Path, required=True)
    parser.add_argument("--texture-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    return parser.parse_args(argv)


def texture_for(name: str, texture_dir: Path) -> Path | None:
    lower = name.lower()
    patterns = []
    if "body" in lower:
        patterns = ["body_cb_*_01.png"]
    elif "hair" in lower:
        patterns = ["head_ch_*_hair.png"]
    elif "face" in lower:
        patterns = ["head_ch_*_face.png"]
    elif "eye" in lower:
        patterns = ["head_ch_*_face.png"]
    elif "acc" in lower:
        patterns = ["head_ch_*_acc01.png"]
    for pattern in patterns:
        matches = sorted(texture_dir.glob(pattern))
        if matches:
            return matches[0]
    return None


def material_for(name: str, texture_dir: Path) -> bpy.types.Material | None:
    texture = texture_for(name, texture_dir)
    if texture is None:
        return None
    material = bpy.data.materials.new(name=f"mat_{name}")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    shader = nodes.new("ShaderNodeBsdfPrincipled")
    image = nodes.new("ShaderNodeTexImage")
    image.image = bpy.data.images.load(str(texture), check_existing=True)
    image.interpolation = "Closest"
    links.new(image.outputs["Color"], shader.inputs["Base Color"])
    links.new(shader.outputs["BSDF"], output.inputs["Surface"])
    shader.inputs["Roughness"].default_value = 0.65
    return material


def main() -> None:
    args = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    imported = []
    for obj_path in sorted(args.obj_dir.glob("*.obj")):
        before = set(bpy.data.objects)
        bpy.ops.wm.obj_import(filepath=str(obj_path), forward_axis="NEGATIVE_Z", up_axis="Y")
        imported.extend([obj for obj in bpy.data.objects if obj not in before])
    if not imported:
        raise SystemExit("no OBJ imported")

    for obj in imported:
        material = material_for(obj.name, args.texture_dir)
        if material is not None:
            obj.data.materials.append(material)

    # Combined world-space bounds, so the camera works for any character export.
    points = []
    for obj in imported:
        for corner in obj.bound_box:
            points.append(obj.matrix_world @ Vector(corner))
    low = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
    high = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
    center = (low + high) / 2
    size = high - low

    camera_data = bpy.data.cameras.new("Camera")
    camera = bpy.data.objects.new("Camera", camera_data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    distance = max(size.z, size.x) * 1.8 + 1.0
    camera.location = (center.x, center.y - distance, center.z + size.z * 0.03)
    camera_data.lens = 55

    target = bpy.data.objects.new("Target", None)
    scene.collection.objects.link(target)
    target.location = center
    constraint = camera.constraints.new("TRACK_TO")
    constraint.target = target
    constraint.track_axis = "TRACK_NEGATIVE_Z"
    constraint.up_axis = "UP_Y"

    for location, energy in [((3, -4, 4), 900), ((-3, -2, 2), 500), ((0, 2, 3), 300)]:
        light_data = bpy.data.lights.new("Area", "AREA")
        light_data.energy = energy
        light_data.size = 5
        light = bpy.data.objects.new("Area", light_data)
        light.location = location
        scene.collection.objects.link(light)
        light.rotation_euler = (0, 0, 0)
        track = light.constraints.new("TRACK_TO")
        track.target = target
        track.track_axis = "TRACK_NEGATIVE_Z"
        track.up_axis = "UP_Y"

    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.08, 0.09, 0.12, 1)
    scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.6

    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.resolution_x = 900
    scene.render.resolution_y = 1200
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = True
    scene.render.filepath = str(args.out)
    bpy.ops.render.render(write_still=True)
    print(f"rendered {args.out}")


main()
