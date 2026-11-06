using System.Linq;
using UnityEngine;

/// Drapes the character's skirt over the animated legs.
///
/// The sway data the game ships (`<character>_sway`) drives ribbons, hair and
/// the skirt through its own solver; the one part that matters for the outfit
/// here is the skirt, and the game's rule for it is written into the outfit's
/// own bone names: `COMANECI_L__slerp_MOMO_L__i70_x0` — "slerp toward MOMO_L
/// at 70%". The skirt fabric is partly skinned to the thighs (about a quarter
/// of the front band's vertices), so when the legs swing the fabric around
/// them follows while the panels that are skinned to the skirt bones do not,
/// and the surface tears open over the thighs.
///
/// So every skirt panel takes 70% of its thigh's rotation, measured relative to
/// the pelvis so the pelvis's own motion is not applied twice. Parameters come
/// from the game (the 70% rule, the bone-to-thigh pairing); nothing is tuned.
[DefaultExecutionOrder(-40)]
public sealed class SwaySolver : MonoBehaviour
{
    public const float FixedDelta = 0.016666668f;
    public const float MaxDelta = 0.025000002f;

    /// How much of the thigh's swing a skirt panel follows.
    public float legFollow = 0.7f;

    public SwayFile file;
    public SwayRig rig;

    public void Bind(SwayFile swayFile)
    {
        file = swayFile;
        rig = SwayRig.Build(swayFile, transform);
        foreach (var bone in rig.bones) bone.initialLocalRotation = bone.restLocalRotation;
        var hip = rig.bones.FirstOrDefault(x => x.transform.name == "KOSHI");
        if (hip != null) rig.BuildSkirtRing(hip.transform.position);
    }

    private void LateUpdate()
    {
        if (rig == null) return;
        Drape();
    }

    /// Rotates every skirt panel by `legFollow` of its thigh's swing.
    public void Drape()
    {
        if (rig == null) return;
        var pelvis = rig.pelvis;
        if (pelvis == null || rig.thighL == null || rig.thighR == null) return;

        var pelvisInverse = Quaternion.Inverse(pelvis.rotation);
        var left = rig.thighL.rotation * pelvisInverse;
        var right = rig.thighR.rotation * pelvisInverse;

        foreach (var bone in rig.skirtBones)
        {
            var name = bone.transform.name;
            var delta = name.Contains("_L") ? left : name.Contains("_R") ? right : Quaternion.Slerp(left, right, 0.5f);
            var parent = bone.transform.parent;
            var bindWorld = (parent != null ? parent.rotation : Quaternion.identity) * bone.initialLocalRotation;
            bone.transform.rotation = Quaternion.Slerp(Quaternion.identity, delta, legFollow) * bindWorld;
        }
    }

    /// One deterministic step, for verification from the editor.
    public void StepOnce(float deltaTime) => Drape();

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
