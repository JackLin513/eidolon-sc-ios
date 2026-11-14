using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEngine;

/// Builds the game's own character from its asset bundles and drives the
/// native-faithful presentation stack (ADR-0033):
///   CalcBone (8 assist-bone algorithms) -> native FaceCtrl -> merged Sway rig
///   -> JointBodyHead/CharacterDrawer/CharacterSoul -> EyeTracking+DropShadow
///   -> CharacterImasMotionPlayerDance (raw imo, continuous time).
/// The legacy 30 fps EULR clip path was removed together with the old
/// SwayPhysics/HelperBones approximations.
public sealed class CharacterBootstrap : MonoBehaviour
{
    [Tooltip("Directory holding cb_/ch_ .unity3d, normally $MLTD_WORK/bundles")]
    public string bundleDirectory = WorkDirectory("bundles");
    public string bodyBundle = "cb_ss001_001har.unity3d";
    public string headBundle = "ch_ss001_001har.unity3d";
    /// The face expression table, exported from the game's `facial_chara`
    /// ScriptableObject (`FaceScrObj.charaParams`).
    public string facialParamsPath = WorkDirectory("out/facial_chara.json");
    [Tooltip("ADR-0033 B1: raw imo JSON directory ($MLTD_WORK/motion)")]
    public string motionDirectory = WorkDirectory("motion");
    public string imoFile = "dan_loveig_01_dan.imo.imo.json";
    public string optionalImoFile = "";
    [Tooltip("ADR-0033 B5: chara_soul.unity3d from the version-pinned snapshot; empty disables CharacterSoul")]
    public string characterSoulBundle = WorkDirectory("assets/1078590/files/03761aa835dd0147e7134e554eb54a0e2c40d132.unity3d");
    [Tooltip("ADR-0033 B4: chara_shadow.unity3d from the version-pinned snapshot; empty disables DropShadow")]
    public string shadowBundlePath = WorkDirectory("assets/1078590/files/9022af9ed73bd949dcabb6c3dc4c5a76e6ccc083.unity3d");
    public float speed = 1f;
    /// <summary>The app's stand host plays its own flat motions; skip the imo dance driver.</summary>
    public bool buildMotion = true;
    /// <summary>The editor probe camera controller is meaningless on the device.</summary>
    public bool buildCameraOrbit = true;

    private NativeMotionDriver motion;
    private SwayRigNative swayRig;
    private FaceCtrlNative faceCtrl;
    private GameObject bodyObject;
    private GameObject headObject;

    /// Derived data lives outside the repo (see docs handoff §5): $MLTD_WORK,
    /// defaulting to ~/mltd-work. Keeping `/tmp` out of the defaults means a
    /// fresh scene still points at a directory that survives a reboot.
    private static string WorkDirectory(string relative)
    {
        var root = Environment.GetEnvironmentVariable("MLTD_WORK");
        if (string.IsNullOrEmpty(root))
            root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "mltd-work");
        return Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
    }

    private bool _rebuilding;

    /// Editor-workflow self-heal: a play-mode domain reload (auto-refresh on
    /// focus change) wipes the runtime-built sway/calc/face state while the
    /// scene objects survive. Detect the dead state and rebuild from the
    /// serialized bundle paths. Native has no hot reload.
    private void Update()
    {
        var calc = GetComponent<CalcBoneNative>();
        var deadSway = swayRig == null || swayRig.bones.Count == 0;
        var deadCalc = calc == null || calc.Count == 0;
        if (!_rebuilding && (deadSway || deadCalc))
        {
            _rebuilding = true;
            Debug.LogWarning("[self-heal] sway/calc state wiped by domain reload — rebuilding");
            var calc0 = GetComponent<CalcBoneNative>();
            if (calc0 != null) calc0.Bind(transform);
            swayRig = null;
            BindNativeSway();
            _rebuilding = false;
        }
    }

    private void Start()
    {
        ApplyGlobals();
        if (!BuildCharacter()) return;
        FixOutlineDepth();

        // CalcBoneNative.Awake captures the bind pose (native CalcBone.Awake
        // 0x1C5F624); it must run before any clip/pose is applied.
        gameObject.AddComponent<CalcBoneNative>();

        Frame();

        // B3: native FaceCtrl; SetFaceDirect(0,0) because native SetFace(0) is a
        // no-op while cur == 0.
        faceCtrl = gameObject.AddComponent<FaceCtrlNative>();
        faceCtrl.Bind(transform);
        if (File.Exists(facialParamsPath))
        {
            faceCtrl.LoadJson(File.ReadAllText(facialParamsPath), CharacterId());
            // B3 data-gap closed: lipParam (float[11,14]) recovered from the
            // compiler static-array blob in global-metadata.dat @0x115FE40
            // (dump.cs <PrivateImplementationDetails>.__StaticArrayInitTypeSize
            // =616). Values are 0..100 and the native UpdateFace 0x379E94C lip
            // path does NOT rescale them (its only *0.01f is the eye scale), so
            // pass the raw table; see FaceLipParamNative and
            // $MLTD_WORK/out/face_lip_param.json.
            faceCtrl.LoadLipParam(FaceLipParamNative.Table);
            faceCtrl.SetFaceDirect(0, 0);
        }

        BindNativeSway();
        BindNativeB5();
        BindNativeB4();
        if (buildMotion) BindNativeMotion();
    }

    /// <summary>The assembled native face, for the app's stand host.</summary>
    public FaceCtrlNative FaceCtrl => faceCtrl;

    /// <summary>The assembled sway rig, for probes.</summary>
    public SwayRigNative SwayRig => swayRig;

    // ------------------------------------------------------------------
    // Sw (B2)
    // ------------------------------------------------------------------

    /// Each bundle ships its own `<character>_sway`: the body one carries the
    /// skirt, the bows and the chest bones, the head one the 17 hair strands.
    /// Native SwayFileIO.ImportCommon 0x1C764FC merges both onto one model.
    private void BindNativeSway()
    {
        var bodyText = LoadSwayText(bodyBundle);
        var headText = LoadSwayText(headBundle);
        Debug.Log($"[sway-diag] bodyText={(bodyText==null?"null":bodyText.Length.ToString())} headText={(headText==null?"null":headText.Length.ToString())}");
        if (bodyText == null) return;
        var bodyFile = SwayFileNative.Parse(bodyText);
        Debug.Log($"[sway-diag] parse: bodyFile={(bodyFile!=null)} mgr={(bodyFile!=null&&bodyFile.managers!=null?bodyFile.managers.Count:-1)} bones={(bodyFile!=null&&bodyFile.bones!=null?bodyFile.bones.Count:-1)}");
        swayRig = SwayRigNative.Build(
            transform,
            bodyFile,
            headText == null ? null : SwayFileNative.Parse(headText));
        Debug.Log($"[sway-diag] built: bones={swayRig.bones.Count} managers={swayRig.managers.Count} bodyFile={(swayRig.bodyFile!=null)}");
    }

    private string LoadSwayText(string bundleName)
    {
        if (string.IsNullOrEmpty(bundleName)) return null;
        var bundle = LoadBundle(bundleName);
        if (bundle == null) return null;
        var asset = bundle.LoadAllAssets<TextAsset>().FirstOrDefault(a => a.name.EndsWith("_sway"));
        return asset == null ? null : asset.text;
    }

    // ------------------------------------------------------------------
    // JointBodyHead / CharacterDrawer / CharacterSoul (B5, partial)
    // ------------------------------------------------------------------

    private void BindNativeB5()
    {
        var jbh = gameObject.AddComponent<JointBodyHeadNative>();
        if (bodyObject != null && headObject != null)
        {
            // The native entry point takes the loaded body/head roots and resolves
            // MODEL_00/BASE/ATAMA/KUBI/MUNE2/eyes under them (0x1C633CC). Without
            // this call JointBodyHead's body/head stay null and RunPostInitialize
            // reports "unresolved".
            jbh.Initialize(bodyObject, headObject, CharacterId());
        }
        if (swayRig != null) jbh.BindSwayRig(swayRig);
        var assembly = new JointBodyHeadAssemblyNative(jbh);
        assembly.RunPostInitialize();

        var drawer = gameObject.AddComponent<CharacterDrawerNative>();
        drawer.Create(0, gameObject, CharacterId(), jbh);
        if (faceCtrl != null) faceCtrl.SetCharacterDrawer(drawer);

        if (string.IsNullOrEmpty(characterSoulBundle) || !File.Exists(characterSoulBundle)) return;
        if (!SoulCache.TryGetValue(characterSoulBundle, out var table))
        {
            table = Imas.CharacterSoulTable.Load(characterSoulBundle, out var loadError);
            if (table != null) SoulCache[characterSoulBundle] = table;
            else Debug.LogWarning("Eidolon: CharacterSoul load failed: " + loadError);
        }
        if (table != null && table.TryGet(CharacterId(), out var soul))
        {
            if (faceCtrl != null && soul.cheekReddenIntensity.isValid)
                faceCtrl.cheekBaseIntensity = soul.cheekReddenIntensity.value;
            // TODO(B5): cheekReddenColor -> drawer material, bodyScale/breast sway
            // -> JBH runtime arrays; see CharacterSoulNative and migration-progress.
        }
        else
        {
            Debug.LogWarning("Eidolon: CharacterSoul load failed: " + characterSoulBundle);
        }
    }

    // ------------------------------------------------------------------
    // EyeTracking + DropShadow (B4)
    // ------------------------------------------------------------------

    private void BindNativeB4()
    {
        SkinnedMeshRenderer eyes = null;
        foreach (var r in GetComponentsInChildren<SkinnedMeshRenderer>(true))
            if (r.name == "eyes") eyes = r;

        if (eyes != null)
        {
            // Native JointBodyHead.Initialize passes DanceIdolInfo / the model's
            // Eye/Atama/Mune2/fingers. The `Front` eye direction needs
            // `info.eye.position.y`: with a null info the native code reads 0 and
            // the target drops below the eye, slams into the clamp and flips
            // +-180 degrees whenever the head crosses the plane (the reported
            // "flash" jump). Feed the real nodes instead of inventing offsets.
            var bodyHolder = transform.Find("MODEL_00_holder");
            var model = bodyHolder != null ? bodyHolder.Find("MODEL_00") : null;
            var atama = model != null ? model.Find("BASE/MUNE1/MUNE2/KUBI/ATAMA") : null;
            var mune2 = model != null ? model.Find("BASE/MUNE1/MUNE2") : null;
            var eyeInfo = new EyeTrackingIdolInfo
            {
                body = bodyHolder != null ? bodyHolder.gameObject : gameObject,
                atama = atama != null ? atama.gameObject : null,
                mune2 = mune2 != null ? mune2.gameObject : null,
                eye = eyes.gameObject,
            };
            var tracking = eyes.gameObject.AddComponent<EyeTracking>();
            EyeTracking.RefreshScreenRatio();
            tracking.Init(eyeInfo);
            // Viewer mode: the spike has no LiveInfo/DanceCameraManager stage
            // data, so native `Front` (stage-forward target) is undefined here
            // and flips +-180 when the head crosses the target plane. Use the
            // native FaceRelative type: its target is a point in front of the
            // eye in eye space (local x == -frontDepth), so the gaze is stable
            // and never crosses the atan2 plane. Native selects the eye type
            // from DanceIdolInfo; this is the viewer analogue, not a formula
            // change (type enum and math come from EyeUpdate 0x379C2BC).
            tracking.SetTarget(eyedirtype.FaceRelative, 0f, 0f, 0, 0);
            // Native AppmasVector.screenRatio() is a screen-space UV ratio for the
            // eye pass; at the 1280x720 reference it is (1,1). The spike samples
            // the authored iris/highlight atlas directly, so an arbitrary Game
            // view aspect would scale the atlas outside the iris (black eyes).
            // Pin the reference ratio; EyeUpdate's formula is unchanged.
            EyeTracking.screenRatioV = Vector2.one;
            EyeTracking.appmasVectorR = Vector2.zero;
            var mats = eyes.sharedMaterials;
            if (mats != null && mats.Length >= 2 && mats[0] != null && mats[1] != null)
                tracking.SetMaterials(mats[0], mats[1]);
            if (faceCtrl != null) faceCtrl.SetEyeTarget(new EyeScaleSink { target = tracking });
            var eyeDriver = gameObject.AddComponent<EyeTrackingDriver>();
            eyeDriver.Bind(tracking);
        }

        if (string.IsNullOrEmpty(shadowBundlePath) || !File.Exists(shadowBundlePath)) return;
        var path = shadowBundlePath;
        if (!BundleCache.TryGetValue(path, out var bundle) || bundle == null)
        {
            bundle = AssetBundle.LoadFromFile(path);
            if (bundle != null) BundleCache[path] = bundle;
        }
        if (bundle == null)
        {
            Debug.LogWarning("Eidolon: chara_shadow bundle failed to load: " + shadowBundlePath);
            return;
        }
        var dropShadow = gameObject.AddComponent<DropShadow>();
        dropShadow.SetShadowMode(DropShadow.Shadow.CIRCLE, bundle);
    }

    private sealed class EyeScaleSink : FaceCtrlNative.IEyeTargetScaleSink
    {
        public EyeTracking target;
        public float scale
        {
            get => target != null ? target.scale : 1f;
            set { if (target != null) target.scale = value; }
        }
    }

    // ------------------------------------------------------------------
    // Motion (B1)
    // ------------------------------------------------------------------

    private void BindNativeMotion()
    {
        var path = Path.Combine(motionDirectory, imoFile);
        if (!File.Exists(path))
        {
            Debug.LogWarning($"Eidolon: native motion not found: {path}");
            return;
        }
        motion = gameObject.AddComponent<NativeMotionDriver>();
        motion.motionDirectory = motionDirectory;
        motion.imoFile = imoFile;
        motion.optionalImoFile = optionalImoFile ?? "";
        motion.playOnStart = true;
        motion.loop = true;
        motion.speed = speed;
        var posNode = transform.Find("POSITION");
        if (posNode != null) motion.positionTarget = posNode;
        var display = gameObject.AddComponent<MotionTimeDisplay>();
        display.motion = motion;
        display.rig = GetComponent<SwayRigNative>();
    }

    // ------------------------------------------------------------------
    // Compatibility shims for the editor probes (they used the packed clip)
    // ------------------------------------------------------------------

    public NativeMotionDriver Motion => motion;

    public int ClipFrames => motion != null && motion.Data != null
        ? Mathf.RoundToInt(motion.Data.length * 30f) : 0;

    public ClipView Clip
    {
        get
        {
            var view = new ClipView { Frames = ClipFrames };
            if (motion != null && motion.Data != null)
            {
                foreach (var set in motion.Data.curve_sets)
                    view.Tracks.Add(new ClipTrackView { Path = set.path });
            }
            return view;
        }
    }

    /// Seeks to a frame of the 30 fps authoring grid used by the probes.
    public void Seek(int frame)
    {
        if (motion == null) return;
        motion.paused = true;
        motion.Seek(frame / 30f);
    }

    public sealed class ClipTrackView
    {
        public string Path;
    }

    public sealed class ClipView
    {
        public int Frames;
        public readonly List<ClipTrackView> Tracks = new List<ClipTrackView>();
    }

    // ------------------------------------------------------------------
    // Assembly / globals / camera (unchanged from the spike)
    // ------------------------------------------------------------------

    /// The game sets these once (and on scene changes); at their zero default
    /// the character shaders multiply the whole figure to black.
    private static void ApplyGlobals()
    {
        // Editor hitching (probe evals, script compiles) otherwise lets the
        // motion time jump forward by up to 0.33 s in one visible flash. The
        // game clamps its own catch-up far tighter.
        Time.maximumDeltaTime = 0.1f;
        Shader.SetGlobalVector("_GuradeParams", new Vector4(0, 1, 0, 1));
        Shader.SetGlobalVector("_FadeColV", Vector4.one);
        Shader.SetGlobalVector("_TheaterColV", Vector4.one);
        Shader.SetGlobalVector("_MonoColor", Vector4.one);
        Shader.SetGlobalVector("_RimCtrl", Vector4.zero);
        Shader.SetGlobalFloat("_Whiteness", 0);
        Shader.SetGlobalFloat("_Luminance", 1);
        Shader.SetGlobalInt("_FogMode", 0);
        Shader.SetGlobalInt("_IsLive", 0);
    }

    private bool BuildCharacter()
    {
        var body = LoadBundle(bodyBundle);
        var head = LoadBundle(headBundle);
        if (body == null || head == null)
        {
            Debug.LogError($"Eidolon: bundles missing in {bundleDirectory}");
            return false;
        }
        var bodyPrefab = body.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("cb_"));
        var headPrefab = head.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("ch_"));
        // Dance imos carry a POSITION track (stage placement). Native mounts the
        // model under a POSITION node that the motion player drives; without it
        // the track is skipped and the model stays at the origin (the notes in
        // motion-native's delivery). Create it here, before anything binds.
        var positionNode = new GameObject("POSITION");
        positionNode.transform.SetParent(transform, false);
        var bodyInstance = Instantiate(bodyPrefab, positionNode.transform);
        bodyInstance.name = "MODEL_00_holder";
        bodyObject = bodyInstance;
        var headInstance = Instantiate(headPrefab, transform);
        headInstance.name = "ch_head";
        headObject = headInstance;
        var model = bodyInstance.transform.Find("MODEL_00") ?? bodyInstance.transform;
        var atama = model.Find("BASE/MUNE1/MUNE2/KUBI/ATAMA");
        headInstance.transform.SetParent(atama != null ? atama : model, true);
        return true;
    }

    /// The character shaders draw their outline as an extruded hull parked
    /// behind the surface with `_ZShift1000*`; the shipped values assume the
    /// game camera. Kept until the native depth/outline draw path moves (B5
    /// out-of-scope), see migration-progress.
    private void FixOutlineDepth()
    {
        var body = GetComponentsInChildren<SkinnedMeshRenderer>(true)
            .FirstOrDefault(r => r.name == "body");
        if (body == null) return;
        foreach (var material in body.sharedMaterials)
        {
            if (material == null || !material.HasProperty("_ZShift1000Max")) continue;
            material.SetFloat("_ZShift1000Min", 0.2f);
            material.SetFloat("_ZShift1000Max", 2f);
        }
    }

    /// An AssetBundle cannot be loaded twice in one process; the app reloads the
    /// same outfit for every call, so keep one cache by absolute path (edit-time
    /// probes may also already hold these).
    private static readonly Dictionary<string, AssetBundle> BundleCache = new Dictionary<string, AssetBundle>();
    private static readonly Dictionary<string, Imas.CharacterSoulTable> SoulCache = new Dictionary<string, Imas.CharacterSoulTable>();

    private AssetBundle LoadBundle(string file)
    {
        var path = Path.Combine(bundleDirectory, file);
        if (BundleCache.TryGetValue(path, out var cached) && cached != null) return cached;
        foreach (var loaded in AssetBundle.GetAllLoadedAssetBundles())
            if (loaded.name == file) { BundleCache[path] = loaded; return loaded; }
        var bundle = AssetBundle.LoadFromFile(path);
        if (bundle != null) BundleCache[path] = bundle;
        return bundle;
    }

    /// `pr001_001har` -> `001har`: the id the face/soul tables are keyed by.
    private string CharacterId()
    {
        var name = bodyBundle.Replace(".unity3d", "");
        var parts = name.Split('_');
        return parts.Length >= 3 ? parts[parts.Length - 1] : name;
    }

    private void Frame()
    {
        var camera = Camera.main;
        if (camera == null)
        {
            var go = new GameObject("Main Camera");
            go.tag = "MainCamera";
            camera = go.AddComponent<Camera>();
        }
        camera.transform.position = new Vector3(0, 1.0f, 2.6f);
        camera.transform.LookAt(new Vector3(0, 0.95f, 0));
        camera.fieldOfView = 30;
        if (buildCameraOrbit && camera.GetComponent<OrbitCamera>() == null) camera.gameObject.AddComponent<OrbitCamera>();
        if (FindObjectOfType<Light>() == null)
        {
            var light = new GameObject("Directional Light").AddComponent<Light>();
            light.type = LightType.Directional;
            light.transform.rotation = Quaternion.Euler(35, -35, 0);
        }
    }
}
