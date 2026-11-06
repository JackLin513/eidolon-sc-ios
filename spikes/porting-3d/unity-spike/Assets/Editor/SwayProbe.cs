using System.Text;
using UnityEditor;
using UnityEngine;

/// Verification helpers for the sway/skirt port.
public static class SwayProbe
{
    [MenuItem("MLTD/Sway: describe")]
    public static void Describe()
    {
        var solver = Object.FindObjectOfType<SwaySolver>();
        Debug.Log(solver == null ? "SwayProbe: no SwaySolver" : "SwayProbe: " + solver.Describe());
    }

    /// Smallest distance from any skirt tip to a collider surface; negative
    /// means the tip is inside a collider.
    public static float Clearance(SwaySolver solver)
    {
        var worst = float.MaxValue;
        foreach (var bone in solver.rig.skirtBones)
        {
            foreach (var collider in bone.colliders)
            {
                var axis = collider.data.axis == "Y" ? collider.joint.up
                    : collider.data.axis == "Z" ? collider.joint.forward
                    : collider.joint.right;
                var center = collider.joint.TransformPoint(collider.data.offset);
                var half = axis * (collider.data.distance * 0.5f);
                var a = center - half;
                var b = center + half;
                var ab = b - a;
                var t = Mathf.Clamp01(Vector3.Dot(bone.curTipPos - a, ab) / Mathf.Max(ab.sqrMagnitude, 1e-8f));
                var distance = Vector3.Distance(bone.curTipPos, a + ab * t) - (collider.data.radius + bone.data.radius);
                if (distance < worst) worst = distance;
            }
        }
        return worst;
    }

    [MenuItem("MLTD/Sway: settle 120 steps")]
    public static void Settle()
    {
        var solver = Object.FindObjectOfType<SwaySolver>();
        if (solver == null) { Debug.Log("SwayProbe: no SwaySolver"); return; }
        for (var i = 0; i < 120; i++) solver.StepOnce(1f / 60f);
        var text = new StringBuilder("SwayProbe settle: ");
        foreach (var bone in solver.rig.skirtBones)
        {
            var down = (bone.tip != null ? bone.tip.position : bone.transform.position) - bone.transform.position;
            text.Append(bone.transform.name).Append(" tipDir=").Append(down.normalized.ToString("F2")).Append(' ');
        }
        Debug.Log(text.ToString());
    }
}
