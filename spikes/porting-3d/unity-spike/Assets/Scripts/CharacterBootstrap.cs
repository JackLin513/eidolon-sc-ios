using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEngine;

/// Builds the game's own character from its asset bundles at runtime and plays
/// one packed motion clip. This is the shape the real client would take: the
/// bundles supply the assets, the clip supplies the pose.
public sealed class CharacterBootstrap : MonoBehaviour
{
    [Tooltip("Directory holding cb_/ch_ .unity3d")]
    public string bundleDirectory = "/tmp/mltd-unity-assets";
    public string bodyBundle = "cb_pr001_001har.unity3d";
    public string headBundle = "ch_pr001_001har.unity3d";
    [Tooltip("EULR dump written from eidolon.motion/1")]
    public string clipPath = "/tmp/mltd-unity-out/clip.bin";
    public bool play = true;
    public float speed = 1f;

    private EidolonMotionClip clip;
    private Dictionary<string, Transform> byPath;
    private float time;
    private int applied = -1;

    private void Start()
    {
        ApplyGlobals();
        if (!BuildCharacter()) return;
        if (File.Exists(clipPath))
        {
            clip = EidolonMotionClip.Load(clipPath);
            byPath = new Dictionary<string, Transform>();
            foreach (var t in GetComponentsInChildren<Transform>(true))
            {
                var path = PathOf(t);
                if (!string.IsNullOrEmpty(path)) byPath[path] = t;
            }
        }
        Frame();
        Apply(0);
    }

    private void Update()
    {
        if (!play || clip == null) return;
        time += Time.deltaTime * speed;
        var frame = Mathf.FloorToInt(time * 30f) % clip.Frames;
        if (frame != applied) Apply(frame);
    }

    /// The game sets these once (and on scene changes); at their zero default
    /// the character shaders multiply the whole figure to black.
    private static void ApplyGlobals()
    {
        Shader.SetGlobalVector("_GuradeParams", new Vector4(0, 1, 0, 1));
        Shader.SetGlobalVector("_FadeColV", Vector4.one);
        Shader.SetGlobalVector("_TheaterColV", Vector4.one);
        Shader.SetGlobalVector("_MonoColor", Vector4.one);
        Shader.SetGlobalVector("_RimCtrl", Vector4.zero);
        Shader.SetGlobalFloat("_Whiteness", 0);
        Shader.SetGlobalFloat("_Luminance", 1);
        Shader.SetGlobalInt("_FogMode", 0);
        Shader.SetGlobalInt("_IsLive", 0);
    }

    private bool BuildCharacter()
    {
        var body = LoadBundle(bodyBundle);
        var head = LoadBundle(headBundle);
        if (body == null || head == null)
        {
            Debug.LogError($"Eidolon: bundles missing in {bundleDirectory}");
            return false;
        }
        var bodyPrefab = body.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("cb_"));
        var headPrefab = head.LoadAllAssets<GameObject>().First(g => g.name.StartsWith("ch_"));
        var bodyInstance = Instantiate(bodyPrefab, transform);
        bodyInstance.name = "MODEL_00_holder";
        var headInstance = Instantiate(headPrefab, transform);
        headInstance.name = "ch_head";
        // The head is a self-contained 34-bone rig authored in model space, so
        // at bind pose it lines up with the body with no offset. Attach it to
        // the body's ATAMA socket at that moment (worldPositionStays) so it
        // follows the neck when the clip bends the spine.
        var model = bodyInstance.transform.Find("MODEL_00") ?? bodyInstance.transform;
        var atama = model.Find("BASE/MUNE1/MUNE2/KUBI/ATAMA");
        headInstance.transform.SetParent(atama != null ? atama : model, true);
        return true;
    }

    /// An AssetBundle cannot be loaded twice in one process; edit-time probes
    /// may already hold these, so reuse whatever is open.
    private AssetBundle LoadBundle(string file)
    {
        foreach (var loaded in AssetBundle.GetAllLoadedAssetBundles())
            if (loaded.name == file) return loaded;
        return AssetBundle.LoadFromFile(Path.Combine(bundleDirectory, file));
    }

    private void Apply(int frame)
    {
        applied = frame;
        foreach (var track in clip.Tracks)
        {
            var key = track.Path.Replace("/BODY_SCALE", "");
            if (!byPath.TryGetValue(key, out var target)) continue;
            var at = frame * (track.HasPosition ? 6 : 3);
            target.localRotation = Quaternion.Euler(
                track.Values[at], track.Values[at + 1], track.Values[at + 2]);
            if (track.HasPosition)
                target.localPosition = new Vector3(
                    track.Values[at + 3], track.Values[at + 4], track.Values[at + 5]);
        }
    }

    private void Frame()
    {
        var camera = Camera.main;
        if (camera == null)
        {
            var go = new GameObject("Main Camera");
            go.tag = "MainCamera";
            camera = go.AddComponent<Camera>();
        }
        // The model faces +Z.
        camera.transform.position = new Vector3(0, 1.0f, 2.6f);
        camera.transform.LookAt(new Vector3(0, 0.95f, 0));
        camera.fieldOfView = 30;
        if (FindObjectOfType<Light>() == null)
        {
            var light = new GameObject("Directional Light").AddComponent<Light>();
            light.type = LightType.Directional;
            light.transform.rotation = Quaternion.Euler(35, -35, 0);
        }
    }

    /// Clip paths are rooted at the model, e.g. `MODEL_00/BASE/KOSHI/MOMO_L`.
    /// The scene hierarchy has extra wrappers around it, so cut the path at the
    /// nearest ancestor named MODEL_00.
    private static string PathOf(Transform transform)
    {
        var parts = new List<string>();
        var rooted = false;
        for (var t = transform; t != null; t = t.parent)
        {
            parts.Add(t.name);
            if (t.name == "MODEL_00") { rooted = true; break; }
        }
        parts.Reverse();
        return rooted ? string.Join("/", parts) : null;
    }
}
