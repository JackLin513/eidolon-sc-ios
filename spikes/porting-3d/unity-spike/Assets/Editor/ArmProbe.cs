using System.Linq;
using System.Text;
using UnityEngine;

/// Answers "what surface is under this pixel?" by baking the skinned mesh and
/// ray-casting the camera ray through every triangle. Used to tell a shading
/// artifact apart from missing or self-intersecting geometry.
public static class ArmProbe
{
    public static string Hit(string rendererName, int px, int py, int viewW, int viewH)
    {
        var character = GameObject.Find("Character");
        var body = character.GetComponentsInChildren<SkinnedMeshRenderer>(true)
            .First(r => r.name == rendererName);
        var baked = new Mesh();
        body.BakeMesh(baked, true);
        var verts = baked.vertices;
        var norms = baked.normals;
        var tris = baked.triangles;
        var colors = baked.colors;
        var toWorld = body.transform.localToWorldMatrix;

        var subMeshes = new System.Collections.Generic.List<(int start, int count, string mat)>();
        for (var s = 0; s < baked.subMeshCount; s++)
        {
            var d = baked.GetSubMesh(s);
            var mat = body.sharedMaterials.Length > s && body.sharedMaterials[s] != null
                ? body.sharedMaterials[s].name : "-";
            subMeshes.Add((d.indexStart, d.indexCount, mat));
        }

        var cam = Camera.main;
        var ray = cam.ViewportPointToRay(new Vector3((px + 0.5f) / viewW, 1f - (py + 0.5f) / viewH, 0f));
        var o = ray.origin;
        var dir = ray.direction;

        var hits = new System.Collections.Generic.List<(float t, int sub, Vector3 n, Color c, Vector3 p)>();
        for (var i = 0; i < tris.Length; i += 3)
        {
            var a = toWorld.MultiplyPoint3x4(verts[tris[i]]);
            var b = toWorld.MultiplyPoint3x4(verts[tris[i + 1]]);
            var c = toWorld.MultiplyPoint3x4(verts[tris[i + 2]]);
            if (!RayTriangle(o, dir, a, b, c, out var t)) continue;
            var sub = 0;
            for (var s = 0; s < subMeshes.Count; s++)
                if (i >= subMeshes[s].start && i < subMeshes[s].start + subMeshes[s].count) sub = s;
            var n = (Vector3)(toWorld.MultiplyVector(norms[tris[i]]));
            var col = colors.Length > tris[i] ? colors[tris[i]] : Color.magenta;
            hits.Add((t, sub, n, col, o + dir * t));
        }
        hits.Sort((x, y) => x.t.CompareTo(y.t));

        var sb = new StringBuilder();
        sb.Append($"pixel ({px},{py}) ray {o:F3}->{dir:F3} hits={hits.Count}\n");
        for (var i = 0; i < hits.Count && i < 10; i++)
        {
            var h = hits[i];
            sb.Append($"  #{i} t={h.t:F4} p={h.p:F3} sub={h.sub}({subMeshes[h.sub].mat}) n={h.n:F3} nDotView={Vector3.Dot(h.n, dir):F3} vcol={h.c:F2}\n");
        }
        return sb.ToString();
    }

    /// The surface that is actually drawn: the first hit whose winding faces
    /// the camera (back-face culling removes everything else).
    public static string Drawn(string rendererName, int px, int py, int viewW, int viewH)
    {
        var full = Hit(rendererName, px, py, viewW, viewH).Split('\n');
        foreach (var line in full)
            if (line.Contains("nDotView=-") && line.Contains("#"))
                return $"({px},{py}) " + line.Trim();
        return $"({px},{py}) nothing front-facing";
    }

    public static string DrawnGrid(string rendererName, int x0, int y0, int x1, int y1, int step, int viewW, int viewH)
    {
        var sb = new StringBuilder();
        for (var y = y0; y <= y1; y += step)
            for (var x = x0; x <= x1; x += step)
                sb.Append(Drawn(rendererName, x, y, viewW, viewH) + "\n");
        return sb.ToString();
    }

    public static string Grid(string rendererName, int x0, int y0, int x1, int y1, int step, int viewW, int viewH)
    {
        var sb = new StringBuilder();
        for (var y = y0; y <= y1; y += step)
            for (var x = x0; x <= x1; x += step)
                sb.Append(Hit(rendererName, x, y, viewW, viewH));
        return sb.ToString();
    }

    private static bool RayTriangle(Vector3 o, Vector3 d, Vector3 a, Vector3 b, Vector3 c, out float t)
    {
        t = 0f;
        var e1 = b - a;
        var e2 = c - a;
        var p = Vector3.Cross(d, e2);
        var det = Vector3.Dot(e1, p);
        if (Mathf.Abs(det) < 1e-9f) return false;
        var inv = 1f / det;
        var s = o - a;
        var u = Vector3.Dot(s, p) * inv;
        if (u < 0f || u > 1f) return false;
        var q = Vector3.Cross(s, e1);
        var v = Vector3.Dot(d, q) * inv;
        if (v < 0f || u + v > 1f) return false;
        t = Vector3.Dot(e2, q) * inv;
        return t > 1e-5f;
    }
}
