using System.Globalization;
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEngine;

/// <summary>
/// The Unity side of the app's 3D stand (ADR-0034): one scene, one character, a
/// tiny string message face for Swift.
///
/// Swift sends <c>LoadCharacter</c> with a small JSON request, then drives the
/// emotion / speaking / blink / nod state with the other methods (all reachable
/// through <c>UnityFramework.sendMessageToGO</c>). Everything the character needs
/// comes from the app's content directory: the game's own costume bundles, the
/// decoded expression table, the soul/shadow bundles and the flat motion files
/// written by <c>tools/fetch_unity3d_content.py</c>.
/// </summary>
public sealed class EidolonStandHost : MonoBehaviour
{
    [Serializable]
    private sealed class LoadRequest
    {
        public string contentRoot;
        public string character;
        public string outfit;
    }

    public static EidolonStandHost Instance { get; private set; }

    private CharacterBootstrap bootstrap;
    private EidolonStandMotion motion;
    private EidolonStandFace face;
    private Camera camera;
    private string contentRoot;
    private string character;
    private string outfit;
    private bool paused;
    private bool loading;
    private string framing = "knees";
    // Measured once from the neutral idle. Framing must not follow the animated pose:
    // recomputing it per presentation zoomed the camera in whenever the story script
    // asked for a leaning or crouching cut.
    private Bounds? framingBounds;
    private Transform characterRoot;
    private GameObject backgroundQuad;
    private Material backgroundMaterial;
    private Texture2D backgroundTexture;
    private string backgroundPath;
    private Vector3 baseOffset;
    private float cameraDistanceFactor = 1f;
    private Coroutine rotationRoutine;
    private Coroutine inOutRoutine;

    private void Awake()
    {
        Instance = this;
        Application.targetFrameRate = 30;
        Screen.sleepTimeout = SleepTimeout.NeverSleep;
        camera = Camera.main;
        if (camera == null)
        {
            var go = new GameObject("Main Camera");
            go.tag = "MainCamera";
            camera = go.AddComponent<Camera>();
        }
        camera.clearFlags = CameraClearFlags.SolidColor;
        camera.backgroundColor = new Color(0.09f, 0.09f, 0.11f, 0f);
        camera.fieldOfView = 30f;
        Debug.Log("[stand] host awake");
    }

    // ------------------------------------------------------------------
    // Messages from Swift
    // ------------------------------------------------------------------

    /// <summary>Load one character in one outfit. Replaces whatever was shown.</summary>
    public void LoadCharacter(string json)
    {
        LoadRequest request;
        try
        {
            request = JsonUtility.FromJson<LoadRequest>(json);
        }
        catch (Exception error)
        {
            EmitFailure("bad request: " + error.Message);
            return;
        }
        if (request == null || string.IsNullOrEmpty(request.contentRoot) || string.IsNullOrEmpty(request.character))
        {
            EmitFailure("request needs contentRoot and character");
            return;
        }
        if (loading) return;
        loading = true;
        contentRoot = request.contentRoot;
        character = request.character;
        outfit = string.IsNullOrEmpty(request.outfit) ? "pr001" : request.outfit;
        StartCoroutine(LoadRoutine(contentRoot, character, outfit));
    }

    /// <summary>Expression + cheek, already resolved by Swift's emotion table: "5,0".</summary>
    public void SetEmotion(string value)
    {
        if (face == null || string.IsNullOrEmpty(value)) return;
        var parts = value.Split(',');
        var facial = 0;
        var cheek = 0;
        if (parts.Length > 0) int.TryParse(parts[0], out facial);
        if (parts.Length > 1) int.TryParse(parts[1], out cheek);
        Debug.Log($"[stand] emotion face={facial} cheek={cheek}");
        face.ApplyExpression(facial, cheek);
    }

    public void SetSpeaking(string value)
    {
        face?.SetSpeaking(value == "1" || value == "true");
    }

    public void SetNod(string value)
    {
        if (value == "no" || value == "noo") motion?.PlayGesture("noo");
        else motion?.PlayGesture("yes");
    }

    /// <summary>
    /// Play one daily action from the package's ``motions/catalog.json``
    /// (``act/swt/yes/noo/str/lop/end``). One-shot clips cross-fade over the idle loop;
    /// unknown names are ignored so a newer client cannot break an older bundle.
    /// </summary>
    public void PlayAction(string value)
    {
        if (motion == null || string.IsNullOrEmpty(value)) return;
        switch (value)
        {
            case "act":
            case "swt":
            case "yes":
            case "noo":
            case "str":
            case "lop":
            case "end":
                Debug.Log($"[stand] action {value}");
                motion.PlayGesture(value);
                break;
            default:
                Debug.Log($"[stand] unknown action {value}");
                break;
        }
    }

    /// <summary>
    /// Switch the idle loop to a story pose clip (``stories/motions/<clip>.tsv``).
    /// The story theatre drives this from the script's 60 fps frame numbers, so the
    /// character performs the pose the scene actually asks for instead of playing
    /// one looping action.
    /// </summary>
    public void PlayPose(string value)
    {
        if (motion == null || string.IsNullOrEmpty(value)) return;
        // `"<path>|<0|1>"`: the flag is the ADV pose type (loopDirect) we recovered
        // from `ADVPoseLogic.Execute` (see the motion reverse-engineering note).
        // `"<path>|<0|1>[|<str|swt|act>]"`: the flag is the ADV pose type
        // (loopDirect) from `ADVPoseLogic.Execute`, the optional third field names the
        // authored clip that walks into the pose (switch poses enter through `_swt`).
        var path = value;
        var loopDirect = false;
        string enter = null;
        var parts = value.Split('|');
        if (parts.Length >= 2)
        {
            path = parts[0];
            loopDirect = parts[1].Trim() == "1";
        }
        if (parts.Length >= 3 && parts[2].Trim().Length > 0) enter = parts[2].Trim();
        motion.PlayPose(path, loopDirect, enter);
    }

    /// <summary>Return to the character's own idle loop once the story ends.</summary>
    /// `<path>`: stand in this clip as the idle loop (the game's own `p01` pose).
    public void SetIdleClip(string value)
    {
        motion?.SetIdleClip(value);
    }

    public void ResetPose(string value)
    {
        motion?.ResetPose();
    }

    /// <summary>Story `actor_facial`: native facialMenu row 0..27.</summary>
    public void SetFacialMenu(string value)
    {
        if (face == null) return;
        if (!int.TryParse(value, out var index)) return;
        face.SetFacialMenu(index);
    }

    /// <summary>Story cheek overlay: 0 off, 1 light, 2 strong.</summary>
    /// <summary>
    /// Authored story mouth envelope: `"&lt;fps&gt;:v0,v1,…"` resampled by the packer;
    /// empty stops it. See `EidolonStandFace.SetLipEnvelope`.
    /// </summary>
    public void SetLipEnvelope(string value)
    {
        face?.SetLipEnvelope(value);
    }

    public void SetCheek(string value)
    {
        if (face == null) return;
        int.TryParse(value, out var level);
        face.SetCheek(level);
    }

    /// <summary>Story `actor_eye_direction`: `"h,v"` in -100…100.</summary>
    public void SetGaze(string value)
    {
        if (face == null) return;
        var separator = value.IndexOf(',');
        if (separator <= 0) return;
        if (!int.TryParse(value.Substring(0, separator), out var h)) return;
        if (!int.TryParse(value.Substring(separator + 1), out var v)) return;
        face.SetGaze(h, v);
    }

    /// <summary>Story `actor_eye_blink`: close / open / blink (CharacterEyeMode).</summary>
    public void SetEyeMode(string value)
    {
        face?.SetEyeMode(value);
    }

    public void SetFraming(string value)
    {
        framing = value == "full" || value == "waist" ? value : "knees";
        FrameCamera(framing);
    }

    /// <summary>Stop advancing the clock while the app is not showing the stand.</summary>
    public void SetPaused(string value)
    {
        paused = value == "1" || value == "true";
        Time.timeScale = paused ? 0f : 1f;
    }

    // ------------------------------------------------------------------
    // Assembly
    // ------------------------------------------------------------------

    private IEnumerator LoadRoutine(string root, string characterId, string outfitId)
    {
        DestroyCharacter();
        yield return null;

        var modelDir = Path.Combine(root, "models", characterId, outfitId);
        var bodyBundle = $"cb_{outfitId}_{characterId}.unity3d";
        var headBundle = $"ch_{outfitId}_{characterId}.unity3d";
        if (!File.Exists(Path.Combine(modelDir, headBundle)))
            headBundle = $"ch_pr001_{characterId}.unity3d";

        var go = new GameObject("Character");
        go.SetActive(false);
        bootstrap = go.AddComponent<CharacterBootstrap>();
        bootstrap.bundleDirectory = modelDir;
        bootstrap.bodyBundle = bodyBundle;
        bootstrap.headBundle = headBundle;
        bootstrap.facialParamsPath = Path.Combine(root, "shared", "facial_chara.json");
        bootstrap.characterSoulBundle = Path.Combine(root, "shared", "chara_soul.unity3d");
        bootstrap.shadowBundlePath = Path.Combine(root, "shared", "chara_shadow.unity3d");
        bootstrap.buildMotion = false;
        bootstrap.buildCameraOrbit = false;
        go.SetActive(true);

        // CharacterBootstrap.Start runs on the first frame after activation; wait
        // for its native state to exist before attaching our motion/face drivers.
        for (var frame = 0; frame < 120 && bootstrap != null && bootstrap.FaceCtrl == null; frame++)
            yield return null;
        if (bootstrap == null || bootstrap.FaceCtrl == null)
        {
            loading = false;
            EmitFailure("character did not assemble");
            yield break;
        }

        characterRoot = go.transform;
        InsertBodyScale(go.transform);
        ApplyMaterialFixes(go.transform);
        // No colour overrides here on purpose: the shipped materials already carry the
        // game's authored values (`_Color`/`_IllumiColor` are the neutral 0.5 the shader
        // multiplies by two, `_AmbientColor` differs per material). Scaling them is what
        // turned the shy face's cheek red into a bruised smear; the look comes from the
        // colour space and the shader's own `_Light` vector.

        motion = go.AddComponent<EidolonStandMotion>();
        motion.Init(go.transform, root, characterId);
        face = go.AddComponent<EidolonStandFace>();
        face.Bind(bootstrap.FaceCtrl);
        EmitLoaded();
        FrameCamera(framing);
        loading = false;
        Debug.Log($"[stand] loaded {characterId}/{outfitId}");
    }

    private void DestroyCharacter()
    {
        if (bootstrap != null) Destroy(bootstrap.gameObject);
        bootstrap = null;
        motion = null;
        face = null;
        framingBounds = null;
    }

    /// <summary>
    /// The game inserts an identity <c>BODY_SCALE</c> node at runtime; every
    /// screen-animation clip binds paths through it (ADR-0033). The bundled prefab
    /// does not carry it, so mirror the insertion before the motion runs.
    /// </summary>
    private static void InsertBodyScale(Transform character)
    {
        var modelRoot = FindDeep(character, "MODEL_00");
        if (modelRoot == null || modelRoot.Find("BODY_SCALE") != null) return;
        var scale = new GameObject("BODY_SCALE").transform;
        scale.SetParent(modelRoot, false);
        var children = new List<Transform>();
        for (var index = 0; index < modelRoot.childCount; index++)
        {
            var child = modelRoot.GetChild(index);
            if (child != scale) children.Add(child);
        }
        foreach (var child in children) child.SetParent(scale, true);
    }

    /// <summary>Outline depth: the shipped `_ZShift1000*` assumes the game camera.</summary>
    private static void ApplyMaterialFixes(Transform character)
    {
        foreach (var renderer in character.GetComponentsInChildren<SkinnedMeshRenderer>(true))
        {
            foreach (var material in renderer.sharedMaterials)
            {
                if (material == null || !material.HasProperty("_ZShift1000Max")) continue;
                material.SetFloat("_ZShift1000Min", 0.2f);
                material.SetFloat("_ZShift1000Max", 2f);
            }
        }
    }

    private static Transform FindDeep(Transform root, string name)
    {
        if (root == null) return null;
        if (root.name == name) return root;
        foreach (var child in root.GetComponentsInChildren<Transform>(true))
            if (child.name == name) return child;
        return null;
    }

    // ------------------------------------------------------------------
    // Camera framing — mirrors EidolonCore's StandFraming math.
    // ------------------------------------------------------------------

    private void FrameCamera(string framing)
    {
        if (camera == null) return;
        if (framingBounds == null)
        {
            // Frame the character's neutral silhouette; a story pose can be much
            // narrower (leaning in) and must not change the shot.
            motion?.SampleIdle(0f);
            if (TryMeasureBounds(out var measured)) framingBounds = measured;
            else return;
        }
        var bounds = framingBounds.Value;

        var aspect = Screen.height > 0 ? (float)Screen.width / Screen.height : 1f;
        var share = framing == "waist" ? 0.66f : framing == "knees" ? 0.85f : 1f;
        // Full-body framing on a full-screen phone: 3% puts her hair right at the top
        // edge (and under the notch), so leave more air above her.
        var headroom = 0.08f;
        float viewHeight;
        if (framing == "full")
        {
            viewHeight = Mathf.Max(bounds.size.y, bounds.size.x / aspect) * (1 + 2 * headroom);
        }
        else
        {
            viewHeight = Mathf.Max(bounds.size.y * share, bounds.size.x * 0.7f / aspect);
        }
        var top = bounds.center.y + bounds.size.y / 2 * (1 + headroom);
        var centerY = framing == "full" ? bounds.center.y : top - viewHeight / 2;
        var distance = viewHeight / (2 * Mathf.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad))
                       * cameraDistanceFactor;
        camera.transform.position = new Vector3(bounds.center.x, centerY, bounds.center.z + distance);
        camera.transform.LookAt(new Vector3(bounds.center.x, centerY, bounds.center.z));
        if (backgroundQuad != null && backgroundQuad.activeSelf) PlaceBackground();
    }

    /// Bounds of the assembled character, restricted to renderers that are actually on.
    private bool TryMeasureBounds(out Bounds bounds)
    {
        bounds = default;
        if (bootstrap == null) return false;
        var renderers = bootstrap.GetComponentsInChildren<Renderer>(true)
            .Where(renderer => renderer.enabled && renderer.gameObject.activeInHierarchy)
            .ToArray();
        if (renderers.Length == 0) return false;
        bounds = renderers[0].bounds;
        foreach (var renderer in renderers) bounds.Encapsulate(renderer.bounds);
        return true;
    }

    /// Probe entry: sample the idle at a fixed time and return one bone's euler.
    public string ProbeIdle(string spec)
    {
        if (motion == null) return "no-motion";
        var parts = spec.Split(',');
        var time = parts.Length > 0 && float.TryParse(parts[0], System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var parsed) ? parsed : 0f;
        motion.SampleIdle(time);
        return parts.Length > 1 ? motion.DebugEuler(parts[1]) : "ok";
    }

    /// <summary>
    /// `actor_camera_set_position_preset`: the ADV camera setups. The game reads the
    /// numbers from its script parameter tables (`solo`/`duo`/`trio`/`solo_sit`/
    /// `live_result`), which are not in the client bundle, so the stand keeps its
    /// measured framing and only shifts the shot distance per preset.
    /// </summary>
    public void SetCameraPreset(string value)
    {
        var preset = value ?? "";
        var factor = 1f;
        switch (preset)
        {
            case "duo": factor = 1.35f; break;
            case "trio": factor = 1.65f; break;
            case "solo_sit": factor = 0.9f; break;
            case "live_result": factor = 1.2f; break;
        }
        if (Mathf.Approximately(factor, cameraDistanceFactor)) return;
        cameraDistanceFactor = factor;
        FrameCamera(framing);
        Debug.Log($"[stand] camera preset {preset} distance x{factor:0.00}");
    }

    /// <summary>
    /// `actor_character_set_position_preset`: only one stand is rendered in this
    /// prototype, so the character stays centred; the preset is logged for the pack
    /// report (`solo` = the single-character layout we already show).
    /// </summary>
    public void SetPlacePreset(string value)
    {
        Debug.Log($"[stand] place preset {value}");
    }

    /// <summary>Show an ADV 2D background behind the character. Empty path hides it.</summary>
    public void SetBackground(string path)
    {
        if (backgroundPath == path) return;
        backgroundPath = path;
        if (string.IsNullOrEmpty(path) || !File.Exists(path))
        {
            if (backgroundQuad != null) backgroundQuad.SetActive(false);
            return;
        }
        try
        {
            if (backgroundTexture == null || backgroundTexture.width < 2)
            {
                backgroundTexture = new Texture2D(2, 2, TextureFormat.RGBA32, false);
            }
            if (!backgroundTexture.LoadImage(File.ReadAllBytes(path)))
            {
                Debug.Log($"[stand] background decode failed: {path}");
                return;
            }
            backgroundTexture.wrapMode = TextureWrapMode.Clamp;
            EnsureBackgroundQuad();
            backgroundMaterial.mainTexture = backgroundTexture;
            backgroundQuad.SetActive(true);
            PlaceBackground();
            Debug.Log($"[stand] background {Path.GetFileName(path)} {backgroundTexture.width}x{backgroundTexture.height}");
        }
        catch (Exception error)
        {
            Debug.Log($"[stand] background failed: {error.Message}");
        }
    }

    private void EnsureBackgroundQuad()
    {
        if (backgroundQuad != null) return;
        backgroundQuad = GameObject.CreatePrimitive(PrimitiveType.Quad);
        backgroundQuad.name = "StoryBackground";
        var collider = backgroundQuad.GetComponent<Collider>();
        if (collider != null) Destroy(collider);
        var shader = Shader.Find("Unlit/Texture");
        backgroundMaterial = new Material(shader);
        backgroundQuad.GetComponent<MeshRenderer>().sharedMaterial = backgroundMaterial;
        backgroundQuad.GetComponent<MeshRenderer>().shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
        backgroundQuad.GetComponent<MeshRenderer>().receiveShadows = false;
    }

    /// <summary>Scale the backdrop to fill the whole view at its fixed depth.</summary>
    private void PlaceBackground()
    {
        if (backgroundQuad == null || camera == null) return;
        var aspect = Screen.height > 0 ? (float)Screen.width / Screen.height : 1f;
        var depth = 24f;
        var height = 2f * depth * Mathf.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad) * 1.06f;
        var width = height * aspect;
        // Square textures are authored 1:1; the game crops them to the screen.
        var tex = backgroundTexture;
        if (tex != null && tex.width > 0 && tex.height > 0)
        {
            var texAspect = (float)tex.width / tex.height;
            if (texAspect > aspect) width = height * texAspect;
            else height = width / texAspect;
        }
        // Parent the backdrop to the camera: it must fill the shot no matter where the
        // framing camera is, and the character can rotate / walk without moving it.
        backgroundQuad.transform.SetParent(camera.transform, false);
        backgroundQuad.transform.localPosition = new Vector3(0f, 0f, depth);
        backgroundQuad.transform.localRotation = Quaternion.identity;
        backgroundQuad.transform.localScale = new Vector3(width, height, 1f);
    }

    /// <summary>Show or hide the assembled character (actor_visible_character).</summary>
    public void SetVisible(string value)
    {
        if (characterRoot == null) return;
        var visible = value == "1" || value == "true" || value == "on";
        if (characterRoot.gameObject.activeSelf == visible) return;
        characterRoot.gameObject.SetActive(visible);
        Debug.Log($"[stand] visible {visible}");
    }

    /// <summary>Absolute character rotation in degrees, `x,y,z`.</summary>
    public void SetCharacterRotation(string value)
    {
        if (characterRoot == null) return;
        if (!TryParseVector(value, out var euler)) return;
        if (rotationRoutine != null) { StopCoroutine(rotationRoutine); rotationRoutine = null; }
        characterRoot.localEulerAngles = euler;
    }

    /// <summary>Animate the character rotation, `x,y,z,durationSeconds,ease`.</summary>
    public void RotateCharacter(string value)
    {
        if (characterRoot == null) return;
        var parts = value.Split(',');
        if (parts.Length < 4) { SetCharacterRotation(value); return; }
        if (!float.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var x) ||
            !float.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var y) ||
            !float.TryParse(parts[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var z) ||
            !float.TryParse(parts[3], NumberStyles.Float, CultureInfo.InvariantCulture, out var duration))
            return;
        var ease = parts.Length > 4 ? parts[4] : "linear";
        if (rotationRoutine != null) StopCoroutine(rotationRoutine);
        rotationRoutine = StartCoroutine(RotateRoutine(new Vector3(x, y, z), duration, ease));
    }

    private IEnumerator RotateRoutine(Vector3 target, float duration, string ease)
    {
        var from = characterRoot.localEulerAngles;
        from.x = NormalizeAngle(from.x);
        from.y = NormalizeAngle(from.y);
        from.z = NormalizeAngle(from.z);
        if (duration <= 0.001f)
        {
            characterRoot.localEulerAngles = target;
            rotationRoutine = null;
            yield break;
        }
        var elapsed = 0f;
        while (elapsed < duration)
        {
            elapsed += Time.deltaTime;
            var t = Ease(Mathf.Clamp01(elapsed / duration), ease);
            characterRoot.localEulerAngles = Vector3.LerpUnclamped(from, target, t);
            yield return null;
        }
        characterRoot.localEulerAngles = target;
        rotationRoutine = null;
    }

    /// <summary>Absolute character offset in metres, `x,y,z`.</summary>
    public void SetCharacterOffset(string value)
    {
        if (characterRoot == null) return;
        if (!TryParseVector(value, out var offset)) return;
        baseOffset = offset;
        characterRoot.localPosition = offset;
    }

    /// <summary>`actor_reset_sway`: drop the accumulated sway state (ResetSwayActor).</summary>
    public void ResetSway(string value)
    {
        var rig = bootstrap != null ? bootstrap.SwayRig : null;
        if (rig == null) return;
        foreach (var bone in rig.bones)
        {
            if (bone == null || bone.tipTrs == null) continue;
            bone.curTipPos = bone.tipTrs.position;
            bone.prevTipPos = bone.curTipPos;
            bone.h = Vector3.zero;
            bone.cc = Vector3.zero;
            bone.force = Vector3.zero;
            if (bone.trs != null) bone.trs.localRotation = bone.initialLocalRotation;
        }
        Debug.Log($"[stand] sway reset ({rig.bones.Count} bones)");
    }

    /// <summary>`actor_lip`: native lip modes are `Close` and `Fomalhout`.</summary>
    public void SetLipMode(string value)
    {
        if (face == null) return;
        face.SetScriptLipMode(value);
        Debug.Log($"[stand] lip mode {value}");
    }

    /// <summary>`actor_in_out`: walk in from / out to the side of the stage.</summary>
    public void PlayInOut(string value)
    {
        if (characterRoot == null) return;
        var parts = value.Split(',');
        if (parts.Length < 3) return;
        var name = parts[0].ToUpperInvariant();
        if (!float.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var speed)) speed = 0f;
        if (!float.TryParse(parts[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var durationMs)) durationMs = 0f;
        var duration = Mathf.Max(0.05f, durationMs / 1000f);
        var from = name.Contains("IN") && !name.Contains("OUT") ? -2.6f : 0f;
        var to = name.Contains("OUT") ? -2.6f : 0f;
        if (inOutRoutine != null) StopCoroutine(inOutRoutine);
        inOutRoutine = StartCoroutine(InOutRoutine(from, to, duration, name.Contains("OUT")));
        Debug.Log($"[stand] inout {name} speed={speed} duration={duration:0.00}s");
    }

    private IEnumerator InOutRoutine(float from, float to, float duration, bool leaving)
    {
        var start = baseOffset + new Vector3(from, 0f, 0f);
        var end = baseOffset + new Vector3(to, 0f, 0f);
        var elapsed = 0f;
        while (elapsed < duration)
        {
            elapsed += Time.deltaTime;
            var t = Ease(Mathf.Clamp01(elapsed / duration), "easeInOutQuad");
            characterRoot.localPosition = Vector3.LerpUnclamped(start, end, t);
            yield return null;
        }
        characterRoot.localPosition = end;
        if (leaving) characterRoot.gameObject.SetActive(false);
        inOutRoutine = null;
    }

    private static float Ease(float t, string ease)
    {
        switch ((ease ?? "").ToLowerInvariant())
        {
            case "easeinquad": return t * t;
            case "easeoutquad": return 1f - (1f - t) * (1f - t);
            case "easeinoutquad": return t < 0.5f ? 2f * t * t : 1f - Mathf.Pow(-2f * t + 2f, 2f) / 2f;
            case "easeinsine": return 1f - Mathf.Cos(t * Mathf.PI * 0.5f);
            case "easeoutsine": return Mathf.Sin(t * Mathf.PI * 0.5f);
            case "easeinoutsine": return -(Mathf.Cos(Mathf.PI * t) - 1f) / 2f;
            default: return t;
        }
    }

    private static float NormalizeAngle(float angle)
    {
        while (angle > 180f) angle -= 360f;
        while (angle < -180f) angle += 360f;
        return angle;
    }

    private static bool TryParseVector(string value, out Vector3 vector)
    {
        vector = default;
        var parts = (value ?? "").Split(',');
        if (parts.Length < 3) return false;
        if (!float.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var x) ||
            !float.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var y) ||
            !float.TryParse(parts[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var z))
            return false;
        vector = new Vector3(x, y, z);
        return true;
    }

    // ------------------------------------------------------------------
    // Events to Swift
    // ------------------------------------------------------------------

    private void EmitLoaded()
    {
        var message = $"{{\"type\":\"loaded\",\"character\":\"{character}\",\"outfit\":\"{outfit}\"," +
                      $"\"bones\":{motion?.BoneCount ?? 0},\"idleFrames\":{motion?.IdleFrames ?? 0}}}";
        EidolonStandBridge.Emit(message);
    }

    private void EmitFailure(string reason)
    {
        var escaped = reason.Replace("\\", "\\\\").Replace("\"", "\\\"");
        EidolonStandBridge.Emit($"{{\"type\":\"failure\",\"reason\":\"{escaped}\"}}");
    }
}
