using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

/// Puts the game's own character prefab into the open scene so it can be
/// orbited in the Scene view. Nothing is saved: the instances come from
/// AssetBundles, which a scene cannot reference.
public static class ShowCharacter
{
    private const string RequestFile = "../unity-spike.request";

    [InitializeOnLoadMethod]
    private static void Queue()
    {
        EditorApplication.delayCall += Auto;
    }

    private static void Auto()
    {
        var request = Path.GetFullPath(Path.Combine(Application.dataPath, RequestFile));
        if (!File.Exists(request)) return;
        File.Delete(request);
        Show();
    }

    [MenuItem("MLTD/Show Character")]
    public static void Show()
    {
        var dir = Environment.GetEnvironmentVariable("MLTD_BUNDLES") ?? "/tmp/mltd-unity-assets";

        Shader.SetGlobalVector("_GuradeParams", new Vector4(0, 1, 0, 1));
        Shader.SetGlobalVector("_FadeColV", Vector4.one);
        Shader.SetGlobalVector("_TheaterColV", Vector4.one);
        Shader.SetGlobalVector("_MonoColor", Vector4.one);
        Shader.SetGlobalVector("_RimCtrl", Vector4.zero);
        Shader.SetGlobalFloat("_Whiteness", 0);
        Shader.SetGlobalFloat("_Luminance", 1);
        Shader.SetGlobalInt("_FogMode", 0);
        Shader.SetGlobalInt("_IsLive", 0);

        foreach (var existing in GameObject.FindObjectsOfType<Transform>())
            if (existing.name.StartsWith("cb_") || existing.name.StartsWith("ch_") || existing.name == "MLTD_Character")
                UnityEngine.Object.DestroyImmediate(existing.gameObject);

        // A bundle cannot be loaded twice in one process; reuse the open one.
        AssetBundle Load(string file)
        {
            var bundle = AssetBundle.GetAllLoadedAssetBundles()
                .FirstOrDefault(b => b.name == file);
            return bundle != null ? bundle : AssetBundle.LoadFromFile(Path.Combine(dir, file));
        }
        var bodyBundle = Load("cb_pr001_001har.unity3d");
        var headBundle = Load("ch_pr001_001har.unity3d");
        if (bodyBundle == null || headBundle == null)
        {
            Debug.LogError($"MLTD: bundles not found in {dir}");
            return;
        }
        var body = UnityEngine.Object.Instantiate(
            bodyBundle.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("cb_")));
        body.name = "MLTD_Character";
        // The head is a second, self-contained prefab: its own `KUBI → ATAMA →
        // HAIR` skeleton drives its own skinned meshes (34 bones, names the body
        // does not have). It therefore goes in at the *model* level, next to the
        // body's `MODEL_00`, not under the body's ATAMA — parenting the head's
        // mesh group alone leaves every skin bone null and the head floats.
        var head = UnityEngine.Object.Instantiate(
            headBundle.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("ch_")));
        head.name = "ch_head";
        head.transform.SetParent(body.transform.Find("MODEL_00"), false);
        head.transform.localPosition = Vector3.zero;
        head.transform.localRotation = Quaternion.identity;
        head.transform.localScale = Vector3.one;

        if (Camera.main == null)
        {
            var camera = new GameObject("Main Camera").AddComponent<Camera>();
            camera.tag = "MainCamera";
            // The model faces +Z.
            camera.transform.position = new Vector3(0, 1.0f, 2.6f);
            camera.transform.LookAt(new Vector3(0, 0.95f, 0));
        }
        if (GameObject.FindObjectsOfType<Light>().Length == 0)
        {
            var light = new GameObject("Directional Light").AddComponent<Light>();
            light.type = LightType.Directional;
            light.transform.rotation = Quaternion.Euler(35, -35, 0);
        }
        Selection.activeGameObject = body;
        SceneView.lastActiveSceneView?.FrameSelected();
        Debug.Log("MLTD: character in scene (body + head), Game view needs Play to drive it");
    }
}
