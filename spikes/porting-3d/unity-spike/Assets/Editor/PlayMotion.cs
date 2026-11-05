using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

/// Menu entry that builds a playable scene for the spike and enters Play mode.
public static class PlayMotion
{
    [MenuItem("MLTD/Play Motion")]
    public static void Play()
    {
        var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        var root = new GameObject("Character");
        root.AddComponent<CharacterBootstrap>();
        var light = new GameObject("Directional Light").AddComponent<Light>();
        light.type = LightType.Directional;
        light.transform.rotation = Quaternion.Euler(35, -35, 0);
        Directory.CreateDirectory("Assets/Scenes");
        EditorSceneManager.SaveScene(scene, "Assets/Scenes/MLTDPlay.unity");
        EditorApplication.isPlaying = true;
    }
}
