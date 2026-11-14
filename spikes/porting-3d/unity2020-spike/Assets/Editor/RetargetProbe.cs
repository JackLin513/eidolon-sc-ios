using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using UnityEditor;
using UnityEditor.Animations;
using UnityEngine;

/// The game's clips are humanoid muscle clips, so `GetCurveBindings` is 0 by
/// design: they have to play through an Animator + Avatar, exactly as the game
/// plays them. This probe does that and renders a frame.
public static class RetargetProbe
{
    public static void Run()
    {
        var characterDir = Environment.GetEnvironmentVariable("MLTD_BUNDLES") ?? "/tmp/mltd-unity-assets";
        var motionDir = Environment.GetEnvironmentVariable("MLTD_MOTIONS") ?? "/tmp/mltd-unity-anims";
        var outDir = Environment.GetEnvironmentVariable("MLTD_OUT") ?? "/tmp/mltd-unity-out";
        Directory.CreateDirectory(outDir);

        var report = new StringBuilder();
        var bodyBundle = AssetBundle.LoadFromFile(Path.Combine(characterDir, "cb_pr001_001har.unity3d"));
        if (bodyBundle == null)
        {
            report.AppendLine("body bundle failed to load");
            Debug.Log(report.ToString());
            return;
        }
        var prefab = bodyBundle.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("cb_"));
        var avatars = bodyBundle.LoadAllAssets<Avatar>();
        report.AppendLine($"avatars {avatars.Length}");
        foreach (var avatar in avatars)
            report.AppendLine(
                $"   avatar {avatar.name} human {avatar.isHuman} valid {avatar.isValid} bones {avatar.humanDescription.skeleton.Length}");

        var body = UnityEngine.Object.Instantiate(prefab);
        body.name = "MODEL_00";
        var animator = body.GetComponent<Animator>() ?? body.AddComponent<Animator>();
        report.AppendLine($"animator avatar {(animator.avatar ? animator.avatar.name : "<none>")}");
        if (animator.avatar == null && avatars.Length > 0) animator.avatar = avatars[0];
        animator.applyRootMotion = false;

        // The clips are split across bundles; find the one that carries this
        // clip rather than guessing by size.
        AnimationClip clip = null;
        var loaded = new List<AssetBundle>();
        foreach (var path in Directory.GetFiles(motionDir, "*.unity3d"))
        {
            var candidate = AssetBundle.LoadFromFile(path);
            if (candidate == null) continue;
            loaded.Add(candidate);
            clip = clip ?? candidate.LoadAllAssets<AnimationClip>()
                .FirstOrDefault(c => c.name == "the_standd_appear_lop_ver01");
        }
        if (clip == null) { report.AppendLine("clip not found"); Debug.Log(report.ToString()); return; }
        report.AppendLine($"clip {clip.name} length {clip.length:F3} humanMotion {clip.isHumanMotion}");

        var controller = AnimatorController.CreateAnimatorControllerAtPath("Assets/Probe.controller");
        controller.AddMotion(clip);
        animator.runtimeAnimatorController = controller;

        foreach (var seconds in new[] { 0.0f, 1.0f, 1.5f })
        {
            var normalised = Mathf.Clamp01(seconds / clip.length);
            animator.Play("the_standd_appear_lop_ver01", 0, normalised);
            animator.Update(0);
            var foot = body.GetComponentsInChildren<Transform>(true).FirstOrDefault(t => t.name == "HIZA_L");
            report.AppendLine($"   t {seconds:F1} state {normalised:F3} HIZA_L {foot.position}");
            Render(body, Path.Combine(outDir, $"retarget-{seconds:F1}.png"));
        }

        File.WriteAllText(Path.Combine(outDir, "retarget-report.txt"), report.ToString());
        Debug.Log(report.ToString());
        UnityEngine.Object.DestroyImmediate(body);
        bodyBundle.Unload(false);
        foreach (var bundle in loaded) bundle.Unload(false);
    }

    private static void Render(GameObject root, string path)
    {
        var renderers = root.GetComponentsInChildren<Renderer>(true);
        if (renderers.Length == 0) return;
        var bounds = renderers[0].bounds;
        foreach (var r in renderers) bounds.Encapsulate(r.bounds);

        var camera = new GameObject("ProbeCamera").AddComponent<Camera>();
        camera.clearFlags = CameraClearFlags.SolidColor;
        camera.backgroundColor = new Color(0.12f, 0.12f, 0.14f);
        camera.fieldOfView = 30;
        var height = Mathf.Max(bounds.size.y, 0.1f);
        var distance = height / (2 * Mathf.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad)) * 1.35f;
        camera.transform.position = bounds.center + new Vector3(0, 0, distance);
        camera.transform.LookAt(bounds.center);

        var light = new GameObject("ProbeLight").AddComponent<Light>();
        light.type = LightType.Directional;
        light.intensity = 1.0f;
        light.transform.rotation = Quaternion.Euler(35, -35, 0);

        var target = new RenderTexture(1024, 1536, 24, RenderTextureFormat.ARGB32);
        camera.targetTexture = target;
        camera.Render();
        RenderTexture.active = target;
        var texture = new Texture2D(target.width, target.height, TextureFormat.RGB24, false);
        texture.ReadPixels(new Rect(0, 0, target.width, target.height), 0, 0);
        texture.Apply();
        File.WriteAllBytes(path, texture.EncodeToPNG());
        RenderTexture.active = null;
        camera.targetTexture = null;

        UnityEngine.Object.DestroyImmediate(camera.gameObject);
        UnityEngine.Object.DestroyImmediate(light.gameObject);
        UnityEngine.Object.DestroyImmediate(target);
        UnityEngine.Object.DestroyImmediate(texture);
    }
}
