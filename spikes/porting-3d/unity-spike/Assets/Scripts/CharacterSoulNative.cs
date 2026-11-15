// Native-faithful port of the game's per-character "soul" data (ADR-0033 B5):
//   Imas.CharacterSoul                 dump.cs TypeDefIndex 9588
//   Imas.CharacterSoul.Value<T>        dump.cs TypeDefIndex 9587
//   Imas.CharaInternal.SoulDatas       dump.cs TypeDefIndex 15091
//   Imas.CharaInternal.SoulDataCharacter  dump.cs TypeDefIndex 15090
//   Imas.CharaInternal.SoulDataColor3i    dump.cs TypeDefIndex 15092
//   CharacterMotif                     dump.cs TypeDefIndex 9526
//
// Data source (version-locked snapshot, ADR-0033 §5):
//   ~/mltd-work/assets/1078590/files/03761aa8….unity3d  ==  "chara_soul.unity3d"
//   container path: assets/imas/resources/json/chara_soul.json
//   TextAsset "chara_soul": {"date","means":[21 names],"characters":[{"values":[21 strings]},…]}
//   61 rows, means == SoulDataCharacter.Param names (verified: Param enum dumped below
//   matches the asset's `means` element by element).
//
// The native parse rules are taken from these decompiled functions (all in
// /tmp/ida-decomp/b5/, addresses are dump.cs RVAs == IDA linear addresses):
//   CharacterSoul..ctor(string)                          0x3799598
//   CharacterSoul..ctor(string, SoulDataCharacter, string[]) 0x3799664
//   CharacterSoul.create_common                          0x3799630
//   SoulDataCharacter.CreateMeans                        0x1C35340  (21 names from Enum.GetName)
//   SoulDataCharacter.get_string_value                   0x1C357BC  (IndexOf(means,name) then value)
//   SoulDataCharacter.get_int_value                      0x1C366B8  (int.TryParse, else default)
//   SoulDataCharacter.get_float_value                    0x1C35BEC  (float.TryParse, else default)
//   SoulDataCharacter.GetCheekReddenColor                0x1C36590  (params 3,4,5)
//   SoulDataCharacter.GetSkinColor                       0x1C36E98  (params 7,8,9)
//   SoulDataCharacter.GetInherentColor/2                 0x1C3728C / 0x1C37680 (params 10..12 / 13..15)
//   SoulDataCharacter.GetMotif                           0x1C388D4  (param 20)
//   SoulDataCharacter.ShortNameToCharacterMotif          0x1C352B0  (IndexOf s_CharacterMotif_ShortNames)
//   SoulDataColor3i.IsValid                              0x1C368BC  (r,g,b all >= 0)
//   SoulDataColor3i.TryParse                            0x1C93980  (Split(',') + 3x TryParse; stale marker 0x1C352B0)
//   SoulDataColor3i.s_invalid_value                      0x1C39768  (-1,-1,-1)
//
// ADR-0033 §3: only performance-layer substitutions below. No formula, constant or
// default value is invented; every value that could not be established is marked
// UNKNOWN with the native address and kept at the neutral value the binary uses.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using UnityEngine;

namespace Imas
{
    /// <summary>CharacterMotif (dump.cs 9526). Values are the shipped enum values.</summary>
    public enum CharacterMotif
    {
        None = -1,
        Princess = 0,
        Fairy = 1,
        Angel = 2,
        Etc = 3,
        Num = 4,
    }

    /// <summary>Imas.CharaInternal.SoulDataColor3i (dump.cs 15092): 0..255 ints.</summary>
    [Serializable]
    public struct SoulDataColor3i
    {
        public int r;
        public int g;
        public int b;

        /// <summary>`s_invalid_value` @0x1C39768 = (-1,-1,-1).</summary>
        public static SoulDataColor3i Invalid => new SoulDataColor3i { r = -1, g = -1, b = -1 };

        public SoulDataColor3i(int r, int g, int b)
        {
            this.r = r;
            this.g = g;
            this.b = b;
        }

        /// <summary>SoulDataColor3i.IsValid 0x1C368BC: all three channels >= 0.</summary>
        public bool IsValid => r >= 0 && g >= 0 && b >= 0;

        public override string ToString() => r + "," + g + "," + b;

        /// <summary>
        /// SoulDataColor3i.TryParse (current binary 0x1C93980, port comment previously
        /// cited the stale 0x1C38D08/0x1C352B0): `str.Split(',')` (0x2C), require
        /// `Length >= 3`, then three `int.TryParse` on parts 0..2; on success writes
        /// (r,g,b) and returns true. Verified against the Hex-Rays body
        /// `sub_1C93980` (2026-11-16): Split(0x2C) -> count check at +0x18 ->
        /// three TryParse out-params -> `*(a2)=part0, a2[1]=part1, a2[2]=part2`.
        /// </summary>
        public static bool TryParse(string str, out SoulDataColor3i color)
        {
            color = Invalid;
            if (string.IsNullOrEmpty(str)) return false;
            var parts = str.Split(',');
            if (parts.Length < 3) return false;
            if (!int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var r)) return false;
            if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var g)) return false;
            if (!int.TryParse(parts[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out var b)) return false;
            color = new SoulDataColor3i(r, g, b);
            return true;
        }
    }

    /// <summary>
    /// Imas.CharaInternal.SoulDataCharacter (dump.cs 15090): one row of
    /// `characters[]`. `values` is positional; `means` (SoulDatas.means) names the
    /// columns. Every getter is `IndexOf(means, Param.ToString())` + TryParse, with
    /// the caller-supplied default on any miss — see 0x1C357BC/0x1C366B8/0x1C35BEC.
    /// </summary>
    [Serializable]
    public struct SoulDataCharacter
    {
        // ---- SoulDataCharacter.Param (dump.cs 15081), index == column order ----
        public enum Param
        {
            None = -1,
            CharacterId = 0,
            BodyScale = 1,
            BodySize = 2,
            CheekReddenColorR = 3,
            CheekReddenColorG = 4,
            CheekReddenColorB = 5,
            CheekReddenIntensity = 6,
            SkinColorR = 7,
            SkinColorG = 8,
            SkinColorB = 9,
            InherentColorR = 10,
            InherentColorG = 11,
            InherentColorB = 12,
            InherentColor2R = 13,
            InherentColor2G = 14,
            InherentColor2B = 15,
            SwayBreastStiffness = 16,
            SwayBreastDrag = 17,
            SwayBreastFollow = 18,
            SwayBreastGravity = 19,
            Motif = 20,
            Num = 21,
        }

        public string[] values;

        /// <summary>
        /// `s_CharacterMotif_ShortNames` (static, 4 entries). The four string literals
        /// are IL2CPP metadata-usage pointers (0x9820680 / 0x9813C48 / 0x98095D0 /
        /// 0x980FB10) and are NOT statically resolvable from the shipped image
        /// (Mach-O chained fixups), so their contents are UNKNOWN.
        ///
        /// The table below is the only value set that reproduces the shipped data:
        /// `chara_soul.json` contains exactly the four short names {a, e, f, p} and
        /// CharacterMotif declares Princess=0, Fairy=1, Angel=2, Etc=3. The mapping
        /// p→Princess / f→Fairy / a→Angel / e→Etc is therefore an INFERENCE by
        /// elimination + declaration order, not a decoded literal.
        /// UNKNOWN(native 0x1C352B0 + 0x1C390A4): literal contents and their order.
        /// Verify with DrawerJbhProbe "Soul: motif table" against a runtime dump.
        /// </summary>
        public static readonly string[] DefaultMotifShortNames = { "p", "f", "a", "e" };

        private static string[] motifShortNames = DefaultMotifShortNames;

        /// <summary>Injection point for a verified literal table (probe / later decode).</summary>
        public static void SetMotifShortNames(string[] names)
        {
            if (names != null && names.Length == (int)CharacterMotif.Num) motifShortNames = names;
        }

        /// <summary>SoulDataCharacter.CreateMeans 0x1C35340: Enum.GetName for 0..20.</summary>
        public static string[] CreateMeans()
        {
            var names = new string[(int)Param.Num];
            for (var i = 0; i < names.Length; i++) names[i] = ((Param)i).ToString();
            return names;
        }

        /// <summary>SoulDataCharacter.ShortNameToCharacterMotif 0x1C352B0.</summary>
        public static CharacterMotif ShortNameToCharacterMotif(string str)
        {
            if (string.IsNullOrEmpty(str)) return CharacterMotif.None;
            var idx = Array.IndexOf(motifShortNames, str);
            return idx < 0 ? CharacterMotif.None : (CharacterMotif)idx;
        }

        /// <summary>SoulDatas.IsValid / SoulDataCharacter.IsValid 0x1C2B010: values != null.</summary>
        public bool IsValid => values != null;

        // ---- column lookup: get_string_value 0x1C357BC ----
        private string GetStringValue(string[] means, Param param, string defaultValue)
        {
            if (means == null || values == null) return defaultValue;
            var idx = Array.IndexOf(means, param.ToString());
            if (idx < 0 || idx >= values.Length) return defaultValue;
            return values[idx];
        }

        private int GetIntValue(string[] means, Param param, int defaultValue)
        {
            var raw = GetStringValue(means, param, null);
            if (raw == null) return defaultValue;
            return int.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : defaultValue;
        }

        private float GetFloatValue(string[] means, Param param, float defaultValue)
        {
            var raw = GetStringValue(means, param, null);
            if (raw == null) return defaultValue;
            // Native Single.TryParse(string, out float) = NumberStyles.Float with the
            // current culture; the shipped asset is invariant-decimal, so pinning the
            // culture is a performance/robustness substitution, not a value change.
            return float.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : defaultValue;
        }

        // ---- typed getters ----

        public string GetCharacterId(string[] means) => GetStringValue(means, Param.CharacterId, null);

        /// <summary>GetBodyScale 0x1C35B7C: default 1.0.</summary>
        public float GetBodyScale(string[] means) => GetFloatValue(means, Param.BodyScale, 1.0f);

        /// <summary>
        /// HasBodyScale 0x1C35D94: `!float.IsNaN(GetBodyScale())`. Because the default
        /// is 1.0 (never NaN) this is always true in the shipped binary — kept verbatim.
        /// </summary>
        public bool HasBodyScale(string[] means) => !float.IsNaN(GetBodyScale(means));

        /// <summary>GetBodySize 0x1C36054: default NaN (NaN == "column absent").</summary>
        public float GetBodySize(string[] means) => GetFloatValue(means, Param.BodySize, float.NaN);

        public bool HasBodySize(string[] means) => !float.IsNaN(GetBodySize(means));

        private SoulDataColor3i GetColor3i(string[] means, Param rParam)
        {
            // GetCheekReddenColor/GetSkinColor/GetInherentColor(2) build the triple from
            // three consecutive int columns, each defaulting to the matching component
            // of s_invalid_value (-1) — so a missing/parsing-failed column makes the
            // whole triple invalid and the CharacterSoul Value stays unset.
            var inv = SoulDataColor3i.Invalid;
            return new SoulDataColor3i(
                GetIntValue(means, rParam, inv.r),
                GetIntValue(means, rParam + 1, inv.g),
                GetIntValue(means, rParam + 2, inv.b));
        }

        public SoulDataColor3i GetCheekReddenColor(string[] means) => GetColor3i(means, Param.CheekReddenColorR);
        public bool HasCheekReddenColor(string[] means) => GetCheekReddenColor(means).IsValid;

        public SoulDataColor3i GetSkinColor(string[] means) => GetColor3i(means, Param.SkinColorR);
        public bool HasSkinColor(string[] means) => GetSkinColor(means).IsValid;

        public SoulDataColor3i GetInherentColor(string[] means) => GetColor3i(means, Param.InherentColorR);
        public bool HasInherentColor(string[] means) => GetInherentColor(means).IsValid;

        public SoulDataColor3i GetInherentColor2(string[] means) => GetColor3i(means, Param.InherentColor2R);
        public bool HasInherentColor2(string[] means) => GetInherentColor2(means).IsValid;

        public float GetCheekReddenIntensity(string[] means) => GetFloatValue(means, Param.CheekReddenIntensity, float.NaN);
        public bool HasCheekReddenIntensity(string[] means) => !float.IsNaN(GetCheekReddenIntensity(means));

        public float GetSwayBreastStiffness(string[] means) => GetFloatValue(means, Param.SwayBreastStiffness, float.NaN);
        public bool HasSwayBreastStiffness(string[] means) => !float.IsNaN(GetSwayBreastStiffness(means));

        public float GetSwayBreastDrag(string[] means) => GetFloatValue(means, Param.SwayBreastDrag, float.NaN);
        public bool HasSwayBreastDrag(string[] means) => !float.IsNaN(GetSwayBreastDrag(means));

        public float GetSwayBreastFollow(string[] means) => GetFloatValue(means, Param.SwayBreastFollow, float.NaN);
        public bool HasSwayBreastFollow(string[] means) => !float.IsNaN(GetSwayBreastFollow(means));

        public float GetSwayBreastGravity(string[] means) => GetFloatValue(means, Param.SwayBreastGravity, float.NaN);
        public bool HasSwayBreastGravity(string[] means) => !float.IsNaN(GetSwayBreastGravity(means));

        /// <summary>GetMotif 0x1C388D4: get_string_value(20, "").</summary>
        public string GetMotif(string[] means) => GetStringValue(means, Param.Motif, string.Empty);
        public bool HasMotif(string[] means) => !string.IsNullOrEmpty(GetMotif(means));
    }

    /// <summary>Imas.CharaInternal.SoulDatas (dump.cs 15091) — the JSON root.</summary>
    [Serializable]
    public struct SoulDatas
    {
        public string date;
        public string[] means;
        public SoulDataCharacter[] characters;

        public bool IsValid => characters != null && means != null;
    }

    /// <summary>
    /// Imas.CharacterSoul (dump.cs 9588). One row of `chara_soul.json` resolved into
    /// the 13 <see cref="Value{T}"/> slots. `isValid == false` means "the column was
    /// absent or unparsable" and is a first-class state: consumers (CharacterMaterials
    /// / FaceCtrl cheek) branch on it, so it must never be filled with a guessed value.
    /// </summary>
    public class CharacterSoul
    {
        /// <summary>
        /// Imas.CharacterSoul.Value&lt;T&gt; (dump.cs 9587): `bool isValid` + `T _value`,
        /// `value` property sets isValid = true (Value&lt;T&gt;..ctor / set_value).
        /// </summary>
        [Serializable]
        public struct Value<T>
        {
            public bool isValid;
            private T _value;

            public Value(T value)
            {
                isValid = true;
                _value = value;
            }

            public T value
            {
                get { return _value; }
                set { _value = value; isValid = true; }
            }

            public override string ToString()
            {
                if (!isValid) return "<invalid>";
                object boxed = _value;
                return boxed != null ? boxed.ToString() : "null";
            }
        }

        // Field order/offsets exactly as dump.cs 9588 (IL2CPP object offsets in
        // parentheses). Value<Color> is 20 bytes (flag + pad + Color), Value<float> 8.
        public Value<string> characterId;                    // 0x10
        public Value<float> bodyScale;                       // 0x20
        public Value<float> bodySize;                        // 0x28
        public Value<Color> cheekReddenColor;                // 0x30
        public Value<float> cheekReddenIntensity;            // 0x44
        public Value<Color> skinColor;                       // 0x4C
        public Value<Color> inherentColor;                   // 0x60
        public Value<Color> inherentColor2;                  // 0x74
        public Value<float> swayBreastStiffness;             // 0x88
        public Value<float> swayBreastDrag;                  // 0x90
        public Value<float> swayBreastFollow;                // 0x98
        public Value<float> swayBreastGravity;               // 0xA0
        public Value<CharacterMotif> motif;                  // 0xA8

        /// <summary>CharacterSoul..ctor(string) 0x3799598 — id only, everything else invalid.</summary>
        public CharacterSoul(string characterId)
        {
            CreateCommon();
            this.characterId = new Value<string>(characterId);
        }

        /// <summary>
        /// CharacterSoul.create_common 0x3799630. The binary clears the isValid flag of
        /// 12 of the 13 slots and does NOT touch 0x44 (cheekReddenIntensity); a freshly
        /// GC-allocated object is zero-filled anyway, so both produce `false`. Kept
        /// verbatim (12 clears) so the quirk stays visible instead of being "tidied up".
        /// </summary>
        public void CreateCommon()
        {
            characterId.isValid = false;            // 0x10
            bodyScale.isValid = false;              // 0x20
            bodySize.isValid = false;               // 0x28
            cheekReddenColor.isValid = false;       // 0x30
            // 0x44 cheekReddenIntensity: not cleared by native create_common.
            skinColor.isValid = false;              // 0x4C
            inherentColor.isValid = false;          // 0x60
            inherentColor2.isValid = false;         // 0x74
            swayBreastStiffness.isValid = false;    // 0x88
            swayBreastDrag.isValid = false;         // 0x90
            swayBreastFollow.isValid = false;       // 0x98
            swayBreastGravity.isValid = false;      // 0xA0
            motif.isValid = false;                  // 0xA8
        }

        /// <summary>
        /// CharacterSoul..ctor(string, SoulDataCharacter, string[]) 0x3799664.
        /// Order and per-field conditions are the ones in the decompiled body:
        ///   characterId  = characterId                       (always valid)
        ///   bodyScale    = 1.0, then overwritten if Has*     (0x1C359D4/0x1C35B7C)
        ///   bodySize     = GetBodySize if HasBodySize        (NaN sentinel otherwise)
        ///   colors       = Color(r/255, g/255, b/255, 1)     (0x5397528, a=1.0)
        ///   cheek/breast = parsed floats
        ///   motif        = ShortNameToCharacterMotif if != None
        /// </summary>
        public CharacterSoul(string characterId, SoulDataCharacter data, string[] means)
        {
            CreateCommon();
            this.characterId = new Value<string>(characterId);

            // bodyScale is pre-seeded with 1.0 and then unconditionally re-read when
            // HasBodyScale (which is always true — see SoulDataCharacter.HasBodyScale).
            bodyScale = new Value<float>(1.0f);
            if (data.HasBodyScale(means)) bodyScale.value = data.GetBodyScale(means);

            if (data.HasBodySize(means)) bodySize = new Value<float>(data.GetBodySize(means));

            if (data.HasCheekReddenColor(means))
                cheekReddenColor = new Value<Color>(ToColor(data.GetCheekReddenColor(means)));
            if (data.HasCheekReddenIntensity(means))
                cheekReddenIntensity = new Value<float>(data.GetCheekReddenIntensity(means));

            if (data.HasSkinColor(means))
                skinColor = new Value<Color>(ToColor(data.GetSkinColor(means)));
            if (data.HasInherentColor(means))
                inherentColor = new Value<Color>(ToColor(data.GetInherentColor(means)));
            if (data.HasInherentColor2(means))
                inherentColor2 = new Value<Color>(ToColor(data.GetInherentColor2(means)));

            if (data.HasSwayBreastStiffness(means))
                swayBreastStiffness = new Value<float>(data.GetSwayBreastStiffness(means));
            if (data.HasSwayBreastDrag(means))
                swayBreastDrag = new Value<float>(data.GetSwayBreastDrag(means));
            if (data.HasSwayBreastFollow(means))
                swayBreastFollow = new Value<float>(data.GetSwayBreastFollow(means));
            if (data.HasSwayBreastGravity(means))
                swayBreastGravity = new Value<float>(data.GetSwayBreastGravity(means));

            if (data.HasMotif(means))
            {
                var m = SoulDataCharacter.ShortNameToCharacterMotif(data.GetMotif(means));
                if (m != CharacterMotif.None) motif = new Value<CharacterMotif>(m);
            }
        }

        /// <summary>
        /// 0x3799664 stores `Color(r/255f, g/255f, b/255f, 1.0f)` — the 4th component is
        /// the literal 1.0 in the decompiled body, not `a/255`.
        /// </summary>
        private static Color ToColor(SoulDataColor3i c)
        {
            return new Color(c.r / 255f, c.g / 255f, c.b / 255f, 1f);
        }

        /// <summary>Convenience: the id with the Value&lt;T&gt; wrapper stripped.</summary>
        public string CharacterId => characterId.value;

        public string Describe()
        {
            var sb = new StringBuilder();
            sb.Append("CharacterSoul ").Append(characterId.value ?? "<null>").AppendLine();
            Append(sb, "bodyScale", bodyScale.isValid, bodyScale.value);
            Append(sb, "bodySize", bodySize.isValid, bodySize.value);
            AppendColor(sb, "cheekReddenColor", cheekReddenColor);
            Append(sb, "cheekReddenIntensity", cheekReddenIntensity.isValid, cheekReddenIntensity.value);
            AppendColor(sb, "skinColor", skinColor);
            AppendColor(sb, "inherentColor", inherentColor);
            AppendColor(sb, "inherentColor2", inherentColor2);
            Append(sb, "swayBreastStiffness", swayBreastStiffness.isValid, swayBreastStiffness.value);
            Append(sb, "swayBreastDrag", swayBreastDrag.isValid, swayBreastDrag.value);
            Append(sb, "swayBreastFollow", swayBreastFollow.isValid, swayBreastFollow.value);
            Append(sb, "swayBreastGravity", swayBreastGravity.isValid, swayBreastGravity.value);
            sb.Append("  motif             = ")
              .Append(motif.isValid ? motif.value.ToString() : "<invalid>").AppendLine();
            return sb.ToString();
        }

        private static void Append(StringBuilder sb, string name, bool valid, float v)
        {
            sb.Append("  ").Append(name.PadRight(18)).Append("= ")
              .Append(valid ? v.ToString("G7") : "<invalid>").AppendLine();
        }

        private static void AppendColor(StringBuilder sb, string name, Value<Color> v)
        {
            sb.Append("  ").Append(name.PadRight(18)).Append("= ")
              .Append(v.isValid
                  ? $"({v.value.r:F3},{v.value.g:F3},{v.value.b:F3},{v.value.a:F3}) 255=(" +
                    $"{Mathf.RoundToInt(v.value.r * 255f)},{Mathf.RoundToInt(v.value.g * 255f)}," +
                    $"{Mathf.RoundToInt(v.value.b * 255f)})"
                  : "<invalid>")
              .AppendLine();
        }
    }

    /// <summary>
    /// Loader for `chara_soul.unity3d` and the `TryGet(cid)` table.
    /// Native counterpart: `SoulDataManager`/`Imas.CharaInternal.SoulDatas` consumers
    /// (e.g. `CharacterManager.GetSoul(string)` dump.cs 339793). The bundle ships one
    /// TextAsset named "chara_soul" under assets/imas/resources/json/chara_soul.json.
    /// </summary>
    public sealed class CharacterSoulTable
    {
        public const string BundleName = "chara_soul.unity3d";
        public const string TextAssetName = "chara_soul";

        public string date;
        public string[] means;

        private readonly Dictionary<string, CharacterSoul> byId =
            new Dictionary<string, CharacterSoul>(StringComparer.Ordinal);
        private readonly List<CharacterSoul> all = new List<CharacterSoul>();

        public int Count => all.Count;
        public IReadOnlyList<CharacterSoul> All => all;
        public string[] Means => means;

        public bool TryGet(string characterId, out CharacterSoul soul)
        {
            soul = null;
            return !string.IsNullOrEmpty(characterId) && byId.TryGetValue(characterId, out soul);
        }

        public CharacterSoul Get(string characterId)
        {
            TryGet(characterId, out var soul);
            return soul;
        }

        /// <summary>
        /// Parses the TextAsset body. `SoulDatas` is the native JSON schema; each row is
        /// turned into a CharacterSoul with the native ctor at 0x3799664 (no defaults
        /// are substituted for absent columns).
        /// </summary>
        public static CharacterSoulTable FromJson(string json, out string error)
        {
            error = null;
            if (string.IsNullOrEmpty(json))
            {
                error = "chara_soul json is empty";
                return null;
            }

            var table = new CharacterSoulTable();
            SoulDatas datas;
            try
            {
                datas = JsonUtility.FromJson<SoulDatas>(json);
            }
            catch (Exception e)
            {
                error = "chara_soul json parse failed: " + e.Message;
                return null;
            }

            if (datas.means == null || datas.means.Length == 0)
            {
                error = "chara_soul json has no `means`";
                return null;
            }
            if (datas.characters == null || datas.characters.Length == 0)
            {
                error = "chara_soul json has no `characters`";
                return null;
            }

            table.date = datas.date;
            table.means = datas.means;

            for (var i = 0; i < datas.characters.Length; i++)
            {
                var row = datas.characters[i];
                if (!row.IsValid) continue;
                var cid = row.GetCharacterId(table.means);
                if (string.IsNullOrEmpty(cid)) continue;
                var soul = new CharacterSoul(cid, row, table.means);
                table.all.Add(soul);
                // Native table is keyed by character id; duplicate ids keep the first
                // row (the shipped asset has none — 61 distinct ids).
                if (!table.byId.ContainsKey(cid)) table.byId[cid] = soul;
            }

            if (table.all.Count == 0)
            {
                error = "chara_soul json produced 0 souls";
                return null;
            }
            return table;
        }

        /// <summary>
        /// Loads the TextAsset out of an already-open `chara_soul.unity3d` bundle.
        /// The bundle must stay alive while the table is in use (the JSON is copied).
        /// </summary>
        public static CharacterSoulTable FromBundle(AssetBundle bundle, out string error)
        {
            error = null;
            if (bundle == null)
            {
                error = "bundle is null";
                return null;
            }
            TextAsset asset = null;
            foreach (var a in bundle.LoadAllAssets<TextAsset>())
            {
                if (a != null && a.name == TextAssetName) { asset = a; break; }
            }
            if (asset == null)
            {
                error = "TextAsset `" + TextAssetName + "` not found in " + bundle.name;
                return null;
            }
            return FromJson(asset.text, out error);
        }

        /// <summary>
        /// Loads `chara_soul.unity3d` from disk and parses it. Re-uses an already loaded
        /// bundle (an AssetBundle cannot be loaded twice in one process).
        /// </summary>
        public static CharacterSoulTable Load(string bundleFile, out string error)
        {
            error = null;
            if (string.IsNullOrEmpty(bundleFile) || !System.IO.File.Exists(bundleFile))
            {
                error = "not found: " + bundleFile;
                return null;
            }
            var name = System.IO.Path.GetFileName(bundleFile);
            AssetBundle bundle = null;
            foreach (var loaded in AssetBundle.GetAllLoadedAssetBundles())
                if (loaded.name == name) { bundle = loaded; break; }
            if (bundle == null) bundle = AssetBundle.LoadFromFile(bundleFile);
            if (bundle == null)
            {
                error = "AssetBundle.LoadFromFile failed: " + bundleFile;
                return null;
            }
            return FromBundle(bundle, out error);
        }

        public string Describe()
        {
            var sb = new StringBuilder();
            sb.Append("CharacterSoulTable souls=").Append(all.Count)
              .Append(" means=").Append(means != null ? means.Length : 0)
              .Append(" date=").Append(date ?? "<none>").AppendLine();
            sb.Append("  means: ").AppendLine(string.Join(",", means ?? Array.Empty<string>()));
            return sb.ToString();
        }

        /// <summary>
        /// Column-presence audit for the shipped asset: which of the 13 CharacterSoul
        /// slots are valid for the given id. Used by the probe to document data-gaps
        /// (e.g. if a colour triple never parses, the Value is invalid natively too).
        /// </summary>
        public string DescribeGaps(string characterId)
        {
            if (!TryGet(characterId, out var soul)) return "soul not found: " + characterId;
            var sb = new StringBuilder();
            sb.Append("CharacterSoul gap audit ").Append(characterId).AppendLine();
            sb.Append("  rows=").Append(all.Count).Append(" means=")
              .Append(means.Length).AppendLine();
            sb.Append("  characterId        ").Append(soul.characterId.isValid ? "OK" : "MISSING").AppendLine();
            sb.Append("  bodyScale          ").Append(soul.bodyScale.isValid ? "OK" : "MISSING").AppendLine();
            sb.Append("  bodySize           ").Append(soul.bodySize.isValid ? "OK" : "MISSING").AppendLine();
            sb.Append("  cheekReddenColor   ").Append(soul.cheekReddenColor.isValid ? "OK" : "MISSING").AppendLine();
            sb.Append("  cheekReddenIntensity ").Append(soul.cheekReddenIntensity.isValid ? "OK" : "MISSING").AppendLine();
            sb.Append("  skinColor          ").Append(soul.skinColor.isValid ? "OK" : "MISSING").AppendLine();
            sb.Append("  inherentColor      ").Append(soul.inherentColor.isValid ? "OK" : "MISSING").AppendLine();
            sb.Append("  inherentColor2     ").Append(soul.inherentColor2.isValid ? "OK" : "MISSING").AppendLine();
            sb.Append("  swayBreastStiffness ").Append(soul.swayBreastStiffness.isValid ? "OK" : "MISSING").AppendLine();
            sb.Append("  swayBreastDrag     ").Append(soul.swayBreastDrag.isValid ? "OK" : "MISSING").AppendLine();
            sb.Append("  swayBreastFollow   ").Append(soul.swayBreastFollow.isValid ? "OK" : "MISSING").AppendLine();
            sb.Append("  swayBreastGravity  ").Append(soul.swayBreastGravity.isValid ? "OK" : "MISSING").AppendLine();
            sb.Append("  motif              ").Append(soul.motif.isValid ? "OK" : "MISSING").AppendLine();
            return sb.ToString();
        }
    }
}
