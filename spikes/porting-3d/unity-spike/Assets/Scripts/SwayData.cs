using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using UnityEngine;

/// Parser for the game's own `<character>_sway` TextAsset.
///
/// The file is a flat list of sections, one per line header, with indented
/// `key: value` lines under each:
///
///     SwayManager: MODEL_00/BODY_SCALE/BASE/KOSHI/skirt_GP
///       gravity: 0,-0.0001,0
///       stiffnessForce: 0.02
///     SwayCollider: MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_L
///       type: Capsule
///       radius: 0.088
///     SwayBone: MODEL_00/BODY_SCALE/BASE/KOSHI/skirt_GP/skirt_LB0
///       isSkirt: True
///       colliders: 3
///       0: MODEL_00/BODY_SCALE/BASE/KOSHI#0
///
/// Collider indices are per SwayManager: a bone names `<joint>#<index>`.
public sealed class SwayFile
{
    public string top;
    public readonly List<SwayManagerData> managers = new List<SwayManagerData>();
    public readonly List<SwayColliderData> colliders = new List<SwayColliderData>();
    public readonly List<SwayBoneData> bones = new List<SwayBoneData>();

    private sealed class Section
    {
        public string kind;
        public string path;
        public readonly List<KeyValuePair<string, string>> pairs = new List<KeyValuePair<string, string>>();
    }

    public static SwayFile Parse(string text)
    {
        var file = new SwayFile();
        var sections = new List<Section>();
        Section current = null;

        foreach (var raw in text.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (line.Length == 0 || line.Trim().Length == 0) continue;

            if (line[0] != ' ' && line[0] != '\t')
            {
                var colon = line.IndexOf(':');
                if (colon < 0) continue;
                current = new Section
                {
                    kind = line.Substring(0, colon).Trim(),
                    path = line.Substring(colon + 1).Trim(),
                };
                sections.Add(current);
                continue;
            }

            if (current == null) continue;
            var trimmed = line.Trim();
            var split = trimmed.IndexOf(':');
            if (split < 0) continue;
            current.pairs.Add(new KeyValuePair<string, string>(
                trimmed.Substring(0, split).Trim(),
                trimmed.Substring(split + 1).Trim()));
        }

        foreach (var section in sections)
        {
            switch (section.kind)
            {
                case "Top":
                    file.top = section.path;
                    break;
                case "SwayManager":
                    file.managers.Add(SwayManagerData.From(section.path, section.pairs));
                    break;
                case "SwayCollider":
                    file.colliders.Add(SwayColliderData.From(section.path, section.pairs));
                    break;
                case "SwayBone":
                    file.bones.Add(SwayBoneData.From(section.path, section.pairs));
                    break;
            }
        }
        return file;
    }

    public static SwayFile Load(string path) => Parse(File.ReadAllText(path));

    /// The manager whose subtree contains `path` — the deepest matching one.
    public SwayManagerData ManagerFor(string path)
    {
        SwayManagerData best = null;
        foreach (var manager in managers)
        {
            if (path != manager.path && !path.StartsWith(manager.path + "/", System.StringComparison.Ordinal))
                continue;
            if (best == null || manager.path.Length > best.path.Length) best = manager;
        }
        return best;
    }

    internal static float F(IReadOnlyDictionary<string, string> map, string key, float fallback)
        => map.TryGetValue(key, out var text) && float.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
            ? value : fallback;

    internal static Vector3 V(IReadOnlyDictionary<string, string> map, string key, Vector3 fallback)
    {
        if (!map.TryGetValue(key, out var text)) return fallback;
        var parts = text.Split(',');
        if (parts.Length != 3) return fallback;
        return new Vector3(
            float.Parse(parts[0], CultureInfo.InvariantCulture),
            float.Parse(parts[1], CultureInfo.InvariantCulture),
            float.Parse(parts[2], CultureInfo.InvariantCulture));
    }

    internal static Dictionary<string, string> ToMap(List<KeyValuePair<string, string>> pairs)
    {
        var map = new Dictionary<string, string>();
        foreach (var pair in pairs) map[pair.Key] = pair.Value;
        return map;
    }

    internal static bool B(IReadOnlyDictionary<string, string> map, string key, bool fallback)
        => map.TryGetValue(key, out var text)
            ? string.Equals(text, "True", System.StringComparison.OrdinalIgnoreCase)
            : fallback;
}

public sealed class SwayManagerData
{
    public string path;
    public Vector3 gravity;
    public float stiffnessForce;
    public float dragForce;
    public float followForce;
    public float lineMoveLimit;
    public float sidelineMoveLimit;

    public static SwayManagerData From(string path, List<KeyValuePair<string, string>> pairs)
    {
        var map = SwayFile.ToMap(pairs);
        return new SwayManagerData
        {
            path = path,
            gravity = SwayFile.V(map, "gravity", Vector3.zero),
            stiffnessForce = SwayFile.F(map, "stiffnessForce", 0.01f),
            dragForce = SwayFile.F(map, "dragForce", 0.5f),
            followForce = SwayFile.F(map, "followForce", 0f),
            lineMoveLimit = SwayFile.F(map, "lineMoveLimit", 0f),
            sidelineMoveLimit = SwayFile.F(map, "sidelineMoveLimit", 0f),
        };
    }
}

public sealed class SwayColliderData
{
    public string joint;
    public string type;          // Sphere | Capsule
    public string axis;          // capsule axis
    public float radius;
    public float distance;       // capsule length along axis
    public Vector3 offset;
    public string planeAxis;
    public bool planeRotOn;
    public Vector3 planeRotEuler;

    public static SwayColliderData From(string path, List<KeyValuePair<string, string>> pairs)
    {
        var map = SwayFile.ToMap(pairs);
        return new SwayColliderData
        {
            joint = path,
            type = map.TryGetValue("type", out var t) ? t : "Sphere",
            axis = map.TryGetValue("axis", out var a) ? a : "X",
            radius = SwayFile.F(map, "radius", 0.05f),
            distance = SwayFile.F(map, "distance", 0f),
            offset = SwayFile.V(map, "offset", Vector3.zero),
            planeAxis = map.TryGetValue("planeAxis", out var p) ? p : "plusX",
            planeRotOn = SwayFile.B(map, "planeRotOn", false),
            planeRotEuler = SwayFile.V(map, "planeRotEuler", Vector3.zero),
        };
    }
}

public sealed class SwayBoneData
{
    public string path;
    public float radius;
    public string type;
    public bool isSkirt;
    public bool hitMuteForce;
    public float hitMuteRate;
    public string sideLink;
    public bool limitAngle;
    public bool useBindDir;
    public float minYAngle, maxYAngle, minZAngle, maxZAngle;
    public float followForce;
    public string refParam;
    public float stiffnessForce;
    public float dragForce;
    public bool hitTwice;
    public bool useLinkHit;
    public Vector3 gravity;
    public Vector3 colliderOffset;
    public float sideSpringTolerance;
    public float sideSpringForce;
    public readonly List<int> colliderIndices = new List<int>();

    public static SwayBoneData From(string path, List<KeyValuePair<string, string>> pairs)
    {
        var map = SwayFile.ToMap(pairs);
        var bone = new SwayBoneData
        {
            path = path,
            radius = SwayFile.F(map, "radius", 0.02f),
            type = map.TryGetValue("type", out var t) ? t : "Sphere",
            isSkirt = SwayFile.B(map, "isSkirt", false),
            hitMuteForce = SwayFile.B(map, "HitMuteForce", false),
            hitMuteRate = SwayFile.F(map, "HitMuteRate", 1f),
            sideLink = map.TryGetValue("sideLink", out var s) ? s : null,
            limitAngle = SwayFile.B(map, "limitAngle", false),
            useBindDir = SwayFile.B(map, "useBindDir", false),
            minYAngle = SwayFile.F(map, "minYAngle", 0f),
            maxYAngle = SwayFile.F(map, "maxYAngle", 0f),
            minZAngle = SwayFile.F(map, "minZAngle", 0f),
            maxZAngle = SwayFile.F(map, "maxZAngle", 0f),
            followForce = SwayFile.F(map, "followForce", 0f),
            refParam = map.TryGetValue("refParam", out var r) ? r : "Self",
            stiffnessForce = SwayFile.F(map, "stiffnessForce", 0.01f),
            dragForce = SwayFile.F(map, "dragForce", 0.5f),
            hitTwice = SwayFile.B(map, "hitTwice", false),
            useLinkHit = SwayFile.B(map, "useLinkHit", false),
            gravity = SwayFile.V(map, "gravity", Vector3.zero),
            colliderOffset = SwayFile.V(map, "colliderOffset", Vector3.zero),
            sideSpringTolerance = SwayFile.F(map, "sideSpringTorelance", 1f),
            sideSpringForce = SwayFile.F(map, "sideSpringForce", 0f),
        };
        foreach (var pair in pairs)
        {
            if (pair.Key.Length == 0 || !char.IsDigit(pair.Key[0])) continue;
            var hash = pair.Value.LastIndexOf('#');
            bone.colliderIndices.Add(hash >= 0 && int.TryParse(pair.Value.Substring(hash + 1), out var index) ? index : -1);
        }
        return bone;
    }
}

