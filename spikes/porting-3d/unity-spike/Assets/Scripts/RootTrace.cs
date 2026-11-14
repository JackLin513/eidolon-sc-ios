using System.Globalization;
using System.IO;
using System.Text;
using UnityEngine;

/// Records the runtime BASE / MODEL_00 rotation of the character so it can be
/// compared quaternion-to-quaternion against the live game capture (no Euler
/// reconstruction involved).
public sealed class RootTrace : MonoBehaviour
{
    public NativeMotionDriver motion;
    public string outputPath = "/Users/jacklin/mltd-work/out/unity-base.csv";
    private readonly StringBuilder _sb = new StringBuilder();
    private Transform _base;
    private Transform _model;
    private bool _header;
    private float _flush;

    private void LateUpdate()
    {
        if (motion == null) return;
        if (_base == null)
        {
            foreach (var t in GetComponentsInChildren<Transform>(true))
            {
                if (t.name == "BASE" && _base == null) _base = t;
                if (t.name == "MODEL_00" && _model == null) _model = t;
            }
        }
        if (_base == null) return;

        if (!_header)
        {
            _sb.AppendLine("t,bx,by,bz,bw,mx,my,mz,mw,px,py,pz");
            _header = true;
        }
        var b = _base.localRotation;
        var m = _model != null ? _model.localRotation : Quaternion.identity;
        var p = _base.position;
        _sb.Append(motion.PlaybackTime.ToString("F3", CultureInfo.InvariantCulture)).Append(',')
           .Append(b.x.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(b.y.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(b.z.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(b.w.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(m.x.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(m.y.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(m.z.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(m.w.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
           .Append(p.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
           .Append(p.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
           .Append(p.z.ToString("F4", CultureInfo.InvariantCulture)).AppendLine();

        _flush += Time.unscaledDeltaTime;
        if (_flush > 2f) { _flush = 0f; File.AppendAllText(outputPath, _sb.ToString()); _sb.Length = 0; }
    }
}
