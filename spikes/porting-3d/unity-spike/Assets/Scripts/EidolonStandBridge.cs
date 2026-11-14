using System.Runtime.InteropServices;
using UnityEngine;

/// <summary>
/// The only Unity → native call: a JSON event posted through the iOS plugin
/// (<c>Assets/Plugins/iOS/EidolonStandNative.mm</c>), which Swift receives as an
/// <c>NSNotification</c>. On every other platform / in the editor the event is
/// just logged so probes can still see it.
/// </summary>
public static class EidolonStandBridge
{
    /// <summary>The last event, for editor probes and tests.</summary>
    public static string LastEvent { get; private set; }

#if UNITY_IOS && !UNITY_EDITOR
    [DllImport("__Internal")]
    private static extern void EidolonUnityPostEvent(string json);
#endif

    public static void Emit(string json)
    {
        LastEvent = json;
        Debug.Log("[stand] event " + json);
#if UNITY_IOS && !UNITY_EDITOR
        EidolonUnityPostEvent(json);
#endif
    }
}
