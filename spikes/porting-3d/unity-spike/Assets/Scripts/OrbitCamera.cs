using UnityEngine;

/// Mouse control for the Game view, so the character can be inspected without
/// touching the camera from a script.
///
///   right-drag   orbit around the character
///   middle-drag  pan the pivot
///   wheel        zoom
///   F            reset
[DefaultExecutionOrder(100)]
public sealed class OrbitCamera : MonoBehaviour
{
    public Transform target;
    public float yaw = 180f;
    public float pitch = 6f;
    public float distance = 2.6f;
    public Vector3 pivot = new Vector3(0f, 0.95f, 0f);

    public float minPitch = -70f;
    public float maxPitch = 85f;
    public float minDistance = 0.3f;
    public float maxDistance = 6f;
    public float orbitSpeed = 4f;
    public float zoomSpeed = 0.25f;

    private Vector3 lastMouse;

    private void Start()
    {
        if (target == null)
        {
            var character = GameObject.Find("Character");
            if (character != null) target = character.transform;
        }
        Apply();
    }

    private void Update()
    {
        if (Input.GetKeyDown(KeyCode.F)) ResetView();

        var overGameView = Input.mousePosition.x > 0 && Input.mousePosition.y > 0
            && Input.mousePosition.x < Screen.width && Input.mousePosition.y < Screen.height;
        if (overGameView) Turn();
        Apply();
    }

    private void Turn()
    {
        var scroll = Input.mouseScrollDelta.y;
        if (Mathf.Abs(scroll) > 0.01f)
            distance = Mathf.Clamp(distance * (1f - scroll * zoomSpeed), minDistance, maxDistance);

        if (Input.GetMouseButtonDown(2)) lastMouse = Input.mousePosition;

        if (Input.GetMouseButton(1))
        {
            var delta = Input.mousePosition - lastMouse;
            yaw += delta.x * orbitSpeed * 0.25f;
            pitch = Mathf.Clamp(pitch - delta.y * orbitSpeed * 0.25f, minPitch, maxPitch);
            lastMouse = Input.mousePosition;
        }
        else if (Input.GetMouseButton(2))
        {
            var delta = Input.mousePosition - lastMouse;
            var scale = distance * 0.0015f;
            pivot -= transform.right * (delta.x * scale);
            pivot -= transform.up * (delta.y * scale);
            lastMouse = Input.mousePosition;
        }
        else
        {
            lastMouse = Input.mousePosition;
        }
    }

    private void Apply()
    {
        var rotation = Quaternion.Euler(pitch, yaw, 0f);
        transform.position = pivot - rotation * Vector3.forward * distance;
        transform.rotation = rotation;
    }

    public void ResetView()
    {
        yaw = 180f; pitch = 6f; distance = 2.6f; pivot = new Vector3(0f, 0.95f, 0f);
        if (target != null) pivot = target.position + Vector3.up * 0.95f;
        Apply();
    }
}
