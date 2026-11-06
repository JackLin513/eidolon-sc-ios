using System.Collections.Generic;
using System.Linq;
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

public static class SwayWeightProbe
{
    /// Dominant bone histogram for the fabric vertices that sit in the front
    /// lower band, where the skirt is supposed to cover the thighs.
    public static string Front(SwaySolver solver)
    {
        var body = solver.GetComponentsInChildren<SkinnedMeshRenderer>(true).FirstOrDefault(r => r.name == "body");
        if (body == null) return "no body";
        var mesh = new Mesh();
        body.BakeMesh(mesh, true);
        var matrix = body.transform.localToWorldMatrix;
        var weights = body.sharedMesh.boneWeights;
        var bones = body.bones;
        var histogram = new Dictionary<string, int>();
        var count = 0;
        for (var i = 0; i < weights.Length && i < mesh.vertices.Length; i++)
        {
            var w = weights[i];
            var best = -1;
            var bestWeight = 0f;
            void Consider(int index, float weight)
            {
                if (weight <= bestWeight) return;
                best = index;
                bestWeight = weight;
            }
            Consider(w.boneIndex0, w.weight0);
            Consider(w.boneIndex1, w.weight1);
            Consider(w.boneIndex2, w.weight2);
            Consider(w.boneIndex3, w.weight3);
            if (best < 0 || bones[best] == null) continue;
            var name = bones[best].name;
            var world = matrix.MultiplyPoint3x4(mesh.vertices[i]);
            if (world.y > 0.78f || world.y < 0.55f) continue;
            if (world.z < 0.02f) continue;
            count++;
            histogram[name] = histogram.ContainsKey(name) ? histogram[name] + 1 : 1;
        }
        Object.DestroyImmediate(mesh);
        var parts = histogram.OrderByDescending(k => k.Value).Take(10).Select(k => k.Key + "=" + k.Value);
        return "fabric(lower)=" + count + " :: " + string.Join(" ", parts);
    }
}

public static class SwayLegProbe
{
    /// Distances of thigh-weighted mesh vertices to the MOMO capsule axis.
    /// If the capsule matches the leg, these bunch around its radius.
    public static string Profile(SwaySolver solver)
    {
        var body = solver.GetComponentsInChildren<SkinnedMeshRenderer>(true).FirstOrDefault(r => r.name == "body");
        if (body == null) return "no body";
        var mesh = new Mesh();
        body.BakeMesh(mesh, true);
        var vertices = mesh.vertices;
        var matrix = body.transform.localToWorldMatrix;
        var source = body.sharedMesh;
        var weights = source.boneWeights;
        var bones = body.bones;

        var results = new List<string>();
        foreach (var name in new[] { "MOMO_L", "MOMO_R" })
        {
            var boneIndex = -1;
            for (var i = 0; i < bones.Length; i++) if (bones[i] != null && bones[i].name == name) boneIndex = i;
            if (boneIndex < 0) { results.Add(name + ": no bone"); continue; }

            var collider = solver.rig.colliders.FirstOrDefault(c => c.joint.name == name && c.data.type == "Capsule");
            if (collider == null) { results.Add(name + ": no collider"); continue; }
            var axis = collider.data.axis == "Y" ? collider.joint.up
                : collider.data.axis == "Z" ? collider.joint.forward : collider.joint.right;
            var center = collider.joint.TransformPoint(collider.data.offset);
            var a = center - axis * (collider.data.distance * 0.5f);
            var b = center + axis * (collider.data.distance * 0.5f);
            var ab = b - a;

            var min = float.MaxValue;
            var max = 0f;
            var count = 0;
            for (var i = 0; i < vertices.Length && i < weights.Length; i++)
            {
                var w = weights[i];
                var total = (w.boneIndex0 == boneIndex ? w.weight0 : 0f) + (w.boneIndex1 == boneIndex ? w.weight1 : 0f)
                          + (w.boneIndex2 == boneIndex ? w.weight2 : 0f) + (w.boneIndex3 == boneIndex ? w.weight3 : 0f);
                if (total < 0.6f) continue;
                var world = matrix.MultiplyPoint3x4(vertices[i]);
                var t = Mathf.Clamp01(Vector3.Dot(world - a, ab) / Mathf.Max(ab.sqrMagnitude, 1e-8f));
                var d = Vector3.Distance(world, a + ab * t);
                if (d < min) min = d;
                if (d > max) max = d;
                count++;
            }
            results.Add($"{name}: verts={count} dist {min:F3}..{max:F3} (collider r={collider.data.radius:F3})");
        }
        Object.DestroyImmediate(mesh);
        return string.Join(" | ", results);
    }
}

/// Measures the actual posed skirt mesh against the leg capsules — the bone
/// tips can look resolved while the fabric between them still cuts the legs.
public static class SwayMeshProbe
{
    public static string Measure(SwaySolver solver)
    {
        var body = solver.GetComponentsInChildren<SkinnedMeshRenderer>(true)
            .FirstOrDefault(r => r.name == "body");
        if (body == null) return "no body renderer";

        var mesh = new Mesh();
        body.BakeMesh(mesh, true);
        var vertices = mesh.vertices;
        var matrix = body.transform.localToWorldMatrix;

        // Only the fabric: vertices whose dominant weight is a skirt bone.
        var source = body.sharedMesh;
        var weights = source.boneWeights;
        var bones = body.bones;
        var fabric = new HashSet<int>();
        for (var i = 0; i < weights.Length && i < vertices.Length; i++)
        {
            var w = weights[i];
            var best = -1;
            var bestWeight = 0f;
            void Consider(int index, float weight)
            {
                if (weight <= bestWeight) return;
                best = index;
                bestWeight = weight;
            }
            Consider(w.boneIndex0, w.weight0);
            Consider(w.boneIndex1, w.weight1);
            Consider(w.boneIndex2, w.weight2);
            Consider(w.boneIndex3, w.weight3);
            if (best >= 0 && bones[best] != null && bones[best].name.StartsWith("skirt_")) fabric.Add(i);
        }

        var penetrations = new List<float>();
        foreach (var collider in solver.rig.colliders)
        {
            if (collider.data.type != "Capsule") continue;
            var axis = collider.data.axis == "Y" ? collider.joint.up
                : collider.data.axis == "Z" ? collider.joint.forward
                : collider.joint.right;
            var center = collider.joint.TransformPoint(collider.data.offset);
            var half = axis * (collider.data.distance * 0.5f);
            var a = center - half;
            var b = center + half;
            var ab = b - a;
            for (var index = 0; index < vertices.Length; index++)
            {
                if (!fabric.Contains(index)) continue;
                var world = matrix.MultiplyPoint3x4(vertices[index]);
                if (world.y < 0.45f || world.y > 0.95f) continue;
                var t = Mathf.Clamp01(Vector3.Dot(world - a, ab) / Mathf.Max(ab.sqrMagnitude, 1e-8f));
                var depth = collider.data.radius - Vector3.Distance(world, a + ab * t);
                if (depth > 0f) penetrations.Add(depth);
            }
        }
        Object.DestroyImmediate(mesh);
        var max = penetrations.Count == 0 ? 0f : penetrations.Max();
        return $"vertsInside={penetrations.Count} maxDepth={max:F4}";
    }
}

/// Renders the game camera straight into a RenderTexture. The Game view in an
/// unfocused editor can serve a stale frame to a screen capture, which makes a
/// skinning change look like it did nothing.
public static class SwayShot
{
    private static string pending;
    private static int pendingSize = 700;

    /// Asks for a shot at the end of the next player-loop frame. Rendering from
    /// a pipeline command runs outside the frame, where the skinned mesh's
    /// skinning buffer has not been updated yet and every shot comes out stale.
    public static string Request(string path, int size = 700)
    {
        pending = path;
        pendingSize = size;
        Application.onBeforeRender -= Pump;
        Application.onBeforeRender += Pump;
        return "queued " + path;
    }

    public static void Pump()
    {
        if (pending == null) return;
        var path = pending;
        pending = null;
        Application.onBeforeRender -= Pump;
        Render(path, pendingSize);
    }

    public static string Render(string path, int size = 700)
    {
        var camera = Camera.main;
        if (camera == null) return "no camera";
        var target = new RenderTexture(size, size, 24);
        var previous = camera.targetTexture;
        var previousAspect = camera.aspect;
        camera.aspect = 1f;
        camera.targetTexture = target;
        camera.Render();
        RenderTexture.active = target;
        var texture = new Texture2D(size, size, TextureFormat.RGB24, false);
        texture.ReadPixels(new Rect(0, 0, size, size), 0, 0);
        texture.Apply();
        System.IO.File.WriteAllBytes(path, texture.EncodeToPNG());
        RenderTexture.active = null;
        camera.targetTexture = previous;
        camera.aspect = previousAspect;
        Object.DestroyImmediate(texture);
        Object.DestroyImmediate(target);
        return "wrote " + path;
    }
}
