using System.Globalization;
using System.IO;
using System.Text;
using UnityEngine;

/// Ground-truth comparable log: every skirt bone's tip + base in the skirt_GP
/// manager's NATIVE bone-array order, stamped with the dance time. The game-side
/// Frida capture records the same fields from the same array, so the two CSVs
/// can be joined on danceTime.
public sealed class SwayBoneLog : MonoBehaviour
{
    public SwayRigNative rig;
    public NativeMotionDriver motion;
    public string outputPath = "/Users/jacklin/mltd-work/out/unity-bones.csv";
    private readonly StringBuilder _sb = new StringBuilder();
    private bool _header;
    private int _frame;
    private float _flushTimer;

    private void LateUpdate()
    {
        if (rig == null || motion == null) return;
        if ((_frame++ & 1) != 0) return;   // every 2nd frame, same as the game capture

        if (!_header)
        {
            _sb.AppendLine("motionT,mgr,bone,tipX,tipY,tipZ,baseX,baseY,baseZ,qx,qy,qz,qw,lqx,lqy,lqz,lqw");
            _header = true;
        }

        for (var m = 0; m < rig.managers.Count; m++)
        {
            var mgr = rig.managers[m];
            if (mgr == null || mgr.swayBones == null) continue;
            var n = mgr.swayBones.Length;
            if (n < 15 || n > 64) continue;   // skirt (20) or hair (17) managers
            var mgrName = mgr.gameObject != null ? mgr.gameObject.name : "mgr";
            for (var i = 0; i < n; i++)
            {
                var b = mgr.swayBones[i];
                if (b == null || b.trs == null) continue;
                var tip = b.curTipPos;
                var bp = b.trs.position;
                _sb.Append(motion.PlaybackTime.ToString("F3", CultureInfo.InvariantCulture)).Append(',')
                   .Append(mgrName).Append(',').Append(i).Append(',')
                   .Append(tip.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(tip.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(tip.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(bp.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(bp.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(bp.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.trs.rotation.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.trs.rotation.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.trs.rotation.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.trs.rotation.w.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.trs.localRotation.x.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.trs.localRotation.y.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.trs.localRotation.z.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.trs.localRotation.w.ToString("F5", CultureInfo.InvariantCulture)).AppendLine();
            }
        }

        _flushTimer += Time.unscaledDeltaTime;
        if (_flushTimer > 2f)
        {
            _flushTimer = 0f;
            File.AppendAllText(outputPath, _sb.ToString());
            _sb.Length = 0;
        }
    }
}
