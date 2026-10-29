"""Rewrite face-varying normals as per-vertex ones, then package a USDZ.

Blender's USD exporter always writes `faceVarying` normals. RealityKit does not
interpolate those, so hair and other curved surfaces come out flat-shaded. This
step averages the per-face normals back onto the points and repackages.
"""

import sys

from pxr import Usd, UsdGeom, UsdUtils


def smooth_normals(stage: Usd.Stage) -> int:
    converted = 0
    for prim in stage.Traverse():
        if prim.GetTypeName() != "Mesh":
            continue
        mesh = UsdGeom.Mesh(prim)
        normals = mesh.GetNormalsAttr()
        values = normals.Get()
        if not values or normals.GetMetadata("interpolation") != "faceVarying":
            continue

        points = mesh.GetPointsAttr().Get()
        counts = mesh.GetFaceVertexCountsAttr().Get()
        indices = mesh.GetFaceVertexIndicesAttr().Get()

        accumulated = [[0.0, 0.0, 0.0] for _ in points]
        cursor = 0
        for count in counts:
            for offset in range(count):
                point = indices[cursor + offset]
                normal = values[cursor + offset]
                cell = accumulated[point]
                cell[0] += normal[0]
                cell[1] += normal[1]
                cell[2] += normal[2]
            cursor += count

        averaged = []
        for cell in accumulated:
            length = (cell[0] ** 2 + cell[1] ** 2 + cell[2] ** 2) ** 0.5 or 1.0
            averaged.append((cell[0] / length, cell[1] / length, cell[2] / length))

        normals.Set(averaged)
        mesh.SetNormalsInterpolation(UsdGeom.Tokens.vertex)
        converted += 1
    return converted


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1 :]
    source, destination = argv[0], argv[1]

    stage = Usd.Stage.Open(source)
    converted = smooth_normals(stage)
    stage.GetRootLayer().Save()

    UsdUtils.CreateNewUsdzPackage(source, destination)
    print(f"packed {destination} ({converted} meshes re-normalled)")


main()
