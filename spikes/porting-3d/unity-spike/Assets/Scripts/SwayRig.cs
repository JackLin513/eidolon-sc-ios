using System.Collections.Generic;
using UnityEngine;

/// Binds a parsed `<character>_sway` file to the instantiated character.
///
/// The sway file is written against the game's own path
/// `MODEL_00/BODY_SCALE/BASE/...`; the prefab has no BODY_SCALE node, so the
/// path is matched with that segment removed, rooted at MODEL_00.
public sealed class SwayRig
{
    public sealed class Collider
    {
        public SwayColliderData data;
        public Transform joint;
        public int index;
    }

    public sealed class Bone
    {
        public SwayBoneData data;
        public SwayManagerData manager;
        public Transform transform;
        public Transform tip;
        public int index;
        public Quaternion restLocalRotation;
        public Vector3 restTipDirection;   // bone-local, normalised
        public float swayLength;
        public Quaternion initialLocalRotation;
        public Vector3 aimVector;
        public readonly List<Collider> colliders = new List<Collider>();
        public Bone sideLink;

        // Working state, mirroring the game's SwayBoneMT.WorkingParams.
        public Vector3 force;
        public Vector3 curTipPos;
        public Vector3 prevTipPos;
        public Vector3 lastBasePos;
        public Vector3 skirtNormal;
        public Vector3 skirtDir;
        public float minZAngle;
        public float maxZAngle;
        public bool lineHit;
        public bool sphereHit;
    }

    public readonly List<Bone> bones = new List<Bone>();
    public readonly List<Collider> colliders = new List<Collider>();
    public readonly List<Bone> skirtBones = new List<Bone>();

    private readonly Dictionary<string, Transform> byPath = new Dictionary<string, Transform>();
    private readonly Dictionary<string, Bone> bonesByPath = new Dictionary<string, Bone>();

    public static SwayRig Build(SwayFile file, Transform root)
    {
        var rig = new SwayRig();
        rig.IndexPaths(root);

        for (var i = 0; i < file.colliders.Count; i++)
        {
            var data = file.colliders[i];
            var joint = rig.Resolve(data.joint);
            if (joint == null) continue;
            rig.colliders.Add(new Collider { data = data, joint = joint, index = i });
        }

        for (var i = 0; i < file.bones.Count; i++)
        {
            var data = file.bones[i];
            var transform = rig.Resolve(data.path);
            if (transform == null)
            {
                Debug.LogWarning($"Sway: no transform for {data.path}");
                continue;
            }
            var bone = new Bone
            {
                data = data,
                manager = file.ManagerFor(data.path),
                transform = transform,
                index = i,
                restLocalRotation = transform.localRotation,
            };
            rig.bones.Add(bone);
            rig.bonesByPath[data.path] = bone;
            if (data.isSkirt) rig.skirtBones.Add(bone);
        }

        // Each sway bone drives the transform of its first child: that child is
        // the tip the collider resolves against and the length the rotation is
        // built from.
        foreach (var bone in rig.bones)
        {
            if (bone.transform.childCount == 0) continue;
            bone.tip = bone.transform.GetChild(0);
            var local = bone.tip.localPosition;
            bone.swayLength = local.magnitude;
            bone.restTipDirection = bone.swayLength > 1e-5f ? local / bone.swayLength : Vector3.down;
        }

        // Collider indices are per manager; a bone names `<joint>#<index>` too,
        // but the index is what the game uses, so match on the parsed index.
        foreach (var bone in rig.bones)
        {
            foreach (var index in bone.data.colliderIndices)
            {
                if (index < 0 || index >= rig.colliders.Count) continue;
                bone.colliders.Add(rig.colliders[index]);
            }
            if (bone.data.sideLink != null && rig.bonesByPath.TryGetValue(bone.data.sideLink, out var link))
                bone.sideLink = link;
        }
        return rig;
    }

    private void IndexPaths(Transform root)
    {
        foreach (var transform in root.GetComponentsInChildren<Transform>(true))
        {
            var parts = new List<string>();
            var rooted = false;
            for (var cursor = transform; cursor != null; cursor = cursor.parent)
            {
                parts.Add(cursor.name);
                if (cursor.name == "MODEL_00") { rooted = true; break; }
            }
            if (!rooted) continue;
            parts.Reverse();
            byPath[string.Join("/", parts)] = transform;
        }
    }

    private Transform Resolve(string path)
    {
        if (byPath.TryGetValue(path, out var direct)) return direct;
        var trimmed = path.Replace("/BODY_SCALE", "");
        if (byPath.TryGetValue(trimmed, out var found)) return found;
        // The head is a self-contained rig parented under the body's ATAMA, so
        // its own hair sits one `ch_head/KUBI/ATAMA` deeper than the game's path.
        var head = trimmed.Replace("/KUBI/ATAMA/HAIR/", "/KUBI/ATAMA/ch_head/KUBI/ATAMA/HAIR/");
        return byPath.TryGetValue(head, out var headFound) ? headFound : null;
    }
}
