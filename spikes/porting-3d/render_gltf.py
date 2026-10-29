"""Render a glTF into a PNG so an export can be eyeballed without Xcode.

bpy is only available inside Blender; this file is never imported by the tests.
"""

import sys
from math import radians

import bpy
from mathutils import Vector


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1 :]
    source, destination = argv[0], argv[1]

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=source)

    # The glTF importer adds an icosphere as a bone-display shape; it is not
    # part of the character and would blow up the framing.
    meshes = [
        o
        for o in bpy.context.scene.objects
        if o.type == "MESH" and any(m.type == "ARMATURE" for m in o.modifiers)
    ]
    points = [
        obj.matrix_world @ Vector(corner) for obj in meshes for corner in obj.bound_box
    ]
    low = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
    high = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
    centre = (low + high) / 2
    height = max(high.z - low.z, 0.1)

    camera_data = bpy.data.cameras.new("camera")
    camera_data.type = "ORTHO"
    camera_data.ortho_scale = height * 1.15
    camera = bpy.data.objects.new("camera", camera_data)
    camera.location = centre + Vector((0, 3.0, 0))
    camera.rotation_euler = (radians(90), 0, radians(180))
    bpy.context.scene.collection.objects.link(camera)
    bpy.context.scene.camera = camera

    light_data = bpy.data.lights.new("key", type="SUN")
    light_data.energy = 4.0
    light = bpy.data.objects.new("key", light_data)
    light.rotation_euler = (radians(60), 0, radians(20))
    bpy.context.scene.collection.objects.link(light)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.eevee.taa_render_samples = 16
    world = bpy.data.worlds.new("world")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.16, 0.17, 0.2, 1.0)
    world.node_tree.nodes["Background"].inputs[1].default_value = 1.0
    scene.world = world
    scene.render.resolution_x = 720
    scene.render.resolution_y = 960
    scene.render.film_transparent = True
    scene.render.filepath = destination
    bpy.ops.render.render(write_still=True)
    print(f"rendered {destination} ({len(meshes)} meshes, height {height:.3f})")
    for obj in meshes:
        print(f"  {obj.name}: dims={[round(v,3) for v in obj.dimensions]} verts={len(obj.data.vertices)}")


main()
