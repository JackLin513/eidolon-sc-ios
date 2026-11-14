"""Render a glTF into a PNG so an export can be eyeballed without Xcode.

bpy is only available inside Blender; this file is never imported by the tests.
"""

import sys
from math import radians

import bpy
from mathutils import Vector


def make_unlit() -> None:
    """把 PBR 材质换成自发光：MLTD 是赛璐璐贴图，受光渲染会整体发暗。"""
    import bpy as _bpy

    for material in _bpy.data.materials:
        if not material.use_nodes:
            continue
        tree = material.node_tree
        principled = next(
            (n for n in tree.nodes if n.type == "BSDF_PRINCIPLED"), None
        )
        output = next((n for n in tree.nodes if n.type == "OUTPUT_MATERIAL"), None)
        if principled is None or output is None:
            continue
        color_input = principled.inputs.get("Base Color")
        source_node = color_input.links[0].from_node if color_input and color_input.links else None
        emission = tree.nodes.new("ShaderNodeEmission")
        emission.inputs["Strength"].default_value = 1.0
        if source_node is not None:
            tree.links.new(source_node.outputs[0], emission.inputs["Color"])
        elif color_input is not None:
            emission.inputs["Color"].default_value = color_input.default_value
        tree.links.new(emission.outputs[0], output.inputs["Surface"])


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1 :]
    source, destination = argv[0], argv[1]
    unlit = "--pbr" not in argv

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=source)
    if unlit:
        make_unlit()

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
    # Blender 5.x 把 BLENDER_EEVEE_NEXT 又改回了 BLENDER_EEVEE，按可用枚举挑一个。
    engines = bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items.keys()
    scene.render.engine = "BLENDER_EEVEE" if "BLENDER_EEVEE" in engines else "CYCLES"
    if hasattr(scene, "eevee") and hasattr(scene.eevee, "taa_render_samples"):
        scene.eevee.taa_render_samples = 16
    world = bpy.data.worlds.new("world")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.5, 0.55, 0.62, 1.0)
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
