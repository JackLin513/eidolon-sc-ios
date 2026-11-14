using UnityEngine;

/// Drives `EyeTracking.EyeUpdate` once per frame. Native has no Update on
/// EyeTracking: `JointBodyHead`/`CharacterDrawer` call EyeUpdate after the pose
/// and face pass. The spike wires the same order here (this component's
/// LateUpdate runs after motion/CalcBone/sway because those already finished in
/// their own LateUpdate/Update passes; see ADR-0033 B4).
[DefaultExecutionOrder(50)]
public sealed class EyeTrackingDriver : MonoBehaviour
{
    public EyeTracking tracking;

    public void Bind(EyeTracking target) => tracking = target;

    private void LateUpdate()
    {
        if (tracking == null) return;
        // EyeUpdate computes eyeTargetPos from the native EyeType and the
        // DanceIdolInfo nodes; screenRatioV is pinned to the 1280x720 reference
        // in CharacterBootstrap (the eye atlas samples the iris/highlight
        // directly, so scaling it by an arbitrary Game view aspect turns the
        // eyes black). Do not override the target here.
        tracking.EyeUpdate();
    }
}
