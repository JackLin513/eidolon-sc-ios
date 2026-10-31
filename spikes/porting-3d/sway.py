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
import re
import struct
from pathlib import Path

FORMAT = "eidolon.sway/1"
GAME_FORMAT = "eidolon.sway/2"

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



# --- the game's own data ------------------------------------------------------

GAME_PREFIXES = ("MODEL_00/BODY_SCALE/BASE/", "MODEL_00/BODY_SCALE/", "MODEL_00/")


def runtime_path(path: str) -> str:
    """`MODEL_00/BODY_SCALE/BASE/KOSHI/...` → the joint name the app sees."""
    for prefix in GAME_PREFIXES:
        if path.startswith(prefix):
            return path[len(prefix):]
    return path


def parse_sway_text(text: str):
    """Read `<model>_sway.txt`: stanzas of `Key: value` under a header line."""
    managers: dict[str, dict] = {}
    bones: dict[str, dict] = {}
    colliders: list[dict] = []
    current = None
    for line in text.splitlines():
        if not line.strip():
            continue
        header = re.match(r"^(SwayManager|SwayBone|SwayCollider): (.+)$", line)
        if header:
            kind, path = header.groups()
            current = {"path": path, "values": {}, "refs": []}
            if kind == "SwayManager":
                managers[path] = current
            elif kind == "SwayBone":
                bones[path] = current
            else:
                colliders.append(current)
            continue
        if current is None:
            continue
        ref = re.match(r"^\s+(\d+): (.+)$", line)
        if ref:
            current["refs"].append(ref.group(2).strip())
            continue
        item = re.match(r"^\s+([A-Za-z0-9_]+): (.*)$", line)
        if item:
            current["values"][item.group(1)] = item.group(2).strip()
    return managers, bones, colliders


def number(values: dict, key: str, default: float = 0.0) -> float:
    try:
        return float(values.get(key, default))
    except (TypeError, ValueError):
        return default


def manager_for(path: str, managers: dict[str, dict]):
    """The deepest `SwayManager` group a bone belongs to."""
    best = None
    for candidate in managers:
        if path.startswith(candidate) and (best is None or len(candidate) > len(best)):
            best = candidate
    return managers[best] if best else None


def spring_from(values: dict, group: dict | None) -> dict:
    source = values if values.get("refParam", "Self") == "Self" else (group or {})
    group_values = (group or {}).get("values", {})
    gravity_values = source.get("gravity") or group_values.get("gravity") or "0,-1,0"
    try:
        parts = [float(part) for part in gravity_values.split(",")]
    except ValueError:
        parts = [0.0, -1.0, 0.0]
    magnitude = sum(part * part for part in parts) ** 0.5
    return {
        "stiffness": number(source, "stiffnessForce", number(group_values, "stiffnessForce")),
        "drag": number(source, "dragForce", number(group_values, "dragForce")),
        "gravity": round(magnitude, 8),
    }

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


def vector(values: dict, key: str, default=(0.0, 0.0, 0.0)) -> list:
    try:
        parts = [float(part) for part in values[key].split(",")]
    except (KeyError, ValueError):
        return list(default)
    return parts if len(parts) == 3 else list(default)


def build(gltf: Path, sway_texts: list[Path] | None = None) -> dict:
    document = Document(gltf)
    armature = document.armature()
    bones = set(armature)
    centroids = document.bone_centroids()
    names = {document.runtime_name(node) for node in armature}

    managers: dict[str, dict] = {}
    game_bones: dict[str, dict] = {}
    collider_stanzas: list[dict] = []
    for path in sway_texts or []:
        parsed_managers, parsed_bones, parsed_colliders = parse_sway_text(
            path.read_text()
        )
        managers.update({runtime_path(key): value for key, value in parsed_managers.items()})
        game_bones.update({runtime_path(key): value for key, value in parsed_bones.items()})
        collider_stanzas.extend(parsed_colliders)

    # Colliders, indexed by (joint, ordinal) in file order; the game's data
    # refers to them as `<joint>#<ordinal>`.
    collider_index: dict[tuple[str, int], int] = {}
    collider_entries: list[dict] = []
    ordinals: dict[str, int] = {}
    for stanza in collider_stanzas:
        joint = runtime_path(stanza["path"])
        ordinal = ordinals.get(joint, 0)
        ordinals[joint] = ordinal + 1
        values = stanza["values"]
        kind = values.get("type", "Sphere")
        if kind not in ("Sphere", "Capsule"):
            continue  # planes and bridges are not modelled yet
        ortho = vector(values, "offset")
        collider_index[(joint, ordinal)] = len(collider_entries)
        collider_entries.append({
            "joint": joint,
            "type": kind.lower(),
            "radius": round(number(values, "radius"), 6),
            "distance": round(number(values, "distance"), 6),
            "offset": [round(value, 6) for value in mirror(ortho)],
            "axis": values.get("axis", "X").upper(),
        })

    entries = []
    used_colliders: list[int] = []
    for node in armature:
        name = document.runtime_name(node)
        family = family_of(name)
        if family is None:
            continue
        stanza = game_bones.get(name)
        if sway_texts and stanza is None:
            # A bone the game's data does not list stays rigid; guessing a
            # spring for it would use the wrong scale and swing it wildly.
            continue
        tail = tail_for(document, node, bones, centroids)
        entry = {
            "name": name,
            "family": family,
            "tail": [round(value, 6) for value in tail],
        }
        if stanza is not None:
            values = stanza["values"]
            group = manager_for(runtime_path(stanza["path"]), managers)
            group_values = (group or {}).get("values", {})
            entry["radius"] = round(number(values, "radius"), 6)
            entry["spring"] = spring_from(values, group)
            source = values if values.get("refParam", "Self") == "Self" else group_values
            follow = source.get("followForce", values.get("followForce"))
            if follow is not None:
                entry["follow"] = round(float(follow), 6)
            if values.get("limitAngle") == "True":
                # A few stanzas list the window with min above max (ribbons are
                # stored that way); order each pair so the clamp is a window.
                y = sorted((number(values, "minYAngle"), number(values, "maxYAngle")))
                z = sorted((number(values, "minZAngle"), number(values, "maxZAngle")))
                entry["limit"] = {"minY": y[0], "maxY": y[1], "minZ": z[0], "maxZ": z[1]}
            link = values.get("sideLink")
            if link and runtime_path(link) in names:
                entry["sideLink"] = runtime_path(link)
            entry["sideSpring"] = round(number(values, "sideSpringForce"), 6)
            if number(values, "antiFoldForceK") > 0:
                entry["antiFold"] = {
                    "force": number(values, "antiFoldForceK"),
                    "angle": number(values, "antiFoldAngle"),
                }
            refs = []
            for reference in stanza["refs"]:
                if "#" not in reference:
                    continue
                path, ordinal = reference.rsplit("#", 1)
                key = (runtime_path(path), int(ordinal))
                if key in collider_index and collider_index[key] not in refs:
                    refs.append(collider_index[key])
            if refs:
                entry["colliders"] = refs
                for index in refs:
                    if index not in used_colliders:
                        used_colliders.append(index)
        entries.append(entry)
    entries.sort(key=lambda entry: entry["name"])

    payload = {
        "format": GAME_FORMAT if sway_texts else FORMAT,
        "families": {
            family: {"stiffness": stiffness, "drag": drag, "gravity": gravity}
            for family, stiffness, drag, gravity in FAMILIES.values()
        },
        "bones": entries,
    }
    if sway_texts:
        remap = {old: new for new, old in enumerate(used_colliders)}
        for entry in entries:
            if "colliders" in entry:
                entry["colliders"] = [remap[index] for index in entry["colliders"]]
        payload["colliders"] = [collider_entries[index] for index in used_colliders]
    return payload


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("gltf", type=Path, help="exported character glTF")
    parser.add_argument("--out", type=Path, help="sidecar path")
    parser.add_argument(
        "--sway-text", action="append", type=Path, default=None,
        help="the game's <model>_sway.txt (repeat for head + body)",
    )
    args = parser.parse_args()

    payload = build(args.gltf, args.sway_text)
    out = args.out or args.gltf.with_suffix(".sway.json")
    out.write_text(json.dumps(payload, indent=2) + "\n")
    families = {}
    for entry in payload["bones"]:
        families[entry["family"]] = families.get(entry["family"], 0) + 1
    summary = ", ".join(f"{family} {count}" for family, count in sorted(families.items()))
    print(f"{out}: {len(payload['bones'])} bones ({summary})")


if __name__ == "__main__":
    main()
