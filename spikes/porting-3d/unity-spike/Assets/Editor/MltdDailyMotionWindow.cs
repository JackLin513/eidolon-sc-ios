using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using UnityEditor;
using UnityEditor.Animations;
using UnityEditor.SceneManagement;
using UnityEngine;

/// 把游戏里的 `chr_anim_com_001har` 日常动作烘成项目内的 AnimationClip 资源，
/// 搭一个角色 + Animator，并打开 Unity 的 Animation 窗口展示。
///
/// 为什么需要烘：游戏 bundle 里的 clip 是构建版资产，编辑器曲线（path 字符串）被剥掉，
/// 只剩 CRC32 path hash + streamed 关键帧，Animation 窗口无法直接显示。
/// 这里用 SampleAnimation（插入运行时才有的 BODY_SCALE 节点后）在 60fps 上采样，
/// 再用 AnimationUtility.SetEditorCurve 写回带 path 的普通动画曲线。
///
/// 运行：Unity -projectPath <unity-spike> -executeMethod MltdDailyMotionWindow.Run
/// 生成物在 Assets/__MLTD/DailyMotions/（.gitignore）。
public static class MltdDailyMotionWindow
{
    private const string Work = "/Users/jacklin/mltd-work";
    private const string AssetRoot = "Assets/__MLTD";
    private const string ClipDir = AssetRoot + "/DailyMotions";
    private const string CtrlDir = AssetRoot + "/DailyControllers";
    private const string CharacterName = "MLTD_DailyCharacter";
    private const string Report = "/tmp/mltd-animation-window.txt";

    private static readonly string[] Actions = { "act", "noo", "yes", "str", "swt", "lop", "end" };

    private static GameObject _character;
    private static string _currentAction;

    [MenuItem("MLTD/Daily Motion/Open Animation Window")]
    public static void Run()
    {
        var sb = new StringBuilder();
        try
        {
            ApplyGlobals();
            EnsureFolder(ClipDir);
            EnsureFolder(CtrlDir);

            var bodyBundle = LoadBundle(Work + "/bundles/cb_ss001_001har.unity3d");
            var headBundle = LoadBundle(Work + "/bundles/ch_ss001_001har.unity3d");
            var clipBundle = LoadBundle(Work + "/chranim-com/chr_anim_com_001har.unity3d");
            if (bodyBundle == null || clipBundle == null)
            {
                File.WriteAllText(Report, "bundle load fail body=" + (bodyBundle == null) + " clips=" + (clipBundle == null));
                return;
            }

            var scene = EditorSceneManager.NewScene(NewSceneSetup.DefaultGameObjects, NewSceneMode.Single);
            var prefab = bodyBundle.LoadAllAssets<GameObject>()[0];
            _character = UnityEngine.Object.Instantiate(prefab);
            _character.name = CharacterName;
            if (headBundle != null)
            {
                var head = UnityEngine.Object.Instantiate(headBundle.LoadAllAssets<GameObject>()[0]);
                head.name = "daily_head";
                var modelRoot = _character.transform.Find("MODEL_00");
                if (modelRoot != null) head.transform.SetParent(modelRoot, false);
            }
            InsertBodyScale(_character);
            FrameCamera(_character);

            foreach (var clip in clipBundle.LoadAllAssets<AnimationClip>().OrderBy(c => c.name))
            {
                var baked = BakeClip(clip, _character, sb);
                if (baked == null) continue;
                var ctrl = BuildController(baked);
                if (ctrl == null) continue;
                sb.AppendLine($"baked {clip.name}: frames={Mathf.RoundToInt(clip.length * 60)} asset={AssetDatabase.GetAssetPath(baked)} ctrl={AssetDatabase.GetAssetPath(ctrl)}");
            }
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();

            ShowAction("act");
            OpenAnimationWindow();
            sb.AppendLine("character=" + CharacterName + " selected action=" + _currentAction);
            Debug.Log("MLTD DAILY MOTION WINDOW READY");
        }
        catch (Exception e)
        {
            sb.AppendLine("EXCEPTION " + e);
            Debug.LogError(e);
        }
        File.WriteAllText(Report, sb.ToString());
    }

    [MenuItem("MLTD/Daily Motion/act")]
    private static void ShowAct() => ShowAction("act");
    [MenuItem("MLTD/Daily Motion/noo")]
    private static void ShowNoo() => ShowAction("noo");
    [MenuItem("MLTD/Daily Motion/yes")]
    private static void ShowYes() => ShowAction("yes");
    [MenuItem("MLTD/Daily Motion/str")]
    private static void ShowStr() => ShowAction("str");
    [MenuItem("MLTD/Daily Motion/swt")]
    private static void ShowSwt() => ShowAction("swt");
    [MenuItem("MLTD/Daily Motion/lop")]
    private static void ShowLop() => ShowAction("lop");
    [MenuItem("MLTD/Daily Motion/end")]
    private static void ShowEnd() => ShowAction("end");

    private static void ShowAction(string action)
    {
        if (_character == null) _character = GameObject.Find(CharacterName);
        if (_character == null)
        {
            Debug.LogWarning("MLTD: no character; run MLTD/Daily Motion/Open Animation Window first");
            return;
        }
        var ctrl = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(CtrlDir + "/com_001har_18y_" + action + ".controller");
        var animator = _character.GetComponent<Animator>();
        if (ctrl == null || animator == null)
        {
            Debug.LogWarning("MLTD: controller/animator missing for " + action);
            return;
        }
        animator.runtimeAnimatorController = ctrl;
        _currentAction = action;
        Selection.activeGameObject = _character;
        var win = OpenAnimationWindow();
        win?.Repaint();
        Debug.Log("MLTD daily motion: " + action);
    }

    private static AnimationClip BakeClip(AnimationClip source, GameObject root, StringBuilder sb)
    {
        // 先采样，记录每根骨的世界无关局部变换（已是 local）
        var transforms = root.GetComponentsInChildren<Transform>(true);
        var paths = new Dictionary<Transform, string>();
        foreach (var tr in transforms)
        {
            if (tr == root.transform) continue;
            var parts = new List<string>();
            for (var t = tr; t != null && t != root.transform; t = t.parent) parts.Add(t.name);
            parts.Reverse();
            paths[tr] = string.Join("/", parts);
        }

        int frames = Mathf.Max(2, Mathf.RoundToInt(source.length * 60f)) + 1;
        var times = new float[frames];
        var rot = new Dictionary<Transform, Quaternion[]>();
        var pos = new Dictionary<Transform, Vector3[]>();
        foreach (var tr in transforms)
        {
            if (tr == root.transform) continue;
            rot[tr] = new Quaternion[frames];
            pos[tr] = new Vector3[frames];
        }
        for (int f = 0; f < frames; f++)
        {
            float t = source.length * f / (frames - 1);
            times[f] = t;
            source.SampleAnimation(root, t);
            foreach (var tr in transforms)
            {
                if (tr == root.transform) continue;
                rot[tr][f] = tr.localRotation;
                pos[tr][f] = tr.localPosition;
            }
        }

        var baked = new AnimationClip { frameRate = 60f, name = source.name };
        var rotationCurves = 0;
        var positionCurves = 0;
        foreach (var tr in transforms)
        {
            if (tr == root.transform) continue;
            var path = paths[tr];
            // 四元数连续性（避免窗口里出现反向跳变）
            var q = rot[tr];
            for (int f = 1; f < frames; f++)
            {
                if (Quaternion.Dot(q[f - 1], q[f]) < 0f) q[f] = new Quaternion(-q[f].x, -q[f].y, -q[f].z, -q[f].w);
            }
            if (IsAnimated(q))
            {
                SetCurve(baked, typeof(Transform), path, "m_LocalRotation.x", times, q.Select(v => v.x).ToArray());
                SetCurve(baked, typeof(Transform), path, "m_LocalRotation.y", times, q.Select(v => v.y).ToArray());
                SetCurve(baked, typeof(Transform), path, "m_LocalRotation.z", times, q.Select(v => v.z).ToArray());
                SetCurve(baked, typeof(Transform), path, "m_LocalRotation.w", times, q.Select(v => v.w).ToArray());
                rotationCurves++;
            }
            var p = pos[tr];
            if (IsAnimated(p))
            {
                SetCurve(baked, typeof(Transform), path, "m_LocalPosition.x", times, p.Select(v => v.x).ToArray());
                SetCurve(baked, typeof(Transform), path, "m_LocalPosition.y", times, p.Select(v => v.y).ToArray());
                SetCurve(baked, typeof(Transform), path, "m_LocalPosition.z", times, p.Select(v => v.z).ToArray());
                positionCurves++;
            }
        }
        baked.legacy = false;
        var assetPath = ClipDir + "/" + source.name + ".anim";
        AssetDatabase.DeleteAsset(assetPath);
        AssetDatabase.CreateAsset(baked, assetPath);
        sb.AppendLine($"  {source.name}: rotationPaths={rotationCurves} positionPaths={positionCurves} frames={frames}");
        return baked;
    }

    private static bool IsAnimated(Quaternion[] values)
    {
        for (int i = 1; i < values.Length; i++)
            if (Quaternion.Angle(values[0], values[i]) > 0.01f) return true;
        return false;
    }

    private static bool IsAnimated(Vector3[] values)
    {
        for (int i = 1; i < values.Length; i++)
            if ((values[i] - values[0]).sqrMagnitude > 1e-10f) return true;
        return false;
    }

    private static void SetCurve(AnimationClip clip, Type type, string path, string property, float[] times, float[] values)
    {
        var keys = new Keyframe[times.Length];
        for (int i = 0; i < times.Length; i++) keys[i] = new Keyframe(times[i], values[i]);
        var curve = new AnimationCurve(keys);
        // 采样已经是 60fps，线性插值最稳，避免 auto tangent 过冲
        for (int i = 0; i < curve.length; i++)
            AnimationUtility.SetKeyLeftTangentMode(curve, i, AnimationUtility.TangentMode.Linear);
        for (int i = 0; i < curve.length; i++)
            AnimationUtility.SetKeyRightTangentMode(curve, i, AnimationUtility.TangentMode.Linear);
        AnimationUtility.SetEditorCurve(clip, new EditorCurveBinding { type = type, path = path, propertyName = property }, curve);
    }

    private static AnimatorController BuildController(AnimationClip clip)
    {
        var path = CtrlDir + "/" + clip.name + ".controller";
        AssetDatabase.DeleteAsset(path);
        var controller = AnimatorController.CreateAnimatorControllerAtPath(path);
        var state = controller.AddMotion(clip);
        controller.layers[0].stateMachine.defaultState = state;
        EditorUtility.SetDirty(controller);
        return controller;
    }

    private static void InsertBodyScale(GameObject character)
    {
        var modelRoot = character.transform.Find("MODEL_00");
        if (modelRoot == null || modelRoot.Find("BODY_SCALE") != null) return;
        var scale = new GameObject("BODY_SCALE").transform;
        scale.SetParent(modelRoot, false);
        var children = new List<Transform>();
        for (int i = 0; i < modelRoot.childCount; i++)
        {
            var c = modelRoot.GetChild(i);
            if (c != scale) children.Add(c);
        }
        foreach (var c in children) c.SetParent(scale, true);
    }

    private static void FrameCamera(GameObject root)
    {
        var camera = Camera.main;
        if (camera == null) return;
        camera.clearFlags = CameraClearFlags.SolidColor;
        camera.backgroundColor = new Color(0.16f, 0.17f, 0.2f);
        camera.fieldOfView = 30f;
        var renderers = root.GetComponentsInChildren<Renderer>(true).Where(r => r.enabled).ToArray();
        if (renderers.Length == 0) return;
        var bounds = renderers[0].bounds;
        foreach (var r in renderers) bounds.Encapsulate(r.bounds);
        var height = Mathf.Max(bounds.size.y, 0.1f);
        var distance = height / (2 * Mathf.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad)) * 1.25f;
        camera.transform.position = bounds.center + new Vector3(0, 0.05f, distance);
        camera.transform.LookAt(bounds.center);
    }

    private static AnimationWindowHandle OpenAnimationWindow()
    {
        var type = typeof(EditorWindow).Assembly.GetType("UnityEditor.AnimationWindow");
        if (type == null) return null;
        var window = EditorWindow.GetWindow(type, false, "Animation", true);
        window.Show();
        window.Focus();
        window.Repaint();
        return new AnimationWindowHandle(window);
    }

    private sealed class AnimationWindowHandle
    {
        private readonly EditorWindow _window;
        public AnimationWindowHandle(EditorWindow window) { _window = window; }
        public void Repaint() { if (_window != null) _window.Repaint(); }
    }

    private static void EnsureFolder(string path)
    {
        var parts = path.Split('/');
        var current = parts[0];
        for (int i = 1; i < parts.Length; i++)
        {
            var next = current + "/" + parts[i];
            if (!AssetDatabase.IsValidFolder(next)) AssetDatabase.CreateFolder(current, parts[i]);
            current = next;
        }
    }

    private static void ApplyGlobals()
    {
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

    private static AssetBundle LoadBundle(string path)
    {
        if (!File.Exists(path)) return null;
        var name = Path.GetFileName(path);
        foreach (var b in AssetBundle.GetAllLoadedAssetBundles())
            if (b.name == name) return b;
        return AssetBundle.LoadFromFile(path);
    }
}
