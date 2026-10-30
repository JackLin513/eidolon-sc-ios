"""Rewrite face-varying normals as per-vertex ones, then package a USDZ.

Blender's USD exporter always writes `faceVarying` normals. RealityKit does not
interpolate those, so hair and other curved surfaces come out flat-shaded. This
step averages the per-face normals back onto the points and repackages.
"""

import json
import sys

from pxr import UsdShade, Gf, Sdf, Usd, UsdGeom, UsdUtils


def average_normals(stage: Usd.Stage) -> int:
    """Fallback: average face-varying normals onto points.

    Only used for meshes where the game's normals could not be restored; without
    it RealityKit would flat-shade them, since it does not interpolate
    `faceVarying` normals.
    """
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


def inject_normals(stage: Usd.Stage, attributes: dict) -> tuple[int, int]:
    """Write the game's own vertex normals, instead of Blender's guess.

    Blender recomputes normals when the USD step clears custom split normals.
    For the hair — thin sheets whose front and back vertices share a position —
    that guess is far from the original: measured median 7.7 degrees off, 30% of
    vertices beyond 30, some fully flipped.

    The vertex order survives the round trip untouched (verified 7268/7268), so
    the only unknown is which axes Blender permuted. That is derived here by
    testing the candidates against the USD points before writing anything.
    """
    import itertools

    points = attributes.get("points") or []
    normals = attributes.get("normals") or []
    if not points or len(points) != len(normals):
        return 0, 0

    targets = [p for p in stage.Traverse() if p.GetTypeName() == "Mesh"]
    installed = 0
    for prim in targets:
        usd_points = prim.GetAttribute("points").Get()
        if not usd_points or len(usd_points) != len(points):
            continue

        sample = range(0, len(points), max(1, len(points) // 200))
        chosen = None
        for order, signs in itertools.product(itertools.permutations(range(3)),
                                              itertools.product((1, -1), repeat=3)):
            ok = True
            for i in sample:
                source = points[i]
                if (round(source[order[0]] * signs[0], 2),
                        round(source[order[1]] * signs[1], 2),
                        round(source[order[2]] * signs[2], 2)) != (
                        round(usd_points[i][0], 2),
                        round(usd_points[i][1], 2),
                        round(usd_points[i][2], 2)):
                    ok = False
                    break
            if ok:
                chosen = (order, signs)
                break
        if chosen is None:
            # pr001 comes back in a different vertex order than it went in (same
            # count, different sequence), so the index mapping does not apply.
            # Leave Blender's normals rather than write a reordering that has
            # not been verified.
            continue

        order, signs = chosen
        converted = [
            Gf.Vec3f(n[order[0]] * signs[0], n[order[1]] * signs[1],
                     n[order[2]] * signs[2])
            for n in normals
        ]
        attribute = prim.GetAttribute("normals")
        if attribute:
            attribute.Set(converted)
        else:
            prim.CreateAttribute("normals", Sdf.ValueTypeNames.Normal3fArray).Set(converted)
        UsdGeom.Mesh(prim).SetNormalsInterpolation(UsdGeom.Tokens.vertex)
        installed += 1
    return installed, 0


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


def _connected_sources(usd_input):
    """`GetConnectedSources` returns a tuple on some pxr builds and a list on others."""
    result = usd_input.GetConnectedSources()
    if isinstance(result, tuple):
        result = result[0]
    for item in result:
        if isinstance(item, tuple):
            yield item[0], item[1]
        else:
            yield item.source, item.sourceName


def diffuse_texture(material):
    """The `UsdUVTexture` feeding `diffuseColor`, not just any texture child.

    Hair and eye materials carry two textures (diffuse and the glow map), so
    picking "the" texture would wire opacity to the wrong image.
    """
    surface = material.ComputeSurfaceSource()[0]
    if not surface:
        return None, None
    diffuse = surface.GetInput("diffuseColor")
    if not diffuse:
        return surface, None
    for source, _name in _connected_sources(diffuse):
        if not source:
            continue
        shader = UsdShade.Shader(source.GetPrim())
        if shader.GetIdAttr().Get() == "UsdUVTexture":
            return surface, shader
    return surface, None


def wire_alpha_from_diffuse(stage, predicate):
    """Connect `opacity <- diffuse.a` for the materials `predicate` selects.

    Declaring `outputs:a` alone is not enough: RealityKit only keeps the alpha
    channel when the material graph actually samples it, so the connection is
    the switch.
    """
    changed = []
    for prim in stage.Traverse():
        if prim.GetTypeName() != "Material":
            continue
        material = UsdShade.Material(prim)
        if not predicate(prim.GetName()):
            continue
        surface, texture = diffuse_texture(material)
        if not surface or not texture:
            continue
        if not texture.GetOutput("a"):
            texture.CreateOutput("a", Sdf.ValueTypeNames.Float)
        opacity = surface.GetInput("opacity")
        if not opacity:
            opacity = surface.CreateInput("opacity", Sdf.ValueTypeNames.Float)
        opacity.ConnectToSource(texture.GetOutput("a"))
        changed.append(prim.GetName())
    return changed


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1 :]
    source, destination = argv[0], argv[1]

    stage = Usd.Stage.Open(source)
    attributes_source = source.rsplit(".", 1)[0] + "-attributes.json"
    try:
        with open(attributes_source) as handle:
            attributes = json.load(handle)
    except OSError:
        attributes = {}
    normals_installed, _ = inject_normals(stage, attributes)
    averaged = average_normals(stage)

    uv_source = source.rsplit(".", 1)[0] + "-uv.json"
    try:
        with open(uv_source) as handle:
            uvs = json.load(handle)["meshes"]
    except OSError:
        uvs = {}
    installed, deviation = inject_second_uv(stage, uvs) if uvs else (0, 0.0)

    # Only `Chr_Alpha` blends in the game; the rest are cutouts, whose alpha the
    # exporter has already flattened to 1.
    try:
        with open(source.rsplit(".", 1)[0] + "-materials.json") as handle:
            table = json.load(handle)["materials"]
    except OSError:
        table = {}
    blended = wire_alpha_from_diffuse(
        stage,
        lambda name: table.get(name, {}).get("shader") == "Custom/Chr_Alpha",
    )
    if blended:
        print(f"alpha wired: {blended}")

    stage.GetRootLayer().Save()

    UsdUtils.CreateNewUsdzPackage(source, destination)
    print(
        f"packed {destination} ({normals_installed} meshes re-normalled, "
        f"{installed} second UV sets added, {averaged} averaged, "
        f"st sanity {deviation:.4f})"
    )


main()
