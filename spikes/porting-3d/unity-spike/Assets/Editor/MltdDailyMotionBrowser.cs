using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Animations;
using UnityEditor.SceneManagement;
using UnityEngine;

/// 全角色日常动作浏览器。
///
/// 数据：`$MLTD_WORK/motion-daily-merged/flat/<idol>_<action>.txt`（30fps TSV，
/// 逐帧四元数；由 `spikes/porting-3d/export_daily_motions.py` 生成）。
/// 行为：
///  1. 载入 `cb_pr001_<idol>` + `ch_pr001_<idol>`，插运行时才有的 BODY_SCALE，
///     头挂到身体 KUBI/ATAMA（和 CharacterBootstrap 一致，否则动画时头身分离）；
///  2. 把 TSV 烘成项目内 `.anim`（带 path 的普通四元数曲线）；
///  3. 打开 Animation 窗口展示曲线，同时在浏览器窗口里用高分辨率 RenderTexture
///     预览（1024×1536，不依赖 Game 窗口分辨率，避免糊）；
///  4. 支持播放/暂停/拖动时间轴/切换角色动作。
public sealed class MltdDailyMotionBrowser : EditorWindow
{
    private const string WorkRoot = "/Users/jacklin/mltd-work";
    private const string FlatDir = WorkRoot + "/motion-daily-merged/flat";
    private const string AssetRoot = "Assets/__MLTD";
    private const string AnimDir = AssetRoot + "/BakedMotions";
    private const string CtrlDir = AssetRoot + "/BakedControllers";
    private const string CharPrefix = "MLTD_DailyCharacter";
    private static readonly string[] Actions = { "act", "noo", "yes", "str", "swt", "lop", "end" };

    private static readonly Dictionary<string, Dictionary<string, string[]>> Catalog = new();
    private static string[] _idols = Array.Empty<string>();

    private static GameObject _character;
    private static AnimationClip _clip;
    private static string _currentIdol;
    private static string _currentAction;
    private static float _time;
    private static bool _playing;
    private static float _speed = 1f;
    private static double _lastTick;

    private static Camera _previewCamera;
    private static RenderTexture _previewTarget;

    private int _idolIndex;
    private int _actionIndex;
    private Vector2 _scroll;

    [MenuItem("MLTD/Daily Motion Browser")]
    public static void Open()
    {
        var window = GetWindow<MltdDailyMotionBrowser>("MLTD Daily Motion");
        window.minSize = new Vector2(620, 820);
        if (window.position.width < 640f)
            window.position = new Rect(window.position.x, window.position.y, 820f, 1080f);
        ReloadCatalog();
        window.Show();
    }

    [InitializeOnLoadMethod]
    private static void Boot()
    {
        EditorApplication.delayCall += CheckRequestFile;
    }

    private static void CheckRequestFile()
    {
        var request = Path.Combine(WorkRoot, "daily-show.request");
        if (!File.Exists(request)) return;
        var spec = File.ReadAllText(request).Trim();
        File.Delete(request);
        var parts = spec.Split(':');
        if (parts.Length != 2)
        {
            Debug.LogWarning("MLTD: request must be <idol>:<action>, got " + spec);
            return;
        }
        ShowCharacterAction(parts[0].Trim(), parts[1].Trim());
        Open();
    }

    private static void ReloadCatalog()
    {
        Catalog.Clear();
        var catalog = Path.Combine(FlatDir, "catalog.tsv");
        if (!File.Exists(catalog))
        {
            _idols = Array.Empty<string>();
            return;
        }
        foreach (var line in File.ReadAllLines(catalog))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            var parts = line.Split('\t');
            if (parts.Length < 5) continue;
            if (!Catalog.TryGetValue(parts[0], out var map)) Catalog[parts[0]] = map = new Dictionary<string, string[]>();
            map[parts[1]] = new[] { parts[2], parts[3], parts[4] };
        }
        _idols = Catalog.Keys.OrderBy(x => x, StringComparer.Ordinal).ToArray();
    }

    private void OnEnable()
    {
        EditorApplication.update += Tick;
        if (_idols.Length == 0) ReloadCatalog();
        SyncSelectionFromState();
    }

    private void OnDisable()
    {
        EditorApplication.update -= Tick;
        DestroyPreview();
    }

    private void SyncSelectionFromState()
    {
        if (_idols.Length == 0) ReloadCatalog();
        var idolIndex = Array.IndexOf(_idols, _currentIdol);
        _idolIndex = idolIndex >= 0 ? idolIndex : 0;
        var actionIndex = Array.IndexOf(Actions, _currentAction);
        _actionIndex = actionIndex >= 0 ? actionIndex : 0;
    }

    private void Tick()
    {
        if (!_playing || _clip == null || _character == null) return;
        var now = EditorApplication.timeSinceStartup;
        var delta = (float)(now - _lastTick);
        _lastTick = now;
        _time += delta * _speed;
        if (_clip.length > 0f)
        {
            while (_time > _clip.length) _time -= _clip.length;
            while (_time < 0f) _time += _clip.length;
        }
        SamplePose(_time);
        Repaint();
    }

    private void OnGUI()
    {
        if (_idols.Length == 0) ReloadCatalog();
        if (_idols.Length == 0)
        {
            EditorGUILayout.HelpBox("没有找到 catalog：" + Path.Combine(FlatDir, "catalog.tsv"), MessageType.Warning);
            return;
        }

        _scroll = EditorGUILayout.BeginScrollView(_scroll);
        EditorGUILayout.Space(4);
        _idolIndex = Mathf.Clamp(_idolIndex, 0, _idols.Length - 1);
        _actionIndex = Mathf.Clamp(_actionIndex, 0, Actions.Length - 1);
        _idolIndex = EditorGUILayout.Popup("角色", _idolIndex, _idols);
        _actionIndex = EditorGUILayout.Popup("动作", _actionIndex, Actions);

        EditorGUILayout.BeginHorizontal();
        if (GUILayout.Button("加载 / 刷新", GUILayout.Height(28)))
            ShowCharacterAction(_idols[_idolIndex], Actions[_actionIndex]);
        if (GUILayout.Button("Action 窗口", GUILayout.Height(28), GUILayout.Width(110)))
            OpenAnimationWindow();
        EditorGUILayout.EndHorizontal();

        EditorGUILayout.Space(4);
        EditorGUILayout.LabelField(
            _currentIdol == null ? "（未加载）" : _currentIdol + " / " + _currentAction +
            (_clip != null ? $"   {_clip.frameRate:F0}fps  {_clip.length:F2}s" : ""),
            EditorStyles.boldLabel);

        if (_character == null || _clip == null)
        {
            EditorGUILayout.HelpBox("选择角色和动作后点「加载 / 刷新」。", MessageType.Info);
            EditorGUILayout.EndScrollView();
            return;
        }

        // 播放控制
        EditorGUILayout.BeginHorizontal();
        if (GUILayout.Button(_playing ? "⏸ 暂停" : "▶ 播放", GUILayout.Width(90)))
        {
            _playing = !_playing;
            _lastTick = EditorApplication.timeSinceStartup;
        }
        if (GUILayout.Button("⏮ 复位", GUILayout.Width(90)))
        {
            _time = 0f;
            SamplePose(_time);
        }
        _speed = EditorGUILayout.Slider(_speed, 0.1f, 2f);
        EditorGUILayout.EndHorizontal();

        var newTime = EditorGUILayout.Slider("时间", _time, 0f, Mathf.Max(0.01f, _clip.length));
        if (!Mathf.Approximately(newTime, _time))
        {
            _time = newTime;
            SamplePose(_time);
        }
        EditorGUILayout.LabelField("帧", Mathf.RoundToInt(_time * _clip.frameRate).ToString());

        // 高分辨率预览（不依赖 Game 窗口大小），按可用高度铺满并居中
        EditorGUILayout.Space(6);
        var availableHeight = Mathf.Max(200f, position.height - 300f);
        var availableWidth = Mathf.Max(200f, position.width - 32f);
        var previewHeight = Mathf.Min(availableHeight, availableWidth * 1.5f);
        var previewWidth = previewHeight / 1.5f;
        EditorGUILayout.BeginHorizontal();
        GUILayout.FlexibleSpace();
        if (_previewTarget != null)
            GUILayout.Box(_previewTarget, GUIStyle.none, GUILayout.Width(previewWidth), GUILayout.Height(previewHeight));
        GUILayout.FlexibleSpace();
        EditorGUILayout.EndHorizontal();
        EditorGUILayout.EndScrollView();
    }

    // ------------------------------------------------------------------
    // 构建
    // ------------------------------------------------------------------

    public static void ShowCharacterAction(string idol, string action)
    {
        if (string.IsNullOrEmpty(idol) || string.IsNullOrEmpty(action))
        {
            Debug.LogWarning("MLTD: empty idol/action");
            return;
        }
        try
        {
            ApplyGlobals();
            EnsureFolders();
            _character = EnsureCharacter(idol);
            if (_character == null) return;
            _clip = EnsureClip(idol, action);
            if (_clip == null) return;
            var controller = EnsureController(idol, action, _clip);
            if (controller == null) return;

            var animator = _character.GetComponent<Animator>();
            if (animator == null) animator = _character.AddComponent<Animator>();
            animator.runtimeAnimatorController = controller;
            animator.applyRootMotion = false;

            _currentIdol = idol;
            _currentAction = action;
            _time = _clip.length * 0.35f;
            _playing = false;
            Selection.activeGameObject = _character;
            Selection.objects = new UnityEngine.Object[] { _character };
            OpenAnimationWindow();
            SamplePose(_time);
            var window = HasOpenInstances<MltdDailyMotionBrowser>() ? GetWindow<MltdDailyMotionBrowser>() : null;
            if (window != null) { window.SyncSelectionFromState(); window.Repaint(); }
            Debug.Log($"MLTD: showing {idol} / {action} -> {AssetDatabase.GetAssetPath(_clip)}");
        }
        catch (Exception e)
        {
            Debug.LogError("MLTD ShowCharacterAction failed: " + e);
        }
    }

    /// CLI/脚本用：加载后停到指定归一化时间，便于截图核对。
    public static void PreviewAt(string idol, string action, float normalized)
    {
        ShowCharacterAction(idol, action);
        if (_clip == null) return;
        _playing = false;
        _time = Mathf.Clamp01(normalized) * _clip.length;
        SamplePose(_time);
        var window = GetWindow<MltdDailyMotionBrowser>("MLTD Daily Motion");
        window.Show();
        window.SyncSelectionFromState();
        window.Repaint();
    }

    private static void SamplePose(float time)
    {
        if (_character == null || _clip == null) return;
        if (!AnimationMode.InAnimationMode()) AnimationMode.StartAnimationMode();
        AnimationMode.SampleAnimationClip(_character, _clip, Mathf.Clamp(time, 0f, _clip.length));
        SceneView.RepaintAll();
        RenderPreview();
    }

    private static GameObject EnsureCharacter(string idol)
    {
        foreach (var existing in FindCharacters()) UnityEngine.Object.DestroyImmediate(existing);
        DestroyPreview();
        if (Catalog.Count == 0) ReloadCatalog();
        if (!Catalog.TryGetValue(idol, out var map) || map.Count == 0)
        {
            Debug.LogWarning("MLTD: unknown idol " + idol);
            return null;
        }
        var first = map.Values.First();
        var bodyBundleName = first[0];
        var headBundleName = first[1];
        if (string.IsNullOrEmpty(bodyBundleName))
        {
            Debug.LogWarning("MLTD: no body bundle for " + idol + " (pr001/ss001 missing)");
            return null;
        }
        EditorSceneManager.NewScene(NewSceneSetup.DefaultGameObjects, NewSceneMode.Single);
        var bodyBundle = LoadBundle(bodyBundleName);
        if (bodyBundle == null)
        {
            Debug.LogWarning("MLTD: body bundle missing " + bodyBundleName);
            return null;
        }
        var prefab = bodyBundle.LoadAllAssets<GameObject>()[0];
        var character = UnityEngine.Object.Instantiate(prefab);
        character.name = CharPrefix + "[" + idol + "]";
        InsertBodyScale(character);
        if (!string.IsNullOrEmpty(headBundleName))
        {
            var headBundle = LoadBundle(headBundleName);
            if (headBundle != null)
            {
                var head = UnityEngine.Object.Instantiate(headBundle.LoadAllAssets<GameObject>()[0]);
                head.name = "ch_head";
                // 和 CharacterBootstrap 一致：头挂到身体 ATAMA（否则动画时头身分离）
                var atama = character.transform.Find("MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/KUBI/ATAMA")
                            ?? FindDeep(character.transform, "ATAMA")
                            ?? character.transform.Find("MODEL_00");
                head.transform.SetParent(atama, true);
            }
        }
        ApplyMaterialFixes(character);
        FrameCamera(character);
        SetCharacterLayer(character);
        return character;
    }

    private static Transform FindDeep(Transform root, string name)
    {
        foreach (var t in root.GetComponentsInChildren<Transform>(true))
            if (t.name == name) return t;
        return null;
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

    /// 游戏 outline 是挤出壳，shipped 的 `_ZShift1000*` 按游戏相机标定；
    /// 编辑器相机下不改会糊成一片（CharacterBootstrap.FixOutlineDepth 同款修正）。
    private static void ApplyMaterialFixes(GameObject character)
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

    private static void SetCharacterLayer(GameObject character)
    {
        // 避免预览相机渲染到 Game 视图以外的层（这里只做标记，保持默认层）。
        foreach (var t in character.GetComponentsInChildren<Transform>(true))
            t.gameObject.layer = 0;
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
        var distance = height / (2 * Mathf.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad)) * 1.12f;
        camera.transform.position = bounds.center + new Vector3(0, 0.02f, distance);
        camera.transform.LookAt(new Vector3(bounds.center.x, bounds.center.y - 0.02f, bounds.center.z));
    }

    // ------------------------------------------------------------------
    // 高分辨率预览
    // ------------------------------------------------------------------

    private static void RenderPreview()
    {
        if (_character == null) return;
        if (_previewTarget == null)
        {
            _previewTarget = new RenderTexture(1024, 1536, 24, RenderTextureFormat.ARGB32)
            {
                name = "MLTDDailyPreview",
                antiAliasing = 4,
            };
        }
        if (_previewCamera == null)
        {
            var go = new GameObject("MLTD_DailyPreviewCamera") { hideFlags = HideFlags.HideAndDontSave };
            _previewCamera = go.AddComponent<Camera>();
            _previewCamera.enabled = false;
            _previewCamera.clearFlags = CameraClearFlags.SolidColor;
            _previewCamera.backgroundColor = new Color(0.16f, 0.17f, 0.2f);
            _previewCamera.fieldOfView = 30f;
            _previewCamera.nearClipPlane = 0.05f;
            _previewCamera.farClipPlane = 20f;
            _previewCamera.allowMSAA = true;
            _previewCamera.targetTexture = _previewTarget;
        }
        if (FindLight() == null)
        {
            var lightObject = new GameObject("MLTD_DailyLight") { hideFlags = HideFlags.HideAndDontSave };
            var light = lightObject.AddComponent<Light>();
            light.type = LightType.Directional;
            light.intensity = 1.1f;
            light.transform.rotation = Quaternion.Euler(35, 200, 0);
        }

        var renderers = _character.GetComponentsInChildren<Renderer>(true).Where(r => r.enabled).ToArray();
        if (renderers.Length == 0) return;
        var bounds = renderers[0].bounds;
        foreach (var r in renderers) bounds.Encapsulate(r.bounds);
        var height = Mathf.Max(bounds.size.y, 0.1f);
        var distance = height / (2 * Mathf.Tan(_previewCamera.fieldOfView * 0.5f * Mathf.Deg2Rad)) * 1.06f;
        _previewCamera.transform.position = bounds.center + new Vector3(0, 0.02f, distance);
        _previewCamera.transform.LookAt(new Vector3(bounds.center.x, bounds.center.y - 0.02f, bounds.center.z));
        _previewCamera.Render();
    }

    private static Light FindLight()
    {
        return UnityEngine.Object.FindObjectsByType<Light>(FindObjectsSortMode.None)
            .FirstOrDefault(l => l != null && l.enabled && l.type == LightType.Directional);
    }

    private static void DestroyPreview()
    {
        if (_previewCamera != null)
        {
            UnityEngine.Object.DestroyImmediate(_previewCamera.gameObject);
            _previewCamera = null;
        }
        if (_previewTarget != null)
        {
            UnityEngine.Object.DestroyImmediate(_previewTarget);
            _previewTarget = null;
        }
    }

    private static bool HasOpenInstances<T>() where T : EditorWindow
    {
        return Resources.FindObjectsOfTypeAll<T>().Length > 0;
    }

    // ------------------------------------------------------------------
    // 烘焙 / 控制器 / 工具
    // ------------------------------------------------------------------

    private static AnimationClip EnsureClip(string idol, string action)
    {
        var flat = Path.Combine(FlatDir, idol + "_" + action + ".txt");
        if (!File.Exists(flat))
        {
            Debug.LogWarning("MLTD: flat motion missing " + flat);
            return null;
        }
        var assetPath = AnimDir + "/" + idol + "_" + action + ".anim";
        var current = AssetDatabase.LoadAssetAtPath<AnimationClip>(assetPath);
        if (current != null && File.GetLastWriteTimeUtc(flat) <= File.GetLastWriteTimeUtc(assetPath)) return current;

        var parsed = ParseFlat(flat);
        var clip = new AnimationClip { name = idol + "_" + action, frameRate = parsed.fps };
        foreach (var item in parsed.rotations)
        {
            var path = item.Key;
            var perFrame = item.Value;
            for (int axis = 0; axis < 4; axis++)
            {
                var values = new float[parsed.frames];
                for (int f = 0; f < parsed.frames; f++)
                    values[f] = axis switch { 0 => perFrame[f].x, 1 => perFrame[f].y, 2 => perFrame[f].z, _ => perFrame[f].w };
                var prop = axis switch { 0 => "m_LocalRotation.x", 1 => "m_LocalRotation.y", 2 => "m_LocalRotation.z", _ => "m_LocalRotation.w" };
                SetCurve(clip, path, prop, parsed.fps, values);
            }
        }
        foreach (var item in parsed.positions)
        {
            var path = item.Key;
            var perFrame = item.Value;
            for (int axis = 0; axis < 3; axis++)
            {
                var values = new float[parsed.frames];
                for (int f = 0; f < parsed.frames; f++)
                    values[f] = axis switch { 0 => perFrame[f].x, 1 => perFrame[f].y, _ => perFrame[f].z };
                var prop = axis switch { 0 => "m_LocalPosition.x", 1 => "m_LocalPosition.y", _ => "m_LocalPosition.z" };
                SetCurve(clip, path, prop, parsed.fps, values);
            }
        }
        AssetDatabase.DeleteAsset(assetPath);
        AssetDatabase.CreateAsset(clip, assetPath);
        AssetDatabase.SaveAssets();
        return clip;
    }

    private static void SetCurve(AnimationClip clip, string path, string property, float fps, float[] values)
    {
        var keys = new Keyframe[values.Length];
        for (int i = 0; i < values.Length; i++) keys[i] = new Keyframe(i / fps, values[i]);
        var curve = new AnimationCurve(keys);
        for (int i = 0; i < curve.length; i++)
            AnimationUtility.SetKeyLeftTangentMode(curve, i, AnimationUtility.TangentMode.Linear);
        for (int i = 0; i < curve.length; i++)
            AnimationUtility.SetKeyRightTangentMode(curve, i, AnimationUtility.TangentMode.Linear);
        AnimationUtility.SetEditorCurve(clip, new EditorCurveBinding { type = typeof(Transform), path = path, propertyName = property }, curve);
    }

    private sealed class ParsedMotion
    {
        public float fps = 30f;
        public int frames;
        public readonly Dictionary<string, Vector4[]> rotations = new();
        public readonly Dictionary<string, Vector3[]> positions = new();
    }

    private static ParsedMotion ParseFlat(string file)
    {
        var motion = new ParsedMotion();
        var rotLists = new Dictionary<string, List<Vector4>>();
        var posLists = new Dictionary<string, List<Vector3>>();
        foreach (var line in File.ReadLines(file))
        {
            if (line.Length == 0) continue;
            var parts = line.Split('\t');
            if (parts[0] == "fps") { motion.fps = float.Parse(parts[1], CultureInfo.InvariantCulture); continue; }
            if (parts[0] == "frames") { motion.frames = int.Parse(parts[1], CultureInfo.InvariantCulture); continue; }
            if (parts[0] == "R" && parts.Length >= 7)
            {
                var path = parts[1];
                if (!rotLists.TryGetValue(path, out var list)) rotLists[path] = list = new List<Vector4>();
                list.Add(new Vector4(
                    float.Parse(parts[3], CultureInfo.InvariantCulture), float.Parse(parts[4], CultureInfo.InvariantCulture),
                    float.Parse(parts[5], CultureInfo.InvariantCulture), float.Parse(parts[6], CultureInfo.InvariantCulture)));
            }
            else if (parts[0] == "P" && parts.Length >= 6)
            {
                var path = parts[1];
                if (!posLists.TryGetValue(path, out var list)) posLists[path] = list = new List<Vector3>();
                list.Add(new Vector3(
                    float.Parse(parts[3], CultureInfo.InvariantCulture), float.Parse(parts[4], CultureInfo.InvariantCulture),
                    float.Parse(parts[5], CultureInfo.InvariantCulture)));
            }
        }
        foreach (var pair in rotLists) motion.rotations[pair.Key] = pair.Value.ToArray();
        foreach (var pair in posLists) motion.positions[pair.Key] = pair.Value.ToArray();
        return motion;
    }

    private static AnimatorController EnsureController(string idol, string action, AnimationClip clip)
    {
        var path = CtrlDir + "/" + idol + "_" + action + ".controller";
        var existing = AssetDatabase.LoadAssetAtPath<AnimatorController>(path);
        if (existing != null) return existing;
        var controller = AnimatorController.CreateAnimatorControllerAtPath(path);
        var state = controller.AddMotion(clip);
        controller.layers[0].stateMachine.defaultState = state;
        EditorUtility.SetDirty(controller);
        AssetDatabase.SaveAssets();
        return controller;
    }

    private static EditorWindow OpenAnimationWindow()
    {
        var type = typeof(EditorWindow).Assembly.GetType("UnityEditor.AnimationWindow");
        if (type == null) return null;
        var window = EditorWindow.GetWindow(type, false, "Animation", true);
        window.Show();
        window.Focus();
        window.Repaint();
        return window;
    }

    private static IEnumerable<GameObject> FindCharacters()
    {
        return Resources.FindObjectsOfTypeAll<GameObject>()
            .Where(go => go.scene.IsValid() && go.name.StartsWith(CharPrefix));
    }

    private static void EnsureFolders()
    {
        foreach (var dir in new[] { AssetRoot, AnimDir, CtrlDir })
        {
            var parts = dir.Split('/');
            var current = parts[0];
            for (int i = 1; i < parts.Length; i++)
            {
                var next = current + "/" + parts[i];
                if (!AssetDatabase.IsValidFolder(next)) AssetDatabase.CreateFolder(current, parts[i]);
                current = next;
            }
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

    private static AssetBundle LoadBundle(string name)
    {
        var candidates = new[]
        {
            Path.Combine(WorkRoot, "characters", name),
            Path.Combine(WorkRoot, "bundles", name),
            Path.Combine(WorkRoot, "chranim-com", name),
            Path.Combine(WorkRoot, "chranim-scene", name),
        };
        foreach (var b in AssetBundle.GetAllLoadedAssetBundles())
            if (b.name == name) return b;
        foreach (var path in candidates)
            if (File.Exists(path)) return AssetBundle.LoadFromFile(path);
        return null;
    }
}
