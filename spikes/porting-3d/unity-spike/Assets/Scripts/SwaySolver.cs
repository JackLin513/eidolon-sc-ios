using UnityEngine;

/// Runs the game's sway/skirt solve on the instantiated character.
///
/// The parameters and the bone/collider graph come from the character's own
/// `<name>_sway` TextAsset; this class only carries the per-frame state.
/// The numeric core is filled in from the game's own solver
/// (`Imas.BoneLib.SwayBoneMT`), not from the earlier hand-tuned prototype.
public sealed class SwaySolver : MonoBehaviour
{
    public SwayFile file;
    public SwayRig rig;

    private float time;

    public void Bind(SwayFile swayFile)
    {
        file = swayFile;
        rig = SwayRig.Build(swayFile, transform);
        Initialize();
    }

    private void Initialize()
    {
    }

    private void LateUpdate()
    {
        if (rig == null) return;
        Step(Time.deltaTime);
    }

    private void Step(float deltaTime)
    {
        time += deltaTime;
    }

    /// One deterministic step, for verification from the editor.
    public void StepOnce(float deltaTime) => Step(deltaTime);

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
