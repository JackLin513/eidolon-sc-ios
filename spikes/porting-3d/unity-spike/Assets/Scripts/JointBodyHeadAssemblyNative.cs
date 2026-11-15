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
    /// Native order (evidence: 0x1C633CC drives Initialize_Post_1 0x1CC1A28 to
    /// completion, then DropShadow.SetShadowMode 0x379A228, then Initialize_Post_2
    /// 0x1CBE770, then is_creation_succeeded=1 @+0x138):
    ///   Initialize_Post_1 (0x1CC1A28, old 0x1C66DB0):
    ///     optionDisplayDict.Clear()          (+0x108)
    ///     swayFollowRate = new float[Enum.GetValues(typeof(SwayBone.swaycategory)).Length]
    ///                                         (+0x128, all zeros; 5 in this build)
    ///     bodyMesh = body.transform.Find("obj_body_GP")   (+0xC0)  → SetBodyMeshs 0x1CBF890
    ///     headMesh = head.transform.Find("obj_head_GP")   (+0xB8)  → SetHeadMeshs 0x1CBFDE4
    ///     if (!start_with_hide) Set_updateWhenOffscreen(true) 0x1CBED20
    ///     headbones fills (children of head "KUBI/ATAMA") + head/body bone reparenting:
    ///       body-side old bone renamed to name+"___"; head-side bone SetParent(body
    ///       "MODEL_00/BASE/MUNE1/MUNE2/KUBI/ATAMA", false); head mesh SetParent(body, true)
    ///     per head mesh: graft bones by name under body "KUBI", replace smr.bones/rootBone
    ///     destroy renamed body bones + head root; create BODY_SCALE under MODEL_00/BASE and
    ///     move MODEL_00's children under it; resolve KUBI/ATAMA/MUNE2/finger paths;
    ///     create Eye_obj under MUNE2 (scale = CharacterSoul bodyScale × Vector3 default one)
    ///     calcBone = Model00.AddComponent&lt;CalcBone&gt;() (+0xF0) — B-suite hook
    ///     CharacterSoul blend pass (`_sle`/`_gla` weights from soul bodySize) — B-suite hook
    ///     GetBoneRot(body.transform) 0x1CBF6E4 → bonesRot (+0xC8)
    ///     EyeTracking + FaceCtrl creation (see <see cref="BindEyeAndFace"/>)
    ///     dshadow = body.AddComponent&lt;DropShadow&gt;() (+0xF8) — B4-owned
    ///   Initialize tail (0x1CBE044): SetShadowMode(shadow, ABShadow)
    ///   Initialize_Post_2 (0x1CBE770): AtamaY = Atama.transform.position.y;
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
            // Native 0x1CBE770 throws NRE (sub_84DD18) on an unresolved node.
            Debug.LogWarning("JointBodyHeadAssemblyNative.RunPostInitialize: " +
                             "jbh.body/head unresolved (native Initialize_Post_2 would NRE)");
            return false;
        }

        // ---- Initialize_Post_1 supplement (0x1CC1A28), only for missing products ----

        if (jbh.headMesh == null)
            jbh.headMesh = jbh.head.transform.Find(JointBodyHeadNative.NameHeadMesh);
        if (jbh.bodyMesh == null)
            jbh.bodyMesh = jbh.body.transform.Find(JointBodyHeadNative.NameBodyMesh);

        if (jbh.bodyMesh != null && jbh.bodymeshes.Count == 0)
            jbh.SetBodyMeshs(jbh.bodyMesh, null);           // 0x1CBF890
        if (jbh.headMesh != null && jbh.headmeshes.Count == 0)
            jbh.SetHeadMeshs(jbh.headMesh, null);           // 0x1CBFDE4

        if (jbh.bonesRot != null && jbh.bonesRot.Count == 0)
        {
            jbh.GetBoneRot(jbh.body.transform);             // 0x1CBF6E4
            filledBonesRotThisRun = true;
        }

        if (jbh.Position == null)
        {
            jbh.AddPositionNode();                          // 0x1CBEBAC
            filledPositionThisRun = true;
        }

        // ---- head/body model tops (0x1CBF338 / 0x1CBF354) ----
        //
        // Native reads the *model node found under the bundle root* (+0xB8 headMesh /
        // +0xC0 bodyMesh, then get_gameObject) and NREs when unset — NOT the bundle root.
        // Keep the same semantics; fall back to the root only when the supplement above
        // could not resolve the model node.
        headTop = TopOr(jbh.headMesh, jbh.head);
        bodyTop = TopOr(jbh.bodyMesh, jbh.body);

        // ---- Initialize_Post_2 (0x1CBE770), same AtamaY/EyesY semantics as jbh ----
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
    /// JointBodyHead.ApplyModelSwitch 0x1CBFC0C (old 0x1C64F94) delegate:
    ///   if render==null return; var tr=render.transform; if info==null return; if tr==null return;
    ///   var asm = info.assem_info(+0xE8);
    ///   if (asm != null &amp;&amp; asm.is_release_model_switch(+0xC5)==1) {
    ///     if (tr.name.EndsWith("_switch"))   SetOptionDisplay(render, asm.enable_model_switch(+0xC4));
    ///     if (tr.name.EndsWith("_switch_r")) SetOptionDisplay(render, asm.enable_model_switch(+0xC4)==0);
    ///   }
    /// </summary>
    public void ApplyModelSwitch(UnityEngine.SkinnedMeshRenderer render, object info)
    {
        jbh.ApplyModelSwitch(render, info);
    }

    /// <summary>
    /// JointBodyHead.ApplyGlassesSwitch 0x1CC019C (old 0x1C65524) delegate:
    ///   gates on assem_info(+0xE8) bytes +0xC6|+0xC7, takes glasses_model_ver (+0xCC),
    ///   compares the renderer transform name against "_gls_base" and the
    ///   "_gls_v"+two-digit grammar, then SetOptionDisplay 0x1CBF498.
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

    /// <summary>JointBodyHead.SetVisible 0x1CBEF18 delegate: SkinnedMeshRenderer loop
    /// (sharedMaterials.Length != 0 → enabled = show), DropShadow.LightAndShadowByChara,
    /// and SetPinLightState through the jbh.dshadow slot (B4 component).</summary>
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

    /// <summary>JointBodyHead.MeasureSway 0x1CBF254 (old 0x1C645DC) delegate; the native
    /// combine of the two sums (updateSwayTime +0x90 / sideLineHitTime +0x94) is lost in
    /// the decompile, so jbh keeps both exposed via the out-overload.</summary>
    public float MeasureSway()
    {
        return jbh.MeasureSway();
    }

    public void MeasureSway(out float updateSwayTime, out float sideLineHitTime)
    {
        jbh.MeasureSway(out updateSwayTime, out sideLineHitTime);
    }

    // =====================================================================
    // BindEyeAndFace — Initialize_Post_1 tail steps (0x1CC1A28, old 0x1C66DB0)
    // =====================================================================

    /// <summary>
    /// Stores the eye/face parts in the same slots the native Post_1 tail fills.
    /// This only binds JointBodyHeadNative's fields — the components themselves
    /// are created/initialised by the bootstrap exactly as before (B3/B4 files
    /// are untouched). The resolved native order at the call site:
    ///
    ///   1. (eye, only when DanceIdolInfo+0xB8 byte == 1)
    ///        info.model(+0x98) = jbh                 (back-reference)
    ///        eye = jbh.Eye(+0x80).AddComponent&lt;EyeTracking&gt;()
    ///        jbh.EyeTarget(+0xE0) = eye
    ///        EyeTracking.Init(info)                  0x3877EA0
    ///   2. (face, unconditional)
    ///        face = new FaceCtrl(objName, info);     0x3879B3C
    ///        jbh.face(+0xE8) = face
    ///        if (soul+0x44 byte == 1) face+0x4C = soul+0x48 (int)   ← CharacterSoul.cheekReddenIntensity
    ///        FaceCtrl.Init(CharacterManager.GetFaceBlendParam())    0x387A4D8
    ///   3. (shadow)
    ///        jbh.dshadow(+0xF8) = body.AddComponent&lt;DropShadow&gt;()
    ///        DropShadow.SetShadowMode 0x379A228 runs later in Initialize 0x1CBE044.
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
    /// CharacterSoul.bodyScale — diagnostics only. The one native write that consumes it
    /// is in Initialize_Post_1 0x1CC1A28: Eye_obj.localScale =
    /// soul.bodyScale.value(+0x24) × Vector3 static default (= one) for x/y/z; that write
    /// is performed by <see cref="JointBodyHeadNative.InitializePost1"/> through
    /// <see cref="JointBodyHeadNative.eyeScaleProvider"/>, and this method only records the
    /// observed value for the probe. (Earlier notes claimed the BODY_SCALE node was scaled
    /// from a CharacterManager dictionary entry; the actual Post_1 code sets BodyScale
    /// localPosition = zero and scales only Eye_obj — decomp wins.)
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
    /// Binds the CharacterSoul bodyScale value (per idol, per swing) into the native
    /// Eye_obj scale consumer for this JointBodyHead instance. Call it after the soul is
    /// resolved and before Initialize/Post_1 runs; `null` restores the neutral 1.0.
    /// </summary>
    public void BindSoulBodyScale(float bodyScale, bool valid)
    {
        lastSoulBodyScale = bodyScale;
        lastSoulBodyScaleValid = valid;
        JointBodyHeadNative.eyeScaleProvider = valid
            ? (Func<JointBodyHeadNative.IDanceIdolInfoFlags, float>)(_ => bodyScale)
            : null;
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
            sb.Append("  switch grammar: model=\"_switch\"/\"_switch_r\", glasses=\"_gls_base\"/\"_gls_v\"+2 digits")
              .AppendLine();
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
        sb.Append("  UNKNOWN not applied: swayBreast mapping (B2 fields), face+0x4C field,")
          .Append(" CalcBone/blend-shape/EyeTracking/FaceCtrl creation (B3/B4 hooks)")
          .AppendLine();
        return sb.ToString();
    }

    private static string Nm(GameObject go)
    {
        return go != null ? go.name : "<null>";
    }
}
