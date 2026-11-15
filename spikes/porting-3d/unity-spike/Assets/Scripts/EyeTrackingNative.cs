// Native-faithful port of the game's `Imas.EyeTracking` (ADR-0033 batch B4).
//
// Source of truth (all addresses are IDA image-base-0 VAs of the shipped
// `UnityFramework` / Il2CppDumper `dump.cs` TypeDefIndex 9599):
//   EyeTracking.Start                       0x379BF7C  (native body is empty/nullsub)
//   EyeTracking.Init                        0x379BF80
//   EyeTracking.SetTarget                   0x379C254
//   EyeTracking.SetExternalEyeAnimationFactor 0x379C2B4
//   EyeTracking.EyeUpdate                   0x379C2BC
//   EyeTracking.GetCamTgtPos                0x379D1BC
//   EyeTracking.SetMaterials                0x379D5A8
//   EyeTracking.SetMaterial                 0x379D6AC
//   EyeTracking.SetTeary                    0x379D768
//   EyeTracking.SetTargetCamera             0x379D778
//   EyeTracking.ctor                        0x379D948
//   EyeTracking.EyeTrackParam.ctor          0x379D9FC
//   EyeTracking.OnDrawGizmos                0x379D944  (empty)
//
// Decompiles: /tmp/ida-decomp/379c2bc.c (EyeUpdate), 379bf80.c (Init),
// 379c254.c, 379c2b4.c, 379d1bc.c, 379d5a8.c, 379d6ac.c, 379d768.c,
// 379d778.c, 379d948.c.
//
// Verified literals (global-metadata v31, resolved through the IL2CPP
// metadata-usage decoder 0x8BE78C, so these are the shipped strings and not
// guesses):
//   "_SubTex" (0x98085B0), "_VfxTex" (0x9808898)
//   "/obj_head_GP/eyes" (0x97DE5B8), "EyeTgT" (0x97ED6A8),
//   "_sub" (0x9809388), "Idol" (0x97F11F8)
// Verified fields / constants from the ctor 0x379D948:
//   on = true, scale = 1.0f, external_eye_anime_factor = -1.0f, tgtIdol = 1,
//   yuragiSpeed = 1, yuragiScale = 1.0f.
// EyeTrackParam ctor xmmword_842AE10 = {0.004f, 10f, -10f, 30f} + Right = -30f.
//
// ADR-0033: behaviour must follow the native code. Only the performance layer
// (jobs/NativeArray/TransformAccess/asset-manager async plumbing) is replaced
// with plain C#/Unity calls. Where the binary's semantics need a piece of the
// live/stage runtime that does not exist in this spike (DanceCameraManager,
// LiveInfoParams loader, AppmasVector screen-ratio cctor, stage light manager)
// a *binding seam* is exposed and the missing native fact is marked UNKNOWN —
// no values are invented.
//
// Assembly (see /tmp/eyes-shadow-native-notes.md):
//   * The component must live on the *same GameObject as the eye
//     SkinnedMeshRenderer* (`ch_<...>/obj_head_GP/eyes`), because
//     Init() takes `eye_base = transform` (native 0x379BF80 reads
//     Component.get_transform on `this`).
//   * Init() then resolves `rendEye` exactly like the native code:
//       GameObject.Find(body.name + "/obj_head_GP/eyes").GetComponent<Renderer>()
//     (0x379BF80 lines: GameObject.get_name, String.Concat, GameObject.Find,
//     GetComponent<Renderer> MethodRef 0xC00619BD).
//   * `eyeTarget` follows the native naming rule:
//       "EyeTgT" + body.name.Replace("_sub","").Replace("Idol","")
//     (0x379BF80; literals quoted above). If no such scene object exists the
//     native code creates one (new GameObject with that name) — ported verbatim.
//
// UNKNOWN tags in this file:
//   UNKNOWN(native 0x9705120) live/stage manager singleton used by the eye
//     target base and by pin-spot init (class identity not recovered from the
//     binary without the metadata-registration type table; only its field
//     offsets are observed).
//   UNKNOWN(native 0x9704BE0) stage/idol-list manager used for the Front sign
//     flags and the OtherIdol list.
//   UNKNOWN(native Imas.AppmasVector 0x36D0140..0x36D02C4) screenRatioV / r are
//     computed from the screen aspect in a cctor that is not part of batch B4;
//     exposed as settable statics with the CLR zero/one defaults.
//   UNKNOWN(native 0x379C2BC type=4) IDA emits `Eye.position.y` twice in the
//     Fixed-target y term; treated as a decompiler artifact, counted once.
//   UNKNOWN(native 0x379C2BC type=3) the Mune2-forward term uses
//     Transform.get_forward * 100 (the decompiler folds the Vector3 into a
//     float; reconstructed as Vector3 multiplication).

using System;
using UnityEngine;

/// <summary>`EyeTracking.eyedirtype` (dump.cs TypeDefIndex 9598).</summary>
public enum eyedirtype
{
    Front = 0,
    LookCamera = 1,
    LookRFinger = 2,
    BustDir = 3,
    Fixed = 4,
    FaceRelative = 5,
    OtherIdol = 6,
    FmtFront = 7,
    CamFix = 8,
    LookLFinger = 9,
}

/// <summary>
/// `EyeTracking.EyeTrackParam` (dump.cs TypeDefIndex 9597).
/// Defaults are the exact immediates from the native ctor 0x379D9FC:
/// xmmword_842AE10 = {0.004f, 10f, -10f, 30f}, then -30f right limit.
/// </summary>
[Serializable]
public class EyeTrackParam
{
    public const float DefaultEyeDirScale = 0.004f;
    public const float DefaultEyeDirLimUp = 10f;
    public const float DefaultEyeDirLimDown = -10f;
    public const float DefaultEyeDirLimLeft = 30f;
    public const float DefaultEyeDirLimRight = -30f;

    public float EyeDirScale;
    public float EyeDirLimUp;
    public float EyeDirLimDown;
    public float EyeDirLimLeft;
    public float EyeDirLimRight;

    public EyeTrackParam()
    {
        EyeDirScale = DefaultEyeDirScale;
        EyeDirLimUp = DefaultEyeDirLimUp;
        EyeDirLimDown = DefaultEyeDirLimDown;
        EyeDirLimLeft = DefaultEyeDirLimLeft;
        EyeDirLimRight = DefaultEyeDirLimRight;
    }
}

/// <summary>
/// The subset of the native `DanceIdolInfo` (TypeDefIndex 16374) + its
/// `JointBodyHead model` (TypeDefIndex 15271) that EyeTracking reads.
///
/// Native mapping (field offsets in DanceIdolInfo / JointBodyHead):
///   info.model (0x98)             -> model
///   model.body (0x18)             -> body
///   model.Atama (0x40)            -> atama
///   model.Mune2 (0x68)            -> mune2
///   model.RFinger (0x70)          -> rFinger
///   model.LFinger (0x78)          -> lFinger
///   model.Eye (0x80)              -> eye
///   info.formationRy (0x44)       -> formationRy
///   info.rotFmtRy (0x48)          -> rotFmtRy
///   info.liveEyeTargetMode (0xF0) -> liveEyeTargetMode
///
/// JointBodyHead is owned by batch B5; this adapter keeps B4 independently
/// compilable (ADR-0033 forbids guessing the missing class shape). The binder
/// fills the same object graph the native JointBodyHead would expose.
/// </summary>
[Serializable]
public class EyeTrackingIdolInfo
{
    public GameObject body;   // JointBodyHead.body (0x18)
    public GameObject atama;  // JointBodyHead.Atama (0x40)
    public GameObject mune2;  // JointBodyHead.Mune2 (0x68)
    public GameObject rFinger;// JointBodyHead.RFinger (0x70)
    public GameObject lFinger;// JointBodyHead.LFinger (0x78)
    public GameObject eye;    // JointBodyHead.Eye (0x80)

    public float formationRy;          // DanceIdolInfo.formationRy (0x44)
    public Quaternion rotFmtRy = Quaternion.identity; // DanceIdolInfo.rotFmtRy (0x48)
    public bool liveEyeTargetMode;     // DanceIdolInfo.liveEyeTargetMode (0xF0)

    /// <summary>
    /// Integration seam (NOT a native field). Native resolves the eye renderer
    /// with `GameObject.Find(body.name + "/obj_head_GP/eyes")`; in this spike
    /// the head prefab is parented under the body's ATAMA bone, so that path is
    /// not findable by name. When set, this full scene path is used instead and
    /// the rest of Init still runs the native logic.
    /// </summary>
    public string eyesScenePathOverride;
}

/// <summary>
/// Native-faithful `Imas.EyeTracking` (type 9599).
///
/// Put on the eye renderer's GameObject (`.../obj_head_GP/eyes`) and call
/// <see cref="Init"/> from the character binder every time the character is
/// instantiated (the native component is added by JointBodyHead and Init'ed
/// with its DanceIdolInfo; native Start 0x379BF7C is empty).
/// </summary>
public class EyeTracking : MonoBehaviour
{
    // ---- Stage / screen globals the native code reads (see UNKNOWN tags) ----
    // Imas.LiveInfoParams static Vector3 fields (dump.cs): +0x0, +0xC, +0x18, +0x24.
    // Initial values are the exact cctor constants (0x1EFC7D8, xmmword_8428050..70
    // read from the shipped UnityFramework):
    //   upCamPosDef = (0, 0.05, 1.9)      upCamTgtPosDef = (0, -0.13, 0)
    //   loopCamPosDef = (0, 0.1, 2.6)     loopCamTgtPosDef = (0, -0.3, 0)
    // UNKNOWN(native 0x970CCF8): the class token used by EyeTracking.GetCamTgtPos /
    // EyeUpdate is inferred to be LiveInfoParams (it is the only class with a
    // static Vector3 at both 0x0 and 0xC). A live stage load overwrites these.
    public static Vector3 upCamPosDef = new Vector3(0f, 0.05f, 1.9f);
    public static Vector3 upCamTgtPosDef = new Vector3(0f, -0.13f, 0f);
    // Imas.AppmasVector static Vector2 fields: r (0x0), screenRatioV (0x8).
    // Native cctor 0x36D02C4 sets r = (1280, 720) and screenRatioV = r;
    // AppmasVector.screenRatio() 0x36D0140 recomputes
    //   screenRatioV = (Screen.width / r.x, Screen.height / r.y).
    // The game boot calls it; this spike has no such bootstrap, so the binder
    // calls EyeTracking.RefreshScreenRatio() once (see notes).
    public static Vector2 appmasVectorR = new Vector2(1280f, 720f);
    public static Vector2 screenRatioV = new Vector2(1280f, 720f);
    // UNKNOWN(native 0x9705120): live/stage manager presence. Native checks the
    // singleton and a stage-idol pointer; when absent the Front path keeps
    // +frontDepth and the eye base stays upCamPosDef.
    public static bool liveStageManagerValid;
    // UNKNOWN(native 0x379C2BC type 0/7): the native code picks the sign of the
    // front-depth term from two stage flags (0x1EFDE64 / 0x1F06E28 on
    // UNKNOWN(native 0x9704BE0)). Default is the no-manager value: +1.
    public static int frontDepthSign = 1;
    // UNKNOWN(native 0x379C2BC type 6): the "other idol" array lives on
    // UNKNOWN(native 0x9704BE0); native indexes [tgtIdol - 1].model.Atama.
    public static EyeTrackingIdolInfo[] idolList;
    // Adapter for the native DanceCameraManager (GetCamTgtPos 0x379D1BC,
    // SetTargetCamera 0x379D778). Native falls back to LiveInfoParams.upCamTgtPosDef
    // when the manager is absent, which is what happens here unless the binder
    // supplies a provider (performance-layer seam only).
    public static Func<int, Vector3> camTgtPosProvider;
    public static Func<int, int> camIndexRemap;

    /// <summary>
    /// Imas.AppmasVector.screenRatio() 0x36D0140:
    /// screenRatioV = (Screen.width / r.x, Screen.height / r.y), r = (1280,720).
    /// The native game calls this on resolution setup; call it once at startup
    /// in this spike (otherwise material scales read the cctor default).
    /// </summary>
    public static void RefreshScreenRatio()
    {
        screenRatioV = new Vector2(Screen.width / appmasVectorR.x,
                                   Screen.height / appmasVectorR.y);
    }

    // ---- Native fields (names/order from dump.cs; offsets in comments) ----
    public EyeTrackParam eyeTrackParam = new EyeTrackParam(); // 0x20

    /// <summary>The live idol's eye tracker, for the stand's scripted gaze.</summary>
    public static EyeTracking Active;

    /// <summary>
    /// Scripted gaze (ADV `actor_eye_direction`). The native actor stores the rate in
    /// CharacterActorBase (+0x13c/+0x140) and CharacterActorBase.SetEyeDirectionByRate
    /// (0x3822AF0) maps it onto the eye rotation limits instead of the camera target;
    /// this replica overrides the same two clamped angles.
    /// </summary>
    private bool forcedGaze;
    private float forcedGazeH;
    private float forcedGazeV;

    public void SetForcedGaze(float hRate, float vRate)
    {
        forcedGaze = true;
        forcedGazeH = Mathf.Clamp(hRate, -1f, 1f);
        forcedGazeV = Mathf.Clamp(vRate, -1f, 1f);
    }

    public void ClearForcedGaze()
    {
        forcedGaze = false;
    }
    public const float frontDepth = 20f;                      // native const
    private Transform eye_base;                               // 0x28
    public Transform eyeTarget;                               // 0x30
    public Vector3 eyeTargetPos;                              // 0x38
    public bool on = true;                                    // 0x44 (ctor 0x379D948)
    private bool initf;                                       // 0x45
    private EyeTrackingIdolInfo info;                         // 0x48 (DanceIdolInfo)
    public eyedirtype type;                                   // 0x50
    public float scale = 1f;                                  // 0x54 (ctor 0x379D948)
    public int evCamNo;                                       // 0x58
    public int camNo;                                         // 0x5C
    public bool camSampled;                                   // 0x60
    private const float vfx_uv_base = 0.95f;
    private const float vfx_uv_range = 0.05f;
    private const float vfx_uv_speed = 5f;
    private float vfx_anime_phase;                            // 0x64
    private float external_eye_anime_factor = -1f;            // 0x68 (ctor 0x379D948)
    public float offX;                                        // 0x6C
    public float offY;                                        // 0x70
    public int tgtIdol = 1;                                   // 0x74 (ctor 0x379D948)
    private float eye_rx;                                     // 0x78
    private float eye_ry;                                     // 0x7C
    private bool teary;                                       // 0x80
    private Renderer rendEye;                                 // 0x88
    private Material[] eyeMats;                               // 0x90
    private bool useEyeMats;                                  // 0x98
    private float yuragiPhase;                                // 0x9C
    private int yuragiSpeed = 1;                              // 0xA0 (ctor 0x379D948)
    private float yuragiScale = 1f;                           // 0xA4 (ctor 0x379D948)
    private int id_SubTex;                                    // 0xA8
    private int id_VfxTex;                                    // 0xAC

    // Read-only views for the runtime probe / tests.
    public bool Initialized => initf;
    public bool On => on;
    public bool Teary => teary;
    public float EyeRX => eye_rx;
    public float EyeRY => eye_ry;
    public float ExternalEyeAnimationFactor => external_eye_anime_factor;
    public Renderer EyeRenderer => rendEye;
    public Material[] EyeMaterials => eyeMats;
    public bool UseEyeMaterials => useEyeMats;
    public EyeTrackingIdolInfo IdolInfo => info;
    public Transform EyeBase => eye_base;
    public Transform EyeTarget => eyeTarget;

    // Native Start 0x379BF7C is an empty function (nullsub_10067); Init is
    // driven by JointBodyHead, so nothing happens on its own.
    private void Start() { }

    /// <summary>
    /// Native `EyeTracking.Init(DanceIdolInfo)` @ 0x379BF80.
    /// </summary>
    public void Init(EyeTrackingIdolInfo info0)
    {
        Active = this;
        info = info0;
        // 0x379BF80: eye_base = Component.get_transform(this).
        eye_base = transform;

        // rendEye = GameObject.Find(body.name + "/obj_head_GP/eyes")
        //              .GetComponent<Renderer>();
        // (native: Object.get_name 0x70B2A88, String.Concat 0x644E67C,
        //  GameObject.Find 0x70ACE14, GetComponent<Renderer> 0x43AB164 with
        //  MethodRef 0xC00619BD, literal "/obj_head_GP/eyes" 0xA0001133.)
        rendEye = null;
        if (info != null && info.body != null)
        {
            string path = !string.IsNullOrEmpty(info.eyesScenePathOverride)
                ? info.eyesScenePathOverride
                : info.body.name + "/obj_head_GP/eyes";
            var eyesGo = GameObject.Find(path);
            if (eyesGo != null) rendEye = eyesGo.GetComponent<Renderer>();
        }
        if (rendEye == null)
        {
            // Native would dereference null here. For integration we fall back to
            // the renderer on the same GameObject (the component is required to
            // be on the eye SMR object by construction); recorded as an
            // integration deviation in the notes.
            rendEye = GetComponent<Renderer>();
        }

        // Native 0x379BF80: when the DanceIdolInfo is in live-eye-target mode the
        // whole eyeTarget block is skipped (jump to LABEL_20); everything below
        // still runs, including the property ids and initf = true.
        if (info != null && !info.liveEyeTargetMode)
        {
            // eyeTarget = GameObject.Find("EyeTgT" + bodyName without "_sub"/"Idol");
            // if missing, native creates a new GameObject with that name.
            // (literals "EyeTgT" 0x97ED6A8, "_sub" 0x9809388, "Idol" 0x97F11F8.)
            string bodyName = info.body != null ? info.body.name : string.Empty;
            string eyeTgtName = "EyeTgT" + bodyName.Replace("_sub", string.Empty).Replace("Idol", string.Empty);
            var eyeTgtGo = GameObject.Find(eyeTgtName);
            if (eyeTgtGo == null) eyeTgtGo = new GameObject(eyeTgtName);
            eyeTarget = eyeTgtGo.transform;
        }

        // 0x379BF80 tail: type = 0 (Front), evCamNo/camNo = 0,
        // camSampled = false, SetTargetCamera(0).
        type = eyedirtype.Front;
        evCamNo = 0;
        camNo = 0;
        camSampled = false;
        SetTargetCamera(0);

        // type 4/5 clear offX/offY in native Init.
        if (type == eyedirtype.Fixed || type == eyedirtype.FaceRelative)
        {
            offX = 0f;
            offY = 0f;
        }

        // Shader.PropertyToID for the two scrolling texture slots.
        id_SubTex = Shader.PropertyToID("_SubTex"); // literal 0x98085B0
        id_VfxTex = Shader.PropertyToID("_VfxTex"); // literal 0x9808898
        initf = true;
    }

    /// <summary>Native `SetTarget` @ 0x379C254.</summary>
    public void SetTarget(eyedirtype type0, float offX0, float offY0, int cam, int idol)
    {
        camSampled = false;
        type = type0;
        SetTargetCamera(cam);
        if (idol >= 1) tgtIdol = idol;
        if (type0 == eyedirtype.Fixed || type0 == eyedirtype.FaceRelative)
        {
            offX = offX0;
            offY = offY0;
        }
    }

    /// <summary>Native `SetTargetCamera` @ 0x379D778.</summary>
    public void SetTargetCamera(int cam)
    {
        evCamNo = cam;
        camNo = cam;
        // Native: if the DanceCameraManager singleton is valid, camNo is remapped
        // through its index table (0x379D778 -> 0x1F6A3CC). Absent manager keeps
        // the raw index.
        if (camIndexRemap != null) camNo = camIndexRemap(cam);
    }

    /// <summary>Native `SetExternalEyeAnimationFactor` @ 0x379C2B4.</summary>
    public void SetExternalEyeAnimationFactor(float factor)
    {
        external_eye_anime_factor = factor;
    }

    /// <summary>Native `SetTeary(bool, int, float)` @ 0x379D768.</summary>
    public void SetTeary(bool sw, int speed, float scale0)
    {
        teary = sw;
        yuragiPhase = 0f;
        yuragiSpeed = speed;
        yuragiScale = scale0;
    }

    /// <summary>Native `SetMaterials(Material eyeR, Material eyeL)` @ 0x379D5A8.</summary>
    public void SetMaterials(Material material_eyeR, Material material_eyeL)
    {
        useEyeMats = true;
        eyeMats = new Material[2];
        eyeMats[0] = material_eyeR;
        eyeMats[1] = material_eyeL;
    }

    /// <summary>Native `SetMaterial(Material eye)` @ 0x379D6AC.</summary>
    public void SetMaterial(Material material_eye)
    {
        useEyeMats = true;
        eyeMats = new Material[1];
        eyeMats[0] = material_eye;
    }

    /// <summary>
    /// Native `GetCamTgtPos` @ 0x379D1BC. Returns the current dance camera's
    /// look-at position, or `LiveInfoParams.upCamTgtPosDef` when the camera
    /// manager is not available (native default read at +0xC).
    /// </summary>
    public Vector3 GetCamTgtPos()
    {
        if (camTgtPosProvider != null) return camTgtPosProvider(camNo);
        return upCamTgtPosDef;
    }

    /// <summary>
    /// Native `EyeUpdate` @ 0x379C2BC. Call from LateUpdate by the binder (the
    /// native component has no Update of its own; JointBodyHead/CharacterDrawer
    /// drives it).
    /// </summary>
    public void EyeUpdate()
    {
        if (!initf) return;
        if (eyeTrackParam == null) eyeTrackParam = new EyeTrackParam();
        if (info == null) return;

        // 0x379C2BC prologue: base = LiveInfoParams.upCamPosDef (v3/v4/v5);
        // if the live manager is valid, base = (model.Eye.position.x, 0, .z).
        Vector3 basePos = upCamPosDef;
        if (liveStageManagerValid && info.eye != null)
        {
            Vector3 eyeWorld = info.eye.transform.position;
            basePos = new Vector3(eyeWorld.x, 0f, eyeWorld.z);
        }

        Vector3 pos = eyeTargetPos;
        float depthSign = frontDepthSign >= 0 ? 1f : -1f;

        switch (type)
        {
            case eyedirtype.Front:
            {
                // base + (0, model.Eye.position.y, sign * frontDepth)
                float eyeY = info.eye != null ? info.eye.transform.position.y : 0f;
                pos = new Vector3(basePos.x, basePos.y + eyeY, basePos.z + depthSign * frontDepth);
                break;
            }
            case eyedirtype.LookCamera:
            {
                pos = GetCamTgtPos();
                break;
            }
            case eyedirtype.LookRFinger:
            {
                if (info.rFinger != null) pos = info.rFinger.transform.position;
                break;
            }
            case eyedirtype.BustDir:
            {
                // model.Mune2.position + Mune2.forward * 100
                // UNKNOWN(0x379C2BC type=3): the decompiler folds
                // Transform.get_forward(0x70BF5A8) into scalars; reconstructed
                // as the Vector3 expression the native code performs.
                if (info.mune2 != null)
                {
                    var t = info.mune2.transform;
                    pos = t.position + t.forward * 100f;
                }
                break;
            }
            case eyedirtype.Fixed:
            {
                // UNKNOWN(0x379C2BC type=4): the disassembly loads
                // model.Eye.position.y twice; one read is used here (a
                // double-count would be a decompiler artifact).
                float eyeY = info.eye != null ? info.eye.transform.position.y : 0f;
                pos = new Vector3(basePos.x + offX, basePos.y + offY + eyeY, basePos.z + depthSign * frontDepth);
                break;
            }
            case eyedirtype.FaceRelative:
            {
                // model.Eye.transform.TransformPoint(-frontDepth, -offX, offY)
                if (info.eye != null)
                    pos = info.eye.transform.TransformPoint(-frontDepth, -offX, offY);
                break;
            }
            case eyedirtype.OtherIdol:
            {
                // UNKNOWN(0x9704BE0): idol array index = tgtIdol - 1,
                // target = other.model.Atama.position.
                if (idolList != null)
                {
                    int i = tgtIdol - 1;
                    if (i >= 0 && i < idolList.Length && idolList[i] != null && idolList[i].atama != null)
                        pos = idolList[i].atama.transform.position;
                }
                break;
            }
            case eyedirtype.FmtFront:
            {
                float eyeY = info.eye != null ? info.eye.transform.position.y : 0f;
                if (info.formationRy == 0f)
                {
                    pos = new Vector3(basePos.x, basePos.y + eyeY, basePos.z + depthSign * frontDepth);
                }
                else
                {
                    Vector3 local = info.rotFmtRy * new Vector3(0f, eyeY, frontDepth);
                    pos = basePos + local;
                }
                break;
            }
            case eyedirtype.CamFix:
            {
                if (!camSampled)
                {
                    pos = GetCamTgtPos();
                    eyeTargetPos = pos;
                    if (eye_base != null)
                    {
                        Vector3 local = eye_base.InverseTransformPoint(eyeTargetPos);
                        if (local.x < 0f)
                        {
                            float k = local.x / -frontDepth;
                            if (k != 0f)
                            {
                                offX = -local.y / k;
                                offY = local.z / k;
                            }
                        }
                    }
                    camSampled = true;
                }
                else
                {
                    // Native LABEL_92: the FaceRelative transform-point path.
                    if (info.eye != null)
                        pos = info.eye.transform.TransformPoint(-frontDepth, -offX, offY);
                }
                break;
            }
            case eyedirtype.LookLFinger:
            {
                if (info.lFinger != null) pos = info.lFinger.transform.position;
                break;
            }
        }

        eyeTargetPos = pos;

        // 0x379C2BC: if (eyeTarget) eyeTarget.position = eyeTargetPos;
        // (Transform.set_position 0x70BEFE0).
        if (eyeTarget != null) eyeTarget.position = eyeTargetPos;

        // direction in eye space; note the native negation of local.x.
        float angleY, angleZ;
        if (eye_base != null)
        {
            Vector3 local = eye_base.InverseTransformPoint(eyeTargetPos);
            angleZ = Mathf.Atan2(local.y, -local.x) * Mathf.Rad2Deg;   // eye_rx
            angleY = Mathf.Atan2(local.z, -local.x) * Mathf.Rad2Deg;   // eye_ry
        }
        else
        {
            angleZ = 0f;
            angleY = 0f;
        }

        // Clamp: rx to [LimRight, LimLeft], ry to [LimDown, LimUp]
        // (0x379C2BC lines around LABEL_119..LABEL_131).
        eye_rx = angleZ;
        eye_ry = angleY;
        if (eye_rx >= eyeTrackParam.EyeDirLimRight)
        {
            if (eye_rx > eyeTrackParam.EyeDirLimLeft) eye_rx = eyeTrackParam.EyeDirLimLeft;
        }
        else
        {
            eye_rx = eyeTrackParam.EyeDirLimRight;
        }
        if (eye_ry < eyeTrackParam.EyeDirLimDown) eye_ry = eyeTrackParam.EyeDirLimDown;
        else if (eye_ry > eyeTrackParam.EyeDirLimUp) eye_ry = eyeTrackParam.EyeDirLimUp;

        if (forcedGaze)
        {
            // rate -1..1 -> the authored eye limits (EyeDirLimLeft/Right = ±30,
            // EyeDirLimUp/Down = +10/-10).
            eye_rx = Mathf.Lerp(eyeTrackParam.EyeDirLimRight, eyeTrackParam.EyeDirLimLeft,
                                (forcedGazeH + 1f) * 0.5f);
            eye_ry = Mathf.Lerp(eyeTrackParam.EyeDirLimDown, eyeTrackParam.EyeDirLimUp,
                                (forcedGazeV + 1f) * 0.5f);
        }

        if (!on)
        {
            // 0x379C2BC LABEL_132: park the scrolling slots.
            if (useEyeMats)
            {
                if (eyeMats != null)
                {
                    for (int i = 0; i < eyeMats.Length; i++)
                    {
                        var m = eyeMats[i];
                        if (m == null) continue;
                        SetMainTextureOffset(m, appmasVectorR);
                        SetTextureOffset(m, id_SubTex, appmasVectorR);
                    }
                }
            }
            else
            {
                var mats = rendEye != null ? rendEye.sharedMaterials : null;
                if (mats != null)
                {
                    for (int i = 0; i < mats.Length && i < 2; i++)
                    {
                        var m = mats[i];
                        if (m == null) continue;
                        SetMainTextureOffset(m, Vector2.zero);
                        SetTextureOffset(m, id_SubTex, Vector2.zero);
                    }
                }
            }
            return;
        }

        // --- 0x379C2BC on==true branch: yuragi + texture scrolling ---
        float yuragi = 0f;
        if (teary)
        {
            float rate = yuragiSpeed * 60f / 255f;
            if (external_eye_anime_factor >= 0f)
                yuragiPhase = Frac(external_eye_anime_factor * rate);
            else
                yuragiPhase = Frac(yuragiPhase + external_eye_anime_factor * rate);
            yuragi = yuragiScale * 0.02f * Mathf.Sin(yuragiPhase * 2f * Mathf.PI);
        }

        Vector2 eyeOff = new Vector2(-eye_rx * eyeTrackParam.EyeDirScale,
                                     -eye_ry * eyeTrackParam.EyeDirScale);

        // UNKNOWN(native 0x379C2BC): the vfx phase accumulator reads
        // UnityEngine.Time.get_deltaTime (0x70B9BAC) but the reconstructed
        // expression does not multiply it; the port keeps the literal
        // per-frame expression observed in the decompile.
        float phaseInput = external_eye_anime_factor >= 0f
            ? external_eye_anime_factor * vfx_uv_speed
            : vfx_anime_phase + external_eye_anime_factor * vfx_uv_speed;
        vfx_anime_phase = Frac(phaseInput);
        float vfxScale = Mathf.Sin(vfx_anime_phase * 2f * Mathf.PI) * vfx_uv_range + vfx_uv_base;

        Vector2 subOff = new Vector2(yuragi + eyeOff.x, yuragi + eyeOff.y);

        if (useEyeMats)
        {
            Vector2 scaleMats = new Vector2(screenRatioV.x * scale, screenRatioV.y * scale);
            if (eyeMats != null)
            {
                for (int i = 0; i < eyeMats.Length; i++)
                {
                    var m = eyeMats[i];
                    if (m == null) continue;
                    SetMainTextureOffset(m, eyeOff);
                    SetTextureOffset(m, id_SubTex, subOff);
                    SetMainTextureScale(m, scaleMats);
                    SetTextureScale(m, id_SubTex, scaleMats);
                    SetTextureOffset(m, id_VfxTex, eyeOff);
                    SetTextureScale(m, id_VfxTex, new Vector2(vfxScale * screenRatioV.x, vfxScale * screenRatioV.y));
                }
            }
            return;
        }

        var shared = rendEye != null ? rendEye.sharedMaterials : null;
        if (shared == null) return;
        for (int i = 0; i < shared.Length && i < 2; i++)
        {
            var m = shared[i];
            if (m == null) continue;
            SetMainTextureOffset(m, eyeOff);
            SetTextureOffset(m, id_SubTex, subOff);
            SetMainTextureScale(m, new Vector2(scale, scale));
            SetTextureScale(m, id_SubTex, new Vector2(scale, scale));
            SetTextureOffset(m, id_VfxTex, eyeOff);
            SetTextureScale(m, id_VfxTex, new Vector2(vfxScale * screenRatioV.x, vfxScale * screenRatioV.y));
        }
    }

    private static float Frac(float v)
    {
        return v - (float)System.Math.Truncate(v);
    }

    // Unity's Material.mainTextureOffset/mainTextureScale setters resolve the
    // main-texture property id internally (native 0x7070308/0x7070454 do the
    // same through Material::GetTexturePropertyNameIDs + MainTexture fallback).
    private static void SetMainTextureOffset(Material m, Vector2 v) { m.mainTextureOffset = v; }
    private static void SetMainTextureScale(Material m, Vector2 v) { m.mainTextureScale = v; }

    // Native Material.SetTextureOffset/SetTextureScale(int, Vector2)
    // (0x7070398/0x70704E4). HasProperty guard: the shipped eye materials have
    // `_SubTex` but no `_VfxTex` (facts §B.1), so the VFX slot is a documented
    // no-op until that texture exists — the native Material call is a no-op for
    // a missing property as well, this only keeps the console clean.
    private static void SetTextureOffset(Material m, int id, Vector2 v)
    {
        if (id != 0 && m.HasProperty(id)) m.SetTextureOffset(id, v);
    }

    private static void SetTextureScale(Material m, int id, Vector2 v)
    {
        if (id != 0 && m.HasProperty(id)) m.SetTextureScale(id, v);
    }
}
