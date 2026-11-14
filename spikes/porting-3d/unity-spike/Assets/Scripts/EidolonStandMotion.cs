using System.Collections.Generic;
using System.Globalization;
using System.IO;
using UnityEngine;

/// <summary>
/// Plays the app-side 60 fps flat motion files (``motions/&lt;idol&gt;/&lt;action&gt;.tsv``)
/// on the game's own skeleton.
///
/// The file is exactly what ``tools/fetch_unity3d_content.py`` writes: ``fps`` and
/// ``frames`` header lines, then one ``R`` line per bone and frame with the local
/// rotation as a quaternion (Unity ``Quaternion.Euler`` space), and ``P`` lines
/// when the clip also moves a node. Paths are the game's own transform paths
/// (``MODEL_00/BODY_SCALE/...``); the game inserts ``BODY_SCALE`` at runtime and
/// <see cref="EidolonStandHost"/> mirrors that, so the paths resolve.
///
/// Two tracks are enough for the stand: the idle loop (``act``) and one-shot
/// gestures (``yes``/``noo``), cross-faded over the idle loop.
/// </summary>
public sealed class EidolonStandMotion : MonoBehaviour
{
    /// One parsed flat file.
    private sealed class Clip
    {
        public int fps = 60;
        public int frames;
        public readonly Dictionary<string, Quaternion[]> rotations = new Dictionary<string, Quaternion[]>();
        public readonly Dictionary<string, Vector3[]> positions = new Dictionary<string, Vector3[]>();
        public float Length => frames > 1 ? (frames - 1f) / fps : 0f;
    }

    private sealed class Bone
    {
        public Transform transform;
    }

    private readonly Dictionary<string, Bone> bones = new Dictionary<string, Bone>();
    private Clip idle;
    private Clip gesture;
    private float idleTime;
    private float gestureTime;
    private string contentRoot;
    private string characterId;

    public int BoneCount => bones.Count;
    public int IdleFrames => idle != null ? idle.frames : 0;
    public float IdleTime => idleTime;

    /// Resolve the game transform paths under the assembled character and start
    /// looping the idle motion.
    public void Init(Transform root, string contentRootDirectory, string character)
    {
        contentRoot = contentRootDirectory;
        characterId = character;
        idle = LoadClip(ActionPath("act"));
        if (idle == null)
        {
            Debug.LogWarning($"[stand] no idle motion for {character}");
            return;
        }
        Resolve(root);
        ApplyIdle(0f);
        Debug.Log($"[stand] motion ready: bones={bones.Count}/{idle.rotations.Count} idleFrames={idle.frames}");
    }

    private string ActionPath(string action)
    {
        return Path.Combine(contentRoot ?? "", "motions", characterId ?? "", action + ".tsv");
    }

    private void Resolve(Transform root)
    {
        var modelRoot = FindDeep(root, "MODEL_00");
        if (modelRoot == null)
        {
            Debug.LogWarning("[stand] MODEL_00 not found; cannot resolve motion paths");
            return;
        }
        foreach (var path in idle.rotations.Keys)
        {
            var target = ResolvePath(root, modelRoot, path);
            if (target == null) continue;
            bones[path] = new Bone { transform = target };
        }
        Debug.Log($"[stand] resolved {bones.Count}/{idle.rotations.Count} motion bones");
    }

    /// Paths are the game's own transform paths: either "MODEL_00/..." (the body
    /// model) or a node directly under the character (POSITION / SCALE_POINT).
    private static Transform ResolvePath(Transform root, Transform modelRoot, string path)
    {
        var segments = path.Split('/');
        Transform current;
        if (segments[0] == "MODEL_00")
        {
            current = modelRoot;
        }
        else
        {
            current = FindDeep(root, segments[0]);
            if (current == null) return null;
        }
        for (var index = 1; index < segments.Length; index++)
        {
            var next = current.Find(segments[index]);
            if (next == null) return null;
            current = next;
        }
        return current;
    }

    private static Transform FindDeep(Transform root, string name)
    {
        if (root == null) return null;
        if (root.name == name) return root;
        foreach (var child in root.GetComponentsInChildren<Transform>(true))
            if (child.name == name) return child;
        return null;
    }

    private static Clip LoadClip(string path)
    {
        if (!File.Exists(path)) return null;
        var clip = new Clip();
        var rotations = new Dictionary<string, List<Quaternion>>();
        var positions = new Dictionary<string, List<Vector3>>();
        foreach (var line in File.ReadLines(path))
        {
            if (string.IsNullOrEmpty(line)) continue;
            var fields = line.Split('\t');
            if (fields.Length < 2) continue;
            switch (fields[0])
            {
                case "fps":
                    clip.fps = int.Parse(fields[1], CultureInfo.InvariantCulture);
                    break;
                case "frames":
                    clip.frames = int.Parse(fields[1], CultureInfo.InvariantCulture);
                    break;
                case "R" when fields.Length >= 7:
                {
                    if (!rotations.TryGetValue(fields[1], out var list))
                    {
                        list = new List<Quaternion>(clip.frames);
                        rotations[fields[1]] = list;
                    }
                    list.Add(new Quaternion(
                        float.Parse(fields[3], CultureInfo.InvariantCulture),
                        float.Parse(fields[4], CultureInfo.InvariantCulture),
                        float.Parse(fields[5], CultureInfo.InvariantCulture),
                        float.Parse(fields[6], CultureInfo.InvariantCulture)));
                    break;
                }
                case "P" when fields.Length >= 6:
                {
                    if (!positions.TryGetValue(fields[1], out var list))
                    {
                        list = new List<Vector3>(clip.frames);
                        positions[fields[1]] = list;
                    }
                    list.Add(new Vector3(
                        float.Parse(fields[3], CultureInfo.InvariantCulture),
                        float.Parse(fields[4], CultureInfo.InvariantCulture),
                        float.Parse(fields[5], CultureInfo.InvariantCulture)));
                    break;
                }
            }
        }
        foreach (var pair in rotations)
            clip.rotations[pair.Key] = pair.Value.ToArray();
        foreach (var pair in positions)
            clip.positions[pair.Key] = pair.Value.ToArray();
        if (clip.frames <= 1) clip.frames = 2;
        return clip;
    }

    /// Play one gesture clip once, cross-faded over the idle loop.
    public void PlayGesture(string action)
    {
        if (idle == null) return;
        var clip = LoadClip(ActionPath(action));
        if (clip == null)
        {
            Debug.Log($"[stand] gesture {action} not available");
            return;
        }
        gesture = clip;
        gestureTime = 0f;
    }

    /// Force the idle clock to a fixed time and re-apply it (probe/debug entry).
    public void SampleIdle(float time)
    {
        idleTime = time;
        ApplyIdle(time);
    }

    /// Local euler angles of a bone by name (probe/debug entry), for comparing the
    /// flat-file playback against the decoded reference clip.
    public string DebugEuler(string boneName)
    {
        foreach (var pair in bones)
        {
            if (pair.Key == boneName || pair.Key.EndsWith("/" + boneName))
            {
                var euler = pair.Value.transform.localEulerAngles;
                return $"{euler.x:F3},{euler.y:F3},{euler.z:F3}";
            }
        }
        return "missing";
    }

    private void Update()
    {
        if (idle == null || bones.Count == 0) return;
        idleTime += Time.deltaTime;
        ApplyIdle(idleTime);
        if (gesture == null) return;
        gestureTime += Time.deltaTime;
        if (gestureTime >= gesture.Length)
        {
            gesture = null;
            return;
        }
        ApplyGesture(gestureTime);
    }

    private static Quaternion SampleRotation(Clip clip, string path, float time)
    {
        if (!clip.rotations.TryGetValue(path, out var frames) || frames.Length == 0) return Quaternion.identity;
        var frame = Mathf.Clamp(time * clip.fps, 0f, frames.Length - 1);
        var low = Mathf.FloorToInt(frame);
        var high = Mathf.Min(low + 1, frames.Length - 1);
        return Quaternion.Slerp(frames[low], frames[high], frame - low);
    }

    private static bool SamplePosition(Clip clip, string path, float time, out Vector3 value)
    {
        value = Vector3.zero;
        if (!clip.positions.TryGetValue(path, out var frames) || frames.Length == 0) return false;
        var frame = Mathf.Clamp(time * clip.fps, 0f, frames.Length - 1);
        var low = Mathf.FloorToInt(frame);
        var high = Mathf.Min(low + 1, frames.Length - 1);
        value = Vector3.Lerp(frames[low], frames[high], frame - low);
        return true;
    }

    private void ApplyIdle(float time)
    {
        var looped = idle.Length > 0.01f ? Mathf.Repeat(time, idle.Length) : 0f;
        foreach (var pair in bones)
        {
            var target = pair.Value.transform;
            target.localRotation = SampleRotation(idle, pair.Key, looped);
            if (SamplePosition(idle, pair.Key, looped, out var position))
                target.localPosition = position;
        }
    }

    private void ApplyGesture(float time)
    {
        var fade = Mathf.Clamp01(time / 0.2f) * Mathf.Clamp01((gesture.Length - time) / 0.2f);
        var looped = idle.Length > 0.01f ? Mathf.Repeat(idleTime, idle.Length) : 0f;
        foreach (var pair in bones)
        {
            var target = pair.Value.transform;
            var posed = SampleRotation(idle, pair.Key, looped);
            if (gesture.rotations.ContainsKey(pair.Key))
                posed = Quaternion.Slerp(posed, SampleRotation(gesture, pair.Key, time), fade);
            target.localRotation = posed;
        }
    }
}
