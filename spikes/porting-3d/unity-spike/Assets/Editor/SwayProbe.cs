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
