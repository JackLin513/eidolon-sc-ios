"""Import an MLTD PMX/VMD pair with MMD Tools and render one frame (headless)."""
from __future__ import annotations

import argparse
import sys

import bpy
from mathutils import Vector


def args() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--pmx", required=True)
    p.add_argument("--vmd")
    p.add_argument("--out", required=True)
    p.add_argument("--frame", type=int, default=1)
    p.add_argument("--vmd-scale", type=float, default=0.08)
    p.add_argument("--pmx-scale", type=float, default=0.08)
    return p.parse_args(argv)


def main() -> None:
    a = args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.preferences.addon_enable(module="mmd_tools")
    bpy.ops.mmd_tools.import_model(filepath=a.pmx, scale=a.pmx_scale, types={"MESH", "ARMATURE", "PHYSICS"})
    if a.vmd:
        bpy.ops.mmd_tools.import_vmd(filepath=a.vmd, scale=a.vmd_scale, margin=0)

    scene = bpy.context.scene
    scene.frame_set(a.frame)

    meshes = [o for o in scene.objects if o.type == "MESH"]
    if not meshes:
        raise SystemExit("no mesh imported")
    points = [o.matrix_world @ Vector(c) for o in meshes for c in o.bound_box]
    low = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
    high = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
    center = (low + high) / 2
    size = high - low

    camera_data = bpy.data.cameras.new("Camera")
    camera = bpy.data.objects.new("Camera", camera_data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    camera.location = (center.x, center.y - max(size.z, size.x) * 1.9, center.z + size.z * 0.03)
    camera_data.lens = 55
    target = bpy.data.objects.new("Target", None)
    scene.collection.objects.link(target)
    target.location = center
    c = camera.constraints.new("TRACK_TO")
    c.target = target
    c.track_axis = "TRACK_NEGATIVE_Z"
    c.up_axis = "UP_Y"

    for loc, energy in [((3, -4, 4), 900), ((-3, -2, 2), 500), ((0, 2, 3), 300)]:
        data = bpy.data.lights.new("Area", "AREA")
        data.energy = energy
        data.size = 5
        light = bpy.data.objects.new("Area", data)
        light.location = loc
        scene.collection.objects.link(light)
        t = light.constraints.new("TRACK_TO")
        t.target = target
        t.track_axis = "TRACK_NEGATIVE_Z"
        t.up_axis = "UP_Y"

    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.08, 0.09, 0.12, 1)
    scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.6
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.resolution_x = 900
    scene.render.resolution_y = 1200
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = a.out
    bpy.ops.render.render(write_still=True)
    print(f"rendered frame {a.frame} to {a.out}")


main()
