using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using UnityEditor;
using UnityEngine;

/// <summary>
/// Verification harness for ADR-0033 B5: <see cref="CharacterSoulNative"/>'s
/// <c>Imas.CharacterSoul</c> table, <see cref="CharacterDrawerNative"/> and
/// <see cref="JointBodyHeadNative"/>.
///
/// Menu items under <c>MLTD/Drawer+JBH</c>:
/// <list type="bullet">
/// <item><b>soul: load chara_soul</b> — open <c>chara_soul.unity3d</c> from the snapshot
///   and report the table (61 rows, 21 means).</item>
/// <item><b>soul: dump one character</b> — every Value&lt;T&gt; of the current cid with
///   its isValid flag (this is the data-gap report: native leaves a Value invalid when
///   a column is absent, and the probe shows exactly which ones).</item>
/// <item><b>soul: dump all 61</b> — one line per character (compact).</item>
/// <item><b>soul: motif table</b> — the short-name table used by
///   <c>SoulDataCharacter.ShortNameToCharacterMotif</c> plus the motif values actually
///   present in the asset (the literal table itself is UNKNOWN, see the C# comments).</item>
/// <item><b>drawer: bind / describe</b> — attach <see cref="CharacterDrawerNative"/> to
///   the character, register every material, then dump the state.</item>
/// <item><b>drawer: dump material params</b> — every shader property the B5 subset can
///   touch, per registered material (the bundle inventory subset).</item>
/// <item><b>drawer: exercise API</b> — call the whole subset once with deterministic
///   values and dump the resulting material state (outline / stencil / rim / cheek).</item>
/// <item><b>jbh: bind / describe</b> — build a <see cref="JointBodyHeadNative"/>, run the
///   native assembly order, bind the B2 sway rig and dump every resolved node.</item>
/// <item><b>jbh: dump sway wiring</b> — per manager: on / followRate / transBack / swayOn
///   plus the manager's bone count.</item>
/// <item><b>jbh: switches</b> — SwaySwitch / SwayManagerAllON / skirt_GP_SwayManagerCtrl /
///   SetVisible round trips.</item>
/// </list>
/// Dumps go to <c>$MLTD_WORK/out/drawer-jbh-probe.txt</c> (or <c>~/mltd-work/out</c>) in
/// addition to the Console, so they can be diffed against a game capture.
/// </summary>
public static class DrawerJbhProbe
{
    public static string DumpPath
    {
        get
        {
            var root = Environment.GetEnvironmentVariable("MLTD_WORK");
            if (string.IsNullOrEmpty(root))
                root = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "mltd-work");
            return Path.Combine(root, "out", "drawer-jbh-probe.txt");
        }
    }

    // ------------------------------------------------------------------
    // Scene lookups
    // ------------------------------------------------------------------

    private static CharacterBootstrap Character()
    {
        return UnityEngine.Object.FindObjectOfType<CharacterBootstrap>();
    }

    private static string CharacterId(CharacterBootstrap bootstrap)
    {
        var name = bootstrap.bodyBundle.Replace(".unity3d", "");
        var parts = name.Split('_');
        return parts.Length >= 3 ? parts[parts.Length - 1] : name;
    }

    /// <summary>`$MLTD_WORK/assets/&lt;version&gt;/files/&lt;sha1&gt;.unity3d` — the snapshot layout.</summary>
    private static string SnapshotBundlePath(string assetName)
    {
        var root = Environment.GetEnvironmentVariable("MLTD_WORK");
        if (string.IsNullOrEmpty(root))
            root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "mltd-work");
        var assetsRoot = Path.Combine(root, "assets");
        if (!Directory.Exists(assetsRoot)) return null;

        // snapshot.json maps "<name>" -> { "file": "files/<sha1>.unity3d" }.
        foreach (var versionDir in Directory.GetDirectories(assetsRoot))
        {
            var snapshot = Path.Combine(versionDir, "snapshot.json");
            if (!File.Exists(snapshot)) continue;
            var entry = FindSnapshotEntry(File.ReadAllText(snapshot), assetName);
            if (entry == null) continue;
            var path = Path.Combine(versionDir, entry);
            if (File.Exists(path)) return path;
        }
        return null;
    }

    private static string FindSnapshotEntry(string json, string assetName)
    {
        // Avoid a JSON dependency in the editor: the snapshot is a flat map whose keys
        // are the asset names, so a quoted-name search is enough.
        var key = "\"" + assetName + "\"";
        var at = json.IndexOf(key, StringComparison.Ordinal);
        if (at < 0) return null;
        var fileAt = json.IndexOf("\"file\"", at, StringComparison.Ordinal);
        if (fileAt < 0) return null;
        var colon = json.IndexOf(':', fileAt);
        if (colon < 0) return null;
        var open = json.IndexOf('"', colon + 1);
        if (open < 0) return null;
        var close = json.IndexOf('"', open + 1);
        if (close < 0) return null;
        return json.Substring(open + 1, close - open - 1).Replace('/', Path.DirectorySeparatorChar);
    }

    // ------------------------------------------------------------------
    // CharacterSoul
    // ------------------------------------------------------------------

    [MenuItem("MLTD/Drawer+JBH/soul: load chara_soul")]
    public static void SoulLoad()
    {
        var table = LoadSoulTable(out var error);
        if (table == null)
        {
            Dump("soul-load", "FAILED: " + error);
            return;
        }
        var text = table.Describe();
        var cid = CurrentCharacterId();
        if (!string.IsNullOrEmpty(cid) && table.TryGet(cid, out _))
            text += "\n" + table.DescribeGaps(cid);
        text += "\n" + MotifReport(table);
        Dump("soul-load", text);
    }

    [MenuItem("MLTD/Drawer+JBH/soul: dump one character")]
    public static void SoulDumpOne()
    {
        var table = LoadSoulTable(out var error);
        if (table == null) { Dump("soul-one", "FAILED: " + error); return; }
        var cid = CurrentCharacterId();
        if (!table.TryGet(cid, out var soul))
        {
            Dump("soul-one", "cid '" + cid + "' not in table");
            return;
        }
        Dump("soul-one", soul.Describe() + "\n" + table.DescribeGaps(cid));
    }

    [MenuItem("MLTD/Drawer+JBH/soul: dump all 61")]
    public static void SoulDumpAll()
    {
        var table = LoadSoulTable(out var error);
        if (table == null) { Dump("soul-all", "FAILED: " + error); return; }

        var sb = new StringBuilder();
        sb.AppendLine("cid        bodyScale bodySize reddenInt skinR skinG skinB inh0(255) inh2(255) stiff drag follow gravity motif");
        for (var i = 0; i < table.All.Count; i++)
        {
            var s = table.All[i];
            sb.Append((s.characterId.value ?? "?").PadRight(10));
            sb.Append(F(s.bodyScale, 8));
            sb.Append(F(s.bodySize, 9));
            sb.Append(F(s.cheekReddenIntensity, 10));
            sb.Append(C255(s.skinColor));
            sb.Append(C255(s.inherentColor));
            sb.Append(C255(s.inherentColor2));
            sb.Append(F(s.swayBreastStiffness, 7));
            sb.Append(F(s.swayBreastDrag, 6));
            sb.Append(F(s.swayBreastFollow, 7));
            sb.Append(F(s.swayBreastGravity, 8));
            sb.AppendLine(s.motif.isValid ? s.motif.value.ToString() : "<inv>");
        }
        Dump("soul-all", sb.ToString());
    }

    [MenuItem("MLTD/Drawer+JBH/soul: motif table")]
    public static void SoulMotifTable()
    {
        var table = LoadSoulTable(out var error);
        var sb = new StringBuilder();
        sb.Append("table = [").Append(string.Join(",", SoulDataCharacterShortNames())).AppendLine("]");
        sb.AppendLine("UNKNOWN(native 0x1C352B0/0x1C390A4): the four literals are IL2CPP");
        sb.AppendLine("metadata-usage pointers (0x9820680/0x9813C48/0x98095D0/0x980FB10) and");
        sb.AppendLine("are not statically resolvable; the order above is inferred from the");
        sb.AppendLine("asset's value set + CharacterMotif's declaration order.");
        if (table != null) sb.Append(MotifReport(table));
        else sb.Append("chara_soul load failed: ").Append(error);
        Dump("soul-motif", sb.ToString());
    }

    private static string[] SoulDataCharacterShortNames()
    {
        // Imas.SoulDataCharacter.DefaultMotifShortNames is the injected table.
        return Imas.SoulDataCharacter.DefaultMotifShortNames;
    }

    private static string MotifReport(Imas.CharacterSoulTable table)
    {
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var i = 0; i < table.All.Count; i++)
        {
            var s = table.All[i];
            var key = s.motif.isValid ? s.motif.value.ToString() : "<invalid>";
            counts.TryGetValue(key, out var n);
            counts[key] = n + 1;
        }
        var sb = new StringBuilder("\nmotif distribution:\n");
        foreach (var kv in counts) sb.Append("  ").Append(kv.Key.PadRight(10)).Append(kv.Value).AppendLine();
        return sb.ToString();
    }

    private static string CurrentCharacterId()
    {
        var bootstrap = Character();
        return bootstrap != null ? CharacterId(bootstrap) : null;
    }

    private static Imas.CharacterSoulTable LoadSoulTable(out string error)
    {
        error = null;
        var path = SnapshotBundlePath(Imas.CharacterSoulTable.BundleName);
        if (path == null)
        {
            error = "snapshot bundle not found for " + Imas.CharacterSoulTable.BundleName
                    + " (run spikes/porting-3d/fetch_snapshot.py --names chara_soul.unity3d)";
            return null;
        }
        var table = Imas.CharacterSoulTable.Load(path, out error);
        if (table != null) error = null;
        return table;
    }

    private static string F(Imas.CharacterSoul.Value<float> v, int width)
    {
        var s = v.isValid ? v.value.ToString("G6") : "<inv>";
        return s.PadRight(width);
    }

    private static string C255(Imas.CharacterSoul.Value<Color> v)
    {
        if (!v.isValid) return "<inv>".PadRight(16);
        var c = v.value;
        var s = "(" + Mathf.RoundToInt(c.r * 255f) + "," + Mathf.RoundToInt(c.g * 255f)
                + "," + Mathf.RoundToInt(c.b * 255f) + ")";
        return s.PadRight(16);
    }

    // ------------------------------------------------------------------
    // CharacterDrawer
    // ------------------------------------------------------------------

    [MenuItem("MLTD/Drawer+JBH/drawer: bind")]
    public static void DrawerBind()
    {
        var drawer = BindDrawer();
        if (drawer == null) return;
        Dump("drawer-bind", drawer.Describe());
    }

    [MenuItem("MLTD/Drawer+JBH/drawer: describe")]
    public static void DrawerDescribe()
    {
        var drawer = FindDrawer();
        if (drawer == null) return;
        Dump("drawer-describe", drawer.Describe() + "\n" + DumpRendererAndMaterials(drawer));
    }

    /// <summary>Adds (or reuses) a CharacterDrawerNative on the character root.</summary>
    public static CharacterDrawerNative BindDrawer()
    {
        var bootstrap = Character();
        if (bootstrap == null)
        {
            Debug.LogError("DrawerJbhProbe: no CharacterBootstrap in the scene");
            return null;
        }
        var drawer = bootstrap.GetComponent<CharacterDrawerNative>();
        if (drawer == null) drawer = bootstrap.gameObject.AddComponent<CharacterDrawerNative>();

        var model = bootstrap.transform.Find("MODEL_00_holder");
        var root = model != null ? model.gameObject : bootstrap.gameObject;
        drawer.Create(0, root, CharacterId(bootstrap), bootstrap.GetComponent<JointBodyHeadNative>());

        var face = bootstrap.GetComponent<FaceCtrlNative>();
        if (face != null) face.drawer = drawer;

        Debug.Log("DrawerJbhProbe: bound CharacterDrawerNative to '" + bootstrap.name
                  + "' cid=" + CharacterId(bootstrap)
                  + " renmats=" + drawer.GetNumOfRendererAndMaterials());
        return drawer;
    }

    private static CharacterDrawerNative FindDrawer()
    {
        var drawer = UnityEngine.Object.FindObjectOfType<CharacterDrawerNative>();
        if (drawer == null) Debug.Log("DrawerJbhProbe: no CharacterDrawerNative; use drawer: bind first");
        return drawer;
    }

    private static string DumpRendererAndMaterials(CharacterDrawerNative drawer)
    {
        var sb = new StringBuilder();
        for (var i = 0; i < drawer.renmats.Count; i++)
        {
            var rm = drawer.renmats[i];
            sb.Append("  renmat[").Append(i).Append("] head=").Append(rm.is_head)
              .Append(" renderer=").Append(rm.renderer_ != null ? rm.renderer_.name : "<null>")
              .Append(" subMeshes=").Append(rm.sub_meshes != null ? rm.sub_meshes.Length : 0)
              .Append(" skinQuality=").Append(rm.renderer_ != null ? rm.renderer_.quality.ToString() : "-")
              .AppendLine();
            if (rm.sub_meshes == null) continue;
            for (var j = 0; j < rm.sub_meshes.Length; j++)
            {
                var sm = rm.sub_meshes[j];
                sb.Append("      sub[").Append(j).Append("] ")
                  .Append(sm.material != null ? sm.material.name : "<null>")
                  .Append(" visible=").Append(sm.is_visible).AppendLine();
            }
        }
        return sb.ToString();
    }

    /// <summary>
    /// Prints every property the B5 subset can write, per registered material, together
    /// with whether the material actually has it (that is what decides whether a native
    /// apply call is a no-op — e.g. `_IsReddish` only exists on the face material).
    /// </summary>
    [MenuItem("MLTD/Drawer+JBH/drawer: dump material params")]
    public static void DrawerDumpMaterials()
    {
        var drawer = FindDrawer();
        if (drawer == null) return;

        string[] floats = { "_Outline", "_OutlineZadj", "_TanFov", "_Stencil", "_RimLightOn", "_IsReddish", "_ReddishIntensity", "_ZShift1000Min", "_ZShift1000Max" };
        string[] colors = { "_OutlineColor", "_RimLight", "_RimColor", "_ReddishColor", "_Color", "_IllumiColor", "_IrisColor" };

        var sb = new StringBuilder();
        if (drawer.GetMaterials() == null)
        {
            Dump("drawer-materials", "no CharacterMaterialsNative (bind first)");
            return;
        }

        var seen = new HashSet<Material>();
        foreach (var rm in drawer.renmats)
        {
            if (rm.sub_meshes == null) continue;
            foreach (var sm in rm.sub_meshes)
            {
                var mat = sm.material;
                if (mat == null || !seen.Add(mat)) continue;
                sb.Append("MAT ").Append(mat.name)
                  .Append("  shader=").Append(mat.shader != null ? mat.shader.name : "<null>").AppendLine();
                foreach (var p in floats)
                    if (mat.HasProperty(p)) sb.Append("    f ").Append(p.PadRight(20)).Append(mat.GetFloat(p).ToString("G6")).AppendLine();
                foreach (var p in colors)
                    if (mat.HasProperty(p)) sb.Append("    c ").Append(p.PadRight(20)).Append(mat.GetColor(p)).AppendLine();
                sb.Append("    kw _ISREDDISH_ON=").Append(mat.IsKeywordEnabled(CharacterMaterialsNative.ReddishKeyword)).AppendLine();
            }
        }
        if (sb.Length == 0) sb.Append("(no materials registered)");
        Dump("drawer-materials", sb.ToString());
    }

    /// <summary>
    /// Exercises the whole ported subset once, in native call order, and dumps the
    /// resulting state so the material writes can be compared with the game.
    /// </summary>
    [MenuItem("MLTD/Drawer+JBH/drawer: exercise API")]
    public static void DrawerExercise()
    {
        var drawer = FindDrawer();
        if (drawer == null) return;

        drawer.SetLayerId(3);
        drawer.SetOutlineWidth(0.0005f);
        drawer.SetOutlineColor(new Color(0.25f, 0.1f, 0.1f, 1f));
        drawer.SetIdolColor(true, new Color(0.9f, 0.3f, 0.2f, 1f));
        drawer.SetIdolColor(new Color(0.8f, 0.2f, 0.1f, 1f));
        drawer.SetMonoColor(new Color(0.5f, 0.5f, 0.5f, 1f));
        drawer.SetMonoColorRatio(0.25f);
        drawer.SetRimLight(true, new Color(1f, 0.9f, 0.7f, 1f));
        drawer.SetRimLightColor(new Color(1f, 0.8f, 0.6f, 1f));
        drawer.SetRimLightEnable(true);
        drawer.SetRimLightDirection(new Vector3(0.3f, 0.4f, 0.8f));
        drawer.SetLightDirection(new Vector3(0.1f, 0.9f, 0.4f));
        drawer.SetCheekRedden(0.6f);
        drawer.SetCheekReddenEnable(true);
        drawer.SetCheekReddenIntensity(0.75f);
        drawer.SetEyeHighlightColor(new Color(0.9f, 0.9f, 1f, 1f));
        drawer.SetSpotlightColor(new Color(1f, 1f, 1f, 1f), new Color(1f, 0.5f, 0.5f, 1f), 0.5f, 0);
        drawer.SetZShiftFace(new CharacterDrawerNative.ZShift(0.2f, 2f));
        drawer.SetZShiftOther(new CharacterDrawerNative.ZShift(0.1f, 1.5f));
        drawer.SetShadowCastEnable(true);
        drawer.SetLODLevel(0);
        drawer.SetSkinQuality(SkinQuality.Bone4);

        var sb = new StringBuilder(drawer.Describe());
        sb.Append("  GetOutlineWidth=").Append(drawer.GetOutlineWidth().ToString("G6")).AppendLine();
        sb.Append("  GetZShiftCloth=").Append(drawer.GetZShiftCloth().min.ToString("F3"))
          .Append(',').Append(drawer.GetZShiftCloth().max.ToString("F3")).AppendLine();
        sb.Append("  GetIdolColor enabled=").Append(drawer.GetIdolColor().is_enable)
          .Append(' ').Append(drawer.GetIdolColor().color).AppendLine();
        sb.Append("  GetSpotlightColor=").Append(drawer.GetSpotlightColor())
          .Append(" pin=").Append(drawer.GetPinSpotlightColor())
          .Append(" alpha=").Append(drawer.GetPinSpotlightAlpha()).AppendLine();
        sb.Append("  GetCharacterDrawerEye=").Append(drawer.GetCharacterDrawerEye().Describe()).AppendLine();
        sb.Append("  IsShadowCastEnabled=").Append(drawer.IsShadowCastEnabled()).AppendLine();
        Dump("drawer-exercise", sb.ToString());
    }

    // ------------------------------------------------------------------
    // JointBodyHead
    // ------------------------------------------------------------------

    [MenuItem("MLTD/Drawer+JBH/jbh: bind")]
    public static void JbhBind()
    {
        var jbh = BindJbh();
        if (jbh == null) return;
        Dump("jbh-bind", jbh.Describe() + "\n" + DumpSwayWiring(jbh));
    }

    [MenuItem("MLTD/Drawer+JBH/jbh: describe")]
    public static void JbhDescribe()
    {
        var jbh = FindJbh();
        if (jbh == null) return;
        Dump("jbh-describe", jbh.Describe() + "\n" + DumpSwayWiring(jbh));
    }

    public static JointBodyHeadNative BindJbh()
    {
        var bootstrap = Character();
        if (bootstrap == null)
        {
            Debug.LogError("DrawerJbhProbe: no CharacterBootstrap in the scene");
            return null;
        }
        var jbh = bootstrap.GetComponent<JointBodyHeadNative>();
        if (jbh == null) jbh = bootstrap.gameObject.AddComponent<JointBodyHeadNative>();

        // CharacterBootstrap instantiates `MODEL_00_holder` (body) and `ch_head` (head).
        var model = bootstrap.transform.Find("MODEL_00_holder");
        var body = model != null ? model.gameObject : bootstrap.gameObject;
        var headT = bootstrap.transform.Find("ch_head");
        var head = headT != null ? headT.gameObject : body;

        jbh.ResetToCtorDefaults(0);
        var ok = jbh.Initialize(body, head, body.name);

        var rig = bootstrap.GetComponent<SwayRigNative>();
        if (rig != null) jbh.BindSwayRig(rig);

        var face = bootstrap.GetComponent<FaceCtrlNative>();
        if (face != null) jbh.face = face;
        var calc = bootstrap.GetComponent<CalcBoneNative>();
        if (calc != null) jbh.calcBone = calc;

        Debug.Log("DrawerJbhProbe: JointBodyHeadNative assembled=" + ok
                  + " body=" + body.name + " head=" + head.name
                  + " managers=" + jbh.swm.Count + " bones=" + jbh.swb.Count);
        return jbh;
    }

    private static JointBodyHeadNative FindJbh()
    {
        var jbh = UnityEngine.Object.FindObjectOfType<JointBodyHeadNative>();
        if (jbh == null) Debug.Log("DrawerJbhProbe: no JointBodyHeadNative; use jbh: bind first");
        return jbh;
    }

    private static string DumpSwayWiring(JointBodyHeadNative jbh)
    {
        var sb = new StringBuilder();
        sb.Append("  swayOn=").Append(jbh.swayOn)
          .Append(" swayTransBack=").Append(jbh.swayTransBack)
          .Append(" swayFollowRate=[").Append(string.Join(",", jbh.swayFollowRate)).Append(']')
          .AppendLine();
        sb.AppendLine("  (swayFollowSW / swayDamper / vecs1 are IdolPositionMgr+EventScenarioData,");
        sb.AppendLine("   not JointBodyHead — see JointBodyHeadNative.cs header)");
        for (var i = 0; i < jbh.swm.Count; i++)
        {
            var m = jbh.swm[i];
            if (m == null) continue;
            sb.Append("  manager[").Append(i).Append("] ").Append(m.name)
              .Append(" on=").Append(m.on)
              .Append(" bones=").Append(m.swayBones != null ? m.swayBones.Length : 0)
              .Append(" followRate=[").Append(string.Join(",", m.swayFollowRate)).Append(']')
              .Append(" damper=[").Append(string.Join(",", m.swayDamper)).Append(']')
              .Append(" followSW=[").Append(string.Join(",", m.swayFollowSW)).Append(']')
              .Append(" transBack=").Append(m.swayTransBack)
              .Append(" swayOn=").Append(m.swayOn)
              .AppendLine();
        }
        jbh.MeasureSway(out var updateTime, out var sideLineTime);
        sb.Append("  MeasureSway sum(updateSwayTime)=").Append(updateTime.ToString("G6"))
          .Append(" sum(sideLineHitTime)=").Append(sideLineTime.ToString("G6")).AppendLine();
        return sb.ToString();
    }

    [MenuItem("MLTD/Drawer+JBH/jbh: switches")]
    public static void JbhSwitches()
    {
        var jbh = FindJbh();
        if (jbh == null) return;

        var sb = new StringBuilder("before:\n");
        sb.Append(DumpSwayWiring(jbh));

        jbh.SwaySwitch(false);
        sb.Append("\nafter SwaySwitch(false):\n").Append(DumpSwayWiring(jbh));
        jbh.SwayManagerAllON();
        sb.Append("\nafter SwayManagerAllON():\n").Append(DumpSwayWiring(jbh));
        jbh.skirt_GP_SwayManagerCtrl(false);
        sb.Append("\nafter skirt_GP_SwayManagerCtrl(false):\n").Append(DumpSwayWiring(jbh));
        jbh.skirt_GP_SwayManagerCtrl(true);

        jbh.SetSwayOn(false);
        sb.Append("\nafter SetSwayOn(false) (JointBodyHead.swayOn 0x104):\n").Append(DumpSwayWiring(jbh));
        jbh.SetSwayOn(true);

        jbh.SetSwayTransBack(true);
        sb.Append("\nafter SetSwayTransBack(true) (0x105):\n").Append(DumpSwayWiring(jbh));
        jbh.SetSwayTransBack(false);

        if (jbh.wingL != null || jbh.wingR != null)
        {
            jbh.SetWingLimit(0);
            sb.Append("\nSetWingLimit(0): wingL=").Append(jbh.wingL != null)
              .Append(" wingR=").Append(jbh.wingR != null).AppendLine();
        }
        else sb.Append("\nSetWingLimit: no wing bones bound (ss003/pr001 have none)\n");

        jbh.SetVisible(false);
        sb.Append("SetVisible(false): body active=").Append(jbh.body != null && jbh.body.activeSelf).AppendLine();
        jbh.SetVisible(true);

        Dump("jbh-switches", sb.ToString());
    }

    // ------------------------------------------------------------------
    // Dump sink
    // ------------------------------------------------------------------

    private static void Dump(string title, string text)
    {
        Debug.Log("DrawerJbhProbe[" + title + "]\n" + text);
        try
        {
            var path = DumpPath;
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.AppendAllText(path,
                "\n===== " + title + " @ " + DateTime.Now.ToString("u") + " =====\n" + text + "\n");
            Debug.Log("DrawerJbhProbe: appended to " + path);
        }
        catch (Exception error)
        {
            Debug.LogWarning("DrawerJbhProbe: could not write dump: " + error.Message);
        }
    }
}
