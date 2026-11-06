using System.Collections.Generic;
using UnityEngine;

/// The game's `Imas.BoneLib.SwayBoneMT` V01 solver, run over the bones listed
/// in a `<character>_sway` file.
///
/// The state is the **tip position**, not a direction. Each frame the tip rides
/// along with its base (`MoveTipPos`, scaled by `followForce`), then a spring
/// pulls it towards the rigid rest tip at `stiffnessForce`, `(tip − previous)`
/// damps it by `(1 − dragForce)` and gravity pulls it down — all in the game's
/// 1/60 s units, so `dt` enters as `frames = dt·60` and every force is divided
/// by `frames²` (`SwayMove`, 0x1C6867C).
///
/// Collisions (`SwayHit`, 0x1C68C3C) push the tip out of the spheres and
/// capsules the bone lists, keeping the deepest push; a bone that was hit
/// skips gravity next frame. The angle window (`CalcRotate`, 0x1C69F04) then
/// clamps the direction to `minYAngle…maxYAngle` (sideways) and
/// `minZAngle…maxZAngle` (lift/droop inside the bone's own radial plane).
///
/// Hair, ribbons and the chest bones are driven this way; the skirt panels are
/// left to `SwaySolver.Drape` for now (`skipSkirt`).
[DefaultExecutionOrder(-45)]
public sealed class SwayPhysics : MonoBehaviour
{
    public const float FramesPerSecond = 60f;
    public const float MaxStep = 0.05f;

    public SwayRig rig;
    public bool skipSkirt = true;
    /// World axis the angle window and gravity are measured against.
    public Vector3 up = Vector3.up;

    private readonly Dictionary<SwayRig.Bone, Quaternion> restLocal = new Dictionary<SwayRig.Bone, Quaternion>();
    private readonly Dictionary<SwayRig.Bone, Vector3> restTipDirection = new Dictionary<SwayRig.Bone, Vector3>();
    private readonly Dictionary<SwayRig.Bone, float> length = new Dictionary<SwayRig.Bone, float>();
    private readonly Dictionary<SwayRig.Bone, Vector3> tips = new Dictionary<SwayRig.Bone, Vector3>();
    private readonly Dictionary<SwayRig.Bone, Vector3> previousTips = new Dictionary<SwayRig.Bone, Vector3>();
    private readonly Dictionary<SwayRig.Bone, Vector3> lastBases = new Dictionary<SwayRig.Bone, Vector3>();
    private readonly Dictionary<SwayRig.Bone, bool> hitLastFrame = new Dictionary<SwayRig.Bone, bool>();

    private readonly List<SwayRig.Bone> driven = new List<SwayRig.Bone>();
    private float accumulator;

    public int Count => driven.Count;

    public void Bind(SwayRig source)
    {
        rig = source;
        driven.Clear();
        restLocal.Clear(); restTipDirection.Clear(); length.Clear();
        tips.Clear(); previousTips.Clear(); lastBases.Clear(); hitLastFrame.Clear();

        foreach (var bone in rig.bones)
        {
            if (skipSkirt && bone.data.isSkirt) continue;
            if (ComputeTip(bone, out var direction, out var boneLength))
            {
                restTipDirection[bone] = direction;
                length[bone] = boneLength;
            }
            else
            {
                continue;
            }
            restLocal[bone] = bone.restLocalRotation;
            driven.Add(bone);
        }
    }

    /// The vector from the bone's origin to its tip, in bone-local space, and
    /// its length. The game takes it from the bone's own radius and the child
    /// it hangs; here the first child is the tip.
    private static bool ComputeTip(SwayRig.Bone bone, out Vector3 direction, out float boneLength)
    {
        direction = Vector3.down;
        boneLength = 0f;
        if (bone.transform.childCount > 0)
        {
            var local = bone.transform.GetChild(0).localPosition;
            boneLength = local.magnitude;
            if (boneLength > 1e-5f)
            {
                direction = local / boneLength;
                return true;
            }
        }
        // A leaf with no child of its own still swings by its radius.
        boneLength = Mathf.Max(bone.data.radius * 2f, 0.01f);
        return true;
    }

    private void LateUpdate()
    {
        if (rig == null) return;
        accumulator += Mathf.Min(Time.deltaTime, MaxStep);
        var step = 1f / FramesPerSecond;
        var guard = 0;
        while (accumulator >= step && guard++ < 4)
        {
            Step(step);
            accumulator -= step;
        }
    }

    private void Step(float dt)
    {
        var frames = dt * FramesPerSecond;
        var square = Mathf.Max(frames * frames, 1e-6f);

        foreach (var bone in driven)
        {
            var transform = bone.transform;
            var parent = transform.parent;
            var basePosition = transform.position;
            var parentRotation = parent != null ? parent.rotation : Quaternion.identity;
            var rigid = parentRotation * restLocal[bone];
            var restOffset = rigid * restTipDirection[bone] * length[bone];
            var aim = basePosition + restOffset;

            if (!tips.ContainsKey(bone))
            {
                tips[bone] = aim;
                previousTips[bone] = aim;
                lastBases[bone] = basePosition;
                hitLastFrame[bone] = false;
                continue;
            }

            var tip = tips[bone];
            var previous = previousTips[bone];
            var follow = bone.data.followForce;
            var travel = (basePosition - lastBases[bone]) * follow;
            tip += travel;
            previous += travel;

            var velocity = tip - previous;
            var force = (aim - tip) * bone.data.stiffnessForce
                        + velocity * (1f - bone.data.dragForce) / square;
            if (!hitLastFrame[bone]) force -= up * Mathf.Abs(bone.data.gravity.y);

            var oldTip = tip;
            tip += force * square;
            previous = oldTip;
            lastBases[bone] = basePosition;

            var offset = tip - basePosition;
            var direction = offset.sqrMagnitude > 1e-10f ? offset.normalized : restOffset.normalized;

            var hit = false;
            Resolve(bone, basePosition, ref direction, ref hit);
            hitLastFrame[bone] = hit;

            tip = basePosition + direction * length[bone];
            tips[bone] = tip;
            previousTips[bone] = previous;

            var clamped = Clamp(bone, basePosition, tip, rigid, restOffset.normalized);
            var turned = Quaternion.FromToRotation(restOffset.normalized, clamped) * rigid;
            transform.rotation = turned;
        }
    }

    /// `SwayHit`: push the free tip out of every listed collider, keeping the
    /// deepest violation, then rebuild the direction from the pushed tip.
    private void Resolve(SwayRig.Bone bone, Vector3 basePosition, ref Vector3 direction, ref bool hit)
    {
        if (bone.colliders.Count == 0) return;
        var point = basePosition + direction * length[bone];
        var normal = Vector3.zero;
        var depth = 0f;

        foreach (var collider in bone.colliders)
        {
            var violation = Violation(point, collider, bone.data.radius);
            if (violation.depth <= depth) continue;
            normal = violation.normal;
            depth = violation.depth;
        }
        if (depth <= 0f) return;

        var delta = point + normal * depth - basePosition;
        hit = true;
        if (delta.sqrMagnitude > 1e-12f) direction = delta.normalized;
    }

    private static (Vector3 normal, float depth) Violation(Vector3 point, SwayRig.Collider collider, float boneRadius)
    {
        var data = collider.data;
        var joint = collider.joint;
        var centre = joint.TransformPoint(data.offset);
        var limit = data.radius + boneRadius;
        var closest = centre;
        if (data.type == "Capsule")
        {
            var axis = data.axis == "Y" ? joint.up : data.axis == "Z" ? joint.forward : joint.right;
            var half = data.distance * 0.5f;
            var along = Mathf.Clamp(Vector3.Dot(point - centre, axis), -half, half);
            closest = centre + axis * along;
        }
        var delta = point - closest;
        var distance = delta.magnitude;
        if (distance >= limit) return (Vector3.zero, 0f);
        var normal = distance > 1e-5f ? delta / distance : joint.right;
        return (normal, limit - distance);
    }

    /// `CalcRotate`: clamp the direction to the bone's yaw/pitch window,
    /// measured from its rest direction inside its own radial plane.
    private Vector3 Clamp(SwayRig.Bone bone, Vector3 basePosition, Vector3 tip, Quaternion rigid, Vector3 restDirection)
    {
        var offset = tip - basePosition;
        if (offset.sqrMagnitude < 1e-10f) return restDirection;
        var direction = offset.normalized;
        if (!bone.data.limitAngle) return direction;

        var rest = restDirection.normalized;
        var radial = rest - up * Vector3.Dot(rest, up);
        if (radial.magnitude < 1e-3f)
        {
            var side = rigid * Vector3.up;
            radial = side - up * Vector3.Dot(side, up);
        }
        if (radial.magnitude < 1e-4f) return direction;
        var outward = radial.normalized;
        var tangent = Vector3.Cross(up, outward);

        (float yaw, float pitch) Angles(Vector3 v)
        {
            var horizontal = new Vector2(Vector3.Dot(v, outward), Vector3.Dot(v, tangent));
            return (Mathf.Atan2(horizontal.y, horizontal.x) * Mathf.Rad2Deg,
                -Mathf.Atan2(Vector3.Dot(v, up), horizontal.magnitude) * Mathf.Rad2Deg);
        }

        var restAngles = Angles(rest);
        var candidate = Angles(direction);
        var yaw = Mathf.Repeat(candidate.yaw - restAngles.yaw + 180f, 360f) - 180f;
        var pitch = candidate.pitch - restAngles.pitch;
        var clampedYaw = Mathf.Clamp(yaw, bone.data.minYAngle, bone.data.maxYAngle);
        var clampedPitch = Mathf.Clamp(pitch, bone.data.minZAngle, bone.data.maxZAngle);
        var yawRadians = (restAngles.yaw + clampedYaw) * Mathf.Deg2Rad;
        var pitchRadians = (restAngles.pitch + clampedPitch) * Mathf.Deg2Rad;
        return (outward * (Mathf.Cos(pitchRadians) * Mathf.Cos(yawRadians))
                + tangent * (Mathf.Cos(pitchRadians) * Mathf.Sin(yawRadians))
                - up * Mathf.Sin(pitchRadians)).normalized;
    }

    /// Lets a caller seed the tips at the current pose (after a seek).
    public void Reset()
    {
        tips.Clear();
        previousTips.Clear();
        lastBases.Clear();
        hitLastFrame.Clear();
        accumulator = 0f;
    }
}
