using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using UnityEditor;
using UnityEngine;

/// Third question for the Unity spike: our packed curves drive the game's own
/// prefab directly. Reads the flat `EULR` dump `tools` writes, sets each
/// transform's local rotation/position, and renders a frame.
public static class DriveProbe
{
    public static void Run()
    {
        var characterDir = Environment.GetEnvironmentVariable("MLTD_BUNDLES") ?? "/tmp/mltd-unity-assets";
        var outDir = Environment.GetEnvironmentVariable("MLTD_OUT") ?? "/tmp/mltd-unity-out";
        var clipPath = Environment.GetEnvironmentVariable("MLTD_CLIP") ?? "/tmp/mltd-unity-out/clip.bin";
        Directory.CreateDirectory(outDir);

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
        var bodyBundle = AssetBundle.LoadFromFile(Path.Combine(characterDir, "cb_pr001_001har.unity3d"));
        var headBundle = AssetBundle.LoadFromFile(Path.Combine(characterDir, "ch_pr001_001har.unity3d"));
        var body = UnityEngine.Object.Instantiate(
            bodyBundle.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("cb_")));
        body.name = "MODEL_00";
        var head = UnityEngine.Object.Instantiate(
            headBundle.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("ch_")));
        var socket = body.GetComponentsInChildren<Transform>(true).First(t => t.name == "ATAMA");
        var headGroup = head.GetComponentsInChildren<Transform>(true).First(t => t.name == "obj_head_GP");
        headGroup.SetParent(socket, false);
        headGroup.localPosition = Vector3.zero;
        headGroup.localRotation = Quaternion.identity;

        var byPath = body.GetComponentsInChildren<Transform>(true)
            .ToDictionary(t => PathOf(t, body.transform), t => t);

        var clip = Clip.Load(clipPath);
        report.AppendLine($"clip frames {clip.Frames} bones {clip.Bones.Count}");

        foreach (var seconds in new[] { 0.0f, 1.0f, 1.5f, 2.0f })
        {
            var frame = Mathf.Clamp(Mathf.RoundToInt(seconds * 30), 0, clip.Frames - 1);
            clip.Apply(frame, byPath, report, seconds == 0.0f);
            Render(body, Path.Combine(outDir, $"drive-{seconds:F1}.png"));
            report.AppendLine($"   frame {frame} rendered {seconds:F1}s");
        }

        var foot = byPath["MODEL_00/BASE/KOSHI/MOMO_L/HIZA_L/ASHI_L/TSUMASAKI_L"];
        report.AppendLine($"world TSUMASAKI_L {foot.position}");

        File.WriteAllText(Path.Combine(outDir, "drive-report.txt"), report.ToString());
        Debug.Log(report.ToString());
        UnityEngine.Object.DestroyImmediate(body);
        UnityEngine.Object.DestroyImmediate(head);
        bodyBundle.Unload(false);
        headBundle.Unload(false);
    }

    private sealed class Clip
    {
        public int Frames;
        public readonly List<(string path, bool hasPos, float[] values)> Bones =
            new List<(string, bool, float[])>();

        public static Clip Load(string path)
        {
            var clip = new Clip();
            using (var reader = new BinaryReader(File.OpenRead(path)))
            {
                if (new string(reader.ReadChars(4)) != "EULR") throw new InvalidDataException("bad magic");
                clip.Frames = reader.ReadInt32();
                var count = reader.ReadInt32();
                for (var i = 0; i < count; i++)
                {
                    var length = reader.ReadUInt16();
                    var name = Encoding.UTF8.GetString(reader.ReadBytes(length));
                    var hasPos = reader.ReadByte() == 1;
                    var floats = (hasPos ? 6 : 3) * clip.Frames;
                    var values = new float[floats];
                    for (var f = 0; f < floats; f++) values[f] = reader.ReadSingle();
                    clip.Bones.Add((name, hasPos, values));
                }
            }
            return clip;
        }

        public void Apply(int frame, Dictionary<string, Transform> byPath, StringBuilder report, bool verbose)
        {
            var stride = 0;
            foreach (var (path, hasPos, values) in Bones)
            {
                stride = hasPos ? 6 : 3;
                // The clips carry a `BODY_SCALE` node the prefab does not have.
                var key = path.Replace("/BODY_SCALE", "");
                if (!byPath.TryGetValue(key, out var transform))
                {
                    if (verbose) report.AppendLine($"   unmapped {path}");
                    continue;
                }
                var at = frame * stride;
                transform.localRotation = Quaternion.Euler(
                    values[at], values[at + 1], values[at + 2]);
                if (hasPos)
                    transform.localPosition = new Vector3(
                        values[at + 3], values[at + 4], values[at + 5]);
            }
        }
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
