using UnityEngine;

/// Lets `SwayShot.Request` take its picture inside a real frame, where Unity
/// has already re-skinned the character.
public sealed class SwayShotDriver : MonoBehaviour
{
    private void LateUpdate()
    {
#if UNITY_EDITOR
        SwayShot.Pump();
#endif
    }
}
