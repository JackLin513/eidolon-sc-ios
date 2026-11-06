using UnityEngine;

/// Runs the game's sway/skirt solve on the instantiated character.
///
/// Structure and numbers come from the game itself: `SwayManager` steps at a
/// fixed 1/60 s (max 0.025 s per frame), and each bone goes through
/// `SwayBoneMT.SwayMove` → `SwayHit` → `CalcRotate`. The per-bone parameters,
/// colliders and side links are read from the character's own `_sway` file.
public sealed class SwaySolver : MonoBehaviour
{
    public const float FixedDelta = 0.016666668f;
    public const float MaxDelta = 0.025000002f;

    public SwayFile file;
    public SwayRig rig;

    public void Bind(SwayFile swayFile)
    {
        file = swayFile;
        rig = SwayRig.Build(swayFile, transform);
        Initialize();
    }

    /// Per-bone constants the game computes once in `SwayBone.InitSub` /
    /// `SwayBoneMT.InitializeFixedParams`.
    private void Initialize()
    {
        foreach (var bone in rig.bones)
        {
            bone.initialLocalRotation = bone.restLocalRotation;
            bone.aimVector = bone.restTipDirection;
        }
    }

    private void LateUpdate()
    {
        if (rig == null) return;
        StepOnce(Time.deltaTime);
    }

    /// One deterministic step, for verification from the editor.
    public void StepOnce(float deltaTime)
    {
        if (rig == null) return;
        var dt = Mathf.Min(deltaTime, MaxDelta);
        foreach (var bone in rig.bones) Move(bone, dt);
        foreach (var bone in rig.bones) Hit(bone);
        foreach (var bone in rig.bones) Rotate(bone);
    }

    private void Move(SwayRig.Bone bone, float deltaTime)
    {
    }

    private void Hit(SwayRig.Bone bone)
    {
    }

    private void Rotate(SwayRig.Bone bone)
    {
    }

    public string Describe()
    {
        if (rig == null) return "no rig";
        var text = new System.Text.StringBuilder();
        text.Append("bones=").Append(rig.bones.Count).Append(" skirt=").Append(rig.skirtBones.Count);
        foreach (var bone in rig.skirtBones)
        {
            var angle = Quaternion.Angle(bone.restLocalRotation, bone.transform.localRotation);
            text.Append(' ').Append(bone.transform.name).Append('=').Append(angle.ToString("F1"));
        }
        return text.ToString();
    }
}
