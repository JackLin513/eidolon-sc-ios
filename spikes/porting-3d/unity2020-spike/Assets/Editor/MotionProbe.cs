using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using UnityEditor;
using UnityEngine;

/// Second question for the Unity spike: do the game's own AnimationClips
/// survive the load, and can they drive the prefab the bundles ship?
public static class MotionProbe
{
    public static void Run()
    {
        var characterDir = Environment.GetEnvironmentVariable("MLTD_BUNDLES") ?? "/tmp/mltd-unity-assets";
        var motionDir = Environment.GetEnvironmentVariable("MLTD_MOTIONS") ?? "/tmp/mltd-unity-anims";
        var outDir = Environment.GetEnvironmentVariable("MLTD_OUT") ?? "/tmp/mltd-unity-out";
        Directory.CreateDirectory(outDir);
        var sampleTime = float.Parse(Environment.GetEnvironmentVariable("MLTD_TIME") ?? "1.0");

        Shader.SetGlobalVector("_GuradeParams", new Vector4(0, 1, 0, 1));
        Shader.SetGlobalVector("_FadeColV", Vector4.one);
        Shader.SetGlobalVector("_TheaterColV", Vector4.one);
        Shader.SetGlobalVector("_MonoColor", Vector4.one);
        Shader.SetGlobalVector("_RimCtrl", Vector4.zero);
        Shader.SetGlobalFloat("_Whiteness", 0);
        Shader.SetGlobalFloat("_Luminance", 1);
        Shader.SetGlobalInt("_FogMode", 0);
        Shader.SetGlobalInt("_IsLive", 0);

        var report = new StringBuilder();

        // --- character: body + head, head parented where the body expects it.
        var bodyBundle = AssetBundle.LoadFromFile(Path.Combine(characterDir, "cb_pr001_001har.unity3d"));
        var headBundle = AssetBundle.LoadFromFile(Path.Combine(characterDir, "ch_pr001_001har.unity3d"));
        var bodyPrefab = bodyBundle.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("cb_"));
        var headPrefab = headBundle.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("ch_"));
        var body = UnityEngine.Object.Instantiate(bodyPrefab);
        body.name = "MODEL_00";
        var head = UnityEngine.Object.Instantiate(headPrefab);
        var socket = body.GetComponentsInChildren<Transform>(true)
            .FirstOrDefault(t => t.name == "ATAMA");
        var headGroup = head.GetComponentsInChildren<Transform>(true)
            .FirstOrDefault(t => t.name == "obj_head_GP");
        report.AppendLine($"socket ATAMA {socket?.name ?? "<none>"} headGroup {headGroup?.name ?? "<none>"}");
        if (socket != null && headGroup != null)
        {
            headGroup.SetParent(socket, false);
            headGroup.localPosition = Vector3.zero;
            headGroup.localRotation = Quaternion.identity;
        }

        // --- hierarchy paths, so the clip binding paths can be compared.
        foreach (var t in body.GetComponentsInChildren<Transform>(true).Take(12))
            report.AppendLine($"   node {PathOf(t, body.transform)}");

        // --- clips
        foreach (var path in Directory.GetFiles(motionDir, "*.unity3d").OrderBy(p => p))
        {
            var bundle = AssetBundle.LoadFromFile(path);
            if (bundle == null) { report.AppendLine($"== {Path.GetFileName(path)} LOAD FAILED"); continue; }
            var clips = bundle.LoadAllAssets<AnimationClip>();
            report.AppendLine($"== {Path.GetFileName(path)} clips {clips.Length}");
            foreach (var clip in clips)
            {
                var bindings = AnimationUtility.GetCurveBindings(clip);
                report.AppendLine(
                    $"   clip {clip.name} length {clip.length:F3} fps {clip.frameRate} legacy {clip.legacy} curves {bindings.Length}");
                foreach (var binding in bindings.Take(4))
                    report.AppendLine($"     bind {binding.path} .{binding.propertyName}");
                if (bindings.Length > 0 && sampleTime <= clip.length)
                {
                    // The clip's paths are rooted at MODEL_00, which is what the
                    // instantiated prefab is renamed to.
                    clip.SampleAnimation(body, sampleTime);
                    report.AppendLine($"   sampled {clip.name} at {sampleTime}");
                    var file = Path.Combine(outDir, $"anim-{clip.name}-{sampleTime:F1}.png");
                    Render(body, file);
                    report.AppendLine($"   wrote {Path.GetFileName(file)}");
                }
            }
            bundle.Unload(false);
        }

        File.WriteAllText(Path.Combine(outDir, "motion-report.txt"), report.ToString());
        Debug.Log(report.ToString());
        UnityEngine.Object.DestroyImmediate(body);
        UnityEngine.Object.DestroyImmediate(head);
        bodyBundle.Unload(false);
        headBundle.Unload(false);
    }

    private static string PathOf(Transform transform, Transform root)
    {
        var parts = new List<string>();
        for (var t = transform; t != null && t != root; t = t.parent) parts.Add(t.name);
        parts.Reverse();
        return string.Join("/", parts);
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
        var distance = height / (2 * Mathf.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad)) * 1.25f;
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
