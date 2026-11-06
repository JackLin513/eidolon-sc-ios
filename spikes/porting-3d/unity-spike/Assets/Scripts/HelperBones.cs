using System.Collections.Generic;
using System.Linq;
using UnityEngine;

/// The game's `Imas.BoneLib.CalcBone` pass.
///
/// A motion only keys the bones the animator moved. The rig also carries assist
/// bones whose rule is encoded in the bone's name — `HIJI_L__rot_UDE_L__z50`
/// takes half of `UDE_L`'s turn — and the game recomputes them every frame from
/// the reference bone's current pose. Without this pass the elbow, wrist, hip
/// and armpit regions stay at their bind pose while the limb swings, so the
/// mesh crumples into itself (the dark wedge in the crook of a bent elbow).
///
/// Grammar: `<mine>__<algorithm>_<reference>[__<parameters>]`. The algorithms
/// are tested in the order slerp, twist, const, rot; anything else (the
/// `__null` bones) is never registered and stays at rest.
[DefaultExecutionOrder(-50)]
public sealed class HelperBones : MonoBehaviour
{
    private enum Kind { Slerp, Twist, Rot, Constrain }

    private sealed class Helper
    {
        public Transform joint;
        public Kind kind;
        public Transform reference;
        public Quaternion initMy;
        public Quaternion initRef;
        public Vector3 initRefVector;   // initRef * Vector3.right
        public float t;                 // SLERP's blend amount
        public float tx;                // how much of the reference's turn to take
        public char axis = 'x';         // which of the reference's axes the rule reads
        public Vector3 axisVector = Vector3.right;
    }

    private readonly List<Helper> helpers = new List<Helper>();
    private readonly Dictionary<Transform, Quaternion> rest = new Dictionary<Transform, Quaternion>();
    private readonly Dictionary<string, List<Transform>> byLeaf = new Dictionary<string, List<Transform>>();

    public int Count => helpers.Count;

    /// Reads the rest pose and the rules. Call it right after the model is
    /// instantiated, before any clip frame is applied — the game's own pass
    /// wakes up on that same pose.
    public void Bind(Transform root)
    {
        helpers.Clear();
        rest.Clear();
        byLeaf.Clear();

        var all = root.GetComponentsInChildren<Transform>(true);
        foreach (var t in all)
        {
            rest[t] = t.localRotation;
            var leaf = t.name;
            if (!byLeaf.TryGetValue(leaf, out var list)) byLeaf[leaf] = list = new List<Transform>();
            list.Add(t);
        }

        foreach (var t in all)
        {
            if (!TryRule(t.name, out var kind, out var target, out var parT, out var tx, out var axis)) continue;
            var reference = kind == Kind.Twist ? t.parent : Resolve(target, t);
            if (reference == null || !rest.ContainsKey(reference)) continue;
            var initRef = rest[reference];
            helpers.Add(new Helper
            {
                joint = t,
                kind = kind,
                reference = reference,
                initMy = rest[t],
                initRef = initRef,
                initRefVector = initRef * AxisVector(axis),
                axisVector = AxisVector(axis),
                t = parT,
                tx = tx,
                axis = axis,
            });
        }
    }

    private void LateUpdate() => Apply();

    /// Puts every assist bone back at its rest rotation, for A/B probes.
    public void RestoreRest()
    {
        foreach (var h in helpers) h.joint.localRotation = h.initMy;
    }

    public void Apply()
    {
        var constraints = new List<Helper>();
        foreach (var h in helpers)
        {
            var current = h.reference.localRotation;
            switch (h.kind)
            {
                case Kind.Slerp: h.joint.localRotation = SlerpEx(current, h); break;
                case Kind.Twist: h.joint.localRotation = Twist(current, h); break;
                case Kind.Rot: h.joint.localRotation = Rot(current, h); break;
                case Kind.Constrain: constraints.Add(h); break;
            }
        }
        // Constraints need world transforms, so they run after the local ones.
        foreach (var h in constraints) Constrain(h);
    }

    /// `SlerpEx`: blend from the reference's rest rotation towards its current
    /// one, taking `tx` of the way first, then `t` of the way from rest to that.
    private static Quaternion SlerpEx(Quaternion current, Helper h)
    {
        var aligned = Quaternion.FromToRotation(h.initRefVector, current * h.axisVector);
        var goal = aligned * h.initRef;
        var start = Quaternion.Dot(current, goal) < 0 ? Negate(current) : current;
        var middle = Quaternion.Slerp(start, goal, h.tx);
        if (Quaternion.Dot(h.initRef, middle) < 0) middle = Negate(middle);
        return Quaternion.Slerp(h.initRef, middle, h.t);
    }

    /// `Twist`: the reference's twist about its own X axis, scaled by `tx` and
    /// expressed in the reference's frame because the helper is its child.
    private static Quaternion Twist(Quaternion current, Helper h)
    {
        var aligned = Quaternion.FromToRotation(h.initRefVector, current * h.axisVector);
        var goal = aligned * h.initRef;
        var start = Quaternion.Dot(current, goal) < 0 ? Negate(current) : current;
        var turn = Quaternion.Slerp(goal, start, h.tx);
        return Quaternion.Inverse(start) * turn;
    }

    /// `ROT`: the part of the reference's turn the helper has not already taken
    /// by sharing the reference's parent, scaled by `tx`, on top of the
    /// helper's own rest rotation.
    private static Quaternion Rot(Quaternion current, Helper h)
    {
        var aligned = Quaternion.FromToRotation(h.initRefVector, current * h.axisVector);
        var goal = aligned * h.initRef;
        var remainder = Quaternion.Inverse(goal) * current;
        if (remainder.w < 0) remainder = Negate(remainder);
        var turn = Quaternion.Slerp(Quaternion.identity, remainder, h.tx);
        return h.initMy * turn;
    }

    /// `Constrain`: point the helper's local −X at the reference in world space,
    /// then convert back through the helper's own parent.
    private static void Constrain(Helper h)
    {
        h.joint.localRotation = h.initMy;
        var mine = h.joint.rotation;
        var direction = h.reference.position - h.joint.position;
        var distance = direction.magnitude;
        var worldRotation = mine;
        if (distance > 1e-5f)
        {
            var forward = mine * Vector3.left;
            worldRotation = Quaternion.FromToRotation(forward, direction / distance) * mine;
        }
        h.joint.localRotation = h.joint.parent != null
            ? Quaternion.Inverse(h.joint.parent.rotation) * worldRotation
            : worldRotation;
    }

    /// Numbers for one helper, to explain why a rule did or did not bite.
    public string Debug(string leaf)
    {
        var sb = new System.Text.StringBuilder();
        foreach (var h in helpers)
        {
            if (!h.joint.name.StartsWith(leaf)) continue;
            var current = h.reference.localRotation;
            var aligned = Quaternion.FromToRotation(h.initRefVector, current * h.axisVector);
            var goal = aligned * h.initRef;
            var remainder = Quaternion.Inverse(goal) * current;
            sb.Append($"{h.joint.name} kind={h.kind} ref={h.reference.name}\n");
            sb.Append($"  current={current.eulerAngles:F1} initRef={h.initRef.eulerAngles:F1} initMy={h.initMy.eulerAngles:F1}\n");
            sb.Append($"  initRefVec={h.initRefVector:F3} cur*axis={current * h.initRefVector:F3}\n");
            sb.Append($"  cur=({current.x:F3},{current.y:F3},{current.z:F3},{current.w:F3}) aligned=({aligned.x:F3},{aligned.y:F3},{aligned.z:F3},{aligned.w:F3})\n");
            sb.Append($"  goal=({goal.x:F3},{goal.y:F3},{goal.z:F3},{goal.w:F3}) rem=({remainder.x:F3},{remainder.y:F3},{remainder.z:F3},{remainder.w:F3}) t={h.t} tx={h.tx}\n");
        }
        return sb.Length == 0 ? "no helper for " + leaf : sb.ToString();
    }

    /// The reference's local axis a rule reads. The game stores the parsed
    /// axis letter next to t/tx, and ROT is the one algorithm that uses it:
    /// `HIJI_L__rot_UDE_L__z50` — half of the elbow's turn about Z.
    private static Vector3 AxisVector(char axis) => axis switch
    {
        'y' => Vector3.up,
        'z' => Vector3.forward,
        _ => Vector3.right,
    };

    private static Quaternion Negate(Quaternion q) => new Quaternion(-q.x, -q.y, -q.z, -q.w);

    private Transform Resolve(string leaf, Transform context)
    {
        if (leaf == null || !byLeaf.TryGetValue(leaf, out var list)) return null;
        // Prefer a reference in the helper's own subtree (body vs. head chains
        // reuse names like KUBI).
        foreach (var candidate in list)
            if (candidate.IsChildOf(context.root)) return candidate;
        return list[0];
    }

    // MARK: name grammar

    private static bool TryRule(string name, out Kind kind, out string target, out float t, out float tx, out char axis)
    {
        kind = Kind.Rot; target = null; t = 0; tx = 0; axis = 'x';
        // `Awake` tests `Contains` in exactly this order, so a CONST bone whose
        // name also contains "rot" is still a constraint.
        if (name.Contains("slerp"))
        {
            target = TargetName(name);
            var values = Parameters(name);
            if (target == null || values.Count == 0) return false;
            kind = Kind.Slerp; t = values[0]; tx = values.Count > 1 ? values[1] : 0;
            return true;
        }
        if (name.Contains("twist"))
        {
            var value = TwistParameter(name);
            if (value == null) return false;
            kind = Kind.Twist; tx = value.Value;
            return true;
        }
        if (name.Contains("const"))
        {
            target = TargetName(name);
            if (target == null) return false;
            kind = Kind.Constrain;
            return true;
        }
        if (name.Contains("rot"))
        {
            target = TargetName(name);
            var values = Parameters(name);
            if (target == null || values.Count == 0) return false;
            kind = Kind.Rot; tx = values[0]; axis = ValueAxis(name);
            return true;
        }
        return false;
    }

    /// The reference bone's name: between the `_` after the algorithm and the
    /// next `__`. TWIST's one-separator names have no such span.
    private static string TargetName(string name)
    {
        var head = name.IndexOf("__", System.StringComparison.Ordinal);
        if (head < 0) return null;
        var start = name.IndexOf('_', head + 2);
        if (start < 0) return null;
        var end = name.IndexOf("__", start + 1, System.StringComparison.Ordinal);
        return end < 0 ? null : name.Substring(start + 1, end - start - 1);
    }

    /// `getParams`: the groups after the reference, e.g. `i30_x0` gives
    /// t = 0.30 then tx = 0.00, and `x100` gives tx = 1.00.
    private static List<float> Parameters(string name)
    {
        var values = new List<float>();
        var head = name.IndexOf("__", System.StringComparison.Ordinal);
        if (head < 0) return values;
        var separator = name.IndexOf("__", head + 2, System.StringComparison.Ordinal);
        if (separator < 0) return values;
        foreach (var group in name.Substring(separator + 2).Split('_'))
        {
            var value = Hundredths(group);
            if (value.HasValue) values.Add(value.Value);
        }
        return values;
    }

    /// TWIST puts its one parameter right after the algorithm name instead of
    /// after a second `__`: `KATA_MD_R__twist_x50`.
    private static float? TwistParameter(string name)
    {
        var head = name.IndexOf("__", System.StringComparison.Ordinal);
        if (head < 0) return null;
        var tail = name.Substring(head + 2);
        var cut = tail.IndexOf('_');
        return cut < 0 ? null : Hundredths(tail.Substring(cut + 1));
    }

    /// The axis letter belonging to the first parameter of a ROT name.
    private static char ValueAxis(string name)
    {
        var head = name.IndexOf("__", System.StringComparison.Ordinal);
        if (head < 0) return 'x';
        var separator = name.IndexOf("__", head + 2, System.StringComparison.Ordinal);
        if (separator < 0) return 'x';
        var first = name.Substring(separator + 2).Split('_')[0];
        return first.Length > 0 && "xyz".IndexOf(first[0]) >= 0 ? first[0] : 'x';
    }

    private static float? Hundredths(string group)
    {
        if (group.Length < 2) return null;
        if ("ixyz".IndexOf(group[0]) < 0) return null;
        return int.TryParse(group.Substring(1), out var value) ? value / 100f : (float?)null;
    }
}
