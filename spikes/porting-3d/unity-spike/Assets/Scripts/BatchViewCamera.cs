using UnityEngine;

/// Keeps the camera framing every spawned character, whatever else in the scene
/// wants to move it (the bootstrap scene has its own close-up camera).
public sealed class BatchViewCamera : MonoBehaviour
{
    public Vector3 min = new Vector3(-6f, 0f, 0f);
    public Vector3 max = new Vector3(6f, 1.7f, 8f);

    public void FitTo(GameObject[] characters)
    {
        if (characters == null || characters.Length == 0) return;
        var lo = new Vector3(float.MaxValue, float.MaxValue, float.MaxValue);
        var hi = new Vector3(float.MinValue, float.MinValue, float.MinValue);
        foreach (var go in characters)
        {
            foreach (var renderer in go.GetComponentsInChildren<Renderer>())
            {
                lo = Vector3.Min(lo, renderer.bounds.min);
                hi = Vector3.Max(hi, renderer.bounds.max);
            }
        }
        lo.y = 0f;
        min = lo;
        max = hi;
    }

    private void LateUpdate()
    {
        var camera = GetComponent<Camera>();
        if (camera == null) return;
        var center = (min + max) * 0.5f;
        var width = Mathf.Max(max.x - min.x, 1f);
        var height = Mathf.Max(max.y - min.y, 1f);
        var distance = Mathf.Max(width / (2f * Mathf.Tan(camera.fieldOfView * Mathf.Deg2Rad * camera.aspect * 0.5f)),
                                 height / (2f * Mathf.Tan(camera.fieldOfView * Mathf.Deg2Rad * 0.5f)));
        camera.transform.position = new Vector3(center.x, center.y + height * 0.15f, min.z - distance * 1.15f);
        camera.transform.LookAt(center);
        camera.farClipPlane = Mathf.Max(camera.farClipPlane, distance * 3f);
    }
}
