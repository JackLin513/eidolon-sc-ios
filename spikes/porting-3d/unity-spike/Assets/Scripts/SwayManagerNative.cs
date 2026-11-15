// Native-faithful assembly + per-frame driver for the game's V01 sway system:
//   SwayManager / SwayCtrlMT  (dump.cs TypeDefIndex 15315 / 15296)
//   SwayFileIO.ImportCommon   (0x1C764FC)
//
// ADR-0033: Jobs/Burst -> serial C#, NativeArray/TransformAccess -> arrays and
// Transform. The pass ORDER, the fixed 1/60 step, the dt clamp and the merge
// rules are kept exactly as the shipped binary does them:
//
//   SwayFileIO.ImportCommon 0x1C764FC attaches, onto the SAME top object
//   (= JointBodyHead.body 0x18):
//       AttachSwayManager(body.sm), AttachSwayManager(head.sm),
//       AttachSwayCollider(body.sc, skirtGuardOffset), AttachSwayCollider(head.sc, 0),
//       AttachSwayBone(body.sb), AttachSwayBone(head.sb),
//       InitSwayManager(jbh), InitSwayBones(jbh)
//   so there is ONE merged rig; head bone collider refs may resolve to body
//   colliders (audit P0-2). `<joint>#k` is the k-th SwayCollider component on
//   that joint (AttachSwayBone 0x1C7726C), never a file-wide array index.
//
//   SwayManager.LateUpdate   0x1C817F0: PrepareUpdate -> ExecuteUpdate(dt) ->
//       PostUpdate; forceUpdate repeats Execute with deltaTimeForForceUpdateInframe.
//   PrepareUpdate 0x1C81A08: accumulator on Time.realtimeSinceStartup, a 1/60
//       trigger, m_delta_time = clamp(old + (Time.deltaTime - old) *
//       Time.deltaTime, 1/60, 0.025); resets bone.h/cc/colliderInx and
//       SwayCollider.Update (0x1C73FE8) clears m_exec_ok.
//   ExecuteUpdate 0x1C81CD8: four passes over SwayManager.swayBones:
//       1 SwayBone.CalcSideLineDistance, 2 SwayBone.CalcAntiFoldForce,
//       3 SwayBone.SwayMove (return written to curTipPos), 4 SwayBone.SwayHit,
//       and when bone.hitTwice (0x18C) a second SwayHit in the same pass.
//   PostUpdate 0x1C81E40: SwayBone.FinishRotate (0x1C720E0) per bone, which
//       normalises the tail to swayLength and runs CalcRotate.
//
// SwayCtrlMT (0x1C6DD94 / ExecuteParallelSway 0x1C6CFD0) is kept as a serial
// container (`SwayCtrlMTNative`) that owns the same arrays and runs the four
// passes in the same order; it exists so the Lead can later swap the loops for
// jobs without changing the manager.

using System;
using System.Collections.Generic;
using System.Text;
using UnityEngine;

/// <summary>
/// One manager group. Native SwayManager is a MonoBehaviour attached to the
/// transform named by the `SwayManager:` stanza path; all bones of that group
/// share its parameters when they have `refParam: Manager`.
/// </summary>
// Native allows more than one manager per node in principle; the data uses one.
public sealed class SwayManagerNative : MonoBehaviour
{
    // -------- SwayManager fields (dump.cs 15315) --------
    public bool on = true;                 // 0x20
    public float stiffnessForce;           // 0x24
    public float dragForce;                // 0x28
    public float followForce;              // 0x2C
    public Vector3 gravity = new Vector3(0f, -0.0001f, 0f); // 0x30 (ctor default 0xB8D1B71700000000)
    public float lineMoveLimit;            // 0x3C
    public float sidelineMoveLimit;        // 0x40
    public float sqrLineMoveLimit;         // 0x44
    public float sqrSidelineMoveLimit;     // 0x48
    public SwayBoneNative[] swayBones;     // 0x50
    [System.NonSerialized] public SwayRigNative rig;
    public SwayBoneNative[] skirtL1;       // 0x58
    public SwayBoneNative[] skirtL2;       // 0x60
    public Transform BodyScale;            // 0x68
    public Transform BaseTr;               // 0x70
    public bool SkirtFallFollow;           // 0x78
    public bool isSkirtFallFollowChanged;  // 0x79
    public float lastTime;                 // 0x88
    public float localDelta;               // 0x8C
    public float updateSwayTime;           // 0x90
    public float sideLineHitTime;          // 0x94
    public float m_delta_time = SwayConstants.FIXED_DELTA; // 0xB4
    public int forceUpdate;                // 0xC8
    public int forceUpdateCountInFrame;    // 0xCC
    public float deltaTimeForForceUpdateInframe; // 0xD0
    public int forceUpdateResetTiming;     // 0xD4
    public SwayCategory Category = SwayCategory.Normal; // 0xD8
    public string fileName;                // 0xE0

    // -------- data that JointBodyHead owns at runtime (not in _sway) --------
    // Native sources (dump.cs JointBodyHead):
    //   swayFollowRate 0x128, swayTransBack 0x105, swayOn 0x104.
    // Live IdolPositionMgr supplies swayFollowSW[] / swayDamper[] / vecs1[].
    // Defaults below are the neutral values used when the live stage sets
    // nothing: followRate 0 -> bone.followForce path, FollowSW false,
    // damper 1, vecs1 zero.
    // UNKNOWN(data): these arrays are runtime-only and not present in the
    // character bundles; the Lead must wire them to JointBodyHead/IdolPositionMgr
    // once those classes are migrated (B5).
    public float[] swayFollowRate = new float[5];
    public bool[] swayFollowSW = new bool[5];
    public float[] swayDamper = { 1f, 1f, 1f, 1f, 1f };
    public Vector3[] vecs1 = new Vector3[5];
    public bool swayTransBack;
    public bool swayOn = true;
    public float FollowFall;               // FixedParams.fallFollow, from JointBodyHead

    /// <summary>SwayCtrlMT serial container (arrays + pass driver).</summary>
    public SwayCtrlMTNative ctrl = new SwayCtrlMTNative();

    private bool initialized;

    private void Awake()
    {
        // SwayManager.Awake 0x1C80DD8: BodyScale = parent.Find("BodyScale"),
        // BaseTr = parent.Find("Base"); if BodyScale inactive, fall back to
        // parent.Find(<fallback>) for both. The spike prefab drops BODY_SCALE,
        // so we additionally accept BASE (native name used by bones) before
        // giving up; this is a documented data gap, not a behavior change.
        var parent = transform.parent;
        if (parent != null)
        {
            BodyScale = FindChild(parent, "BodyScale");
            if (BodyScale == null) BodyScale = FindChild(parent, "BODY_SCALE");
            BaseTr = FindChild(parent, "Base");
            if (BaseTr == null) BaseTr = FindChild(parent, "BASE");
            if (BodyScale == null) BodyScale = BaseTr;
            if (BaseTr == null) BaseTr = BodyScale;
        }
        if (BodyScale == null) BodyScale = FindChild(transform.root, "BODY_SCALE");
        if (BodyScale == null) BodyScale = FindChild(transform.root, "BASE");
    }

    private static Transform FindChild(Transform parent, string name)
    {
        for (var i = 0; i < parent.childCount; i++)
        {
            var child = parent.GetChild(i);
            if (string.Equals(child.name, name, StringComparison.Ordinal)) return child;
        }
        return null;
    }

    /// <summary>
    /// SwayFileIO.AttachSwayManager 0x1C76B34: copy SwayManagerParams fields.
    /// Native SwayManager.ctor 0x1C8249C already sets on=true, gravity
    /// (0,-0.0001,0), line/sideline 0; the stanza overrides them.
    /// </summary>
    public void Attach(SwayManagerNativeParams p, SwayCategory category)
    {
        this.fileName = p.fname;
        Category = category;
        gravity = p.gravity;
        stiffnessForce = p.stiffnessForce;
        dragForce = p.dragForce;
        followForce = p.followForce;
        lineMoveLimit = p.lineMoveLimit;
        sidelineMoveLimit = p.sidelineMoveLimit;
        // Newer optional fields are parsed but no V01 solver path consumes them
        // in the decompiles we transcribed; keep them in SwayManagerNativeParams
        // so a later stage pass can use them without re-parsing.
    }

    /// <summary>
    /// SwayManager.Init 0x1C810CC. Native collects bones recursively from its
    /// own transform, resolves sideLink paths with SwayFileIO.ReadPath, links
    /// sideLink2 back-pointers, stores the bone array and computes the squared
    /// line limits; then copies manager parameters into refParam=Manager bones.
    ///
    /// DEVIATION(native 0x1C814AC): the native recursion collects every
    /// SwayBone under the manager transform, which would put skirt bones into
    /// both the root and the `skirt_GP` manager (their subtrees nest). We assign
    /// each bone to the deepest manager instead (the same bone->manager rule the
    /// audit's rig model uses); to be validated with a runtime probe.
    /// </summary>
    public void Init(List<SwayBoneNative> assignedBones, Func<string, SwayBoneNative> resolveBone)
    {
        if (initialized) return;
        initialized = true;

        if (assignedBones != null)
        {
            // Resolve sideLink before sideLink2 so both directions exist.
            for (var i = 0; i < assignedBones.Count; i++)
            {
                var bone = assignedBones[i];
                if (bone == null) continue;
                if (!string.IsNullOrEmpty(bone.sideLinkPath))
                {
                    bone.sideLink = resolveBone(bone.sideLinkPath);
                    bone.sideLinkPath = null;
                }
            }
            for (var i = 0; i < assignedBones.Count; i++)
            {
                var bone = assignedBones[i];
                if (bone != null && bone.sideLink != null)
                    bone.sideLink.sideLink2 = bone;
            }
        }

        swayBones = assignedBones != null ? assignedBones.ToArray() : Array.Empty<SwayBoneNative>();
        for (var i = 0; i < swayBones.Length; i++)
        {
            var bone = swayBones[i];
            if (bone == null) continue;
            bone.SetManager(this, Category);
            bone.swbIndex = i;
            bone.owner = this;
        }

        // Native: manager BodyScale/BaseTr found in Awake; squared limits from
        // localScale.x (0x1C810CC tail).
        var scale = BodyScale != null ? BodyScale.localScale.x : 1f;
        sqrLineMoveLimit = (lineMoveLimit * scale) * (lineMoveLimit * scale);
        sqrSidelineMoveLimit = (sidelineMoveLimit * scale) * (sidelineMoveLimit * scale);

        // Skirt L1/L2 buckets exist in the native class but SwayManager.Init in
        // this build only fills one list (the recursive collector appends to the
        // first list only); keep empty for parity.
        skirtL1 = Array.Empty<SwayBoneNative>();
        skirtL2 = Array.Empty<SwayBoneNative>();

        UpdateParameters();
    }

    private void ResetColliderFrameFlags()
    {
        if (swayBones == null) return;
        for (var i = 0; i < swayBones.Length; i++)
        {
            var bone = swayBones[i];
            if (bone == null || bone.colliders == null) continue;
            for (var c = 0; c < bone.colliders.Length; c++)
            {
                var set = bone.colliders[c];
                if (set != null && set.c != null) set.c.m_exec_ok = false;
            }
        }
    }

    /// <summary>
    /// SwayManager.UpdateParameters 0x1C816F8: copy stiffness/drag/follow/gravity
    /// into bones with refParam == Manager.
    /// </summary>
    public void UpdateParameters()
    {
        if (swayBones == null) return;
        for (var i = 0; i < swayBones.Length; i++)
        {
            var bone = swayBones[i];
            if (bone == null) continue;
            if (bone.refParam != SwayRefType.Manager) continue;
            bone.stiffnessForce = stiffnessForce;
            bone.dragForce = dragForce;
            bone.followForce = followForce;
            bone.gravity = gravity;
        }
    }

    /// <summary>
    /// SwayManager.PrepareUpdate 0x1CEFA50 (old 0x1C81A08): 60 Hz accumulator on
    /// Time.realtimeSinceStartup, the native m_delta_time blend/clamp
    /// [1/60, 0.025], per-bone h/cc/colliderInx reset, then the LiveParams
    /// skirt-fall classification (inert while LiveSettings.inst is null).
    /// </summary>
    public void PrepareUpdate()
    {
        var now = Time.realtimeSinceStartup;
        localDelta = (now - lastTime) + localDelta;
        lastTime = now;
        if (localDelta < 0f)
        {
            localDelta = 0f;
            return;
        }
        // SwayCollider.Update 0x1C73FE8 clears m_exec_ok every Unity frame; the
        // manager's own step may be gated by the 1/60 accumulator, so this reset
        // must live before the fixed-step early-out.
        ResetColliderFrameFlags();

        if (localDelta < SwayConstants.FIXED_DELTA) return;

        localDelta -= 0.01666f;
        if (localDelta > 1f) localDelta = 0f;

        // Native: m_delta_time = clamp(old + (Time.deltaTime - old) *
        // Time.deltaTime, FIXED_DELTA, MAX_DELTA). Time.deltaTime is read twice
        // on purpose (the second read is the multiplier).
        var dt = Time.deltaTime;
        var blended = m_delta_time + (dt - m_delta_time) * Time.deltaTime;
        var clamped = blended <= SwayConstants.MAX_DELTA ? blended : SwayConstants.MAX_DELTA;
        m_delta_time = blended >= SwayConstants.FIXED_DELTA ? clamped : SwayConstants.FIXED_DELTA;

        if (swayBones == null || !on) return;
        for (var i = 0; i < swayBones.Length; i++)
        {
            var bone = swayBones[i];
            if (bone == null) continue;
            // Native PrepareUpdate writes h = Vector3.zero, cc = Vector3.zero,
            // colliderInx = -1 for every bone (0x1CEFA50 inner loop).
            bone.h = Vector3.zero;
            bone.cc = Vector3.zero;
            bone.colliderInx = -1;
        }

        // Native tail: when LiveSettings.inst.live != null and its
        // SkirtFollow100EnableByYpos (0xD8) is set, SkirtFallFollow (0x78) =
        // BaseTr.position.y >= live.fallLimit (0xE0), flagging
        // isSkirtFallFollowChanged (0x79) on change. The LiveParams asset is not
        // shipped with character bundles (research doc §8), so inst is null in
        // the spike and the serialized SkirtFallFollow stays untouched.
        var liveSettings = LiveSettingsNative.inst;
        if (liveSettings != null && liveSettings.live != null
            && liveSettings.live.SkirtFollow100EnableByYpos && BaseTr != null)
        {
            var follow = BaseTr.position.y >= liveSettings.live.fallLimit;
            if (SkirtFallFollow != follow)
            {
                SkirtFallFollow = follow;
                isSkirtFallFollowChanged = true;
            }
        }
    }

    /// <summary>
    /// Stand-ins for `Imas.Live.LiveSettings` / `Imas.Live.LiveParams` (the
    /// PrepareUpdate tail reads `LiveSettings.inst` static field 0 and
    /// `live` at 0x20). Character bundles do not carry the Live ScriptableObject
    /// (research doc §8), so `inst` stays null in the spike; a future Live host
    /// can assign it to enable the native skirt-fall path.
    /// </summary>
    public sealed class LiveParamsNative
    {
        public bool SkirtFollow100EnableByYpos;   // 0xD8
        public float fallLimit;                   // 0xE0
    }

    public sealed class LiveSettingsNative
    {
        public static LiveSettingsNative inst;    // 0x0 static field
        public LiveParamsNative live;             // 0x20
    }

    /// <summary>
    /// SwayManager.ExecuteUpdate 0x1C81CD8: the four ordered passes.
    /// </summary>
    public void ExecuteUpdate(float deltaTime)
    {
        if (swayBones == null || swayBones.Length == 0) return;
        ctrl.ExecuteSerial(swayBones, deltaTime);
    }

    /// <summary>SwayManager.PostUpdate 0x1C81E40: FinishRotate (CalcRotate) pass.</summary>
    public void PostUpdate()
    {
        if (swayBones == null) return;
        for (var i = 0; i < swayBones.Length; i++)
        {
            var bone = swayBones[i];
            if (bone == null) continue;
            bone.FinishRotate();
        }
    }

    /// <summary>SwayManager.SetTemporaryStiffnessForce 0x1C81F00.</summary>
    public void SetTemporaryStiffnessForce(float value)
    {
        if (swayBones == null) return;
        for (var i = 0; i < swayBones.Length; i++)
        {
            var bone = swayBones[i];
            if (bone != null) bone.stiffnessForce = value;
        }
    }

    /// <summary>
    /// SwayManager.LateUpdate 0x1C817F0. Native skips when the global character
    /// manager object is inactive (sub_35D9C14 0x35D9C14 = !activeSelf); the
    /// spike has no such singleton, so the equivalent gate is this component
    /// being enabled plus (!swayOn only when a JointBodyHead exists).
    /// </summary>
    private void LateUpdate()
    {
        // Editor-workflow self-heal: `bones`/`swayBones` are plain-class lists
        // that a play-mode domain reload wipes (the component survives, the
        // state does not). Native has no hot reload; without this the skirt
        // becomes a rigid shell and the legs punch through it, which is what
        // was repeatedly mistaken for a physics bug during watch sessions.
        if ((swayBones == null || swayBones.Length == 0) && rig != null)
        {
            rig.RebuildIfEmpty();
            if (swayBones == null || swayBones.Length == 0) return;
        }
        if (!GlobalSwayActive()) return;
        if (!on) return;
        if (!swayOn) return; // JointBodyHead.swayOn 0x104

        PrepareUpdate();
        if (!on) return;

        ExecuteUpdate(m_delta_time);
        PostUpdate();

        // forceUpdate: repeat the whole step with the forced dt
        // (SwayManager.forceUpdate 0xC8 / deltaTimeForForceUpdateInframe 0xD0).
        if (forceUpdate > 0)
        {
            var count = 0;
            var transBack = swayTransBack;
            swayTransBack = false;
            while (count < forceUpdate)
            {
                PrepareUpdate();
                ExecuteUpdate(deltaTimeForForceUpdateInframe);
                PostUpdate();
                count++;
            }
            swayTransBack = transBack;
            forceUpdate = 0;
        }
    }

    private static bool GlobalSwayActive()
    {
        // sub_35D9C14 checks a global singleton GameObject active state; there
        // is no equivalent in the spike. Treat "active" as always true so the
        // normal path runs (documented UNKNOWN in the report).
        return true;
    }

    /// <summary>
    /// SwayManager.GetWind 0x1CEFFB0 (old 0x1C81F68): sums every registered
    /// ISwayWind whose winds_use[i] is set, then scales the sum by
    ///   * 1.3f when an unresolved static no-arg bool predicate is true
    ///     (sub_3695F10(0), class off_97BDA50; the report maps it to a
    ///     quality/high-end setting), or
    ///   * (QualityLevel - 1) * 0.3f + 1f otherwise (sub_714EAB4 = quality level).
    /// Character bundles register no wind sources (research doc §9), so in story
    /// playback the loop body never runs and this returns Vector3.zero before the
    /// factor matters; the aggregation/factor are kept for Live parity only.
    /// UNKNOWN(native 0x1CEFFB0): the exact identity of the off_97BDA50 static
    /// predicate (sub_3695F10); the spike returns true (GlobalSwayActive) so the
    /// native 1.3 branch is modelled.
    /// </summary>
    public Vector3 GetWind(Vector3 position)
    {
        if (winds == null || winds.Count == 0) return Vector3.zero;
        var sum = Vector3.zero;
        for (var i = 0; i < winds.Count && i < SwayConstants.WIND_MAX; i++)
        {
            if (winds[i] == null || !winds_use[i]) continue;
            sum += winds[i].GetWind(position);
        }
        var factor = GlobalSwayActive() ? 1.3f : (QualitySettings.GetQualityLevel() - 1f) * 0.3f + 1f;
        return sum * factor;
    }

    public readonly List<ISwayWindNative> winds = new List<ISwayWindNative>();
    private readonly bool[] winds_use = new bool[SwayConstants.WIND_MAX];

    public void SetWind(ISwayWindNative wind, int idx = 0)
    {
        if (idx < 0 || idx >= SwayConstants.WIND_MAX) return;
        if (winds.Count <= idx) while (winds.Count <= idx) winds.Add(null);
        winds[idx] = wind;
        winds_use[idx] = wind != null;
    }

    // -------- per-category runtime arrays (JointBodyHead / IdolPositionMgr) --------

    public float GetFollowRate(int category)
    {
        return swayFollowRate != null && category >= 0 && category < swayFollowRate.Length
            ? swayFollowRate[category] : 0f;
    }

    public bool GetFollowSW(int category)
    {
        return swayFollowSW != null && category >= 0 && category < swayFollowSW.Length && swayFollowSW[category];
    }

    public float GetDamper(int category)
    {
        if (swayDamper == null || category < 0 || category >= swayDamper.Length) return 1f;
        return swayDamper[category];
    }

    public Vector3 GetVecs1(int category)
    {
        return vecs1 != null && category >= 0 && category < vecs1.Length ? vecs1[category] : Vector3.zero;
    }

    private void OnDrawGizmosSelected()
    {
        if (swayBones == null) return;
        Gizmos.color = Color.yellow;
        for (var i = 0; i < swayBones.Length; i++)
        {
            var bone = swayBones[i];
            if (bone == null) continue;
            Gizmos.DrawLine(bone.transform.position, bone.curTipPos);
        }
    }

    public string Describe()
    {
        var sb = new StringBuilder();
        sb.Append("SwayManager(").Append(fileName).Append(" cat=").Append(Category)
          .Append(" on=").Append(on).Append(" dt=").Append(m_delta_time.ToString("F4"))
          .Append(" bones=").Append(swayBones != null ? swayBones.Length : 0)
          .Append(" BodyScale=").Append(BodyScale != null ? BodyScale.name : "<null>").Append(')');
        return sb.ToString();
    }
}

/// <summary>
/// SwayCtrlMT (dump.cs 15296): in native it owns NativeArrays and starts the
/// Burst jobs. ADR-0033 replaces jobs with serial loops; the container is kept
/// so the array layout/order is still explicit and a later job port can reuse
/// it. The four passes and the hitTwice rule are exactly
/// SwayManager.ExecuteUpdate 0x1C81CD8.
/// </summary>
public sealed class SwayCtrlMTNative
{
    public readonly List<SwayBoneNative> parallelSwbs = new List<SwayBoneNative>();
    public readonly List<SwayFixedParams> fixedParams = new List<SwayFixedParams>();
    public readonly List<SwayWorkingParams> workingParams = new List<SwayWorkingParams>();
    public readonly List<SwaySideLinkParams> sideLinkParams = new List<SwaySideLinkParams>();
    public readonly List<SwayColliderParams> colliderParams = new List<SwayColliderParams>();
    public readonly List<SwayColliderIndexParams> colliderIndexParams = new List<SwayColliderIndexParams>();

    /// <summary>
    /// SwayCtrlMT.InitializeParallelSway 0x1C6E2D8 (array allocation) reduced to
    /// the serial port: snapshots the structs for probes and future job use.
    /// </summary>
    public void InitializeParallelSway(SwayBoneNative[] bones)
    {
        parallelSwbs.Clear();
        fixedParams.Clear();
        workingParams.Clear();
        sideLinkParams.Clear();
        colliderParams.Clear();
        colliderIndexParams.Clear();
        if (bones == null) return;
        for (var i = 0; i < bones.Length; i++)
        {
            var bone = bones[i];
            if (bone == null) continue;
            parallelSwbs.Add(bone);
            fixedParams.Add(bone.BuildFixedParams());
            workingParams.Add(bone.BuildWorkingParams());
            sideLinkParams.Add(new SwaySideLinkParams
            {
                tipTrsPosition = bone.tipTrs != null ? bone.tipTrs.position : bone.transform.position,
                tipTrsLocalPosition = bone.tipTrs != null ? bone.tipTrs.localPosition : Vector3.zero,
                sideLinkTipTrsPosition = bone.sideLink != null && bone.sideLink.tipTrs != null
                    ? bone.sideLink.tipTrs.position : Vector3.zero,
            });
            var idx = SwayColliderIndexParams.Create();
            var sets = bone.colliders;
            idx.numOfColliders = sets != null ? Mathf.Min(sets.Length, SwayColliderIndexParams.MAX_COLLIDERS) : 0;
            for (var c = 0; c < idx.numOfColliders; c++)
            {
                var set = sets[c];
                if (set == null || set.c == null) { idx.index[c] = -1; continue; }
                idx.index[c] = colliderParams.Count;
                colliderParams.Add(set.c.ToParams());
            }
            colliderIndexParams.Add(idx);
        }
    }

    /// <summary>
    /// SwayCtrlMT.ExecuteParallelSway 0x1C6CFD0 / SwayCtrlAllMT job order,
    /// serialised. Native job chain:
    ///   CopyColliderBridgetgtPositionJob, UpdateColliderJob,
    ///   CopySideLinkInfoJob, CalcSideLineDistanceJob, CalcAntiFoldForceJob,
    ///   SwayMoveJob, CopyParentRotationJob, SwayHitJob, FinishRotateJob.
    /// The manager already drives FinishRotate in PostUpdate, so this method
    /// runs the four SwayManager.ExecuteUpdate passes only.
    /// </summary>
    public void ExecuteSerial(SwayBoneNative[] bones, float deltaTime)
    {
        if (bones == null) return;

        // SwayCtrlMT.UpdateColliderJob / SwayColliderMT.ExecUpdate: geometry is
        // refreshed lazily by SwayColliderNative.Check (m_exec_ok), which is the
        // same "once per frame" contract.
        for (var i = 0; i < bones.Length; i++)
        {
            var bone = bones[i];
            if (bone == null) continue;
            bone.CalcSideLineDistance();
        }
        for (var i = 0; i < bones.Length; i++)
        {
            var bone = bones[i];
            if (bone == null) continue;
            bone.CalcAntiFoldForce();
        }
        for (var i = 0; i < bones.Length; i++)
        {
            var bone = bones[i];
            if (bone == null) continue;
            bone.curTipPos = bone.SwayMove(deltaTime);
        }
        for (var i = 0; i < bones.Length; i++)
        {
            var bone = bones[i];
            if (bone == null) continue;
            bone.SwayHit();
            if (bone.hitTwice) bone.SwayHit();
        }
    }
}

/// <summary>Native ISwayWind, character-bundle wind is stage-driven (out of scope).</summary>
public interface ISwayWindNative
{
    Vector3 GetWind(Vector3 position);
}

/// <summary>
/// Entry point replacing the old SwayRig + SwayPhysics pair. Build one per
/// character, passing the body and head `_sway` files; it merges them into a
/// single rig in the exact SwayFileIO.ImportCommon order.
/// </summary>
public sealed class SwayRigNative : MonoBehaviour
{
    public SwayFileNative bodyFile;
    public SwayFileNative headFile;
    public readonly List<SwayManagerNative> managers = new List<SwayManagerNative>();
    public readonly List<SwayBoneNative> bones = new List<SwayBoneNative>();
    public readonly List<SwayColliderNative> colliders = new List<SwayColliderNative>();

    private readonly Dictionary<string, Transform> transforms = new Dictionary<string, Transform>(StringComparer.Ordinal);
    private readonly Dictionary<string, SwayBoneNative> bonesByPath = new Dictionary<string, SwayBoneNative>(StringComparer.Ordinal);
    private readonly Dictionary<string, List<SwayColliderNative>> collidersByJointPath =
        new Dictionary<string, List<SwayColliderNative>>(StringComparer.Ordinal);
    public Transform BodyScale;
    private Func<Transform, Quaternion> bindRotationProvider;

    /// <summary>
    /// SwayFileIO.ImportCommon 0x1C764FC equivalent. Attach order matters:
    /// managers (body, head) -> colliders (body with skirtGuardOffset, head 0)
    /// -> bones (body, head) -> manager init -> bone init -> side-link rest
    /// distances. All components live under the same `root` (the body object).
    /// </summary>
    public static SwayRigNative Build(Transform root, SwayFileNative body, SwayFileNative head,
        float skirtGuardOffset = 0f, Func<Transform, Quaternion> bindRotationProvider = null)
    {
        var rig = root.GetComponent<SwayRigNative>();
        if (rig == null) rig = root.gameObject.AddComponent<SwayRigNative>();
        rig.bodyFile = body;
        rig.headFile = head;
        rig.bindRotationProvider = bindRotationProvider;
        rig.BuildInternal(skirtGuardOffset);
        return rig;
    }

    /// <summary>
    /// Editor-workflow self-heal (domain reload wipes the plain-class lists):
    /// rebuild every manager's bone assignment from the surviving data files.
    /// No-op when the lists are intact.
    /// </summary>
    public void RebuildIfEmpty()
    {
        if (bones.Count > 0 || managers.Count == 0) return;
        if (bodyFile == null) return;
        BuildInternal(0f);
    }

    private void BuildInternal(float skirtGuardOffset)
    {
        managers.Clear();
        bones.Clear();
        colliders.Clear();
        transforms.Clear();
        bonesByPath.Clear();
        collidersByJointPath.Clear();

        IndexTransforms(transform);

        BodyScale = FindTransformByName(transform, "BODY_SCALE");
        if (BodyScale == null) BodyScale = FindTransformByName(transform, "BASE");
        if (BodyScale == null) BodyScale = FindTransformByName(transform, "Base");
        if (BodyScale == null) BodyScale = transform;

        // 1) managers: body first, then head (ImportCommon order).
        managerEntries.Clear();
        AttachManagers(bodyFile);
        AttachManagers(headFile);

        // 2) colliders: body (with skirtGuardOffset) then head (0).
        AttachColliders(bodyFile, skirtGuardOffset);
        AttachColliders(headFile, 0f);

        // 3) bones: body then head. Global merged order = attachment order.
        AttachBones(bodyFile);
        AttachBones(headFile);

        // 4) resolve `<joint>#k` against the per-joint component list, exactly
        //    like AttachSwayBone 0x1C7726C (FindObjectByPath + GetComponents).
        ResolveColliderSets();

        // 5) group bones by deepest manager and run manager init.
        for (var i = 0; i < managerEntries.Count; i++)
        {
            var entry = managerEntries[i];
            var assigned = new List<SwayBoneNative>();
            for (var b = 0; b < bones.Count; b++)
            {
                var bone = bones[b];
                if (bone == null || bone.data == null) continue;
                if (DeepestManagerPath(bone.data.path) != entry.path) continue;
                assigned.Add(bone);
            }
            entry.manager.Init(assigned, ResolveBone);
            entry.manager.rig = this;
        }

        // 6) bones Init (SwayFileIO.InitSwayBones 0x1C75970) then side-link rest
        //    distance (CalcSideLinkDistance 0x1C716E8) for every bone.
        for (var i = 0; i < bones.Count; i++)
        {
            var bone = bones[i];
            if (bone == null) continue;
            bone.Init();
        }
        for (var i = 0; i < bones.Count; i++)
        {
            var bone = bones[i];
            if (bone == null) continue;
            bone.CalcSideLinkDistance();
        }
        for (var i = 0; i < bones.Count; i++)
        {
            var bone = bones[i];
            if (bone == null) continue;
            bone.RefreshCollidersEnable();
        }

        // 7) SwayCtrlMT.InitializeParallelSway 0x1C6E2D8 snapshots.
        for (var i = 0; i < managers.Count; i++)
        {
            var m = managers[i];
            if (m == null) continue;
            m.ctrl.InitializeParallelSway(m.swayBones);
        }
    }

    private struct ManagerEntry
    {
        public SwayManagerNative manager;
        public string path;
        public SwayCategory category;
    }

    private readonly List<ManagerEntry> managerEntries = new List<ManagerEntry>();

    private void AttachManagers(SwayFileNative file)
    {
        if (file == null) return;
        for (var i = 0; i < file.managers.Count; i++)
        {
            var p = file.managers[i];
            var category = CategoryForPath(p.path);
            var duplicate = false;
            for (var m = 0; m < managerEntries.Count; m++)
                if (managerEntries[m].path == p.path) { duplicate = true; break; }
            if (duplicate) continue;

            var node = ResolveTransform(transform, p.path, file == headFile);
            if (node == null) node = transform;
            var mgr = node.GetComponent<SwayManagerNative>();
            // Native AddComponent allows several managers on one node; the data
            // never does, so reuse the component if Build is called twice.
            if (mgr == null) mgr = node.gameObject.AddComponent<SwayManagerNative>();
            mgr.Attach(p, category);
            if (mgr.BodyScale == null) mgr.BodyScale = BodyScale;
            if (mgr.BaseTr == null) mgr.BaseTr = BodyScale;
            managers.Add(mgr);
            managerEntries.Add(new ManagerEntry { manager = mgr, path = p.path, category = category });
        }
    }

    private void AttachColliders(SwayFileNative file, float skirtGuardOffset)
    {
        if (file == null) return;
        var perJoint = new Dictionary<Transform, List<SwayColliderNative>>();
        for (var i = 0; i < file.colliders.Count; i++)
        {
            var p = file.colliders[i];
            var joint = ResolveTransform(transform, p.path, file == headFile);
            if (joint == null)
            {
                Debug.LogWarning("SwayNative: no transform for collider " + p.path);
                continue;
            }
            var c = joint.gameObject.AddComponent<SwayColliderNative>();
            c.Attach(p, transform, BodyScale, skirtGuardOffset);
            colliders.Add(c);

            List<SwayColliderNative> list;
            if (!perJoint.TryGetValue(joint, out list))
            {
                list = new List<SwayColliderNative>();
                perJoint[joint] = list;
            }
            list.Add(c);

            // Also key by the text joint path: bone refs are written with the
            // game's path (`MODEL_00/BODY_SCALE/...`), which may resolve to the
            // same transform via a different spelling after BODY_SCALE removal.
            List<SwayColliderNative> pathList;
            if (!collidersByJointPath.TryGetValue(p.path, out pathList))
            {
                pathList = new List<SwayColliderNative>();
                collidersByJointPath[p.path] = pathList;
            }
            pathList.Add(c);
        }
    }

    private void AttachBones(SwayFileNative file)
    {
        if (file == null) return;
        for (var i = 0; i < file.bones.Count; i++)
        {
            var p = file.bones[i];
            var trs = ResolveTransform(transform, p.path, file == headFile);
            if (trs == null)
            {
                Debug.LogWarning("SwayNative: no transform for bone " + p.path);
                continue;
            }
            var bone = trs.gameObject.GetComponent<SwayBoneNative>();
            if (bone == null) bone = trs.gameObject.AddComponent<SwayBoneNative>();
            // The manager is assigned later from the merged manager list.
            bone.Attach(p, null, BodyScale, -1);
            bone.bindRotationProvider = bindRotationProvider;
            bones.Add(bone);
            bonesByPath[p.path] = bone;
        }
    }

    private void ResolveColliderSets()
    {
        for (var i = 0; i < bones.Count; i++)
        {
            var bone = bones[i];
            if (bone == null || bone.colliders == null) continue;
            for (var s = 0; s < bone.colliders.Length; s++)
            {
                var set = bone.colliders[s];
                if (set == null || string.IsNullOrEmpty(set.path)) continue;
                List<SwayColliderNative> list;
                if (!collidersByJointPath.TryGetValue(set.path, out list))
                {
                    // Reference may use the pre-BODY_SCALE spelling; resolve the
                    // joint and look it up by transform.
                    var joint = ResolveTransform(transform, set.path);
                    if (joint != null)
                    {
                        var byTransform = new List<SwayColliderNative>();
                        for (var c = 0; c < colliders.Count; c++)
                            if (colliders[c] != null && colliders[c].transform == joint) byTransform.Add(colliders[c]);
                        list = byTransform;
                    }
                }
                if (list == null || set.n < 0 || set.n >= list.Count)
                {
                    Debug.LogWarning("SwayNative: unresolved collider ref " + set.raw + " on " + bone.name);
                    continue;
                }
                set.c = list[set.n];
            }
        }
    }

    /// <summary>Deepest manager path that is an ancestor of `bonePath` among both files.</summary>
    private string DeepestManagerPath(string bonePath)
    {
        string best = null;
        var bestLen = -1;
        for (var i = 0; i < managerEntries.Count; i++)
        {
            var p = managerEntries[i].path;
            if (string.IsNullOrEmpty(p)) continue;
            if (bonePath != p && !bonePath.StartsWith(p + "/", StringComparison.Ordinal)) continue;
            if (p.Length > bestLen) { best = p; bestLen = p.Length; }
        }
        return best;
    }

    private SwayBoneNative ResolveBone(string path)
    {
        SwayBoneNative bone;
        return bonesByPath.TryGetValue(path, out bone) ? bone : null;
    }

    private static Transform FindTransformByName(Transform root, string name)
    {
        foreach (var t in root.GetComponentsInChildren<Transform>(true))
            if (string.Equals(t.name, name, StringComparison.Ordinal)) return t;
        return null;
    }

    private void IndexTransforms(Transform root)
    {
        foreach (var t in root.GetComponentsInChildren<Transform>(true))
        {
            var parts = new List<string>();
            var cursor = t;
            var rooted = false;
            while (cursor != null)
            {
                parts.Add(cursor.name);
                if (cursor.name == "MODEL_00") { rooted = true; break; }
                cursor = cursor.parent;
            }
            if (!rooted) continue;
            parts.Reverse();
            var path = string.Join("/", parts);
            transforms[path] = t;
            // Also index without the BODY_SCALE segment (spike prefab drops it,
            // SwayRig.Resolve's first fallback in the old port).
            var trimmed = path.Replace("/BODY_SCALE", "");
            if (trimmed != path) transforms[trimmed] = t;
            // Also index without MODEL_00 prefix so a root named MODEL_00 works.
            var noRoot = path.StartsWith("MODEL_00/") ? path.Substring("MODEL_00/".Length) : path;
            transforms[noRoot] = t;
        }
    }

    /// <summary>
    /// SwayFileIO.ReadPath/FindObjectByPath equivalent: direct path, then the
    /// BODY_SCALE removal, then the head nesting that the spike prefab introduces
    /// (ch_head/KUBI/ATAMA inserted under the body ATAMA — audit §7.2).
    /// </summary>
    public static Transform ResolveTransform(Transform root, string path, bool preferHead = false)
    {
        if (string.IsNullOrEmpty(path)) return null;
        var trimmed = path.Replace("/BODY_SCALE", "");
        string head = null;
        if (trimmed.IndexOf("/ch_head/", StringComparison.Ordinal) < 0)
        {
            // The head prefab is instantiated under the body's ATAMA and
            // renamed ch_head; the game's head sway paths skip that node
            // (audit §7.2). Insert it after the first KUBI/ATAMA so both head
            // bones (.../KUBI/ATAMA/HAIR/...) and head colliders on ATAMA
            // (.../KUBI/ATAMA) resolve into the nested rig.
            const string pivot = "/KUBI/ATAMA";
            var idx = trimmed.IndexOf(pivot, StringComparison.Ordinal);
            if (idx >= 0)
                head = trimmed.Insert(idx + pivot.Length, "/ch_head/KUBI/ATAMA");
        }

        var rig = root.GetComponent<SwayRigNative>();
        if (rig != null)
        {
            // Head stanzas must prefer the nested head rig: the body and head
            // prefabs both contain KUBI/ATAMA, and the trimmed body path would
            // otherwise shadow the head bones (audit §7.2).
            if (preferHead && head != null)
            {
                Transform t;
                if (rig.transforms.TryGetValue(head, out t)) return t;
            }
            {
                Transform t;
                if (rig.transforms.TryGetValue(path, out t)) return t;
                if (rig.transforms.TryGetValue(trimmed, out t)) return t;
                if (head != null && rig.transforms.TryGetValue(head, out t)) return t;
            }
        }
        // Fallback for callers before the rig component exists.
        var all = root.GetComponentsInChildren<Transform>(true);
        for (var i = 0; i < all.Length; i++)
        {
            var name = all[i].name;
            if (name == trimmed || name == path || (head != null && name == head)) return all[i];
        }
        return null;
    }

    /// <summary>Category rule used for SetManager (native tag checks are UNKNOWN; see SwayBone.SetManager).</summary>
    public static SwayCategory CategoryForPath(string path)
    {
        if (string.IsNullOrEmpty(path)) return SwayCategory.Normal;
        if (path.IndexOf("HAIR", StringComparison.OrdinalIgnoreCase) >= 0) return SwayCategory.Hair;
        if (path.IndexOf("skirt", StringComparison.OrdinalIgnoreCase) >= 0) return SwayCategory.Skirt;
        if (path.IndexOf("OPAI", StringComparison.OrdinalIgnoreCase) >= 0) return SwayCategory.Opai;
        return SwayCategory.Normal;
    }

    /// <summary>Editor/probe hook: force one fixed step (used by verification).</summary>
    public void StepOnce(float dt)
    {
        for (var i = 0; i < managers.Count; i++)
        {
            var m = managers[i];
            if (m == null) continue;
            m.PrepareUpdate();
            m.ExecuteUpdate(dt);
            m.PostUpdate();
        }
    }

    /// <summary>Audit probe: the bone→collider map that P0-1/P0-2 needed.</summary>
    public string Describe()
    {
        var sb = new StringBuilder();
        sb.Append("SwayRigNative managers=").Append(managers.Count)
          .Append(" bones=").Append(bones.Count).Append(" colliders=").Append(colliders.Count)
          .Append(" BodyScale=").Append(BodyScale != null ? BodyScale.name : "<null>").AppendLine();
        for (var i = 0; i < managers.Count; i++)
            if (managers[i] != null) sb.Append("  ").AppendLine(managers[i].Describe());
        for (var i = 0; i < bones.Count; i++)
            if (bones[i] != null) sb.Append("  ").AppendLine(bones[i].DescribeRefs());
        return sb.ToString();
    }
}
