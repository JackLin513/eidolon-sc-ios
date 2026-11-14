// Parser for the game's own `<bundle>_sway` TextAsset, matching the native
// import pipeline `Imas.BoneLib.SwayFileIO`:
//
//   SwayFileIO.Import           (0x1C761C0)  / ImportCommon (0x1C764FC)
//   SwayFileIO.ReadText/Install (0x1C7641C / 0x1C779C8)
//   SwayFileIO.PearsText        (0x1C77EAC)  line parser, builds SwayParamsScrObj
//   SwayParamsScrObj            (dump.cs 15317): List<SwayBoneParams>,
//                                List<SwayColliderParams>, List<SwayManagerParams>
//
// The text file is a flat list of stanzas:
//
//   Top: Chara/body/ss003/cb_ss003_001har/cb_ss003_001har
//   SwayManager: MODEL_00
//     gravity: 0,-0.0001,0
//     ...
//   SwayCollider: MODEL_00/BODY_SCALE/BASE/KOSHI
//     type: Sphere
//     radius: 0.13
//     ...
//   SwayBone: MODEL_00/BODY_SCALE/BASE/KOSHI/skirt_GP/skirt_B0
//     radius: 0.05
//     ...
//     colliders: 2
//     0: MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_L#0
//     1: MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_R#0
//
// Two data facts that the old approximate parser got wrong and that are
// preserved here (see audit-migration P0-1/P0-2):
//
//  1. `<joint>#k` -> k is the k-th SwayCollider component **on that joint**
//     (SwayFileIO.AttachSwayBone 0x1C7726C: FindObjectByPath(top, path) then
//     GetComponents<SwayCollider>() and array[n]). It is NOT an index into the
//     file-wide collider array. SwayColliderSet keeps path + n.
//  2. The body and head `_sway` files are merged into one rig by
//     SwayFileIO.ImportCommon (0x1C764FC) which attaches managers, colliders
//     and bones from both files to the same top object in this order:
//       AttachSwayManager(body), AttachSwayManager(head),
//       AttachSwayCollider(body, skirtGuardOffset), AttachSwayCollider(head, 0),
//       AttachSwayBone(body), AttachSwayBone(head).
//     Therefore collider refs in the head file may point at body colliders and
//     vice versa; SwayFileNative itself stays per-file, SwayManagerNative.Build
//     does the merge in that exact order.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using UnityEngine;

/// <summary>SwayManagerParams (dump.cs 15316) + the newer optional fields.</summary>
[Serializable]
public sealed class SwayManagerNativeParams
{
    public string path;
    public string fname;

    // Old format, always written.
    public Vector3 gravity;          // 0x20
    public float stiffnessForce;     // 0x2C
    public float dragForce;          // 0x30
    public float followForce;        // 0x34
    public float lineMoveLimit;      // 0x38
    public float sidelineMoveLimit;  // 0x3C

    // Newer format (audit §4.4: isSpread/threshold14/20/SpreadZRot*/pushRatio*).
    public bool isSpread;
    public float threshold14;
    public float spreadZRot14;
    public float pushRatio14_0;
    public float pushRatio14_1;
    public float threshold20;
    public float spreadZRot20;
    public float pushRatio20_0;
    public float pushRatio20_1;
    public float pushRatio20_2;

    public readonly Dictionary<string, string> extra = new Dictionary<string, string>(StringComparer.Ordinal);
}

/// <summary>
/// SwayColliderParams (dump.cs 15309). `id` is the file-local ordinal (native
/// PearsText assigns it while building the list; SwayCollider.id is copied from
/// it in AttachSwayCollider 0x1C76DD8).
/// </summary>
[Serializable]
public sealed class SwayColliderNativeParams
{
    public string path;
    public string fname;
    public int id;

    public SwayColliderType type;               // type: Sphere|Capsule|Plane|Bridge
    public SwayColliderAxis axis;               // axis: X|Y|Z
    public float n_radius;                      // text key `radius` (SwayCollider.n_radius)
    public string bridgetgt;                    // Bridge only
    public float distance;                      // capsule length
    public Vector3 offset;
    public SwayPlaneAxis planeAxis;             // planeAxis: plusX..minusZ
    public bool CapsuleSphere1;
    public bool CapsuleSphere2;
    public SwayClipPlane clipPlane;             // clipPlane: All/Axis2ndPlus..Axis3rdMinus
    // Skirt barrier. The shipped ss001 _sway file has NO `useSkirtBarrier`
    // field at all, yet the native runtime value is 1 for every collider
    // (verified by reading SwayCtrlMT.swayColliderParamsArray @0x64 in the
    // running game). The parser therefore defaults to true, matching native.
    // Turning this off is what let the thighs punch through the front skirt
    // panels at t≈23 s: the barrier is the mechanism that pushes a panel out
    // of the skirt plane before the capsule test ever runs.
    public bool useSkirtBarrier = true;
    public bool planeRotOn;
    public Quaternion planeRotQ;                // built from planeRotEuler (degrees)
    public Vector3 planeRotEuler;

    public readonly Dictionary<string, string> extra = new Dictionary<string, string>(StringComparer.Ordinal);
}

/// <summary>
/// SwayColliderSet (dump.cs 15303): a bone's reference to one SwayCollider.
/// `path` and `n` come straight from the text; `c` is resolved after all
/// colliders of the merged rig exist (AttachSwayBone 0x1C7726C).
/// </summary>
[Serializable]
public sealed class SwayColliderSetNative
{
    public SwayColliderNative c;   // resolved component, null until Build
    public string path;            // joint path without the #n suffix
    public int n;                  // per-joint component ordinal
    public string raw;             // original `path#n` text, for diagnostics
}

/// <summary>
/// SwayBoneParams (dump.cs 15302) + newer optional fields (isZConstraint,
/// HitOneCollider, sideAntiSpring*, antiFold*). Text key `radius` maps to
/// n_radius; SwayBone.InitSub 0x1C711A4 computes radius = n_radius * bodyScale.
/// </summary>
[Serializable]
public sealed class SwayBoneNativeParams
{
    public string path;
    public string fname;

    public float n_radius;                 // key `radius`
    public Vector3 gravity;
    public SwayHitType type;               // key `type` (always Sphere in text)
    public bool isSkirt;
    public bool HitMuteForce;
    public float HitMuteRate;
    public string sideLink;
    public bool limitAngle;
    public bool useBindDir;
    public float minYAngle;
    public float maxYAngle;
    public float minZAngle;
    public float maxZAngle;
    public float followForce;
    public SwayRefType refParam;
    public float stiffnessForce;
    public float dragForce;
    public bool hitTwice;
    public bool useLinkHit;
    public bool isZConstraint;             // newer format, parsed for parity
    public bool HitOneCollider;            // newer format, parsed for parity
    public readonly List<SwayColliderSetNative> colliders = new List<SwayColliderSetNative>();
    public Vector3 colliderOffset;
    public float sideSpringTorelance;
    public float sideSpringForce;
    public float sideAntiSpringTorelance;
    public float sideAntiSpringForce;
    public float antiFoldForceK;
    public float antiFoldAngle;

    public readonly Dictionary<string, string> extra = new Dictionary<string, string>(StringComparer.Ordinal);

    /// <summary>Index of this bone inside the parsed file, used as FixedParams.swbIndex.</summary>
    public int fileIndex;
}

/// <summary>
/// One parsed `_sway` file. Kept separate from the merged rig because the game
/// also parses per bundle (`SwayParamsScrObj`) before ImportCommon merges them.
/// </summary>
public sealed class SwayFileNative
{
    public string top;
    public readonly List<SwayManagerNativeParams> managers = new List<SwayManagerNativeParams>();
    public readonly List<SwayColliderNativeParams> colliders = new List<SwayColliderNativeParams>();
    public readonly List<SwayBoneNativeParams> bones = new List<SwayBoneNativeParams>();

    /// <summary>Raw text, for diagnostics (not used by the solver).</summary>
    public string sourceText;

    private sealed class Stanza
    {
        public string kind;
        public string path;
        public readonly List<KeyValuePair<string, string>> lines = new List<KeyValuePair<string, string>>();
    }

    public static SwayFileNative Parse(string text)
    {
        if (text == null) throw new ArgumentNullException(nameof(text));
        var file = new SwayFileNative { sourceText = text };
        var stanzas = new List<Stanza>();
        Stanza current = null;

        // PearsText / ReadTextInternal consume the TextAsset line by line; the
        // parser is whitespace sensitive only for "indented = field".
        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if (line.Length == 0) continue;
            // 89/1554 corpus files start with a UTF-8 BOM; native TextAsset
            // strips it, our string may still carry it.
            if (line[0] == '\uFEFF') line = line.Substring(1);
            if (line.Length == 0 || line.Trim().Length == 0) continue;

            var indented = line[0] == ' ' || line[0] == '\t';
            if (!indented)
            {
                var colon = line.IndexOf(':');
                if (colon < 0) continue;
                current = new Stanza
                {
                    kind = line.Substring(0, colon).Trim(),
                    path = line.Substring(colon + 1).Trim(),
                };
                stanzas.Add(current);
                continue;
            }
            if (current == null) continue;
            var body = line.Trim();
            var split = body.IndexOf(':');
            if (split < 0) continue;
            current.lines.Add(new KeyValuePair<string, string>(
                body.Substring(0, split).Trim(),
                body.Substring(split + 1).Trim()));
        }

        foreach (var stanza in stanzas)
        {
            switch (stanza.kind)
            {
                case "Top":
                    file.top = stanza.path;
                    break;
                case "SwayManager":
                    file.managers.Add(ParseManager(stanza.path, stanza.lines));
                    break;
                case "SwayCollider":
                    file.colliders.Add(ParseCollider(stanza.path, stanza.lines, file.colliders.Count));
                    break;
                case "SwayBone":
                    var bone = ParseBone(stanza.path, stanza.lines);
                    bone.fileIndex = file.bones.Count;
                    file.bones.Add(bone);
                    break;
                default:
                    // Unknown stanza types are ignored exactly like PearsText's
                    // default branch (only Top/Manager/Collider/Bone exist).
                    break;
            }
        }
        return file;
    }

    public static SwayFileNative Load(string path)
    {
        return Parse(File.ReadAllText(path));
    }

    /// <summary>
    /// Deepest manager whose subtree contains `path` (native SwayManager.Init
    /// collects bones recursively under its own transform, so a bone belongs to
    /// the deepest manager above it). Paths are the raw text paths.
    /// </summary>
    public SwayManagerNativeParams ManagerFor(string path)
    {
        SwayManagerNativeParams best = null;
        for (var i = 0; i < managers.Count; i++)
        {
            var m = managers[i];
            if (m.path == null) continue;
            if (path != m.path && !path.StartsWith(m.path + "/", StringComparison.Ordinal)) continue;
            if (best == null || m.path.Length > best.path.Length) best = m;
        }
        return best;
    }

    public SwayBoneNativeParams BoneFor(string path)
    {
        for (var i = 0; i < bones.Count; i++)
            if (bones[i].path == path) return bones[i];
        return null;
    }

    public SwayColliderNativeParams ColliderFor(string path, int id = -1)
    {
        if (id >= 0 && id < colliders.Count && colliders[id].path == path) return colliders[id];
        for (var i = 0; i < colliders.Count; i++)
            if (colliders[i].path == path) return colliders[i];
        return null;
    }

    private static SwayManagerNativeParams ParseManager(string path, List<KeyValuePair<string, string>> lines)
    {
        var m = new SwayManagerNativeParams { path = path, fname = path };
        foreach (var pair in lines)
        {
            var key = pair.Key;
            var value = pair.Value;
            switch (key)
            {
                case "gravity": m.gravity = ParseVector(value, Vector3.zero); break;
                case "stiffnessForce": m.stiffnessForce = ParseFloat(value, 0f); break;
                case "dragForce": m.dragForce = ParseFloat(value, 0f); break;
                case "followForce": m.followForce = ParseFloat(value, 0f); break;
                case "lineMoveLimit": m.lineMoveLimit = ParseFloat(value, 0f); break;
                case "sidelineMoveLimit": m.sidelineMoveLimit = ParseFloat(value, 0f); break;
                case "isSpread": m.isSpread = ParseBool(value, false); break;
                case "threshold14": m.threshold14 = ParseFloat(value, 0f); break;
                case "SpreadZRot14": m.spreadZRot14 = ParseFloat(value, 0f); break;
                case "pushRatio14_0": m.pushRatio14_0 = ParseFloat(value, 0f); break;
                case "pushRatio14_1": m.pushRatio14_1 = ParseFloat(value, 0f); break;
                case "threshold20": m.threshold20 = ParseFloat(value, 0f); break;
                case "SpreadZRot20": m.spreadZRot20 = ParseFloat(value, 0f); break;
                case "pushRatio20_0": m.pushRatio20_0 = ParseFloat(value, 0f); break;
                case "pushRatio20_1": m.pushRatio20_1 = ParseFloat(value, 0f); break;
                case "pushRatio20_2": m.pushRatio20_2 = ParseFloat(value, 0f); break;
                default: m.extra[key] = value; break;
            }
        }
        return m;
    }

    private static SwayColliderNativeParams ParseCollider(string path, List<KeyValuePair<string, string>> lines, int id)
    {
        var c = new SwayColliderNativeParams
        {
            path = path,
            fname = path,
            id = id,
            type = SwayColliderType.Sphere,
            axis = SwayColliderAxis.X,
            planeAxis = SwayPlaneAxis.plusX,
            clipPlane = SwayClipPlane.All,
        };
        foreach (var pair in lines)
        {
            var key = pair.Key;
            var value = pair.Value;
            switch (key)
            {
                case "type": c.type = ParseColliderType(value, SwayColliderType.Sphere); break;
                case "axis": c.axis = ParseColliderAxis(value, SwayColliderAxis.X); break;
                case "radius": c.n_radius = ParseFloat(value, 0f); break;
                case "distance": c.distance = ParseFloat(value, 0f); break;
                case "offset": c.offset = ParseVector(value, Vector3.zero); break;
                case "planeAxis": c.planeAxis = ParsePlaneAxis(value, SwayPlaneAxis.plusX); break;
                case "CapsuleSphere1": c.CapsuleSphere1 = ParseBool(value, false); break;
                case "CapsuleSphere2": c.CapsuleSphere2 = ParseBool(value, false); break;
                case "clipPlane": c.clipPlane = ParseClipPlane(value, SwayClipPlane.All); break;
                case "useSkirtBarrier": c.useSkirtBarrier = ParseBool(value, true); break;
                case "bridgetgt": c.bridgetgt = value; break;
                case "planeRotOn": c.planeRotOn = ParseBool(value, false); break;
                case "planeRotEuler":
                    // Plane rotation is kept as Euler here (PearsText stores the
                    // Quaternion in SwayColliderParams); SwayColliderNative.Attach
                    // converts it with Quaternion.Euler in the Unity runtime.
                    c.planeRotEuler = ParseVector(value, Vector3.zero);
                    break;
                default: c.extra[key] = value; break;
            }
        }
        return c;
    }

    private static SwayBoneNativeParams ParseBone(string path, List<KeyValuePair<string, string>> lines)
    {
        var b = new SwayBoneNativeParams
        {
            path = path,
            fname = path,
            refParam = SwayRefType.Manager, // enum default in the native class; text always writes it
            type = SwayHitType.Sphere,
        };
        foreach (var pair in lines)
        {
            var key = pair.Key;
            var value = pair.Value;
            // Numeric keys are collider slots: `0:` .. `n-1:` -> `<path>#<k>`.
            if (key.Length > 0 && char.IsDigit(key[0]))
            {
                b.colliders.Add(ParseColliderSet(value));
                continue;
            }
            switch (key)
            {
                case "radius": b.n_radius = ParseFloat(value, 0f); break;
                case "gravity": b.gravity = ParseVector(value, Vector3.zero); break;
                case "type": b.type = ParseHitType(value, SwayHitType.Sphere); break;
                case "isSkirt": b.isSkirt = ParseBool(value, false); break;
                case "HitMuteForce": b.HitMuteForce = ParseBool(value, false); break;
                case "HitMuteRate": b.HitMuteRate = ParseFloat(value, 0f); break;
                case "sideLink": b.sideLink = string.IsNullOrEmpty(value) ? null : value; break;
                case "limitAngle": b.limitAngle = ParseBool(value, false); break;
                case "useBindDir": b.useBindDir = ParseBool(value, false); break;
                case "minYAngle": b.minYAngle = ParseFloat(value, 0f); break;
                case "maxYAngle": b.maxYAngle = ParseFloat(value, 0f); break;
                case "minZAngle": b.minZAngle = ParseFloat(value, 0f); break;
                case "maxZAngle": b.maxZAngle = ParseFloat(value, 0f); break;
                case "followForce": b.followForce = ParseFloat(value, 0f); break;
                case "refParam": b.refParam = ParseRefType(value, SwayRefType.Manager); break;
                case "stiffnessForce": b.stiffnessForce = ParseFloat(value, 0f); break;
                case "dragForce": b.dragForce = ParseFloat(value, 0f); break;
                case "hitTwice": b.hitTwice = ParseBool(value, false); break;
                case "useLinkHit": b.useLinkHit = ParseBool(value, false); break;
                case "useHitLink": b.useLinkHit = ParseBool(value, false); break;
                case "HitOneCollider": b.HitOneCollider = ParseBool(value, false); break;
                case "isZConstraint": b.isZConstraint = ParseBool(value, false); break;
                case "colliders": break; // count line, self-check only
                case "colliderOffset": b.colliderOffset = ParseVector(value, Vector3.zero); break;
                case "sideSpringTorelance": b.sideSpringTorelance = ParseFloat(value, 0f); break;
                case "sideSpringForce": b.sideSpringForce = ParseFloat(value, 0f); break;
                case "sideAntiSpringTorelance": b.sideAntiSpringTorelance = ParseFloat(value, 0f); break;
                case "sideAntiSpringForce": b.sideAntiSpringForce = ParseFloat(value, 0f); break;
                case "antiFoldForceK": b.antiFoldForceK = ParseFloat(value, 0f); break;
                case "antiFoldAngle": b.antiFoldAngle = ParseFloat(value, 0f); break;
                default: b.extra[key] = value; break;
            }
        }
        return b;
    }

    /// <summary>
    /// Parse one collider reference `<jointPath>#<k>`.
    /// Native AttachSwayBone 0x1C7726C: FindObjectByPath(top, path), then
    /// GetComponents&lt;SwayCollider&gt;()[n].
    /// </summary>
    private static SwayColliderSetNative ParseColliderSet(string value)
    {
        var set = new SwayColliderSetNative { raw = value, n = 0 };
        var hash = value.LastIndexOf('#');
        if (hash < 0)
        {
            // Corpus never does this; native PearsText would have no ordinal and
            // AttachSwayBone defaults n to 0.
            set.path = value.Trim();
            return set;
        }
        set.path = value.Substring(0, hash).Trim();
        int n;
        set.n = int.TryParse(value.Substring(hash + 1).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out n) && n >= 0
            ? n
            : 0;
        return set;
    }

    internal static float ParseFloat(string text, float fallback)
    {
        float value;
        return float.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out value) ? value : fallback;
    }

    internal static bool ParseBool(string text, bool fallback)
    {
        if (string.IsNullOrEmpty(text)) return fallback;
        var t = text.Trim();
        if (string.Equals(t, "True", StringComparison.OrdinalIgnoreCase)) return true;
        if (string.Equals(t, "False", StringComparison.OrdinalIgnoreCase)) return false;
        if (t == "1") return true;
        if (t == "0") return false;
        return fallback;
    }

    internal static Vector3 ParseVector(string text, Vector3 fallback)
    {
        if (string.IsNullOrEmpty(text)) return fallback;
        var parts = text.Split(',');
        if (parts.Length != 3) return fallback;
        return new Vector3(
            ParseFloat(parts[0], fallback.x),
            ParseFloat(parts[1], fallback.y),
            ParseFloat(parts[2], fallback.z));
    }

    internal static SwayColliderType ParseColliderType(string text, SwayColliderType fallback)
    {
        switch ((text ?? string.Empty).Trim().ToLowerInvariant())
        {
            case "sphere": return SwayColliderType.Sphere;
            case "capsule": return SwayColliderType.Capsule;
            case "plane": return SwayColliderType.Plane;
            case "bridge": return SwayColliderType.Bridge;
            default: return fallback;
        }
    }

    internal static SwayHitType ParseHitType(string text, SwayHitType fallback)
    {
        switch ((text ?? string.Empty).Trim().ToLowerInvariant())
        {
            case "sphere": return SwayHitType.Sphere;
            case "line": return SwayHitType.Line;
            default: return fallback;
        }
    }

    internal static SwayColliderAxis ParseColliderAxis(string text, SwayColliderAxis fallback)
    {
        switch ((text ?? string.Empty).Trim().ToUpperInvariant())
        {
            case "X": return SwayColliderAxis.X;
            case "Y": return SwayColliderAxis.Y;
            case "Z": return SwayColliderAxis.Z;
            default: return fallback;
        }
    }

    internal static SwayPlaneAxis ParsePlaneAxis(string text, SwayPlaneAxis fallback)
    {
        switch ((text ?? string.Empty).Trim())
        {
            case "plusX": return SwayPlaneAxis.plusX;
            case "minusX": return SwayPlaneAxis.minusX;
            case "plusY": return SwayPlaneAxis.plusY;
            case "minusY": return SwayPlaneAxis.minusY;
            case "plusZ": return SwayPlaneAxis.plusZ;
            case "minusZ": return SwayPlaneAxis.minusZ;
            default: return fallback;
        }
    }

    internal static SwayClipPlane ParseClipPlane(string text, SwayClipPlane fallback)
    {
        switch ((text ?? string.Empty).Trim())
        {
            case "All": return SwayClipPlane.All;
            case "Axis2ndPlus": return SwayClipPlane.Axis2ndPlus;
            case "Axis2ndMinus": return SwayClipPlane.Axis2ndMinus;
            case "Axis3rdPlus": return SwayClipPlane.Axis3rdPlus;
            case "Axis3rdMinus": return SwayClipPlane.Axis3rdMinus;
            default: return fallback;
        }
    }

    internal static SwayRefType ParseRefType(string text, SwayRefType fallback)
    {
        switch ((text ?? string.Empty).Trim().ToLowerInvariant())
        {
            case "manager": return SwayRefType.Manager;
            case "self": return SwayRefType.Self;
            default: return fallback;
        }
    }

    /// <summary>Debug summary used by probes / the Lead's scene checks.</summary>
    public string Describe()
    {
        var sb = new StringBuilder();
        sb.Append("SwayFile(top=").Append(top ?? "<null>")
          .Append(" managers=").Append(managers.Count)
          .Append(" colliders=").Append(colliders.Count)
          .Append(" bones=").Append(bones.Count).Append(')');
        return sb.ToString();
    }
}
