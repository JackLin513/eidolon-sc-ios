using UnityEngine;

/// 逐帧采样一个 AnimationClip 到本角色的骨架上。
///
/// 游戏的日常动作（`chr_anim_com_*` 里的 clip）是 Mecanim 的 Generic 轨道，
/// 老的 `Animation` 组件播不动（legacy 标志为 false，静默无效果）。这里用
/// `SampleAnimation` 直接按路径写 transform，简单可靠，也不依赖 Avatar。
public sealed class ClipSampler : MonoBehaviour
{
    public AnimationClip clip;
    public float speed = 1f;
    public bool loop = true;

    private float _time;

    private void LateUpdate()
    {
        if (clip == null) return;
        _time += Time.deltaTime * speed;
        var length = clip.length;
        if (length <= 0f) return;
        if (loop) _time %= length;
        else _time = Mathf.Min(_time, length);
        clip.SampleAnimation(gameObject, _time);
    }
}
