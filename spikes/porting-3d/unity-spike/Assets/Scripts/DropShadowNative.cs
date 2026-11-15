// Native-faithful port of the game's `Imas.DropShadow` (ADR-0033 batch B4).
//
// Source of truth (CURRENT shipped binary; region delta old→new RVA = +0xDBF20,
// Il2CppDumper `dump.cs` TypeDefIndex 9898, enum `DropShadow.Shadow` 9896,
// iterator `DropShadow.<SetShadowModeAsync>d__25` 9897):
//   DropShadow.Awake                   0x3876110  (old 0x379A1F0)
//   DropShadow.SetHeightOffset         0x3876140  (old 0x379A220)
//   DropShadow.SetShadowMode           0x3876148  (old 0x379A228)
//   DropShadow.SetShadowModeAsync      0x3876CF4  (old 0x379ADD4, MoveNext 0x38777FC / old 0x379B8DC)
//   DropShadow.InitShadowMode          0x38764CC  (old 0x379A5AC)
//   DropShadow.InitPinSpotLight        0x3876EF0  (old 0x379AFD0)
//   DropShadow.SetPinLightState        0x3877158  (old 0x379B238)
//   DropShadow.CopyPinSpotParam        0x3877378  (old 0x379B458)
//   DropShadow.LightAndShadowByEvent   0x387739C  (old 0x379B47C)
//   DropShadow.LightAndShadowByChara   0x3877424  (old 0x379B504)
//   DropShadow.setTransforms           0x3876D98  (old 0x379AE78)
//   DropShadow.LateUpdate              0x38774AC  (old 0x379B58C)
//   DropShadow.ctor                    0x38777BC  (old 0x379B89C)
//
// Decompiles (CURRENT build): /tmp/decomp2/DropShadow_*.c. The old
// /tmp/ida-decomp/*.c files cited by earlier revisions are a previous build.
//
// Asset paths are *verified string literals* of the CURRENT metadata (resolved
// from /tmp/ild/script.json ScriptString; the old slots 0x97E7780/88/90/98 are
// previous-build addresses and no longer resolve):
//   "Chara/Shadow/lt_pin_spot"  (0x989E9B8)
//   "Chara/Shadow/ltmap_chara"  (0x989E9C0)
//   "Chara/Shadow/sd_chara"     (0x989E9C8)
//   "Chara/Shadow/sd_chara2"    (0x989E9D0)
// and the transform paths used by setTransforms are the literals
//   "MODEL_00" (0x98AC2D0), "MODEL_00/BODY_SCALE" (0x98AC2F0),
//   "MODEL_00/BODY_SCALE/BASE" (0x98AC2F8),
//   "MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_L/HIZA_L/ASHI_L" (0x98AC338),
//   "MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_R/HIZA_R/ASHI_R" (0x98AC380).
// The `_Irogae` shader property id literal resolves to slot 0x98BF248 (the old
// note "0x9807E48" was a stale address, not the literal itself).
//
// Asset bundle facts (facts report §C, re-checked with UnityPy against
// `chara_shadow.unity3d`, 82,494 B): pure Mesh/Material/Texture + 4 prefab/fbx
// roots (sd_chara, sd_chara2, ltmap_chara, lt_pin_spot); there is **no**
// DropShadow MonoBehaviour inside the bundle, so the component and its wiring
// are rebuilt here exactly as the native class does.
//
// Assembly (see /tmp/eyes-shadow-native-notes.md):
//   * Add this component to the character instance root: the object whose
//     direct child is `MODEL_00` (native setTransforms does `tra.Find(...)`
//     with `tra = transform`, Awake 0x379A1F0). In this spike that is the
//     instantiated `cb_<...>` body root.
//   * Load `chara_shadow.unity3d` into an AssetBundle and call
//     SetShadowMode(mode, shadowBundle) after the character is built.
//
// UNKNOWN tags in this file — resolution status (CURRENT build):
//   The native asset manager (`AssetBundleManager.GetResource`, current
//   `Method$AssetBundleManager.GetResource<Object>()` 0x981E430, TypeInfo 0x97AEE58)
//   is replaced by Unity's AssetBundle API (performance layer: same asset identity,
//   same load order). The shadow material post-process `sub_357E268` is landed as a
//   real pass (see `ApplyShadowMaterialsNative`): child-Renderer walk + static-table
//   (name→Material) swap; its name-pattern literals are still exact-key only.
//   The old stage/pin-spot/global/shadow data addresses (0x9705120, 0x9709770,
//   0x970CCF8) are previous-build slots and do not resolve in the current metadata;
//   the current code reads these Live identities instead:
//     Imas.Live.MainLoop_TypeInfo       0x97B93B8  (InitPinSpotLight)
//     Imas.CustomShaderUtility_TypeInfo 0x97B1BD8  (InitShadowMode)
//     Imas.ShadowMapCtrl_TypeInfo       0x97BDAD0  (InitShadowMode)
//     Vector3_TypeInfo                  0x97C10A0  (defaults)
//   Live-stage/pin-spot state has no ADV-story equivalent ⇒ the settable seams
//   (`pinSpotStage`, `hideCharacterShadow`, `shadowScaleVectorOverride`) are the
//   evidence-backed outcome; the Live-only stage camera defaults stay out of scope.
//   UNKNOWN(native 0x3877158) precise question: the decompile of SetPinLightState
//   does not make the `useGlobalColor` -> material color path unique (global vs
//   per-stage color selection); a runtime probe of the shipped binary is required
//   before changing CopyPinSpotParam.

using System.Collections;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// Native-faithful `Imas.DropShadow` (type 9596). Ground shadow + pin spot
/// light for a 3D idol. Rebuilt from the binary because the shipped
/// `chara_shadow.unity3d` bundle contains only prefab/FBX/mesh/material/texture
/// assets and no component.
/// </summary>
public class DropShadow : MonoBehaviour
{
    /// <summary>`DropShadow.Shadow` (type 9594).</summary>
    public enum Shadow
    {
        NONE = 0,
        CIRCLE = 1,
        STAR = 2,
        STAGE_CIRCLE = 3,
        STAGE_STAR = 4,
    }

    // ---- Native fields (dump.cs offsets in comments) ----
    public Shadow shadowMode;          // 0x20
    public GameObject lightObj;        // 0x28
    public GameObject pinlightObj;     // 0x30
    public Material lightmat;          // 0x38
    public Material pinmat;            // 0x40
    public GameObject kage1Obj;        // 0x48
    public GameObject kage2Obj;        // 0x50
    private Transform MODEL_00;        // 0x58
    private Transform BODY_SCALE;      // 0x60
    private Transform BASE;            // 0x68
    private Transform ASHI_L;          // 0x70
    private Transform ASHI_R;          // 0x78
    private bool eventSW = true;       // 0x80 (ctor 0x379B89C: true)
    private bool charaSW = true;       // 0x81 (ctor 0x379B89C: true)
    private bool initOK;               // 0x82
    protected float height_offset;     // 0x84
    public bool pinlightevSW;          // 0x88 (InitShadowMode writes WORD 0x0101)
    public bool pinlightshowSW;        // 0x89
    public bool pinlightEnable;        // 0x8A
    public int _Irogae;                // 0x8C (Shader.PropertyToID("_Irogae"))
    private Transform tra;             // 0x90

    // ---- Native statics/seams (see UNKNOWN tags in the header) ----
    /// <summary>
    /// Native `sub_357E268(GameObject)` (decompiled, C pass — /tmp/ida-decomp/f_357e268.c):
    /// walks the object's child Renderers (`sub_43ABD8C(go, true)`), reverses through
    /// each Renderer's shared-material list, and swaps every qualifying material for
    /// the one stored in the CustomShaderUtility static table
    /// (Dictionary&lt;string, Material&gt; built by cctor; the decompile is from the
    /// PREVIOUS build, so its qword_97FDD50/9793818 slots are stale and do not
    /// resolve in the current script.json), then writes it back while re-checking
    /// the previous material reference.
    /// The four name-pattern literals (qword_97EAF98/97E84E8/97E9818 +
    /// qword_98043E0/8, plus keys qword_97E8500/97E84F0) belong to that previous
    /// build; their current slots were not re-derived for this pass, so the
    /// conservative replacement below fires only on an exact registry key match
    /// (material name, then shader name). (The earlier note that IL2CPP
    /// metadata-usage slots are "not statically resolvable" is false: the CURRENT
    /// build's slots all resolve via /tmp/ild/script.json ScriptString — e.g.
    /// "_Irogae" 0x98BF248, shadow asset paths 0x989E9B8..0x989E9D0.) A binder can
    /// still override the whole pass via <see cref="applyShadowMaterials"/>.
    /// </summary>
    public static System.Action<GameObject> applyShadowMaterials;

    /// <summary>
    /// Port of the CustomShaderUtility material table (cctor sub_357DEE4: a
    /// name → Material dictionary built once from the native static resource
    /// table). The port fills it from the loaded `chara_shadow` bundle — the
    /// same shipped assets the dictionary covers in the game — so
    /// `ApplyShadowMaterialsNative` can resolve cross-refs by name.
    /// </summary>
    private static readonly Dictionary<string, Material> shadowMaterialRegistry =
        new Dictionary<string, Material>(80, System.StringComparer.Ordinal);

    /// <summary>
    /// UNKNOWN(current: Live stage manager absent in the ADV spike; previous-build slot 0x9705120, current read Imas.Live.MainLoop_TypeInfo 0x97B93B8): stage manager singleton read by
    /// InitPinSpotLight (field +0x80 -> object with `kind` at +0x10 and
    /// intensities at +0x20/+0x24). Null means "no stage manager", which is the
    /// native no-op path.
    /// </summary>
    public static IPinSpotLightStage pinSpotStage;

    /// <summary>
    /// UNKNOWN(current: Live global shadow-off flag absent; previous-build slot 0x9709770, replaced by the hideCharacterShadow seam): global singleton whose field +432 == 1 means
    /// "hide the character shadow" (native disables both kage renderers).
    /// </summary>
    public static bool hideCharacterShadow;

    /// <summary>
    /// UNKNOWN(current: Live shadow scale default absent; previous-build slot 0x970CCF8+0xC, replaced by the shadowScaleVectorOverride seam): InitShadowMode scales a loaded shadow by
    /// `staticVector * (localScale * 0.6f)` (0x379A5AC). The class token is not
    /// resolvable from the binary here (candidate Imas.LiveInfoParams gives
    /// upCamTgtPosDef = (0, -0.13, 0), which degenerates the kage to zero scale;
    /// the shipped shadow prefabs are 0.01-scaled, so the native multiplier must
    /// be a real scale vector). When not null this override supplies that vector
    /// (binder seam); when null the native expression with
    /// EyeTracking.upCamTgtPosDef is used unchanged.
    /// </summary>
    public static Vector3? shadowScaleVectorOverride;

    // Read-only views for the runtime probe / tests.
    public bool InitOk => initOK;
    public float HeightOffset => height_offset;
    public Transform Model00 => MODEL_00;
    public Transform BodyScale => BODY_SCALE;
    public Transform BaseNode => BASE;
    public Transform AshiL => ASHI_L;
    public Transform AshiR => ASHI_R;
    public Transform Tra => tra;

    /// <summary>Native `Awake` @ 0x379A1F0: tra = transform.</summary>
    public void Awake()
    {
        tra = transform;
    }

    /// <summary>Native `SetHeightOffset` @ 0x379A220.</summary>
    public void SetHeightOffset(float offset)
    {
        height_offset = offset;
    }

    /// <summary>
    /// Integration alias used by B5's JointBodyHeadNative comments
    /// (`dshadow.Initialize(shadow, ABShadow)`); the native method name is
    /// SetShadowMode (0x379A228), so this only forwards.
    /// </summary>
    public void Initialize(Shadow mode, AssetBundle ABShadow)
    {
        SetShadowMode(mode, ABShadow);
    }

    /// <summary>
    /// Integration alias for character visibility (B5 hook name). Native does
    /// this through LightAndShadowByChara (0x379B504); forwards unchanged.
    /// </summary>
    public void SetVisible(bool show)
    {
        LightAndShadowByChara(show);
    }

    /// <summary>
    /// Native `SetShadowMode(Shadow, AssetBundle)` @ 0x379A228.
    /// Synchronous load path. The native code loads through
    /// `AssetBundleManager.GetResource&lt;GameObject&gt;(bundle, path)`
    /// (callee 0x421BDCC); Unity's AssetBundle API loads the same shipped
    /// prefab, which is the allowed performance-layer replacement.
    /// </summary>
    public void SetShadowMode(Shadow mode, AssetBundle ABShadow)
    {
        shadowMode = mode;
        RegisterShadowBundleMaterials(ABShadow);

        // STAGE_CIRCLE / STAGE_STAR: lightObj = Load("Chara/Shadow/ltmap_chara")
        if (mode == Shadow.STAGE_CIRCLE || mode == Shadow.STAGE_STAR)
        {
            lightObj = LoadShadowAsset(ABShadow, "Chara/Shadow/ltmap_chara");
        }

        if (mode == Shadow.NONE)
        {
            InitShadowMode(mode, null);
            return;
        }

        // kage1Obj: sd_chara2 for STAR/STAGE_STAR, sd_chara otherwise.
        string kageName = (mode == Shadow.STAR || mode == Shadow.STAGE_STAR)
            ? "Chara/Shadow/sd_chara2"
            : "Chara/Shadow/sd_chara";
        kage1Obj = LoadShadowAsset(ABShadow, kageName);

        // STAGE_STAR loads a second copy for the second foot.
        if (mode == Shadow.STAGE_STAR)
        {
            kage2Obj = LoadShadowAsset(ABShadow, kageName);
        }

        // STAGE_*: InitShadowMode receives the pin spot prefab.
        GameObject pin = null;
        if (mode == Shadow.STAGE_CIRCLE || mode == Shadow.STAGE_STAR)
        {
            pin = LoadShadowAsset(ABShadow, "Chara/Shadow/lt_pin_spot");
        }
        InitShadowMode(mode, pin);
    }

    /// <summary>
    /// Native `SetShadowModeAsync` @ 0x379ADD4 (+ iterator MoveNext 0x379B8DC).
    /// Keeps the native state machine and load order; the native code awaits
    /// AssetBundleLoadResourceOperation objects, here the bundle is local so the
    /// operation is replaced by a frame yield (performance-layer equivalence).
    /// </summary>
    public IEnumerator SetShadowModeAsync(Shadow mode, AssetBundle ABShadow)
    {
        shadowMode = mode;
        RegisterShadowBundleMaterials(ABShadow);

        // state 0: STAGE_* loads the light beam plate first.
        if (mode == Shadow.STAGE_CIRCLE || mode == Shadow.STAGE_STAR)
        {
            lightObj = LoadShadowAsset(ABShadow, "Chara/Shadow/ltmap_chara");
            yield return null;
        }

        // state 1: NONE finishes; otherwise start kage load.
        if (mode == Shadow.NONE)
        {
            InitShadowMode(mode, null);
            yield break;
        }

        string kageName = (mode == Shadow.STAR || mode == Shadow.STAGE_STAR)
            ? "Chara/Shadow/sd_chara2"
            : "Chara/Shadow/sd_chara";
        kage1Obj = LoadShadowAsset(ABShadow, kageName);
        yield return null;

        // state 2: STAGE_STAR starts the second kage load.
        if (mode == Shadow.STAGE_STAR)
        {
            kage2Obj = LoadShadowAsset(ABShadow, kageName);
            yield return null;
        }

        // state 3: STAGE_* starts the pin-spot load, then wires everything.
        GameObject pin = null;
        if (mode == Shadow.STAGE_CIRCLE || mode == Shadow.STAGE_STAR)
        {
            pin = LoadShadowAsset(ABShadow, "Chara/Shadow/lt_pin_spot");
            yield return null;
        }
        InitShadowMode(mode, pin);
    }

    /// <summary>
    /// Native `InitShadowMode(Shadow, Object)` @ 0x379A5AC.
    /// Wires the loaded prefabs to the character bones. `pinSpotAsset` is the
    /// `lt_pin_spot` prefab for STAGE_* modes, null otherwise.
    /// </summary>
    public void InitShadowMode(Shadow mode, Object pinSpotAsset)
    {
        _Irogae = Shader.PropertyToID("_Irogae");
        shadowMode = mode;
        // native: *(WORD*)(this+0x88) = 257 -> pinlightevSW = pinlightshowSW = true
        pinlightevSW = true;
        pinlightshowSW = true;

        setTransforms();

        // --- STAGE_*: light beam / map plate under MODEL_00? (native keeps it
        //     with BODY_SCALE for the light object; see below) ---
        if (mode == Shadow.STAGE_CIRCLE || mode == Shadow.STAGE_STAR)
        {
            if (lightObj != null)
            {
                ApplyShadowMaterials(lightObj);
                var lt = lightObj.transform;
                lt.SetParent(BODY_SCALE, false);                        // 0x70BFCE0
                lt.localPosition = new Vector3(0f, -0.005f, 0f);        // 0x70BE1B4
                lightObj.SetActive(true);                               // 0x70AB9E4
            }
        }

        if (mode != Shadow.NONE)
        {
            // Common first kage (all non-NONE modes).
            ApplyShadowMaterials(kage1Obj);

            if (mode == Shadow.CIRCLE || mode == Shadow.STAGE_CIRCLE)
            {
                WireKage(kage1Obj, BODY_SCALE, Vector3.zero);
            }
            else if (mode == Shadow.STAGE_STAR)
            {
                // Native handles kage1 and kage2 with the same sequence.
                WireKage(kage1Obj, BODY_SCALE, Vector3.zero);
                ApplyShadowMaterials(kage2Obj);
                WireKage(kage2Obj, BODY_SCALE, Vector3.zero);
            }

            // Pin spot light: only STAGE_* and only when the prefab exists.
            if ((mode == Shadow.STAGE_CIRCLE || mode == Shadow.STAGE_STAR) && pinSpotAsset != null)
            {
                pinlightObj = pinSpotAsset as GameObject;
                if (pinlightObj != null)
                {
                    var pt = pinlightObj.transform;
                    pt.SetParent(MODEL_00, false);                      // 0x58 (MODEL_00)
                    pt.localPosition = Vector3.zero;
                    ScaleLikeNative(pt);
                    pinlightObj.SetActive(true);
                    SetRendererEnabled(pinlightObj, true);
                }

                // UNKNOWN(current: Live global shadow-off flag absent; previous-build slot 0x9709770, replaced by the hideCharacterShadow seam): when the global shadow-off flag is
                // set, the native code disables both kage renderers after the
                // pin spot has been wired.
                if (hideCharacterShadow)
                {
                    SetRendererEnabled(kage1Obj, false);
                    SetRendererEnabled(kage2Obj, false);
                }
            }
        }

        initOK = true; // native 0x379A5AC writes *(this+0x82) = 1 last.
    }

    /// <summary>
    /// Native `InitPinSpotLight` @ 0x379AFD0. Reads the stage manager's light
    /// kind (UNKNOWN(current: Live stage manager absent in the ADV spike; previous-build slot 0x9705120, current read Imas.Live.MainLoop_TypeInfo 0x97B93B8)) to decide `pinlightEnable`, caches the
    /// two materials and hides the pin object until SetPinLightState opens it.
    /// With no stage manager this is the native no-op path.
    /// </summary>
    public void InitPinSpotLight()
    {
        if (pinSpotStage == null) return;
        int lightKind = pinSpotStage.GetPinSpotLightKind();
        if (!pinSpotStage.IsPinSpotActive()) return;

        if (lightObj != null)
        {
            var r = lightObj.GetComponent<Renderer>();
            if (r != null) lightmat = r.sharedMaterial;
        }
        if (pinlightObj != null)
        {
            pinlightObj.SetActive(false);
            pinlightEnable = lightKind == 0;
            var r = pinlightObj.GetComponent<Renderer>();
            if (r != null) pinmat = r.sharedMaterial;
        }
    }

    /// <summary>
    /// Native `SetPinLightState(bool sw, bool useGlobalColor, bool isEvent, float scaleY)`
    /// @ 0x379B238.
    /// </summary>
    public void SetPinLightState(bool sw, bool useGlobalColor, bool isEvent = false, float scaleY = -1f)
    {
        if (isEvent) pinlightevSW = sw;
        else pinlightshowSW = sw;

        if (pinlightObj != null)
        {
            bool active = pinlightevSW && pinlightshowSW && pinlightEnable;
            pinlightObj.SetActive(active);
            if (scaleY >= 0f)
            {
                var t = pinlightObj.transform;
                t.localScale = new Vector3(1f, scaleY, 1f);
            }
        }

        if (lightmat != null) lightmat.SetFloat(_Irogae, useGlobalColor ? 1f : 0f);
        if (pinmat != null) pinmat.SetFloat(_Irogae, useGlobalColor ? 1f : 0f);
    }

    /// <summary>Native `CopyPinSpotParam(DropShadow src)` @ 0x379B458.</summary>
    public void CopyPinSpotParam(DropShadow src)
    {
        if (src == null) return;
        pinlightevSW = src.pinlightevSW;
        pinlightshowSW = src.pinlightshowSW;
        pinlightEnable = src.pinlightEnable;
    }

    /// <summary>Native `LightAndShadowByEvent(bool show)` @ 0x379B47C.</summary>
    public void LightAndShadowByEvent(bool show)
    {
        eventSW = show;
        if (kage1Obj != null) kage1Obj.SetActive(show && charaSW);
        if (kage2Obj != null) kage2Obj.SetActive(show && charaSW);
        if (lightObj != null) lightObj.SetActive(show && charaSW);
    }

    /// <summary>Native `LightAndShadowByChara(bool show)` @ 0x379B504.</summary>
    public void LightAndShadowByChara(bool show)
    {
        charaSW = show;
        if (kage1Obj != null) kage1Obj.SetActive(eventSW && show);
        if (kage2Obj != null) kage2Obj.SetActive(eventSW && show);
        if (lightObj != null) lightObj.SetActive(eventSW && show);
    }

    /// <summary>
    /// Native `setTransforms` @ 0x379AE78: caches the character skeleton nodes
    /// through `Transform.Find(path)` from this component's own transform.
    /// </summary>
    private void setTransforms()
    {
        if (tra == null) return;
        MODEL_00 = tra.Find("MODEL_00");                                         // 0x58
        BODY_SCALE = tra.Find("MODEL_00/BODY_SCALE");                            // 0x60
        BASE = tra.Find("MODEL_00/BODY_SCALE/BASE");                             // 0x68
        ASHI_L = tra.Find("MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_L/HIZA_L/ASHI_L");// 0x70
        ASHI_R = tra.Find("MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_R/HIZA_R/ASHI_R");// 0x78
    }

    /// <summary>
    /// Native `LateUpdate` @ 0x379B58C. Follows the character's ground position;
    /// STAGE_STAR pins the two kages to the feet, everything else keeps one kage
    /// under the body at `height_offset`.
    /// </summary>
    public void LateUpdate()
    {
        if (shadowMode == Shadow.NONE) return;

        float dx = 0f, dz = 0f;
        if (initOK)
        {
            // Native: BODY_SCALE.localScale.x * BASE.position.{x,z}
            // (0x70BF870 get_localScale, 0x70BE0A8 get_position).
            if (BODY_SCALE != null && BASE != null)
            {
                float s = BODY_SCALE.localScale.x;
                Vector3 bp = BASE.position;
                dx = s * bp.x;
                dz = s * bp.z;
            }

            if (shadowMode == Shadow.STAGE_CIRCLE || shadowMode == Shadow.STAGE_STAR)
            {
                if (lightObj != null)
                    lightObj.transform.localPosition = new Vector3(dx, -0.005f, dz);
            }
        }

        if (!initOK) return;

        if (shadowMode == Shadow.STAGE_STAR)
        {
            if (kage1Obj != null && ASHI_L != null)
            {
                var t = kage1Obj.transform;
                t.position = ASHI_L.position;
                t.rotation = Quaternion.Inverse(tra != null ? tra.rotation : Quaternion.identity);
            }
            if (kage2Obj != null && ASHI_R != null)
            {
                var t = kage2Obj.transform;
                t.position = ASHI_R.position;
                t.rotation = Quaternion.Inverse(tra != null ? tra.rotation : Quaternion.identity);
            }
        }
        else
        {
            if (kage1Obj != null)
            {
                var t = kage1Obj.transform;
                t.localPosition = new Vector3(dx, height_offset, dz);
                t.rotation = Quaternion.Inverse(tra != null ? tra.rotation : Quaternion.identity);
            }
        }

        if (lightObj != null)
            lightObj.transform.localPosition = new Vector3(dx, 0f, dz);
    }

    // ------------------------------------------------------------------
    // Helpers (performance/binding layer; no behaviour change)
    // ------------------------------------------------------------------

    /// <summary>
    /// Native `AssetBundleManager.GetResource&lt;GameObject&gt;(bundle, path)`
    /// (0x421BDCC) with the verified "Chara/Shadow/..." keys. Unity asset
    /// bundles store the objects under their short names, so try the native
    /// path, then its basename, then scan the bundle for a matching prefab.
    /// </summary>
    private static GameObject LoadShadowAsset(AssetBundle bundle, string nativePath)
    {
        if (bundle == null) return null;
        var go = bundle.LoadAsset<GameObject>(nativePath);
        if (go != null) return go;
        string shortName = nativePath.Substring(nativePath.LastIndexOf('/') + 1);
        go = bundle.LoadAsset<GameObject>(shortName);
        if (go != null) return go;
        foreach (var candidate in bundle.LoadAllAssets<GameObject>())
        {
            if (candidate == null) continue;
            if (candidate.name == shortName) return candidate;
        }
        Debug.LogWarning($"DropShadow: shadow asset not found in bundle: {nativePath}");
        return null;
    }

    private static void ApplyShadowMaterials(GameObject go)
    {
        if (go == null) return;
        if (applyShadowMaterials != null)
        {
            applyShadowMaterials(go);
            return;
        }
        ApplyShadowMaterialsNative(go);
    }

    /// <summary>
    /// sub_357E268 port: child Renderers (true, sub_43ABD8C) → per-Rendère
    /// shared-materials in reverse order → registry lookup → write-back.
    /// Because the four name-pattern literals are UNKNOWN (see field doc), the
    /// neutral policy only fires where the registry already contains an entry
    /// for the exact material name (or shader name) — never invents a key.
    /// </summary>
    private static void ApplyShadowMaterialsNative(GameObject go)
    {
        var renderers = go.GetComponentsInChildren<Renderer>(true);
        if (renderers == null || renderers.Length == 0) return;
        for (var r = renderers.Length - 1; r >= 0; r--)   // native walks the reverse indices
        {
            var rend = renderers[r];
            if (rend == null) continue;
            var mats = rend.sharedMaterials;               // sub_706C85C
            if (mats == null || mats.Length == 0) continue;
            var replaced = false;
            for (var i = mats.Length - 1; i >= 0; i--)
            {
                var mat = mats[i];
                if (mat == null) continue;
                Material replacement;
                // apply-path key read: the pass keyed on the sub_706FBF0 name of
                // each shared material; try material name, then shader name.
                if (!shadowMaterialRegistry.TryGetValue(mat.name, out replacement) &&
                    (mat.shader == null || !shadowMaterialRegistry.TryGetValue(mat.shader.name, out replacement)))
                    continue;
                if (replacement == null || replacement == mat) continue;
                mats[i] = replacement;                     // sub_706FD2C write-back
                replaced = true;
            }
            if (replaced) rend.sharedMaterials = mats;
        }
    }

    /// <summary>
    /// Registers the loaded shadow bundle into the CustomShaderUtility port
    /// table (idempotent). Called from SetShadowMode/SetShadowModeAsync where
    /// the native path loads the same bundle through
    /// AssetBundleManager.GetResource (UNKNOWN(current: AssetBundleManager.GetResource<Object> MethodRef 0x981E430; previous-build slot qword_97FDD50) source).
    /// </summary>
    public static void RegisterShadowBundleMaterials(AssetBundle bundle)
    {
        if (bundle == null) return;
        var materials = bundle.LoadAllAssets<Material>();
        if (materials == null) return;
        foreach (var mat in materials)
        {
            if (mat == null || string.IsNullOrEmpty(mat.name)) continue;
            shadowMaterialRegistry[mat.name] = mat;
        }
    }

    /// <summary>
    /// Native InitShadowMode wiring for one kage object:
    /// SetParent(BODY_SCALE, false), localPosition, localScale =
    /// upCamTgtPosDef * (localScale * 0.6), active, renderer.enabled = true.
    /// The 0.6 factor and upCamTgtPosDef are the native immediates
    /// (LiveInfoParams static +0xC, UNKNOWN(current: Imas.LiveInfoParams cctor absent; previous-build slot 0x969...) but read through the
    /// same static seam as EyeTracking).
    /// </summary>
    private static void WireKage(GameObject go, Transform parent, Vector3 localPosition)
    {
        if (go == null) return;
        var t = go.transform;
        t.SetParent(parent, false);
        t.localPosition = localPosition;
        ScaleLikeNative(t);
        go.SetActive(true);
        SetRendererEnabled(go, true);
    }

    private static void ScaleLikeNative(Transform t)
    {
        // 0x70BF870 get_localScale -> Vector3; native multiplies component-wise
        // by the static vector at UNKNOWN(current: Live shadow scale default absent; previous-build slot 0x970CCF8+0xC, replaced by the shadowScaleVectorOverride seam) and 0.6f.
        Vector3 basePosDef = shadowScaleVectorOverride ?? EyeTracking.upCamTgtPosDef;
        t.localScale = new Vector3(
            basePosDef.x * (t.localScale.x * 0.6f),
            basePosDef.y * (t.localScale.y * 0.6f),
            basePosDef.z * (t.localScale.z * 0.6f));
    }

    private static void SetRendererEnabled(GameObject go, bool enabled)
    {
        if (go == null) return;
        var r = go.GetComponent<Renderer>();
        if (r != null) r.enabled = enabled; // 0x706B574 Renderer.set_enabled
    }
}

/// <summary>
/// UNKNOWN(current: Live stage manager absent in the ADV spike; previous-build slot 0x9705120, current read Imas.Live.MainLoop_TypeInfo 0x97B93B8): the stage manager the native DropShadow reads for
/// pin-spot light kind/activation. B4 cannot identify the class from the binary
/// without the metadata-registration type table; the binder supplies it.
/// </summary>
public interface IPinSpotLightStage
{
    /// <summary>Native reads object+0x10 (kind == 2) then +0x24 / +0x20.</summary>
    int GetPinSpotLightKind();
    /// <summary>Native checks the stage manager singleton and its idol pointer.</summary>
    bool IsPinSpotActive();
}
