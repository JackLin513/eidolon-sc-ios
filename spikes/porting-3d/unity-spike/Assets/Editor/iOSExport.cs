using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;

/// iOS 导出（M1：先把 Unity-as-a-Library 要用的 Xcode 工程导出来）。
///
/// 用法（批处理）：
///   Unity -batchmode -quit -projectPath <本项目> -buildTarget iOS \
///         -executeMethod iOSExport.Build -logFile <log>
/// 产出：build/ios-export/Unity-iPhone.xcodeproj（含 UnityFramework target）。
public static class iOSExport
{
    private const string ScenePath = "Assets/Scenes/StandScene.unity";
    private const string OutputDir = "build/ios-export";
    private const string BundleId = "com.jacklin.eidolon3dspike";

    [MenuItem("MLTD/Export iOS Xcode Project")]
    public static void ExportMenu() => Build();

    /// 模拟器变体（M2 验证用）：SDK 切到 SimulatorSDK，产出可跑在 iOS Simulator 的
    /// UnityFramework，不需要真机信任。
    public static void BuildSimulator()
    {
        EnsureStandScene();
        ConfigurePlayer();
        PlayerSettings.iOS.sdkVersion = iOSSdkVersion.SimulatorSDK;
        // Unity 默认给模拟器出 x86_64，但 Apple Silicon 上的 simulator 要 arm64；
        // Unity 的自带库（baselib/UnityRuntime）必须与 framework 架构一致。
        PlayerSettings.iOS.simulatorSdkArchitecture = AppleMobileArchitectureSimulator.ARM64;
        BuildInternal("build/ios-export-sim", "SIMULATOR");
    }

    public static void Build()
    {
        EnsureStandScene();
        ConfigurePlayer();
        PlayerSettings.iOS.sdkVersion = iOSSdkVersion.DeviceSDK;
        BuildInternal(OutputDir, "DEVICE");
    }

    private static void BuildInternal(string outputDir, string tag)
    {

        var options = new BuildPlayerOptions
        {
            scenes = new[] { ScenePath },
            locationPathName = outputDir,
            target = BuildTarget.iOS,
            options = BuildOptions.None,
        };
        var report = BuildPipeline.BuildPlayer(options);
        var summary = report.summary;
        var message = $"IOS EXPORT ({tag}) RESULT: {summary.result} errors={summary.totalErrors} warnings={summary.totalWarnings} " +
                      $"size={summary.totalSize} output={summary.outputPath}";
        Debug.Log(message);
        File.WriteAllText(Path.Combine("build", $"ios-export-result-{tag.ToLowerInvariant()}.txt"), message);
        if (summary.result != BuildResult.Succeeded)
        {
            EditorApplication.Exit(1);
        }
    }

    /// 3D 立绘场景：相机 + 平行光 + EidolonStandHost。每次导出都重建，保证场景里
    /// 一定有宿主组件（旧版本只建空 GameObject）。
    public static void EnsureStandScene()
    {
        AssetDatabase.Refresh();
        Directory.CreateDirectory("Assets/Scenes");
        var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        var cameraObject = new GameObject("Main Camera");
        var camera = cameraObject.AddComponent<Camera>();
        // Transparent clear so the iOS view behind the Unity layer can show through
        // (the call page's own backdrop). Alpha is ignored while the view is opaque.
        camera.clearFlags = CameraClearFlags.SolidColor;
        camera.backgroundColor = new Color(0.09f, 0.09f, 0.11f, 0f);
        camera.fieldOfView = 30f;
        cameraObject.transform.position = new Vector3(0f, 1f, 2.6f);
        cameraObject.transform.LookAt(new Vector3(0f, 0.95f, 0f));
        cameraObject.tag = "MainCamera";
        var lightObject = new GameObject("Directional Light");
        var light = lightObject.AddComponent<Light>();
        light.type = LightType.Directional;
        light.intensity = 1.1f;
        lightObject.transform.rotation = Quaternion.Euler(35f, 200f, 0f);
        var host = new GameObject("EidolonStandHost");
        host.AddComponent<EidolonStandHost>();
        EditorSceneManager.SaveScene(scene, ScenePath);
        AssetDatabase.Refresh();
    }

    private static void ConfigurePlayer()
    {
        PlayerSettings.companyName = "JackLin";
        PlayerSettings.productName = "EidolonStand";
        PlayerSettings.SetApplicationIdentifier(BuildTargetGroup.iOS, BundleId);
        PlayerSettings.SetScriptingBackend(BuildTargetGroup.iOS, ScriptingImplementation.IL2CPP);
        PlayerSettings.SetArchitecture(BuildTargetGroup.iOS, 1); // arm64 only
        PlayerSettings.iOS.targetOSVersionString = "16.0";
        PlayerSettings.iOS.appleEnableAutomaticSigning = false;
        PlayerSettings.iOS.appleDeveloperTeamID = string.Empty;
        PlayerSettings.iOS.allowHTTPDownload = true;
        // The game ships Gamma (PlayerSettings.m_ActiveColorSpace = 0) and its character
        // shaders do no colour-space conversion, so their maths runs on sRGB values.
        // Rendering them in Linear darkens the mid-tones and shifts every hue.
        PlayerSettings.colorSpace = ColorSpace.Gamma;
        PlayerSettings.stripEngineCode = true;
        EditorUserBuildSettings.buildAppBundle = false;
        var scenes = EditorBuildSettings.scenes.ToList();
        if (scenes.All(s => s.path != ScenePath))
        {
            scenes.Insert(0, new EditorBuildSettingsScene(ScenePath, true));
            EditorBuildSettings.scenes = scenes.ToArray();
        }
    }
}
