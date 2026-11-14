using System.Collections.Generic;
using System.Linq;
using System.Text;
using UnityEngine;

/// Reports which bones actually deform the geometry around a joint, so a
/// missing animation track shows up as bones stuck at bind pose.
public static class ElbowProbe
{
    public static string Bones(string rendererName, string jointName, float radius)
    {
        var character = GameObject.Find("Character");
        var body = character.GetComponentsInChildren<SkinnedMeshRenderer>(true)
            .First(r => r.name == rendererName);
        var joint = character.GetComponentsInChildren<Transform>(true).First(t => t.name == jointName);
        var bind = body.bones;
        var center = joint.position;
        var mesh = new Mesh();
        body.BakeMesh(mesh, true);
        var verts = mesh.vertices;
        var toWorld = body.transform.localToWorldMatrix;
        var weights = body.sharedMesh.boneWeights;

        var tally = new Dictionary<string, float>();
        var count = 0;
        for (var v = 0; v < verts.Length; v++)
        {
            if ((toWorld.MultiplyPoint3x4(verts[v]) - center).magnitude > radius) continue;
            count++;
            var bw = weights[v];
            var ws = new[] { bw.weight0, bw.weight1, bw.weight2, bw.weight3 };
            var bs = new[] { bw.boneIndex0, bw.boneIndex1, bw.boneIndex2, bw.boneIndex3 };
            for (var i = 0; i < 4; i++)
            {
                var w = ws[i];
                if (w <= 0.001f) continue;
                var name = bind[bs[i]].name;
                tally.TryGetValue(name, out var acc);
                tally[name] = acc + w;
            }
        }

        var sb = new StringBuilder();
        sb.Append($"{jointName}: {count} verts within {radius} m\n");
        foreach (var kv in tally.OrderByDescending(k => k.Value))
            sb.Append($"  {kv.Key} {kv.Value:F1}\n");
        return sb.ToString();
    }

    /// Names of bones that own a track in the loaded clip.
    public static string ClipBones()
    {
        var boot = Object.FindObjectOfType<CharacterBootstrap>();
        var clip = boot.Clip;
        return clip == null ? "no clip" : string.Join("\n", clip.Tracks.Select(t => t.Path));
    }
}
