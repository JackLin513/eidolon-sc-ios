using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

/// 生成/重建多角色展示场景：场景里只放 GalleryBootstrap，Play 时自动生成角色。
public static class GalleryScene
{
    public const string ScenePath = "Assets/Scenes/MLTDGallery.unity";

    [MenuItem("MLTD/Rebuild Gallery Scene")]
    public static void Build()
    {
        var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        var root = new GameObject("Gallery");
        root.AddComponent<GalleryBootstrap>();
        root.AddComponent<GalleryViewer>();

        var camera = new GameObject("Main Camera").AddComponent<Camera>();
        camera.tag = "MainCamera";
        camera.transform.position = new Vector3(0f, 1.6f, -9f);
        camera.fieldOfView = 38;
        camera.gameObject.AddComponent<BatchViewCamera>();

        var light = new GameObject("Directional Light").AddComponent<Light>();
        light.type = LightType.Directional;
        light.transform.rotation = Quaternion.Euler(35, -35, 0);

        Directory.CreateDirectory("Assets/Scenes");
        EditorSceneManager.SaveScene(scene, ScenePath);
        Debug.Log($"MLTD: gallery scene at {ScenePath}");
    }
}
