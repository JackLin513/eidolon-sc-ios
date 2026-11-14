using System;
using System.Globalization;
using System.IO;
using System.Text;
using UnityEditor;
using UnityEngine;

/// <summary>
/// Verification harness for <see cref="FaceCtrlNative"/> (ADR-0033 B3).
///
/// Binds the native FaceCtrl to the character that <see cref="CharacterBootstrap"/>
/// built, reports what it loaded (character row / expression count / face
/// renderer / material / five TransitionModules), and dumps everything needed to
/// diff against the native formulas:
/// <list type="bullet">
/// <item>the 32 blend-shape weights (mouth 0..13, eye region 14..31) and the five
/// native buffers,</item>
/// <item>every expression's 33-wide open/close vectors,</item>
/// <item>the ConvLip code→kind map and the recovered <c>lipChar</c> / <c>facialMenu</c>,</item>
/// <item>deterministic blink / cheek / lip fades stepped with an explicit dt
/// (the editor has no per-frame ticks; <see cref="FaceCtrlNative.ActionWithDeltaTime"/>
/// is the same composition code with the time source substituted).</item>
/// </list>
/// Dumps go to <c>$MLTD_WORK/out/face-probe.txt</c> (or <c>~/mltd-work/out</c>) in
/// addition to the Console, so they can be diffed against a game capture.
/// </summary>
public static class FaceCtrlProbe
{
    /// <summary>Path used by the dump menu items (same convention as the sway probes).</summary>
    public static string DumpPath
    {
        get
        {
            var root = Environment.GetEnvironmentVariable("MLTD_WORK");
            if (string.IsNullOrEmpty(root))
                root = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "mltd-work");
            return Path.Combine(root, "out", "face-probe.txt");
        }
    }

    // ------------------------------------------------------------------
    // Binding
    // ------------------------------------------------------------------

    /// <summary>Character currently in the scene.</summary>
    public static CharacterBootstrap Character()
    {
        return UnityEngine.Object.FindObjectOfType<CharacterBootstrap>();
    }

    /// <summary>
    /// Adds (or reuses) a <see cref="FaceCtrlNative"/> on the character root,
    /// binds the face renderer (native ctor's
    /// <c>objname + "/obj_head_GP/face"</c> lookup) and loads the exported
    /// expression table through the native <c>BlendParamLoad</c> + <c>Init</c> +
    /// <c>Init2</c> path.
    /// </summary>
    public static FaceCtrlNative Bind()
    {
        var bootstrap = Character();
        if (bootstrap == null)
        {
            Debug.LogError("FaceCtrlProbe: no CharacterBootstrap in the scene");
            return null;
        }

        var face = bootstrap.GetComponent<FaceCtrlNative>();
        if (face == null) face = bootstrap.gameObject.AddComponent<FaceCtrlNative>();
        face.Bind(bootstrap.transform);

        var cid = CharacterId(bootstrap);
        if (!string.IsNullOrEmpty(bootstrap.facialParamsPath)
            && File.Exists(bootstrap.facialParamsPath))
        {
            int count = face.LoadJson(File.ReadAllText(bootstrap.facialParamsPath), cid);
            Debug.Log("FaceCtrlProbe: bound FaceCtrlNative to '" + bootstrap.name
                      + "' cid=" + cid + " expressions=" + count);
        }
        else
        {
            Debug.LogWarning("FaceCtrlProbe: expression table not found at "
                             + bootstrap.facialParamsPath);
        }
        return face;
    }

    /// <summary>Same cid derivation as CharacterBootstrap.CharacterId().</summary>
    private static string CharacterId(CharacterBootstrap bootstrap)
    {
        var name = bootstrap.bodyBundle.Replace(".unity3d", "");
        var parts = name.Split('_');
        return parts.Length >= 3 ? parts[parts.Length - 1] : name;
    }

    private static FaceCtrlNative Find()
    {
        var face = UnityEngine.Object.FindObjectOfType<FaceCtrlNative>();
        if (face == null)
        {
            Debug.Log("FaceCtrlProbe: no FaceCtrlNative; use MLTD/Face: bind first");
        }
        return face;
    }

    // ------------------------------------------------------------------
    // Describe
    // ------------------------------------------------------------------

    [MenuItem("MLTD/Face: bind native FaceCtrl")]
    public static void BindMenu()
    {
        var face = Bind();
        if (face != null) Dump("bind", face.Describe());
    }

    [MenuItem("MLTD/Face: describe")]
    public static void Describe()
    {
        var face = Find();
        if (face == null) return;
        Dump("describe", face.Describe() + "\n\n" + face.DumpBuffers());
    }

    // ------------------------------------------------------------------
    // Weight / buffer dumps
    // ------------------------------------------------------------------

    [MenuItem("MLTD/Face: dump channels + buffers")]
    public static void DumpChannels()
    {
        var face = Find();
        if (face == null) return;
        Dump("channels", face.Describe() + "\n\n" + face.DumpBuffers() + "\n" + face.DumpChannelWeights());
    }

    [MenuItem("MLTD/Face: dump all 28 expressions")]
    public static void DumpExpressions()
    {
        var face = Find();
        if (face == null) return;
        var sb = new StringBuilder();
        sb.Append("facialMenu = ").Append(string.Join(",", FaceCtrlNative.facialMenu)).Append("\n\n");
        for (int i = 0; i < FaceCtrlNative.facialMenu.Length; i++)
            sb.Append(face.DumpExpression(i)).Append('\n');
        Dump("expressions", sb.ToString());
    }

    [MenuItem("MLTD/Face: dump lip code map")]
    public static void DumpLipMap()
    {
        var sb = new StringBuilder();
        sb.Append("ConvLip(n) @0x379F3A4:  50->5, 54->-1, 55..59->6..10, else n%5\n");
        for (int n = -2; n <= 60; n++)
            sb.Append("  ConvLip(").Append(n).Append(") = ").Append(FaceCtrlNative.ConvLip(n)).Append('\n');
        sb.Append("\nlipChar[60] = ");
        for (int i = 0; i < FaceCtrlNative.lipChar.Length; i++)
            sb.Append(i).Append(':').Append(FaceCtrlNative.lipChar[i] ?? "<null>").Append(' ');
        Dump("lip-map", sb.ToString());
    }

    // ------------------------------------------------------------------
    // Deterministic fade steps (explicit dt; native 60 Hz step = 1/60)
    // ------------------------------------------------------------------

    private const float Step = 1f / 60f;

    [MenuItem("MLTD/Face: blink step (24 frames)")]
    public static void BlinkStep()
    {
        var face = Find();
        if (face == null) return;
        var sb = new StringBuilder();
        sb.Append("native blink: eyeBlinkTime=").Append(FaceCtrlNative.eyeBlinkTime)
          .Append("s, TransitionModule 0.1s, dt=").Append(Step.ToString("F6")).Append('\n');

        face.SetEyeCloseDirect(false);
        face.UpdateFace();
        sb.Append("open  ").Append(MiniState(face)).Append('\n');
        sb.Append("  weights ").Append(EyeWeights(face)).Append('\n');

        face.SetEyeClose(true); // native SetEyeClose(true) targets EyeState.Close (kind 0)
        for (int i = 0; i < 12; i++)
        {
            face.ActionWithDeltaTime(Step);
            sb.Append("close f").Append(i + 1).Append(' ').Append(MiniState(face)).Append('\n');
            sb.Append("  weights ").Append(EyeWeights(face)).Append('\n');
            if (face.eyeTrs.timer == 0f) break;
        }

        face.SetEyeClose(false);
        for (int i = 0; i < 12; i++)
        {
            face.ActionWithDeltaTime(Step);
            sb.Append("open  f").Append(i + 1).Append(' ').Append(MiniState(face)).Append('\n');
            sb.Append("  weights ").Append(EyeWeights(face)).Append('\n');
            if (face.eyeTrs.timer == 0f) break;
        }
        Dump("blink", sb.ToString());
    }

    [MenuItem("MLTD/Face: cheek fade step (OFF→Weak→Strong)")]
    public static void CheekStep()
    {
        var face = Find();
        if (face == null) return;
        var sb = new StringBuilder();
        sb.Append("cheekBaseIntensity=").Append(face.cheekBaseIntensity.ToString("F3"))
          .Append(" cheekTransTime=0.1 dt=").Append(Step.ToString("F6")).Append('\n');

        face.SetCheekDirect((int)FaceCtrlNative.CheekState.OFF);
        face.UpdateFace();
        sb.Append("OFF   ").Append(MiniState(face)).Append("  material=").Append(CheekMaterial(face)).Append('\n');

        face.SetCheek((int)FaceCtrlNative.CheekState.Weak);
        StepCheek(face, sb, "Weak ");
        face.SetCheek((int)FaceCtrlNative.CheekState.Strong);
        StepCheek(face, sb, "Strong");
        face.SetCheek((int)FaceCtrlNative.CheekState.OFF);
        StepCheek(face, sb, "OFF->");
        Dump("cheek", sb.ToString());
    }

    private static void StepCheek(FaceCtrlNative face, StringBuilder sb, string label)
    {
        for (int i = 0; i < 12; i++)
        {
            face.ActionWithDeltaTime(Step);
            sb.Append(label).Append(" f").Append(i + 1).Append(' ').Append(MiniState(face))
              .Append("  material=").Append(CheekMaterial(face)).Append('\n');
            if (face.cheekTrs.timer == 0f) break;
        }
    }

    [MenuItem("MLTD/Face: lip step (all kinds)")]
    public static void LipStep()
    {
        var face = Find();
        if (face == null) return;
        var sb = new StringBuilder();
        sb.Append("lipTransitionTime=0.2 dt=").Append(Step.ToString("F6"))
          .Append(" lipParam=").Append(face.lipParam == null ? "null" : "zeros (data-gap)")
          .Append('\n');
        for (int code = 0; code <= 59; code++)
        {
            face.SetLipDirect(code);
            face.UpdateFace();
            sb.Append("code ").Append(code).Append(" -> kind ").Append(face.GetCurrentLip())
              .Append("  mouth ").Append(MouthWeights(face)).Append('\n');
        }
        Dump("lip", sb.ToString());
    }

    // ------------------------------------------------------------------
    // Frame-body dump helpers
    // ------------------------------------------------------------------

    private static string MiniState(FaceCtrlNative face)
    {
        return "eye[" + face.eyeTrs.last + "→" + face.eyeTrs.cur + " r=" + face.eyeTrs.ratio.ToString("F4")
               + " t=" + face.eyeTrs.timer.ToString("F4") + "]"
               + " cheek[" + face.cheekTrs.last + "→" + face.cheekTrs.cur + " r=" + face.cheekTrs.ratio.ToString("F4")
               + "]"
               + " lip[" + face.lipTrs.last + "→" + face.lipTrs.cur + "]";
    }

    private static string EyeWeights(FaceCtrlNative face)
    {
        return "BS24..31 " + Weights(face, FaceCtrlNative.mouthShapes + FaceCtrlNative.eyeShapes - 8,
                     FaceCtrlNative.mouthShapes + FaceCtrlNative.eyeShapes);
    }

    private static string MouthWeights(FaceCtrlNative face)
    {
        return "BS0..13 " + Weights(face, 0, FaceCtrlNative.mouthShapes);
    }

    private static string Weights(FaceCtrlNative face, int start, int end)
    {
        if (face.render == null) return "no renderer";
        var sb = new StringBuilder();
        for (int i = start; i < end; i++)
        {
            if (i > start) sb.Append(',');
            sb.Append(face.render.GetBlendShapeWeight(i).ToString("F2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    private static string CheekMaterial(FaceCtrlNative face)
    {
        if (face.render == null) return "no renderer";
        Material material = face.face_material != null ? face.face_material : face.render.sharedMaterial;
        if (material == null) return "no material";
        float isReddish = material.HasProperty("_IsReddish") ? material.GetFloat("_IsReddish") : float.NaN;
        float intensity = material.HasProperty("_ReddishIntensity")
            ? material.GetFloat("_ReddishIntensity")
            : float.NaN;
        bool keyword = material.IsKeywordEnabled(FaceCtrlNative.ReddishKeyword);
        return "material=" + material.name
               + " _IsReddish=" + isReddish.ToString("F3")
               + " _ReddishIntensity=" + intensity.ToString("F3")
               + " " + FaceCtrlNative.ReddishKeyword + "=" + keyword;
    }

    // ------------------------------------------------------------------
    // Dump sink
    // ------------------------------------------------------------------

    private static void Dump(string title, string text)
    {
        Debug.Log("FaceCtrlProbe[" + title + "]\n" + text);
        try
        {
            var path = DumpPath;
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.AppendAllText(path,
                "\n===== " + title + " @ " + DateTime.Now.ToString("u") + " =====\n" + text + "\n");
            Debug.Log("FaceCtrlProbe: appended to " + path);
        }
        catch (Exception error)
        {
            Debug.LogWarning("FaceCtrlProbe: could not write dump: " + error.Message);
        }
    }
}
