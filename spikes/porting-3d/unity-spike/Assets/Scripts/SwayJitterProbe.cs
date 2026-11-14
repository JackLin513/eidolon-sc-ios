using System.Globalization;
using System.IO;
using System.Text;
using UnityEngine;

/// Phase-0 diagnostic: samples a sway bone's world position AND local rotation
/// per frame. Demo tool (ADR-0033 probe family).
public sealed class SwayJitterProbe : MonoBehaviour
{
    public Transform opai;
    public Transform skirt;
    private readonly StringBuilder _sb = new StringBuilder();
    private int _n;
    private bool _header;

    private void LateUpdate()
    {
        if (!_header) { _sb.AppendLine("frame,qw,qx,qy,qz,ox,oy,oz"); _header = true; }
        var q = opai != null ? opai.localRotation : Quaternion.identity;
        var o = opai != null ? opai.position : Vector3.zero;
        _sb.Append(Time.frameCount).Append(',')
           .Append(q.w.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(q.x.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(q.y.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(q.z.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(o.x.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(o.y.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(o.z.ToString("F5", CultureInfo.InvariantCulture)).AppendLine();
        if (++_n >= 180)
        {
            File.WriteAllText("/Users/jacklin/mltd-work/out/jitter-rot.csv", _sb.ToString());
            enabled = false;
        }
    }
}
