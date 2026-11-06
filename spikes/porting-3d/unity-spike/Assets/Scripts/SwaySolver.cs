using System.Linq;
using UnityEngine;

/// Runs the game's sway/skirt solve on the instantiated character.
///
/// Structure follows the game: `SwayManager` steps at a fixed 1/60 s, and every
/// bone goes `SwayBoneMT.SwayMove` (spring + drag + follow + gravity, integrated
/// as a tip position) → `SwayHit` (push the tip out of the bound colliders) →
/// `CalcRotate` (turn the tip direction back into a bone rotation, clamped to
/// the bone's Y/Z angle window). All numbers come from the character's own
/// `_sway` file; nothing here is hand-tuned.
public sealed class SwaySolver : MonoBehaviour
{
    public const float FixedDelta = 0.016666668f;
    public const float MaxDelta = 0.025000002f;

    public SwayFile file;
    public SwayRig rig;

    public void Bind(SwayFile swayFile)
    {
        file = swayFile;
        rig = SwayRig.Build(swayFile, transform);
        Initialize();
        var hip = rig.bones.FirstOrDefault(x => x.transform.name == "KOSHI");
        if (hip != null) rig.BuildSkirtRing(hip.transform.position);
    }

    private void Initialize()
    {
        foreach (var bone in rig.bones)
        {
            bone.initialLocalRotation = bone.restLocalRotation;
            bone.aimVector = bone.restTipDirection;
            bone.minZAngle = bone.data.minZAngle;
            bone.maxZAngle = bone.data.maxZAngle;
            bone.lastBasePos = bone.transform.position;
            bone.curTipPos = RestTip(bone);
            bone.prevTipPos = bone.curTipPos;
        }
    }

    private static Vector3 RestTip(SwayRig.Bone bone)
    {
        var parentRotation = bone.transform.parent != null ? bone.transform.parent.rotation : Quaternion.identity;
        var restRotation = parentRotation * bone.initialLocalRotation;
        var direction = restRotation * bone.aimVector;

        // A skirt falls with gravity instead of staying rigid to the tilted
        // pelvis (the game's SkirtFallFollow); without this the panels swing
        // back with the hips and uncover the thighs.
        if (bone.data.isSkirt)
            direction = Vector3.Slerp(direction, Vector3.down, SkirtFall);

        return bone.transform.position + direction * bone.swayLength;
    }

    public const float SkirtFall = 1f;

    private void LateUpdate()
    {
        if (rig == null) return;
        Drape();
    }

    /// One deterministic step, for verification from the editor.
    public void StepOnce(float deltaTime)
    {
        if (rig == null) return;
        foreach (var bone in rig.bones) Move(bone, deltaTime);
        foreach (var bone in rig.bones) Hit(bone);
        foreach (var bone in rig.bones) Rotate(bone);
    }

    /// Pose-space drape: every frame starts from the bone's rest tip (what the
    /// parent pose puts it in) and pushes that panel out of the colliders the
    /// game binds to it. The push direction is the horizontal radial direction
    /// at the deepest contact, so a panel that a thigh has entered moves
    /// outwards around the leg instead of flipping through it.
    public void Drape()
    {
        if (rig == null) return;
        foreach (var bone in rig.bones)
        {
            bone.transform.localPosition = bone.restLocalPosition;
            var tip = RestTip(bone);
            for (var pass = 0; pass < 4; pass++)
            {
                var moved = false;
                var basePosition = bone.transform.position;
                var bodyCenter = bone.transform.parent != null ? bone.transform.parent.position : basePosition;
                foreach (var collider in bone.colliders)
                {
                    if (!DeepestContact(basePosition, tip, collider, bone, out var contact, out var depth)) continue;
                    if (depth <= 1e-4f) continue;
                    var radial = contact - bodyCenter;
                    radial.y = 0f;
                    if (radial.sqrMagnitude < 1e-8f) continue;
                    tip += radial.normalized * depth;
                    moved = true;
                }
                if (!moved) break;
            }
            bone.curTipPos = tip;
        }
        foreach (var bone in rig.bones) Rotate(bone);
    }

    /// Neighbouring panels must keep the distance they have at rest, otherwise
    /// the fabric tears open between two panels that were pushed apart.
    private void KeepSkirtRingTogether()
    {
        for (var pass = 0; pass < 2; pass++)
        {
            foreach (var (a, b, rest) in rig.skirtRing)
            {
                var delta = b.curTipPos - a.curTipPos;
                var distance = delta.magnitude;
                if (distance < 1e-5f) continue;
                var correction = (distance - rest) * 0.5f * delta / distance;
                a.curTipPos += correction;
                b.curTipPos -= correction;
            }
        }
    }

    /// The panels are pinned at the hip, so a rotation alone cannot move the
    /// fabric off a thigh that has entered it; shift the panel outwards by the
    /// remaining penetration as well (the game does this through its skirt
    /// barrier / resolve depth).
    private void Barrier()
    {
        foreach (var bone in rig.skirtBones)
        {
            var basePosition = bone.transform.position;
            var bodyCenter = bone.transform.parent != null ? bone.transform.parent.position : basePosition;
            var deepest = 0f;
            foreach (var collider in bone.colliders)
            {
                if (!DeepestContact(basePosition, bone.curTipPos, collider, bone, out var contact, out var depth)) continue;
                var radial = contact - bodyCenter;
                radial.y = 0f;
                if (radial.sqrMagnitude < 1e-8f) continue;
                if (depth > deepest) deepest = depth;
            }
            if (deepest <= 1e-4f) continue;
            var outward = basePosition - bodyCenter;
            outward.y = 0f;
            if (outward.sqrMagnitude < 1e-8f) continue;
            bone.transform.position = basePosition + outward.normalized * (deepest * bone.resolveDepthFactor);
        }
    }

    /// Deepest penetration of the bone's line against one collider, with the
    /// world point on the line where it happens.
    private bool DeepestContact(Vector3 basePosition, Vector3 tip, SwayRig.Collider collider, SwayRig.Bone bone,
        out Vector3 contact, out float depth)
    {
        contact = Vector3.zero;
        depth = 0f;
        var radius = collider.data.radius + bone.data.radius;

        switch (collider.data.type)
        {
            case "Capsule":
            {
                var axis = AxisOf(collider.joint, collider.data.axis);
                var center = collider.joint.TransformPoint(collider.data.offset);
                var half = axis * (collider.data.distance * 0.5f);
                var p0 = center - half;
                var p1 = center + half;

                const int samples = 8;
                for (var i = 1; i <= samples; i++)
                {
                    var point = Vector3.Lerp(basePosition, tip, i / (float)samples);
                    ClosestPoints(point, point, p0, p1, out _, out var onCapsule, out _);
                    var penetration = radius - Vector3.Distance(point, onCapsule);
                    if (penetration <= depth) continue;
                    depth = penetration;
                    contact = point;
                }
                return depth > 0f;
            }
            default:
            {
                var center = collider.joint.TransformPoint(collider.data.offset);
                var penetration = radius - Vector3.Distance(tip, center);
                if (penetration <= 0f) return false;
                depth = penetration;
                contact = tip;
                return true;
            }
        }
    }

    /// `SwayBoneMT.SwayMove`: the tip is integrated as a position so the result
    /// is frame-rate independent; the spring pulls it back to the bone's rest
    /// tip, drag keeps part of the previous frame's velocity, and the parent's
    /// movement is followed by `followForce`.
    private void Move(SwayRig.Bone bone, float deltaTime)
    {
        var transform = bone.transform;
        var basePosition = transform.position;
        var parentRotation = transform.parent != null ? transform.parent.rotation : Quaternion.identity;

        var follow = bone.data.followForce;
        var manager = bone.manager;
        if (manager != null && string.Equals(bone.data.refParam, "Manager", System.StringComparison.Ordinal))
            follow = manager.followForce;

        var baseDelta = basePosition - bone.lastBasePos;
        bone.lastBasePos = basePosition;

        var tip = bone.curTipPos + baseDelta * follow;
        var previous = bone.prevTipPos + baseDelta * follow;

        var restTip = basePosition + parentRotation * bone.initialLocalRotation * bone.aimVector * bone.swayLength;
        var velocity = (tip - previous) * (1f - bone.data.dragForce);
        var spring = (restTip - tip) * bone.data.stiffnessForce;

        var next = tip + velocity + spring + bone.data.gravity;

        if (bone.sideLink != null)
            next += (bone.sideLink.curTipPos - tip) * bone.data.sideSpringForce;

        bone.prevTipPos = tip;
        bone.curTipPos = next;
    }

    /// `SwayBoneMT.SwayHit` + `SwayColliderMT`: push the tip out of every
    /// collider bound to this bone.
    private void Hit(SwayRig.Bone bone)
    {
        foreach (var collider in bone.colliders)
        {
            switch (collider.data.type)
            {
                case "Capsule":
                    PushOutOfCapsule(bone, collider);
                    break;
                default:
                    PushOutOfSphere(bone, collider);
                    break;
            }
        }
    }

    private static Vector3 AxisOf(Transform joint, string axis)
    {
        switch (axis)
        {
            case "Y": return joint.up;
            case "Z": return joint.forward;
            default: return joint.right;
        }
    }

    private void PushOutOfSphere(SwayRig.Bone bone, SwayRig.Collider collider)
    {
        var center = collider.joint.TransformPoint(collider.data.offset);
        var minimum = collider.data.radius + bone.data.radius;
        var delta = bone.curTipPos - center;
        var distance = delta.magnitude;
        if (distance >= minimum || distance < 1e-6f) return;
        bone.curTipPos = center + delta / distance * minimum;
        bone.sphereHit = true;
    }

    /// The game tests the whole bone line (base → tip) against the capsule, not
    /// just the tip: the deepest penetration along that line moves the tip out
    /// by `resolveDepthFactor` of the depth. That is what keeps the skirt off
    /// the thighs.
    private void PushOutOfCapsule(SwayRig.Bone bone, SwayRig.Collider collider)
    {
        var axis = AxisOf(collider.joint, collider.data.axis);
        var center = collider.joint.TransformPoint(collider.data.offset);
        var half = axis * (collider.data.distance * 0.5f);
        var p0 = center - half;
        var p1 = center + half;

        var basePosition = bone.transform.position;
        var tip = bone.curTipPos;
        var radius = collider.data.radius + bone.data.radius;

        ClosestPoints(basePosition, tip, p0, p1, out var onBone, out var onCapsule, out var along);
        // The panel is pinned at the hip; a collider that only touches the very
        // base of the bone (the hip sphere) must not swing the whole panel out.
        if (along < 0.25f) return;
        var delta = onBone - onCapsule;
        var distance = delta.magnitude;
        if (distance >= radius) return;

        var direction = distance > 1e-6f
            ? delta / distance
            : Vector3.Cross(p1 - p0, basePosition - p0).normalized;
        if (direction.sqrMagnitude < 1e-8f) direction = Vector3.up;

        var depth = (radius - distance) * bone.resolveDepthFactor;
        bone.curTipPos = tip + direction * depth;
        bone.lineHit = true;
    }

    private static void ClosestPoints(Vector3 a0, Vector3 a1, Vector3 b0, Vector3 b1, out Vector3 onA, out Vector3 onB, out float along)
    {
        var da = a1 - a0;
        var db = b1 - b0;
        var r = a0 - b0;
        var a = Vector3.Dot(da, da);
        var e = Vector3.Dot(db, db);
        var f = Vector3.Dot(db, r);
        float s, t;

        if (a <= 1e-8f && e <= 1e-8f)
        {
            onA = a0;
            onB = b0;
            along = 0f;
            return;
        }
        if (a <= 1e-8f)
        {
            s = 0f;
            t = Mathf.Clamp01(f / e);
        }
        else
        {
            var c = Vector3.Dot(da, r);
            if (e <= 1e-8f)
            {
                t = 0f;
                s = Mathf.Clamp01(-c / a);
            }
            else
            {
                var b = Vector3.Dot(da, db);
                var denom = a * e - b * b;
                s = denom > 1e-8f ? Mathf.Clamp01((b * f - c * e) / denom) : 0f;
                t = (b * s + f) / e;
                if (t < 0f) { t = 0f; s = Mathf.Clamp01(-c / a); }
                else if (t > 1f) { t = 1f; s = Mathf.Clamp01((b - c) / a); }
            }
        }
        onA = a0 + da * s;
        onB = b0 + db * t;
        along = s;
    }

    /// `SwayBoneMT.CalcRotate`: the tip direction, taken back into the bone's
    /// rest frame, becomes a yaw (clamped by min/max Y) and a pitch (clamped by
    /// min/max Z); the bone's rotation is the rest rotation times that Euler.
    private void Rotate(SwayRig.Bone bone)
    {
        var transform = bone.transform;
        var basePosition = transform.position;
        var parentRotation = transform.parent != null ? transform.parent.rotation : Quaternion.identity;

        var inParent = Quaternion.Inverse(parentRotation) * (bone.curTipPos - basePosition);
        var inRest = Quaternion.Inverse(bone.initialLocalRotation) * inParent;
        if (inRest.sqrMagnitude < 1e-8f) return;

        var yaw = Mathf.Atan2(inRest.z, -inRest.x) * Mathf.Rad2Deg;
        var pitch = -Mathf.Atan2(inRest.y, Mathf.Sqrt(inRest.x * inRest.x + inRest.z * inRest.z)) * Mathf.Rad2Deg;

        if (bone.data.limitAngle)
        {
            // The game's "Y angle" is the rotation about the bone's local Y
            // (a sideways swing) and "Z angle" about local Z (the forward/back
            // swing the panels are meant to travel through).
            yaw = Mathf.Clamp(yaw, bone.minZAngle, bone.maxZAngle);
            pitch = Mathf.Clamp(pitch, bone.data.minYAngle, bone.data.maxYAngle);
        }

        transform.localRotation = bone.initialLocalRotation * Quaternion.Euler(0f, yaw, pitch);
    }

    public string Describe()
    {
        if (rig == null) return "no rig";
        var text = new System.Text.StringBuilder();
        text.Append("bones=").Append(rig.bones.Count).Append(" skirt=").Append(rig.skirtBones.Count);
        foreach (var bone in rig.skirtBones)
        {
            var angle = Quaternion.Angle(bone.restLocalRotation, bone.transform.localRotation);
            text.Append(' ').Append(bone.transform.name).Append('=').Append(angle.ToString("F1"));
        }
        return text.ToString();
    }
}
