using System.Collections.Generic;
using System.Linq;
using UnityEngine;

/// 给 MLTD 的骨架现场构建一个 humanoid Avatar。
///
/// 游戏里的日常动作（`chr_anim_com_*`）是 humanoid 肌肉动画，但包里的 Avatar 是
/// 通用类型；不换成人形 Avatar，Animator/Playable 一条曲线都绑不上。
public static class HumanoidAvatarBuilder
{
    /// 每个槽位给多个候选骨名，按顺序取第一个存在的。
    private static readonly (string slot, string[] candidates)[] Slots =
    {
        (HumanBodyBones.Hips.ToString(),         new[] { "KOSHI", "koshi", "HARA" }),
        (HumanBodyBones.Spine.ToString(),        new[] { "HARA_ROT1", "MUNE1", "mune1_chn", "HARA" }),
        (HumanBodyBones.Chest.ToString(),        new[] { "MUNE1", "mune1_chn", "MUNE_R" }),
        (HumanBodyBones.Neck.ToString(),         new[] { "KUBI", "kubi_chn", "KUBI_RT__twist_x0" }),
        (HumanBodyBones.Head.ToString(),         new[] { "ATAMA_jnt", "ATAMA", "atama_chn" }),
        (HumanBodyBones.LeftShoulder.ToString(), new[] { "KATA_L", "kata_l_ROT" }),
        (HumanBodyBones.RightShoulder.ToString(),new[] { "KATA_R", "kata_r_ROT" }),
        (HumanBodyBones.LeftUpperArm.ToString(), new[] { "UDE_L_jnt", "UDE_L", "HIJI_L__rot_UDE_L__z50" }),
        (HumanBodyBones.RightUpperArm.ToString(),new[] { "UDE_R_jnt", "UDE_R" }),
        (HumanBodyBones.LeftLowerArm.ToString(), new[] { "TE_L_jnt", "TE_L", "r_te_ROT1" }),
        (HumanBodyBones.RightLowerArm.ToString(),new[] { "TE_R_jnt", "TE_R" }),
        (HumanBodyBones.LeftHand.ToString(),     new[] { "TE_L", "te_l_ROT" }),
        (HumanBodyBones.RightHand.ToString(),    new[] { "TE_R", "te_r_ROT" }),
        (HumanBodyBones.LeftUpperLeg.ToString(), new[] { "MOMO_L_jnt", "MOMO_L", "momo_l_ROT" }),
        (HumanBodyBones.RightUpperLeg.ToString(),new[] { "MOMO_R_jnt", "MOMO_R", "momo_r_ROT" }),
        (HumanBodyBones.LeftLowerLeg.ToString(), new[] { "HIZA_L_jnt", "HIZA_L", "hiza_l_eff" }),
        (HumanBodyBones.RightLowerLeg.ToString(),new[] { "HIZA_R_jnt", "HIZA_R", "hiza_r_eff" }),
        (HumanBodyBones.LeftFoot.ToString(),     new[] { "ASHI_L_jnt", "ASHI_L" }),
        (HumanBodyBones.RightFoot.ToString(),    new[] { "ASHI_R_jnt", "ASHI_R" }),
    };

    public static Avatar Build(GameObject character, out string report)
    {
        var logs = new List<string>();
        Application.LogCallback capture = (condition, stackTrace, type) =>
        {
            if (type == LogType.Error || type == LogType.Warning || type == LogType.Exception)
                logs.Add(type + ": " + condition);
        };
        Application.logMessageReceived += capture;
        try { return BuildCore(character, out report, logs); }
        finally { Application.logMessageReceived -= capture; }
    }

    private static Avatar BuildCore(GameObject character, out string report, List<string> logs)
    {
        var transforms = character.GetComponentsInChildren<Transform>(true);

        // Unity 的 Avatar 按名字匹配骨骼，同名节点会让构建直接判无效。
        // 先把重名改成唯一名（只在运行时改名，不影响资产）。
        var seen = new Dictionary<string, int>();
        foreach (var t in transforms)
        {
            if (!seen.TryGetValue(t.name, out var count)) { seen[t.name] = 1; continue; }
            seen[t.name] = count + 1;
            t.name = $"{t.name}#{count}";
        }

        var byName = new Dictionary<string, Transform>();
        foreach (var t in transforms)
            if (!byName.ContainsKey(t.name)) byName[t.name] = t;

        var skeleton = new List<SkeletonBone>();
        foreach (var t in transforms)
            skeleton.Add(new SkeletonBone
            {
                name = t.name,
                position = t.localPosition,
                rotation = t.localRotation,
                scale = t.localScale,
            });

        var human = new List<HumanBone>();
        var lines = new List<string>();
        foreach (var (slot, candidates) in Slots)
        {
            var picked = candidates.FirstOrDefault(byName.ContainsKey);
            if (picked == null) { lines.Add($"{slot}: (无)"); continue; }
            human.Add(new HumanBone
            {
                boneName = picked,
                humanName = slot,
                limit = new HumanLimit { useDefaultValues = true },
            });
            lines.Add($"{slot}: {picked}");
        }
        report = string.Join("; ", lines);

        var description = new HumanDescription
        {
            skeleton = skeleton.ToArray(),
            human = human.ToArray(),
            upperArmTwist = 0.5f,
            lowerArmTwist = 0.5f,
            upperLegTwist = 0.5f,
            lowerLegTwist = 0.5f,
            armStretch = 0.05f,
            legStretch = 0.05f,
            feetSpacing = 0f,
        };

        var avatar = AvatarBuilder.BuildHumanAvatar(character, description);
        if (avatar == null) { report += " | avatar=null"; return null; }
        if (!avatar.isValid) { report += " | avatar=invalid"; return null; }
        report += $" | avatar ok human={avatar.isHuman}";
        if (logs.Count > 0) report += " | logs: " + string.Join(" / ", logs.GetRange(0, Mathf.Min(3, logs.Count)));
        return avatar;
    }
}
