using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using UnityEngine;

/// 探针：逐段采样日常动作 clip，统计"哪些骨骼真的动了"。
/// 用来判断持物/手臂 T-pose 是 clip 本来就没动手臂，还是绑定没生效。
public static class ClipProbeRuntime
{
    private static readonly string[] Bones =
    {
        "MUNE_L", "MUNE_R", "UDE_L", "UDE_R", "TE_L", "TE_R",      // 手臂
        "MOMO_L", "MOMO_R", "SUNE_L", "SUNE_R", "ASHI_L", "ASHI_R", // 腿
        "BASE", "KOSHI", "KUBI", "ATAMA"                            // 躯干/头
    };

    public static void Probe()
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "mltd-work/bundles-all");
        var path = Path.Combine(dir, "chr_anim_com_001har.unity3d");
        var bundle = AssetBundle.GetAllLoadedAssetBundles()
            .FirstOrDefault(b => b.name == Path.GetFileName(path)) ?? AssetBundle.LoadFromFile(path);
        if (bundle == null) { Debug.LogError("MLTD: clip bundle missing"); return; }

        var character = GameObject.Find("MLTD_Ref") ?? GameObject.Find("Character");
        if (character == null) { Debug.LogError("MLTD: no character in scene"); return; }

        var index = new Dictionary<string, Transform>();
        foreach (var t in character.GetComponentsInChildren<Transform>(true))
            if (!index.ContainsKey(t.name)) index[t.name] = t;

        var report = new StringBuilder();
        foreach (var clip in bundle.LoadAllAssets<AnimationClip>())
        {
            var first = new Dictionary<string, Quaternion>();
            var maxAngle = new Dictionary<string, float>();
            const int steps = 24;
            for (var step = 0; step <= steps; step++)
            {
                clip.SampleAnimation(character, clip.length * step / steps);
                foreach (var name in Bones)
                {
                    if (!index.TryGetValue(name, out var bone)) continue;
                    if (step == 0) { first[name] = bone.localRotation; maxAngle[name] = 0f; continue; }
                    var angle = Quaternion.Angle(first[name], bone.localRotation);
                    if (angle > maxAngle[name]) maxAngle[name] = angle;
                }
            }
            report.AppendLine($"[{clip.name}] length={clip.length:F2}s");
            foreach (var name in Bones)
                if (maxAngle.TryGetValue(name, out var angle))
                    report.AppendLine($"    {name,-8} maxΔ={angle:F1}°");
        }
        File.WriteAllText("/tmp/clip-probe.txt", report.ToString());
        Debug.Log("MLTD: clip probe written to /tmp/clip-probe.txt");
    }
}
