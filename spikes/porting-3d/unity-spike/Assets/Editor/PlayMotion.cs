using System;
using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

/// Menu entry that opens the saved playable scene (or builds it the first
/// time) and enters Play mode. The scene carries the bundle/clip paths in its
/// serialized CharacterBootstrap fields, so a restarted Editor only needs the
/// one call: `PlayMotion.Play()`; nothing has to be typed in again by hand.
public static class PlayMotion
{
    public const string ScenePath = "Assets/Scenes/MLTDPlay.unity";

    [MenuItem("MLTD/Play Motion")]
    public static void Play()
    {
        if (File.Exists(ScenePath) && !EditorApplication.isPlaying)
        {
            EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
            EditorApplication.isPlaying = true;
            return;
        }
        BuildAndSaveScene();
        EditorApplication.isPlaying = true;
    }

    /// Rebuilds `MLTDPlay.unity` from the component defaults and the derived
    /// workspace config `$MLTD_WORK/scene.json` written by
    /// `spikes/porting-3d/prepare_work.py`. Run after switching costume or in a
    /// fresh checkout; the paths then live in the scene, not in the code.
    [MenuItem("MLTD/Rebuild Play Scene")]
    public static void BuildAndSaveScene()
    {
        var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        var root = new GameObject("Character");
        var bootstrap = root.AddComponent<CharacterBootstrap>();
        ApplySceneConfig(bootstrap);
        var light = new GameObject("Directional Light").AddComponent<Light>();
        light.type = LightType.Directional;
        light.transform.rotation = Quaternion.Euler(35, -35, 0);
        Directory.CreateDirectory("Assets/Scenes");
        EditorSceneManager.SaveScene(scene, ScenePath);
    }

    [Serializable]
    private sealed class SceneConfig
    {
        public string bundleDirectory;
        public string bodyBundle;
        public string headBundle;
        public string clipPath;   // legacy EULR path, ignored by the native player
        public string facialParamsPath;
        public string motionDirectory;
        public string imoFile;
        public string optionalImoFile;
        public string characterSoulBundle;
        public string shadowBundlePath;
    }

    private static void ApplySceneConfig(CharacterBootstrap bootstrap)
    {
        var root = Environment.GetEnvironmentVariable("MLTD_WORK");
        if (string.IsNullOrEmpty(root))
            root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "mltd-work");
        var configPath = Path.Combine(root, "scene.json");
        if (!File.Exists(configPath)) return;
        var config = JsonUtility.FromJson<SceneConfig>(File.ReadAllText(configPath));
        if (config == null) return;
        if (!string.IsNullOrEmpty(config.bundleDirectory)) bootstrap.bundleDirectory = config.bundleDirectory;
        if (!string.IsNullOrEmpty(config.bodyBundle)) bootstrap.bodyBundle = config.bodyBundle;
        if (!string.IsNullOrEmpty(config.headBundle)) bootstrap.headBundle = config.headBundle;
        // clipPath (packed EULR) is intentionally ignored: ADR-0033 B1 replaced it
        // with the raw-imo player. The motion settings below are the successors.
        if (!string.IsNullOrEmpty(config.motionDirectory)) bootstrap.motionDirectory = config.motionDirectory;
        if (!string.IsNullOrEmpty(config.imoFile)) bootstrap.imoFile = config.imoFile;
        if (!string.IsNullOrEmpty(config.optionalImoFile)) bootstrap.optionalImoFile = config.optionalImoFile;
        if (!string.IsNullOrEmpty(config.characterSoulBundle)) bootstrap.characterSoulBundle = config.characterSoulBundle;
        if (!string.IsNullOrEmpty(config.shadowBundlePath)) bootstrap.shadowBundlePath = config.shadowBundlePath;
        if (!string.IsNullOrEmpty(config.facialParamsPath)) bootstrap.facialParamsPath = config.facialParamsPath;
        Debug.Log("PlayMotion: scene config applied from " + configPath);
    }
}
