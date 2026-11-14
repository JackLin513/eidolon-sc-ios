// Native-faithful port of `Imas.BoneLib.SwayCollider` + `SwayColliderMT`
// (dump.cs TypeDefIndex 15308 / 15281) for the serial (non-job) path.
//
// ADR-0033 performance-layer substitutions used here:
//   * TransformAccess -> Transform (the collider is a MonoBehaviour in native
//     too; SwayColliderMT only wraps the transform for Burst);
//   * NativeArray<ColliderParams> -> SwayColliderParams (array);
//   * jobs -> direct calls.
// All formulas and constants are transcribed from IDA decompiles of the
// actual shipped binary. Addresses are noted on every method; things that could
// not be resolved from the decompiled binary are marked UNKNOWN(native ...).
//
// Native class/field map (dump.cs SwayCollider):
//   type 0x20, axis 0x24, planeAxis 0x28, clipPlane 0x2C, on 0x30,
//   n_radius 0x34, radius 0x38, distance 0x3C, offset 0x40,
//   CapsuleSphere1 0x4C, CapsuleSphere2 0x4D, useSkirtBarrier 0x4E,
//   bridgetgt 0x50, planeRotOn 0x58, planeRotEuler 0x5C, planeRotQ 0x68,
//   id 0x78, newpos 0x7C, pushOutV 0x88, BodyScale 0x98, boneRadius 0xA0,
//   skirtGuardOffset 0xA4, m_exec_ok 0xA8, m_scale 0xAC, m_w_center 0xB0,
//   m_culling_r 0xBC, m_w_dir 0xC0, trs 0xD0, mt 0xD8.
//
// Attach: SwayFileIO.AttachSwayCollider 0x1C76DD8 (fields copied from
// SwayColliderParams, Bridge->Capsule conversion when bridgetgt is a child).
// Per-frame geometry: SwayCollider.ExecUpdate 0x1C73FF0 /
// SwayColliderMT.ExecUpdate 0x1C6A9E0.
// Tests: SwayColliderMT.Check 0x1C73424 (dispatch), CapsuleHit 0x1C74500,
// CapsuleBridgeHit 0x1C74828, CheckPlane 0x1C748DC, CapsuleSideLineHit
// 0x1C74EC4, CapsuleSideLineBridgeHit 0x1C75124, CheckSideLine 0x1C75380,
// CalcBridge 0x1C742AC, CheckCulling 0x1C7565C.
// UMath primitives: adjust_length 0x1C8255C, hit_capsule_sphere 0x1C82678,
// hit_line_sphere 0x1C82904, hit_line_line 0x1C82AEC.

using UnityEngine;

/// <summary>
/// Runtime SwayCollider component. Native adds these with AddComponent on the
/// joint GameObject, one per `SwayCollider` stanza, in file order. The per-joint
/// ordinal used by `<joint>#k` is the index inside GetComponents&lt;SwayCollider&gt;()
/// on that joint (SwayFileIO.AttachSwayBone 0x1C7726C).
/// </summary>
// Native attaches several SwayCollider components to the same joint (the `#k`
// ordinal indexes them), so multiple components must be allowed here.
public sealed class SwayColliderNative : MonoBehaviour
{
    // ---- SwayColliderParams / runtime fields (native layout) ----
    public SwayColliderType type;                 // 0x20
    public SwayColliderAxis axis;                 // 0x24
    public SwayPlaneAxis planeAxis;               // 0x28
    public SwayClipPlane clipPlane;               // 0x2C
    public bool on = true;                        // 0x30
    public float n_radius;                        // 0x34  text `radius`
    public float radius;                          // 0x38  n_radius * m_scale
    public float distance;                        // 0x3C
    public Vector3 offset;                        // 0x40
    public bool CapsuleSphere1 = true;            // 0x4C
    public bool CapsuleSphere2 = true;            // 0x4D
    public bool useSkirtBarrier;                  // 0x4E
    public Transform bridgetgt;                   // 0x50
    public bool planeRotOn;                       // 0x58
    public Vector3 planeRotEuler;                 // 0x5C
    public Quaternion planeRotQ = Quaternion.identity; // 0x68
    public int id;                                // 0x78
    public Vector3 newpos;                        // 0x7C  result of the last Check
    public Vector3 pushOutV;                      // 0x88  result of CheckSideLine
    public Transform BodyScale;                   // 0x98
    public float boneRadius;                      // 0xA0  (unused by V01 tests we transcribed)
    public float skirtGuardOffset;                // 0xA4
    public bool m_exec_ok;                        // 0xA8
    public float m_scale = 1f;                    // 0xAC
    public Vector3 m_w_center;                    // 0xB0
    public float m_culling_r;                     // 0xBC
    public Vector3 m_w_dir;                       // 0xC0
    public Transform trs;                         // 0xD0

    /// <summary>
    /// SwayCollider.Awake 0x1C73E34: trs = transform; BodyScale = parent.Find("BodyScale").
    /// The spike prefab drops the BODY_SCALE node (see SwayRig.Resolve), so if it
    /// is absent we keep m_scale = 1 and record the data gap instead of inventing
    /// a scale: UNKNOWN(data) BODY_SCALE node missing in spike prefab.
    /// </summary>
    private void Awake()
    {
        trs = transform;
        BodyScale = null;
        var parent = transform.parent;
        if (parent != null)
        {
            BodyScale = parent.Find("BodyScale");
            if (BodyScale == null) BodyScale = parent.Find("BODY_SCALE");
        }
        m_scale = BodyScale != null ? BodyScale.localScale.x : 1f;
    }

    /// <summary>
    /// SwayFileIO.AttachSwayCollider 0x1C76DD8 + SwayCollider.Awake.
    /// Copies SwayColliderParams into this component. `top` is the merged rig
    /// root used to resolve `bridgetgt`. Bridge conversion rule from native:
    /// when type==Bridge and bridgetgt is a direct child of this transform, the
    /// component becomes a Capsule whose length is the distance to that child
    /// (native computes this at attach time).
    /// </summary>
    public void Attach(SwayColliderNativeParams p, Transform top, Transform bodyScale, float skirtGuard)
    {
        trs = transform;
        type = p.type;
        axis = p.axis;
        planeAxis = p.planeAxis;
        clipPlane = p.clipPlane;
        on = true;
        n_radius = p.n_radius;
        distance = p.distance;
        offset = p.offset;
        CapsuleSphere1 = p.CapsuleSphere1;
        CapsuleSphere2 = p.CapsuleSphere2;
        useSkirtBarrier = p.useSkirtBarrier;
        planeRotOn = p.planeRotOn;
        planeRotEuler = p.planeRotEuler;
        planeRotQ = Quaternion.Euler(planeRotEuler);
        id = p.id;
        skirtGuardOffset = skirtGuard;
        BodyScale = bodyScale;
        m_scale = BodyScale != null ? BodyScale.localScale.x : 1f;
        radius = n_radius * m_scale;

        if (!string.IsNullOrEmpty(p.bridgetgt))
        {
            bridgetgt = SwayRigNative.ResolveTransform(top, p.bridgetgt);
            // Native AttachSwayCollider 0x1C76DD8: if the resolved target is a
            // child of this collider's transform, replace Bridge with a fixed
            // Capsule between the two joints (type = 1, axis = X,
            // distance = |child - self| / m_scale, offset = (-distance/2,0,0)).
            if (bridgetgt != null && bridgetgt.parent == transform)
            {
                type = SwayColliderType.Capsule;
                axis = SwayColliderAxis.X;
                var childPos = bridgetgt.position;
                var ownPos = transform.position;
                var len = Vector3.Distance(childPos, ownPos) / Mathf.Max(m_scale, 1e-6f);
                distance = len;
                offset = new Vector3(len * -0.5f, 0f, 0f);
            }
        }
    }

    /// <summary>SwayCollider.SetScale 0x1C716D4 (native also called by SwayManager/AdjustScaleLine).</summary>
    public void SetScale()
    {
        if (BodyScale != null) m_scale = BodyScale.localScale.x;
        radius = n_radius * m_scale;
    }

    /// <summary>SwayCollider.UpdateInternalScale 0x1C73F28.</summary>
    public void UpdateInternalScale()
    {
        if (BodyScale != null && BodyScale.gameObject.activeInHierarchy)
            m_scale = BodyScale.localScale.x;
        radius = n_radius * m_scale;
    }

    /// <summary>
    /// SwayCollider.ExecUpdate 0x1C73FF0 / SwayColliderMT.ExecUpdate 0x1C6A9E0:
    /// refresh world-space geometry once per frame.
    /// Native field notes:
    ///  - Sphere: m_w_center only;
    ///  - Capsule: m_w_center, m_culling_r = radius + distance*0.5, m_w_dir from axis;
    ///  - Bridge: CalcBridge (0x1C742AC) builds an oriented capsule toward bridgetgt;
    ///  - Plane: nothing but m_scale (CheckPlane uses trs directly).
    /// The native m_exec_ok flag is reset by SwayCollider.Update (0x1C73FE8,
    /// confirmed: it is exactly `m_exec_ok = false`); SwayManagerNative resets it
    /// once per Unity frame before the fixed-step gate.
    /// </summary>
    public void ExecUpdate()
    {
        if (m_exec_ok) return;

        // Native ExecUpdate refreshes m_scale and leaves radius at its last
        // SetScale value (SetScale is called by InitSub/AdjustScaleLine). The
        // character scale is static here, so refreshing both per frame is
        // equivalent; the report notes this as a minor deviation.
        SetScale();
        switch (type)
        {
            case SwayColliderType.Sphere:
            {
                m_w_center = SwayNativeMath.TransformPoint(
                    transform.position, transform.rotation, BodyScaleScaleVector(), offset);
                break;
            }
            case SwayColliderType.Capsule:
            {
                m_w_center = SwayNativeMath.TransformPoint(
                    transform.position, transform.rotation, BodyScaleScaleVector(), offset);
                m_culling_r = radius + distance * 0.5f;
                m_w_dir = transform.TransformDirection(AxisVector(axis));
                break;
            }
            case SwayColliderType.Bridge:
            {
                CalcBridge();
                break;
            }
            case SwayColliderType.Plane:
            {
                // CheckPlane transforms the tip into this collider's local space;
                // no cached world geometry is needed.
                break;
            }
        }
        m_exec_ok = true;
    }

    private Vector3 BodyScaleScaleVector()
    {
        return BodyScale != null ? BodyScale.localScale : Vector3.one;
    }

    private static Vector3 AxisVector(SwayColliderAxis a)
    {
        switch (a)
        {
            case SwayColliderAxis.Y: return Vector3.up;
            case SwayColliderAxis.Z: return Vector3.forward;
            default: return Vector3.right;
        }
    }

    /// <summary>
    /// SwayCollider.CalcBridge 0x1C742AC:
    ///   d = |bridgetgt.position - trs.position| / m_scale
    ///   distance = d; offset = (d*0.5, 0, 0);
    ///   m_w_dir = normalize(bridgetgt.position - trs.position);
    ///   m_w_center = midpoint.
    /// If bridgetgt is inactive/missing native returns early (keeps old geometry);
    /// we do the same.
    /// </summary>
    public void CalcBridge()
    {
        if (bridgetgt == null || !bridgetgt.gameObject.activeInHierarchy) return;
        var target = bridgetgt.position;
        var own = transform.position;
        var delta = target - own;
        var len = delta.magnitude;
        distance = len / Mathf.Max(m_scale, 1e-6f);
        offset = new Vector3(distance * 0.5f, 0f, 0f);
        m_w_dir = SwayNativeMath.NormalizeOrZero(delta);
        m_w_center = (own + target) * 0.5f;
        m_culling_r = radius + distance * 0.5f;
    }

    /// <summary>
    /// SwayCollider.Check 0x1C73424 dispatch + SwayColliderMT.Check 0x1C68E30.
    /// Runs ExecUpdate first (native Check calls sub_1C73FF0 at entry), then
    /// dispatches by type. On success `newpos` holds the pushed-out tip.
    /// </summary>
    public bool Check(SwayBoneNative bone, int index)
    {
        ExecUpdate();
        switch (type)
        {
            case SwayColliderType.Sphere:
                return SwayColliderMT.CheckSphere(bone, this, out newpos);
            case SwayColliderType.Capsule:
                return SwayColliderMT.CapsuleHit(bone, this, out newpos);
            case SwayColliderType.Plane:
                return SwayColliderMT.CheckPlane(bone, this, bone.curTipPos, out newpos);
            case SwayColliderType.Bridge:
                return SwayColliderMT.CapsuleBridgeHit(bone, this, out newpos);
            default:
                return false;
        }
    }

    /// <summary>SwayCollider.CheckCulling 0x1C7565C: cheap radius reject.</summary>
    public bool CheckCulling(SwayBoneNative bone)
    {
        var delta = bone.curTipPos - m_w_center;
        var limit = bone.radius * 2f + m_culling_r;
        return delta.sqrMagnitude <= limit * limit;
    }

    public SwayColliderParams ToParams()
    {
        return new SwayColliderParams
        {
            type = type,
            m_w_center = m_w_center,
            n_radius = n_radius,
            radius = radius,
            distance = distance,
            m_scale = m_scale,
            offset = offset,
            m_culling_r = m_culling_r,
            transformIndex = -1,
            bridgetgtIndex = -1,
            axis = axis,
            m_w_dir = m_w_dir,
            planeRotQ = planeRotQ,
            planeRotOn = planeRotOn ? 1 : 0,
            planeAxis = planeAxis,
            clipPlane = clipPlane,
            useSkirtBarrier = useSkirtBarrier ? 1 : 0,
            skirtGuardOffset = skirtGuardOffset,
        };
    }
}

/// <summary>
/// Collider math extracted from SwayColliderMT (static, Burst-safe in native).
/// Kept static and pure so `SwayColliderParams` can also be exercised directly
/// by probes/tests (the serial manager still drives SwayColliderNative).
/// </summary>
public static class SwayColliderMT
{
    // ---- diagnostics (probe only) ----
    public static int diagBarrierTry, diagBarrierHit, diagCapsuleHit;
    public static float diagMaxPush, diagLastBarrierD, diagLastBarrierAlong;
    public static void DiagReset() { diagBarrierTry = diagBarrierHit = diagCapsuleHit = 0; diagMaxPush = 0f; }

    // ------------------------- UMath primitives -------------------------

    /// <summary>
    /// UMath.hit_capsule_sphere 0x1C82678. Capsule axis is `org ± dir*half`,
    /// sphere center is `sphereCenter` with `radius`. Returns the normal that
    /// pushes the sphere out and the penetration depth.
    /// </summary>
    public static bool HitCapsuleSphere(Vector3 lineOrg, Vector3 lineDir, Vector3 sphereCenter,
        float lineHalf, float radius, out Vector3 hitNv, out float depth)
    {
        hitNv = Vector3.zero;
        depth = 0f;
        var dir = SwayNativeMath.NormalizeOrZero(lineDir);
        var rel = sphereCenter - lineOrg;
        var t = Vector3.Dot(rel, dir);
        if (t < -lineHalf) t = -lineHalf;
        else if (t > lineHalf) t = lineHalf;
        var closest = lineOrg + dir * t;
        var delta = sphereCenter - closest;
        var distSq = delta.sqrMagnitude;
        if (distSq > radius * radius) return false;
        var dist = Mathf.Sqrt(distSq);
        if (dist > 0.00001f)
        {
            hitNv = delta / dist;
            depth = radius - dist;
        }
        else
        {
            // Degenerate: pick an axis perpendicular to the capsule direction.
            var fallback = Vector3.Cross(dir, Vector3.up);
            if (fallback.sqrMagnitude < 1e-8f) fallback = Vector3.Cross(dir, Vector3.right);
            hitNv = SwayNativeMath.NormalizeOrZero(fallback);
            depth = radius;
        }
        return depth > 0f;
    }

    /// <summary>
    /// UMath.hit_line_sphere 0x1C82904. Line segment `org ± dir*half` vs sphere.
    /// `hitNv` points from the sphere centre toward the closest point on the
    /// line (CheckSideLine 0x1C75380 negates the push: line is pushed away).
    /// </summary>
    public static bool HitLineSphere(Vector3 lineOrg, Vector3 lineDir, Vector3 sphereCenter,
        float lineHalf, float radius, out Vector3 hitNv, out float depth)
    {
        hitNv = Vector3.zero;
        depth = 0f;
        var dir = SwayNativeMath.NormalizeOrZero(lineDir);
        var rel = sphereCenter - lineOrg;
        var t = Vector3.Dot(rel, dir);
        if (t < -lineHalf) t = -lineHalf;
        else if (t > lineHalf) t = lineHalf;
        var closest = lineOrg + dir * t;
        var delta = closest - sphereCenter;
        var distSq = delta.sqrMagnitude;
        if (distSq > radius * radius) return false;
        var dist = Mathf.Sqrt(distSq);
        if (dist > 0.00001f) hitNv = delta / dist;
        depth = radius - dist;
        return depth > 0f;
    }

    /// <summary>
    /// UMath.hit_line_line 0x1C82AEC. Two segments (A = `orgA ± dirA*halfA`,
    /// B = `orgB ± dirB*halfB`) with radius; `hitNv` points from B to A.
    /// </summary>
    public static bool HitLineLine(Vector3 orgA, Vector3 dirA, Vector3 orgB, Vector3 dirB,
        float halfA, float halfB, float radius, out Vector3 hitNv, out float depth)
    {
        hitNv = Vector3.zero;
        depth = 0f;
        var da = SwayNativeMath.NormalizeOrZero(dirA);
        var db = SwayNativeMath.NormalizeOrZero(dirB);
        var r = orgA - orgB;
        var a = Vector3.Dot(da, da);
        var e = Vector3.Dot(db, db);
        var f = Vector3.Dot(db, r);
        float s, t;
        if (a <= 1e-8f && e <= 1e-8f)
        {
            s = t = 0f;
        }
        else if (a <= 1e-8f)
        {
            s = 0f;
            t = Mathf.Clamp(f / e, -halfB, halfB);
        }
        else
        {
            var c = Vector3.Dot(da, r);
            if (e <= 1e-8f)
            {
                t = 0f;
                s = Mathf.Clamp(-c / a, -halfA, halfA);
            }
            else
            {
                var b = Vector3.Dot(da, db);
                var denom = a * e - b * b;
                s = denom > 1e-8f ? Mathf.Clamp((b * f - c * e) / denom, -halfA, halfA) : 0f;
                t = (b * s + f) / e;
                if (t < -halfB) { t = -halfB; s = Mathf.Clamp((b * t - c) / a, -halfA, halfA); }
                else if (t > halfB) { t = halfB; s = Mathf.Clamp((b * t - c) / a, -halfA, halfA); }
            }
        }
        var pa = orgA + da * s;
        var pb = orgB + db * t;
        var delta = pa - pb;
        var distSq = delta.sqrMagnitude;
        if (distSq > radius * radius) return false;
        var dist = Mathf.Sqrt(distSq);
        if (dist > 0.00001f) hitNv = delta / dist;
        depth = radius - dist;
        return depth > 0f;
    }

    // ------------------------- point tests -------------------------

    /// <summary>SwayCollider.Check case 0 (0x1C73424): sphere vs tip point.</summary>
    public static bool CheckSphere(SwayBoneNative bone, SwayColliderNative col, out Vector3 newPos)
    {
        var radius = col.radius + bone.radius;
        var delta = bone.curTipPos - col.m_w_center;
        var distSq = delta.sqrMagnitude;
        if (distSq > radius * radius)
        {
            newPos = bone.curTipPos;
            return false;
        }
        var n = SwayNativeMath.NormalizeOrZero(delta);
        newPos = col.m_w_center + n * radius;
        return true;
    }

    /// <summary>
    /// SwayCollider.CapsuleHit 0x1C74500 / SwayColliderMT.CapsuleHit 0x1C6AF4C.
    /// First the skirt barrier (useSkirtBarrier &amp;&amp; bone.isSkirt), then
    /// capsule-vs-tip with radius = bone.radius and half length = distance*0.5*m_scale.
    /// </summary>
    public static bool CapsuleHit(SwayBoneNative bone, SwayColliderNative col, out Vector3 newPos)
    {
        newPos = bone.curTipPos;
        var center = col.m_w_center;
        var tip = bone.curTipPos;
        var radius = bone.radius;

        // Culling: (2*radius + m_culling_r)^2 before anything else (0x1C74500).
        var limit = radius * 2f + col.m_culling_r;
        if ((tip - center).sqrMagnitude > limit * limit) return false;

        var hit = false;

        // Skirt barrier (0x1C74500 lines after cull; research §3.3.2).
        if (col.useSkirtBarrier && bone.isSkirt)
        {
            diagBarrierTry++;
            var axis = col.m_w_dir;
            var along = Vector3.Dot(bone.skirtDir, axis);
            diagLastBarrierAlong = along;
            if (along > 0.1f)
            {
                var normal = bone.skirtNormal - axis * Vector3.Dot(bone.skirtNormal, axis);
                normal = SwayNativeMath.NormalizeOrZero(normal);
                var d = Vector3.Dot(normal, tip - center) - radius - col.radius * col.skirtGuardOffset;
                diagLastBarrierD = d;
                if (d < 0f)
                {
                    diagBarrierHit++;
                    tip -= normal * d;
                    newPos = tip;
                    hit = true;
                }
            }
        }

        var half = col.distance * 0.5f * col.m_scale;
        Vector3 nv;
        float depth;
        // Native 0x1C74500 line 146 passes `collider.radius + bone.radius` into
        // UMath.hit_capsule_sphere; `radius` above is the bone-only value used by
        // the culling test and the skirt barrier (native keeps them separate).
        if (HitCapsuleSphere(center, col.m_w_dir, tip, half, col.radius + bone.radius, out nv, out depth))
        {
            diagCapsuleHit++;
            if (depth > diagMaxPush) diagMaxPush = depth;
            newPos = tip + nv * depth;
            return true;
        }
        return hit;
    }

    /// <summary>SwayCollider.CapsuleBridgeHit 0x1C74828.</summary>
    public static bool CapsuleBridgeHit(SwayBoneNative bone, SwayColliderNative col, out Vector3 newPos)
    {
        var half = col.distance * 0.5f * col.m_scale;
        Vector3 nv;
        float depth;
        if (HitCapsuleSphere(col.m_w_center, col.m_w_dir, bone.curTipPos, half,
                col.radius + bone.radius, out nv, out depth))
        {
            newPos = bone.curTipPos + nv * depth;
            return true;
        }
        newPos = bone.curTipPos;
        return false;
    }

    /// <summary>
    /// SwayCollider.CheckPlane 0x1C748DC: transform tip into collider local space
    /// (minus offset, optionally into planeRotQ space), test the normal axis and
    /// clipPlane, then transform the pushed point back.
    /// </summary>
    public static bool CheckPlane(SwayBoneNative bone, SwayColliderNative col, Vector3 tipPos, out Vector3 newPos)
    {
        newPos = tipPos;
        var trs = col.trs != null ? col.trs : col.transform;
        Vector3 p;
        if (col.planeRotOn)
        {
            var inv = Quaternion.Inverse(col.planeRotQ);
            p = inv * (trs.InverseTransformPoint(tipPos) - col.offset);
        }
        else
        {
            p = trs.InverseTransformPoint(tipPos) - col.offset;
        }

        var r = bone.n_radius; // 0x1C748DC reads SwayBone+0x2C n_radius
        var plus = false;
        switch (col.planeAxis)
        {
            case SwayPlaneAxis.plusX:
                if (p.x <= -r) return false;
                plus = true;
                p.x = r;
                break;
            case SwayPlaneAxis.minusX:
                if (p.x >= r) return false;
                plus = false;
                p.x = -r;
                break;
            case SwayPlaneAxis.plusY:
                if (p.y <= -r) return false;
                plus = true;
                p.y = r;
                break;
            case SwayPlaneAxis.minusY:
                if (p.y >= r) return false;
                plus = false;
                p.y = -r;
                break;
            case SwayPlaneAxis.plusZ:
                if (p.z <= -r) return false;
                plus = true;
                p.z = r;
                break;
            case SwayPlaneAxis.minusZ:
                if (p.z >= r) return false;
                plus = false;
                p.z = -r;
                break;
            default:
                return false;
        }

        if (!ClipAllows(col.clipPlane, col.planeAxis, p, plus)) return false;

        Vector3 local = (col.planeRotOn ? col.planeRotQ * p : p) + col.offset;
        newPos = trs.TransformPoint(local);
        return true;
    }

    /// <summary>
    /// clipPlane gate from CheckPlane (0x1C748DC). The 2nd/3rd axes depend on
    /// which plane normal is used, exactly as the switch does in native.
    /// </summary>
    private static bool ClipAllows(SwayClipPlane clip, SwayPlaneAxis axis, Vector3 p, bool plusSide)
    {
        float a2, a3;
        switch (axis)
        {
            case SwayPlaneAxis.plusX:
            case SwayPlaneAxis.minusX:
                a2 = p.y; a3 = p.z; break;
            case SwayPlaneAxis.plusY:
            case SwayPlaneAxis.minusY:
                a2 = p.x; a3 = p.z; break;
            default:
                a2 = p.x; a3 = p.y; break;
        }
        switch (clip)
        {
            case SwayClipPlane.All: return true;
            case SwayClipPlane.Axis2ndPlus: return a2 >= 0f;
            case SwayClipPlane.Axis2ndMinus: return a2 < 0f;
            case SwayClipPlane.Axis3rdPlus: return a3 >= 0f;
            case SwayClipPlane.Axis3rdMinus: return a3 < 0f;
            default: return false;
        }
    }

    // ------------------------- side-line tests -------------------------

    /// <summary>
    /// SwayCollider.CheckSideLine 0x1C75380: line between this bone's tip and its
    /// sideLink tip vs the collider. Writes `pushOutV`; caller (SwayBone.SwayHit
    /// useLinkHit branch, UNKNOWN caller detail) adds it to the tip.
    /// </summary>
    public static bool CheckSideLine(SwayBoneNative bone, SwayColliderNative col)
    {
        col.ExecUpdate();
        switch (col.type)
        {
            case SwayColliderType.Sphere:
                return CheckSideLineSphere(bone, col);
            case SwayColliderType.Capsule:
                return CapsuleSideLineHit(bone, col);
            case SwayColliderType.Plane:
            {
                Vector3 pushed;
                if (CheckPlane(bone, col, bone.curTipPos, out pushed))
                {
                    col.pushOutV = pushed - bone.curTipPos;
                    return true;
                }
                return false;
            }
            case SwayColliderType.Bridge:
                return CapsuleSideLineBridgeHit(bone, col);
            default:
                return false;
        }
    }

    private static bool CheckSideLineSphere(SwayBoneNative bone, SwayColliderNative col)
    {
        var side = bone.sideLink;
        if (side == null) return false;
        var tipA = bone.curTipPos;
        var tipB = side.curTipPos;
        var mid = (tipA + tipB) * 0.5f;
        var dir = tipA - tipB;
        var half = dir.magnitude * 0.5f;
        var r = Mathf.Min(bone.radius, side.radius) * SwayConstants.SIDE_LINE_R
                + col.n_radius * col.m_scale;
        Vector3 nv;
        float depth;
        if (!HitLineSphere(mid, dir, col.m_w_center, half, r, out nv, out depth)) return false;
        col.pushOutV = nv * -depth;
        return true;
    }

    /// <summary>SwayCollider.CapsuleSideLineHit 0x1C74EC4.</summary>
    private static bool CapsuleSideLineHit(SwayBoneNative bone, SwayColliderNative col)
    {
        var side = bone.sideLink;
        if (side == null) return false;
        var tipA = bone.curTipPos;
        var tipB = side.curTipPos;
        var mid = (tipA + tipB) * 0.5f;
        var dir = tipA - tipB;
        var half = dir.magnitude * 0.5f;
        var r = Mathf.Min(bone.radius, side.radius) * SwayConstants.SIDE_LINE_R
                + col.n_radius * col.m_scale;
        Vector3 nv;
        float depth;
        if (!HitLineLine(mid, dir, col.m_w_center, col.m_w_dir,
                half, col.distance * 0.5f * col.m_scale, r, out nv, out depth)) return false;
        col.pushOutV = nv * depth;
        return true;
    }

    /// <summary>SwayCollider.CapsuleSideLineBridgeHit 0x1C75124.</summary>
    private static bool CapsuleSideLineBridgeHit(SwayBoneNative bone, SwayColliderNative col)
    {
        return CapsuleSideLineHit(bone, col);
    }

    private static Vector3 AxisVector(SwayColliderAxis a)
    {
        switch (a)
        {
            case SwayColliderAxis.Y: return Vector3.up;
            case SwayColliderAxis.Z: return Vector3.forward;
            default: return Vector3.right;
        }
    }

    /// <summary>SwayColliderMT.ExecUpdate 0x1C6A9E0 for the struct path.</summary>
    public static void ExecUpdate(ref SwayColliderParams cp, Transform trs, Transform bridgetgt, Vector3 bodyScale)
    {
        switch (cp.type)
        {
            case SwayColliderType.Sphere:
                cp.m_w_center = SwayNativeMath.TransformPoint(trs.position, trs.rotation, bodyScale, cp.offset);
                break;
            case SwayColliderType.Capsule:
                cp.m_w_center = SwayNativeMath.TransformPoint(trs.position, trs.rotation, bodyScale, cp.offset);
                cp.m_culling_r = cp.radius + cp.distance * 0.5f;
                cp.m_w_dir = trs.TransformDirection(AxisVector(cp.axis));
                break;
            case SwayColliderType.Bridge:
                if (bridgetgt != null && bridgetgt.gameObject.activeInHierarchy)
                {
                    var own = trs.position;
                    var target = bridgetgt.position;
                    var delta = target - own;
                    cp.distance = delta.magnitude / Mathf.Max(cp.m_scale, 1e-6f);
                    cp.offset = new Vector3(cp.distance * 0.5f, 0f, 0f);
                    cp.m_w_dir = SwayNativeMath.NormalizeOrZero(delta);
                    cp.m_w_center = (own + target) * 0.5f;
                    cp.m_culling_r = cp.radius + cp.distance * 0.5f;
                }
                break;
        }
    }
}
