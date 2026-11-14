using System.Collections.Generic;
using System.IO;
using System.Text;
using UnityEditor;
using UnityEngine;

/// 用 Unity 2020 打开游戏的 2018 版 bundle，把 AnimationClip 的曲线导成 JSON。
public static class BundleCurveExport
{
    public static void Run()
    {
        var bundlePath = "/Users/jacklin/mltd-work/bundles-all/chr_anim_com_001har.unity3d";
        var outPath = "/tmp/chr_anim_curves.json";
        var bundle = AssetBundle.LoadFromFile(bundlePath);
        if (bundle == null) { File.WriteAllText(outPath, "{\"error\":\"bundle load failed\"}"); return; }

        var clips = bundle.LoadAllAssets<AnimationClip>();
        var sb = new StringBuilder();
        sb.Append("{\"clips\":[");
        var first = true;
        foreach (var clip in clips)
        {
            var bindings = AnimationUtility.GetCurveBindings(clip);
            if (!first) sb.Append(",");
            first = false;
            sb.Append("{\"name\":\"").Append(clip.name).Append("\",\"length\":").Append(clip.length).Append(",\"curves\":[");
            var firstCurve = true;
            foreach (var b in bindings)
            {
                var curve = AnimationUtility.GetEditorCurve(clip, b);
                if (curve == null) continue;
                if (!firstCurve) sb.Append(",");
                firstCurve = false;
                sb.Append("{\"path\":\"").Append(b.path).Append("\",\"property\":\"").Append(b.propertyName).Append("\",\"keys\":[");
                for (var i = 0; i < curve.length; i++)
                {
                    var k = curve.keys[i];
                    if (i > 0) sb.Append(",");
                    sb.Append("[").Append(k.time).Append(",").Append(k.value).Append("]");
                }
                sb.Append("]}");
            }
            sb.Append("]}");
            Debug.Log($"MLTD clip {clip.name}: {bindings.Length} curves");
        }
        sb.Append("]}");
        File.WriteAllText(outPath, sb.ToString());
        Debug.Log($"MLTD wrote {outPath}");
    }
}
