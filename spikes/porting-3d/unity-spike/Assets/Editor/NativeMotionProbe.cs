using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using Imas;
using Imas.CharaImasMotion;
using UnityEditor;
using UnityEngine;
using CharaImasMotion = Imas.CharaImasMotion;

/// <summary>
/// Editor probe for the native-faithful motion port. Two modes:
///
///  * Data probe — evaluates the raw imo curves at chosen times without a scene. The lines
///    are the contract for the numeric cross-check against `motion.py` /
///    /tmp/motion-native-samples.py (same value semantics, printed with "R"-style floats).
///  * Scene probe — seeks a <see cref="NativeMotionDriver"/> to chosen times and prints,
///    per bound curve set, the solved angle/position plus what actually landed on the
///    transforms. This is the "one frame, every track" table for comparing with the game.
///
/// Times come from `MLTD_PROBE_TIMES` (comma separated seconds), default `0,1,30`.
/// Output goes to `$MLTD_WORK/out/native-motion-probe.txt` unless a path is passed.
/// </summary>
public static class NativeMotionProbe
{
    private const string DefaultImoFile = "dan_loveig_01_dan.imo.imo.json";
    private const string DefaultOptionalFile = "dan_amater_01_apg.opt.imo.imo.json";

    // ---------------------------------------------------------------- menu

    [MenuItem("MLTD/Native Motion/Probe Data (imo json)")]
    public static void ProbeDataMenu()
    {
        var times = ProbeTimes();
        var imo = Environment.GetEnvironmentVariable("MLTD_PROBE_IMO");
        if (string.IsNullOrEmpty(imo)) imo = DefaultImoFile;
        var optional = Environment.GetEnvironmentVariable("MLTD_PROBE_OPT");
        if (string.IsNullOrEmpty(optional)) optional = DefaultOptionalFile;
        var outPath = Path.Combine(WorkDirectory("out"), "native-motion-probe.txt");
        var report = RunDataProbe(WorkDirectory("motion"), imo, optional, times, outPath);
        Debug.Log(report);
    }

    [MenuItem("MLTD/Native Motion/Probe Scene Driver")]
    public static void ProbeSceneMenu()
    {
        var driver = UnityEngine.Object.FindFirstObjectByType<NativeMotionDriver>();
        if (driver == null)
        {
            Debug.LogError("NativeMotionProbe: no NativeMotionDriver in the open scene.");
            return;
        }
        var outPath = Path.Combine(WorkDirectory("out"), "native-motion-pose.txt");
        var report = RunSceneProbe(driver, ProbeTimes(), outPath);
        Debug.Log(report);
    }

    [MenuItem("MLTD/Native Motion/Reload Scene Driver")]
    public static void ReloadSceneDriverMenu()
    {
        var driver = UnityEngine.Object.FindFirstObjectByType<NativeMotionDriver>();
        if (driver == null)
        {
            Debug.LogError("NativeMotionProbe: no NativeMotionDriver in the open scene.");
            return;
        }
        driver.Load();
        Debug.Log("NativeMotionProbe: driver reloaded (" + driver.IsLoaded + ")");
    }

    // ------------------------------------------------------------- data probe

    /// <summary>
    /// Samples every curve of the given assets at the given times and returns the report
    /// (also written to `outputPath` when it is not empty). Pure data; no scene needed.
    /// </summary>
    public static string RunDataProbe(string motionDirectory, string imoFile, string optionalFile,
                                      float[] times, string outputPath)
    {
        var report = new StringBuilder(64 * 1024);
        report.AppendLine("# native motion data probe");
        report.AppendLine("# solve per curve: CharacterImasMotionPlayer.SolveCurve (native 0x37E80B8)");
        report.AppendLine("# format: t=<s> path=<imo path> property=<PropertyType> key_type=<KeyType> value=<float>");
        if (times == null || times.Length == 0) times = new[] { 0f, 1f, 30f };

        var directory = motionDirectory;
        var asset = CharacterImasMotionAsset.Load(Path.Combine(directory, imoFile));
        if (asset == null)
        {
            report.AppendLine("# ERROR cannot load " + Path.Combine(directory, imoFile));
            Write(report, outputPath);
            return report.ToString();
        }
        var data = CharacterImasMotionData.CreateFromImoAsset(asset);
        report.AppendLine("# asset=" + data.name + " kind=" + asset.kind + " length=" + F(data.length) +
                          " curve_sets=" + data.curve_sets.Count);
        for (var t = 0; t < times.Length; t++)
        {
            var time = times[t];
            report.AppendLine("# t=" + F(time));
            for (var s = 0; s < data.curve_sets.Count; s++)
            {
                var set = data.curve_sets[s];
                AppendCurve(report, time, set.path, "AngleX", set.rx);
                AppendCurve(report, time, set.path, "AngleY", set.ry);
                AppendCurve(report, time, set.path, "AngleZ", set.rz);
                AppendCurve(report, time, set.path, "PositionX", set.px);
                AppendCurve(report, time, set.path, "PositionY", set.py);
                AppendCurve(report, time, set.path, "PositionZ", set.pz);
            }
        }

        if (!string.IsNullOrEmpty(optionalFile))
        {
            var optionalPath = Path.Combine(directory, optionalFile);
            var optionalAsset = CharacterImasMotionAsset.Load(optionalPath);
            if (optionalAsset == null)
            {
                report.AppendLine("# optional missing: " + optionalPath);
            }
            else
            {
                var optional = CharaOptionalImoData.CreateFromImoAsset(optionalAsset);
                report.AppendLine("# optional=" + optionalAsset.name + " kind=" + optionalAsset.kind +
                                  " length=" + F(optional.length));
                for (var t = 0; t < times.Length; t++)
                {
                    var time = times[t];
                    report.AppendLine("# t=" + F(time));
                    for (var i = 0; i < optional.curves.Length; i++)
                    {
                        var curve = optional.curves[i];
                        if (curve == null) continue;
                        AppendCurve(report, time, "optional[" + i + "]", curve.property_name, curve);
                    }
                }
            }
        }

        Write(report, outputPath);
        return report.ToString();
    }

    private static void AppendCurve(StringBuilder report, float time, string path, string property,
                                    CharaImasMotion.Curve curve)
    {
        if (curve == null) return;
        var seeker = 0;
        var value = CharacterImasMotionPlayer.SolveCurve(curve, time, ref seeker);
        report.Append("t=").Append(F(time))
              .Append(" path=").Append(path)
              .Append(" property=").Append(property)
              .Append(" key_type=").Append(curve.key_type)
              .Append(" value=").Append(F(value))
              .AppendLine();
    }

    // ------------------------------------------------------------ scene probe

    /// <summary>
    /// Seeks the driver to each time and dumps every bound track: the solved angle/position
    /// and the values that ended up on the transform.
    /// </summary>
    public static string RunSceneProbe(NativeMotionDriver driver, float[] times, string outputPath)
    {
        var report = new StringBuilder(64 * 1024);
        report.AppendLine("# native motion pose probe (scene)");
        report.AppendLine("# format: t=<s> path=<imo path> angle=(x,y,z) position=(x,y,z) has_position=<0|1> local_pos=(x,y,z) euler=(x,y,z)");
        if (driver == null)
        {
            report.AppendLine("# ERROR no driver");
            Write(report, outputPath);
            return report.ToString();
        }
        if (!driver.IsLoaded) driver.Load();
        if (!driver.IsLoaded)
        {
            report.AppendLine("# ERROR driver not loaded: " + driver.LoadError);
            Write(report, outputPath);
            return report.ToString();
        }
        var player = driver.Player;
        if (times == null || times.Length == 0) times = new[] { 0f, 1f, 30f };

        for (var t = 0; t < times.Length; t++)
        {
            var time = times[t];
            driver.Seek(time);
            report.AppendLine("# t=" + F(time) + " current_time=" + F(player.current_time));
            var count = player.BinderCount;
            for (var i = 0; i < count; i++)
            {
                var binder = player.GetBinder(i);
                if (binder == null || binder.curve_set == null) continue;
                var result = player.GetResult(i);
                report.Append("t=").Append(F(time))
                      .Append(" path=").Append(binder.curve_set.path);
                if (result != null)
                {
                    report.Append(" angle=").Append(V(result.angle))
                          .Append(" position=").Append(V(result.position));
                }
                else
                {
                    report.Append(" angle=<none> position=<none>");
                }
                report.Append(" has_position=").Append(binder.curve_set.HasPosition ? 1 : 0);
                if (binder.tr != null)
                {
                    report.Append(" local_pos=").Append(V(binder.tr.localPosition))
                          .Append(" euler=").Append(V(binder.tr.localRotation.eulerAngles));
                }
                else
                {
                    report.Append(" local_pos=<no transform> euler=<no transform>");
                }
                report.AppendLine();
            }
        }

        Write(report, outputPath);
        return report.ToString();
    }

    // -------------------------------------------------------------- helpers

    public static float[] ProbeTimes()
    {
        var raw = Environment.GetEnvironmentVariable("MLTD_PROBE_TIMES");
        if (string.IsNullOrEmpty(raw)) return new[] { 0f, 1f, 30f };
        var parts = raw.Split(',');
        var times = new List<float>();
        for (var i = 0; i < parts.Length; i++)
        {
            if (float.TryParse(parts[i], NumberStyles.Float, CultureInfo.InvariantCulture, out var value))
                times.Add(value);
        }
        return times.Count > 0 ? times.ToArray() : new[] { 0f, 1f, 30f };
    }

    private static string WorkDirectory(string relative)
    {
        var root = Environment.GetEnvironmentVariable("MLTD_WORK");
        if (string.IsNullOrEmpty(root))
            root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "mltd-work");
        return Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
    }

    private static void Write(StringBuilder report, string outputPath)
    {
        if (string.IsNullOrEmpty(outputPath)) return;
        var directory = Path.GetDirectoryName(outputPath);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        File.WriteAllText(outputPath, report.ToString());
        Debug.Log("NativeMotionProbe: wrote " + outputPath);
    }

    // "R" round-trips a float; the C# reference implementation prints the same shape.
    private static string F(float value)
    {
        return value.ToString("R", CultureInfo.InvariantCulture);
    }

    private static string V(Vector3 value)
    {
        return "(" + F(value.x) + "," + F(value.y) + "," + F(value.z) + ")";
    }
}
