using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;

/// 用一副标准命名的骨架验证 clip 数据本身是否有内容。
/// 骨架构造成功率高，能把"clip 有问题"和"MTLD 骨架映射有问题"分开。
public static class SyntheticHumanoidProbe
{
    private static readonly (string name, string human, string parent, Vector3 offset)[] Rig =
    {
        ("Hips", "Hips", null, new Vector3(0, 0.9f, 0)),
        ("Spine", "Spine", "Hips", new Vector3(0, 0.1f, 0)),
        ("Chest", "Chest", "Spine", new Vector3(0, 0.15f, 0)),
        ("Neck", "Neck", "Chest", new Vector3(0, 0.15f, 0)),
        ("Head", "Head", "Neck", new Vector3(0, 0.1f, 0)),
        ("LeftShoulder", "LeftShoulder", "Chest", new Vector3(-0.08f, 0.12f, 0)),
        ("LeftUpperArm", "LeftUpperArm", "LeftShoulder", new Vector3(-0.12f, 0, 0)),
        ("LeftLowerArm", "LeftLowerArm", "LeftUpperArm", new Vector3(-0.25f, 0, 0)),
        ("LeftHand", "LeftHand", "LeftLowerArm", new Vector3(-0.22f, 0, 0)),
        ("RightShoulder", "RightShoulder", "Chest", new Vector3(0.08f, 0.12f, 0)),
        ("RightUpperArm", "RightUpperArm", "RightShoulder", new Vector3(0.12f, 0, 0)),
        ("RightLowerArm", "RightLowerArm", "RightUpperArm", new Vector3(0.25f, 0, 0)),
        ("RightHand", "RightHand", "RightLowerArm", new Vector3(0.22f, 0, 0)),
        ("LeftUpperLeg", "LeftUpperLeg", "Hips", new Vector3(-0.09f, -0.05f, 0)),
        ("LeftLowerLeg", "LeftLowerLeg", "LeftUpperLeg", new Vector3(0, -0.42f, 0)),
        ("LeftFoot", "LeftFoot", "LeftLowerLeg", new Vector3(0, -0.40f, 0)),
        ("RightUpperLeg", "RightUpperLeg", "Hips", new Vector3(0.09f, -0.05f, 0)),
        ("RightLowerLeg", "RightLowerLeg", "RightUpperLeg", new Vector3(0, -0.42f, 0)),
        ("RightFoot", "RightFoot", "RightLowerLeg", new Vector3(0, -0.40f, 0)),
    };

    public static string Run(string clipBundlePath)
    {
        var bundle = AssetBundle.GetAllLoadedAssetBundles()
            .FirstOrDefault(b => b.name == Path.GetFileName(clipBundlePath))
            ?? AssetBundle.LoadFromFile(clipBundlePath);
        if (bundle == null) return "clip bundle 加载失败";

        var root = new GameObject("SyntheticRig");
        var map = new Dictionary<string, Transform>();
        foreach (var (name, _, parent, offset) in Rig)
        {
            var go = new GameObject(name);
            go.transform.SetParent(parent == null ? root.transform : map[parent], false);
            go.transform.localPosition = offset;
            map[name] = go.transform;
        }

        // 命名和 humanName 一致，Avatar 构建的成功率高得多。
        var skeleton = Rig.Select(r => new SkeletonBone
        {
            name = r.name,
            position = map[r.name].localPosition,
            rotation = Quaternion.identity,
            scale = Vector3.one,
        }).ToArray();
        var humanBones = Rig.Select(r => new HumanBone
        {
            boneName = r.name,
            humanName = r.human,
            limit = new HumanLimit { useDefaultValues = true },
        }).ToArray();

        var avatar = AvatarBuilder.BuildHumanAvatar(root, new HumanDescription
        {
            skeleton = skeleton,
            human = humanBones,
            upperArmTwist = 0.5f,
            lowerArmTwist = 0.5f,
            upperLegTwist = 0.5f,
            lowerLegTwist = 0.5f,
            armStretch = 0.05f,
            legStretch = 0.05f,
            feetSpacing = 0f,
        });
        if (avatar == null || !avatar.isValid) return "标准骨架 Avatar 构建失败（意外）";

        var animator = root.AddComponent<Animator>();
        animator.avatar = avatar;
        animator.enabled = true;

        var graph = PlayableGraph.Create("synthetic");
        var output = AnimationPlayableOutput.Create(graph, "clip", animator);
        var mixer = AnimationMixerPlayable.Create(graph, 1);
        output.SetSourcePlayable(mixer);

        var watched = new[] { "LeftUpperArm", "LeftLowerArm", "RightUpperArm", "RightLowerArm", "Chest", "Head" };
        var report = new StringBuilder();
        foreach (var clip in bundle.LoadAllAssets<AnimationClip>())
        {
            var playable = AnimationClipPlayable.Create(graph, clip);
            graph.Connect(playable, 0, mixer, 0);
            mixer.SetInputWeight(0, 1f);
            graph.Play();

            var first = new Dictionary<string, Quaternion>();
            var maxAngle = new Dictionary<string, float>();
            const int steps = 24;
            for (var step = 0; step <= steps; step++)
            {
                playable.SetTime(clip.length * step / steps);
                graph.Evaluate(0f);
                foreach (var name in watched)
                {
                    if (!map.TryGetValue(name, out var bone)) continue;
                    if (step == 0) { first[name] = bone.localRotation; maxAngle[name] = 0f; continue; }
                    var angle = Quaternion.Angle(first[name], bone.localRotation);
                    if (angle > maxAngle[name]) maxAngle[name] = angle;
                }
            }
            report.AppendLine($"[{clip.name}]");
            foreach (var name in watched)
                if (maxAngle.TryGetValue(name, out var a))
                    report.AppendLine($"    {name,-14} maxΔ={a:F1}°");
            graph.Disconnect(mixer, 0);
        }
        graph.Destroy();
        File.WriteAllText("/tmp/synthetic-probe.txt", report.ToString());
        return "ok";
    }
}
