using System.Collections.Generic;
using UnityEngine;

/// Copies one character's skeleton pose onto another each frame.
///
/// Driving 50 characters with 50 copies of the imo playback would mean 50x the
/// curve memory; instead one reference character plays the motion and the rest
/// mirror its bones by hierarchy path. Same skeleton layout per costume, so the
/// path map covers the body; bones a costume does not share simply stay as
/// authored.
public sealed class PosePuppet : MonoBehaviour
{
    public Transform reference;
    public int matched;

    private Transform[] _targets;
    private Transform[] _sources;

    private void Start()
    {
        Build();
    }

    private int _framesWithoutTargets;

    /// Rebuild the path map (call after the reference rig is built/rebuilt).
    public void Build()
    {
        if (reference == null)
        {
            var root = GameObject.Find("Character");
            if (root != null) reference = root.transform;
        }
        if (reference == null) return;

        var index = new Dictionary<string, Transform>();
        foreach (var t in reference.GetComponentsInChildren<Transform>(true))
            index[Path(t)] = t;

        var targets = new List<Transform>();
        var sources = new List<Transform>();
        foreach (var t in GetComponentsInChildren<Transform>(true))
        {
            if (index.TryGetValue(Path(t), out var source) && source != t)
            {
                targets.Add(t);
                sources.Add(source);
            }
        }
        _targets = targets.ToArray();
        _sources = sources.ToArray();
        matched = _targets.Length;
    }

    /// 从 `MODEL_00` 开始算路径：参考角色和木偶的根节点名字不同
    /// （Character / MLTD_All_*），拿整条路径当 key 会一个都匹配不上。
    private static string Path(Transform t)
    {
        var stack = new List<string>();
        Transform anchor = null;
        for (var cur = t; cur != null; cur = cur.parent)
            if (cur.name == "MODEL_00") anchor = cur;
        // 从 t 往上走到 MODEL_00 为止（含），再反过来 —— 之前写成从 anchor 继续往上，等于没走到子节点。
        for (var cur = t; cur != null; cur = cur.parent)
        {
            stack.Add(cur.name);
            if (cur == anchor) break;
        }
        stack.Reverse();
        return string.Join("/", stack);
    }

    private void LateUpdate()
    {
        if (_targets == null || _targets.Length == 0)
        {
            // 参考角色可能比木偶晚一帧准备好（运行时时序），重试几次就好。
            if (_framesWithoutTargets++ < 120) Build();
            if (_targets == null || _targets.Length == 0) return;
        }
        for (var i = 0; i < _targets.Length; i++)
        {
            var source = _sources[i];
            var target = _targets[i];
            target.localPosition = source.localPosition;
            target.localRotation = source.localRotation;
            target.localScale = source.localScale;
        }
    }
}
