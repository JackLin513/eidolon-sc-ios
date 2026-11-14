using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using UnityEditor;
using UnityEngine;

/// Loads the game's own character bundles and renders them, so the spike can
/// answer one question: does Unity take these assets as they are?
/// Run with `-executeMethod BundleProbe.Run`.
public static class BundleProbe
{
    public static void Run()
    {
        var dir = Environment.GetEnvironmentVariable("MLTD_BUNDLES") ?? "/tmp/mltd-unity-assets";
        var outDir = Environment.GetEnvironmentVariable("MLTD_OUT") ?? "/tmp/mltd-unity-out";
        Directory.CreateDirectory(outDir);

        // The game sets these globals each frame; at their zero default the
        // character shaders multiply the whole figure to black
        // (`COLOR0.z = min(g.x + g.y, 1)` with `_GuradeParams = 0`).
        Shader.SetGlobalVector("_GuradeParams", new Vector4(0, 1, 0, 1));
        Shader.SetGlobalInt("_FogMode", 0);
        Shader.SetGlobalInt("_IsLive", 0);
        Shader.SetGlobalFloat("_Whiteness", 0);
        // `out.rgb = col * _FadeColV.rgb` — the fade multiplier defaults to
        // zero as well.
        Shader.SetGlobalVector("_FadeColV", Vector4.one);
        Shader.SetGlobalVector("_TheaterColV", Vector4.one);
        Shader.SetGlobalVector("_MonoColor", Vector4.one);
        Shader.SetGlobalVector("_RimCtrl", Vector4.zero);
        Shader.SetGlobalFloat("_Luminance", 1);

        var report = new StringBuilder();
        var shaders = new HashSet<Shader>();
        foreach (var path in Directory.GetFiles(dir, "*.unity3d").OrderBy(p => p))
        {
            var file = Path.GetFileNameWithoutExtension(path);
            report.AppendLine($"== {file}");
            var bundle = AssetBundle.LoadFromFile(path);
            if (bundle == null)
            {
                report.AppendLine("   LOAD FAILED");
                continue;
            }
            foreach (var name in bundle.GetAllAssetNames())
                report.AppendLine($"   asset {name}");

            var all = bundle.LoadAllAssets<GameObject>();
            report.AppendLine($"   gameobjects {all.Length}");
            // The prefab is the one whose name matches the bundle and that owns
            // the whole hierarchy; the rest are its parts.
            var prefab = all.FirstOrDefault(g => g.name == file)
                ?? all.OrderByDescending(g => g.GetComponentsInChildren<Transform>(true).Length).First();
            report.AppendLine($"   prefab {prefab.name} nodes {prefab.GetComponentsInChildren<Transform>(true).Length}");

            var root = UnityEngine.Object.Instantiate(prefab);
            root.name = file;
            foreach (var renderer in root.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                var mesh = renderer.sharedMesh;
                report.AppendLine(
                    $"     smr {PathOf(renderer.transform)} bones {renderer.bones?.Length} mesh {mesh?.name} verts {mesh?.vertexCount} shapes {mesh?.blendShapeCount}");
                foreach (var material in renderer.sharedMaterials)
                {
                    if (material == null) { report.AppendLine("       mat <null>"); continue; }
                    shaders.Add(material.shader);
                    report.AppendLine(
                        $"       mat {material.name} shader {material.shader?.name} supported {material.shader?.isSupported}");
                    for (var i = 0; i < material.shader.GetPropertyCount(); i++)
                    {
                        var name = material.shader.GetPropertyName(i);
                        var type = material.shader.GetPropertyType(i);
                        if (type == UnityEngine.Rendering.ShaderPropertyType.Texture)
                        {
                            var tex = material.GetTexture(name);
                            report.AppendLine($"         prop {name} tex {(tex ? tex.name + " " + tex.width + "x" + tex.height : "<null>")}");
                        }
                        else if (type == UnityEngine.Rendering.ShaderPropertyType.Color)
                            report.AppendLine($"         prop {name} {material.GetColor(name)}");
                        else if (type == UnityEngine.Rendering.ShaderPropertyType.Float)
                            report.AppendLine($"         prop {name} {material.GetFloat(name)}");
                        else if (type == UnityEngine.Rendering.ShaderPropertyType.Vector)
                            report.AppendLine($"         prop {name} {material.GetVector(name)}");
                    }
                }
            }
            Render(root, Path.Combine(outDir, file + ".png"));
            // Same geometry through Unity's own Standard shader: if this one
            // lights up and the game's does not, the black is the shader's
            // global state, not the render setup.
            var standard = Shader.Find("Standard");
            var fallback = new Material(standard);
            foreach (var r in root.GetComponentsInChildren<Renderer>(true))
            {
                var mats = new Material[r.sharedMaterials.Length];
                for (var i = 0; i < mats.Length; i++) mats[i] = fallback;
                r.sharedMaterials = mats;
            }
            Render(root, Path.Combine(outDir, file + "-standard.png"));
            UnityEngine.Object.DestroyImmediate(root);
            bundle.Unload(false);
        }

        foreach (var shader in shaders)
        {
            if (shader == null) continue;
            report.AppendLine($"   shader {shader.name} supported {shader.isSupported} error {ShaderUtil.ShaderHasError(shader)}");
        }

        File.WriteAllText(Path.Combine(outDir, "report.txt"), report.ToString());
        Debug.Log(report.ToString());
    }

    private static string PathOf(Transform transform)
    {
        var parts = new List<string>();
        for (var t = transform; t != null; t = t.parent) parts.Add(t.name);
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
        var distance = height / (2 * Mathf.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad)) * 1.2f;
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
