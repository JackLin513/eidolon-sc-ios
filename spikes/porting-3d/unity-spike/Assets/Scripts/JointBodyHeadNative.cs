// Native-faithful port of `Imas.BoneLib.JointBodyHead` (dump.cs TypeDefIndex 15607) plus
// the assembly/switch skeleton it drives (ADR-0033 B5).
//
// Evidence: Hex-Rays bodies of the CURRENT shipped binary from /tmp/unk2-decomp/
// (files `JointBodyHead__old_<oldRVA>__new_<newRVA>.c`, body = function at <newRVA>)
// plus /tmp/decomp2/ (`JointBodyHead_<Method>.c`) for the methods outside that set.
// Region delta old→new RVA = +0x5AC78; the comments below cite the CURRENT RVA.
//   SetVisible                         0x1CBEF18  (old 0x1C642A0)
//   MeasureSway                        0x1CBF254  (old 0x1C645DC)
//   SetBodyMeshs                       0x1CBF890  (old 0x1C64C18)
//   SetHeadMeshs                       0x1CBFDE4  (old 0x1C6516C)
//   ApplyModelSwitch                   0x1CBFC0C  (old 0x1C64F94)
//   ApplyGlassesSwitch                 0x1CC019C  (old 0x1C65524)
//   Initialize_Post_1.MoveNext         0x1CC1A28  (old 0x1C66DB0 — the real assembly order)
//   .ctor() 0x1CBDB24, .ctor(int) 0x1CBDE10, Initialize 0x1CBE044,
//   Initialize_Post_1 0x1CBE6C0, Initialize_Post_2 0x1CBE770, AddPositionNode 0x1CBEBAC,
//   Set_updateWhenOffscreen 0x1CBED20, SwaySwitch 0x1CBF1AC, GetHeadModelTop 0x1CBF338,
//   GetBodyModelTop 0x1CBF354, GetDropShadow 0x1CBF370, SetWingLimit 0x1CBF378,
//   SetOptionDisplay 0x1CBF498, InitializeDisplay 0x1CBF598, GetBoneRot 0x1CBF6E4,
//   SwayManagerAllON 0x1CBD9A0, skirt_GP_SwayManagerCtrl 0x1CBDA38, Reset 0x1CBE7D0,
//   GetInitRot 0x1CBD424, serchChild 0x1CC0614, serchChildRrecursive 0x1CC06E4.
//
// String literals are IL2CPP metadata-usage slots and ARE statically resolvable: every
// literal below was read from /tmp/ild/script.json `ScriptString`, keyed by the slot
// address printed by Hex-Rays (e.g. qword_98E2DA8 → "wing"). No literal in this file is a
// guess; the previous "IL2CPP literal slots cannot be resolved statically" note was wrong.
//
// OUT OF SCOPE (Live orchestration, listed so the gap stays explicit):
//   InitializeAsync 0x1CBE9B4 (AssetBundleLoadResourceOperation / loading progress),
//   Initialize_Post_1's bundle-wait states and its 5 ms `EarlyAdopter.stopWatch` yields
//   (the spike has no async load, so Initialize runs the same steps without yielding),
//   MovePosition 0x1CBD574 / RePosition 0x1CBD904 (stage placement / lift),
//   Finalize/Dispose 0x1CBDD50/0x1CBDDF4, boneDump 0x1CC0884 / weightDump 0x1CC0988 /
//   bindPoseDump 0x1CC1068 (debug dumps), and the Live-stage consumers of the created
//   nodes (CharacterManager soul data, EyeTracking/FaceCtrl/DropShadow ownership is
//   wired by B4; see the hooks below).
//
// ---------------------------------------------------------------------------
// Sway runtime arrays — what actually lives on JointBodyHead
// ---------------------------------------------------------------------------
// dump.cs 15607 declares exactly ONE sway runtime array on this class:
//     public float[] swayFollowRate;   // 0x128
// plus `swayOn` 0x104 and `swayTransBack` 0x105.
// `swayFollowSW`, `swayDamper` and `vecs1` are NOT JointBodyHead fields:
//     IdolPositionMgr.swayFollowSW   (dump.cs 16396, 0x30)
//     IdolPositionMgr.swayDamper     (dump.cs 16396, 0x38)
//     EventScenarioData.vecs1        (dump.cs ~536724, 0x138)
// i.e. they are Live-stage data owned by the stage/formation manager, which is out of
// scope here. This class therefore pushes only what the binary really has:
// `swayFollowRate`, `swayTransBack`, `swayOn`.
//
// swayFollowRate's native default (Post_1 @0x1CC1A28, resolved):
//     int n = Enum.GetValues(typeof(SwayBone.swaycategory)).Length;
//     swayFollowRate = new float[n];
// i.e. N is the SwayCategory enum count (5 in this build: Normal/Hair/Skirt/Opai/
// SideHair), NOT a global manager-list count. All entries are zero; a zero rate means
// "fall through to the bone's own followForce" in SwayBoneMT.SwayMove, so the two
// readings are value-equivalent, but the count is now pinned.

using System;
using System.Collections.Generic;
using System.Text;
using UnityEngine;

/// <summary>Imas.BoneLib.JointBodyHead (dump.cs 15271). Fields kept in native order.</summary>
public sealed class JointBodyHeadNative : MonoBehaviour
{
    // SwayCategory count = SwayCategory { Normal, Hair, Skirt, Opai, SideHair } (B2).
    public const int SwayCategoryCount = 5;

    // Native name constants — every value is a resolved ScriptString literal (slot address
    // in the comment), not a guess. The previous note that IL2CPP metadata-usage literal
    // slots are statically unresolvable was wrong; /tmp/ild/script.json resolves all of them.
    public const string NamePosition = "POSITION";        // 0x98B0488 (AddPositionNode 0x1CBEBAC)
    public const string NameModel00 = "MODEL_00";         // 0x98AC2D0
    public const string NameBodyScale = "BODY_SCALE";     // 0x989B638 / 0x98AC2F0
    public const string NameBase = "BASE";                // path segment of 0x98AC2F8
    public const string NameAtama = "ATAMA";              // 0x9899D60
    public const string NameKubi = "KUBI";                // 0x98AAEC8
    public const string NameMune2 = "MUNE2";              // path segment of 0x98AC2E0
    public const string NameRFinger =
        "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_R/KATA_R/UDE_R/TE_R/HITO3_R/HITO2_R/HITO1_R"; // 0x98AC5A0
    public const string NameLFinger =
        "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L/TE_L/HITO3_L/HITO2_L/HITO1_L"; // 0x98AC4A0
    public const string NameEye = "Eye_obj";              // 0x98A4930
    public const string NameSkirtGP = "skirt_GP";         // skirt_GP_SwayManagerCtrl (old 0x1C62DC0)
    // Post_1 (0x1CC1A28) transform literals.
    public const string NameBodyMesh = "obj_body_GP";     // 0x98D70E8
    public const string NameHeadMesh = "obj_head_GP";     // 0x98D70F0
    public const string NameKubiAtama = "KUBI/ATAMA";     // 0x98AAED0
    public const string NameBodyKubiAtama = "MODEL_00/BASE/MUNE1/MUNE2/KUBI/ATAMA"; // 0x98AC2E0
    public const string NameOldBoneSuffix = "___";        // 0x98BFEC0

    // =====================================================================
    // Fields (dump.cs offsets in comments)
    // =====================================================================

    public int jbhIndex;                        // 0x10
    public GameObject body;                     // 0x18
    public GameObject Position;                 // 0x20
    public GameObject Model00;                  // 0x28
    public GameObject BodyScale;                // 0x30
    public GameObject Base;                     // 0x38
    public GameObject Atama;                    // 0x40
    public SwayBoneNative wingL;                // 0x48
    public SwayBoneNative wingR;                // 0x50
    public float AtamaY;                        // 0x58
    public float EyesY;                         // 0x5C
    public GameObject Kubi;                     // 0x60
    public GameObject Mune2;                    // 0x68
    public GameObject RFinger;                  // 0x70
    public GameObject LFinger;                  // 0x78
    public GameObject Eye;                      // 0x80
    public bool isV2;                           // 0x88

    public GameObject head;                     // 0x90
    public readonly List<HeadMeshRef> headmeshes = new List<HeadMeshRef>(); // 0x98
    public readonly List<BodyMeshRef> bodymeshes = new List<BodyMeshRef>(); // 0xA0
    public readonly List<string> headbones = new List<string>();            // 0xA8
    public Transform kubiTrans;                 // 0xB0
    public Transform headMesh;                  // 0xB8
    public Transform bodyMesh;                  // 0xC0
    public readonly List<BoneInitRot> bonesRot = new List<BoneInitRot>();   // 0xC8
    public Vector3 initPos;                     // 0xD0

    public Component EyeTarget;                 // 0xE0 (B4: EyeTrackingNative)
    public FaceCtrlNative face;                 // 0xE8
    public CalcBoneNative calcBone;             // 0xF0
    public Component dshadow;                   // 0xF8 (B4: DropShadowNative)
    public float scale = 1f;                    // 0x100 (ctor literal 1.0f)
    public bool swayOn = true;                  // 0x104 (ctor literal true)
    public bool swayTransBack;                  // 0x105
    public readonly Dictionary<Renderer, bool> optionDisplayDict = new Dictionary<Renderer, bool>(); // 0x108

    public readonly List<SwayBoneNative> swb = new List<SwayBoneNative>();  // 0x110
    public readonly List<SwayManagerNative> swm = new List<SwayManagerNative>(); // 0x118

    public float ResolveDepthFactor = 0.9f;     // 0x120 (ctor literal 0.9f)
    public float[] swayFollowRate = new float[SwayCategoryCount];            // 0x128
    public SwayCtrlMTNative swayMT;             // 0x130
    public bool is_creation_succeeded;          // 0x138
    public bool destroy_loadedResource_soon;    // 0x139
    public bool is_creation_start_with_hide;    // 0x13A

    /// <summary>Optional hook so the assembly can drive FaceCtrl/EyeTracking without a hard
    /// dependency on B3/B4 types (the Lead wires them).</summary>
    [NonSerialized] public Action<JointBodyHeadNative> onAssembled;

    // =====================================================================
    // Nested native helper classes (dump.cs 15266 / 15267 / 15268)
    // =====================================================================

    /// <summary>Imas.BoneLib.HeadMeshRef (15266).</summary>
    public sealed class HeadMeshRef
    {
        public GameObject obj;
        public List<string> bones = new List<string>();
    }

    /// <summary>Imas.BoneLib.BodyMeshRef (15267).</summary>
    public sealed class BodyMeshRef
    {
        public GameObject obj;
        public int KUBI_index = -1;
        public int ATAMA_index = -1;
    }

    /// <summary>Imas.BoneLib.BoneInitRot (15268).</summary>
    public sealed class BoneInitRot
    {
        public GameObject obj;
        public Quaternion rot;
    }

    // =====================================================================
    // Constructors
    // =====================================================================

    /// <summary>
    /// JointBodyHead..ctor(int index) 0x1C63198:
    ///   headmeshes/bodymeshes/headbones/bonesRot = new List<>,
    ///   scale = 1.0f, swayOn = true, optionDisplayDict = new Dictionary<>(),
    ///   ResolveDepthFactor = 0.9f, jbhIndex = index, swayMT = new SwayCtrlMT(this, 0).
    /// The field initialisers above already carry the same literals; this method exists
    /// so a caller that mirrors the native `new JointBodyHead(i)` path has an entry.
    /// </summary>
    public void ResetToCtorDefaults(int index)
    {
        jbhIndex = index;
        headmeshes.Clear();
        bodymeshes.Clear();
        headbones.Clear();
        bonesRot.Clear();
        optionDisplayDict.Clear();
        swb.Clear();
        swm.Clear();
        scale = 1f;
        swayOn = true;
        swayTransBack = false;
        ResolveDepthFactor = 0.9f;
        swayFollowRate = new float[SwayCategoryCount];
        swayMT = new SwayCtrlMTNative();
        is_creation_succeeded = false;
        is_creation_start_with_hide = false;
        destroy_loadedResource_soon = false;
        isV2 = false;
    }

    // =====================================================================
    // Assembly
    // =====================================================================

    /// <summary>
    /// Native `Initialize(string objName, AssetBundle ABHead, AssetBundle ABbody,
    /// AssetBundle ABShadow, DanceIdolInfo info, DropShadow.Shadow shadow,
    /// bool start_with_hide, bool is_bloom_enabled)` 0x1C633CC, with the bundle/asset
    /// loading replaced by already-instantiated GameObjects (the spike loads its own
    /// prefabs in CharacterBootstrap; there is no AssetBundleLoadResourceOperation).
    ///
    /// Order preserved from the decompiled body:
    ///   1 is_creation_succeeded = false
    ///   2 body  = loaded body root; DestroyAndHide(body.Find(objName), …)
    ///   3 SetActive(body, false)                 (sub_357E268)
    ///   4 head  = loaded head root; DestroyAndHide(head.Find(objName), …)
    ///   5 SetActive(head, false)
    ///   6 drive Initialize_Post_1 to completion  (the coroutine's states are flattened
    ///     here because nothing is awaited any more)
    ///   7 dshadow.Initialize(shadow, ABShadow)   (0x379A228 — B4 owns DropShadow)
    ///   8 Initialize_Post_2()
    ///   9 is_creation_succeeded = true
    /// </summary>
    public bool Initialize(GameObject bodyGo, GameObject headGo, string objName,
        bool start_with_hide = false, bool is_bloom_enabled = true,
        IDanceIdolInfoFlags info = null)
    {
        is_creation_succeeded = false;
        destroy_loadedResource_soon = false;
        is_creation_start_with_hide = start_with_hide;

        if (bodyGo == null) return false;
        body = bodyGo;
        Position = null;

        if (headGo == null) return false;
        head = headGo;

        // Initialize_Post_1 0x1CC1A28 (old 0x1C66DB0). The native iterator yields for
        // the 5 ms EarlyAdopter.stopWatch budget between head-bone grafts; the spike has
        // no AssetBundle load, so every state runs synchronously in the same order.
        if (!InitializePost1(objName, info, start_with_hide)) return false;

        AddPositionNode();          // 0x1CBEBAC (old 0x1C63F34)
        InitializeDisplay();        // 0x1CBF598 (old 0x1C64920)

        // 0x1CBE044 tail: DropShadow.Initialize(shadow, ABShadow) is B4-owned; the hook
        // lets the binder run DropShadow.SetShadowMode 0x379A228 / EyeTracking.Init /
        // FaceCtrl.Init in the native order.
        onAssembled?.Invoke(this);

        Initialize_Post_2();        // 0x1CBE770 (old 0x1C63AF8)

        is_creation_succeeded = true;
        return true;
    }

    /// <summary>
    /// JointBodyHead.Initialize_Post_1.MoveNext 0x1CC1A28 (old 0x1C66DB0), synchronous
    /// flattening of the iterator (state 0 + the 5 ms resume). Native order:
    ///   optionDisplayDict.Clear(); swayFollowRate = new float[SwayCategoryCount];
    ///   bodyMesh = body.transform.Find("obj_body_GP"); headMesh = head.transform.Find("obj_head_GP");
    ///   SetBodyMeshs(bodyMesh, info); SetHeadMeshs(headMesh, info);
    ///   if (!start_with_hide) Set_updateWhenOffscreen(true);
    ///   headbones = children of head.transform.Find("KUBI/ATAMA");
    ///   per bone: rename body-side old bone to name+"___", head-side bone SetParent(body KUBI/ATAMA, false);
    ///   headMesh.SetParent(body.transform, true); kubiTrans = serchChild(body, "KUBI");
    ///   per head mesh: graft bones by name under kubiTrans, replace smr.bones/rootBone;
    ///   destroy old body-side bones and the head root;
    ///   create BODY_SCALE under MODEL_00/BASE and move MODEL_00's children under it;
    ///   resolve KUBI/ATAMA/MUNE2/finger paths, create Eye_obj under MUNE2;
    ///   clear/re-capture bonesRot; renderer shadow baseline.
    /// Steps left to the hooks (Live-only data): CalcBone AddComponent (+0xF0), the
    /// CharacterSoul blend-shape pass (`_sle`/`_gla`), EyeTracking/FaceCtrl creation and
    /// dshadow = body.AddComponent&lt;DropShadow&gt;() (+0xF8).
    /// </summary>
    private bool InitializePost1(string objName, IDanceIdolInfoFlags info, bool start_with_hide)
    {
        optionDisplayDict.Clear();
        AllocateSwayFollowRate();
        if (swayMT == null) swayMT = new SwayCtrlMTNative();

        // bodyMesh(+0xC0) = body.transform.Find("obj_body_GP");
        // headMesh(+0xB8) = head.transform.Find("obj_head_GP"); (Transform.Find, not a deep search)
        bodyMesh = body.transform.Find(NameBodyMesh);
        if (bodyMesh == null) return false;                 // native returns false
        headMesh = head.transform.Find(NameHeadMesh);
        if (headMesh == null) return false;

        SetBodyMeshs(bodyMesh, info);                       // 0x1CBF890
        SetHeadMeshs(headMesh, info);                       // 0x1CBFDE4

        if (!start_with_hide) Set_updateWhenOffscreen(true); // 0x1CBED20

        // headbones: direct children of the head's KUBI/ATAMA node.
        var atamaRoot = head.transform.Find(NameKubiAtama);
        if (atamaRoot == null) return false;
        headbones.Clear();
        for (var i = 0; i < atamaRoot.childCount; i++) headbones.Add(atamaRoot.GetChild(i).name);

        // Bone reparenting: the body-side old bone is renamed with the "___" suffix and
        // the head-side bone is moved under the body-side KUBI/ATAMA (worldPositionStays = false).
        var tBody = body.transform.Find(NameBodyKubiAtama);
        if (tBody == null) return false;
        for (var i = 0; i < headbones.Count; i++)
        {
            var boneName = headbones[i];
            var old = body.transform.Find(NameBodyKubiAtama + "/" + boneName);
            if (old != null) old.name = boneName + NameOldBoneSuffix;
            var tHead = head.transform.Find(NameKubiAtama + "/" + boneName);
            if (tHead == null) return false;
            tHead.SetParent(tBody, false);
        }

        headMesh.SetParent(body.transform, true);           // worldPositionStays = true
        kubiTrans = serchChild(body.transform, NameKubi);
        if (kubiTrans == null) return false;

        // Head-mesh bone grafting (the iterator yields here every 5 ms; flattened).
        for (var i = 0; i < headmeshes.Count; i++)
        {
            var rf = headmeshes[i];
            var graft = new List<Transform>();
            var names = rf.bones;
            if (names != null)
            {
                for (var k = 0; k < names.Count; k++)
                {
                    var t = serchChild(kubiTrans, names[k]);
                    if (t != null) graft.Add(t);            // native passes the lookup result through
                }
            }
            var smr = rf.obj != null ? rf.obj.GetComponent<SkinnedMeshRenderer>() : null;
            if (smr != null)
            {
                smr.bones = graft.ToArray();
                smr.rootBone = kubiTrans;
            }
        }

        // Destroy the renamed old body-side bones, then the (now emptied) head root.
        for (var i = 0; i < headbones.Count; i++)
        {
            var old = body.transform.Find(NameBodyKubiAtama + "/" + headbones[i] + NameOldBoneSuffix);
            if (old != null) Destroy(old.gameObject);
        }
        if (head != null) Destroy(head);

        // MODEL_00 children (captured before BODY_SCALE exists) move under a new BODY_SCALE
        // node parented to MODEL_00/BASE.
        Model00 = FindGo(body.transform, NameModel00);
        if (Model00 == null) return false;
        var modelTr = Model00.transform;
        var kids = new Transform[modelTr.childCount];
        for (var i = 0; i < kids.Length; i++) kids[i] = modelTr.GetChild(i);

        Base = FindGo(body.transform, "MODEL_00/BASE");
        if (Base == null) return false;

        var bodyScaleGo = new GameObject(NameBodyScale);
        BodyScale = bodyScaleGo;
        bodyScaleGo.transform.localPosition = Vector3.zero;
        bodyScaleGo.transform.SetParent(Base.transform, false);
        for (var i = 0; i < kids.Length; i++)
            if (kids[i] != null) kids[i].SetParent(bodyScaleGo.transform, false);

        // Reference nodes after the BODY_SCALE insertion.
        Kubi = FindGo(body.transform, "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/KUBI");
        Atama = FindGo(body.transform, "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/KUBI/ATAMA");
        Mune2 = FindGo(body.transform, "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2");
        RFinger = FindGo(body.transform, NameRFinger);
        LFinger = FindGo(body.transform, NameLFinger);
        if (Kubi == null || Atama == null || Mune2 == null) return false;

        // Eye_obj: empty gaze anchor under MUNE2. Native scales it with the CharacterSoul
        // body-scale value (soul.Value+0x24) times a Vector3 static (the default = one);
        // the soul lookup needs CharacterManager (Live-only), so a seam supplies the
        // factor and its neutral default is 1.0.
        var eyeGo = new GameObject(NameEye);
        Eye = eyeGo;
        eyeGo.transform.localPosition = Vector3.zero;
        eyeGo.transform.SetParent(Mune2.transform, false);
        var eyeScale = eyeScaleProvider != null ? eyeScaleProvider(info) : 1f;
        eyeGo.transform.localScale = new Vector3(eyeScale, eyeScale, eyeScale);

        // 0x1CBF6E4: bonesRot is cleared and re-captured over the whole body.
        bonesRot.Clear();
        GetBoneRot(body.transform);

        // Renderer baseline: receiveShadows = false, shadowCastingMode = Off,
        // lightProbeUsage = Off over body.GetComponentsInChildren&lt;Renderer&gt;().
        foreach (var r in body.GetComponentsInChildren<Renderer>(true))
        {
            if (r == null) continue;
            r.receiveShadows = false;
            r.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            r.lightProbeUsage = UnityEngine.Rendering.LightProbeUsage.Off;
        }
        return true;
    }

    /// <summary>
    /// Initialize_Post_1 0x1CC1A28 (old 0x1C66DB0) head, resolved:
    ///   int n = Enum.GetValues(typeof(SwayBone.swaycategory)).Length;
    ///   swayFollowRate(+0x128) = new float[n];   // zero-filled
    /// The native sink is `sub_671BD44(swaycategory_var)` (Enum.GetValues) followed by
    /// Array.get_Length, so the length is the SwayCategory enum count (5 in this build),
    /// not a manager-list count.
    /// </summary>
    private void AllocateSwayFollowRate()
    {
        var n = Enum.GetValues(typeof(SwayCategory)).Length;
        if (swayFollowRate == null || swayFollowRate.Length != n)
            swayFollowRate = new float[n];
        for (var i = 0; i < swayFollowRate.Length; i++) swayFollowRate[i] = 0f;
    }

    /// <summary>
    /// JointBodyHead.Initialize_Post_2 0x1C63AF8, verbatim:
    ///   AtamaY = Atama.transform.position.y;
    ///   EyesY  = Eye.transform.position.y;
    /// (both `.y` components; the decompiled body reads the Vector3 and stores s1).
    /// </summary>
    public void Initialize_Post_2()
    {
        if (Atama == null || Eye == null)
        {
            // Native throws (sub_84DD18 = NullReferenceException) on a null node.
            Debug.LogWarning("JointBodyHead.Initialize_Post_2: Atama/Eye unresolved " +
                             "(native would NRE at 0x1C63AF8)");
            return;
        }
        AtamaY = Atama.transform.position.y;
        EyesY = Eye.transform.position.y;
    }

    /// <summary>
    /// JointBodyHead.AddPositionNode 0x1CBEBAC (old 0x1C63F34), verbatim:
    ///   var t = body.transform.Find("POSITION");            // Transform.Find, direct child
    ///   if (t != null) Position(+0x20) = t.gameObject;
    ///   else { var go = new GameObject(); go.name = "POSITION";
    ///          go.transform.SetParent(body.transform, true); Position = go; }
    /// </summary>
    public void AddPositionNode()
    {
        if (body == null) return;
        var found = body.transform.Find(NamePosition);
        if (found != null)
        {
            Position = found.gameObject;
            return;
        }
        var go = new GameObject(NamePosition);
        Position = go;
        go.transform.SetParent(body.transform, true);
    }

    /// <summary>
    /// JointBodyHead.SetBodyMeshs 0x1CBF890 (old 0x1C64C18), fills bodymeshes (+0xA0):
    ///   for i in 0..top.childCount-1:
    ///     child = top.GetChild(i); render = child.GetComponent&lt;SkinnedMeshRenderer&gt;();
    ///     ApplyModelSwitch(render, info);                               // 0x1CBFC0C
    ///     if (child.name.Equals("wing"))                                // literal 0x98E2DA8
    ///         SetOptionDisplay(render, assem_info(+0xE8).costume_number_changed(+0xD6) == 0);
    ///     if (render == null) continue;                                 // op_Inequality
    ///     bm = new BodyMeshRef { obj = child.gameObject, KUBI_index = -1, ATAMA_index = -1 };
    ///     for k in render.bones: if (bones[k].name.Equals("KUBI"))  bm.KUBI_index  = k;
    ///                            if (bones[k].name.Equals("ATAMA")) bm.ATAMA_index = k;
    ///     bodymeshes.Add(bm);
    /// The KUBI/ATAMA indices come from the renderer's BONE list, NOT from sharedMaterials
    /// (the earlier port read material names; that was wrong). The native "wing" gate
    /// dereferences info/assem_info without a null guard; with no info the port skips that
    /// display write instead of throwing.
    /// </summary>
    public void SetBodyMeshs(Transform top, object info)
    {
        if (top == null) return;
        for (var i = 0; i < top.childCount; i++)
        {
            var child = top.GetChild(i);
            if (child == null) continue;
            var render = child.GetComponent<SkinnedMeshRenderer>();
            ApplyModelSwitch(render, info);

            if (string.Equals(child.name, "wing", StringComparison.Ordinal))
            {
                // UNKNOWN(native 0x1CBF890): native has no null guard on info/assem_info
                // here (it NREs); the port skips the write when the flag source is absent.
                var asm = info as IPartsAssembleInfoFlags;
                if (asm != null) SetOptionDisplay(render, !asm.CostumeNumberChanged);
            }

            if (render == null) continue;

            var bm = new BodyMeshRef { obj = child.gameObject, KUBI_index = -1, ATAMA_index = -1 };
            var bones = render.bones;
            if (bones != null)
            {
                for (var k = 0; k < bones.Length; k++)
                {
                    var bone = bones[k];
                    if (bone == null) continue;
                    var boneName = bone.name;
                    if (string.Equals(boneName, NameKubi, StringComparison.Ordinal)) bm.KUBI_index = k;
                    if (string.Equals(boneName, NameAtama, StringComparison.Ordinal)) bm.ATAMA_index = k;
                }
            }
            bodymeshes.Add(bm);
        }
    }

    /// <summary>
    /// DanceIdolInfo.assem_info (PartsAssembleInfo, DanceIdolInfo+0xE8) field read by
    /// SetBodyMeshs' "wing" gate: `costume_number_changed` (+0xD6). Implement it on the
    /// object passed as `info`; when absent the wing display write is skipped (native NREs).
    /// </summary>
    public interface IPartsAssembleInfoFlags
    {
        bool CostumeNumberChanged { get; }
    }

    /// <summary>
    /// JointBodyHead.SetHeadMeshs 0x1CBFDE4 (old 0x1C6516C):
    ///   for each child of top:
    ///     render = child.GetComponent&lt;SkinnedMeshRenderer&gt;();
    ///     ApplyModelSwitch(render, info); ApplyGlassesSwitch(render, info);
    ///     if (render == null) { SetHeadMeshs(child, info); continue; }      // depth-first
    ///     href = new HeadMeshRef { obj = child.gameObject, bones = new List&lt;string&gt;() };
    ///     for k in render.bones: href.bones.Add(bones[k].name);             // no dedupe
    ///     headmeshes(+0x98).Add(href);
    /// Recursion walks the sub-trees that carry no renderer, so nested head parts are
    /// included; the bone names are later grafted by name under KUBI in InitializePost1.
    /// </summary>
    public void SetHeadMeshs(Transform top, object info)
    {
        if (top == null) return;
        for (var i = 0; i < top.childCount; i++)
        {
            var child = top.GetChild(i);
            if (child == null) continue;
            var render = child.GetComponent<SkinnedMeshRenderer>();
            ApplyModelSwitch(render, info);
            ApplyGlassesSwitch(render, info);
            if (render == null)
            {
                SetHeadMeshs(child, info);
                continue;
            }

            var href = new HeadMeshRef { obj = child.gameObject };
            var bones = render.bones;
            if (bones != null)
            {
                for (var b = 0; b < bones.Length; b++)
                    if (bones[b] != null && bones[b].name != null) href.bones.Add(bones[b].name);
            }
            headmeshes.Add(href);
        }
    }

    /// <summary>
    /// JointBodyHead.GetBoneRot 0x1C64A6C (recursive): for every child of `top`, add
    /// `{ obj = child.gameObject, rot = child.localRotation }` to bonesRot and recurse.
    /// This is the bind-pose snapshot GetInitRot answers from.
    /// </summary>
    public void GetBoneRot(Transform top)
    {
        if (top == null) return;
        for (var i = 0; i < top.childCount; i++)
        {
            var child = top.GetChild(i);
            if (child == null) continue;
            bonesRot.Add(new BoneInitRot { obj = child.gameObject, rot = child.localRotation });
            if (child.childCount >= 1) GetBoneRot(child);
        }
    }

    /// <summary>
    /// JointBodyHead.GetInitRot 0x1C627AC: linear scan of bonesRot for `obj`; returns
    /// `Quaternion.identity` (the static identity, `off_9707A30`) when not found.
    /// </summary>
    public Quaternion GetInitRot(GameObject obj)
    {
        for (var i = 0; i < bonesRot.Count; i++)
        {
            var e = bonesRot[i];
            if (e != null && ReferenceEquals(e.obj, obj)) return e.rot;
        }
        return Quaternion.identity;
    }

    /// <summary>
    /// JointBodyHead.InitializeDisplay 0x1C64920:
    ///   is_creation_start_with_hide = false;
    ///   foreach renderer in body.GetComponentsInChildren&lt;Renderer&gt;():
    ///       r.enabled = optionDisplayDict.TryGetValue(r) ? value : true;
    /// </summary>
    public void InitializeDisplay()
    {
        is_creation_start_with_hide = false;
        if (body == null) return;
        foreach (var r in body.GetComponentsInChildren<Renderer>(true))
        {
            if (r == null) continue;
            r.enabled = !optionDisplayDict.TryGetValue(r, out var vis) || vis;
        }
    }

    /// <summary>
    /// JointBodyHead.SetOptionDisplay 0x1C64820:
    ///   if (renderer == null) return;
    ///   optionDisplayDict[renderer] = sw;
    ///   if (!is_creation_start_with_hide) renderer.enabled = sw;
    /// </summary>
    public void SetOptionDisplay(Renderer renderer, bool sw)
    {
        if (renderer == null) return;
        optionDisplayDict[renderer] = sw;
        if (!is_creation_start_with_hide) renderer.enabled = sw;
    }

    /// <summary>
    /// JointBodyHead.ApplyModelSwitch 0x1CBFC0C (old 0x1C64F94), verbatim:
    ///   if (render == null) return;
    ///   var tr = render.transform;
    ///   if (info == null) return;                 // (decomp checks info after transform)
    ///   if (tr == null) return;
    ///   var asm = info.assem_info(+0xE8);
    ///   if (asm != null &amp;&amp; asm.is_release_model_switch(+0xC5) == 1) {
    ///       var n = render.transform.name;
    ///       if (n.EndsWith("_switch"))   SetOptionDisplay(render, asm.enable_model_switch(+0xC4));
    ///       if (n.EndsWith("_switch_r")) SetOptionDisplay(render, asm.enable_model_switch(+0xC4) == 0);
    ///   }
    /// Literals: "_switch" 0x98C07D0, "_switch_r" 0x98C07D8 — both are SUFFIXES of the
    /// renderer's transform name (not root-bone parent names).
    /// </summary>
    public void ApplyModelSwitch(SkinnedMeshRenderer render, object info)
    {
        if (render == null) return;
        var tr = render.transform;
        if (info == null) return;
        if (tr == null) return;
        var flags = info as IDanceIdolInfoFlags;
        if (flags == null || !flags.ModelSwitchEnabled) return;

        var n = tr.name;
        if (n.EndsWith("_switch", StringComparison.Ordinal))
            SetOptionDisplay(render, flags.ModelSwitchVisible);
        if (n.EndsWith("_switch_r", StringComparison.Ordinal))
            SetOptionDisplay(render, !flags.ModelSwitchVisible);
    }

    /// <summary>
    /// JointBodyHead.ApplyGlassesSwitch 0x1CC019C (old 0x1C65524), resolved grammar:
    ///   if (render == null) return; if (render.transform == null) return;
    ///   if (info == null) return; var asm = info.assem_info(+0xE8); if (asm == null) return;
    ///   bool enabled = (asm.is_release_glasses(+0xC6) &amp; 1) != 0
    ///               || (asm.is_release_enable_only_default_glasses(+0xC7) &amp; 1) != 0;
    ///   int no = asm.glasses_model_ver(+0xCC);   // int
    ///   if (enabled) {
    ///       if (name.EndsWith("_gls_base")) SetOptionDisplay(render, no == 0);
    ///       if (name.Length >= "_gls_v".Length + 2) {
    ///           var suffix = name.Substring(name.Length - 2);        // two chars
    ///           if (name == "_gls_v" + suffix &amp;&amp; int.TryParse(suffix, out var v))
    ///               SetOptionDisplay(render, no == v);
    ///       }
    ///   } else if (name.Length >= "_gls_v".Length + 2) {
    ///       var suffix = name.Substring(name.Length - 2);
    ///       if (name == "_gls_v" + suffix) SetOptionDisplay(render, false);
    ///   }
    /// Literals: "_gls_base" 0x98C0528, "_gls_v" 0x98C0530 (single prefix string, not an
    /// array; the decomp's off_98C0530 points at its length+chars).
    /// </summary>
    public void ApplyGlassesSwitch(SkinnedMeshRenderer render, object info)
    {
        if (render == null) return;
        var tr = render.transform;
        if (tr == null) return;
        if (info == null) return;
        var flags = info as IDanceIdolInfoFlags;
        if (flags == null) return;

        var n = tr.name;
        if (flags.GlassesSwitchEnabled)
        {
            if (n.EndsWith(GlassesBaseSuffix, StringComparison.Ordinal))
                SetOptionDisplay(render, flags.GlassesIndex == 0);
            if (n.Length >= GlassesVersionPrefix.Length + 2)
            {
                var suffix = n.Substring(n.Length - 2);
                if (n == GlassesVersionPrefix + suffix && int.TryParse(suffix, out var v))
                    SetOptionDisplay(render, flags.GlassesIndex == v);
            }
        }
        else if (n.Length >= GlassesVersionPrefix.Length + 2)
        {
            var suffix = n.Substring(n.Length - 2);
            if (n == GlassesVersionPrefix + suffix) SetOptionDisplay(render, false);
        }
    }

    /// <summary>Native literal "_gls_base" (slot 0x98C0528), a renderer-name suffix.</summary>
    public const string GlassesBaseSuffix = "_gls_base";
    /// <summary>Native literal "_gls_v" (slot 0x98C0530); names are prefix + two digits.</summary>
    public const string GlassesVersionPrefix = "_gls_v";

    /// <summary>
    /// The DanceIdolInfo flag surface ApplyModelSwitch/ApplyGlassesSwitch read from
    /// DanceIdolInfo.assem_info (PartsAssembleInfo, DanceIdolInfo+0xE8). Implement it on
    /// whatever carries the costume switch data; absent ⇒ both switches are no-ops.
    /// Mapping to the native bytes:
    ///   ModelSwitchEnabled = is_release_model_switch (+0xC5)
    ///   ModelSwitchVisible = enable_model_switch (+0xC4)
    ///   GlassesSwitchEnabled = is_release_glasses (+0xC6) | is_release_enable_only_default_glasses (+0xC7)
    ///   GlassesIndex = glasses_model_ver (+0xCC, int)
    /// </summary>
    public interface IDanceIdolInfoFlags
    {
        bool ModelSwitchEnabled { get; }
        bool ModelSwitchVisible { get; }
        bool GlassesSwitchEnabled { get; }
        int GlassesIndex { get; }
    }

    /// <summary>
    /// JointBodyHead.Set_updateWhenOffscreen 0x1C640A8: writes
    /// `SkinnedMeshRenderer.updateWhenOffscreen` on the head/body renderers.
    /// Native walks the registered renderers; the spike applies it to the body subtree
    /// (the head is parented under it, so a single traversal covers both).
    /// </summary>
    public void Set_updateWhenOffscreen(bool updateWhenOffscreen)
    {
        if (body == null) return;
        foreach (var r in body.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            if (r != null) r.updateWhenOffscreen = updateWhenOffscreen;
    }

    // =====================================================================
    // Sway wiring
    // =====================================================================

    /// <summary>
    /// Registers the merged sway rig (B2 `SwayRigNative`) so `SwaySwitch`,
    /// `SwayManagerAllON`, `skirt_GP_SwayManagerCtrl` and `MeasureSway` operate on the
    /// same manager/bone lists the native class fills in AttachSwayManager/Bone.
    /// </summary>
    public void BindSwayRig(SwayRigNative rig)
    {
        swm.Clear();
        swb.Clear();
        if (rig == null) return;
        for (var i = 0; i < rig.managers.Count; i++)
            if (rig.managers[i] != null) swm.Add(rig.managers[i]);
        for (var i = 0; i < rig.bones.Count; i++)
            if (rig.bones[i] != null) swb.Add(rig.bones[i]);
        PushSwayRuntimeState();
    }

    /// <summary>
    /// JointBodyHead.SwaySwitch 0x1C64534: `foreach (swm) manager.on = on;`
    /// (the byte written is SwayManager.on at 0x20).
    /// </summary>
    public void SwaySwitch(bool on)
    {
        for (var i = 0; i < swm.Count; i++)
            if (swm[i] != null) swm[i].on = on;
    }

    /// <summary>JointBodyHead.SwayManagerAllON 0x1C62D28: `foreach (swm) manager.on = true;`.</summary>
    public void SwayManagerAllON()
    {
        for (var i = 0; i < swm.Count; i++)
            if (swm[i] != null) swm[i].on = true;
    }

    /// <summary>
    /// JointBodyHead.skirt_GP_SwayManagerCtrl 0x1C62DC0: `foreach (swm)
    /// if (manager.gameObject.name == "skirt_GP") manager.on = on;` — on/off for the
    /// skirt group only (the name is compared against a string literal, exposed as
    /// <see cref="NameSkirtGP"/>; the value "skirt_GP" is the node name the shipped
    /// ss003/head `_sway` files and the body prefab both use).
    /// </summary>
    public void skirt_GP_SwayManagerCtrl(bool on)
    {
        for (var i = 0; i < swm.Count; i++)
        {
            var m = swm[i];
            if (m == null) continue;
            if (m.gameObject.name == NameSkirtGP) m.on = on;
        }
    }

    /// <summary>
    /// JointBodyHead.MeasureSway 0x1CBF254 (old 0x1C645DC), decoded:
    ///   float a = 0, b = 0;
    ///   foreach (var m in swm (+0x118)) { a += m.updateSwayTime (+0x90); b += m.sideLineHitTime (+0x94); }
    /// The Hex-Rays tail does not show the combine/return: the two float sums stay in
    /// s8/s9 and the emitted `return` is the List.get_Item register artifact, so the final
    /// scalar is genuinely unresolved. Both sums are exposed via out parameters; the
    /// convenience overload returns their sum only because callers need a single float.
    /// </summary>
    public float MeasureSway()
    {
        MeasureSway(out var time, out var sideLine);
        // UNKNOWN(native 0x1CBF254): how the native float return combines the two sums
        // (add / max / one of them only). The decompile loses that instruction; a runtime
        // probe of the shipped binary is required before changing this.
        return time + sideLine;
    }

    public void MeasureSway(out float updateSwayTime, out float sideLineHitTime)
    {
        updateSwayTime = 0f;
        sideLineHitTime = 0f;
        for (var i = 0; i < swm.Count; i++)
        {
            var m = swm[i];
            if (m == null) continue;
            updateSwayTime += m.updateSwayTime;
            sideLineHitTime += m.sideLineHitTime;
        }
    }

    /// <summary>
    /// JointBodyHead.SetWingLimit 0x1C64700: if wingL != null → SwayBone.SetWingLimitL
    /// (0x1C727B4) with the index, then the same for wingR → SetWingLimitR (0x1C7288C).
    /// Both SwayBone side-table indices stay UNKNOWN inside B2's port.
    /// </summary>
    public void SetWingLimit(int index)
    {
        if (wingL != null) wingL.SetWingLimitL(index);
        if (wingR != null) wingR.SetWingLimitR(index);
    }

    /// <summary>
    /// Pushes the JointBodyHead-owned runtime sway state into every registered
    /// SwayManager. Only the three values the binary actually keeps on this class are
    /// written (`swayFollowRate` 0x128, `swayTransBack` 0x105, `swayOn` 0x104);
    /// swayFollowSW/swayDamper/vecs1 belong to IdolPositionMgr / EventScenarioData and
    /// are left untouched here (see the file header).
    /// </summary>
    public void PushSwayRuntimeState()
    {
        for (var i = 0; i < swm.Count; i++)
        {
            var m = swm[i];
            if (m == null) continue;
            m.swayFollowRate = swayFollowRate;
            m.swayTransBack = swayTransBack;
            m.swayOn = swayOn;
        }
    }

    /// <summary>Setter that keeps the managers in sync immediately (native has no setter: the
    /// managers read the fields through the shared SwayCtrlMT).</summary>
    public void SetSwayOn(bool on)
    {
        swayOn = on;
        PushSwayRuntimeState();
    }

    public void SetSwayTransBack(bool transBack)
    {
        swayTransBack = transBack;
        PushSwayRuntimeState();
    }

    public void SetSwayFollowRate(int category, float value)
    {
        if (swayFollowRate == null || category < 0 || category >= swayFollowRate.Length) return;
        swayFollowRate[category] = value;
        PushSwayRuntimeState();
    }

    // =====================================================================
    // Accessors
    // =====================================================================

    /// <summary>JointBodyHead.GetHeadModelTop 0x1C646C0: returns `head` (0x90).</summary>
    public GameObject GetHeadModelTop()
    {
        return head;
    }

    /// <summary>JointBodyHead.GetBodyModelTop 0x1C646DC: returns `body` (0x18).</summary>
    public GameObject GetBodyModelTop()
    {
        return body;
    }

    /// <summary>JointBodyHead.GetDropShadow 0x1C646F8: returns `dshadow` (0xF8).</summary>
    public Component GetDropShadow()
    {
        return dshadow;
    }

    /// <summary>
    /// JointBodyHead.SetVisible 0x1CBEF18 (old 0x1C642A0), verbatim:
    ///   if (body == null) return;
    ///   foreach (var smr in body.GetComponentsInChildren&lt;SkinnedMeshRenderer&gt;())   // includeInactive = false
    ///       if (smr.sharedMaterials != null &amp;&amp; smr.sharedMaterials.Length != 0) smr.enabled = show;
    ///   if (dshadow != null) dshadow.LightAndShadowByChara(show);                    // 0x3877424
    ///   bool useGlobalColor = true;
    ///   var vm = VisualManager3d.instance;
    ///   if (vm != null) { var st = vm.stageMgr (+0x70); if (st != null) useGlobalColor = st.pinSpotUseGlobalColor (+0x80); }
    ///   if (dshadow.pinlightObj (+0x30) != null)
    ///       dshadow.SetPinLightState(show, useGlobalColor, false, -1.0f);             // 0x3877158
    /// Deviations: the native dereferences dshadow.pinlightObj without a dshadow null check
    /// (it throws when dshadow is null), so the port guards dshadow; VisualManager3d is a
    /// Live-only subsystem with no ADV-story equivalent, so the global-color byte comes from
    /// a seam whose default `true` reproduces the native initialiser.
    /// </summary>
    public void SetVisible(bool show)
    {
        if (body == null) return;
        foreach (var smr in body.GetComponentsInChildren<SkinnedMeshRenderer>())
        {
            if (smr == null) continue;
            var mats = smr.sharedMaterials;
            if (mats != null && mats.Length != 0) smr.enabled = show;
        }
        if (dshadow == null) return;

        var shadow = dshadow as DropShadow;
        if (shadow == null) return;
        shadow.LightAndShadowByChara(show);

        var useGlobalColor = pinSpotUseGlobalColor != null ? pinSpotUseGlobalColor() : true;
        // UNKNOWN(native 0x1CBEF18): StageMgr.pinSpotUseGlobalColor (+0x80) is Live-stage
        // state; absent in the ADV-story spike, so the seam falls back to the native `true`.
        if (shadow.pinlightObj != null)
            shadow.SetPinLightState(show, useGlobalColor, false, -1.0f);
    }

    /// <summary>
    /// Live subsystem seam: StageMgr.pinSpotUseGlobalColor (VisualManager3d.instance.stageMgr
    /// +0x80). Native default is `true` when there is no stage manager; the ADV-story spike
    /// leaves it unset.
    /// </summary>
    [NonSerialized] public static Func<bool> pinSpotUseGlobalColor;

    /// <summary>
    /// Live subsystem seam: CharacterSoul body-scale factor used for Eye_obj.localScale in
    /// Initialize_Post_1 (native multiplies the soul's Value&lt;float&gt; bodyScale by the
    /// Vector3 static default = one). Neutral default 1.0; CharacterManager is Live-only.
    /// </summary>
    [NonSerialized] public static Func<IDanceIdolInfoFlags, float> eyeScaleProvider;

    /// <summary>
    /// JointBodyHead.Reset 0x1C63B58 (used before a re-Initialize): clears the collected
    /// refs. The native body also destroys the loaded objects; the spike's objects are
    /// owned by CharacterBootstrap, so only the bookkeeping is cleared.
    /// </summary>
    public void Reset()
    {
        headmeshes.Clear();
        bodymeshes.Clear();
        headbones.Clear();
        bonesRot.Clear();
        optionDisplayDict.Clear();
        swb.Clear();
        swm.Clear();
        body = null;
        head = null;
        Position = null;
        Model00 = null;
        BodyScale = null;
        Base = null;
        Atama = null;
        Kubi = null;
        Mune2 = null;
        RFinger = null;
        LFinger = null;
        Eye = null;
        bodyMesh = null;
        headMesh = null;
        kubiTrans = null;
        wingL = null;
        wingR = null;
        AtamaY = 0f;
        EyesY = 0f;
        isV2 = false;
        is_creation_succeeded = false;
        is_creation_start_with_hide = false;
    }

    // =====================================================================
    // Search helpers (serchChild 0x1CC0614 / serchChildRrecursive 0x1CC06E4)
    // =====================================================================

    /// <summary>
    /// JointBodyHead.serchChild 0x1CC0614 (old 0x1C6599C), verbatim:
    ///   if (top == null) throw NullReferenceException;
    ///   return top.name.Equals(name) ? top : serchChildRrecursive(top, name);
    /// Exact ordinal name compare; the top node itself is tested first.
    /// </summary>
    public static Transform serchChild(Transform top, string name)
    {
        if (top == null || name == null) return null;
        if (string.Equals(top.name, name, StringComparison.Ordinal)) return top;
        return serchChildRrecursive(top, name);
    }

    /// <summary>
    /// JointBodyHead.serchChildRrecursive 0x1CC06E4 (old 0x1C65A6C): children in order,
    /// exact ordinal name compare; after a child miss the native recurses only while
    /// `String.Compare(child.name, "___") &lt; 0` (literal 0x98BFEC0, a pruning optimization
    /// that skips the "___"-suffixed renamed bones). The port walks every child; for the
    /// shipped bone names this yields the same first match.
    /// </summary>
    private static Transform serchChildRrecursive(Transform top, string name)
    {
        if (top == null) return null;
        for (var i = 0; i < top.childCount; i++)
        {
            var c = top.GetChild(i);
            if (c == null) continue;
            if (string.Equals(c.name, name, StringComparison.Ordinal)) return c;
            var hit = serchChildRrecursive(c, name);
            if (hit != null) return hit;
        }
        return null;
    }

    /// <summary>
    /// IdolUtility.FindObjectByPath equivalent used by Initialize_Post_1: a path with '/'
    /// goes through Transform.Find (native IdolUtility.FindObjectByPath 0x365DC78); a bare
    /// name is a serchChild deep search.
    /// </summary>
    private static GameObject FindGo(Transform top, string path)
    {
        if (top == null || string.IsNullOrEmpty(path)) return null;
        if (path.IndexOf('/') >= 0)
        {
            var t = top.Find(path);
            return t != null ? t.gameObject : null;
        }
        var hit = serchChild(top, path);
        return hit != null ? hit.gameObject : null;
    }

    // =====================================================================

    public string Describe()
    {
        var sb = new StringBuilder();
        sb.Append("JointBodyHeadNative index=").Append(jbhIndex)
          .Append(" ok=").Append(is_creation_succeeded)
          .Append(" isV2=").Append(isV2)
          .Append(" body=").Append(body != null ? body.name : "<null>")
          .Append(" head=").Append(head != null ? head.name : "<null>")
          .AppendLine();
        sb.Append("  Atama=").Append(Nm(Atama)).Append(" Kubi=").Append(Nm(Kubi))
          .Append(" Mune2=").Append(Nm(Mune2)).Append(" Eye=").Append(Nm(Eye))
          .Append(" Base=").Append(Nm(Base)).Append(" BodyScale=").Append(Nm(BodyScale))
          .Append(" Model00=").Append(Nm(Model00)).Append(" Position=").Append(Nm(Position))
          .Append(" RFinger=").Append(Nm(RFinger)).Append(" LFinger=").Append(Nm(LFinger))
          .AppendLine();
        sb.Append("  AtamaY=").Append(AtamaY.ToString("F4"))
          .Append(" EyesY=").Append(EyesY.ToString("F4"))
          .Append(" scale=").Append(scale.ToString("F3"))
          .Append(" ResolveDepthFactor=").Append(ResolveDepthFactor.ToString("F3"))
          .AppendLine();
        sb.Append("  swayOn=").Append(swayOn)
          .Append(" swayTransBack=").Append(swayTransBack)
          .Append(" swayFollowRate=[").Append(string.Join(",", swayFollowRate ?? Array.Empty<float>())).Append(']')
          .AppendLine();
        sb.Append("  swm=").Append(swm.Count).Append(" swb=").Append(swb.Count)
          .Append(" bonesRot=").Append(bonesRot.Count)
          .Append(" bodymeshes=").Append(bodymeshes.Count)
          .Append(" headmeshes=").Append(headmeshes.Count)
          .Append(" headbones=").Append(headbones.Count)
          .Append(" options=").Append(optionDisplayDict.Count)
          .AppendLine();
        for (var i = 0; i < swm.Count; i++)
        {
            var m = swm[i];
            if (m == null) continue;
            sb.Append("    swm[").Append(i).Append("] ").Append(m.name)
              .Append(" on=").Append(m.on)
              .Append(" bones=").Append(m.swayBones != null ? m.swayBones.Length : 0)
              .AppendLine();
        }
        for (var i = 0; i < bodymeshes.Count; i++)
        {
            var bm = bodymeshes[i];
            sb.Append("    bodymesh[").Append(i).Append("] ").Append(Nm(bm.obj))
              .Append(" KUBI=").Append(bm.KUBI_index)
              .Append(" ATAMA=").Append(bm.ATAMA_index)
              .AppendLine();
        }
        return sb.ToString();
    }

    private static string Nm(GameObject go)
    {
        return go != null ? go.name : "<null>";
    }
}
