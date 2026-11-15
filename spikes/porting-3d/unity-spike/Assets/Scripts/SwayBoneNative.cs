using System.Text;
// Native-faithful port of `Imas.BoneLib.SwayBone` (dump.cs TypeDefIndex 15301)
// V01, serial execution path (the one SwayManager.ExecuteUpdate drives when
// SwayCtrlMT's Burst jobs are not used; jobs are a documented performance-layer
// replacement allowed by ADR-0033).
//
// Field layout follows dump.cs SwayBone one-for-one. Addresses in comments are
// IDA linear addresses (= Il2CppDumper RVA). The list below is the older shipped
// binary; the 2026-11-16 pass re-checked these bodies against the CURRENT binary
// (Δ = +0x5AC78, e.g. SetManager 0x1CCBBC8, Init(jbh) 0x1CCBA28, ResetRotForADV
// 0x1CCC9F8, InitWingLimit 0x1CCD2D8, SetWingLimitL 0x1CCD42C, SetWingLimitR
// 0x1CCD504, SwayHit 0x1CCDF60, FinishRotate 0x1CCCD58) and cites the current
// RVA on each rewritten method. The source of truth for every formula is the
// decompile of:
//   Awake 0x1C70C20, SetManager 0x1C70F50, Init 0x1C71198/0x1C70DB0,
//   InitSub 0x1C711A4, RefreshCollidersEnable 0x1C714CC,
//   CalcSideLinkDistance 0x1C716E8, SetAntiFoldAngle 0x1C718A8,
//   SetSkirtParam 0x1C716D0, AdjustSkirt 0x1C718C4,
//   ResetRot 0x1C71C84, FinishRotate 0x1C720E0, ResetTipPos 0x1C72640,
//   SwayMove 0x1C72964 (scalar; SwayBoneMT.SwayMove 0x1C6867C is the same math
//   over WorkingParams), SwayHit 0x1C732E8, CalcRotate 0x1C72220
//   (SwayBoneMT.CalcRotate 0x1C69F04), CalcSideLineDistance 0x1C736B8,
//   CalcAntiFoldForce 0x1C738A8.
//
// UNKNOWN markers call out where the shipped binary could not be pinned down in
// this pass; those must be re-checked with a runtime probe before being called
// native-equivalent.
//
// 2026-11-08 sway-fix pass (CalcRotate/SwayMove semantics against the fresh IDA
// rebuild, evidence in /tmp/ida-sway-helpers/h_*.c with pinned il2cpp method
// strings):
//   sub_70C13F4  = InverseTransformDirection_Injected (not set_position /
//                  InverseTransformPoint — resolved the Lead's open question)
//   0x1C72220 head: trs.localRotation = initialLocalRotation runs for BOTH
//                  branches; the limitAngle==0 (OPAI) else-branch therefore
//                  measures the direction in the bind frame every frame.
//   sub_70BEEAC = get_position, sub_70BE0A8 = get_localPosition,
//   sub_70BC63C = TransformPoint, sub_70BF458 = set_localRotation,
//   sub_7095878 = Quaternion.Euler (Internal_FromEulerRad),
//   sub_70953E8 = FromToRotation, sub_70954C0 = Quaternion.Inverse,
//   sub_70BC718 = get_rotation, sub_70BED4C = GetParent,
//   sub_70C3450/70C3578/70C37C0 = TransformAccess GetPosition/GetRotation/
//                  SetLocalRotation (MT path), sub_70C2A8C = Transform.GetChild.
//
// 2026-11-08 ribbon-fix pass (shoulderRibbon kink hunt, ss001; MT SwayMove
// 0x1C6867C + MT CalcRotate 0x1C69F04 + FP init 0x1C69508 + ExecuteUpdate
// 0x1C81CD8 line-by-line against the scalar path):
//   SwayBoneMT.FixedParams job-memory mapping (a3 = float32x4 lanes, 16 B):
//     a3[0]=swbIndex/sideLink/sideLink2/isSkirt, a3[1]=useLinkHit/
//     m_side_line_initial_dist/sideSpringTorelance/sideSpringForce,
//     a3[2]=parentRotation, a3[3]=SkirtFallFollow/side_tipPosition,
//     a3[4]=gravity/category(i32[3]), a3[5]=initialLocalRotation,
//     a3[6]=followForce/fallFollow/aimVector.xy, a3[7]=aimVector.z/
//     stiffnessForce/dragForce/radius, a3[9].f32[3]=minZAngleTgt,
//     a3[10].f32[0]=maxZAngleTgt, a3[12].i32[1]=isWing.
//   Job array mapping: a4(+88*swbIndex)=WorkingParams(memory layout 0x00..
//     lastBasePos 0x4C), a12/a15 = per-swb side-line/anti-line force arrays
//     (isSkirt: += own when sideLink>=0, -= sideLink2's), a17=swayDamper[],
//     a19=swayFollowRate[], a21=swayFollowSW[], a23=per-category vecs1
//     (a24 = its length gate), a25/a26 = tip TransformAccess (transBack pin),
//     a27 = swayTransBack.
//   Verified equal (no code change needed): wing transition (±4°, isWing gate
//     skip when workOnCharacterViewer), follow-rate chain (rate ->
//     followSW=1 -> SkirtFallFollow&&isSkirt -> fallFollow -> followForce,
//     transBack->0), baseDelta applied to BOTH curTip and prevTip, rot =
//     parent.rotation * initialLocalRotation (quaternion multiply, a9 = 1.0),
//     aim*(stiffness+antiFoldForceSum), drag term (1-drag)/ratioSq, gravity
//     gated on lineHitF only, ratio=(dt/0.016)^2 + integrate curTip +=
//     force*ratioSq with prevTip = old curTip, damper applied before both the
//     stored force and the integrate, skirtNormal/skirtDir = trs.rotation *
//     up/right, sideLink2 vecs1-side force subtraction, hitTwice second
//     SwayHit, CalcRotate reset-then-limitAngle (yaw=atan2(z,-x),
//     pitch=-atan2(y,hypot), WP minZ/maxZ), clamped write-back
//     (curTip=prevTip=TransformPoint(tipLocal+offset)), FinishRotate tail.
//   useBindDir (0x61): byte is NOT read by any sway pass in the shipped
//     binary (no a1+97/-0x61 reference in SwayMove/CalcRotate/SwayHit/
//     FinishRotate/InitSub; only float +97 = sideSpringForce at 0x184).
//     The static never participates in V01; port not reading it is native-
//     faithful.
//   Fixed: per-bone force accumulation order made native-faithful
//     (gravity -> vecs1[category] -> side-line forces) and skirtNormal/
//     skirtDir write moved before the integration (native LABEL_96 order);
//     both are FP-order/parallel-order parity fixes, not formula changes.

using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// One swinging bone. Native creates it as a MonoBehaviour on the sway bone
/// transform; the first child transform is the tail (`tipTrs`, SwayBone 0x20)
/// and the tail position is integrated in world space.
/// </summary>
[DisallowMultipleComponent]
public sealed class SwayBoneNative : MonoBehaviour
{
    // ---------------- serialized data (SwayBoneParams / text) ----------------
    public SwayBoneNativeParams data;

    // ---------------- SwayBone fields (dump.cs offsets) ----------------
    public Transform tipTrs;                 // 0x20
    public SwayHitType type;                 // 0x28
    public float n_radius;                   // 0x2C  text `radius`
    public float radius;                     // 0x30  n_radius * bodyScale
    public bool HitMuteForce;                // 0x34
    public float HitMuteRate;                // 0x38
    public bool isSkirt;                     // 0x3C
    public bool isWing;                      // 0x3D
    public bool workOnCharacterViewer;       // 0x3E
    public SwayCategory category;            // 0x40
    public string sideLinkPath;              // 0x48
    public SwayBoneNative sideLink;          // 0x50
    public SwayBoneNative sideLink2;         // 0x58
    public bool limitAngle;                  // 0x60
    public bool useBindDir;                  // 0x61
    public float minYAngle;                  // 0x64
    public float maxYAngle;                  // 0x68
    public float minZAngle;                  // 0x6C
    public float maxZAngle;                  // 0x70
    public float minZAngleTgt;               // 0x74
    public float maxZAngleTgt;               // 0x78
    public bool isWingLimitAngleChanged;     // 0x7C
    public SwayRefType refParam;             // 0x80
    public float stiffnessForce;             // 0x84
    public float stockStiffnessForce;        // 0x88
    public float dragForce;                  // 0x8C
    public Vector3 gravity;                  // 0x90
    public float followForce;                // 0x9C
    public SwayRecordParameter rec;          // 0xA0
    public SwayColliderSetNative[] colliders;    // 0xC8
    public bool[] colliders_enable;              // 0xD0
    public Quaternion initialLocalRotation;      // 0xD8
    public SwayManagerNative mgr;                // 0xE8
    public float swayLength;                     // 0xF0
    public Transform trs;                        // 0xF8
    public Vector3 curTipPos;                    // 0x100 world
    public Vector3 prevTipPos;                   // 0x10C world
    public Vector3 h;                            // 0x118 (reset each PrepareUpdate)
    public Vector3 cc;                           // 0x124 (reset each PrepareUpdate)
    public int colliderInx;                      // 0x130
    public Vector3 force;                        // 0x134
    public Vector3 tmpPos;                       // 0x140
    public bool lineHitF;                        // 0x14C
    public bool sphereHitF;                      // 0x14D
    public Vector3 aimVector;                    // 0x150 bone-local bind tip direction
    public Vector3 lastBasePos;                  // 0x15C world
    // Native also has `SwayBoneMT mt` at 0x168; the serial port builds the MT
    // record per pass (FixedParams/WorkingParams) and keeps no persistent object,
    // so only the jbh back-reference written by Init(JointBodyHead) is stored.
    public JointBodyHeadNative jbh;              // 0x170
    public Vector3 colliderOffset;               // 0x178
    public float sideSpringForce;                // 0x184
    public float sideSpringTorelance;            // 0x188
    public bool hitTwice;                        // 0x18C
    public bool useLinkHit;                      // 0x18D
    public float sideAntiSpringForce;            // 0x190
    public float sideAntiSpringTorelance;        // 0x194
    public float antiFoldForceK;                 // 0x198
    public float antiFoldAngle;                  // 0x19C
    public float m_side_line_initial_dist;       // 0x1A0
    public float m_side_line_dist;               // 0x1A4
    public Vector3 m_side_line_force;            // 0x1A8
    public float m_side_line_hit_depth;          // 0x1B4
    public Vector3 m_side_line_hit_nv;           // 0x1B8
    public float m_side_line_anti_dist;          // 0x1C4
    public Vector3 m_side_line_anti_force;       // 0x1C8
    public float antiFoldForceSum;               // 0x1D4
    public float antiFoldAngleRad;               // 0x1D8
    public Quaternion m_offset_rot;              // 0x1DC
    public Vector3 skirtNormal;                  // 0x1EC
    public Vector3 skirtDir;                     // 0x1F8
    public Transform BodyScale;                  // 0x208
    public float resolveDepthFactor = SwayConstants.DEFAULT_RESOLVE_DEPTH_FACTOR; // 0x210

    /// <summary>
    /// Optional bind-rotation source. Native InitSwayBones 0x1C75970 takes the
    /// rotation from JointBodyHead.GetInitRot 0x1C627AC; the spike can pass the
    /// same value here once JointBodyHead exists, otherwise the current local
    /// rotation at Build time is used (documented data gap).
    /// </summary>
    public Func<Transform, Quaternion> bindRotationProvider;

    /// <summary>Index in SwayManagerNative.swayBones (FixedParams.swbIndex).</summary>
    public int swbIndex = -1;
    /// <summary>Optional wind source, set by SwayManagerNative (native SwayManager.winds).</summary>
    public SwayManagerNative owner;

    private readonly List<SwayColliderNative> resolvedColliders = new List<SwayColliderNative>();

    // ---------------- MT struct bridge (SwayBoneMT.*) ----------------

    /// <summary>
    /// SwayBoneMT.InitializeFixedParams 0x1C69508. Kept as an explicit transform
    /// from the SwayBone fields so the struct layout can be validated against
    /// dump.cs without running the solver.
    /// </summary>
    public SwayFixedParams BuildFixedParams()
    {
        var fp = new SwayFixedParams();
        fp.swbIndex = swbIndex;
        fp.sideLink = sideLink != null ? sideLink.swbIndex : -1;
        fp.sideLink2 = sideLink2 != null ? sideLink2.swbIndex : -1;
        fp.isSkirt = isSkirt ? 1 : 0;
        fp.useLinkHit = useLinkHit ? 1 : 0;
        fp.m_side_line_initial_dist = m_side_line_initial_dist;
        fp.sideSpringTorelance = sideSpringTorelance;
        fp.sideSpringForce = sideSpringForce;
        fp.parentRotation = trs != null && trs.parent != null ? trs.parent.rotation : Quaternion.identity;
        fp.SkirtFallFollow = mgr != null && mgr.SkirtFallFollow ? 1 : 0;
        fp.side_tipPosition = sideLink != null && sideLink.trs != null && sideLink.tipTrs != null
            ? sideLink.tipTrs.position : Vector3.zero;
        fp.gravity = gravity;
        fp.category = category;
        fp.initialLocalRotation = initialLocalRotation;
        fp.followForce = followForce;
        fp.fallFollow = mgr != null ? mgr.FollowFall : 0f;
        fp.aimVector = aimVector;
        fp.stiffnessForce = stiffnessForce;
        fp.dragForce = dragForce;
        fp.radius = radius;
        fp.n_radius = n_radius;
        fp.m_offset_rot = m_offset_rot;
        fp.minYAngle = minYAngle;
        fp.maxYAngle = maxYAngle;
        fp.minZAngleTgt = minZAngleTgt;
        fp.maxZAngleTgt = maxZAngleTgt;
        fp.limitAngle = limitAngle ? 1 : 0;
        fp.colliderOffset = colliderOffset;
        fp.HitMuteForce = HitMuteForce ? 1 : 0;
        fp.HitMuteRate = HitMuteRate;
        fp.swayLength = swayLength;
        fp.hitTwice = hitTwice ? 1 : 0;
        fp.isWing = isWing ? 1 : 0;
        fp.hasSideLinkTipTrs = sideLink != null ? 1 : 0;
        fp.sideAntiSpringForce = sideAntiSpringForce;
        fp.sideAntiSpringTorelance = sideAntiSpringTorelance;
        fp.antiFoldForceK = antiFoldForceK;
        fp.antiFoldAngleRad = antiFoldAngleRad;
        fp.resolveDepthFactor = resolveDepthFactor;
        fp.bodyScale = BodyScale != null ? BodyScale.localScale : Vector3.one;
        return fp;
    }

    /// <summary>SwayBoneMT.WorkingParams snapshot from the SwayBone fields.</summary>
    public SwayWorkingParams BuildWorkingParams()
    {
        return new SwayWorkingParams
        {
            force = force,
            lineHitF = lineHitF ? 1 : 0,
            sphereHitF = sphereHitF ? 1 : 0,
            skirtNormal = skirtNormal,
            skirtDir = skirtDir,
            minZAngle = minZAngle,
            maxZAngle = maxZAngle,
            curTipPos = curTipPos,
            prevTipPos = prevTipPos,
            lastBasePos = lastBasePos,
        };
    }

    /// <summary>SwayBoneMT.CopyFromWorkingParams 0x1C69DE8.</summary>
    public void ApplyWorkingParams(SwayWorkingParams wp)
    {
        force = wp.force;
        lineHitF = wp.lineHitF != 0;
        sphereHitF = wp.sphereHitF != 0;
        skirtNormal = wp.skirtNormal;
        skirtDir = wp.skirtDir;
        minZAngle = wp.minZAngle;
        maxZAngle = wp.maxZAngle;
        curTipPos = wp.curTipPos;
        prevTipPos = wp.prevTipPos;
        lastBasePos = wp.lastBasePos;
    }

    // ---------------- lifecycle ----------------

    /// <summary>
    /// SwayBone.Awake 0x1CCB898 (old 0x1C70C20) + SwayFileIO.AttachSwayBone
    /// (old 0x1C7726C). Sets the transform/tip references and copies
    /// SwayBoneParams fields.
    /// Native Awake stores initialLocalRotation = trs.localRotation. The later
    /// SwayFileIO.InitSwayBones calls Init(JointBodyHead) 0x1CCBA28 (overload
    /// below), which binds the jbh back-reference and re-resolves the collider
    /// components — it does NOT touch the bind rotation. The bind rotation
    /// enters through the separate Init(Quaternion rot) 0x1CCBE10 overload,
    /// modelled by the 0-arg Init() via bindRotationProvider.
    /// </summary>
    public void Attach(SwayBoneNativeParams p, SwayManagerNative manager, Transform bodyScale, int index)
    {
        data = p;
        trs = transform;
        tipTrs = transform.childCount > 0 ? transform.GetChild(0) : null;
        swbIndex = index;

        type = p.type;
        n_radius = p.n_radius;
        HitMuteForce = p.HitMuteForce;
        HitMuteRate = p.HitMuteRate;
        isSkirt = p.isSkirt;
        limitAngle = p.limitAngle;
        useBindDir = p.useBindDir;
        minYAngle = p.minYAngle;
        maxYAngle = p.maxYAngle;
        minZAngle = p.minZAngle;
        maxZAngle = p.maxZAngle;
        // SwayBone.Awake writes minZAngleTgt/maxZAngleTgt = minZAngle/maxZAngle
        // (0x74 <- 0x6C, 0x78 <- 0x70).
        minZAngleTgt = p.minZAngle;
        maxZAngleTgt = p.maxZAngle;
        followForce = p.followForce;
        refParam = p.refParam;
        stiffnessForce = p.stiffnessForce;
        stockStiffnessForce = p.stiffnessForce;
        dragForce = p.dragForce;
        gravity = p.gravity;
        hitTwice = p.hitTwice;
        useLinkHit = p.useLinkHit;
        colliderOffset = p.colliderOffset;
        sideSpringTorelance = p.sideSpringTorelance;
        sideSpringForce = p.sideSpringForce;
        sideAntiSpringTorelance = p.sideAntiSpringTorelance;
        sideAntiSpringForce = p.sideAntiSpringForce;
        antiFoldForceK = p.antiFoldForceK;
        antiFoldAngle = p.antiFoldAngle;
        antiFoldAngleRad = p.antiFoldAngle * Mathf.Deg2Rad;
        sideLinkPath = p.sideLink;

        BodyScale = bodyScale;
        mgr = manager;
        category = manager != null ? manager.Category : SwayCategory.Normal;
        initialLocalRotation = trs.localRotation;

        // SwayFileIO.AttachSwayBone assigns SwayColliderSet.path/n; the collider
        // components are resolved by SwayManagerNative.Build after every file
        // was attached (body + head merged).
        colliders = p.colliders.Count > 0 ? new SwayColliderSetNative[p.colliders.Count] : null;
        if (colliders != null)
            for (var i = 0; i < p.colliders.Count; i++)
                colliders[i] = new SwayColliderSetNative
                {
                    path = p.colliders[i].path,
                    n = p.colliders[i].n,
                    raw = p.colliders[i].raw,
                };
        colliders_enable = colliders != null ? new bool[colliders.Length] : null;
    }

    /// <summary>
    /// SwayBone.SetManager 0x1CCBBC8 (old 0x1C70F50): manager + category, then
    /// three GameObject.CompareTag groups:
    ///   * OPAI_L0 / OPAI_R0                         -> category Opai (3);
    ///   * hair_side, or hair_yoko without A/C tags  -> category SideHair (4)
    ///     (native additionally requires the global VisualManager3d static
    ///     field[0] to be null; the spike has no VisualManager3d, so that holds);
    ///   * wing_L0 / wing_R0                         -> isWing (0x3D) = true.
    /// The tagged literals were resolved from the current binary: OPAI_L0
    /// 0x98AF150, OPAI_R0 0x98AF158, hair_side 0x98CCFE0, hair_yoko 0x98CCFE8,
    /// A 0x98995A8, C 0x989C660, wing_L0 0x98E2DB0, wing_R0 0x98E2DB8.
    /// Native does not write useBindDir here; that text field is only carried.
    /// </summary>
    public void SetManager(SwayManagerNative manager, SwayCategory cat)
    {
        mgr = manager;
        category = cat;
        var go = gameObject;
        if (CompareTagSafe(go, "OPAI_L0") || CompareTagSafe(go, "OPAI_R0"))
        {
            category = SwayCategory.Opai;
        }
        else if (CompareTagSafe(go, "hair_side")
                 || (CompareTagSafe(go, "hair_yoko")
                     && !CompareTagSafe(go, "A")
                     && !CompareTagSafe(go, "C")))
        {
            category = SwayCategory.SideHair;
        }
        if (CompareTagSafe(go, "wing_L0") || CompareTagSafe(go, "wing_R0"))
            isWing = true;
    }

    /// <summary>
    /// GameObject.CompareTag with the native semantics but tolerant of absent
    /// TagManager entries: Unity throws for a tag that is not declared in the
    /// project, while the shipped project declares every costume tag. The spike
    /// has no TagManager entries for OPAI_L0/wing_L0/..., so an undeclared tag
    /// is treated as "not equal" (the native value would also be false there).
    /// </summary>
    private static bool CompareTagSafe(GameObject go, string tag)
    {
        if (go == null) return false;
        try
        {
            return go.CompareTag(tag);
        }
        catch (UnityException)
        {
            return false;
        }
    }

    /// <summary>
    /// SwayBone.Init(Quaternion rot) 0x1CCBE10 (old 0x1C71198): stores the bind
    /// local rotation and runs InitSub. The spike sources `rot` from
    /// bindRotationProvider (the value JointBodyHead.GetInitRot hands the native
    /// caller); a null provider falls back to the local rotation at Bind() time.
    /// </summary>
    public void Init()
    {
        if (trs == null) trs = transform;
        if (tipTrs == null && transform.childCount > 0) tipTrs = transform.GetChild(0);
        initialLocalRotation = bindRotationProvider != null
            ? bindRotationProvider(transform)
            : trs.localRotation;
        InitSub();
    }

    /// <summary>
    /// SwayBone.Init(JointBodyHead jbh0) 0x1CCBA28 (old 0x1C70DB0): stores the
    /// jbh back-reference (native also writes SwayBoneMT.jbh at 0x168+0x18; the
    /// serial port has no persistent MT record), then for every collider set
    /// re-resolves the component from its own GameObject:
    /// `set.c = set.c.gameObject.GetComponents&lt;SwayCollider&gt;()[set.n]`.
    /// Finally RefreshCollidersEnable() then InitSub(). SwayFileIO.InitSwayBones
    /// calls this overload; the 0-arg Init() above models the bind-rotation
    /// overload (0x1CCBE10).
    /// </summary>
    public void Init(JointBodyHeadNative jbh0)
    {
        if (jbh0 != null) jbh = jbh0;
        if (colliders != null)
        {
            for (var i = 0; i < colliders.Length; i++)
            {
                var set = colliders[i];
                if (set == null || set.c == null) continue;
                var components = set.c.gameObject.GetComponents<SwayColliderNative>();
                if (set.n >= 0 && set.n < components.Length) set.c = components[set.n];
            }
        }
        RefreshCollidersEnable();
        InitSub();
    }

    /// <summary>SwayBone.InitSub 0x1C711A4.</summary>
    private void InitSub()
    {
        if (trs == null || tipTrs == null) return;

        lastBasePos = trs.position;
        m_side_line_initial_dist = 0f;
        m_side_line_dist = 0f;

        // curTipPos = trs.TransformPoint(tipTrs.localPosition + colliderOffset)
        var tipLocal = tipTrs.localPosition + colliderOffset;
        curTipPos = trs.TransformPoint(tipLocal);
        prevTipPos = curTipPos;
        lastBasePos = trs.position;

        // aimVector = normalize(tipLocal); if degenerate -> zero (0x1C711A4).
        var len = tipLocal.magnitude;
        if (len > 0.00001f)
            aimVector = tipLocal / len;
        else
            aimVector = Vector3.zero;
        swayLength = len * BodyScaleScale();

        // m_offset_rot = FromToRotation(aimVector, -Vector3.right)
        m_offset_rot = Quaternion.FromToRotation(aimVector, -Vector3.right);

        radius = n_radius * BodyScaleScale();

        // Reset the MT parallel state; in the serial port this only means the
        // working record is re-seeded from the freshly computed tip.
        h = Vector3.zero;
        cc = Vector3.zero;
        colliderInx = -1;

        if (colliders != null)
            for (var i = 0; i < colliders.Length; i++)
            {
                var set = colliders[i];
                if (set == null || set.c == null) continue;
                set.c.SetScale();
            }
        RefreshCollidersEnable();
    }

    private float BodyScaleScale()
    {
        return BodyScale != null ? BodyScale.localScale.x : 1f;
    }

    /// <summary>
    /// SwayBone.RefreshCollidersEnable 0x1C714CC: bool[] with true only for
    /// colliders that exist and are not null.
    /// </summary>
    public void RefreshCollidersEnable()
    {
        if (colliders == null)
        {
            colliders_enable = null;
            return;
        }
        if (colliders_enable == null || colliders_enable.Length != colliders.Length)
            colliders_enable = new bool[colliders.Length];
        for (var i = 0; i < colliders.Length; i++)
        {
            colliders_enable[i] = false;
            var set = colliders[i];
            if (set == null || set.c == null) continue;
            colliders_enable[i] = true;
        }
    }

    /// <summary>
    /// SwayBone.CalcSideLinkDistance 0x1C716E8 (bind-time snapshot of the rest
    /// distance between the two tips). Native stores 0.1f first, then overwrites
    /// it with |sideLink.tail.position - own.tail.position| and refreshes
    /// antiFoldAngleRad. The per-frame distance/force is CalcSideLineDistance
    /// 0x1C736B8 below.
    /// </summary>
    public void CalcSideLinkDistance()
    {
        // Native 0x1C716E8 stores 0.1f (0x3DCCCCCD) first, then overwrites with
        // the distance between this bone's tail and sideLink's tail.
        m_side_line_initial_dist = 0.1f;
        m_side_line_dist = 0f;
        m_side_line_anti_dist = 0f;
        antiFoldAngleRad = antiFoldAngle * Mathf.Deg2Rad;
        if (sideLink == null) return;
        var ownTip = tipTrs != null ? tipTrs.position : trs.position;
        var otherTip = sideLink.tipTrs != null ? sideLink.tipTrs.position : sideLink.trs.position;
        m_side_line_initial_dist = Vector3.Distance(ownTip, otherTip);
    }

    /// <summary>SwayBone.SetAntiFoldAngle 0x1C718A8.</summary>
    public void SetAntiFoldAngle(float angle)
    {
        antiFoldAngle = angle;
        antiFoldAngleRad = angle * Mathf.Deg2Rad;
    }

    /// <summary>SwayBone.SetSkirtParam 0x1C716D0: native body is empty.</summary>
    public void SetSkirtParam()
    {
    }

    /// <summary>
    /// SwayBone.AdjustSkirt 0x1C718C4. Window constants read from the shipped
    /// binary at 0x8426C10 = (-5, 5, -150, 150); the radius branch shifts
    /// colliderOffset by r - n_radius and re-derives radius from body scale.
    /// </summary>
    public void AdjustSkirt(float r)
    {
        isSkirt = true;
        limitAngle = true;
        // xmmword_8426C10 = minY -5, maxY 5, minZ -150, maxZ 150 (read from
        // the shipped binary at offset 0x8426C10).
        minYAngle = -5f;
        maxYAngle = 5f;
        minZAngle = -150f;
        maxZAngle = 150f;
        minZAngleTgt = minZAngle;
        maxZAngleTgt = maxZAngle;
        if (n_radius < r)
        {
            AdjustColliderOffset(0f, r - n_radius, 0f);
            n_radius = r;
            radius = BodyScaleScale() * r;
        }
    }

    /// <summary>SwayBone.AdjustColliderOffset 0x1C71940 (radius based offset shift).</summary>
    public void AdjustColliderOffset(Vector3 vec)
    {
        // Native 0x1C71940 assigns colliderOffset (it does not accumulate),
        // then recomputes aimVector, swayLength, curTipPos/prevTipPos and
        // m_offset_rot from tipTrs.localPosition + colliderOffset.
        colliderOffset = vec;
        if (tipTrs == null || trs == null) return;
        var tipLocal = tipTrs.localPosition + colliderOffset;
        var len = tipLocal.magnitude;
        aimVector = len > 0.00001f ? tipLocal / len : Vector3.zero;
        swayLength = len * BodyScaleScale();
        curTipPos = trs.TransformPoint(tipLocal);
        prevTipPos = curTipPos;
        lastBasePos = trs.position;
        m_offset_rot = Quaternion.FromToRotation(aimVector, -Vector3.right);
    }

    /// <summary>Convenience overload matching the native (x,y,z) signature.</summary>
    public void AdjustColliderOffset(float x, float y, float z)
    {
        AdjustColliderOffset(new Vector3(x, y, z));
    }

    /// <summary>SwayBone.ResetRot 0x1C71C84.</summary>
    public void ResetRot()
    {
        if (trs == null) return;
        trs.localRotation = initialLocalRotation;
        if (tipTrs != null)
        {
            prevTipPos = tipTrs.position;
            curTipPos = tipTrs.position;
        }
        if (colliders != null && colliders_enable != null)
            for (var i = 0; i < colliders.Length && i < colliders_enable.Length; i++)
            {
                if (!colliders_enable[i]) continue;
                var set = colliders[i];
                if (set == null || set.c == null) continue;
                if (set.c.on) set.c.m_exec_ok = false;
            }
    }

    /// <summary>SwayBone.ResetTipPos 0x1C72640: only marks MT state ResetTipPos.</summary>
    public void ResetTipPos()
    {
        // SwayBoneMT.ParallelParamsUpdateState.ResetTipPos = 4; the serial port
        // has no deferred state, so this is a no-op (documented).
    }

    /// <summary>
    /// SwayBone.FinishRotate 0x1CCCD58 (old 0x1C720E0): normalize the tip offset
    /// around the base to swayLength (0xF0) then run CalcRotate (0x1CCCE98, the
    /// native tail call). When |curTip - base| &lt;= 1e-5 native falls back to the
    /// first static member of UnityEngine.Vector3 (off_970CCF8 static_fields
    /// +0x00) as the direction; Vector3.cctor 0x7095358 writes the 128-byte
    /// static block in the order zero(+0x00)/(0,0,0), one(+0x0C), up(+0x18),
    /// down(+0x24), left(+0x30), right(+0x3C), forward(+0x48), back(+0x54) — so
    /// the native fallback IS Vector3.zero and the port's zero fallback is
    /// native-faithful. The current-binary decompile confirms the whole body
    /// (no formula delta vs the existing port).
    /// </summary>
    public void FinishRotate()
    {
        if (trs == null) return;
        var basePos = trs.position;
        var offset = curTipPos - basePos;
        var len = offset.magnitude;
        var dir = len > 0.00001f ? offset / len : Vector3.zero;
        curTipPos = basePos + dir * swayLength;
        CalcRotate();
    }

    /// <summary>
    /// SwayBone.CalcRotate 0x1C72220. Native order, verified against the fresh
    /// IDA rebuild of /tmp/ida-decomp2/f_1c72220.c and the wrapper strings in
    /// /tmp/ida-sway-helpers/h_*.c:
    ///   head   set_localRotation(initialLocalRotation)   (sub_70BF458 = set_localRotation_Injected)
    ///   if limitAngle:
    ///     localDir = trs.InverseTransformDirection(curTipPos - trs.position)   (sub_70C13F4 =
    ///            InverseTransformDirection_Injected — set_position/InverseTransformPoint claims
    ///            are disproven: the wrapper's il2cpp string is pinned)
    ///     dir = m_offset_rot * localDir  (0x1DC quaternion applied by the inlined Quaternion*Vector3 )
    ///     yaw = Atan2(dir.z, -dir.x) * Rad2Deg ; pitch = -Atan2(dir.y, sqrt(dir.x^2+dir.z^2)) * Rad2Deg
    ///     clamp yaw in [minY,+0x64], pitch in [minZ(+0x6C),maxZ(+0x70) working params]
    ///     localRotation = initialLocalRotation * Euler(0, yaw, pitch)   (sub_7095878 =
    ///            Quaternion.Internal_FromEulerRad; the multiply-operand mapping in the decompile
    ///            resolves exactly to q(initial) * q(euler))
    ///     if clamped && tipTrs: curTipPos = trs.TransformPoint(tipTrs.localPosition + colliderOffset)
    ///                           (sub_70BE0A8 = get_localPosition, sub_70BC63C = TransformPoint);
    ///                           prevTipPos = curTipPos
    ///   else   localDir = InverseTransformDirection(curTipPos - trs.position)  — after the head
    ///          reset, so it is measured in the bind frame every frame
    ///          localRotation = initialLocalRotation * FromToRotation(aimVector, localDir)
    ///          (sub_70953E8 = FromToRotation_Injected; multiply operand mapping again resolves
    ///          to q(initial) * q(delta))
    ///   tail   lastBasePos = trs.position
    ///   HitMuteForce && (lineHitF || sphereHitF): prevTipPos = curTipPos*rate + prevTipPos*(1-rate)
    /// </summary>
    /// <summary>Diagnostic mirror of the native clamp-hit flag (probe only).</summary>
    [System.NonSerialized] public bool diag_clamped;
    [System.NonSerialized] public float diag_yaw, diag_pitch;
    [System.NonSerialized] public Vector3 diag_tipBefore;
    public static float followScale = 1f;
    public static readonly StringBuilder diagHit = new StringBuilder();
    public static bool diagHitOn;
    [System.NonSerialized] public float diag_stiff, diag_grav, diag_drag, diag_forceY, diag_ratio, diag_follow;

    public void CalcRotate()
    {
        // 0x1C72220 head: both branches reset first. The previous revision put
        // this reset inside the limitAngle branch only; the limitAngle==0
        // (OPAI) path therefore measured InverseTransformDirection against
        // LAST frame's localRotation (already = initial * delta), and the else
        // branch compounded one FromToRotation delta per frame in a feedback
        // loop — OPAI_L0 localRotation alternated between two poses ~147°
        // apart (sampled |dot(q[i],q[i+1])| ≈ 0.28 instead of ≈ 1).
        if (trs == null) return;
        trs.localRotation = initialLocalRotation;

        if (limitAngle)
        {
            var localDir = trs.InverseTransformDirection(curTipPos - trs.position);
            var dir = m_offset_rot * localDir;

            var yaw = Mathf.Atan2(dir.z, -dir.x) * Mathf.Rad2Deg;
            diag_tipBefore = curTipPos;
            var pitch = Mathf.Atan2(dir.y, Mathf.Sqrt(dir.x * dir.x + dir.z * dir.z)) * -Mathf.Rad2Deg;

            diag_yaw = yaw; diag_pitch = pitch;
            var clamped = false;
            var y = yaw;
            if (y < minYAngle) { y = minYAngle; clamped = true; }
            else if (y > maxYAngle) { y = maxYAngle; clamped = true; }

            var z = pitch;
            // Native clamps to the animated WorkingParams minZAngle/maxZAngle
            // (0x1C72220 +108/+112), which SwayMove updates for wings.
            if (z < minZAngle) { z = minZAngle; clamped = true; }
            else if (z > maxZAngle) { z = maxZAngle; clamped = true; }

            trs.localRotation = initialLocalRotation * Quaternion.Euler(0f, y, z);

            diag_clamped = clamped;
            if (clamped && tipTrs != null)
            {
                // Recompute the tail at the clamped angle and write it back to
                // both curTipPos and prevTipPos (0x1C72220, v32/v25 != 0).
                curTipPos = trs.TransformPoint(tipTrs.localPosition + colliderOffset);
                prevTipPos = curTipPos;
            }
        }
        else
        {
            // 0x1C72220 else-branch: the head reset above means localDir is the
            // direction in the bind frame; that removes the per-frame feedback
            // that produced the OPAI flip.
            var localDir = trs.InverseTransformDirection(curTipPos - trs.position);
            var delta = Quaternion.FromToRotation(aimVector, localDir);
            trs.localRotation = initialLocalRotation * delta;
        }

        lastBasePos = trs.position;

        if (HitMuteForce && (lineHitF || sphereHitF))
        {
            // HitMute: prevTip = curTip * HitMuteRate + prevTip * (1 - rate)
            // (0x1C72220 tail; gate is lineHitF || sphereHitF exactly as decompiled).
            var rate = HitMuteRate;
            prevTipPos = curTipPos * rate + prevTipPos * (1f - rate);
        }
    }

    /// <summary>
    /// SwayBone.ResetRotForADV 0x1CCC9F8 (old 0x1C71D80). Story (ADV) speaker
    /// switches call this; missing it leaves the previous speaker's tip offset
    /// and snaps head/hair rotations. Current-binary body:
    ///   trs.localRotation = initialLocalRotation (0xD8);
    ///   lastBasePos (0x15C) = trs.position;
    ///   (native reads trs.parent's rotation here — see UNKNOWN below);
    ///   curTipPos (0x100) = tipTrs.position + gravity (0x90);
    ///   dir = normalize(curTipPos - trs.position), |.| &lt;= 1e-5 -> Vector3.zero;
    ///   curTipPos = trs.position + dir * swayLength (0xF0);
    ///   prevTipPos (0x10C) = curTipPos;
    ///   every enabled collider whose set.c.on (0x30) is true clears m_exec_ok
    ///   (0xA8); tail sets SwayBoneMT.ParallelParamsUpdateState = 5 (serial port
    ///   has no MT state, so that write is a no-op).
    /// UNKNOWN(native 0x1CCC9F8): Hex-Rays shows an extra Vector3 term added to
    /// tipTrs.position + gravity from `sub_712AC70` (in CalcRotate the same
    /// helper is Quaternion.op_Multiply), with a preceding `trs.parent` rotation
    /// read whose operand vector Hex-Rays drops; the term is left out until the
    /// operands can be pinned (it is exact zero only if the operand is a zero
    /// vector, which the report reads it as).
    /// </summary>
    public void ResetRotForADV()
    {
        if (trs == null) return;
        trs.localRotation = initialLocalRotation;
        lastBasePos = trs.position;
        curTipPos = (tipTrs != null ? tipTrs.position : trs.position) + gravity;
        var offset = curTipPos - trs.position;
        var len = offset.magnitude;
        var dir = len > 0.00001f ? offset / len : Vector3.zero;
        curTipPos = trs.position + dir * swayLength;
        prevTipPos = curTipPos;
        if (colliders != null && colliders_enable != null)
        {
            for (var i = 0; i < colliders.Length && i < colliders_enable.Length; i++)
            {
                if (!colliders_enable[i]) continue;
                var set = colliders[i];
                if (set == null || set.c == null) continue;
                if (set.c.on) set.c.m_exec_ok = false;
            }
        }
    }

    // ---------------- wing limits ----------------

    // Native statics LWingMinZ/LWingMaxZ/RWingMinZ/RWingMaxZ are 11-element
    // float[] built by SwayBone..cctor 0x1CCE8A8 (old 0x1C73C30) through
    // RuntimeHelpers.InitializeArray — the literal values live in metadata
    // field-RVA blobs that the /tmp dump does not carry (no shipped binary is
    // available in this session). Every entry is therefore UNKNOWN(native
    // 0x1CCE8A8); the stand-in fills all 11 indices with the documented
    // WING_DEFAULT_MIN_Z/WING_DEFAULT_MAX_Z window so the tag/index/flag control
    // flow below stays native-faithful and index-safe. Swap in the real tables
    // once the field-RVA bytes are readable.
    private static readonly float[] LWingMinZ = WingDefaultTable(-10f);   // WING_DEFAULT_MIN_Z
    private static readonly float[] LWingMaxZ = WingDefaultTable(10f);    // WING_DEFAULT_MAX_Z
    private static readonly float[] RWingMinZ = WingDefaultTable(-10f);
    private static readonly float[] RWingMaxZ = WingDefaultTable(10f);

    private static float[] WingDefaultTable(float value)
    {
        var table = new float[11];
        for (var i = 0; i < table.Length; i++) table[i] = value;
        return table;
    }

    /// <summary>
    /// SwayBone.InitWingLimit 0x1CCD2D8 (old 0x1C72660): wing_L0 copies
    /// LWingMinZ[0]/LWingMaxZ[0], wing_R0 copies RWingMinZ[0]/RWingMaxZ[0] into
    /// minZAngleTgt (0x74) / maxZAngleTgt (0x78). The native tail sets
    /// isWingLimitAngleChanged (0x7C) = true unconditionally (also for non-wings).
    /// UNKNOWN(native 0x1CCD2D8): the exact 11-entry table values (cctor blobs,
    /// see above); index 0 is the only entry this method reads.
    /// </summary>
    public void InitWingLimit()
    {
        var go = gameObject;
        if (CompareTagSafe(go, "wing_L0"))
        {
            minZAngleTgt = LWingMinZ[0];
            maxZAngleTgt = LWingMaxZ[0];
        }
        if (CompareTagSafe(go, "wing_R0"))
        {
            minZAngleTgt = RWingMinZ[0];
            maxZAngleTgt = RWingMaxZ[0];
        }
        isWingLimitAngleChanged = true;
    }

    /// <summary>
    /// SwayBone.SetWingLimitL 0x1CCD42C (old 0x1C727B4): minZAngleTgt =
    /// LWingMinZ[param], maxZAngleTgt = LWingMaxZ[param] (each write bounds-checked
    /// in native; the port guards and skips instead of throwing),
    /// isWingLimitAngleChanged = true.
    /// </summary>
    public void SetWingLimitL(int param)
    {
        if (param >= 0 && param < LWingMinZ.Length && param < LWingMaxZ.Length)
        {
            minZAngleTgt = LWingMinZ[param];
            maxZAngleTgt = LWingMaxZ[param];
        }
        isWingLimitAngleChanged = true;
    }

    /// <summary>
    /// SwayBone.SetWingLimitR 0x1CCD504 (old 0x1C7288C): same as the L variant
    /// against RWingMinZ/RWingMaxZ.
    /// </summary>
    public void SetWingLimitR(int param)
    {
        if (param >= 0 && param < RWingMinZ.Length && param < RWingMaxZ.Length)
        {
            minZAngleTgt = RWingMinZ[param];
            maxZAngleTgt = RWingMaxZ[param];
        }
        isWingLimitAngleChanged = true;
    }

    // ---------------- per-frame passes ----------------

    /// <summary>
    /// SwayBone.SwayMove 0x1C72964 (scalar) / SwayBoneMT.SwayMove 0x1C6867C
    /// (struct, world-space). Implements, in native order:
    ///   swayTransBack tail reset (curTip = prev = tipTrs.position) -> wing
    ///   limit transition (±4°/frame) -> follow (rate priority:
    ///   swayFollowRate[cat] > swayFollowSW=1 > skirt fallFollow > followForce,
    ///   0 when swayTransBack; baseDelta = trs.position − lastBasePos added to
    ///   BOTH curTip and prevTip) -> stiffness/antiFold
    ///   (parentWorldRotation * initialLocalRotation applied to
    ///   aimVector * (stiffnessForce + antiFoldForceSum)) + velocity damping
    ///   ((curTip − prevTip + wind*dt) * (1 − dragForce) * (60s/dt)²⁻¹) ->
    ///   gravity (only when !lineHitF, 0x1C72964 tests byte 0x14C only) -> wind
    ///   term inside the velocity -> vecs1[cat] -> side-line forces (isSkirt)
    ///   -> skirtNormal/skirtDir = this-transform world rotation * up /
    ///   right (LABEL_96, before the integrate) -> swayDamper[cat] blend ->
    ///   integrate curTip += force*ratioSq, prevTip = oldTip.
    /// Returns the new tip (SwayManager.ExecuteUpdate writes it to bone+0x100).
    /// lastBasePos (0x15C) is NOT written here; CalcRotate's tail maintains it.
    /// </summary>
    public Vector3 SwayMove(float deltaTime)
    {
        if (trs == null || tipTrs == null) return curTipPos;

        var transBack = owner != null && owner.swayTransBack;

        // 1) swayTransBack: tail is pinned to the current tail transform.
        if (transBack)
        {
            curTipPos = tipTrs.position;
            prevTipPos = curTipPos;
        }

        // 2) wing limit transition (+/- WING_SPEED degrees per frame).
        // Native 0x1C72964: skipped when workOnCharacterViewer (0x3E) is set.
        if (isWing && !workOnCharacterViewer)
        {
            minZAngle = SwayNativeMath.WingMoveTowards(minZAngle, minZAngleTgt, SwayConstants.WING_SPEED);
            maxZAngle = SwayNativeMath.WingMoveTowards(maxZAngle, maxZAngleTgt, SwayConstants.WING_SPEED);
        }

        // 3) follow: rate = swayFollowRate[category]; 0 -> swayFollowSW -> bone
        //    followForce (SkirtFallFollow uses fallFollow), swayTransBack -> 0.
        var followRate = transBack ? 0f : GetFollowRate();
        if (followRate != 0f)
        {
            var baseDelta = trs.position - lastBasePos;
            diag_follow = baseDelta.magnitude * followRate;
            curTipPos += baseDelta * (followRate * followScale);
            prevTipPos += baseDelta * (followRate * followScale);
        }

        // 4) ratio terms: dt is normalised by the native 1/60 frame.
        var ratio = deltaTime / 0.016f;
        var ratioSq = ratio * ratio;
        var invRatioSq = ratioSq > 1e-8f ? 1f / ratioSq : 0f;

        // 5) force.
        var parentRotation = trs.parent != null ? trs.parent.rotation : Quaternion.identity;
        var rot = parentRotation * initialLocalRotation;
        var stiffTerm = rot * aimVector * (stiffnessForce + antiFoldForceSum);
        var forceAcc = stiffTerm;
        diag_stiff = stiffTerm.magnitude;
        diag_grav = gravity.y;
        var velocity = curTipPos - prevTipPos;
        if (owner != null) velocity += owner.GetWind(curTipPos) * deltaTime;
        forceAcc += velocity * (1f - dragForce) * invRatioSq;

        // 0x1C72964 tests only lineHitF (+0x14C byte 0) before adding gravity —
        // sphereHitF (+0x14D) does NOT gate gravity in the shipped binary.
        if (!lineHitF)
            forceAcc += gravity;
        diag_drag = forceAcc.magnitude;

        // Per-category extra force (SwayCtrlMT.vecs1Array; per-category native
        // array at static+136 → +40 → +312, stride 12 bytes per category,
        // added at LABEL_61 BEFORE the side-line forces below). Zero by
        // default, driven by the live stage, out of the character bundle.
        if (owner != null) forceAcc += owner.GetVecs1((int)category);

        // Side-line forces — native adds these AFTER the vecs1 term
        // (SwayBone.SwayMove 0x1C72964: LABEL_61 vecs1 pass, then LABEL_72
        // side-line pass). Only the isSkirt branch exists in native
        // (SwayBoneMT 0x1C6867C gates the arrays the same way); side forces
        // are only computed by CalcSideLineDistance when isSkirt (0x1C736B8
        // first check).
        if (isSkirt)
        {
            if (sideLink != null && sideSpringForce > 0f && m_side_line_dist > 0.001f)
            {
                forceAcc += m_side_line_force;
            }
            else if (sideAntiSpringForce > 0f && m_side_line_anti_dist < -0.001f)
            {
                forceAcc += m_side_line_anti_force;
            }
            if (sideLink2 != null && sideLink2.sideSpringForce > 0f)
            {
                if (sideLink2.m_side_line_dist > 0.001f)
                    forceAcc -= sideLink2.m_side_line_force;
                else if (sideAntiSpringForce > 0f && sideLink2.m_side_line_anti_dist < -0.001f)
                    forceAcc -= sideLink2.m_side_line_anti_force;
            }
        }

        // 6) damper, integrate.
        var damper = owner != null ? owner.GetDamper((int)category) : 1f;
        forceAcc *= damper;
        force = forceAcc;

        // 7) skirt barrier frame — native writes skirtNormal/skirtDir BEFORE the
        //    integration (SwayBone.SwayMove 0x1C72964 LABEL_96 runs before
        //    LABEL_103/LABEL_113), reading THIS.transform.rotation (the pose the
        //    previous CalcRotate left in place).
        skirtNormal = trs.rotation * Vector3.up;
        skirtDir = trs.rotation * Vector3.right;

        diag_forceY = force.y;
        diag_ratio = ratio;
        var oldTip = curTipPos;
        curTipPos += force * ratioSq;
        prevTipPos = oldTip;
        // native 0x1C72964 does NOT write lastBasePos (0x15C) — only the
        // CalcRotate 0x1C72220 tail maintains it (same trs.position value this
        // frame, so the old port's duplicate write changed nothing observable).

        return curTipPos;
    }

    private float GetFollowRate()
    {
        if (mgr == null) return followForce;
        var categoryIndex = (int)category;
        var rate = mgr.GetFollowRate(categoryIndex);
        if (rate != 0f) return rate;
        if (mgr.GetFollowSW(categoryIndex)) return 1f;
        // SkirtFallFollow uses fallFollow only for skirt bones (native
        // 0x1C72964 compares manager.SkirtFallFollow && bone.isSkirt).
        if (mgr.SkirtFallFollow && isSkirt) return mgr.FollowFall;
        return followForce;
    }

    /// <summary>
    /// SwayBone.SwayHit 0x1CCDF60 (old 0x1C732E8): clear lineHitF/sphereHitF
    /// (one 16-bit store at 0x14C), test every enabled collider
    /// (colliders_enable 0xD0, set.c.on), and when SwayCollider.Check 0x1CCE09C
    /// reports a contact keep the test whose push (`newpos` 0x7C) is farthest
    /// from the running curTipPos — the distance is re-evaluated against the
    /// CURRENT curTipPos every iteration (deepest wins) — write it into
    /// curTipPos and set sphereHitF (0x14D).
    /// The current body contains NO useLinkHit/CheckSideLine pass: it calls only
    /// SwayCollider.Check. (Old 0x1C75380 is SwayCollider.CheckSideLine's entry,
    /// per SwayColliderNative.cs, not a SwayHit call site.) No scalar-path
    /// consumer of useLinkHit is proven; leaving it unread is
    /// UNKNOWN(native 0x1CCDF60): where useLinkHit is consumed in the shipped
    /// binary.
    /// </summary>
    public void SwayHit()
    {
        lineHitF = false;
        sphereHitF = false;
        if (colliders == null) return;

        var bestSq = 0f;
        for (var i = 0; i < colliders.Length; i++)
        {
            if (colliders_enable != null && i < colliders_enable.Length && !colliders_enable[i]) continue;
            var set = colliders[i];
            if (set == null || set.c == null) continue;
            if (!set.c.on) continue;
            var hitOk = set.c.Check(this, i);
            if (diagHitOn && transform.name == "skirt_F0")
            {
                var cc = set.c;
                diagHit.Append(" col").Append(i).Append(" type=").Append(cc.type)
                    .Append(" on=").Append(cc.on)
                    .Append(" center=").Append(cc.m_w_center.ToString("F3"))
                    .Append(" dir=").Append(cc.m_w_dir.ToString("F3"))
                    .Append(" r=").Append(cc.radius.ToString("F3"))
                    .Append(" d=").Append(cc.distance.ToString("F3"))
                    .Append(" sc=").Append(cc.m_scale.ToString("F3"))
                    .Append(" cull=").Append(cc.m_culling_r.ToString("F3"))
                    .Append(" tipr=").Append(radius.ToString("F3"))
                    .Append(" |tip-c|=").Append((curTipPos - cc.m_w_center).magnitude.ToString("F3"))
                    .Append(" ok=").Append(hitOk)
                    .Append(" newpos=").Append(cc.newpos.ToString("F3"))
                    .Append(" push=").Append((cc.newpos - curTipPos).magnitude.ToString("F3")).AppendLine();
            }
            if (!hitOk) continue;
            var d2 = (set.c.newpos - curTipPos).sqrMagnitude;
            if (d2 <= bestSq) continue;
            bestSq = d2;
            curTipPos = set.c.newpos;
            sphereHitF = true;
        }
    }

    /// <summary>
    /// SwayBone.CalcSideLineDistance 0x1C736B8. Native order: `isSkirt` gate
    /// (0x3C), sideLink != null (sub_70B5238 object check), THEN
    /// antiFoldForceSum (0x1D4) = 0 — the clear only happens after the null
    /// gate, the old port zeroed it before the gate; and the tail-side math
    /// only runs when sideSpringForce (0x184) > 0. sideLink's tail is read as
    /// sideLink.TRS.GetChild(0) (sub_70C2A8C = GetChild_Injected), the same
    /// value as the cached tipTrs field.
    /// </summary>
    public void CalcSideLineDistance()
    {
        if (!isSkirt) return;
        if (sideLink == null || sideLink.trs == null || tipTrs == null) return;

        var sideTip = sideLink.tipTrs;
        if (sideTip == null || !sideTip.gameObject.activeInHierarchy) return;

        antiFoldForceSum = 0f;
        if (sideSpringForce <= 0f) return; // 0x1C736B8 gates the tail math on sideSpringForce > 0

        var delta = sideTip.position - tipTrs.position;
        var dist = delta.magnitude;
        var dir = dist > 0.00001f ? delta / dist : Vector3.zero;

        m_side_line_dist = dist - sideSpringTorelance * m_side_line_initial_dist;
        m_side_line_force = dir * (m_side_line_dist * sideSpringForce);

        if (sideAntiSpringForce > 0f)
        {
            m_side_line_anti_dist = dist - m_side_line_initial_dist * sideAntiSpringTorelance;
            m_side_line_anti_force = dir * (sideAntiSpringForce * m_side_line_anti_dist);
        }
    }

    /// <summary>
    /// SwayBone.CalcAntiFoldForce 0x1C738A8. Native order: antiFoldForceK
    /// (0x198) > 0, sideLink (0x50) != null, sideLink2 (0x58) != null, then
    /// normalize(sideLink tip - curTipPos) and normalize(sideLink2 tip -
    /// curTipPos); the degenerate direction is the first static member of
    /// UnityEngine.Vector3 (off_970CCF8 static_fields +0x00 = Vector3.zero,
    /// cctor 0x7095358 — same resolution as FinishRotate), and when
    /// acos(dot) &lt; antiFoldAngleRad (0x1D8) the loop writes
    /// max(antiFoldForceSum, K) along the .sideLink2 chain STARTING AT
    /// sideLink2 itself — sideLink is not written to. The port keeps a 16-hop
    /// guard as a safety net; native loops unbounded but breaks when a node's
    /// object reference is null.
    /// </summary>
    public void CalcAntiFoldForce()
    {
        if (antiFoldForceK <= 0f) return;
        if (sideLink == null || sideLink.trs == null || sideLink.tipTrs == null) return;
        if (sideLink2 == null || sideLink2.trs == null || sideLink2.tipTrs == null) return;

        var d1 = SwayNativeMath.NormalizeOrZero(sideLink.tipTrs.position - curTipPos);
        var d2 = SwayNativeMath.NormalizeOrZero(sideLink2.tipTrs.position - curTipPos);
        var angle = Mathf.Acos(Mathf.Clamp(Vector3.Dot(d1, d2), -1f, 1f));
        if (!(angle < antiFoldAngleRad)) return;

        var n = sideLink2;
        var guard = 0;
        while (n != null && guard++ < 16)
        {
            n.antiFoldForceSum = Mathf.Max(n.antiFoldForceSum, antiFoldForceK);
            n = n.sideLink2;
        }
    }

    /// <summary>SwayBone.Record 0x1C70A94 (editor/record path): store current params.</summary>
    public void Record()
    {
        rec.minYAngle = minYAngle;
        rec.maxYAngle = maxYAngle;
        rec.minZAngle = minZAngle;
        rec.maxZAngle = maxZAngle;
        rec.stiffnessForce = stiffnessForce;
        rec.dragForce = dragForce;
        rec.gravity = gravity;
        rec.followForce = followForce;
    }

    /// <summary>SwayManager.UpdateParameters 0x1C816F8 / SwayManager.Init tail:
    /// copy manager parameters into bones with refParam == Manager.</summary>
    public void ApplyManagerParameters()
    {
        if (mgr == null) return;
        stiffnessForce = mgr.stiffnessForce;
        dragForce = mgr.dragForce;
        followForce = mgr.followForce;
        gravity = mgr.gravity;
    }

    /// <summary>Diagnostics for probes, mirrors the audit's bone→collider table.</summary>
    public string DescribeRefs()
    {
        if (colliders == null) return name + " refs=0";
        var sb = new System.Text.StringBuilder();
        sb.Append(name).Append(" refs=").Append(colliders.Length).Append(" ::");
        for (var i = 0; i < colliders.Length; i++)
        {
            var set = colliders[i];
            var c = set != null ? set.c : null;
            sb.Append(' ').Append(set != null ? set.path : "<null>").Append('#').Append(set != null ? set.n : -1);
            if (c != null)
                sb.Append('(').Append(c.type).Append(" r").Append(c.n_radius.ToString("F3"))
                  .Append('@').Append(c.transform.name).Append(')');
            else
                sb.Append("(unresolved)");
        }
        return sb.ToString();
    }
}
