// JointBodyHead assembly / switch orchestration — B5 add-on (ADR-0033).
//
// This file is only the *non-MonoBehaviour glue* on top of the already-ported
// JointBodyHeadNative (dump.cs 15271). It adds exactly what JointBodyHeadNative
// does not have and delegates everything else to it, so there is no duplicated
// port logic:
//
//   * RunPostInitialize          — idempotent bookkeeping for the Post_1/Post_2
//                                  products (0x1C66DB0 / 0x1C63AF8), because the
//                                  spike's JointBodyHeadNative.Initialize flattens
//                                  Post_1 and callers may run only Initialize
//                                  or only the Post steps.
//   * switch / visible / sway    — thin delegates onto the native-equivalent
//                                  methods that already live on
//                                  JointBodyHeadNative (0x1C64F94, 0x1C65524,
//                                  0x1C64820, 0x1C64920, 0x1C642A0, 0x1C64534,
//                                  0x1C62D28, 0x1C62DC0, 0x1C64700, 0x1C645DC).
//   * BindEyeAndFace             — the Post_1 tail ordering (EyeTracking →
//                                  FaceCtrl) written down so a bootstrap can call
//                                  it in the native order; it does NOT change the
//                                  B3/B4 Eye/Face files.
//   * ApplySoulBodyScale /
//     ApplySoulBreastSway        — the CharacterSoul consumers where the xref
//                                  evidence is not (yet) sufficient; both stay
//                                  no-ops and only record diagnostics. See the
//                                  UNKNOWN notes in place before writing
//                                  transforms or sway fields.
//
// Evidence (decompiled product, only source of truth):
//   /tmp/ida-decomp/JointBodyHead__Initialize_Post_2.c        0x1C63AF8
//   /tmp/ida-decomp/b5/JBH__Initialize@0x1c633cc.c            0x1C633CC
//   /tmp/ida-decomp/b5/JBH__Initialize_Post_1_MoveNext@0x1c66db0.c  0x1C66DB0
//   /tmp/ida-decomp/b5/JBH__GetBoneRot@0x1c64a6c.c            0x1C64A6C
//   /tmp/ida-decomp/b5/JBH__AddPositionNode@0x1c63f34.c       0x1C63F34
//   /tmp/ida-decomp/b5/JBH__SetBodyMeshs@0x1c64c18.c          0x1C64C18
//   /tmp/ida-decomp/b5/JBH__SetHeadMeshs@0x1c6516c.c          0x1C6516C
//   /tmp/ida-decomp/b5/JBH__ApplyModelSwitch@0x1c64f94.c      0x1C64F94
//   /tmp/ida-decomp/b5/JBH__ApplyGlassesSwitch@0x1c65524.c    0x1C65524
//   /tmp/ida-decomp/b5/JBH__SetOptionDisplay@0x1c64820.c      0x1C64820
//   /tmp/ida-decomp/b5/JBH__InitializeDisplay@0x1c64920.c     0x1C64920
//   /tmp/ida-decomp/b5/JBH__SetVisible@0x1c642a0.c            0x1C642A0
//   /tmp/ida-decomp/b5/JBH__SwaySwitch@0x1c64534.c            0x1C64534
//   /tmp/ida-decomp/b5/JBH__SwayManagerAllON@0x1c62d28.c      0x1C62D28
//   /tmp/ida-decomp/b5/JBH__skirt_GP_SwayManagerCtrl@0x1c62dc0.c 0x1C62DC0
//   /tmp/ida-decomp/b5/JBH__SetWingLimit@0x1c64700.c          0x1C64700
//   /tmp/ida-decomp/b5/JBH__MeasureSway@0x1c645dc.c           0x1C645DC
//   /tmp/ida-decomp/b5/JBH__GetHeadModelTop@0x1c646c0.c       0x1C646C0
//   /tmp/ida-decomp/b5/JBH__GetBodyModelTop@0x1c646dc.c       0x1C646DC
//   Appended by the same files: EyeTracking.Init 0x379BF80,
//   FaceCtrl..ctor 0x379DC1C, FaceCtrl.Init 0x379E5B8,
//   DropShadow.SetShadowMode 0x379A228.
//
// ADR-0033: only performance-layer substitutions are allowed. Anything the
// shipped binary could not pin down statically is marked UNKNOWN and kept at
// the neutral (no-op) value it has today — nothing is invented.
//
// Lead wiring (one line, read-only; do not modify CharacterBootstrap here):
//   after jbh.Initialize(...): var asm = new JointBodyHeadAssemblyNative(jbh);
//   asm.RunPostInitialize(); asm.BindEyeAndFace(<EyeTracking component>, <FaceCtrlNative>);
//   asm.ApplySoulBodyScale(soul); asm.ApplySoulBreastSway(rig, soul);  // no-ops, see UNKNOWN
//
// Companion notes: /tmp/jbh-assembly-notes.md.

using System;
using System.Collections.Generic;
using System.Text;
using UnityEngine;

/// <summary>
/// Assembly/switch orchestration for <see cref="JointBodyHeadNative"/> (ADR-0033 B5).
/// Plain class — no MonoBehaviour, no per-frame logic; every step is called once by
/// the bootstrap in the order JointBodyHead.Initialize → Post_1 → Post_2 drives.
/// </summary>
public sealed class JointBodyHeadAssemblyNative
{
    // =====================================================================
    // State
    // =====================================================================

    private readonly JointBodyHeadNative jbh;

    /// <summary>RunPostInitialize completed with both body/head resolved.</summary>
    public bool postInitializeDone { get; private set; }

    /// <summary>Head-model top (= JointBodyHead.GetHeadModelTop 0x1C646C0).</summary>
    public GameObject headTop { get; private set; }

    /// <summary>Body-model top (= JointBodyHead.GetBodyModelTop 0x1C646DC).</summary>
    public GameObject bodyTop { get; private set; }

    /// <summary>BonesRot supplementary fill happened during RunPostInitialize (it was
    /// missing when the method ran — i.e. jbh.Initialize was not driven).</summary>
    public bool filledBonesRotThisRun { get; private set; }

    /// <summary>Position node was created/located during RunPostInitialize.</summary>
    public bool filledPositionThisRun { get; private set; }

    /// <summary>Last EyeTracking component cached by BindEyeAndFace (0xE0 alias).</summary>
    public Component eyeTracking { get; private set; }

    /// <summary>Last FaceCtrl component cached by BindEyeAndFace (0xE8 alias).</summary>
    public FaceCtrlNative faceCtrl { get; private set; }

    /// <summary>True after BindEyeAndFace.</summary>
    public bool eyeAndFaceBound { get; private set; }

    // -------- soul-consumer diagnostics (no applications, see UNKNOWN) --------

    /// <summary>Last ApplySoulBodyScale input (value only; never applied).</summary>
    public float lastSoulBodyScale { get; private set; }

    /// <summary>CharacterSoul.bodyScale.isValid of the last ApplySoulBodyScale.</summary>
    public bool lastSoulBodyScaleValid { get; private set; }

    /// <summary>ApplySoulBreastSway input values (value only; never applied).</summary>
    public float lastSoulBreastStiffness { get; private set; }
    public float lastSoulBreastDrag { get; private set; }
    public float lastSoulBreastFollow { get; private set; }
    public float lastSoulBreastGravity { get; private set; }
    public bool lastSoulBreastValid { get; private set; }

    /// <summary>Sway bones classified SwayCategory.Opai found by ApplySoulBreastSway —
    /// the mapping targets exist; which one receives a soul value is UNKNOWN.</summary>
    public readonly List<string> opaiBonePaths = new List<string>();

    private const int MaxOpaiNames = 32;

    /// <summary>
    /// Caches the assembled JointBodyHead the caller already drove through
    /// <see cref="JointBodyHeadNative.Initialize"/> (or that is about to be
    /// drive-backed by <see cref="RunPostInitialize"/>).
    /// </summary>
    public JointBodyHeadAssemblyNative(JointBodyHeadNative jbh)
    {
        this.jbh = jbh;
    }

    // =====================================================================
    // RunPostInitialize — 0x1C66DB0 bookkeeping + 0x1C63AF8
    // =====================================================================

    /// <summary>
    /// Completes the assembly bookkeeping that Post_1/Post_2 produce, at the
    /// granularity JointBodyHeadNative already implements. It is idempotent and
    /// safe to call after a full <see cref="JointBodyHeadNative.Initialize"/> —
    /// every step is guarded by "is the product already there".
    ///
    /// Native order (evidence: 0x1C633CC drives 0x1C66DB0 to completion, then
    /// DropShadow.SetShadowMode 0x379A228, then 0x1C63AF8, then
    /// is_creation_succeeded=1 @+0x138):
    ///   Post_1 (@0x1C66DB0):
    ///     optionDisplayDict.Clear()          (+0x108)
    ///     swayFollowRate = new float[N]      (+0x128, all zeros; N UNKNOWN,
    ///                                         a zero array is value-equivalent)
    ///     bodyMesh = body.transform.Find(..)  (+0xC0)      → SetBodyMeshs 0x1C64C18
    ///     headMesh = head.transform.Find(..)  (+0xB8)      → SetHeadMeshs 0x1C6516C
    ///     if (!start_with_hide) Set_updateWhenOffscreen(true) 0x1C640A8
    ///     headbones fills + head/body bone reparenting (head-side nodes slid under
    ///       body-side parents; Transform.SetParent, literal names UNKNOWN)
    ///     BodyScale node create/scale bookkeeping (its scale factor comes from a
    ///       CharacterManager-owned dictionary entry, NOT CharacterSoul — see
    ///       <see cref="ApplySoulBodyScale"/>)
    ///     calcBone = GetComponent&lt;CalcBone&gt;(Model00) (+0xF0)
    ///     material baseline resets on the body subtree (three zero writes each,
    ///       component identity UNKNOWN)
    ///     eye-material cheek offsets from the same dictionary entry (property
    ///       names UNKNOWN — see /tmp/jbh-assembly-notes.md §UNKNOWN)
    ///     GetBoneRot(body.transform) 0x1C64A6C → bonesRot (+0xC8)
    ///     EyeTracking + FaceCtrl creation (see <see cref="BindEyeAndFace"/>)
    ///     dshadow = GetComponent&lt;DropShadow&gt;(body) (+0xF8)
    ///   Initialize tail (0x1C633CC): SetShadowMode(shadow, ABShadow)
    ///   Post_2 (0x1C63AF8): AtamaY = Atama.transform.position.y;
    ///                       EyesY = Eye.transform.position.y;
    ///   is_creation_succeeded = 1
    /// </summary>
    public bool RunPostInitialize()
    {
        postInitializeDone = false;
        filledBonesRotThisRun = false;
        filledPositionThisRun = false;

        if (jbh == null) return false;
        if (jbh.body == null || jbh.head == null)
        {
            // Native 0x1C63AF8 throws NRE (sub_84DD18) on an unresolved node.
            Debug.LogWarning("JointBodyHeadAssemblyNative.RunPostInitialize: " +
                             "jbh.body/head unresolved (native 0x1C63AF8 would NRE)");
            return false;
        }

        // ---- Post_1 supplement (0x1C66DB0), only for states that are missing ----

        if (jbh.headMesh == null)
            jbh.headMesh = JointBodyHeadNative.serchChild(
                jbh.head.transform, JointBodyHeadNative.NameModel00);
        if (jbh.bodyMesh == null)
            jbh.bodyMesh = JointBodyHeadNative.serchChild(
                jbh.body.transform, JointBodyHeadNative.NameModel00);

        if (jbh.bodyMesh != null && jbh.bodymeshes.Count == 0)
            jbh.SetBodyMeshs(jbh.bodyMesh, null);           // 0x1C64C18
        if (jbh.headMesh != null && jbh.headmeshes.Count == 0)
            jbh.SetHeadMeshs(jbh.headMesh, null);           // 0x1C6516C

        if (jbh.bonesRot != null && jbh.bonesRot.Count == 0)
        {
            jbh.GetBoneRot(jbh.body.transform);             // 0x1C64A6C
            filledBonesRotThisRun = true;
        }

        if (jbh.Position == null)
        {
            jbh.AddPositionNode();                          // 0x1C63F34
            filledPositionThisRun = true;
        }

        // ---- head/body model tops (0x1C646C0 / 0x1C646DC) ----
        //
        // Native correction finding: both accessors read the *model node found
        // under the bundle root* (jbh+0xB8 headMesh / +0xC0 bodyMesh, then
        // get_gameObject 0x70A753C) and NRE when unset — NOT the bundle root
        // itself. Keep the same semantics; fall back to the root only when the
        // model node could not be resolved (supplement above failed).
        headTop = TopOr(jbh.headMesh, jbh.head);
        bodyTop = TopOr(jbh.bodyMesh, jbh.body);

        // ---- Post_2 (0x1C63AF8), same AtamaY/EyesY semantics as jbh ----
        jbh.Initialize_Post_2();

        postInitializeDone = true;
        return true;
    }

    private static GameObject TopOr(Transform modelNode, GameObject fallback)
    {
        if (modelNode != null) return modelNode.gameObject;   // get_gameObject 0x70A753C
        return fallback;                                      // + UNKNOWN deviation note
    }

    // =====================================================================
    // Switch delegates (logic lives on JointBodyHeadNative; this is the seam)
    // =====================================================================

    /// <summary>
    /// JointBodyHead.ApplyModelSwitch 0x1C64F94 (native-equal method on jbh):
    /// gated on DanceIdolInfo flags, compares the root bone's parent name against
    /// two literals, then SetOptionDisplay 0x1C64820 → optionDisplayDict(+0x108)
    /// and renderer.enabled. Flag layout and literals: UNKNOWN (see notes).
    /// </summary>
    public void ApplyModelSwitch(UnityEngine.SkinnedMeshRenderer render, object info)
    {
        jbh.ApplyModelSwitch(render, info);
    }

    /// <summary>
    /// JointBodyHead.ApplyGlassesSwitch 0x1C65524 (native-equal method on jbh):
    /// renderer name vs two literals + the info-carried index, then
    /// SetOptionDisplay. Flag layout, literals and suffix grammar: UNKNOWN.
    /// </summary>
    public void ApplyGlassesSwitch(UnityEngine.SkinnedMeshRenderer render, object info)
    {
        jbh.ApplyGlassesSwitch(render, info);
    }

    /// <summary>JointBodyHead.SetOptionDisplay 0x1C64820 delegate.</summary>
    public void SetOptionDisplay(Renderer renderer, bool sw)
    {
        jbh.SetOptionDisplay(renderer, sw);
    }

    /// <summary>JointBodyHead.InitializeDisplay 0x1C64920 delegate
    /// (is_creation_start_with_hide=false; dictionary-driven renderer.enabled).</summary>
    public void InitializeDisplay()
    {
        jbh.InitializeDisplay();
    }

    /// <summary>JointBodyHead.SetVisible 0x1C642A0 delegate (renderer loop +
    /// DropShadow forward through jbh.onDropShadowVisible).</summary>
    public void SetVisible(bool show)
    {
        jbh.SetVisible(show);
    }

    /// <summary>JointBodyHead.SwaySwitch 0x1C64534 delegate (swm[i].on = on).</summary>
    public void SwaySwitch(bool on)
    {
        jbh.SwaySwitch(on);
    }

    /// <summary>JointBodyHead.SwayManagerAllON 0x1C62D28 delegate.</summary>
    public void SwayManagerAllON()
    {
        jbh.SwayManagerAllON();
    }

    /// <summary>JointBodyHead.skirt_GP_SwayManagerCtrl 0x1C62DC0 delegate
    /// (skirt_GP managers only; the name constant is on jbh).</summary>
    public void skirt_GP_SwayManagerCtrl(bool on)
    {
        jbh.skirt_GP_SwayManagerCtrl(on);
    }

    /// <summary>JointBodyHead.SetWingLimit 0x1C64700 delegate (wingL→SetWingLimitL
    /// 0x1C727B4 / wingR→SetWingLimitR 0x1C7288C).</summary>
    public void SetWingLimit(int index)
    {
        jbh.SetWingLimit(index);
    }

    /// <summary>JointBodyHead.MeasureSway 0x1C645DC delegate; the combine step of
    /// the two sums (updateSwayTime + sideLineHitTime) is UNKNOWN in the
    /// decompile and stays exposed via the out-overload on jbh.</summary>
    public float MeasureSway()
    {
        return jbh.MeasureSway();
    }

    public void MeasureSway(out float updateSwayTime, out float sideLineHitTime)
    {
        jbh.MeasureSway(out updateSwayTime, out sideLineHitTime);
    }

    // =====================================================================
    // BindEyeAndFace — Post_1 tail ordering (@0x1C66DB0, lines 1202-1274)
    // =====================================================================

    /// <summary>
    /// Stores the eye/face parts in the same slots the native Post_1 tail fills.
    /// This only binds JointBodyHeadNative's fields — the components themselves
    /// are created/initialised by the bootstrap exactly as before (B3/B4 files
    /// are untouched). The native order to follow at the call site:
    ///
    ///   1. (eye, only when the info flag @info+184 == 1)
    ///        info+152 = jbh                     (back-reference field)
    ///        eye = GetComponent&lt;EyeTracking&gt;(jbh.Eye @0x80)
    ///        jbh+0xE0 = eye                     (holding slot; B4 maps named EyeTarget)
    ///        EyeTracking.Init(info)             0x379BF80
    ///   2. (face, unconditional)
    ///        face = new FaceCtrl; ctor 0x379DC1C(face, managerArg, info)
    ///        jbh+0xE8 = face
    ///        if (info+68 byte == 1) face+76 = info+72 value   ← face-side
    ///            field identity UNKNOWN (see notes §UNKNOWN)
    ///        FaceCtrl.Init(arg)                 0x379E5B8
    ///   3. (shadow)
    ///        jbh+0xF8 = GetComponent&lt;DropShadow&gt;(body)     — jbh.dshadow alias;
    ///        SetShadowMode 0x379A228 runs later in Initialize 0x1C633CC.
    ///
    /// The two late JointBodyHeadNative offsets are +0xE0 (eye tracking) and
    /// +0xE8 (face); the spike's field names are <see cref="JointBodyHeadNative.EyeTarget"/>
    /// and <see cref="JointBodyHeadNative.face"/>.
    /// </summary>
    public void BindEyeAndFace(Component eyeTracking, FaceCtrlNative faceCtrl)
    {
        if (jbh == null) return;
        this.eyeTracking = eyeTracking;
        jbh.EyeTarget = eyeTracking;              // Post_1 tail: jbh+0xE0
        this.faceCtrl = faceCtrl;
        jbh.face = faceCtrl;                      // Post_1 tail: jbh+0xE8
        eyeAndFaceBound = eyeTracking != null || faceCtrl != null;
    }

    // =====================================================================
    // CharacterSoul consumers — evidence-gated, both no-ops today
    // =====================================================================

    /// <summary>
    /// CharacterSoul.bodyScale → JointBodyHead. NOT APPLIED.
    /// UNKNOWN: every GetBodyScale 0x1C35B7C call site is outside the decompiled
    /// evidence set (no xref available offline), so the consumer is not
    /// established. The only BodyScale-scale write in the evidence (Post_1
    /// @0x1C66DB0 lines 1040-1059) scales the created BodyScale node from a
    /// CharacterManager-owned dictionary entry (value at +36, multiplied by the
    /// three default factors off_970CCF8 +12/+16/+20) — that is costume data,
    /// not CharacterSoul. Until xref evidence exists the transform stays
    /// untouched (whether bodyScale feeds camera/placement at all is also
    /// unestablished — same UNKNOWN).
    /// </summary>
    public void ApplySoulBodyScale(Imas.CharacterSoul soul)
    {
        lastSoulBodyScaleValid = false;
        lastSoulBodyScale = -1f;
        if (soul == null) return;
        lastSoulBodyScale = soul.bodyScale.value;
        lastSoulBodyScaleValid = soul.bodyScale.isValid;
    }

    /// <summary>
    /// CharacterSoul.swayBreast{Stiffness,Drag,Follow,Gravity} → SwayBone.
    /// NOT APPLIED. UNKNOWN: the mapping to the SwayBoneNative fields
    /// (stiffnessForce 0x84 / dragForce 0x8C / followForce 0x9C / gravity 0x90,
    /// or the OUTV[n]/Tail[n] slots named in the audit) has no static evidence
    /// in /tmp/ida-decomp — GetSwayBreast* 0x1C37A14..0x1C38524 callers are not
    /// in the decompiled set and no xref is available offline. Which Opai bone
    /// receives a value, and whether the manager-level or bone-level fields are
    /// the write target, would both be guesses. Opai-classified bones are
    /// recorded in <see cref="opaiBonePaths"/> (bounded) so the eventual xref
    /// can be validated against one call. Overriding IDanceIdolInfo-style probe
    /// writes must come from a runtime dump, not from here.
    /// </summary>
    public void ApplySoulBreastSway(SwayRigNative rig, Imas.CharacterSoul soul)
    {
        lastSoulBreastValid = false;
        lastSoulBreastStiffness = -1f;
        lastSoulBreastDrag = -1f;
        lastSoulBreastFollow = -1f;
        lastSoulBreastGravity = -1f;

        opaiBonePaths.Clear();
        if (rig != null)
        {
            for (var i = 0; i < rig.bones.Count; i++)
            {
                var b = rig.bones[i];
                if (b == null || b.category != SwayCategory.Opai) continue;
                if (opaiBonePaths.Count >= MaxOpaiNames) break;
                // SwayBone.trs.path is not exposed; the bone name is observation-level.
                opaiBonePaths.Add(b.name);
            }
        }

        if (soul == null) return;
        lastSoulBreastStiffness = soul.swayBreastStiffness.value;
        lastSoulBreastDrag = soul.swayBreastDrag.value;
        lastSoulBreastFollow = soul.swayBreastFollow.value;
        lastSoulBreastGravity = soul.swayBreastGravity.value;
        lastSoulBreastValid =
            soul.swayBreastStiffness.isValid &&
            soul.swayBreastDrag.isValid &&
            soul.swayBreastFollow.isValid &&
            soul.swayBreastGravity.isValid;
    }

    // =====================================================================
    // Describe
    // =====================================================================

    /// <summary>One-shot probe string: bound nodes / fields / arrays / switch state.</summary>
    public string Describe()
    {
        var sb = new StringBuilder();

        sb.Append("JointBodyHeadAssemblyNative ok=").Append(postInitializeDone)
          .Append(" body=").Append(Nm(jbh != null ? jbh.body : null))
          .Append(" head=").Append(Nm(jbh != null ? jbh.head : null))
          .Append(" headTop=").Append(Nm(headTop))
          .Append(" bodyTop=").Append(Nm(bodyTop))
          .AppendLine();
        if (!postInitializeDone)
        {
            sb.AppendLine("  postInitialize: not run (body/head unresolved or not called)");
        }

        if (jbh != null)
        {
            sb.Append("  Post_1 products: bodymeshes=").Append(jbh.bodymeshes.Count)
              .Append(" headmeshes=").Append(jbh.headmeshes.Count)
              .Append(" headbones=").Append(jbh.headbones.Count)
              .Append(" bonesRot=").Append(jbh.bonesRot != null ? jbh.bonesRot.Count : 0)
              .Append(" options=").Append(jbh.optionDisplayDict.Count)
              .Append(" Position=").Append(Nm(jbh.Position))
              .Append(" AtamaY=").Append(jbh.AtamaY.ToString("F4"))
              .Append(" EyesY=").Append(jbh.EyesY.ToString("F4"))
              .AppendLine();
            sb.Append("  filled this run: bonesRot=").Append(filledBonesRotThisRun)
              .Append(" position=").Append(filledPositionThisRun)
              .AppendLine();
            sb.Append("  sway: swm=").Append(jbh.swm.Count).Append(" swb=").Append(jbh.swb.Count)
              .Append(" swayOn=").Append(jbh.swayOn)
              .Append(" swayTransBack=").Append(jbh.swayTransBack)
              .Append(" followRate=[").Append(string.Join(",", jbh.swayFollowRate))
              .Append(']').AppendLine();
            sb.Append("  bindings: eye=")
              .Append(jbh.EyeTarget != null ? jbh.EyeTarget.GetType().Name : "<null>")
              .Append(" face=").Append(jbh.face != null ? "FaceCtrlNative" : "<null>")
              .Append(" dshadow=").Append(jbh.dshadow != null ? "bound" : "<null>")
              .AppendLine();
            sb.Append("  switch literals: modelA=\"").Append(jbh.modelSwitchNameA)
              .Append('"').Append(" modelB=\"").Append(jbh.modelSwitchNameB)
              .Append('"').Append(" glassesA=\"").Append(jbh.glassesNameA)
              .Append('"').Append(" glassesB=\"").Append(jbh.glassesNameB)
              .Append('"').AppendLine();
        }

        sb.Append("  soul: bodyScale=").Append(lastSoulBodyScaleValid
            ? lastSoulBodyScale.ToString("F4") : "invalid")
          .Append(" breast(s/d/f/g)=")
          .Append(lastSoulBreastValid
            ? string.Format("{0:F4}/{1:F4}/{2:F4}/{3:F4}",
                lastSoulBreastStiffness, lastSoulBreastDrag,
                lastSoulBreastFollow, lastSoulBreastGravity)
            : "invalid")
          .Append(" opaiBones=").Append(opaiBonePaths.Count)
          .AppendLine();
        for (var i = 0; i < opaiBonePaths.Count; i++)
        {
            sb.Append("    opai[").Append(i).Append("] ").Append(opaiBonePaths[i])
              .AppendLine();
        }
        sb.Append("  UNKNOWN not applied: bodyScale write, swayBreast mapping,")
          .Append(" DanceIdolInfo flags/literals, face+76 field")
          .AppendLine();
        return sb.ToString();
    }

    private static string Nm(GameObject go)
    {
        return go != null ? go.name : "<null>";
    }
}
