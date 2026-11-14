using UnityEngine;

/// Demo camera: sits in front of the character and follows the POSITION node,
/// so stage placement in the dance imo does not leave the frame. Demo-only —
/// the native camera is a Live/stage system (out of scope, ADR-0033 B6).
public sealed class FrontFollow : MonoBehaviour
{
    public Transform model;
    public float height = 0.95f;
    public float distance = 2.6f;

    private UnityEngine.Camera _cam;

    private void Start()
    {
        _cam = GetComponent<Camera>();
        if (_cam != null) _cam.depth = (UnityEngine.Camera.main != null ? UnityEngine.Camera.main.depth - 1 : 0);
    }

    private void LateUpdate()
    {
        if (model == null) return;
        var p = model.position;
        // Follow the model's FACING (MODEL_00 rotates with the dance), so the
        // camera stays in front of her instead of being swallowed by a flared
        // skirt when she turns.
        var fwd = model.forward; fwd.y = 0f;
        if (fwd.sqrMagnitude < 1e-6f) fwd = Vector3.forward;
        fwd.Normalize();
        transform.position = p + fwd * distance + new Vector3(0f, height, 0f);
        transform.LookAt(p + new Vector3(0f, height - 0.05f, 0f));
    }
}
