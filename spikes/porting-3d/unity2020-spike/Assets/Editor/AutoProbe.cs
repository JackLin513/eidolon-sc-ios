using System;
using System.IO;
using UnityEditor;
using UnityEngine;

/// Runs the bundle/animation probes once, the first time this project is
/// opened in Unity 2020.3.32f1 (the version the game's bundles were built
/// with), then deletes the request file so a later open does nothing.
public static class AutoProbe
{
    private const string RequestFile = "../unity2020-probe.request";
    private const string ReportFile = "/tmp/mltd-unity2020-report.txt";

    [InitializeOnLoadMethod]
    private static void Queue()
    {
        EditorApplication.delayCall += Run;
    }

    /// `-executeMethod AutoProbe.ForceRun` runs it without the marker file.
    public static void ForceRun()
    {
        Run(force: true);
    }

    private static void Run()
    {
        Run(force: false);
    }

    private static void Run(bool force)
    {
        var request = Path.GetFullPath(Path.Combine(Application.dataPath, RequestFile));
        if (!force && !File.Exists(request)) return;
        try
        {
            var log = new System.Text.StringBuilder();
            log.AppendLine($"unity {Application.unityVersion}");
            Application.LogCallback capture = (condition, stack, type) =>
                log.AppendLine($"{type}: {condition}");
            Application.logMessageReceived += capture;
            // One probe per session: an AssetBundle cannot be loaded twice in
            // one process, and BundleProbe keeps its bundles alive.
            RetargetProbe.Run();
            Application.logMessageReceived -= capture;
            var bundleReport = File.Exists("/tmp/mltd-unity-out/report.txt")
                ? File.ReadAllText("/tmp/mltd-unity-out/report.txt") : "";
            var motionReport = File.Exists("/tmp/mltd-unity-out/motion-report.txt")
                ? File.ReadAllText("/tmp/mltd-unity-out/motion-report.txt") : "";
            var retargetReport = File.Exists("/tmp/mltd-unity-out/retarget-report.txt")
                ? File.ReadAllText("/tmp/mltd-unity-out/retarget-report.txt") : "";
            File.WriteAllText(ReportFile, log + "\n--- bundle ---\n" + bundleReport
                + "\n--- motion ---\n" + motionReport
                + "\n--- retarget ---\n" + retargetReport);
        }
        catch (Exception exception)
        {
            File.WriteAllText(ReportFile, $"FAILED {exception}");
        }
        finally
        {
            if (File.Exists(request)) File.Delete(request);
        }
    }
}
