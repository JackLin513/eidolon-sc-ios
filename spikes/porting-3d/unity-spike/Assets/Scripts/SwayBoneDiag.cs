using System.Globalization;
using System.IO;
using System.Text;
using UnityEngine;

/// Deep diagnostic log for the game-vs-port comparison: per skirt bone and
/// frame it records the world/local/initial rotations plus the parent world
/// rotation and the collision/clamp flags, so the native solver's yaw/pitch can
/// be reconstructed on BOTH sides (the game side is derived from its world
/// rotation using this parent rotation).
public sealed class SwayBoneDiag : MonoBehaviour
{
    public SwayRigNative rig;
    public NativeMotionDriver motion;
    public string outputPath = "/Users/jacklin/mltd-work/out/unity-diag.csv";
    private readonly StringBuilder _sb = new StringBuilder();
    private bool _header;
    private int _frame;
    private float _flushTimer;
    public float windowStart = 20f;
    public float windowEnd = 28f;

    private void LateUpdate()
    {
        if (rig == null || motion == null) { return; }
        var t = motion.PlaybackTime;
        if (t < windowStart || t > windowEnd) { _sb.Length = 0; return; }
        if ((_frame++ & 1) != 0) { return; }

        if (motion.PlaybackTime > 22.8f && motion.PlaybackTime < 24.2f) SwayBoneNative.diagHitOn = true;
        else SwayBoneNative.diagHitOn = false;
        if (SwayBoneNative.diagHit.Length > 0)
        {
            File.AppendAllText("/Users/jacklin/mltd-work/out/hit-diag.txt",
                "t=" + motion.PlaybackTime.ToString("F3") + "\n" + SwayBoneNative.diagHit + "\n");
            SwayBoneNative.diagHit.Length = 0;
        }
        if (!_header)
        {
            _sb.AppendLine("motionT,bone,worldQX,worldQY,worldQZ,worldQW,localQX,localQY,localQZ,localQW," +
                           "parentWQX,parentWQY,parentWQZ,parentWQW,initQX,initQY,initQZ,initQW," +
                           "tipX,tipY,tipZ,baseX,baseY,baseZ,lineHit,sphereHit,clamped," +
                           "aimX,aimY,aimZ,offX,offY,offZ,offW,dirX,dirY,dirZ,tipLocalX,tipLocalY,tipLocalZ,preYaw,prePitch,beforeTipX,beforeTipY,beforeTipZ," +
                           "stiff,gravY,dragMag,forceY,ratio,follow,forceX,forceZ,prevTipX,prevTipY,prevTipZ," +
                           "bTry,bHit,cHit,maxPush,lastD,lastAlong");
            _header = true;
        }

        for (var m = 0; m < rig.managers.Count; m++)
        {
            var mgr = rig.managers[m];
            if (mgr == null || mgr.swayBones == null) continue;
            if (mgr.gameObject == null || mgr.gameObject.name != "skirt_GP") continue;
            for (var i = 0; i < mgr.swayBones.Length; i++)
            {
                var b = mgr.swayBones[i];
                if (b == null || b.trs == null) continue;
                var w = b.trs.rotation;
                var l = b.trs.localRotation;
                var pq = b.trs.parent != null ? b.trs.parent.rotation : Quaternion.identity;
                var iq = b.initialLocalRotation;
                var tip = b.curTipPos;
                var bp = b.trs.position;
                _sb.Append(t.ToString("F3", CultureInfo.InvariantCulture)).Append(',').Append(i).Append(',')
                   .Append(w.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(w.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(w.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(w.w.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(l.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(l.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(l.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(l.w.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(pq.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(pq.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(pq.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(pq.w.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(iq.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(iq.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(iq.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(iq.w.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(tip.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(tip.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(tip.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(bp.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(bp.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(bp.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.lineHitF ? 1 : 0).Append(',')
                   .Append(b.sphereHitF ? 1 : 0).Append(',')
                   .Append(b.diag_clamped ? 1 : 0).Append(',')
                   .Append(b.aimVector.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.aimVector.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.aimVector.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.m_offset_rot.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.m_offset_rot.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.m_offset_rot.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                   .Append(b.m_offset_rot.w.ToString("F4", CultureInfo.InvariantCulture)).Append(',');
                {
                    var ld = b.trs.InverseTransformDirection(b.curTipPos - b.trs.position);
                    var dir = b.m_offset_rot * ld;
                    _sb.Append(dir.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                       .Append(dir.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                       .Append(dir.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',');
                }
                {
                    var tl = b.tipTrs != null ? b.tipTrs.localPosition + b.colliderOffset : Vector3.zero;
                    _sb.Append(tl.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                       .Append(tl.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                       .Append(tl.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.diag_yaw.ToString("F3", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.diag_pitch.ToString("F3", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.diag_tipBefore.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.diag_tipBefore.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.diag_tipBefore.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.diag_stiff.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.diag_grav.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.diag_drag.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.diag_forceY.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.diag_ratio.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.diag_follow.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.force.x.ToString("F6", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.force.z.ToString("F6", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.prevTipPos.x.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.prevTipPos.y.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                       .Append(b.prevTipPos.z.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                       .Append(SwayColliderMT.diagBarrierTry).Append(',')
                       .Append(SwayColliderMT.diagBarrierHit).Append(',')
                       .Append(SwayColliderMT.diagCapsuleHit).Append(',')
                       .Append(SwayColliderMT.diagMaxPush.ToString("F5", CultureInfo.InvariantCulture)).Append(',')
                       .Append(SwayColliderMT.diagLastBarrierD.ToString("F4", CultureInfo.InvariantCulture)).Append(',')
                       .Append(SwayColliderMT.diagLastBarrierAlong.ToString("F4", CultureInfo.InvariantCulture)).AppendLine();

                }
            }
        }

        _flushTimer += Time.unscaledDeltaTime;
        if (_flushTimer > 1f) { _flushTimer = 0f; File.AppendAllText(outputPath, _sb.ToString()); _sb.Length = 0; }
    }
}
