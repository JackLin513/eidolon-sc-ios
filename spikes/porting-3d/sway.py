"""Sway sidecar for the bones the game animates with runtime physics (#28).

The dance curves key 57 bones and none of the skirt panels, ribbons or hair
chains.  The game moves those with `Imas.BoneLib.SwayBone`, so on the phone
they need a spring of their own (`ios/MotionSway.swift`) instead of an
animation track.

The spring needs one number per bone: the tail vector from the joint to the
point where the bone's mass sits, expressed in the bone's own local axes.  A
chain bone's tail is the next bone's translation; a leaf panel's tail is the
centroid of the vertices it dominates, taken in bind space.

    python3 spikes/porting-3d/sway.py <model.gltf> [--out <file>]

Writes `<stem>.sway.json` beside the glTF (or to `--out`).  The sidecar is
derived from game geometry, so it is local-only like the models themselves and
must not be committed.

Runtime joint names come out of RealityKit's skeleton: paths built from the
armature nodes below `BASE`, with spaces replaced by underscores.  Only that
armature is exported here, because that is the name set the app matches.
"""

from __future__ import annotations

import argparse
import base64
import json
import struct
from pathlib import Path

FORMAT = "eidolon.sway/1"

# leaf-name prefix, family, stiffness, drag, gravity.  Chosen against the
# offline prototype: the game's own SwayBone values are not in the shipped
# bundles.  Stiffness is low enough that the skirt visibly swings during the
# dance but still hangs; the defaults for ribbon and hair are the stiff end.
FAMILIES = {
    "skirt_": ("skirt", 16.0, 1.5, 6.0),
    "ribbon_": ("ribbon", 90.0, 9.0, 1.0),
    "hair_": ("hair", 110.0, 11.0, 0.5),
}
GROUP_NODES = {"skirt_GP", "ribbon_GP"}

COMPONENTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
COMPONENT_TYPES = {
    5120: ("b", 1),
    5121: ("B", 1),
    5122: ("h", 2),
    5123: ("H", 2),
    5125: ("I", 4),
    5126: ("f", 4),
}


class Document:
    """Just enough glTF: accessors over a blob, plus the node tree."""

    def __init__(self, path: Path):
        self.gltf = json.loads(path.read_text())
        self.blob = self._buffer(path)
        self.nodes = self.gltf["nodes"]
        self.parents = {}
        for index, node in enumerate(self.nodes):
            for child in node.get("children", []):
                self.parents[child] = index
        self.skin_joints = self.gltf["skins"][0]["joints"]
        self.joint_set = set(self.skin_joints)

    def _buffer(self, path: Path) -> bytes:
        uri = self.gltf["buffers"][0]["uri"]
        if uri.startswith("data:"):
            return base64.b64decode(uri.split(",", 1)[1])
        return (path.parent / uri).read_bytes()

    def accessor(self, index: int) -> list:
        accessor = self.gltf["accessors"][index]
        view = self.gltf["bufferViews"][accessor["bufferView"]]
        offset = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
        count = COMPONENTS[accessor["type"]]
        fmt, size = COMPONENT_TYPES[accessor["componentType"]]
        stride = view.get("byteStride", count * size)
        if count == 1:
            return [
                struct.unpack_from("<" + fmt, self.blob, offset + k * stride)[0]
                for k in range(accessor["count"])
            ]
        return [
            struct.unpack_from("<" + fmt * count, self.blob, offset + k * stride)
            for k in range(accessor["count"])
        ]

    def ancestors(self, node: int) -> list[int]:
        chain = [node]
        while node in self.parents:
            node = self.parents[node]
            chain.append(node)
        return chain

    # -- naming ---------------------------------------------------------------

    def armature_roots(self) -> list[int]:
        """The joint nodes RealityKit uses as skeleton roots.

        That is the lowest common ancestor of the skin's joints, or its
        children on the way down.  The exporter puts the two real roots
        (`MUNE1`, `KOSHI`) under `BASE`; taking the LCA keeps that rule without
        hard-coding the name.
        """
        chains = [set(self.ancestors(joint)) for joint in self.skin_joints]
        common = set.intersection(*chains)
        lca = max(common, key=lambda n: len(self.ancestors(n)))
        if lca in self.joint_set:
            return [lca]
        inside = set().union(*chains)
        return [
            child for child in self.nodes[lca].get("children", [])
            if child in inside
        ]

    def armature(self) -> list[int]:
        """Every armature node, including non-deform groups like `skirt_GP`."""
        roots = set(self.armature_roots())
        bones = set()
        for joint in self.skin_joints:
            for node in self.ancestors(joint):
                bones.add(node)
                if node in roots:
                    break
        return sorted(bones)

    def runtime_name(self, node: int) -> str:
        roots = set(self.armature_roots())
        parts = []
        while True:
            name = self.nodes[node].get("name", "").replace(" ", "_")
            parts.append(name)
            if node in roots:
                break
            node = self.parents[node]
        return "/".join(reversed(parts))

    # -- geometry -------------------------------------------------------------

    def bone_centroids(self) -> dict[int, tuple]:
        """Centroid of each joint's dominant vertices, in its local frame."""
        inverse_bind = {}
        raw = self.accessor(self.gltf["skins"][0]["inverseBindMatrices"])
        for slot, node in enumerate(self.skin_joints):
            m = raw[slot]
            inverse_bind[node] = [
                [m[column * 4 + row] for column in range(4)] for row in range(4)
            ]
        sums: dict[int, list[float]] = {}
        for node in self.nodes:
            if "mesh" not in node:
                continue
            for primitive in self.gltf["meshes"][node["mesh"]]["primitives"]:
                attributes = primitive["attributes"]
                if "JOINTS_0" not in attributes or "WEIGHTS_0" not in attributes:
                    continue
                positions = self.accessor(attributes["POSITION"])
                joints = self.accessor(attributes["JOINTS_0"])
                weights = self.accessor(attributes["WEIGHTS_0"])
                for vertex, point in enumerate(positions):
                    dominant = max(range(4), key=lambda k: weights[vertex][k])
                    if weights[vertex][dominant] <= 0:
                        continue
                    joint = self.skin_joints[joints[vertex][dominant]]
                    matrix = inverse_bind.get(joint)
                    if matrix is None:
                        continue
                    local = [
                        sum(matrix[row][k] * point[k] for k in range(3)) + matrix[row][3]
                        for row in range(3)
                    ]
                    total = sums.setdefault(joint, [0.0, 0.0, 0.0, 0.0])
                    for axis in range(3):
                        total[axis] += local[axis]
                    total[3] += 1
        return {
            joint: (total[0] / total[3], total[1] / total[3], total[2] / total[3])
            for joint, total in sums.items() if total[3]
        }


def mirror(vector) -> tuple:
    """glTF bone-local axes to the app's: the usual `(x, y, −z)` flip."""
    return (vector[0], vector[1], -vector[2])


def family_of(name: str) -> str | None:
    leaf = name.split("/")[-1]
    if leaf in GROUP_NODES:
        return None
    for prefix, (family, _, _, _) in FAMILIES.items():
        if leaf.startswith(prefix):
            return family
    return None


def tail_for(document: Document, node: int, bones: set[int],
             centroids: dict[int, tuple]) -> tuple:
    """The bone-local vector from the joint to its mass point."""
    sway_children = [
        child for child in document.nodes[node].get("children", [])
        if child in bones and family_of(document.runtime_name(child))
    ]
    if len(sway_children) == 1:
        child = sway_children[0]
        return mirror(document.nodes[child].get("translation", [0, 0, 0]))
    if node in centroids:
        return mirror(centroids[node])
    children = document.nodes[node].get("children", [])
    if children:
        return mirror(document.nodes[children[0]].get("translation", [0, 0, 0]))
    return (-0.04, 0.0, 0.0)


def build(gltf: Path) -> dict:
    document = Document(gltf)
    armature = document.armature()
    bones = set(armature)
    centroids = document.bone_centroids()

    entries = []
    for node in armature:
        name = document.runtime_name(node)
        family = family_of(name)
        if family is None:
            continue
        tail = tail_for(document, node, bones, centroids)
        entries.append({
            "name": name,
            "family": family,
            "tail": [round(value, 6) for value in tail],
        })
    entries.sort(key=lambda entry: entry["name"])

    return {
        "format": FORMAT,
        "families": {
            family: {"stiffness": stiffness, "drag": drag, "gravity": gravity}
            for family, stiffness, drag, gravity in FAMILIES.values()
        },
        "bones": entries,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("gltf", type=Path, help="exported character glTF")
    parser.add_argument("--out", type=Path, help="sidecar path")
    args = parser.parse_args()

    payload = build(args.gltf)
    out = args.out or args.gltf.with_suffix(".sway.json")
    out.write_text(json.dumps(payload, indent=2) + "\n")
    families = {}
    for entry in payload["bones"]:
        families[entry["family"]] = families.get(entry["family"], 0) + 1
    summary = ", ".join(f"{family} {count}" for family, count in sorted(families.items()))
    print(f"{out}: {len(payload['bones'])} bones ({summary})")


if __name__ == "__main__":
    main()
