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


def main() -> None:
    a = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.preferences.addon_enable(module="mmd_tools")
    bpy.ops.mmd_tools.import_model(filepath=a.pmx, scale=0.08, types={"MESH", "ARMATURE"})
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
