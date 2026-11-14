using System.Globalization;
using System.IO;
using System.Text;
using UnityEngine;

/// Dev probe for the B4 eye-jitter report: samples per frame after
/// EyeTrackingDriver (order 50) so it sees exactly what the renderer gets.
[DefaultExecutionOrder(100)]
public sealed class EyeFlickerProbe : MonoBehaviour
{
    public EyeTracking tracking;
    public string outputPath = "";
    public int maxFrames = 600;
    public bool logEyeTarget = true;

    private readonly StringBuilder _sb = new StringBuilder();
    private int _frames;
    private bool _done;

    public void Bind(EyeTracking eye) => tracking = eye;

    private void LateUpdate()
    {
        if (_done || tracking == null) return;
        if (_frames == 0)
        {
            _sb.AppendLine("frame,t,rx,ry,scale,baseX,baseY,baseZ,camX,camY,camZ,tgtX,tgtY,tgtZ");
        }
        var baseRot = tracking.EyeBase != null ? tracking.EyeBase.eulerAngles : Vector3.zero;
        var cam = Camera.main != null ? Camera.main.transform.position : Vector3.zero;
        var tgt = tracking.EyeTarget != null ? tracking.EyeTarget.position : Vector3.zero;
        _sb.Append(_frames).Append(',')
            .Append(Time.time.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
            .Append(tracking.EyeRX.ToString("F3", CultureInfo.InvariantCulture)).Append(',')
            .Append(tracking.EyeRY.ToString("F3", CultureInfo.InvariantCulture)).Append(',')
            .Append(tracking.scale.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
            .Append(baseRot.x.ToString("F2", CultureInfo.InvariantCulture)).Append(',')
            .Append(baseRot.y.ToString("F2", CultureInfo.InvariantCulture)).Append(',')
            .Append(baseRot.z.ToString("F2", CultureInfo.InvariantCulture)).Append(',')
            .Append(cam.x.ToString("F3", CultureInfo.InvariantCulture)).Append(',')
            .Append(cam.y.ToString("F3", CultureInfo.InvariantCulture)).Append(',')
            .Append(cam.z.ToString("F3", CultureInfo.InvariantCulture)).Append(',')
            .Append(tgt.x.ToString("F3", CultureInfo.InvariantCulture)).Append(',')
            .Append(tgt.y.ToString("F3", CultureInfo.InvariantCulture)).Append(',')
            .Append(tgt.z.ToString("F3", CultureInfo.InvariantCulture)).AppendLine();
        if (++_frames >= maxFrames)
        {
            _done = true;
            if (!string.IsNullOrEmpty(outputPath))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(outputPath));
                File.WriteAllText(outputPath, _sb.ToString());
            }
        }
    }
}
