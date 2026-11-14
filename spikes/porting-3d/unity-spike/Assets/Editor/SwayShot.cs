using UnityEditor;
using UnityEngine;

/// <summary>Reliable screenshot helper (kept from the old probe file; the
/// old SwaySolver/SwayPhysics probes were removed with the legacy solver).</summary>
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
