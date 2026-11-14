using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using UnityEditor;
using UnityEngine;

/// 打出日常动作 clip 的真实绑定路径，以及角色 prefab 上 Animator/Avatar 的状态。
/// 这两件事决定"clip 能不能绑到我们的骨架上"。
public static class BindingProbe
{
    [MenuItem("MLTD/Probe Clip Bindings")]
    public static void Probe()
    {
        var dir = Path.Combine(
            System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile), "mltd-work/bundles-all");
        var report = new StringBuilder();

        var clipBundle = AssetBundle.LoadFromFile(Path.Combine(dir, "chr_anim_com_001har.unity3d"));
        if (clipBundle == null) { Debug.LogError("MLTD: clip bundle missing"); return; }
        foreach (var clip in clipBundle.LoadAllAssets<AnimationClip>())
        {
            var bindings = AnimationUtility.GetCurveBindings(clip);
            report.AppendLine($"[{clip.name}] curves={bindings.Length} humanMotion={clip.isHumanMotion} legacy={clip.legacy}");
            var seen = new List<string>();
            foreach (var b in bindings)
            {
                var line = $"{b.path}|{b.type?.Name}|{b.propertyName}";
                if (!seen.Contains(line)) seen.Add(line);
            }
            foreach (var line in seen.Take(12)) report.AppendLine("    " + line);
            report.AppendLine($"    ... 共 {seen.Count} 条不同绑定");
        }

        var body = AssetBundle.LoadFromFile(Path.Combine(dir, "cb_ss001_001har.unity3d"));
        if (body != null)
        {
            var prefab = body.LoadAllAssets<GameObject>().FirstOrDefault();
            var animator = prefab != null ? prefab.GetComponentInChildren<Animator>(true) : null;
            report.AppendLine();
            report.AppendLine($"body prefab={prefab?.name} animator={(animator != null)}");
            if (animator != null)
            {
                report.AppendLine($"    avatar={(animator.avatar != null ? animator.avatar.name : "null")} " +
                                  $"human={animator.avatar != null && animator.avatar.isHuman} " +
                                  $"valid={animator.avatar != null && animator.avatar.isValid}");
            }
            var bones = prefab != null
                ? prefab.GetComponentsInChildren<Transform>(true).Select(t => t.name).ToList()
                : new List<string>();
            report.AppendLine($"    bones={bones.Count} 前 12: {string.Join(", ", bones.Take(12))}");
            report.AppendLine($"    含 UDE_L={bones.Contains("UDE_L")} TE_L={bones.Contains("TE_L")} " +
                              $"MUNE_L={bones.Contains("MUNE_L")}");
        }

        File.WriteAllText("/tmp/binding-probe.txt", report.ToString());
        Debug.Log("MLTD: binding probe written");
    }
}
