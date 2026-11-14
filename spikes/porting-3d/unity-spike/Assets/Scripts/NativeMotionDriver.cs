using System;
using System.Collections.Generic;
using System.IO;
using Imas;
using UnityEngine;

/// <summary>
/// Drop-in replacement for the old 30 fps clip player: drives the native-faithful
/// <see cref="CharacterImasMotionPlayerDance"/> from the raw `eidolon.imo/1` assets
/// exported by `spikes/porting-3d/export_imo.py`.
///
/// It hangs on the same GameObject as `CharacterBootstrap` (the "Character" root) and
/// deliberately does **not** touch that file; the integrator removes/Disables the old
/// `clipPath` playback and adds this component instead.
///
/// Per-frame order mirrors the game's `Imas.Live.DanceMotionPlayer`:
///   Execute()            0x1EDD17C  → execute_async_imo(dontInterpolateThisFrame)
///   execute_async_imo    0x1EDD228  → imo_player.UpdateTime(0.0f)   (delta is always 0;
///                                     the dance is driven by an external SetTime)
///                                   → imo_player.SolveCurves(flag)
///                                   → if (HasCurrentMotionOptionalImoData) SolveOptionalCurves()
///   PostExecuteSync()    0x1EDD2B8  → post_execute_sync_imo 0x1EDD380
///                                   → imo_player.SetResultToTransforms()
///                                   → hand IK consumes opt_results[0..1]
/// The async job is not reproduced (ADR-0033 §3 allows Jobs → serial C#); everything runs
/// in `Update`.
///
/// The game's external time source is music sync. Here the time is advanced locally by
/// `UnityEngine.Time.deltaTime * speed` and offered to the player with `SetTime`, exactly the way the
/// live system offers the song position; `UpdateTime(0)` then performs the loop/end clamp.
/// </summary>
public sealed class NativeMotionDriver : MonoBehaviour
{
    [Header("Data ($MLTD_WORK/motion by default)")]
    [Tooltip("Directory holding the exported imo JSON files (eidolon.imo/1)")]
    public string motionDirectory = WorkDirectory("motion");
    [Tooltip("Main dance asset file name, relative to motionDirectory")]
    public string imoFile = "dan_loveig_01_dan.imo.imo.json";
    [Tooltip("Optional (kind == \"optional\") asset file name; empty = none. " +
             "HandToHand curves only.")]
    public string optionalImoFile = string.Empty;

    [Header("Playback")]
    public bool playOnStart = true;
    public bool loop = true;
    public bool paused = false;
    [Tooltip("Playback speed multiplier applied to UnityEngine.Time.deltaTime")]
    public float speed = 1f;
    [Tooltip("Passed to SolveCurves: snap the solve time to the nearest 1/60 frame " +
             "(native 0x37EE384 dontInterpolateThisFrame). Leave off for continuous playback.")]
    public bool dontInterpolateThisFrame = false;

    [Header("Hierarchy")]
    [Tooltip("The game's bone paths carry a BODY_SCALE node the spike prefab does not have; " +
             "same adaptation as CharacterBootstrap.Apply / SwayRig.")]
    public bool stripBodyScaleNode = true;
    [Tooltip("Transform that receives the imo \"POSITION\" track (stage placement). " +
             "The native character hierarchy has a POSITION node; the spike prefab does not, " +
             "so this is auto-detected and can be assigned by hand.")]
    public Transform positionTarget;
    public string positionTargetPath = "POSITION";
    [Tooltip("Log each imo path that has no matching transform once")]
    public bool logUnmappedTracks = true;

    private CharacterImasMotionPlayerDance player;
    private CharacterImasMotionData data;
    private CharaOptionalImoData optionalData;
    private Dictionary<string, Transform> byPath;
    private readonly HashSet<string> loggedUnmapped = new HashSet<string>(StringComparer.Ordinal);
    private float time;
    private bool loaded;
    private bool loadAttempted;
    private string loadError;

    /// <summary>The native player; probes read `Results`, `opt_results`, `current_time` here.</summary>
    public CharacterImasMotionPlayerDance Player => player;
    public CharacterImasMotionData Data => data;
    public CharaOptionalImoData OptionalData => optionalData;
    public bool IsLoaded => loaded;
    public string LoadError => loadError;
    public float PlaybackTime => time;
    public string ImoPath => Path.Combine(Expand(motionDirectory), imoFile);

    private static string WorkDirectory(string relative)
    {
        var root = Environment.GetEnvironmentVariable("MLTD_WORK");
        if (string.IsNullOrEmpty(root))
            root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "mltd-work");
        return Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
    }

    private static string Expand(string directory)
    {
        if (string.IsNullOrEmpty(directory)) return directory;
        if (directory.StartsWith("~", StringComparison.Ordinal))
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), directory.Substring(1));
        return directory;
    }

    private void Start()
    {
        // Loading is deferred to the first Update: CharacterBootstrap builds MODEL_00 in its
        // own Start, and Unity does not guarantee the order between components. By the first
        // Update every Start has run, so the transform path map is complete.
        if (!playOnStart) loadAttempted = true;
    }

    /// <summary>
    /// Reads the JSON assets, builds the player and registers one motion at index 0.
    /// Safe to call again (probes call it after a script reload).
    /// </summary>
    public bool Load()
    {
        loadAttempted = true;
        loaded = false;
        loadError = null;
        var directory = Expand(motionDirectory);
        var imoPath = Path.Combine(directory, imoFile);
        if (!File.Exists(imoPath))
        {
            loadError = "imo JSON missing: " + imoPath;
            Debug.LogError("NativeMotionDriver: " + loadError);
            return false;
        }

        // Rebuild the path map at load time: CharacterBootstrap builds the body in its own
        // Start, so this is called from Update (after every Start) the first time round.
        byPath = BuildPathMap();
        ResolvePositionTarget();

        var asset = CharacterImasMotionAsset.Load(imoPath);
        data = CharacterImasMotionData.CreateFromImoAsset(asset);
        if (data == null)
        {
            loadError = "could not parse " + imoPath;
            Debug.LogError("NativeMotionDriver: " + loadError);
            return false;
        }

        optionalData = null;
        if (!string.IsNullOrEmpty(optionalImoFile))
        {
            var optionalPath = Path.Combine(directory, optionalImoFile);
            if (File.Exists(optionalPath))
            {
                optionalData = CharaOptionalImoData.CreateFromImoAsset(CharacterImasMotionAsset.Load(optionalPath));
            }
            else
            {
                Debug.LogWarning("NativeMotionDriver: optional imo missing: " + optionalPath);
            }
        }

        player = new CharacterImasMotionPlayerDance();
        player.path_resolver = ResolvePath;
        player.Create(gameObject);
        player.RegisterImoData(0, data, optionalData);
        player.SetLoopToMotion(0, loop);
        player.PlayMotion(0);
        time = 0f;
        loaded = true;

        // Native never applies a pose before the first Execute (0x1EDD228):
        // the character shows its bind pose for that first frame (deviation
        // audit B-5 — removed the early ApplyFrame).
        Debug.Log("NativeMotionDriver: loaded " + data.name + " (" + data.curve_sets.Count +
                  " curve sets, length " + data.length.ToString("F3") + "s)" +
                  (optionalData != null ? " + optional" : string.Empty));
        return true;
    }

    /// <summary>Registers an extra motion (appeal clip etc.) without starting it.</summary>
    public bool LoadMotion(int index, string imoPath, string optionalPath, bool isLoop)
    {
        var asset = CharacterImasMotionAsset.Load(Path.IsPathRooted(imoPath) ? imoPath : Path.Combine(Expand(motionDirectory), imoPath));
        if (asset == null)
        {
            Debug.LogError("NativeMotionDriver: cannot load motion " + imoPath);
            return false;
        }
        var motion = CharacterImasMotionData.CreateFromImoAsset(asset);
        CharaOptionalImoData optional = null;
        if (!string.IsNullOrEmpty(optionalPath))
        {
            var optionalAsset = CharacterImasMotionAsset.Load(Path.IsPathRooted(optionalPath) ? optionalPath : Path.Combine(Expand(motionDirectory), optionalPath));
            optional = CharaOptionalImoData.CreateFromImoAsset(optionalAsset);
        }
        if (player == null)
        {
            player = new CharacterImasMotionPlayerDance();
            player.path_resolver = ResolvePath;
            player.Create(gameObject);
        }
        player.RegisterImoData(index, motion, optional);
        player.SetLoopToMotion(index, isLoop);
        return true;
    }

    /// <summary>Switches to a registered motion (native PlayMotion resets time to 0).</summary>
    public void Play(int index)
    {
        if (player == null) return;
        player.PlayMotion(index);
        player.SetLoopToMotion(index, loop);
        time = 0f;
        // Native PlayMotion does not solve ahead; the next Execute lands the pose.
    }

    public void SetLoop(bool isLoop)
    {
        loop = isLoop;
        if (player != null) player.SetLoopToMotion(player.CurrentMotionIndex, isLoop);
    }

    /// <summary>Jumps to an absolute time (seconds) and applies that pose immediately.</summary>
    private bool timeSeeded;

    public void Seek(float seconds)
    {
        if (player == null) return;
        time = seconds;
        timeSeeded = true;
        player.SetTime(seconds);
        // UpdateTime transfers next_time -> current_time and only wraps when the *previous*
        // current_time already ran past the length. Seed current_time too so a plain seek
        // does not depend on whatever frame happened to be current before.
        player.current_time = seconds;
        player.UpdateTime(0f);
        player.SolveCurves(false);
        if (player.HasCurrentMotionOptionalImoData()) player.SolveOptionalCurves();
        player.SetResultToTransforms();
    }

    private void Update()
    {
        if (!loadAttempted)
        {
            // Deferred one frame so CharacterBootstrap.Start has instantiated MODEL_00.
            Load();
            return;
        }
        if (!loaded) return;
        if (paused) return;
        // Delta-driven flow (UpdateTime 0x37EDF1C semantics). The native dance
        // driver feeds a music-synced absolute time that never leaves [0,
        // length); this standalone player instead accumulates INSIDE the
        // player: UpdateTime advances next_time by the delta and the wrap
        // branch fires exactly once when current_time crosses the length.
        // Feeding an ever-growing absolute time via SetTime + UpdateTime(0)
        // breaks that invariant: current_time alternates between the wrapped
        // value and the raw out-of-range one, so SolveCurves evaluates the
        // pose at two different times on alternating frames (the reported
        // "flash"/flip, and the sway fed by those alternating parents).
        if (!timeSeeded)
        {
            player.SetTime(0f);
            player.current_time = 0f;
            timeSeeded = true;
        }
        player.UpdateTime(Time.deltaTime * speed);
        time = player.current_time;
        player.SolveCurves(dontInterpolateThisFrame);
        if (player.HasCurrentMotionOptionalImoData()) player.SolveOptionalCurves();
        player.SetResultToTransforms();
    }

    // B-5: ApplyFrame() removed — the native DanceMotionPlayer lands no pose
    // before the first Execute (0x1EDD228); the first Update() call after load
    // is the only pose source.

    // ------------------------------------------------------------------ paths

    /// <summary>
    /// Rebuilds the transform path map. The imo paths are rooted at MODEL_00
    /// (e.g. `MODEL_00/BASE/KOSHI/MOMO_L`), and the spike hierarchy carries extra wrappers
    /// around it, so the map keys are cut at the nearest ancestor named MODEL_00 — the same
    /// rule `CharacterBootstrap.PathOf` uses.
    /// </summary>
    public void RebuildPathMap()
    {
        byPath = BuildPathMap();
        if (player != null && player.CurrentMotionIndex >= 0)
        {
            // Re-register so the binders pick up the new transforms.
            var motion = data;
            var optional = optionalData;
            if (motion != null)
            {
                player.RegisterImoData(player.CurrentMotionIndex, motion, optional);
                player.SetLoopToMotion(player.CurrentMotionIndex, loop);
                player.PlayMotion(player.CurrentMotionIndex);
                time = 0f;
                // B-5: no pose before the first Execute. The next Update() runs the
                // native pipeline (UpdateTime→SolveCurves→optional→SetResult) exactly
                // like the first Execute landing the pose.
            }
        }
    }

    private Dictionary<string, Transform> BuildPathMap()
    {
        var map = new Dictionary<string, Transform>(StringComparer.Ordinal);
        var root = FindModelRoot();
        if (root == null) root = transform;
        var all = GetComponentsInChildren<Transform>(true);
        for (var i = 0; i < all.Length; i++)
        {
            var current = all[i];
            if (current == null) continue;
            var parts = new List<string>();
            var rooted = false;
            for (var t = current; t != null; t = t.parent)
            {
                parts.Add(t.name);
                if (t == root)
                {
                    rooted = true;
                    break;
                }
            }
            if (!rooted) continue;
            parts.Reverse();
            var key = string.Join("/", parts);
            if (!map.ContainsKey(key)) map[key] = current;
        }
        return map;
    }

    private Transform FindModelRoot()
    {
        var all = GetComponentsInChildren<Transform>(true);
        for (var i = 0; i < all.Length; i++)
            if (all[i] != null && all[i].name == "MODEL_00") return all[i];
        return null;
    }

    private void ResolvePositionTarget()
    {
        if (positionTarget != null || string.IsNullOrEmpty(positionTargetPath)) return;
        var direct = transform.Find(positionTargetPath);
        if (direct != null)
        {
            positionTarget = direct;
            return;
        }
        var all = GetComponentsInChildren<Transform>(true);
        for (var i = 0; i < all.Length; i++)
        {
            if (all[i] != null && all[i].name == positionTargetPath)
            {
                positionTarget = all[i];
                return;
            }
        }
        // Not fatal: native also skips a curve set whose Transform.Find fails (0x37ECCE4).
        Debug.LogWarning("NativeMotionDriver: no '" + positionTargetPath +
                         "' node; POSITION track skipped (assign positionTarget to enable stage placement).");
    }

    private Transform ResolvePath(Transform root, string path)
    {
        if (string.IsNullOrEmpty(path)) return null;
        if (positionTarget != null && !string.IsNullOrEmpty(positionTargetPath) &&
            (path == positionTargetPath || path.StartsWith(positionTargetPath + "/", StringComparison.Ordinal)))
        {
            return positionTarget;
        }
        var key = stripBodyScaleNode ? path.Replace("/BODY_SCALE", string.Empty) : path;
        if (byPath != null && byPath.TryGetValue(key, out var found)) return found;
        if (logUnmappedTracks && loggedUnmapped.Add(key))
            Debug.LogWarning("NativeMotionDriver: no transform for imo path '" + path + "'");
        return null;
    }
}
