using UnityEngine;

/// On-screen dance clock so a human can report "clips at t=xx.x s".
/// Demo tool (ADR-0033 probe family); shows the raw-imo player time plus the
/// loop count and the current worst skirt clearance from the telemetry rig.
public sealed class MotionTimeDisplay : MonoBehaviour
{
    public NativeMotionDriver motion;
    public SwayRigNative rig;
    private float _worst;
    private string _worstBone = "";

    private void LateUpdate()
    {
        if (motion == null || rig == null) return;
        float worst = float.PositiveInfinity; string wName = "";
        for (var i = 0; i < rig.bones.Count; i++)
        {
            var b = rig.bones[i];
            if (b == null || b.data == null || !b.data.isSkirt) continue;
            for (var j = 0; j < b.colliders.Length; j++)
            {
                var set = b.colliders[j];
                if (set == null || set.c == null) continue;
                var cc = set.c;
                var axis = cc.m_w_dir.sqrMagnitude > 1e-8f ? cc.m_w_dir.normalized : Vector3.up;
                var half = cc.distance * cc.m_scale * 0.5f;
                var t = Mathf.Clamp(Vector3.Dot(b.curTipPos - cc.m_w_center, axis), -half, half);
                var q = cc.m_w_center + axis * t;
                var d = Vector3.Distance(b.curTipPos, q) - (cc.radius + b.radius);
                if (d < worst) { worst = d; wName = b.transform.name; }
            }
        }
        _worst = worst; _worstBone = wName;
        var loops = motion.Data != null && motion.Data.length > 0f
            ? (int)(motion.PlaybackTime / motion.Data.length) : 0;
        var tt = motion.PlaybackTime % (motion.Data != null && motion.Data.length > 0f ? motion.Data.length : 1f);
    }

    private void OnGUI()
    {
        if (motion == null || motion.Data == null) return;
        var loops = motion.Data.length > 0f ? (int)(motion.PlaybackTime / motion.Data.length) : 0;
        var tt = motion.PlaybackTime % (motion.Data.length > 0f ? motion.Data.length : 1f);
        GUI.Label(new Rect(12f, 8f, 460f, 60f),
            $"第 {loops+1} 遍  t = {tt:F2}s / {motion.Data.length:F1}s\n最差裙间隙 {(_worst*100f):F1}cm ({_worstBone})");
    }
}
