using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;

/// 用 Animator + PlayableGraph 播游戏的日常动作片段，并统计骨骼变化。
///
/// 之前用 AnimationClip.SampleAnimation 播，腿动了但手臂保持 T-pose；
/// 这里换成游戏实际用的 Animator 管线（Playable），看是不是采样方式的锅。
public static class ClipPlayableProbe
{
    private static readonly string[] Bones =
    {
        "MUNE_L", "MUNE_R", "UDE_L", "UDE_R", "TE_L", "TE_R",
        "MOMO_L", "MOMO_R", "SUNE_L", "SUNE_R", "ASHI_L", "ASHI_R",
        "BASE", "KOSHI", "KUBI", "ATAMA"
    };

    public static string Run(string bundlePath, string characterName = "Character")
    {
        var bundle = AssetBundle.GetAllLoadedAssetBundles()
            .FirstOrDefault(b => b.name == Path.GetFileName(bundlePath)) ?? AssetBundle.LoadFromFile(bundlePath);
        if (bundle == null) return "bundle 加载失败";

        // 场景里的 "Character" 只是 bootstrap 的壳，真正的骨架在它下面某处（或兄弟节点），
        // 所以按"哪个根节点里含 MODEL_00 且子节点最多"来找。
        GameObject character = null;
        var best = 0;
        foreach (var t in GameObject.FindObjectsOfType<Transform>())
        {
            if (t.parent != null) continue;
            var count = t.GetComponentsInChildren<Transform>(true).Length;
            if (count <= best) continue;
            var hasModel = false;
            foreach (var child in t.GetComponentsInChildren<Transform>(true))
                if (child.name == "MODEL_00") { hasModel = true; break; }
            if (!hasModel) continue;
            best = count;
            character = t.gameObject;
        }
        if (character == null) character = GameObject.Find(characterName);
        if (character == null) return $"找不到 {characterName}";

        // 身体 prefab 自带 Animator；Avatar 必须建在它所在的那个节点上，
        // 建在外层壳（Character）上会判无效。
        var animator = character.GetComponentInChildren<Animator>(true);
        if (animator == null)
        {
            animator = character.GetComponent<Animator>();
            if (animator == null) animator = character.AddComponent<Animator>();
        }
        var rigRoot = animator.gameObject;
        animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
        animator.enabled = true;

        // 关键一步：换成现场构建的 humanoid Avatar，否则肌肉动画绑不上。
        var avatar = HumanoidAvatarBuilder.Build(rigRoot, out var avatarReport);
        string avatarInfo;
        if (avatar != null)
        {
            animator.avatar = avatar;
            animator.Rebind();
            avatarInfo = "avatar=humanoid valid";
        }
        else
        {
            avatarInfo = "avatar=build failed";
        }
        animator.Rebind();

        var allTransforms = rigRoot.GetComponentsInChildren<Transform>(true);
        var index = new Dictionary<string, Transform>();
        foreach (var t in allTransforms)
            if (!index.ContainsKey(t.name)) index[t.name] = t;
        var diag = $"character={character.name} rig={rigRoot.name} transforms={allTransforms.Length} " +
                   $"hasUDE_L={index.ContainsKey("UDE_L")} hasTE_L={index.ContainsKey("TE_L")}";

        var graph = PlayableGraph.Create("MLTD clip probe");
        var output = AnimationPlayableOutput.Create(graph, "clip", animator);
        var mixer = AnimationMixerPlayable.Create(graph, 1);
        output.SetSourcePlayable(mixer);

        var report = new StringBuilder();
        foreach (var clip in bundle.LoadAllAssets<AnimationClip>())
        {
            var playable = AnimationClipPlayable.Create(graph, clip);
            playable.SetApplyFootIK(false);
            graph.Connect(playable, 0, mixer, 0);
            mixer.SetInputWeight(0, 1f);
            graph.Play();

            var first = new Dictionary<string, Quaternion>();
            var maxAngle = new Dictionary<string, float>();
            const int steps = 24;
            for (var step = 0; step <= steps; step++)
            {
                var t = clip.length * step / steps;
                playable.SetTime(t);
                graph.Evaluate(0f);
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

            graph.Disconnect(mixer, 0);
        }

        graph.Destroy();
        File.WriteAllText("/tmp/clip-playable-probe.txt",
            diag + "\n" + avatarInfo + "\n" + avatarReport + "\n\n" + report.ToString());
        return "ok";
    }
}
