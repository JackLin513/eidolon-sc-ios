using System;
using System.Linq;
using UnityEngine;

/// 播放游戏里的日常动作（`chr_anim_com_<idol>.unity3d` 里的 AnimationClip）。
///
/// 这些是对话/日常用的动作，不是舞蹈，很适合一套衣服一套衣服地看姿态。
/// 片段是 Generic 轨道按 Transform 路径绑定的，所以同一段动作能套到所有角色身上。
public static class DailyMotionPlayer
{
    public static string Play(string bundlePath, string clipName = "act", float speed = 1f)
    {
        var bundle = AssetBundle.GetAllLoadedAssetBundles()
            .FirstOrDefault(b => b.name == System.IO.Path.GetFileName(bundlePath));
        if (bundle == null) bundle = AssetBundle.LoadFromFile(bundlePath);
        if (bundle == null) return "bundle 加载失败";

        var clips = bundle.LoadAllAssets<AnimationClip>();
        if (clips == null || clips.Length == 0) return "没有 AnimationClip";

        var wanted = string.IsNullOrEmpty(clipName)
            ? clips[0]
            : clips.FirstOrDefault(c => c.name.EndsWith("_" + clipName, StringComparison.OrdinalIgnoreCase))
              ?? clips[0];

        var character = GameObject.Find("Character");
        if (character == null) return "没有 Character";

        // 老 Animation 组件播不动非 legacy 的 Generic clip，用逐帧采样。
        var sampler = character.GetComponent<ClipSampler>();
        if (sampler == null) sampler = character.AddComponent<ClipSampler>();
        sampler.clip = wanted;
        sampler.speed = speed;
        return $"播放 {wanted.name}（共 {clips.Length} 段，逐帧采样）";
    }
}
