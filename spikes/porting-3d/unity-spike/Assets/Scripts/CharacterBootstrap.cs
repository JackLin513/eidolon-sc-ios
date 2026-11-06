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
        // The assist bones read the rest pose, so this has to happen before the
        // first clip frame is applied.
        var helpers = gameObject.AddComponent<HelperBones>();
        helpers.Bind(transform);
        FixOutlineDepth();
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

        if (!string.IsNullOrEmpty(bodyBundle))
        {
            var bodyAssetBundle = LoadBundle(bodyBundle);
            var swayAsset = bodyAssetBundle == null ? null : bodyAssetBundle.LoadAllAssets<TextAsset>()
                .FirstOrDefault(a => a.name.EndsWith("_sway"));
            if (swayAsset != null)
            {
                var solver = gameObject.AddComponent<SwaySolver>();
                solver.Bind(SwayFile.Parse(swayAsset.text));
            }
        }
    }

    /// The clip currently driving the pose (probes read this).
    public EidolonMotionClip Clip => clip;

    /// Re-reads the packed clip and rebuilds the path map (used by the probes
    /// after a script reload, where Start may not have run again).
    public bool LoadClip(string path)
    {
        if (!File.Exists(path)) return false;
        clip = EidolonMotionClip.Load(path);
        byPath = new Dictionary<string, Transform>();
        foreach (var t in GetComponentsInChildren<Transform>(true))
        {
            var key = PathOf(t);
            if (!string.IsNullOrEmpty(key)) byPath[key] = t;
        }
        return true;
    }

    /// Applies a frame of the loaded clip.
    public void Seek(int frame)
    {
        if (clip == null) return;
        Apply(frame);
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

    /// The character shaders draw their outline as an extruded hull and park it
    /// behind the surface with `_ZShift1000*`. The shipped values assume the
    /// game's own camera; with ours the hull is far too close and bleeds
    /// through the pleated skirt from behind (a brown crown of `_OutlineColor`
    /// over the fabric). Pushing it back further restores the silhouette lines
    /// and leaves the surface clean.
    private void FixOutlineDepth()
    {
        var body = GetComponentsInChildren<SkinnedMeshRenderer>(true)
            .FirstOrDefault(r => r.name == "body");
        if (body == null) return;
        foreach (var material in body.sharedMaterials)
        {
            if (material == null || !material.HasProperty("_ZShift1000Max")) continue;
            material.SetFloat("_ZShift1000Min", 0.2f);
            material.SetFloat("_ZShift1000Max", 2f);
        }
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
        if (camera.GetComponent<OrbitCamera>() == null) camera.gameObject.AddComponent<OrbitCamera>();
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
