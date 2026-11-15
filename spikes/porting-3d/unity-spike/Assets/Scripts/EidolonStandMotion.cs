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
/// Pose playback mirrors the game's own animator controller (``AnimCtrl_Commu``,
/// see ``docs/research/mltd-motion-reverse-engineering-2026-11-15.md``): a pose is
/// a set of clips named ``_start`` / ``_loop`` / ``_end`` / ``_yes`` / ``_no`` /
/// ``_action`` (exported here as ``_str`` / ``_lop`` / ``_end`` / ``_yes`` /
/// ``_noo`` / ``_act``). The controller transitions run with zero blend duration
/// at the end of each clip, so the authored clips carry the motion:
/// ``_start -> _loop``, ``_yes/_no -> _loop``, ``_end -> idle``, ``_action -> idle``.
/// Only returning to the character's own idle pose blends (0.1 s), the same value
/// the game passes to its own <c>PlayAnimation</c> call.
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

    /// The clip set of one pose, mirroring the game's pose state machine.
    private sealed class PoseSet
    {
        public string stem;
        public Clip loop;    // `_lop`
        public Clip enter;   // `_str`
        public Clip transition; // `_swt` (switch poses: `a16_p17` etc.)
        public Clip leave;   // `_end`
        public Clip action;  // `_act` (one-shot action poses such as `a16`)
        public Clip yes;     // `_yes`
        public Clip no;      // `_noo`

        public bool HasLoop => loop != null;
    }

    private enum Phase
    {
        Idle,
        Entering,
        Looping,
        Leaving,
        Acting,
    }

    private sealed class Bone
    {
        public Transform transform;
    }

    private static readonly string[] PoseActions = { "lop", "act", "str", "end", "swt", "yes", "noo" };

    private const float IdleBlendDuration = 0.1f;

    private readonly Dictionary<string, Bone> bones = new Dictionary<string, Bone>();
    private Clip idle;          // the character's own idle loop (`motions/<idol>/act.tsv`)
    private Clip current;       // clip being sampled right now
    private bool currentLoops;
    private float clock;        // seconds into `current`
    private Phase phase = Phase.Idle;

    private PoseSet pose;       // current story pose (null when standing in idle)
    private PoseSet pendingPose;
    private bool pendingLoopDirect;
    private Clip pendingIntro;

    private Clip blendFrom;     // 0.1 s blend when a pose returns to the idle loop
    private float blendTime;

    private Clip gesture;
    private float gestureTime;
    private string contentRoot;
    private string characterId;
    private string idlePath;

    public int BoneCount => bones.Count;
    public int IdleFrames => idle != null ? idle.frames : 0;
    public float IdleTime => clock;

    /// Resolve the game transform paths under the assembled character and start
    /// looping the idle motion.
    public void Init(Transform root, string contentRootDirectory, string character)
    {
        contentRoot = contentRootDirectory;
        characterId = character;
        idlePath = ActionPath("act");
        idle = LoadClip(idlePath);
        if (idle == null)
        {
            Debug.LogWarning($"[stand] no idle motion for {character}");
            return;
        }
        Resolve(root);
        StartClip(idle, true);
        ApplyCurrent();
        Debug.Log($"[stand] motion ready: bones={bones.Count}/{idle.rotations.Count} idleFrames={idle.frames}");
    }

    /// Replace the idle loop. The script scenes stand in the game's own `p01` idle
    /// (`com_cut_01z_lop`), not the character's daily action loop, so the theatre
    /// hands the neutral pose clip over once the character is ready.
    public void SetIdleClip(string path)
    {
        if (string.IsNullOrEmpty(path)) return;
        var clip = LoadClip(path);
        if (clip == null)
        {
            Debug.Log($"[stand] idle clip {path} not available");
            return;
        }
        idlePath = path;
        idle = clip;
        if (phase != Phase.Idle) return;
        blendFrom = current;
        blendTime = 0f;
        StartClip(idle, true);
        ApplyCurrent();
        Debug.Log($"[stand] idle clip {Path.GetFileName(path)} frames={clip.frames}");
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

    // ---------------------------------------------------------------- story poses

    /// Switch to a story pose. `clip` names the pose's loop clip
    /// (``<variant>_<pose>_lop``) or an action clip (``<variant>_<pose>_act``);
    /// the other halves of the pose are resolved from the same directory.
    ///
    /// This follows the game's own sequence: the current pose plays its ``_end``
    /// clip, then the new pose plays ``_start`` and settles into ``_loop``. When
    /// `loopDirect` is set (the ADV pose type flag) the ``_start`` clip is skipped.
    public void PlayPose(string clip, bool loopDirect)
    {
        PlayPose(clip, loopDirect, null);
    }

    /// <param name="enter">Which authored clip walks into the pose: `str` (the
    /// normal `_start`), `swt` (a switch pose's `_switch`) or `act` (a private
    /// action's one-shot `_action`). Null keeps the default `_str`.</param>
    public void PlayPose(string clip, bool loopDirect, string enter)
    {
        if (string.IsNullOrEmpty(clip)) return;
        var set = LoadPose(StoryClipPath(clip));
        if (set == null)
        {
            Debug.Log($"[stand] pose {clip} not available");
            return;
        }
        if (pose != null && pose.stem == set.stem && (phase == Phase.Looping || phase == Phase.Entering))
        {
            Debug.Log($"[stand] pose {clip} already showing");
            return;
        }
        Debug.Log($"[stand] pose {clip} loop={(set.loop != null)} enter={(set.enter != null)} " +
                  $"switch={(set.transition != null)} end={(set.leave != null)} " +
                  $"action={(set.action != null)} loopDirect={loopDirect} enterKind={enter ?? "str"}");
        if (pose != null && pose.leave != null && (phase == Phase.Looping || phase == Phase.Entering))
        {
            // The controller's `_end -> idle` transition is what the game uses when a
            // pose goes away; queue the next pose behind the authored exit.
            pendingPose = set;
            pendingLoopDirect = loopDirect;
            pendingIntro = ResolveIntro(set, enter);
            StartClip(pose.leave, false);
            phase = Phase.Leaving;
            ApplyCurrent();
            return;
        }
        EnterPose(set, loopDirect, ResolveIntro(set, enter));
    }

    /// Return to the character's own idle loop after a story ends.
    public void ResetPose()
    {
        if (idle == null) return;
        if (pose != null && pose.leave != null && (phase == Phase.Looping || phase == Phase.Entering))
        {
            pendingPose = null;
            StartClip(pose.leave, false);
            phase = Phase.Leaving;
            ApplyCurrent();
            return;
        }
        GoIdle();
    }

    /// The authored clip that walks into this pose. The game enters a normal pose
    /// through `_start` (`str`), a switch pose through the source pose's `_switch`
    /// (`swt`, passed as `swt:<source clip>`) and a private action through `_action`.
    private Clip ResolveIntro(PoseSet set, string enter)
    {
        if (string.IsNullOrEmpty(enter)) return set.enter;
        if (enter == "act") return set.action;
        if (enter == "swt") return set.transition;
        if (enter.StartsWith("swt:"))
        {
            var directory = Path.GetDirectoryName(set.stem);
            var name = enter.Substring(4);
            var path = Path.Combine(directory ?? "", name + "_swt.tsv");
            return File.Exists(path) ? LoadClip(path) : null;
        }
        return set.enter;
    }

    private void EnterPose(PoseSet set, bool loopDirect)
    {
        EnterPose(set, loopDirect, null);
    }

    private void EnterPose(PoseSet set, bool loopDirect, Clip intro)
    {
        pose = set;
        pendingPose = null;
        pendingIntro = null;
        gesture = null;
        if (!loopDirect && intro != null)
        {
            StartClip(intro, false);
            phase = Phase.Entering;
        }
        else if (set.loop != null)
        {
            StartClip(set.loop, true);
            phase = Phase.Looping;
        }
        else
        {
            StartClip(set.action, false);
            phase = Phase.Acting;
        }
        ApplyCurrent();
    }

    private void GoIdle()
    {
        pose = null;
        pendingPose = null;
        gesture = null;
        blendFrom = current;
        blendTime = 0f;
        StartClip(idle, true);
        phase = Phase.Idle;
        ApplyCurrent();
        Debug.Log("[stand] pose idle");
    }

    private void StartClip(Clip clip, bool loops)
    {
        current = clip;
        currentLoops = loops;
        clock = 0f;
    }

    /// Story clips are addressed by absolute path (the theatre and the character
    /// bundle can live in different roots); a bare name resolves inside the bundle.
    private string StoryClipPath(string clip)
    {
        if (clip.IndexOf('/') >= 0 || clip.IndexOf('\\') >= 0) return clip;
        return Path.Combine(contentRoot ?? "", "stories", "motions", clip + ".tsv");
    }

    private static PoseSet LoadPose(string path)
    {
        var directory = Path.GetDirectoryName(path);
        var extension = Path.GetExtension(path);
        var name = Path.GetFileNameWithoutExtension(path);
        if (string.IsNullOrEmpty(extension)) extension = ".tsv";
        foreach (var action in PoseActions)
        {
            var suffix = "_" + action;
            if (!name.EndsWith(suffix, System.StringComparison.Ordinal)) continue;
            name = name.Substring(0, name.Length - suffix.Length);
            break;
        }
        if (string.IsNullOrEmpty(name)) return null;
        var stem = string.IsNullOrEmpty(directory) ? name : Path.Combine(directory, name);

        Clip Load(string action)
        {
            var candidate = stem + "_" + action + extension;
            return File.Exists(candidate) ? LoadClip(candidate) : null;
        }

        var set = new PoseSet
        {
            stem = stem,
            loop = Load("lop"),
            enter = Load("str"),
            transition = Load("swt"),
            leave = Load("end"),
            action = Load("act"),
            yes = Load("yes"),
            no = Load("noo"),
        };
        return set.loop != null || set.action != null ? set : null;
    }

    /// Play one `yes`/`no` clip of the current pose once, then settle back into the
    /// pose loop (the controller's `_yes -> _loop` transition). Falls back to the
    /// character's own gesture when the pose ships none.
    public void PlayGesture(string action)
    {
        if (idle == null) return;
        Clip clip = null;
        if (pose != null) clip = action == "yes" ? pose.yes : action == "noo" || action == "no" ? pose.no : null;
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
        clock = time;
        ApplyCurrent();
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
        if (current == null || bones.Count == 0) return;
        clock += Time.deltaTime;
        if (blendFrom != null)
        {
            blendTime += Time.deltaTime;
            if (blendTime >= IdleBlendDuration) blendFrom = null;
        }
        switch (phase)
        {
            case Phase.Entering when clock >= current.Length:
                if (pose != null && pose.loop != null)
                {
                    StartClip(pose.loop, true);
                    phase = Phase.Looping;
                    Debug.Log("[stand] pose enter done -> loop");
                }
                else if (pose != null && pose.action != null)
                {
                    StartClip(pose.action, false);
                    phase = Phase.Acting;
                }
                else
                {
                    GoIdle();
                }
                break;
            case Phase.Leaving when clock >= current.Length:
            case Phase.Acting when clock >= current.Length:
                if (pendingPose != null) EnterPose(pendingPose, pendingLoopDirect, pendingIntro);
                else GoIdle();
                break;
        }
        ApplyCurrent();
        if (gesture == null) return;
        gestureTime += Time.deltaTime;
        if (gestureTime >= gesture.Length)
        {
            gesture = null;
            ApplyCurrent();
            return;
        }
        ApplyGesture(gestureTime);
    }

    private static Quaternion SampleRotation(Clip clip, string path, float time)
    {
        if (clip == null || !clip.rotations.TryGetValue(path, out var frames) || frames.Length == 0) return Quaternion.identity;
        var frame = Mathf.Clamp(time * clip.fps, 0f, frames.Length - 1);
        var low = Mathf.FloorToInt(frame);
        var high = Mathf.Min(low + 1, frames.Length - 1);
        return Quaternion.Slerp(frames[low], frames[high], frame - low);
    }

    private static bool SamplePosition(Clip clip, string path, float time, out Vector3 value)
    {
        value = Vector3.zero;
        if (clip == null || !clip.positions.TryGetValue(path, out var frames) || frames.Length == 0) return false;
        var frame = Mathf.Clamp(time * clip.fps, 0f, frames.Length - 1);
        var low = Mathf.FloorToInt(frame);
        var high = Mathf.Min(low + 1, frames.Length - 1);
        value = Vector3.Lerp(frames[low], frames[high], frame - low);
        return true;
    }

    /// Sample `current` at its clock. Loops wrap; one-shot clips (``_start``,
    /// ``_end``, ``_action``) hold their last frame until the phase machine swaps
    /// them out, exactly like an animator state that has finished.
    private void ApplyCurrent()
    {
        if (current == null) return;
        var time = currentLoops && current.Length > 0.01f ? Mathf.Repeat(clock, current.Length) : Mathf.Min(clock, current.Length);
        var alpha = 1f;
        var fromTime = 0f;
        if (blendFrom != null)
        {
            alpha = Mathf.SmoothStep(0f, 1f, Mathf.Clamp01(blendTime / IdleBlendDuration));
            fromTime = blendFrom.Length > 0.01f ? Mathf.Repeat(blendTime, blendFrom.Length) : 0f;
        }
        foreach (var pair in bones)
        {
            var target = pair.Value.transform;
            var rotation = SampleRotation(current, pair.Key, time);
            var hasPosition = SamplePosition(current, pair.Key, time, out var position);
            if (blendFrom != null)
            {
                rotation = Quaternion.Slerp(SampleRotation(blendFrom, pair.Key, fromTime), rotation, alpha);
                if (SamplePosition(blendFrom, pair.Key, fromTime, out var fromPosition))
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
        var baseTime = currentLoops && current.Length > 0.01f ? Mathf.Repeat(clock, current.Length) : Mathf.Min(clock, current.Length);
        foreach (var pair in bones)
        {
            var target = pair.Value.transform;
            var posed = SampleRotation(current, pair.Key, baseTime);
            if (gesture.rotations.ContainsKey(pair.Key))
                posed = Quaternion.Slerp(posed, SampleRotation(gesture, pair.Key, time), fade);
            target.localRotation = posed;
        }
    }
}
