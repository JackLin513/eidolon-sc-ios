using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using UnityEditor;
using UnityEngine;

/// <summary>
/// Verification harness for <see cref="CalcBoneNative"/>.
///
/// It binds the native CalcBone pass to the character that
/// <see cref="CharacterBootstrap"/> built, lists what the pass registered
/// (algorithm / reference bones / parsed parameters), and dumps the assist bones'
/// local rotations per clip frame so a run can be diffed against another build
/// (or against a capture of the game). It does not touch the old
/// <see cref="HelperBones"/> component.
/// </summary>
public static class CalcBoneProbe
{
    /// <summary>Path used by the dump menu items (overridable for diffing runs).</summary>
    public static string DumpPath
    {
        get
        {
            var root = Environment.GetEnvironmentVariable("MLTD_WORK");
            if (string.IsNullOrEmpty(root))
                root = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "mltd-work");
            return Path.Combine(root, "out", "calcbone-frames.txt");
        }
    }

    // ------------------------------------------------------------------
    // Binding
    // ------------------------------------------------------------------

    /// <summary>
    /// Adds (or reuses) a <see cref="CalcBoneNative"/> on the character root and
    /// binds it to the current rest pose. Must run while the rig is in bind pose
    /// — before any clip frame is applied — because binding captures
    /// `initMyRot` / `initRefRot` / `initMyPosition`.
    /// </summary>
    public static CalcBoneNative Bind()
    {
        var bootstrap = UnityEngine.Object.FindObjectOfType<CharacterBootstrap>();
        if (bootstrap == null)
        {
            Debug.LogError("CalcBoneProbe: no CharacterBootstrap in the scene");
            return null;
        }

        var cb = bootstrap.GetComponent<CalcBoneNative>();
        if (cb == null) cb = bootstrap.gameObject.AddComponent<CalcBoneNative>();
        cb.Bind(bootstrap.transform);
        Debug.Log("CalcBoneProbe: bound " + cb.Count + " assist bones on '" + bootstrap.name + "'");
        return cb;
    }

    /// <summary>Character currently in the scene, bound and ready for stepping.</summary>
    public static CharacterBootstrap Character()
    {
        return UnityEngine.Object.FindObjectOfType<CharacterBootstrap>();
    }

    // ------------------------------------------------------------------
    // Registration report
    // ------------------------------------------------------------------

    /// <summary>
    /// One line per registered assist bone: algorithm, own name, reference
    /// bone(s), parsed t/tx/axis and the captured rest rotations. This is the
    /// "what did the native grammar decide for this model" view.
    /// </summary>
    public static string Describe(CalcBoneNative cb)
    {
        if (cb == null) return "CalcBoneProbe: not bound";
        var sb = new StringBuilder();
        sb.Append("CalcBoneNative: ").Append(cb.Count).Append(" assist bones\n");
        sb.Append("  #  type                 my bone                              ref1                 ref2                 t     tx    axis  initMyRot(euler)\n");
        for (var i = 0; i < cb.Infos.Count; i++)
        {
            var info = cb.Infos[i];
            sb.Append(i.ToString(CultureInfo.InvariantCulture).PadLeft(3)).Append("  ");
            sb.Append(info.type.ToString().PadRight(20)).Append("  ");
            sb.Append(Trim(info.myPath, 34).PadRight(34)).Append("  ");
            sb.Append(Trim(info.referPath, 20).PadRight(20)).Append("  ");
            sb.Append(Trim(info.referPath2, 20).PadRight(20)).Append("  ");
            sb.Append(info.t.ToString("F2", CultureInfo.InvariantCulture).PadLeft(4)).Append("  ");
            sb.Append(info.tx.ToString("F2", CultureInfo.InvariantCulture).PadLeft(4)).Append("  ");
            sb.Append(info.axis.ToString(CultureInfo.InvariantCulture).PadLeft(4)).Append("  ");
            sb.Append(Euler(info.initMyRot));
            sb.Append('\n');
        }
        return sb.ToString();
    }

    /// <summary>
    /// Compact parameter/type table for the same bones, one line per bone,
    /// suitable for pasting into a report or diffing against the native dump.
    /// </summary>
    public static string Table(CalcBoneNative cb)
    {
        if (cb == null) return "CalcBoneProbe: not bound";
        var sb = new StringBuilder();
        for (var i = 0; i < cb.Infos.Count; i++)
        {
            var info = cb.Infos[i];
            sb.Append(info.type).Append('\t')
              .Append(info.myPath).Append('\t')
              .Append(info.referPath ?? "-").Append('\t')
              .Append(info.referPath2 ?? "-").Append('\t')
              .Append(info.t.ToString("R", CultureInfo.InvariantCulture)).Append('\t')
              .Append(info.tx.ToString("R", CultureInfo.InvariantCulture)).Append('\t')
              .Append(info.axis.ToString(CultureInfo.InvariantCulture));
            sb.Append('\n');
        }
        return sb.ToString();
    }

    // ------------------------------------------------------------------
    // Per-frame pose dumps
    // ------------------------------------------------------------------

    /// <summary>
    /// Seeks the current clip to <paramref name="frame"/>, runs one native solve
    /// pass, and returns every assist bone's current localRotation (x,y,z,w and
    /// euler for readability). Frames are the packed 30 fps clip frames the
    /// bootstrap uses.
    /// </summary>
    public static string Frame(int frame)
    {
        var cb = Bind();
        if (cb == null) return "CalcBoneProbe: not bound";
        var bootstrap = Character();
        if (bootstrap == null) return "CalcBoneProbe: no CharacterBootstrap";

        bootstrap.Seek(frame);
        cb.ExplictUpdate();
        return Rotations(cb, "frame " + frame);
    }

    /// <summary>
    /// Dumps the assist-bone local rotations for a frame range:
    /// <c>frame \t bone \t x y z w \t euler</c>.
    /// </summary>
    public static string Dump(int fromFrame, int toFrame, int step)
    {
        var cb = Bind();
        if (cb == null) return "CalcBoneProbe: not bound";
        var bootstrap = Character();
        if (bootstrap == null) return "CalcBoneProbe: no CharacterBootstrap";
        if (step <= 0) step = 1;

        var sb = new StringBuilder();
        sb.Append("# CalcBoneNative dump (30 fps packed clip frames)\n");
        sb.Append("# ").Append(Describe(cb));
        for (var frame = fromFrame; frame <= toFrame; frame += step)
        {
            bootstrap.Seek(frame);
            cb.ExplictUpdate();
            sb.Append(Rotations(cb, frame.ToString(CultureInfo.InvariantCulture)));
        }
        return sb.ToString();
    }

    /// <summary>
    /// Rest-pose vs. clip-frame comparison: useful to prove a rule bites and to
    /// A/B against a different implementation of the same pass. When
    /// <paramref name="withPass"/> is false the assist bones are left at whatever
    /// the clip wrote, i.e. the pose without the CalcBone pass.
    /// </summary>
    public static string FramePair(int frame, bool withPass)
    {
        var cb = Bind();
        if (cb == null) return "CalcBoneProbe: not bound";
        var bootstrap = Character();
        if (bootstrap == null) return "CalcBoneProbe: no CharacterBootstrap";

        bootstrap.Seek(frame);
        if (withPass) cb.ExplictUpdate();
        return Rotations(cb, frame + (withPass ? " with CalcBone" : " without CalcBone"));
    }

    // ------------------------------------------------------------------
    // Menu items
    // ------------------------------------------------------------------

    [MenuItem("MLTD/CalcBone: bind + describe")]
    public static void MenuBindDescribe()
    {
        var cb = Bind();
        if (cb != null) Debug.Log(Describe(cb));
    }

    [MenuItem("MLTD/CalcBone: dump parameters")]
    public static void MenuTable()
    {
        var cb = Bind();
        if (cb != null) Debug.Log(Table(cb));
    }

    [MenuItem("MLTD/CalcBone: dump frame 0 vs frame 45 (with/without pass)")]
    public static void MenuCompareFrame45()
    {
        var cb = Bind();
        if (cb == null) return;
        var bootstrap = Character();
        if (bootstrap == null) return;

        bootstrap.Seek(0);
        Debug.Log(Rotations(cb, "frame 0 (rest/bind)"));
        var without = FramePair(45, false);
        var with = FramePair(45, true);
        Debug.Log(without);
        Debug.Log(with);
        Debug.Log(Diff(without, with));
    }

    [MenuItem("MLTD/CalcBone: dump 0..N frames to " + "MLTD_WORK/out/calcbone-frames.txt")]
    public static void MenuDumpRange()
    {
        var bootstrap = Character();
        var frames = bootstrap != null && bootstrap.Clip != null ? bootstrap.Clip.Frames : 61;
        var text = Dump(0, frames - 1, 1);
        var path = DumpPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
        File.WriteAllText(path, text);
        Debug.Log("CalcBoneProbe: wrote " + frames + " frames to " + path);
    }

    // ------------------------------------------------------------------
    // Formatting helpers
    // ------------------------------------------------------------------

    private static string Rotations(CalcBoneNative cb, string label)
    {
        var sb = new StringBuilder();
        sb.Append("# ").Append(label).Append('\n');
        for (var i = 0; i < cb.Infos.Count; i++)
        {
            var info = cb.Infos[i];
            var q = info.myTransform.localRotation;
            sb.Append(info.myPath).Append('\t')
              .Append(q.x.ToString("F7", CultureInfo.InvariantCulture)).Append(' ')
              .Append(q.y.ToString("F7", CultureInfo.InvariantCulture)).Append(' ')
              .Append(q.z.ToString("F7", CultureInfo.InvariantCulture)).Append(' ')
              .Append(q.w.ToString("F7", CultureInfo.InvariantCulture)).Append('\t')
              .Append(Euler(q)).Append('\n');
        }
        return sb.ToString();
    }

    /// <summary>
    /// Line diff of two <see cref="Rotations"/> blocks (same bone order): reports
    /// the largest per-component delta, which is what "does the rule bite / do
    /// two implementations agree" needs.
    /// </summary>
    private static string Diff(string withoutPass, string withPass)
    {
        var a = ParseQuaternions(withoutPass);
        var b = ParseQuaternions(withPass);
        var sb = new StringBuilder("CalcBoneProbe diff (max |delta| per bone):\n");
        var worst = 0f;
        var worstName = "-";
        for (var i = 0; i < a.Count && i < b.Count; i++)
        {
            var da = Mathf.Max(
                Mathf.Abs(a[i].Value.x - b[i].Value.x),
                Mathf.Max(
                    Mathf.Abs(a[i].Value.y - b[i].Value.y),
                    Mathf.Max(Mathf.Abs(a[i].Value.z - b[i].Value.z), Mathf.Abs(a[i].Value.w - b[i].Value.w))));
            if (da <= 1e-5f) continue;
            sb.Append("  ").Append(a[i].Key).Append("  delta=")
              .Append(da.ToString("F6", CultureInfo.InvariantCulture)).Append('\n');
            if (da > worst) { worst = da; worstName = a[i].Key; }
        }
        sb.Append("  worst: ").Append(worstName).Append(" = ")
          .Append(worst.ToString("F6", CultureInfo.InvariantCulture)).Append('\n');
        return sb.ToString();
    }

    private static List<KeyValuePair<string, Quaternion>> ParseQuaternions(string block)
    {
        var list = new List<KeyValuePair<string, Quaternion>>();
        foreach (var raw in block.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line[0] == '#') continue;
            var tab = line.IndexOf('\t');
            if (tab < 0) continue;
            var name = line.Substring(0, tab);
            var parts = line.Substring(tab + 1).Split('\t')[0].Split(' ');
            if (parts.Length < 4) continue;
            if (!float.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var x)) continue;
            if (!float.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var y)) continue;
            if (!float.TryParse(parts[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var z)) continue;
            if (!float.TryParse(parts[3], NumberStyles.Float, CultureInfo.InvariantCulture, out var w)) continue;
            list.Add(new KeyValuePair<string, Quaternion>(name, new Quaternion(x, y, z, w)));
        }
        return list;
    }

    private static string Euler(Quaternion q)
    {
        var e = q.eulerAngles;
        return e.x.ToString("F3", CultureInfo.InvariantCulture) + "," +
               e.y.ToString("F3", CultureInfo.InvariantCulture) + "," +
               e.z.ToString("F3", CultureInfo.InvariantCulture);
    }

    private static string Trim(string value, int width)
    {
        if (string.IsNullOrEmpty(value)) return "-";
        return value.Length <= width ? value : value.Substring(0, width - 1) + "~";
    }
}
