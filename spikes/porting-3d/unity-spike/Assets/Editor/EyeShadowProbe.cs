// B4 runtime probe: EyeTracking + DropShadow.
//
// Purpose (ADR-0033 acceptance): make the migrated state observable so it can
// be diffed against the native values instead of "looks about right".
//   * EyeTracking: eye target position/offsets, clamped rx/ry, teary/yuragi
//     state, external animation factor, the material slots that EyeUpdate
//     scrolls (_MainTex/_SubTex/_VfxTex), and the assembly (same GameObject as
//     the eye SkinnedMeshRenderer, rendEye resolved, eyeTarget created).
//   * DropShadow: mode, initOK, the cached skeleton nodes from
//     setTransforms, kage/light/pin positions and active flags, height offset.
//
// Every printed field maps to a named native field (see the comments in
// EyeTrackingNative.cs / DropShadowNative.cs). No values are invented: missing
// runtime facts are printed as `(none)` / `UNKNOWN`.
//
// Binding is best effort and only creates/attaches the migrated components; it
// never guesses native parameters (shadow mode defaults to NONE and can be
// cycled with the menu item below, the mode comes from the stage in the game).

using System;
using System.IO;
using System.Text;
using UnityEditor;
using UnityEngine;

public static class EyeShadowProbe
{
    private const string ShadowModePref = "Eidolon.B4.ProbeShadowMode";
    private const string ShadowBundlePref = "Eidolon.B4.ShadowBundle";

    [MenuItem("Tools/Eidolon/B4/Describe Eye & Shadow", false, 100)]
    public static void DescribeMenu()
    {
        Debug.Log(Describe());
    }

    [MenuItem("Tools/Eidolon/B4/Bind EyeTracking on eye renderer", false, 110)]
    public static void BindEyeTrackingMenu()
    {
        Debug.Log(BindEyeTracking());
    }

    [MenuItem("Tools/Eidolon/B4/Bind DropShadow on character root", false, 111)]
    public static void BindDropShadowMenu()
    {
        Debug.Log(BindDropShadow());
    }

    [MenuItem("Tools/Eidolon/B4/Cycle shadow mode for Bind", false, 112)]
    public static void CycleShadowModeMenu()
    {
        var current = (DropShadow.Shadow)EditorPrefs.GetInt(ShadowModePref, 0);
        var next = (DropShadow.Shadow)(((int)current + 1) % 5);
        EditorPrefs.SetInt(ShadowModePref, (int)next);
        Debug.Log($"[B4] Bind shadow mode -> {next} (native DropShadow.Shadow)");
    }

    // ------------------------------------------------------------------
    // Describe
    // ------------------------------------------------------------------

    public static string Describe()
    {
        var sb = new StringBuilder();
        sb.AppendLine("[B4] EyeTracking / DropShadow state");
        DescribeEyeTracking(sb);
        DescribeDropShadow(sb);
        return sb.ToString();
    }

    private static void DescribeEyeTracking(StringBuilder sb)
    {
        var eye = FindFirst<EyeTracking>();
        if (eye == null)
        {
            sb.AppendLine("EyeTracking: (none in scene)");
            sb.AppendLine("  assembly requirement: component must sit on the eye SkinnedMeshRenderer object " +
                          "(`.../obj_head_GP/eyes`) because Init 0x379BF80 sets eye_base = transform.");
            return;
        }

        sb.AppendLine($"EyeTracking: {PathOf(eye.transform)}");
        sb.AppendLine($"  initialized={eye.Initialized} on={eye.On} type={eye.type} scale={eye.scale}");
        sb.AppendLine($"  eye_base={NameOf(eye.EyeBase)} eyeTarget={NameOf(eye.EyeTarget)} " +
                      $"eyeTargetPos={Fmt(eye.eyeTargetPos)}");
        sb.AppendLine($"  eyeTarget.world={Fmt(eye.EyeTarget != null ? eye.EyeTarget.position : Vector3.zero)}");
        sb.AppendLine($"  offX={eye.offX:F5} offY={eye.offY:F5} camNo={eye.camNo} evCamNo={eye.evCamNo} " +
                      $"tgtIdol={eye.tgtIdol} camSampled={eye.camSampled}");
        sb.AppendLine($"  clamped rx={eye.EyeRX:F4} ry={eye.EyeRY:F4} " +
                      $"limits up/down={eye.eyeTrackParam.EyeDirLimUp}/{eye.eyeTrackParam.EyeDirLimDown} " +
                      $"left/right={eye.eyeTrackParam.EyeDirLimLeft}/{eye.eyeTrackParam.EyeDirLimRight} " +
                      $"scale={eye.eyeTrackParam.EyeDirScale}");
        sb.AppendLine($"  teary={eye.Teary} externalEyeAnimationFactor={eye.ExternalEyeAnimationFactor:F4} " +
                      $"useEyeMats={eye.UseEyeMaterials} eyeMats={(eye.EyeMaterials != null ? eye.EyeMaterials.Length : 0)}");
        sb.AppendLine($"  rendEye={NameOf(eye.EyeRenderer)}");
        DescribeMaterialSlots(sb, eye);
    }

    private static void DescribeMaterialSlots(StringBuilder sb, EyeTracking eye)
    {
        int idMain = Shader.PropertyToID("_MainTex");
        int idSub = Shader.PropertyToID("_SubTex");
        int idVfx = Shader.PropertyToID("_VfxTex");

        Material[] mats = eye.UseEyeMaterials ? eye.EyeMaterials
            : (eye.EyeRenderer != null ? eye.EyeRenderer.sharedMaterials : null);
        if (mats == null || mats.Length == 0)
        {
            sb.AppendLine("  materials: (none)");
            return;
        }

        for (int i = 0; i < mats.Length; i++)
        {
            var m = mats[i];
            if (m == null) { sb.AppendLine($"  mat[{i}]: (null)"); continue; }
            sb.AppendLine($"  mat[{i}]={m.name}");
            AppendSlot(sb, m, "_MainTex", idMain);
            AppendSlot(sb, m, "_SubTex", idSub);
            AppendSlot(sb, m, "_VfxTex", idVfx);
        }
        sb.AppendLine("  note: shipped eye materials have _MainTex/_SubTex and no _VfxTex (facts §B.1); " +
                      "a missing _VfxTex slot is the native no-op path.");
    }

    private static void AppendSlot(StringBuilder sb, Material m, string name, int id)
    {
        if (!m.HasProperty(id))
        {
            sb.AppendLine($"    {name}: absent");
            return;
        }
        Vector2 off = m.GetTextureOffset(id);
        Vector2 scale = m.GetTextureScale(id);
        sb.AppendLine($"    {name}: offset={Fmt(off)} scale={Fmt(scale)}");
    }

    private static void DescribeDropShadow(StringBuilder sb)
    {
        var shadow = FindFirst<DropShadow>();
        if (shadow == null)
        {
            sb.AppendLine("DropShadow: (none in scene)");
            sb.AppendLine("  assembly requirement: component must sit on the character root whose direct child " +
                          "is MODEL_00 (Awake 0x379A1F0 + setTransforms 0x379AE78 use transform.Find).");
            return;
        }

        sb.AppendLine($"DropShadow: {PathOf(shadow.transform)}");
        sb.AppendLine($"  mode={shadow.shadowMode} initOK={shadow.InitOk} heightOffset={shadow.HeightOffset:F5} " +
                      $"_Irogae={shadow._Irogae} eventSW={shadow.pinlightevSW} charaSW={shadow.pinlightshowSW}");
        sb.AppendLine($"  MODEL_00={NameOf(shadow.Model00)} BODY_SCALE={NameOf(shadow.BodyScale)} " +
                      $"BASE={NameOf(shadow.BaseNode)} ASHI_L={NameOf(shadow.AshiL)} ASHI_R={NameOf(shadow.AshiR)}");
        AppendObject(sb, "kage1", shadow.kage1Obj);
        AppendObject(sb, "kage2", shadow.kage2Obj);
        AppendObject(sb, "light", shadow.lightObj);
        AppendObject(sb, "pinlight", shadow.pinlightObj);
        sb.AppendLine($"  pinlight enable={shadow.pinlightEnable} evSW={shadow.pinlightevSW} " +
                      $"showSW={shadow.pinlightshowSW} lightmat={NameOf(shadow.lightmat)} pinmat={NameOf(shadow.pinmat)}");
        sb.AppendLine($"  lightmat._Irogae={ReadIrogae(shadow.lightmat)} pinmat._Irogae={ReadIrogae(shadow.pinmat)}");
    }

    private static string ReadIrogae(Material m)
    {
        if (m == null) return "(none)";
        int id = Shader.PropertyToID("_Irogae");
        return m.HasProperty(id) ? m.GetFloat(id).ToString("F3") : "(absent)";
    }

    private static void AppendObject(StringBuilder sb, string label, GameObject go)
    {
        if (go == null) { sb.AppendLine($"  {label}: (none)"); return; }
        var t = go.transform;
        sb.AppendLine($"  {label}: {go.name} active={go.activeInHierarchy} pos={Fmt(t.position)} " +
                      $"localPos={Fmt(t.localPosition)} rot={Fmt(t.rotation)} scale={Fmt(t.lossyScale)}");
    }

    // ------------------------------------------------------------------
    // Bind (best effort; no native parameter is invented)
    // ------------------------------------------------------------------

    public static string BindEyeTracking()
    {
        var sb = new StringBuilder();
        var renderers = UnityEngine.Object.FindObjectsByType<SkinnedMeshRenderer>(
            FindObjectsInactive.Include, FindObjectsSortMode.None);

        SkinnedMeshRenderer eyeRenderer = null;
        foreach (var r in renderers)
        {
            if (r != null && r.name == "eyes") { eyeRenderer = r; break; }
        }
        if (eyeRenderer == null)
        {
            sb.AppendLine("[B4] Bind EyeTracking failed: no SkinnedMeshRenderer named 'eyes' in scene.");
            return sb.ToString();
        }

        // The head root is the ancestor that owns `obj_head_GP` (native
        // Init 0x379BF80 resolves `body.name + "/obj_head_GP/eyes"`).
        GameObject headRoot = null;
        for (var t = eyeRenderer.transform; t != null; t = t.parent)
        {
            if (t.Find("obj_head_GP") != null) { headRoot = t.gameObject; break; }
        }

        var eyeGo = eyeRenderer.gameObject;
        var tracking = eyeGo.GetComponent<EyeTracking>();
        if (tracking == null) tracking = Undo.AddComponent<EyeTracking>(eyeGo);
        else Undo.RegisterCompleteObjectUndo(tracking, "Bind EyeTracking");

        var info = new EyeTrackingIdolInfo
        {
            body = headRoot,
            eye = eyeGo,
            // Native uses GameObject.Find(body.name + "/obj_head_GP/eyes"); in
            // this spike the head is nested under ATAMA so the exact scene path
            // is supplied instead.
            eyesScenePathOverride = PathOf(eyeGo.transform),
        };
        tracking.Init(info);
        EditorUtility.SetDirty(tracking);
        sb.AppendLine($"[B4] Bound EyeTracking on {PathOf(eyeGo.transform)}; headRoot={NameOf(headRoot)}; " +
                      $"initialized={tracking.Initialized} rendEye={NameOf(tracking.EyeRenderer)}");
        sb.AppendLine("  next: call tracking.EyeUpdate() every LateUpdate from the character driver " +
                      "(native JointBodyHead/CharacterDrawer drives it).");
        return sb.ToString();
    }

    public static string BindDropShadow()
    {
        var sb = new StringBuilder();
        Transform characterRoot = null;
        foreach (var r in UnityEngine.Object.FindObjectsByType<SkinnedMeshRenderer>(
                     FindObjectsInactive.Include, FindObjectsSortMode.None))
        {
            if (r == null || r.name != "body") continue;
            for (var t = r.transform; t != null; t = t.parent)
            {
                if (t.Find("MODEL_00") != null) { characterRoot = t; break; }
            }
            if (characterRoot != null) break;
        }
        if (characterRoot == null)
        {
            sb.AppendLine("[B4] Bind DropShadow failed: no character root with a MODEL_00 child in scene.");
            return sb.ToString();
        }

        var shadow = characterRoot.GetComponent<DropShadow>();
        if (shadow == null) shadow = Undo.AddComponent<DropShadow>(characterRoot.gameObject);
        else Undo.RegisterCompleteObjectUndo(shadow, "Bind DropShadow");

        var mode = (DropShadow.Shadow)EditorPrefs.GetInt(ShadowModePref, 0);
        string bundlePath = ResolveShadowBundle();
        if (bundlePath == null)
        {
            sb.AppendLine($"[B4] Bound DropShadow on {PathOf(characterRoot)}; shadow bundle not found " +
                          "(set MLTD_SHADOW_BUNDLE or $MLTD_WORK/bundles/chara_shadow.unity3d).");
            sb.AppendLine($"  component is bound; call SetShadowMode((DropShadow.Shadow){mode}, bundle) later.");
            return sb.ToString();
        }

        var bundle = AssetBundle.LoadFromFile(bundlePath);
        if (bundle == null)
        {
            sb.AppendLine($"[B4] Bound DropShadow on {PathOf(characterRoot)}; failed to load {bundlePath}.");
            return sb.ToString();
        }

        shadow.SetShadowMode(mode, bundle);
        EditorUtility.SetDirty(shadow);
        sb.AppendLine($"[B4] Bound DropShadow on {PathOf(characterRoot)}; bundle={bundlePath}; mode={mode}");
        sb.AppendLine($"  kage1={NameOf(shadow.kage1Obj)} kage2={NameOf(shadow.kage2Obj)} " +
                      $"light={NameOf(shadow.lightObj)} pinlight={NameOf(shadow.pinlightObj)} initOK={shadow.InitOk}");
        return sb.ToString();
    }

    private static string ResolveShadowBundle()
    {
        string path = Environment.GetEnvironmentVariable("MLTD_SHADOW_BUNDLE");
        if (!string.IsNullOrEmpty(path) && File.Exists(path)) return path;

        string work = Environment.GetEnvironmentVariable("MLTD_WORK");
        if (string.IsNullOrEmpty(work))
            work = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "mltd-work");
        path = Path.Combine(work, "bundles", "chara_shadow.unity3d");
        return File.Exists(path) ? path : null;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private static T FindFirst<T>() where T : Component
    {
        return UnityEngine.Object.FindFirstObjectByType<T>(FindObjectsInactive.Include);
    }

    private static string NameOf(UnityEngine.Object o)
    {
        return o == null ? "(none)" : o.name;
    }

    private static string PathOf(Transform t)
    {
        if (t == null) return "(none)";
        var parts = new System.Collections.Generic.List<string>();
        for (var cur = t; cur != null; cur = cur.parent) parts.Add(cur.name);
        parts.Reverse();
        return string.Join("/", parts);
    }

    private static string Fmt(Vector3 v)
    {
        return $"({v.x:F4}, {v.y:F4}, {v.z:F4})";
    }

    private static string Fmt(Vector2 v)
    {
        return $"({v.x:F4}, {v.y:F4})";
    }

    private static string Fmt(Quaternion q)
    {
        return $"({q.x:F4}, {q.y:F4}, {q.z:F4}, {q.w:F4})";
    }
}
