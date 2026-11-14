// Native-faithful port of `Imas.BoneLib.JointBodyHead` (dump.cs TypeDefIndex 15271) plus
// the assembly/switch skeleton it drives (ADR-0033 B5).
//
// Decompiled evidence (all in /tmp/ida-decomp/b5/, addresses = dump.cs RVAs):
//   .ctor()                                  0x1C62EAC
//   .ctor(int index)                         0x1C63198
//   Initialize                               0x1C633CC
//   Initialize_Post_1 (iterator)             0x1C63A48
//   Initialize_Post_1.MoveNext               0x1C66DB0   (the real assembly order)
//   Initialize_Post_2                        0x1C63AF8   (AtamaY / EyesY)
//   AddPositionNode                          0x1C63F34
//   SwayManagerAllON                         0x1C62D28
//   skirt_GP_SwayManagerCtrl                 0x1C62DC0
//   SwaySwitch                               0x1C64534
//   MeasureSway                              0x1C645DC
//   GetHeadModelTop                          0x1C646C0
//   GetBodyModelTop                          0x1C646DC
//   GetDropShadow                            0x1C646F8
//   SetWingLimit                             0x1C64700
//   SetOptionDisplay                         0x1C64820
//   InitializeDisplay                        0x1C64920
//   GetBoneRot                               0x1C64A6C
//   SetBodyMeshs                             0x1C64C18
//   SetHeadMeshs                             0x1C6516C
//   ApplyModelSwitch                         0x1C64F94
//   ApplyGlassesSwitch                       0x1C65524
//   SetVisible                               0x1C642A0
//   Reset                                    0x1C63B58
//   GetInitRot                               0x1C627AC
//   Set_updateWhenOffscreen                  0x1C640A8
//
// OUT OF SCOPE (Live orchestration, listed so the gap stays explicit):
//   InitializeAsync 0x1C63D3C (AssetBundleLoadResourceOperation / loading progress),
//   Initialize_Post_1's bundle-wait states, MovePosition 0x1C628FC / RePosition 0x1C62C8C
//   (stage placement / lift), Finalize/Dispose 0x1C630D8/0x1C6317C, boneDump 0x1C65C0C /
//   weightDump 0x1C65D10 / bindPoseDump 0x1C663F0 (debug dumps), ApplyModelSwitch /
//   ApplyGlassesSwitch's DanceIdolInfo flag source (see the UNKNOWN notes in place).
//
// ---------------------------------------------------------------------------
// Sway runtime arrays — what actually lives on JointBodyHead
// ---------------------------------------------------------------------------
// dump.cs 15271 declares exactly ONE sway runtime array on this class:
//     public float[] swayFollowRate;   // 0x128
// plus `swayOn` 0x104 and `swayTransBack` 0x105.
// `swayFollowSW`, `swayDamper` and `vecs1` are NOT JointBodyHead fields:
//     IdolPositionMgr.swayFollowSW   (dump.cs 16396, 0x30)
//     IdolPositionMgr.swayDamper     (dump.cs 16396, 0x38)
//     EventScenarioData.vecs1        (dump.cs ~536724, 0x138)
// i.e. they are Live-stage data owned by the stage/formation manager, which is out of
// scope here. SwayManagerNative already models them with the neutral defaults
// (0 / false / 1 / zero) that the V01 solver falls back to when nothing is set, and
// `FollowFall` is SwayBoneMT.FixedParams.fallFollow (from the `_sway` text), not a JBH
// field either. This class therefore pushes only what the binary really has:
// `swayFollowRate`, `swayTransBack`, `swayOn`.
//
// swayFollowRate's own native default: Initialize_Post_1 allocates
// `swayFollowRate = new float[N]` (all zeros) where N is the count of a *global*
// manager list (sub_6653270/sub_6661FF0/sub_6661FD0 on the qword_96E1210 +
// qword_9C9C2F0 statics). N and that list are UNKNOWN(native 0x1C66DB0 @start):
// the array is zero-filled either way, and 0 means "fall through to the bone's own
// followForce" in SwayBoneMT.SwayMove 0x1C6867C. A 5-entry zero array is therefore
// value-equivalent to the native allocation for SwayCategory {Normal,Hair,Skirt,Opai,
// SideHair}; the length itself stays documented as a gap.

using System;
using System.Collections.Generic;
using System.Text;
using UnityEngine;

/// <summary>Imas.BoneLib.JointBodyHead (dump.cs 15271). Fields kept in native order.</summary>
public sealed class JointBodyHeadNative : MonoBehaviour
{
    // SwayCategory count = SwayCategory { Normal, Hair, Skirt, Opai, SideHair } (B2).
    public const int SwayCategoryCount = 5;

    // Native name constants. These are the *field names* of JointBodyHead; the native
    // code passes string literals to `serchChild` / `Transform.Find`, and those
    // literals are IL2CPP metadata-usage pointers that cannot be resolved statically
    // (Mach-O chained fixups). UNKNOWN(native 0x1C66DB0 / 0x1C63F34 literal slots):
    // used as the search names, overridable from the inspector / probe.
    public const string NamePosition = "Position";
    public const string NameModel00 = "Model00";
    public const string NameBodyScale = "BodyScale";
    public const string NameBase = "Base";
    public const string NameAtama = "Atama";
    public const string NameKubi = "Kubi";
    public const string NameMune2 = "Mune2";
    public const string NameRFinger = "RFinger";
    public const string NameLFinger = "LFinger";
    public const string NameEye = "Eye";
    public const string NameSkirtGP = "skirt_GP";

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
        bool start_with_hide = false, bool is_bloom_enabled = true)
    {
        is_creation_succeeded = false;
        destroy_loadedResource_soon = false;
        is_creation_start_with_hide = start_with_hide;

        if (bodyGo == null) return false;
        body = bodyGo;
        Position = null;

        if (headGo == null) return false;
        head = headGo;

        // Initialize_Post_1 0x1C66DB0: clear the option-display dictionary, allocate the
        // per-category follow-rate array, then walk body -> head.
        optionDisplayDict.Clear();
        AllocateSwayFollowRate();
        if (swayMT == null) swayMT = new SwayCtrlMTNative();

        // body_mesh / head_mesh: native does body.transform.Find(<lit>) into 0xC0 and
        // head.transform.Find(<lit>) into 0xB8.
        bodyMesh = FindDeep(body.transform, NameModel00) ?? body.transform;
        headMesh = FindDeep(head.transform, NameModel00) ?? head.transform;

        SetBodyMeshs(bodyMesh, null);
        SetHeadMeshs(headMesh, null);

        if (!start_with_hide) Set_updateWhenOffscreen(true);

        // Reference nodes (native resolves each with serchChild/Find on the body model;
        // the literals are UNKNOWN, see the name constants above).
        Model00 = FindGo(body.transform, NameModel00);
        BodyScale = FindGo(body.transform, NameBodyScale);
        Base = FindGo(body.transform, NameBase);
        Atama = FindGo(body.transform, NameAtama);
        Kubi = FindGo(body.transform, NameKubi);
        Mune2 = FindGo(body.transform, NameMune2);
        RFinger = FindGo(body.transform, NameRFinger);
        LFinger = FindGo(body.transform, NameLFinger);
        Eye = FindGo(head.transform, NameEye);
        kubiTrans = Kubi != null ? Kubi.transform : null;

        // GetBoneRot 0x1C64A6C runs over the *body* model at the end of Post_1
        // (`sub_1C64A6C(v8, v184)`); every child's localRotation is captured at bind.
        bonesRot.Clear();
        if (body.transform != null) GetBoneRot(body.transform);

        AddPositionNode();
        InitializeDisplay();

        // 0x1C633CC tail: DropShadow.Initialize(shadow, ABShadow) — B4 owns DropShadow,
        // so only the hook is called.
        onAssembled?.Invoke(this);

        Initialize_Post_2();

        is_creation_succeeded = true;
        return true;
    }

    /// <summary>
    /// Initialize_Post_1 0x1C66DB0 head: `swayFollowRate = new float[count]` (all
    /// zeros). See the file header for why the count is UNKNOWN and why a 5-entry zero
    /// array is value-equivalent for the V01 solver.
    /// </summary>
    private void AllocateSwayFollowRate()
    {
        if (swayFollowRate == null || swayFollowRate.Length != SwayCategoryCount)
            swayFollowRate = new float[SwayCategoryCount];
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
    /// JointBodyHead.AddPositionNode 0x1C63F34: find the `Position` node under the body
    /// model; if it is missing create an empty GameObject with that name and parent it
    /// to the body (worldPositionStays = true).
    /// </summary>
    public void AddPositionNode()
    {
        if (body == null) return;
        var found = FindDeep(body.transform, NamePosition);
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
    /// JointBodyHead.SetBodyMeshs 0x1C64C18: for every child of `top`:
    ///   render = child.GetComponent&lt;SkinnedMeshRenderer&gt;();
    ///   ApplyModelSwitch(render, info);
    ///   if (child.gameObject.name == &lt;lit&gt;) SetOptionDisplay(render, info.flag == 0);
    ///   if (render == null) continue;
    ///   bm.obj = child.gameObject; bm.KUBI_index = bm.ATAMA_index = -1;
    ///   for each shared material j: if (name == &lt;lit Kubi&gt;) bm.KUBI_index = j;
    ///                               if (name == &lt;lit Atama&gt;) bm.ATAMA_index = j;
    ///   bodymeshes.Add(bm);
    /// The two material-name literals are UNKNOWN(native 0x1C64C18 slots
    /// qword_97F3C08 / qword_97E2B40); they are exposed as fields so the probe can
    /// report which material matched.
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

            if (child.gameObject.name == kubiMeshName)
                SetOptionDisplay(render, true);
            if (render == null) continue;

            var bm = new BodyMeshRef { obj = child.gameObject, KUBI_index = -1, ATAMA_index = -1 };
            var mats = render.sharedMaterials;
            for (var j = 0; j < mats.Length; j++)
            {
                var m = mats[j];
                if (m == null) continue;
                if (m.name == kubiMaterialName) bm.KUBI_index = j;
                if (m.name == atamaMaterialName) bm.ATAMA_index = j;
            }
            bodymeshes.Add(bm);
        }
    }

    /// <summary>UNKNOWN(native 0x1C64C18 literal qword_982B5D0): child-name gate for the option display.</summary>
    public string kubiMeshName = "kubi";
    /// <summary>UNKNOWN(native 0x1C64C18 literal qword_97F3C08): material name that marks the KUBI sub-mesh.</summary>
    public string kubiMaterialName = "kubi";
    /// <summary>UNKNOWN(native 0x1C64C18 literal qword_97E2B40): material name that marks the ATAMA sub-mesh.</summary>
    public string atamaMaterialName = "atama";

    /// <summary>
    /// JointBodyHead.SetHeadMeshs 0x1C6516C: same walk over the head model, filling
    /// headmeshes (GameObject + the list of bone names the head renderer skinning
    /// references, used by SetHeadMeshs/headbones) and applying ApplyGlassesSwitch.
    /// </summary>
    public void SetHeadMeshs(Transform top, object info)
    {
        if (top == null) return;
        for (var i = 0; i < top.childCount; i++)
        {
            var child = top.GetChild(i);
            if (child == null) continue;
            var render = child.GetComponent<SkinnedMeshRenderer>();
            ApplyGlassesSwitch(render, info);
            if (render == null) continue;

            var href = new HeadMeshRef { obj = child.gameObject };
            var bones = render.bones;
            if (bones != null)
            {
                for (var b = 0; b < bones.Length; b++)
                {
                    if (bones[b] == null) continue;
                    if (!href.bones.Contains(bones[b].name)) href.bones.Add(bones[b].name);
                }
            }
            headmeshes.Add(href);
            for (var b = 0; b < href.bones.Count; b++)
                if (!headbones.Contains(href.bones[b])) headbones.Add(href.bones[b]);
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
    /// JointBodyHead.ApplyModelSwitch 0x1C64F94. Native gates on DanceIdolInfo flags
    /// (`info+232` sub-object bytes 0xC4/0xC5) and on the *root bone parent's* GameObject
    /// name matching one of two literals, then calls SetOptionDisplay. The flags and the
    /// literals are Live costume data:
    ///   UNKNOWN(native 0x1C64F94): DanceIdolInfo.modelSwitch flags + the two name
    ///   literals. Without `info` this is a no-op, which is the neutral value.
    /// </summary>
    public void ApplyModelSwitch(SkinnedMeshRenderer render, object info)
    {
        var flags = info as IDanceIdolInfoFlags;
        if (render == null || flags == null) return;
        if (!flags.ModelSwitchEnabled) return;
        var rootBone = render.rootBone;
        if (rootBone == null || rootBone.parent == null) return;
        var name = rootBone.parent.gameObject.name;

        if (name == modelSwitchNameA) SetOptionDisplay(render, flags.ModelSwitchVisible);
        if (name == modelSwitchNameB) SetOptionDisplay(render, !flags.ModelSwitchVisible);
    }

    /// <summary>
    /// JointBodyHead.ApplyGlassesSwitch 0x1C65524. Native gates on DanceIdolInfo flag
    /// bytes 0xC6/0xC7, compares the renderer's GameObject name against a literal and,
    /// when the name ends with the "&lt;...&gt;" suffix pair, compares the suffix number
    /// with `info` (0xCC) before calling SetOptionDisplay.
    /// UNKNOWN(native 0x1C65524): flag layout, literals, suffix grammar.
    /// </summary>
    public void ApplyGlassesSwitch(SkinnedMeshRenderer render, object info)
    {
        var flags = info as IDanceIdolInfoFlags;
        if (render == null || flags == null) return;
        if (!flags.GlassesSwitchEnabled) return;
        var name = render.gameObject.name;
        if (name == glassesNameA) SetOptionDisplay(render, flags.GlassesIndex == 0);
        if (name == glassesNameB) SetOptionDisplay(render, flags.GlassesIndex == 1);
    }

    /// <summary>UNKNOWN(native 0x1C64F94 literals): root-bone parent names for the model switch.</summary>
    public string modelSwitchNameA = "model_a";
    /// <summary>UNKNOWN(native 0x1C64F94 literals).</summary>
    public string modelSwitchNameB = "model_b";
    /// <summary>UNKNOWN(native 0x1C65524 literals): renderer names for the glasses switch.</summary>
    public string glassesNameA = "glasses_a";
    /// <summary>UNKNOWN(native 0x1C65524 literals).</summary>
    public string glassesNameB = "glasses_b";

    /// <summary>
    /// The DanceIdolInfo flag surface ApplyModelSwitch/ApplyGlassesSwitch read
    /// (dump.cs DanceIdolInfo is Live-only and not migrated). Implement it on whatever
    /// carries the costume switch data; absent ⇒ both switches are no-ops.
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
    /// JointBodyHead.MeasureSway 0x1C645DC: sums SwayManager.updateSwayTime (0x90) and
    /// SwayManager.sideLineHitTime (0x94) over `swm` into two accumulators.
    /// UNKNOWN(native 0x1C645DC): the combine step / return value — the decompiled body
    /// leaves both sums in s8/s9 and returns nothing visible, so both are exposed via
    /// out parameters instead of guessing a formula.
    /// </summary>
    public float MeasureSway()
    {
        MeasureSway(out var time, out var sideLine);
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
    /// JointBodyHead.SetVisible 0x1C642A0:
    ///   if (body == null) return;
    ///   foreach renderer in body.GetComponentsInChildren&lt;Renderer&gt;():
    ///       if (renderer.sharedMaterials.Length != 0) renderer.enabled = show;
    ///   if (dshadow != null) dshadow.SetVisible(show);
    ///   if (dshadow.activeShadow != null) dshadow.SetShadowVisible(show, &lt;global flag&gt;, -1.0f);
    /// UNKNOWN(native 0x1C642A0): the global flag read from the CharacterManager
    /// singleton (off_970CEB8 → +112 → byte 128) and the DropShadow entry points are B4
    /// scope; the renderer loop is reproduced exactly.
    /// </summary>
    public void SetVisible(bool show)
    {
        if (body == null) return;
        foreach (var r in body.GetComponentsInChildren<Renderer>(true))
        {
            if (r == null) continue;
            if (r.sharedMaterials.Length != 0) r.enabled = show;
        }
        // dshadow.SetVisible / SetShadowVisible — wired by B4 via onSetVisibleHook.
        onDropShadowVisible?.Invoke(show);
    }

    /// <summary>B4 hook: DropShadow.SetVisible(show) (+ SetShadowVisible).</summary>
    [NonSerialized] public Action<bool> onDropShadowVisible;

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
    // Search helpers (serchChild 0x1C6599C / serchChildRrecursive 0x1C65A6C)
    // =====================================================================

    /// <summary>
    /// JointBodyHead.serchChild 0x1C6599C: depth-first search of `top`'s descendants for
    /// a Transform whose GameObject name equals `name` (native also stops at the first
    /// match). A case-sensitive ordinal compare is used; the shipped names are ASCII.
    /// </summary>
    public static Transform serchChild(Transform top, string name)
    {
        if (top == null || string.IsNullOrEmpty(name)) return null;
        return FindDeep(top, name);
    }

    /// <summary>
    /// The native literals for the reference nodes are UNKNOWN; the shipped bundles
    /// name them in upper case with underscores ("MODEL_00", "BODY_SCALE", "ATAMA",
    /// "POSITION", ...) while the decompiled constants are PascalCase. Compare
    /// case/underscore-insensitively, exact match first, then a prefix match so
    /// "Eye" still finds the head's "eyes" node without letting "KUBI" match
    /// "KUBI_RT__twist_x0" before the real "KUBI" node.
    /// </summary>
    private static Transform FindDeep(Transform top, string name)
    {
        if (top == null) return null;
        var wanted = NormalizeName(name);
        if (wanted.Length == 0) return null;
        var exact = FindDeep(top, wanted, false);
        return exact ?? FindDeep(top, wanted, true);
    }

    private static Transform FindDeep(Transform top, string wanted, bool prefix)
    {
        for (var i = 0; i < top.childCount; i++)
        {
            var c = top.GetChild(i);
            if (c == null) continue;
            var candidate = NormalizeName(c.name);
            if (prefix ? candidate.StartsWith(wanted, StringComparison.Ordinal) : candidate == wanted)
                return c;
            var hit = FindDeep(c, wanted, prefix);
            if (hit != null) return hit;
        }
        return null;
    }

    private static string NormalizeName(string name)
    {
        if (string.IsNullOrEmpty(name)) return string.Empty;
        var sb = new StringBuilder(name.Length);
        foreach (var ch in name)
        {
            if (ch == '_' || ch == ' ') continue;
            sb.Append(char.ToLowerInvariant(ch));
        }
        return sb.ToString();
    }

    private static GameObject FindGo(Transform top, string name)
    {
        var t = FindDeep(top, name);
        return t != null ? t.gameObject : null;
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
