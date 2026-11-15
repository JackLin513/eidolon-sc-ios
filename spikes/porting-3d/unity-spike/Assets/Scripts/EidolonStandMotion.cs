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
        // Some pose clips ship only as `act`, and that clip is the game's one-shot
        // gesture: it starts at the neutral stance, reaches the pose and returns to
        // the neutral stance. Looping one of those makes the character raise and drop
        // her arms over and over. Play the entry once, then hold the pose with only
        // the small sway authored inside the pose's plateau.
        public bool oneShot;
        public float holdStart;
        public float holdEnd;
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

    // Story poses are absolute local rotations, so switching poses means
    // blending out of the previous clip instead of switching hard.
    private Clip poseFadeFrom;
    private float poseFadeTime;
    private const float PoseFadeDuration = 0.25f;
    // The authored `str` clip is the game's own entry into a pose (`str` = start,
    // `lop` = loop, `end` = leave). When the story pack ships it, the entry clip
    // plays first and the loop takes over when it ends; blending two loops while
    // an entry clip is overlaid made the arms end up in neither pose.
    private Clip poseNextLoop;
    private string poseClip;

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
        AnalyzeClip(clip, path);
        return clip;
    }

    /// Classify a clip as a loop or a one-shot gesture.
    ///
    /// A loop returns to where it started (``lop``); a pose-enter ``str`` ends on the
    /// pose; an `act` clip that starts and ends on the same neutral stance with a large
    /// excursion in between is a one-shot gesture. For those, playback stops on the
    /// frame where the pose is most expressed.
    private static void AnalyzeClip(Clip clip, string path)
    {
        // Only story pose `act` clips qualify. The character's own daily `act` is the
        // idle loop (it wanders and returns), and `cut_*_lop` is explicitly the loop.
        var normalized = (path ?? "").Replace('\\', '/');
        if (!normalized.Contains("/stories/motions/") || !normalized.EndsWith("_act.tsv")) return;
        if (clip.frames < 3 || clip.rotations.Count == 0) return;
        var paths = new List<string>();
        foreach (var pair in clip.rotations)
            if (pair.Value.Length == clip.frames) paths.Add(pair.Key);
        if (paths.Count == 0) return;
        var start = new Quaternion[paths.Count];
        var last = new Quaternion[paths.Count];
        for (var i = 0; i < paths.Count; i++)
        {
            start[i] = clip.rotations[paths[i]][0];
            last[i] = clip.rotations[paths[i]][clip.frames - 1];
        }
        var endsWhereItStarts = 0f;
        for (var i = 0; i < paths.Count; i++) endsWhereItStarts += Quaternion.Angle(start[i], last[i]);
        endsWhereItStarts /= paths.Count;
        var peakIndex = 0;
        var peakAngle = 0f;
        for (var frame = 1; frame < clip.frames; frame++)
        {
            var angle = 0f;
            for (var i = 0; i < paths.Count; i++) angle += Quaternion.Angle(start[i], clip.rotations[paths[i]][frame]);
            angle /= paths.Count;
            if (angle <= peakAngle) continue;
            peakAngle = angle;
            peakIndex = frame;
        }
        if (endsWhereItStarts > 2f || peakAngle < 5f) return;
        // The plateau is where the clip has settled on the pose; looping only that span
        // keeps the authored sway without repeating the raise/lower gesture.
        var plateauStart = -1;
        var plateauEnd = -1;
        for (var frame = 0; frame < clip.frames; frame++)
        {
            var angle = 0f;
            for (var i = 0; i < paths.Count; i++) angle += Quaternion.Angle(start[i], clip.rotations[paths[i]][frame]);
            angle /= paths.Count;
            if (angle < peakAngle * 0.9f) continue;
            if (plateauStart < 0) plateauStart = frame;
            plateauEnd = frame;
        }
        clip.oneShot = true;
        if (plateauEnd - plateauStart >= 9)
        {
            clip.holdStart = plateauStart / (float)clip.fps;
            clip.holdEnd = plateauEnd / (float)clip.fps;
        }
        else
        {
            clip.holdStart = clip.holdEnd = Mathf.Clamp((peakIndex - 1) / (float)clip.fps, 0f, clip.Length);
        }
        Debug.Log($"[stand] one-shot pose clip: enter then hold {clip.holdStart:F2}-{clip.holdEnd:F2}s (peak {peakAngle:F1}deg)");
    }

    /// Where to read a clip at wall-clock `time`: loops wrap, one-shot gestures play the
    /// entry and then stay on their plateau.
    private static float ClipTime(Clip clip, float time)
    {
        if (clip == null) return 0f;
        if (!clip.oneShot) return clip.Length > 0.01f ? Mathf.Repeat(time, clip.Length) : 0f;
        if (time <= clip.holdStart) return time;
        var span = clip.holdEnd - clip.holdStart;
        if (span <= 0.01f) return clip.holdStart;
        return clip.holdStart + Mathf.Repeat(time - clip.holdStart, span);
    }

    /// Switch the loop to a story pose clip, cross-fading over 0.25 s.
    ///
    /// `clip` is the shared story motion name (``<variant>_<pose>_<action>``)
    /// under ``stories/motions``; the scene's 60 fps script and the audio line
    /// decide when this is called, so the pose is not tied to a single action.
    public void PlayPose(string clip)
    {
        if (string.IsNullOrEmpty(clip)) return;
        var path = StoryClipPath(clip);
        if (path == poseClip)
        {
            Debug.Log($"[stand] pose {clip} already showing");
            return;
        }
        var loop = LoadClip(path);
        if (loop == null)
        {
            Debug.Log($"[stand] pose {clip} not available");
            return;
        }
        var intro = LoadIntro(path);
        // A one-shot `act` already contains the entry (neutral -> pose -> neutral), so
        // chaining the `str` entry in front of it would play the movement twice.
        if (loop.oneShot) intro = null;
        BeginPoseFade();
        gesture = null;
        idleTime = 0f;
        poseClip = path;
        if (intro != null)
        {
            // Play the game's own entry clip first; `Update` swaps in the loop when
            // it finishes (the extracted `str` ends on the loop's first pose).
            idle = intro;
            poseNextLoop = loop;
        }
        else
        {
            idle = loop;
            poseNextLoop = null;
        }
        Debug.Log($"[stand] pose {clip} frames={loop.frames} intro={(intro != null)}");
    }

    /// Return to the character's own idle loop after a story ends.
    public void ResetPose()
    {
        if (string.IsNullOrEmpty(characterId)) return;
        var home = LoadClip(ActionPath("act"));
        if (home == null) return;
        BeginPoseFade();
        idle = home;
        idleTime = 0f;
        poseClip = null;
        gesture = null;
        poseNextLoop = null;
        Debug.Log("[stand] pose reset");
    }

    /// Story clips are addressed by absolute path (the theatre and the character
    /// bundle can live in different roots); a bare name resolves inside the bundle.
    private string StoryClipPath(string clip)
    {
        if (clip.IndexOf('/') >= 0 || clip.IndexOf('\\') >= 0) return clip;
        return Path.Combine(contentRoot ?? "", "stories", "motions", clip + ".tsv");
    }

    /// The loop half of a pose line is `<clip>_lop`/`<clip>_act`; the authored extract
    /// for a gesture or for entering the pose drops that suffix.
    private string PoseGesturePath(string action)
    {
        var directory = Path.GetDirectoryName(poseClip);
        var name = Path.GetFileNameWithoutExtension(poseClip);
        if (string.IsNullOrEmpty(directory) || string.IsNullOrEmpty(name)) return null;
        foreach (var suffix in new[] { "_lop", "_act", "_swt" })
            if (name.EndsWith(suffix, System.StringComparison.Ordinal))
            {
                name = name.Substring(0, name.Length - suffix.Length);
                break;
            }
        return Path.Combine(directory, name + "_" + action + ".tsv");
    }

    /// `<clip>_lop.tsv` -> `<clip>_str.tsv`, when the pose was exported with one.
    private Clip LoadIntro(string loopPath)
    {
        var extension = Path.GetExtension(loopPath);
        var stem = loopPath.Substring(0, loopPath.Length - extension.Length);
        foreach (var suffix in new[] { "_lop", "_act", "_swt" })
        {
            if (!stem.EndsWith(suffix, System.StringComparison.Ordinal)) continue;
            var introPath = stem.Substring(0, stem.Length - suffix.Length) + "_str" + extension;
            if (!File.Exists(introPath)) return null;
            return LoadClip(introPath);
        }
        return null;
    }

    private void BeginPoseFade()
    {
        poseFadeFrom = idle;
        poseFadeTime = 0f;
    }

    /// Play one gesture clip once, cross-faded over the idle loop. Story poses
    /// ship their own ``<clip>_yes/_noo``; fall back to the character's own.
    public void PlayGesture(string action)
    {
        if (idle == null) return;
        Clip clip = null;
        var poseGesture = PoseGesturePath(action);
        if (poseGesture != null) clip = LoadClip(poseGesture);
        if (clip == null) clip = LoadClip(ActionPath(action));
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
        // The entry clip handed over to the pose loop; blend from its last frame.
        if (poseNextLoop != null && idleTime >= idle.Length)
        {
            BeginPoseFade();
            idle = poseNextLoop;
            poseNextLoop = null;
            idleTime = 0f;
            Debug.Log("[stand] pose enter done -> loop");
        }
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
        var looped = ClipTime(idle, time);
        if (poseFadeFrom != null)
        {
            poseFadeTime += Time.deltaTime;
            if (poseFadeTime >= PoseFadeDuration) poseFadeFrom = null;
        }
        var alpha = poseFadeFrom == null
            ? 1f
            : Mathf.SmoothStep(0f, 1f, Mathf.Clamp01(poseFadeTime / PoseFadeDuration));
        var fromTime = poseFadeFrom != null ? ClipTime(poseFadeFrom, poseFadeTime) : 0f;
        foreach (var pair in bones)
        {
            var target = pair.Value.transform;
            var rotation = SampleRotation(idle, pair.Key, looped);
            var hasPosition = SamplePosition(idle, pair.Key, looped, out var position);
            if (poseFadeFrom != null)
            {
                rotation = Quaternion.Slerp(SampleRotation(poseFadeFrom, pair.Key, fromTime), rotation, alpha);
                if (SamplePosition(poseFadeFrom, pair.Key, fromTime, out var fromPosition))
                {
                    position = hasPosition ? Vector3.Lerp(fromPosition, position, alpha) : fromPosition;
                    hasPosition = true;
                }
            }
            target.localRotation = rotation;
            if (hasPosition) target.localPosition = position;
        }
    }

    private void ApplyGesture(float time)
    {
        var fade = Mathf.Clamp01(time / 0.2f) * Mathf.Clamp01((gesture.Length - time) / 0.2f);
        var looped = ClipTime(idle, idleTime);
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
