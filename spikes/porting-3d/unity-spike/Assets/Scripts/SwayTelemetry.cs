using System.Globalization;
using System.Text;
using System.IO;
using UnityEngine;

/// Goal telemetry: logs EVERY LateUpdate across the whole dance — per-frame
/// skirt-vs-thigh clearance (worst over all skirt bones), OPAI quaternion
/// continuity vs the previous frame, and the motion player's time. One CSV row
/// per frame, flushed continuously so a frozen loop is visible in the data.
public sealed class SwayTelemetry : MonoBehaviour
{
    public SwayRigNative rig;
    public NativeMotionDriver motion;
    public UnityEngine.Transform opaiL;
    public UnityEngine.Transform ribbon;
    public SwayBoneNative ribbonBone;
    private Quaternion _prevOpai = Quaternion.identity;
    private bool _prevValid;
    private readonly StringBuilder _sb = new StringBuilder();
    private bool _header;
    public string outputPath = "/Users/jacklin/mltd-work/out/sway-telemetry.csv";
    private float _flushTimer;

    private void LateUpdate()
    {
        if (!_header)
        {
            _sb.AppendLine("frame,time,worstClear,worstBone,dotOpai,motionT,ribX,ribY,tipX,tipY,tipZ");
            _header = true;
        }

        float worst = float.PositiveInfinity;
        string worstName = "";
        if (rig != null)
        {
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
                    if (d < worst) { worst = d; worstName = b.transform.name; }
                }
            }
        }

        float dot = 1f;
        if (opaiL != null)
        {
            var q = opaiL.localRotation;
            if (_prevValid) dot = Mathf.Abs(Quaternion.Dot(q, _prevOpai));
            _prevOpai = q;
            _prevValid = true;
        }

        var rb = ribbonBone;
        _sb.Append(Time.frameCount).Append(',')
           .Append(Time.time.ToString("F3", CultureInfo.InvariantCulture)).Append(',')
           .Append(worst.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
           .Append(worstName).Append(',')
           .Append(dot.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(motion != null ? motion.PlaybackTime.ToString("F2", CultureInfo.InvariantCulture) : "0").Append(',')
           .Append(rb != null && rb.trs != null ? rb.trs.position.x.ToString("F3", CultureInfo.InvariantCulture) : "0").Append(',')
           .Append(rb != null && rb.trs != null ? rb.trs.position.y.ToString("F3", CultureInfo.InvariantCulture) : "0").Append(',')
           .Append(rb != null ? rb.curTipPos.x.ToString("F3", CultureInfo.InvariantCulture) : "0").Append(',')
           .Append(rb != null ? rb.curTipPos.y.ToString("F3", CultureInfo.InvariantCulture) : "0").Append(',')
           .Append(rb != null ? rb.curTipPos.z.ToString("F3", CultureInfo.InvariantCulture) : "0")
           .AppendLine();

        _flushTimer += Time.unscaledDeltaTime;
        if (_flushTimer > 2f)
        {
            _flushTimer = 0f;
            File.AppendAllText(outputPath, _sb.ToString());
            _sb.Length = 0;
        }
    }
}
