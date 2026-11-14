using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;

/// 验证游戏的做法：AnimatorController（298 段 dummy clip）+ AnimatorOverrideController
/// 把真实动作注入进去，看骨骼是否真的动。
public static class OverrideAnimProbe
{
    public static string Run()
    {
        var sb = new StringBuilder();
        try
        {
            var dir = Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile), "mltd-work/bundles-all");
            AssetBundle Load(string file)
            {
                var name = Path.GetFileName(file);
                var loaded = AssetBundle.GetAllLoadedAssetBundles().FirstOrDefault(b => b.name == name);
                return loaded != null ? loaded : AssetBundle.LoadFromFile(Path.Combine(dir, file));
            }
            var ctrlBundle = Load("chr_anim_ctrl_com.unity3d");
            var bodyBundle = Load("cb_ss001_001har.unity3d");
            var clipBundle = Load("chr_anim_com_001har.unity3d");
            sb.AppendLine($"bundles ctrl={ctrlBundle != null} body={bodyBundle != null} clip={clipBundle != null}");
            if (ctrlBundle == null || bodyBundle == null || clipBundle == null)
            {
                File.WriteAllText("/tmp/mltd-override6.txt", sb.ToString());
                return "bundle 缺失";
            }

            var controller = ctrlBundle.LoadAllAssets<RuntimeAnimatorController>().FirstOrDefault();
            sb.AppendLine($"controller={(controller != null ? controller.name : "null")} clips={(controller != null ? controller.animationClips.Length : 0)}");

            var real = clipBundle.LoadAllAssets<AnimationClip>().FirstOrDefault(c => c.name.Contains("_act"));
            sb.AppendLine($"realClip={(real != null ? real.name : "null")} len={(real != null ? real.length : 0f):F2}");

            var body = Object.Instantiate(bodyBundle.LoadAllAssets<GameObject>()[0]);
            var animator = body.GetComponentInChildren<Animator>(true);
            if (animator == null) { sb.AppendLine("no animator"); File.WriteAllText("/tmp/mltd-override6.txt", sb.ToString()); return "no animator"; }
            sb.AppendLine($"avatar={(animator.avatar != null ? animator.avatar.name : "null")} isHuman={(animator.avatar != null && animator.avatar.isHuman)}");

            var ov = new AnimatorOverrideController(controller);
            var pairs = new List<KeyValuePair<AnimationClip, AnimationClip>>();
            ov.GetOverrides(pairs);
            for (var i = 0; i < pairs.Count; i++)
                pairs[i] = new KeyValuePair<AnimationClip, AnimationClip>(pairs[i].Key, real);
            ov.ApplyOverrides(pairs);
            sb.AppendLine($"overrides={pairs.Count}");

            animator.runtimeAnimatorController = ov;
            var index = new Dictionary<string, Transform>();
            foreach (var t in body.GetComponentsInChildren<Transform>(true))
                if (!index.ContainsKey(t.name)) index[t.name] = t;

            var graph = PlayableGraph.Create("ov-probe");
            var output = AnimationPlayableOutput.Create(graph, "anim", animator);
            var playable = AnimatorControllerPlayable.Create(graph, ov);
            output.SetSourcePlayable(playable);
            graph.Play();

            var watched = new[] { "UDE_L", "TE_L", "MUNE1", "KOSHI" };
            var first = new Dictionary<string, Quaternion>();
            var maxA = new Dictionary<string, float>();
            const int steps = 30;
            for (var s = 0; s <= steps; s++)
            {
                playable.SetTime(1.83f * s / steps);
                graph.Evaluate(0f);
                foreach (var n in watched)
                {
                    if (!index.TryGetValue(n, out var t)) continue;
                    if (s == 0) { first[n] = t.localRotation; maxA[n] = 0f; continue; }
                    var a = Quaternion.Angle(first[n], t.localRotation);
                    if (a > maxA[n]) maxA[n] = a;
                }
            }
            sb.Append("result:");
            foreach (var n in watched)
                if (maxA.TryGetValue(n, out var a)) sb.Append($" {n}={a:F1}°");
            sb.AppendLine();
            graph.Destroy();
            File.WriteAllText("/tmp/mltd-override6.txt", sb.ToString());
            return "ok";
        }
        catch (System.Exception e)
        {
            File.WriteAllText("/tmp/mltd-override6.txt", e.ToString());
            return "err " + e.Message;
        }
    }
}
