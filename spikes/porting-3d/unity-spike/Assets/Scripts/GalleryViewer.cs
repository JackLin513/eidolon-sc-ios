using System.Collections.Generic;
using UnityEngine;

/// 浏览整排角色：左右键（或按钮）切换当前聚焦的人，F 键回到全景。
public sealed class GalleryViewer : MonoBehaviour
{
    private readonly List<Transform> _characters = new List<Transform>();
    private int _current = -1;
    private int _frames;

    private void Update()
    {
        if (_characters.Count == 0 && _frames++ < 120) Collect();

        if (Input.GetKeyDown(KeyCode.RightArrow)) Step(1);
        if (Input.GetKeyDown(KeyCode.LeftArrow)) Step(-1);
        if (Input.GetKeyDown(KeyCode.F)) FitAll();
    }

    private void Collect()
    {
        _characters.Clear();
        foreach (var t in GameObject.FindObjectsOfType<Transform>())
            if (t.name.StartsWith("MLTD_All_") || t.name == "MLTD_Ref")
                _characters.Add(t);
        _characters.Sort((a, b) => a.position.x.CompareTo(b.position.x));
    }

    private void Step(int delta)
    {
        if (_characters.Count == 0) return;
        _current = Mathf.Clamp(_current + delta, 0, _characters.Count - 1);
        Focus(_characters[_current]);
    }

    private void Focus(Transform target)
    {
        var camera = Camera.main;
        if (camera == null) return;
        var framer = camera.GetComponent<BatchViewCamera>();
        if (framer != null) framer.enabled = false;
        camera.transform.position = target.position + new Vector3(0f, 1.2f, -2.2f);
        camera.transform.LookAt(target.position + new Vector3(0f, 0.95f, 0f));
    }

    private void FitAll()
    {
        var camera = Camera.main;
        if (camera == null) return;
        var framer = camera.GetComponent<BatchViewCamera>();
        if (framer == null) return;
        var all = new List<GameObject>();
        foreach (var t in _characters) all.Add(t.gameObject);
        framer.FitTo(all.ToArray());
        framer.enabled = true;
    }

    private void OnGUI()
    {
        var style = new GUIStyle(GUI.skin.label) { fontSize = 18 };
        var y = 10f;
        GUI.Label(new Rect(10, y, 900, 30),
            _current >= 0 && _current < _characters.Count
                ? $"当前：{_characters[_current].name}  (←/→ 切换，F 全景)"
                : $"共 {_characters.Count} 个角色  (←/→ 切换，F 全景)", style);
        y += 34;
        if (GUI.Button(new Rect(10, y, 90, 28), "◀ 上一个")) Step(-1);
        if (GUI.Button(new Rect(106, y, 90, 28), "下一个 ▶")) Step(1);
        if (GUI.Button(new Rect(202, y, 90, 28), "全景")) FitAll();
    }
}
