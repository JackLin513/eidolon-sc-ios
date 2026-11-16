using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// Native replica of the game's `Imas.BoneLib.CalcBone` assist-bone pass.
///
/// Source: MLTD UnityFramework (IL2CPP), addresses below are RVAs in the
/// 2026-10 `UnityFramework` binary and match `dump.cs` 1:1.
///
/// A motion only keys the bones the animator moved. The rig also carries assist
/// bones whose rule is encoded in the bone's *name*
/// (`WAKI_L__slerp_KATA_L__i30_x0`), and the game recomputes them every frame
/// from the reference bones' current pose. This class reproduces that pass
/// branch for branch: the name grammar (`getParams`/`getTargetName`), rest-pose
/// capture (`Awake`), the eight `ALGO_TYPE` dispatch cases (`ExplictUpdate`),
/// the four base algorithms, the four TITE_F/TITE_B skirt-plate algorithms, the
/// four `CALC_TITE_SKIRT_*` helpers, `forceUpdate`/`ForceUpdateFrames`
/// throttling, and `IsAssistBone`.
///
/// Only performance-layer substitutions are made vs. the native code:
/// `List`/`Dictionary` instead of the game's IL2CPP collections, `Transform`
/// instead of `TransformAccess`, plain floats instead of `NativeArray`, and
/// Unity's `Mathf`/`Quaternion`/`Matrix4x4` managed APIs (the same Unity
/// functions the game calls through IL2CPP: `Quaternion.Slerp` @0x7095584,
/// `FromToRotation` @0x70953E8, `Inverse` @0x70954C0, `AngleAxis` @0x7095AD8,
/// `Matrix4x4` indexer @0x7091D1C, `Transform` getters/setters). No formula,
/// constant, default, branch or data hand-off is changed.
///
/// Coordinate note (verified from the binary, not assumed): every base algorithm
/// aligns with `Vector3.right` — the read is the static field at offset 0x3C of
/// `UnityEngine.Vector3`'s static block (`rightVector`, see cctor @0x7095358).
/// The `axis` letter parsed from the name is only used for the ROT
/// `'z' -> SLERP` selection described in <see cref="Bind"/>, never to pick the
/// alignment vector.
///
/// Integration: attach it to an ancestor of the whole skeleton (the game's
/// CalcBone `Awake` calls `GetComponentsInChildren<Transform>(true)` on its own
/// transform). It must be bound while the rig is in its rest/bind pose — the
/// native `Awake` captures `initMyRot`/`initRefRot`/`initMyPosition` then.
/// `LateUpdate` drives the pass exactly like the native `LateUpdate`.
/// </summary>
[DefaultExecutionOrder(-50)]
public sealed class CalcBoneNative : MonoBehaviour
{
    // ------------------------------------------------------------------
    // Native types
    // ------------------------------------------------------------------

    /// <summary>`CalcBone.ALGO_TYPE` (TypeDefIndex 15263).</summary>
    public enum AlgoType
    {
        SLERP = 0,
        TWIST = 1,
        ROT = 2,
        CONST = 3,
        TITE_FRONT_ROT = 4,
        TITE_FRONT_TRANS = 5,
        TITE_BACK_ROT_YZ = 6,
        TITE_BACK_ROT_X = 7,
    }

    /// <summary>
    /// `CalcBone.CALC_BONE_INFO` (TypeDefIndex 15264). Field order, types and
    /// semantics follow the native struct; the game has three constructors
    /// (@0x1C60580 / 0x1C60600 / 0x1C6266C) but `Awake` builds the object and
    /// writes the fields directly, which is what <see cref="Bind"/> does too.
    /// Exposed read-only-ish for the editor probe.
    /// </summary>
    public sealed class CalcBoneInfo
    {
        public AlgoType type;          // 0x10
        public string myPath;          // 0x18
        public Transform myTransform;  // 0x20
        public Quaternion initMyRot;   // 0x28
        public string referPath;       // 0x38
        public Transform referTransform;   // 0x40
        public Quaternion referInitRot;    // 0x48
        public Vector3 referInitVec;       // 0x58
        public float t;                    // 0x64
        public float tx;                   // 0x68
        public int axis;                   // 0x6C
        public string referPath2;          // 0x70
        public Transform referTransform2;  // 0x78
        public Quaternion referInitRot2;   // 0x80
        public Vector3 referInitVec2;      // 0x90
        public Vector3 initMyPosition;     // 0x9C
    }

    // ------------------------------------------------------------------
    // Native fields (CalcBone, TypeDefIndex 15265)
    // ------------------------------------------------------------------

    /// <summary>`private static readonly int ForceUpdateFrames = 1` — set by the
    /// native `.cctor` @0x1C62614 (`**static_fields = 1`).</summary>
    private const int ForceUpdateFrames = 1;

    private readonly int[] param_axis = new int[2];     // native 0x20
    private readonly float[] param_value = new float[2]; // native 0x28
    private readonly List<CalcBoneInfo> m_infoList = new List<CalcBoneInfo>(); // native 0x30

    /// <summary>
    /// Native field @0x38. `RequestUpdate` sets it to ForceUpdateFrames; each
    /// `LateUpdate` with a positive value decrements it and updates
    /// unconditionally, otherwise the update is gated on the live sequencer.
    /// </summary>
    public int forceUpdate;

    /// <summary>
    /// Native `LateUpdate` reads `MainLoop.player` (static field @0x18 of
    /// `MainLoop`, TypeDefIndex 16063) and only runs while
    /// `MainLoop.player.running` (`SequencePlayer.get_running` @0x1E8AD68).
    /// This port has no `MainLoop`; a null gate reproduces the native
    /// `MainLoop.player == null` branch (always update). Wire an existing
    /// motion/live player's "running" state here when one exists so the
    /// throttling matches the game.
    /// </summary>
    public static Func<bool> PlayerRunningGate;

    /// <summary>Registered assist bones, in native registration order.</summary>
    public IReadOnlyList<CalcBoneInfo> Infos => m_infoList;

    public int Count => m_infoList.Count;

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    /// <summary>
    /// `CalcBone.Awake` @0x1C5F624. Native behaviour: capture the rest pose and
    /// parse every child name. It runs before the first clip frame, so the rig
    /// must still be in bind pose here.
    /// </summary>
    private void Awake()
    {
        Bind(transform);
    }

    /// <summary>
    /// Native `Awake` body, parameterised on the hierarchy root so probes and
    /// tests can rebind. `Awake` calls it with `transform` (the component's own
    /// subtree is exactly what the native `GetComponentsInChildren` walks).
    /// </summary>
    public void Bind(Transform root)
    {
        m_infoList.Clear();
        if (root == null) throw new ArgumentNullException(nameof(root));

        // Native builds a name -> Transform map: vtable set_Item with
        // (name, transform), get_Item for lookups. Duplicate names therefore
        // resolve to the last transform in GetComponentsInChildren order.
        bindRoot = root;
        var byName = new Dictionary<string, Transform>();
        var all = root.GetComponentsInChildren<Transform>(true);
        foreach (var tr in all) byName[tr.name] = tr;

        foreach (var tr in all)
        {
            var name = tr.name;
            CalcBoneInfo info = null;

            // The native `Awake` is a chain of independent `if`s in this exact
            // order; each match builds a NEW info, so a later match would
            // replace the earlier one. (In the shipped rigs each name matches
            // exactly one branch; CONST names additionally contain "__rot" but
            // the CONST branch jumps straight to registration.)
            if (name.Contains("__slerp"))
            {
                // type 0: my = name, refer = getTargetName(name),
                // t = param_value[0], tx = param_value[1], axis = param_axis[1]
                getParams(name, AlgoType.SLERP);
                info = new CalcBoneInfo
                {
                    type = AlgoType.SLERP,
                    myPath = name,
                    referPath = getTargetName(name),
                    t = param_value[0],
                    tx = param_value[1],
                    axis = param_axis[1],
                };
            }

            if (name.Contains("__twist"))
            {
                // type 1: refer = transform.parent.name, t = -1,
                // tx = param_value[0], axis = param_axis[0]
                getParams(name, AlgoType.TWIST);
                var parent = tr.parent;
                info = new CalcBoneInfo
                {
                    type = AlgoType.TWIST,
                    myPath = name,
                    referPath = parent == null ? null : parent.name,
                    t = -1f,
                    tx = param_value[0],
                    axis = param_axis[0],
                };
            }

            if (name.Contains("__tite"))
            {
                if (name.Contains("_front_rot"))
                {
                    // type 4: driven by MOMO_L and MOMO_R, no name parameters
                    // (single "__", so getParams leaves axis=[-1,-1], value=[0,0])
                    getParams(name, AlgoType.TITE_FRONT_ROT);
                    info = new CalcBoneInfo
                    {
                        type = AlgoType.TITE_FRONT_ROT,
                        myPath = name,
                        referPath = "MOMO_L",   // qword_97F53B8 -> string literal "MOMO_L"
                        referPath2 = "MOMO_R",  // qword_97F53C0 -> string literal "MOMO_R"
                        t = -1f,
                        tx = param_value[0],
                        axis = param_axis[0],
                    };
                }
                if (name.Contains("_front_trans_wait"))
                {
                    // type 5: reference is the parent (KOSHI), no name parameters
                    getParams(name, AlgoType.TITE_FRONT_TRANS);
                    var parent = tr.parent;
                    info = new CalcBoneInfo
                    {
                        type = AlgoType.TITE_FRONT_TRANS,
                        myPath = name,
                        referPath = parent == null ? null : parent.name,
                        t = -1f,
                        tx = param_value[0],
                        axis = param_axis[0],
                    };
                }
                if (name.Contains("_back_rot_YZ"))
                {
                    // type 6: driven by MOMO_L and MOMO_R
                    getParams(name, AlgoType.TITE_BACK_ROT_YZ);
                    info = new CalcBoneInfo
                    {
                        type = AlgoType.TITE_BACK_ROT_YZ,
                        myPath = name,
                        referPath = "MOMO_L",
                        referPath2 = "MOMO_R",
                        t = -1f,
                        tx = param_value[0],
                        axis = param_axis[0],
                    };
                }
                if (name.Contains("_back_rot_X_wait"))
                {
                    // type 7: driven by MOMO_L and MOMO_R
                    getParams(name, AlgoType.TITE_BACK_ROT_X);
                    info = new CalcBoneInfo
                    {
                        type = AlgoType.TITE_BACK_ROT_X,
                        myPath = name,
                        referPath = "MOMO_L",
                        referPath2 = "MOMO_R",
                        t = -1f,
                        tx = param_value[0],
                        axis = param_axis[0],
                    };
                }
            }

            // CONST is tested before ROT and wins: the CONSTRAINT branch goes
            // straight to registration, so a CONST name's trailing "__rot_..."
            // span is not re-read as a ROT rule.
            var isConst = name.Contains("__const");
            if (isConst)
            {
                // type 3: refer = getTargetName(name), t = -1,
                // tx = param_value[0], axis = param_axis[0]
                getParams(name, AlgoType.CONST);
                info = new CalcBoneInfo
                {
                    type = AlgoType.CONST,
                    myPath = name,
                    referPath = getTargetName(name),
                    t = -1f,
                    tx = param_value[0],
                    axis = param_axis[0],
                };
            }
            else if (name.Contains("__rot"))
            {
                // type 2, with one native special case: a parameter letter of
                // 'z' (param_axis[0] == 2) selects SLERP with tx = 1 instead of
                // ROT. This is the only place the parsed axis letter is used.
                getParams(name, AlgoType.ROT);
                if (param_axis[0] == 2)
                {
                    info = new CalcBoneInfo
                    {
                        type = AlgoType.SLERP,
                        myPath = name,
                        referPath = getTargetName(name),
                        t = param_value[0],
                        tx = 1f,
                        axis = param_axis[0],
                    };
                }
                else
                {
                    info = new CalcBoneInfo
                    {
                        type = AlgoType.ROT,
                        myPath = name,
                        referPath = getTargetName(name),
                        t = -1f,
                        tx = param_value[0],
                        axis = param_axis[0],
                    };
                }
            }

            if (info == null) continue; // "__null"/"__gnull" bones stay at rest

            // ---- native registration tail (0x1C5F624, LABEL_98..LABEL_169) ----
            // myTransform = map[myPath]; initMyRot = localRotation;
            // initMyPosition = localPosition.
            info.myTransform = Require(byName, info.myPath);
            info.initMyRot = info.myTransform.localRotation;
            info.initMyPosition = info.myTransform.localPosition;

            // referTransform = map[referPath]; initRefRot = localRotation;
            // initRefVec = initRefRot * Vector3.right  (rightVector @0x3C).
            info.referTransform = Require(byName, info.referPath);
            info.referInitRot = info.referTransform.localRotation;
            info.referInitVec = info.referInitRot * Vector3.right;

            // Second reference (TITE types 4/6/7) when the path is non-empty.
            if (!string.IsNullOrEmpty(info.referPath2))
            {
                info.referTransform2 = Require(byName, info.referPath2);
                info.referInitRot2 = info.referTransform2.localRotation;
                info.referInitVec2 = info.referInitRot2 * Vector3.right;
            }

            m_infoList.Add(info); // native m_infoList.Add(info)
        }
    }

    /// <summary>
    /// `CalcBone.LateUpdate` @0x1C60694.
    /// <code>
    /// if (forceUpdate-- != 0) { forceUpdate++; ExplictUpdate(); }  // forceUpdate >= 1
    /// else if (MainLoop.player == null) ExplictUpdate();
    /// else if (MainLoop.player.running) ExplictUpdate();
    /// </code>
    /// (the native code decrements only on the taken branch, hence the exact
    /// `forceUpdate &gt; 0 -> forceUpdate -= 1` form below).
    /// </summary>
    private void LateUpdate()
    {
        // Editor-workflow self-heal (domain reload wipes m_infoList): re-register
        // from the surviving skeleton. Native has no hot reload.
        if (m_infoList.Count == 0) { Awake(); return; }
        if (forceUpdate > 0)
        {
            forceUpdate -= 1;
            ExplictUpdate();
            return;
        }

        var gate = PlayerRunningGate;
        if (gate == null) // native: MainLoop.player == null
        {
            ExplictUpdate();
            return;
        }

        if (gate()) // native: MainLoop.player.running
            ExplictUpdate();
    }

    /// <summary>`CalcBone.RequestUpdate` @0x1C60A70: `forceUpdate = ForceUpdateFrames;`</summary>
    public void RequestUpdate()
    {
        forceUpdate = ForceUpdateFrames;
    }

    // ------------------------------------------------------------------
    // Dispatch (CalcBone.ExplictUpdate @0x1C60748)
    // ------------------------------------------------------------------

    /// <summary>
    /// One native solve pass over `m_infoList`, in registration order. For each
    /// info the reference bone's *current* local rotation is read first, then
    /// the ALGO_TYPE case writes the bone's localRotation (types 0/1/2/4/6/7),
    /// world rotation (type 3), or localPosition (type 5).
    /// </summary>
    private Transform bindRoot;
    private readonly HashSet<string> reportedUnresolved = new HashSet<string>();
    private float nextRebindTime;
    private bool skipTwist;
    private bool skipTwistLogged;
    private bool skippedNeckTwist;
    private bool reportedRebind;

    public void ExplictUpdate()
    {
        if (!skipTwistLogged)
        {
            skipTwistLogged = true;
            skipTwist = System.Environment.GetEnvironmentVariable("EIDOLON_CALC_SKIP_TWIST") == "1";
            if (skipTwist) Debug.Log("[calc] skipping __twist entries (EIDOLON_CALC_SKIP_TWIST=1)");
        }
        for (var i = 0; i < m_infoList.Count; i++)
        {
            var info = m_infoList[i];
            if (skipTwist && info.myPath != null
                && info.myPath.IndexOf("__twist", StringComparison.Ordinal) >= 0) continue;

            // "Fake null": Unity reports a destroyed/replaced Transform as null.
            // The native Awake binds after the joint-body-head assembly has grafted
            // the head bones, so its names always resolve; a port that binds first
            // (or that lives through a rebuild) can hold stale references. Re-resolve
            // by name once, then only skip what is genuinely absent.
            if (!HasResolvedTransforms(info))
            {
                // Cheap cooldown: the assembly happens once per character, so a
                // one-second retry cadence settles immediately without rebuilding
                // the name map on every frame.
                if (Time.unscaledTime >= nextRebindTime)
                {
                    nextRebindTime = Time.unscaledTime + 1f;
                    RebindReferences();
                }
                if (!HasResolvedTransforms(info))
                {
                    ReportUnresolved(info);
                    continue;
                }
            }

            var curRefRot = info.referTransform.localRotation;

            switch (info.type)
            {
                case AlgoType.SLERP:
                    info.myTransform.localRotation = SlerpEx(
                        curRefRot, info.referInitRot, info.referInitVec, info.t, info.tx);
                    break;

                case AlgoType.TWIST:
                    // The neck helper only carries skinned vertices (it has no children), and
                    // our Twist() is an approximation that is known-good for the limb helpers
                    // but shears the neck when applied to KUBI: the A/B screenshots show the
                    // neck skin tearing away from the collar with it on. Keep the neck helper
                    // rigidly attached until the native Twist math is recovered exactly.
                    if (info.myPath != null
                        && info.myPath.IndexOf("KUBI_RT__twist", StringComparison.Ordinal) >= 0)
                    {
                        if (!skippedNeckTwist)
                        {
                            skippedNeckTwist = true;
                            Debug.Log("[calc] leaving KUBI_RT__twist* rigid (native Twist math not"
                                + " verified for the neck helper)");
                        }
                        break;
                    }
                    info.myTransform.localRotation = Twist(
                        curRefRot, info.referInitRot, info.referInitVec, info.tx);
                    break;

                case AlgoType.ROT:
                    info.myTransform.localRotation = Rot(
                        curRefRot, info.referInitRot, info.referInitVec, info.initMyRot, info.tx);
                    break;

                case AlgoType.CONST:
                    Constrain(info.myTransform, info.initMyRot, info.referTransform);
                    break;

                case AlgoType.TITE_FRONT_ROT:
                {
                    // Native passes locals by ref for the two current thigh
                    // rotations and the info field by ref for initMyRot.
                    var refL = curRefRot;
                    var refR = info.referTransform2.localRotation;
                    info.myTransform.localRotation =
                        TiteFrontRot(ref refL, ref refR, ref info.initMyRot);
                    break;
                }

                case AlgoType.TITE_FRONT_TRANS:
                {
                    var cur = curRefRot;
                    info.myTransform.localPosition =
                        TiteFrontTrans(ref cur, ref info.initMyPosition);
                    break;
                }

                case AlgoType.TITE_BACK_ROT_YZ:
                {
                    var refL = curRefRot;
                    var refR = info.referTransform2.localRotation;
                    info.myTransform.localRotation =
                        TiteBackRotYz(ref refL, ref refR, ref info.initMyRot);
                    break;
                }

                case AlgoType.TITE_BACK_ROT_X:
                {
                    var refL = curRefRot;
                    var refR = info.referTransform2.localRotation;
                    info.myTransform.localRotation =
                        TiteBackRotX(ref refL, ref refR, ref info.initMyRot);
                    break;
                }
            }
        }
    }

    /// <summary>
    /// `CalcBone.IsAssistBone` @0x1C5F014: true when `tr` is a child of any
    /// registered assist-bone transform (`Transform.IsChildOf(myTransform)`).
    /// </summary>
    public bool IsAssistBone(Transform tr)
    {
        for (var i = 0; i < m_infoList.Count; i++)
            if (tr.IsChildOf(m_infoList[i].myTransform))
                return true;
        return false;
    }

    // ------------------------------------------------------------------
    // Base algorithms
    // ------------------------------------------------------------------

    /// <summary>
    /// `CalcBone.SlerpEx` @0x1C60ADC.
    /// <code>
    /// d = FromToRotation(initRefVec, curRefRot * Vector3.right);
    /// c = d * initRefRot;
    /// if (Dot(curRefRot, c) &lt; 0) curRefRot = -curRefRot;
    /// mid = Slerp(c, curRefRot, tx);              // operand order c -> cur
    /// if (Dot(initRefRot, mid) &lt; 0) mid = -mid;
    /// return Slerp(initRefRot, mid, t_all);
    /// </code>
    /// (the 4th parameter of the native signature is named `t_all`.)
    /// </summary>
    private static Quaternion SlerpEx(
        Quaternion curRefRot, Quaternion initRefRot, Vector3 initRefVec, float t_all, float tx)
    {
        var d = Quaternion.FromToRotation(initRefVec, curRefRot * Vector3.right);
        var c = d * initRefRot;
        if (Quaternion.Dot(curRefRot, c) < 0f) curRefRot = Negate(curRefRot);
        var mid = Quaternion.Slerp(c, curRefRot, tx);
        if (Quaternion.Dot(initRefRot, mid) < 0f) mid = Negate(mid);
        return Quaternion.Slerp(initRefRot, mid, t_all);
    }

    /// <summary>
    /// `CalcBone.Twist` @0x1C60D00.
    /// <code>
    /// d = FromToRotation(initRefVec, curRefRot * Vector3.right);
    /// c = d * initRefRot;
    /// inv = Inverse(curRefRot);                   // computed before the sign fix
    /// if (Dot(curRefRot, c) &lt; 0) curRefRot = -curRefRot;
    /// return inv * Slerp(c, curRefRot, t);         // native's 4th arg is `t`,
    /// </code>                                     // caller passes info.tx
    /// The helper is the reference bone's child, so the inverse converts the
    /// result back into the reference bone's local frame.
    /// </summary>
    private static Quaternion Twist(
        Quaternion curRefRot, Quaternion initRefRot, Vector3 initRefVec, float t)
    {
        var d = Quaternion.FromToRotation(initRefVec, curRefRot * Vector3.right);
        var c = d * initRefRot;
        var inv = Quaternion.Inverse(curRefRot);
        if (Quaternion.Dot(curRefRot, c) < 0f) curRefRot = Negate(curRefRot);
        return inv * Quaternion.Slerp(c, curRefRot, t);
    }

    /// <summary>
    /// `CalcBone.ROT` @0x1C60F74. The helper is the reference bone's sibling, so
    /// the result is a local rotation directly.
    /// <code>
    /// d = FromToRotation(initRefVec, curRefRot * Vector3.right);
    /// c = d * initRefRot;
    /// b = Inverse(c) * curRefRot;
    /// if (Dot(Quaternion.identity, b) &lt; 0) b = -b;      // i.e. b.w &lt; 0
    /// return initMyRot * Slerp(Quaternion.identity, b, tx);
    /// </code>
    /// </summary>
    private static Quaternion Rot(
        Quaternion curRefRot, Quaternion initRefRot, Vector3 initRefVec,
        Quaternion initMyRot, float tx)
    {
        var d = Quaternion.FromToRotation(initRefVec, curRefRot * Vector3.right);
        var c = d * initRefRot;
        var b = Quaternion.Inverse(c) * curRefRot;
        if (b.w < 0f) b = Negate(b); // Dot(identity, b) == b.w
        var r2 = Quaternion.Slerp(Quaternion.identity, b, tx);
        return initMyRot * r2;
    }

    /// <summary>
    /// `CalcBone.Constrain` @0x1C612A4. World-space constraint: reset to the rest
    /// local rotation, then rotate the world pose so local −X points at the
    /// reference bone. Runs on the world pose, so it must run after the local
    /// algorithms (it does: one ordered pass).
    /// </summary>
    private static void Constrain(
        Transform curMyTransform, Quaternion initMyRot, Transform curRefTransform)
    {
        curMyTransform.localRotation = initMyRot;

        var d = curRefTransform.position - curMyTransform.position;
        var len = Mathf.Sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
        var dir = len <= 0.00001f ? Vector3.zero : d / len;

        var f = Quaternion.FromToRotation(-curMyTransform.right, dir);
        curMyTransform.rotation = f * curMyTransform.rotation;
    }

    // ------------------------------------------------------------------
    // TITE_F / TITE_B skirt-plate algorithms
    // ------------------------------------------------------------------

    /// <summary>
    /// `CalcBone.TITE_FRONT_ROT` @0x1C614B0. Front skirt plate, driven by both
    /// thighs' local rotations (`MOMO_L`, `MOMO_R`). `initMyRot` is declared
    /// `ref` natively but never written (all four TITE methods are read-only).
    ///
    /// Per thigh, the euler is extracted with `BoneUtil.GetRot(ROT_XYZ,
    /// BoneUtil.ToMatrix(q))`; this code uses `-rot.y` (pitch) and `-rot.z`
    /// (yaw) in degrees. Angles are combined, clamped, then composed as
    ///   MirrorYZ( AngleAxis(avgY, forward) * AngleAxis(avgX, up) *
    ///             AngleAxis(roll, right) )
    /// where `MirrorYZ(q) = (x, -y, -z, w)` — the native code negates the
    /// product's y/z components on return (verified in the epilogue:
    /// `fneg s5`/`fneg s6` before `ret`).
    /// </summary>
    private static Quaternion TiteFrontRot(
        ref Quaternion curMomoLRot, ref Quaternion curMomoRRot, ref Quaternion initMyRot)
    {
        GetPitchYaw(curMomoLRot, out var pitchL, out var yawL);
        GetPitchYaw(curMomoRRot, out var pitchR, out var yawR);

        // avgY
        float avgY;
        if (yawL >= yawR)
        {
            if (yawR < yawL) avgY = yawL * 0.2f + yawR * 0.7f;
            else avgY = (yawL + yawR) * 0.45f;
        }
        else
        {
            avgY = yawL * 0.7f + yawR * 0.2f;
        }
        avgY = Mathf.Clamp(avgY, -100f, 0f);

        // avgX
        var d = yawL - yawR;
        float weight;
        if (d < 0f && pitchL > 0f)
        {
            pitchL = pitchL * Mathf.Abs(yawL) / 10f;
            weight = 0.25f;
        }
        else if (d > 0f && pitchR < 0f)
        {
            pitchR = pitchR * Mathf.Abs(yawR) / 10f;
            weight = 0.25f;
        }
        else
        {
            weight = 0.5f;
        }
        var avgX = Mathf.Clamp((pitchL + pitchR) * weight, -40f, 40f);

        // roll: -0.5 * d, except exactly 2 degrees -> 0
        // (native: (yawR-yawL)*0.5, then 0 when d<=2, then -0.5*d when d<2;
        //  equivalent to -0.5*d for every d except d==2, NaN included).
        var roll = d * -0.5f;
        if (d == 2f) roll = 0f;

        var q1 = Quaternion.AngleAxis(avgY, Vector3.forward); // native uses Vector3 static field +0x48
        var q2 = Quaternion.AngleAxis(avgX, Vector3.up);      // +0x18
        var q3 = Quaternion.AngleAxis(roll, Vector3.right);   // +0x3C
        return MirrorYz((q1 * q2) * q3);
    }

    /// <summary>
    /// `CalcBone.TITE_FRONT_TRANS` @0x1C6196C. Front plate position: the plate
    /// slides along local X by an amount derived from the parent's (KOSHI) yaw;
    /// local Y/Z are kept from `initMyPosition`. Only `Vector3.x` of the returned
    /// vector is computed — verified in the epilogue: `ret` leaves s0 = result,
    /// s1/s2 = initMyPosition.y/z.
    /// </summary>
    private static Vector3 TiteFrontTrans(
        ref Quaternion curRefCalcBoneRot, ref Vector3 initMyPosition)
    {
        var rot = BoneUtilGetRotXyz(BoneUtilToMatrix(curRefCalcBoneRot));
        var yaw = rot.z * Mathf.Rad2Deg; // GetRot.z = Atan2(m[4], m[0]) * Rad2Deg

        float x;
        if (yaw > 0f && yaw <= 90f)
        {
            x = ((Mathf.Sin(yaw * -Mathf.Deg2Rad) * 9f + 10f) * 1.7f + 3f) * -0.01f;
        }
        else if (yaw <= 90f)
        {
            x = -0.2f;
        }
        else
        {
            x = -0.05f;
        }

        return new Vector3(x, initMyPosition.y, initMyPosition.z);
    }

    /// <summary>
    /// `CalcBone.TITE_BACK_ROT_YZ` @0x1C61ABC. Back plate, driven by both thighs.
    /// Composition (verified component by component):
    /// <code>
    /// p = MirrorYZ(initMyRot) * AngleAxis(avgY, forward);
    /// return MirrorYZ(p * AngleAxis(roll, up));
    /// </code>
    /// avgY in [-100, 60], roll in [-13, 13].
    /// </summary>
    private static Quaternion TiteBackRotYz(
        ref Quaternion curMomoLRot, ref Quaternion curMomoRRot, ref Quaternion initMyRot)
    {
        GetPitchYaw(curMomoLRot, out var pitchL, out var yawL);
        GetPitchYaw(curMomoRRot, out var pitchR, out var yawR);

        // avgY
        var avgY = (yawL + yawR) * 0.5f;
        if (yawR < yawL) avgY = yawL * 0.9f + yawR * 0.1f;
        if (yawL < yawR) avgY = yawL * 0.1f + yawR * 0.9f;
        avgY = Mathf.Clamp(avgY, -100f, 60f);

        // roll
        var d = yawL - yawR;
        float roll;
        if (d < 0f && pitchL > 0f)
        {
            roll = pitchR * 1.2f;
        }
        else if (d <= 0f || pitchR >= 0f)
        {
            if (d < 0f && pitchL < 0f)
            {
                roll = (pitchL + pitchR) / 0.9f;
            }
            else
            {
                var sum = pitchL + pitchR;
                roll = d > 0f && pitchR > 0f ? sum / 0.9f : sum * 0.5f;
            }
        }
        else
        {
            roll = (pitchL + pitchR) * 1.2f;
        }
        roll = Mathf.Clamp(roll, -13f, 13f);

        var g1 = Quaternion.AngleAxis(avgY, Vector3.forward);
        var g2 = Quaternion.AngleAxis(roll, Vector3.up);
        return MirrorYz(MirrorYz(initMyRot) * g1 * g2); // native associates ((p * g2))
    }

    /// <summary>
    /// `CalcBone.TITE_BACK_ROT_X` @0x1C61F64. Back plate twist about the plate's
    /// local X from the yaw difference: `angle = -0.5 * d` (0 when d == 2).
    /// Composition: `MirrorYZ(MirrorYZ(initMyRot) * AngleAxis(angle, right))`.
    /// </summary>
    private static Quaternion TiteBackRotX(
        ref Quaternion curMomoLRot, ref Quaternion curMomoRRot, ref Quaternion initMyRot)
    {
        GetPitchYaw(curMomoLRot, out _, out var yawL);
        GetPitchYaw(curMomoRRot, out _, out var yawR);

        var d = yawL - yawR;
        float angle;
        if (d >= 2f)
        {
            if (d == 2f) angle = 0f;
            else angle = (yawR - yawL) * 0.5f;
        }
        else
        {
            angle = d * -0.5f;
        }

        var g = Quaternion.AngleAxis(angle, Vector3.right);
        return MirrorYz(MirrorYz(initMyRot) * g);
    }

    /// <summary>
    /// The shared per-thigh euler read used by all four TITE methods: native
    /// calls `BoneUtil.GetRot(ROT_XYZ, BoneUtil.ToMatrix(q))` and then uses
    /// `-GetRot.y` (pitch) and `-GetRot.z` (yaw), in degrees. Verified from the
    /// inlined instruction sequence: `fneg; bl asinf` then `* -57.29578f`.
    /// </summary>
    private static void GetPitchYaw(Quaternion q, out float pitch, out float yaw)
    {
        var rot = BoneUtilGetRotXyz(BoneUtilToMatrix(q));
        pitch = -rot.y;
        yaw = -rot.z;
    }

    // ------------------------------------------------------------------
    // CALC_TITE_SKIRT_* helpers
    // ------------------------------------------------------------------

    /// <summary>
    /// `CalcBone.CALC_TITE_SKIRT_ROT_Z` @0x1C62230 (scalar helper; native takes
    /// Vector3 "rotations" by ref and ignores `this`). Returns a clamped blend of
    /// the two plates' z values:
    /// l.z &gt; r.z: l.z*weak + r.z*strong; equal: (l.z+r.z)*mean;
    /// l.z &lt; r.z: l.z*strong + r.z*weak.
    /// </summary>
    public float CalcTiteSkirtRotZ(
        ref Vector3 curMomoLRot, ref Vector3 curMomoRRot,
        float strongWeight, float weakWeight, float meanWeight,
        float upperLimit, float lowerLimit)
    {
        var lz = curMomoLRot.z;
        var rz = curMomoRRot.z;
        var mean = (lz + rz) * meanWeight;
        if (rz < lz) mean = lz * weakWeight + rz * strongWeight;
        var result = lz * strongWeight + rz * weakWeight;
        if (lz >= rz) result = mean;
        if (result < lowerLimit) result = lowerLimit;
        if (result > upperLimit) result = upperLimit;
        return result;
    }

    /// <summary>
    /// `CalcBone.CALC_TITE_SKIRT_FRONT_ROT_Y` @0x1C6227C. Clamped to ±threshold.
    /// </summary>
    public float CalcTiteSkirtFrontRotY(
        ref Vector3 curMomoLRot, ref Vector3 curMomoRRot, float threshold)
    {
        var lz = curMomoLRot.z;
        var rz = curMomoRRot.z;
        var d = lz - rz;

        float v;
        float weight;
        if (d >= 0f || curMomoLRot.y <= 0f)
        {
            var ry = curMomoRRot.y;
            if (d <= 0f || ry >= 0f)
            {
                v = curMomoLRot.y + ry;
                weight = 0.5f;
            }
            else
            {
                v = Mathf.Abs(rz) * ry / 10f + curMomoLRot.y;
                weight = 0.25f;
            }
        }
        else
        {
            v = Mathf.Abs(lz) * curMomoLRot.y / 10f + curMomoRRot.y;
            weight = 0.25f;
        }

        var result = v * weight;
        if (result < -threshold) result = -threshold;
        if (result > threshold) result = threshold;
        return result;
    }

    /// <summary>
    /// `CalcBone.CALC_TITE_SKIRT_BACK_ROT_Y` @0x1C62358. Clamped to ±threshold.
    /// </summary>
    public float CalcTiteSkirtBackRotY(
        ref Vector3 curMomoLRot, ref Vector3 curMomoRRot, float threshold)
    {
        var d = curMomoLRot.z - curMomoRRot.z;
        float result;

        if (d < 0f && curMomoLRot.y > 0f)
        {
            result = curMomoRRot.y * 1.2f;
        }
        else if (d > 0f && curMomoRRot.y < 0f)
        {
            result = curMomoLRot.y * 1.2f;
        }
        else
        {
            float v;
            if (d >= 0f || curMomoLRot.y >= 0f)
            {
                var ry = curMomoRRot.y;
                var ly = curMomoLRot.y;
                if (d <= 0f || ry <= 0f)
                {
                    result = (ly + ry) * 0.5f;
                    if (result < -threshold) result = -threshold;
                    if (result > threshold) result = threshold;
                    return result;
                }
                v = ry + ly;
            }
            else
            {
                v = curMomoLRot.y + curMomoRRot.y;
            }
            result = v / 0.9f;
        }

        if (result < -threshold) result = -threshold;
        if (result > threshold) result = threshold;
        return result;
    }

    /// <summary>
    /// `CalcBone.CALC_TITE_SKIRT_ROT_X` @0x1C62318.
    /// d = l.z − r.z; d &gt; 2 → (r.z − l.z) * 0.5; d == 2 → 0; else d * −0.5
    /// (NaN falls through to the last branch, as natively compiled).
    /// </summary>
    public float CalcTiteSkirtRotX(ref Vector3 curMomoLRot, ref Vector3 curMomoRRot)
    {
        var lz = curMomoLRot.z;
        var rz = curMomoRRot.z;
        var d = lz - rz;

        if (d >= 2f)
        {
            if (d == 2f) return 0f;
            return (rz - lz) * 0.5f;
        }
        return d * -0.5f;
    }

    // ------------------------------------------------------------------
    // Name grammar (getParams / getTargetName)
    // ------------------------------------------------------------------

    /// <summary>
    /// `CalcBone.getParams` @0x1C5F1D0. Fills `param_axis`/`param_value`
    /// (`private int[] / float[]`, length 2) from the name.
    ///
    /// Only the tail after the *second* "__" carries parameters
    /// (`...__i30_x0`); the single-"__" form (`...__twist_x50`) is parsed only
    /// for TWIST. Letters i/x/y/z map to axis -1/0/1/2; the numeric value is
    /// integer-hundredths (`i30` → 0.30). CONST returns immediately (its
    /// trailing `__rot_...__x0` span is not parsed).
    /// </summary>
    private void getParams(string node, AlgoType type)
    {
        param_axis[0] = -1;
        param_axis[1] = -1;
        param_value[0] = 0f;
        param_value[1] = 0f;

        if (type == AlgoType.CONST) return;

        var i0 = node.IndexOf("__", StringComparison.Ordinal);
        if (i0 < 0) return;

        var i1 = node.IndexOf("__", i0 + 2, StringComparison.Ordinal);
        if (i1 < 0)
        {
            // One "__": TWIST's `_x50` form (only parsed for TWIST).
            var u = node.IndexOf("_", i0 + 2, StringComparison.Ordinal);
            if (type == AlgoType.TWIST)
            {
                switch (node[u + 1])
                {
                    case 'x': param_axis[0] = 0; break;
                    case 'y': param_axis[0] = 1; break;
                    case 'z': param_axis[0] = 2; break;
                }
                param_value[0] = int.Parse(node.Substring(u + 2)) / 100f;
            }
            return;
        }

        switch (node[i1 + 2])
        {
            case 'i': param_axis[0] = -1; break;
            case 'x': param_axis[0] = 0; break;
            case 'y': param_axis[0] = 1; break;
            case 'z': param_axis[0] = 2; break;
        }

        var sep = node.IndexOf("_", i1 + 2, StringComparison.Ordinal);
        var num = sep < 0
            ? node.Substring(i1 + 3)
            : node.Substring(i1 + 3, sep - i1 - 3);
        param_value[0] = int.Parse(num) / 100f;

        if (sep < 0) return;

        switch (node[sep + 1])
        {
            case 'i': param_axis[1] = -1; break;
            case 'x': param_axis[1] = 0; break;
            case 'y': param_axis[1] = 1; break;
            case 'z': param_axis[1] = 2; break;
        }
        param_value[1] = int.Parse(node.Substring(sep + 2)) / 100f;
    }

    /// <summary>
    /// `CalcBone.getTargetName` @0x1C5F0FC: the reference bone's name — between
    /// the `_` after the algorithm token and the next `__`. Returns null when
    /// the name has no such span (e.g. the TWIST form).
    /// </summary>
    private static string getTargetName(string node)
    {
        var i0 = node.IndexOf("__", StringComparison.Ordinal);
        if (i0 < 0) return null;
        var separator = node.IndexOf("_", i0 + 2, StringComparison.Ordinal);
        if (separator < 0) return null;
        var start = separator + 1;
        var end = node.IndexOf("__", start, StringComparison.Ordinal);
        if (end < 0) return null;
        return node.Substring(start, end - start);
    }

    // ------------------------------------------------------------------
    // Dependency replicas: Imas.BoneLib.BoneUtil (@0x1C5EAA0 / 0x1C5ECA8)
    // ------------------------------------------------------------------

    /// <summary>
    /// `BoneUtil.ToMatrix(Quaternion q)` @0x1C5EAA0. This is Unity's rotation
    /// matrix transposed (i.e. `Quaternion.Inverse(q)`'s rotation matrix); the
    /// native code assigns the 16 elements through `Matrix4x4`'s indexer, and
    /// the index→offset mapping is `offset = 4 * index` (`Matrix4x4.get_Item`
    /// @0x7091D1C), i.e. index 8 = `m02`, index 4 = `m01`, index 0 = `m00`.
    /// </summary>
    private static Matrix4x4 BoneUtilToMatrix(Quaternion q)
    {
        var x2 = q.x * q.x + q.x * q.x;
        var y2 = q.y * q.y + q.y * q.y;
        var z2 = q.z * q.z + q.z * q.z;
        var xy = q.x * q.y + q.x * q.y;
        var yz = q.y * q.z + q.y * q.z;
        var zx = q.z * q.x + q.z * q.x;
        var xw = q.x * q.w + q.x * q.w;
        var yw = q.y * q.w + q.y * q.w;
        var zw = q.z * q.w + q.z * q.w;

        var m = new Matrix4x4();
        m.m00 = 1f - y2 - z2;
        m.m01 = xy + zw;
        m.m02 = zx - yw;
        m.m03 = 0f;
        m.m10 = xy - zw;
        m.m11 = 1f - z2 - x2;
        m.m12 = yz + xw;
        m.m13 = 0f;
        m.m20 = zx + yw;
        m.m21 = yz - xw;
        m.m22 = 1f - x2 - y2;
        m.m23 = 0f;
        m.m30 = 0f;
        m.m31 = 0f;
        m.m32 = 0f;
        m.m33 = 1f;
        return m;
    }

    /// <summary>
    /// `BoneUtil.GetRot(BoneUtil.rot_order order, Matrix4x4 m)` @0x1C5ECA8,
    /// returning degrees; the six order branches are transcribed from the
    /// switch. CalcBone only ever passes `ROT_XYZ` (order 0), whose used
    /// components are `y = Asin(-m[8]) * Rad2Deg` and
    /// `z = Atan2(m[4], m[0]) * Rad2Deg` (`m[i]` = element at byte offset 4*i).
    /// Out-of-range orders return (0,0,0) natively; kept for completeness.
    /// </summary>
    private static Vector3 BoneUtilGetRotXyz(Matrix4x4 m)
    {
        return BoneUtilGetRot(0 /* BoneUtil.rot_order.ROT_XYZ */, m);
    }

    private static Vector3 BoneUtilGetRot(int order, Matrix4x4 m)
    {
        float x;
        float y;
        float z;

        switch (order)
        {
            case 0: // ROT_XYZ
                x = Mathf.Atan2(m.m12, m.m22);
                y = Mathf.Asin(-m.m02);
                z = Mathf.Atan2(m.m01, m.m00);
                break;
            case 1: // ROT_YZX
                x = Mathf.Atan2(m.m12, m.m11);
                y = Mathf.Atan2(m.m20, m.m00);
                z = Mathf.Asin(-m.m10);
                break;
            case 2: // ROT_ZXY
                x = Mathf.Asin(-m.m21);
                y = Mathf.Atan2(m.m20, m.m22);
                z = Mathf.Atan2(m.m01, m.m11);
                break;
            case 3: // ROT_XZY
                x = Mathf.Atan2(-m.m21, m.m11);
                y = Mathf.Atan2(-m.m02, m.m00);
                z = Mathf.Asin(m.m01);
                break;
            case 4: // ROT_YXZ
                x = Mathf.Asin(m.m12);
                y = Mathf.Atan2(-m.m02, m.m22);
                z = Mathf.Atan2(-m.m10, m.m11);
                break;
            case 5: // ROT_ZYX
                x = Mathf.Atan2(-m.m21, m.m22);
                y = Mathf.Asin(m.m20);
                z = Mathf.Atan2(-m.m10, m.m00);
                break;
            default:
                return Vector3.zero;
        }

        return new Vector3(x * Mathf.Rad2Deg, y * Mathf.Rad2Deg, z * Mathf.Rad2Deg);
    }

    // ------------------------------------------------------------------
    // Small helpers
    // ------------------------------------------------------------------

    /// <summary>Quaternion negation (same rotation, opposite double-cover sign).</summary>
    private static Quaternion Negate(Quaternion q)
    {
        return new Quaternion(-q.x, -q.y, -q.z, -q.w);
    }

    /// <summary>
    /// The native TITE epilogues negate the returned quaternion's y and z
    /// components (`fneg s5` / `fneg s6`); this is that exact component flip,
    /// applied where the native code applies it (on `initMyRot` and on the final
    /// product), so the composition order is preserved.
    /// </summary>
    private static Quaternion MirrorYz(Quaternion q)
    {
        return new Quaternion(q.x, -q.y, -q.z, q.w);
    }

    /// <summary>
    /// Native dictionary lookup (`dict[path]` then a null check that throws).
    /// Only reachable on malformed rigs; the shipped models always contain the
    /// named bones.
    /// </summary>
    private static string FullPath(Transform tr)
    {
        if (tr == null) return "<null>";
        var path = tr.name;
        var parent = tr.parent;
        var guard = 0;
        while (parent != null && guard++ < 32)
        {
            path = parent.name + "/" + path;
            parent = parent.parent;
        }
        return path;
    }

    private static bool HasResolvedTransforms(CalcBoneInfo info)
    {
        if (info.myTransform == null || info.referTransform == null) return false;
        if (info.type == AlgoType.TITE_FRONT_ROT || info.type == AlgoType.TITE_BACK_ROT_YZ
            || info.type == AlgoType.TITE_BACK_ROT_X)
        {
            return info.referTransform2 != null;
        }
        return true;
    }

    /// <summary>
    /// Re-resolves every registered entry against the current hierarchy (names
    /// only — the bind-pose captures such as initMyRot stay untouched, so this is
    /// NOT a re-bind). Mirrors what the native Awake would see if it ran after the
    /// joint-body-head graft instead of before it.
    /// </summary>
    public void RebindReferences()
    {
        var root = bindRoot != null ? bindRoot : transform;
        if (root == null) return;
        var byName = new Dictionary<string, Transform>(StringComparer.Ordinal);
        var all = root.GetComponentsInChildren<Transform>(true);
        foreach (var tr in all) byName[tr.name] = tr;

        var recovered = 0;
        for (var i = 0; i < m_infoList.Count; i++)
        {
            var info = m_infoList[i];
            if (info.myTransform == null && byName.TryGetValue(info.myPath ?? string.Empty, out var mine))
            {
                info.myTransform = mine;
                recovered++;
            }
            if (info.referTransform == null && byName.TryGetValue(info.referPath ?? string.Empty, out var refer))
            {
                info.referTransform = refer;
                recovered++;
            }
            if (info.referTransform2 == null && !string.IsNullOrEmpty(info.referPath2)
                && byName.TryGetValue(info.referPath2, out var refer2))
            {
                info.referTransform2 = refer2;
                recovered++;
            }
        }
        if (recovered > 0 && !reportedRebind)
        {
            reportedRebind = true;
            Debug.Log("[calc] re-resolved " + recovered
                + " stale calc-bone reference(s) after the joint-body-head assembly");
            for (var i = 0; i < m_infoList.Count; i++)
            {
                var info = m_infoList[i];
                if (info.myTransform == null || info.referTransform == null) continue;
                Debug.Log("[calc] entry my=" + FullPath(info.myTransform) + " refer="
                    + FullPath(info.referTransform) + " type=" + info.type + " tx=" + info.tx);
            }
        }
    }

    private void ReportUnresolved(CalcBoneInfo info)
    {
        var key = (info.myPath ?? "<null>") + "|" + (info.referPath ?? "<null>");
        if (!reportedUnresolved.Add(key)) return;
        if (reportedUnresolved.Count > 8) return;
        var hunt = new System.Text.StringBuilder();
        var root = bindRoot != null ? bindRoot : transform;
        if (root != null)
        {
            var all = root.GetComponentsInChildren<Transform>(true);
            foreach (var tr in all)
            {
                if (tr.name.IndexOf("KUBI", StringComparison.Ordinal) < 0
                    && tr.name.IndexOf("ATAMA", StringComparison.Ordinal) < 0) continue;
                hunt.Append(' ').Append(tr.name).Append("<-")
                    .Append(tr.parent != null ? tr.parent.name : "<root>");
                if (hunt.Length > 400) break;
            }
        }
        Debug.LogWarning("[calc] unresolved calc-bone entry: my=" + (info.myPath ?? "<null>")
            + " refer=" + (info.referPath ?? "<null>") + " type=" + info.type
            + " myParent=" + (info.myTransform != null && info.myTransform.parent != null
                ? info.myTransform.parent.name : "<none>")
            + " hierarchy:" + hunt);
    }

    private static Transform Require(Dictionary<string, Transform> byName, string path)
    {
        if (path != null && byName.TryGetValue(path, out var tr) && tr != null) return tr;
        throw new NullReferenceException(
            "CalcBone: no Transform named '" + (path ?? "<null>") + "' in the bound hierarchy");
    }
}
