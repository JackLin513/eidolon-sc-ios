"""Convert a glTF into a USDZ by way of Blender.

Blender is only a format converter here: it imports the glTF the exporter wrote
and writes USD. It must not bind, retarget or pose anything.
"""

import sys

import bpy


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1 :]
    source, destination = argv[0], argv[1]

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=source)

    if argv[2:] and argv[2] == "--join":
        meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
        if len(meshes) > 1:
            bpy.ops.object.select_all(action="DESELECT")
            for mesh in meshes:
                mesh.select_set(True)
            bpy.context.view_layer.objects.active = meshes[0]
            bpy.ops.object.join()

    # The glTF importer creates an icosphere to draw joints with; it is not part
    # of the character and must not reach the USD.
    for obj in list(bpy.context.scene.objects):
        if obj.name.startswith("Icosphere"):
            bpy.data.objects.remove(obj, do_unlink=True)

    # glTF says a skinned mesh's own transform is irrelevant: the joints alone
    # place the vertices. Blender re-parents the imported skinned mesh under the
    # armature, so exporting as-is bakes the skeleton root's rotation in twice.
    for obj in list(bpy.context.scene.objects):
        if obj.type == "MESH" and any(m.type == "ARMATURE" for m in obj.modifiers):
            obj.parent = None
            obj.matrix_world.identity()

    bpy.ops.wm.usd_export(
        filepath=destination,
        export_armatures=True,
        export_shapekeys=True,
        convert_orientation=True,
        export_animation=False,
        export_materials=True,
        export_uvmaps=True,
        export_normals=True,
        export_textures=True,
        selected_objects_only=False,
        visible_objects_only=False,
    )
    print(f"wrote {destination}")


main()
