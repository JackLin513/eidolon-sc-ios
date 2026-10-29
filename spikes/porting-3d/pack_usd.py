"""Rewrite face-varying normals as per-vertex ones, then package a USDZ.

Blender's USD exporter always writes `faceVarying` normals. RealityKit does not
interpolate those, so hair and other curved surfaces come out flat-shaded. This
step averages the per-face normals back onto the points and repackages.
"""

import json
import sys

from pxr import Gf, Sdf, Usd, UsdGeom, UsdUtils


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


def inject_second_uv(stage: Usd.Stage, uvs: dict) -> tuple[int, float]:
    """Add `primvars:st1` from the UV sets Blender could not export.

    Blender's USD exporter writes only the first UV set per mesh. The side-car
    the glTF step dumped holds every layer in loop order, which is the order the
    exporter used for `primvars:st` — checked against that first set before
    anything is written, so a reordering upstream skips the mesh instead of
    silently placing the hair sheen with the wrong coordinates.
    """
    installed = 0
    worst = 0.0
    for prim in stage.Traverse():
        if prim.GetTypeName() != "Mesh":
            continue
        entry = uvs.get(prim.GetName())
        if not entry:
            continue
        layers = list(entry.values())
        if len(layers) < 2:
            continue
        attribute = prim.GetAttribute("primvars:st")
        values = attribute.Get()
        if not values or len(values) != len(layers[0]):
            continue
        deviation = max(
            abs(values[i][0] - layers[0][i][0]) + abs(values[i][1] - layers[0][i][1])
            for i in range(0, len(values), 97)
        )
        worst = max(worst, deviation)
        if deviation > 0.01:
            continue
        if prim.HasAttribute("primvars:st1"):
            prim.RemoveProperty("primvars:st1")
        st1 = prim.CreateAttribute("primvars:st1", Sdf.ValueTypeNames.TexCoord2fArray)
        st1.Set([Gf.Vec2f(u, v) for u, v in layers[1]])
        st1.SetMetadata("interpolation", "faceVarying")
        installed += 1
    return installed, worst


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1 :]
    source, destination = argv[0], argv[1]

    stage = Usd.Stage.Open(source)
    converted = smooth_normals(stage)

    uv_source = source.rsplit(".", 1)[0] + "-uv.json"
    try:
        with open(uv_source) as handle:
            uvs = json.load(handle)["meshes"]
    except OSError:
        uvs = {}
    installed, deviation = inject_second_uv(stage, uvs) if uvs else (0, 0.0)

    stage.GetRootLayer().Save()

    UsdUtils.CreateNewUsdzPackage(source, destination)
    print(
        f"packed {destination} ({converted} meshes re-normalled, "
        f"{installed} second UV sets added, st sanity {deviation:.4f})"
    )


main()
