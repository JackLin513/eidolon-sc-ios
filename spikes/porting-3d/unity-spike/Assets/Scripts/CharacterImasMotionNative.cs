using System;
using System.Collections.Generic;
using System.IO;
using UnityEngine;

// Native-faithful port of the game's `Imas.*` imo (chara dance) motion chain.
//
// Source of truth: the shipped UnityFramework IL2CPP build. Every type/method below
// names its dump.cs TypeDefIndex and the address of the function it reproduces, the
// same way the B2 sway files do. Addresses are the flat VA from dump.cs (IDA linear
// address, 1:1 with the RVA).
//
// Only performance-layer substitutions are made (ADR-0033 §3):
//   * List<T>/T[] instead of the native GC arrays; a fixed native capacity of 64
//     becomes a growable array of the same shape.
//   * the native `ref int seeker_position` search hint is kept on the same curves,
//     but the search itself uses an equivalent binary search instead of the native
//     "scan forward/backwards from the previous position" loop. Both return the same
//     segment; the hint only exists for speed.
//   * Transform.Find / Transform instead of TransformAccess where the native player
//     used plain Transform API already.
//
// No resampling happens here: curve values are consumed as the raw `eidolon.imo/1`
// keys (the export of `CharacterImasMotionAsset`), and `SolveCurve` interpolates at
// whatever time it is handed, exactly like the game.
//
// Data notes that belong to the report, not the code:
//   * `attribs` is per curve and holds `property_type X`, `property_name Y`,
//     `key_type Z` strings (asset-level attribs is always empty in shipped data).
//   * Optional curves are a *separate* asset with `kind == "optional"`.
//   * Named differences from `motion.py` are marked UNKNOWN below.

namespace Imas.CharaImasMotion
{
    /// <summary>
    /// `Imas.CharaImasMotion.KeyType` (TypeDefIndex 14918). Values are the raw codes
    /// switched on by `CharacterImasMotionPlayer.SolveCurve` (0x38A9500,
    /// old 0x37E80B8).
    /// </summary>
    public enum KeyType
    {
        None = -1,
        FullFrame = 0,
        Discreate = 1,
        Const = 2,
        FCurve = 3,
        Step = 4,
        Step_3Values = 5,
        FullFrameOffset = 6,
        DeltaFrame = 7,
        Num = 8,
    }

    /// <summary>
    /// `Imas.CharaImasMotion.PropertyType` (TypeDefIndex 14917). 1..6 are the six
    /// slots of `CharacterImasMotionData.CurveSet` (px..rz); General(0) is only used
    /// by `CharaOptionalImoData`.
    /// </summary>
    public enum PropertyType
    {
        None = -1,
        General = 0,
        PositionX = 1,
        PositionY = 2,
        PositionZ = 3,
        AngleX = 4,
        AngleY = 5,
        AngleZ = 6,
        Num = 7,
    }

    /// <summary>
    /// `Imas.CharaImasMotion.Curve` (TypeDefIndex 14919; path 0x10, property_type 0x18,
    /// property_name 0x20, key_type 0x28, values 0x30). Produced from one asset curve by
    /// `ImoCurveConverter.AssetCurveToRuntimeCurve` (0x37FF198).
    /// </summary>
    public sealed class Curve
    {
        public string path;
        public PropertyType property_type;
        public string property_name;
        public KeyType key_type;
        public float[] values;
    }
}

namespace Imas
{
    /// <summary>
    /// `Imas.CharacterImasMotionAsset` (TypeDefIndex 9715). This is the `eidolon.imo/1`
    /// JSON written by `spikes/porting-3d/export_imo.py`: the asset is copied verbatim,
    /// including every curve's `attribs` (which carry property_type/key_type).
    /// </summary>
    [Serializable]
    public sealed class CharacterImasMotionAsset
    {
        /// <summary>
        /// `CharacterImasMotionAsset.Curve` (TypeDefIndex 9714): path, attribs, values.
        /// (Native declares a struct; a class keeps `JsonUtility` de/serialisation simple
        /// and has no behavioural effect here.)
        /// </summary>
        [Serializable]
        public sealed class Curve
        {
            public string path;
            public string[] attribs;
            public float[] values;
        }

        public string format;          // "eidolon.imo/1" — export header, not a native field
        public string name;            // m_Name, e.g. "dan_loveig_01_dan.imo"
        public string kind;            // "imo.chara" / "imo.cam" / "optional" / "item-sync-mot"
        public string[] attribs;       // asset-level attribs; empty in shipped data
        public float time_length;
        public string date;
        public string source_bundle;   // export metadata; native has the bundle outside the asset
        public Curve[] curves;

        /// <summary>Parses one exported asset. `JsonUtility` is native C++ and handles the
        /// 13 MB `dan_loveig_01` asset in the tens-of-milliseconds range; see the notes in
        /// /tmp/motion-native-notes.md for the measured layout and memory shape.</summary>
        public static CharacterImasMotionAsset FromJson(string json)
        {
            if (string.IsNullOrEmpty(json)) return null;
            return JsonUtility.FromJson<CharacterImasMotionAsset>(json);
        }

        public static CharacterImasMotionAsset Load(string path)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
            return FromJson(File.ReadAllText(path));
        }
    }

    /// <summary>
    /// `Imas.ImoCurveConverter` (TypeDefIndex 9767).
    /// </summary>
    public static class ImoCurveConverter
    {
        public const string s_property_type_str = "property_type";
        public const string s_property_name_str = "property_name";
        public const string s_key_type_str = "key_type";

        // Native splits each attrib with String.Split(new[]{' '}) (0x6464940) and then
        // switches on the first token (0x37FF198); Enum.Parse is used for the two enums.
        private static readonly char[] s_separator = { ' ' };

        /// <summary>`ImoCurveConverter.AssetCurveToRuntimeCurve` — 0x37FF198.</summary>
        public static CharaImasMotion.Curve AssetCurveToRuntimeCurve(CharacterImasMotionAsset.Curve asset_curve)
        {
            if (asset_curve == null) return null;
            var curve = new CharaImasMotion.Curve();
            curve.path = asset_curve.path;
            curve.values = asset_curve.values;
            var attribs = asset_curve.attribs;
            if (attribs != null)
            {
                for (var i = 0; i < attribs.Length; i++)
                {
                    var attrib = attribs[i];
                    if (string.IsNullOrEmpty(attrib)) continue;
                    var parts = attrib.Split(s_separator, StringSplitOptions.None);
                    if (parts.Length < 2) continue;
                    var key = parts[0];
                    var value = parts[1];
                    if (key == s_property_type_str)
                    {
                        curve.property_type = ParseEnum(value, CharaImasMotion.PropertyType.None);
                    }
                    else if (key == s_property_name_str)
                    {
                        curve.property_name = value;
                    }
                    else if (key == s_key_type_str)
                    {
                        curve.key_type = ParseEnum(value, CharaImasMotion.KeyType.None);
                    }
                    // Native has no else: an unknown prefix is ignored.
                }
            }
            return curve;
        }

        /// <summary>`ImoCurveConverter.RuntimeCurveToAssetCurve` — 0x37FF5D4 (round trip,
        /// used by the export tooling rather than by playback).</summary>
        public static CharacterImasMotionAsset.Curve RuntimeCurveToAssetCurve(CharaImasMotion.Curve curve)
        {
            if (curve == null) return null;
            var attribs = new List<string>(3);
            if (curve.property_type != CharaImasMotion.PropertyType.None)
                attribs.Add(s_property_type_str + " " + curve.property_type);
            if (!string.IsNullOrEmpty(curve.property_name))
                attribs.Add(s_property_name_str + " " + curve.property_name);
            if (curve.key_type != CharaImasMotion.KeyType.None)
                attribs.Add(s_key_type_str + " " + curve.key_type);
            return new CharacterImasMotionAsset.Curve
            {
                path = curve.path,
                attribs = attribs.ToArray(),
                values = curve.values,
            };
        }

        // Native Enum.Parse(string, bool) throws ArgumentException on an unknown
        // token, and the port now matches it (deviation audit B-6): a bad asset
        // fails loudly at load time with the raw exception (ADR-0033 "不静默"
        // — silent fallback to 0/None masked the failure and quietly aimed the
        // curve at slot 0).
        private static T ParseEnum<T>(string text, T fallback) where T : struct
        {
            if (Enum.TryParse(text, false, out T parsed)) return parsed;
            throw new ArgumentException(
                $"Item={text ?? "<null>"} is not a valid {typeof(T).Name} value (imo asset enum token unknown)",
                nameof(text));
        }
    }

    /// <summary>
    /// `Imas.CharacterImasMotionData` (TypeDefIndex 9718): the runtime form of one imo
    /// asset — curves folded into per-path `CurveSet`s whose six slots are px/py/pz/rx/ry/rz.
    /// </summary>
    public sealed class CharacterImasMotionData
    {
        /// <summary>TypeDefIndex 9716 (path 0x10, px 0x18, py 0x20, pz 0x28, rx 0x30, ry 0x38, rz 0x40).</summary>
        public sealed class CurveSet
        {
            public string path;
            public CharaImasMotion.Curve px;
            public CharaImasMotion.Curve py;
            public CharaImasMotion.Curve pz;
            public CharaImasMotion.Curve rx;
            public CharaImasMotion.Curve ry;
            public CharaImasMotion.Curve rz;

            /// <summary>Native gate for `Transform.set_localPosition` (0x37EE99C: any of
            /// px/py/pz non-null). It is *not* "the value is non-zero".</summary>
            public bool HasPosition => px != null || py != null || pz != null;

            public bool HasAngle => rx != null || ry != null || rz != null;
        }

        public string name;   // 0x10 — asset m_Name, e.g. "dan_loveig_01_dan.imo"
        public float length;  // 0x18 — asset time_length
        public List<CurveSet> curve_sets = new List<CurveSet>(); // 0x20

        /// <summary>
        /// `CharacterImasMotionData.CreateFromImoAsset` — 0x37EC030.
        /// Groups the asset curves by path and stores each runtime curve in the slot named
        /// by `property_type - 1` (1..6 there, i.e. PositionX..AngleZ); a later curve for
        /// the same slot overwrites the earlier one. `General` (0) has no slot and is
        /// dropped, which is why dance assets carry no General curves.
        /// </summary>
        public static CharacterImasMotionData CreateFromImoAsset(CharacterImasMotionAsset imo_asset)
        {
            if (imo_asset == null) return null;
            var data = new CharacterImasMotionData();
            data.name = imo_asset.name;
            data.length = imo_asset.time_length;
            var curves = imo_asset.curves;
            if (curves == null) return data;
            for (var i = 0; i < curves.Length; i++)
            {
                var curve = ImoCurveConverter.AssetCurveToRuntimeCurve(curves[i]);
                if (curve == null) continue;
                var set = FindSet(data.curve_sets, curve.path);
                if (set == null)
                {
                    set = new CurveSet { path = curve.path };
                    data.curve_sets.Add(set);
                }
                switch (curve.property_type)
                {
                    case CharaImasMotion.PropertyType.PositionX: set.px = curve; break;
                    case CharaImasMotion.PropertyType.PositionY: set.py = curve; break;
                    case CharaImasMotion.PropertyType.PositionZ: set.pz = curve; break;
                    case CharaImasMotion.PropertyType.AngleX: set.rx = curve; break;
                    case CharaImasMotion.PropertyType.AngleY: set.ry = curve; break;
                    case CharaImasMotion.PropertyType.AngleZ: set.rz = curve; break;
                    default: break; // General / None: no slot in the dance data
                }
            }
            return data;
        }

        private static CurveSet FindSet(List<CurveSet> sets, string path)
        {
            for (var i = 0; i < sets.Count; i++)
                if (sets[i].path == path) return sets[i];
            return null;
        }

        /// <summary>`CharacterImasMotionData.GetKeyCount` — 0x37EC388.</summary>
        public static int GetKeyCount(CharaImasMotion.Curve curve)
        {
            if (curve == null || curve.values == null) return 0;
            var n = curve.values.Length;
            switch (curve.key_type)
            {
                case CharaImasMotion.KeyType.FullFrame: return n;
                case CharaImasMotion.KeyType.Discreate: return n / 2;
                case CharaImasMotion.KeyType.Const: return 1;
                case CharaImasMotion.KeyType.FCurve: return n / 4;
                case CharaImasMotion.KeyType.FullFrameOffset:
                case CharaImasMotion.KeyType.DeltaFrame: return n - 1;
                default: return 0;
            }
        }

        /// <summary>`CharacterImasMotionData.GetDeltaTime` — 0x37EC454.</summary>
        public static float GetDeltaTime(CharaImasMotion.Curve curve)
        {
            if (curve != null && curve.key_type == CharaImasMotion.KeyType.DeltaFrame)
            {
                if (curve.values != null && curve.values.Length > 0) return curve.values[0];
            }
            return CharacterImasMotionPlayer.s_delta_time;
        }

        /// <summary>`CharacterImasMotionData.GetKeyTime` — 0x37EC4A4.</summary>
        public static float GetKeyTime(CharaImasMotion.Curve curve, int key_index)
        {
            if (curve == null || curve.values == null) return 0f;
            var v = curve.values;
            var dt = CharacterImasMotionPlayer.s_delta_time;
            switch (curve.key_type)
            {
                case CharaImasMotion.KeyType.FullFrame:
                    return (float)key_index * dt;
                case CharaImasMotion.KeyType.Discreate:
                    return Key(v, 2 * key_index);
                case CharaImasMotion.KeyType.FCurve:
                    return Key(v, 4 * key_index);
                case CharaImasMotion.KeyType.FullFrameOffset:
                    return (float)key_index * dt + Key(v, 0);
                case CharaImasMotion.KeyType.DeltaFrame:
                    return Key(v, 0) * (float)key_index;
                default:
                    return 0f;
            }
        }

        /// <summary>`CharacterImasMotionData.GetKeyValue` — 0x37EC598.</summary>
        public static float GetKeyValue(CharaImasMotion.Curve curve, int key_index)
        {
            if (curve == null || curve.values == null) return 0f;
            var v = curve.values;
            switch (curve.key_type)
            {
                case CharaImasMotion.KeyType.FullFrame:
                    return Key(v, key_index);
                case CharaImasMotion.KeyType.Discreate:
                    return Key(v, 2 * key_index + 1);
                case CharaImasMotion.KeyType.Const:
                    return Key(v, 0);
                case CharaImasMotion.KeyType.FCurve:
                    return Key(v, 4 * key_index + 1);
                case CharaImasMotion.KeyType.FullFrameOffset:
                case CharaImasMotion.KeyType.DeltaFrame:
                    return Key(v, key_index + 1);
                default:
                    return 0f;
            }
        }

        private static float Key(float[] values, int index)
        {
            return index >= 0 && index < values.Length ? values[index] : 0f;
        }
    }

    /// <summary>
    /// `Imas.CharacterImasMotionPlayer` (TypeDefIndex 9719): the stateless curve evaluator.
    /// </summary>
    public static class CharacterImasMotionPlayer
    {
        /// <summary>Native const `s_delta_time` = 0.016666668 (1/60).</summary>
        public const float s_delta_time = 0.016666668f;

        /// <summary>
        /// `CharacterImasMotionPlayer.GetLastSeekerPosition` — 0x37E89DC.
        /// Returns the last *segment* index, which is what `set_seeker_to_end` stores.
        /// </summary>
        public static int GetLastSeekerPosition(CharaImasMotion.Curve curve)
        {
            if (curve == null || curve.values == null) return 0;
            var n = curve.values.Length;
            switch (curve.key_type)
            {
                case CharaImasMotion.KeyType.FullFrame:
                case CharaImasMotion.KeyType.FullFrameOffset:
                case CharaImasMotion.KeyType.DeltaFrame:
                    return n - 2;
                case CharaImasMotion.KeyType.Discreate:
                    return n / 2 - 2;
                case CharaImasMotion.KeyType.FCurve:
                    return n / 4 - 2;
                default:
                    return 0;
            }
        }

        /// <summary>
        /// `CharacterImasMotionPlayer.SolveCurve(Curve curve, float time, ref int seeker_position)`
        /// — 0x38A9500 (old 0x37E80B8). Mirrors the native key_type switch exactly;
        /// see the per-case helpers for the native formula.
        /// </summary>
        public static float SolveCurve(CharaImasMotion.Curve curve, float time, ref int seeker_position)
        {
            if (curve == null || curve.values == null) return 0f;
            switch (curve.key_type)
            {
                case CharaImasMotion.KeyType.FullFrame:      // case 0
                    return SolveFullFrame(curve.values, time);
                case CharaImasMotion.KeyType.Discreate:      // case 1
                    return SolveLinearPairs(curve.values, time, ref seeker_position);
                case CharaImasMotion.KeyType.Const:          // case 2
                    return SolveConst(curve.values);
                case CharaImasMotion.KeyType.FCurve:         // case 3
                    return SolveHermite(curve.values, time, ref seeker_position);
                case CharaImasMotion.KeyType.Step:           // case 4
                    return SolveStepPairs(curve.values, time, ref seeker_position);
                case CharaImasMotion.KeyType.FullFrameOffset: // case 6
                    return SolveFullFrameOffset(curve.values, time);
                case CharaImasMotion.KeyType.DeltaFrame:     // case 7
                    return SolveDeltaFrame(curve.values, time);
                default:
                    // case 5 (Step_3Values) and None fall into the native `default` branch
                    // of the switch: SolveCurve returns 0 without looking at the keys.
                    return 0f;
            }
        }

        // case 0 — FullFrame: one value per 1/60 s, linear between adjacent samples.
        private static float SolveFullFrame(float[] values, float time)
        {
            var count = values.Length;
            if (count == 0) return 0f;
            var position = time / s_delta_time;
            var index = Mathf.FloorToInt(position);
            if (index < 0) return values[0];                       // negative → first key
            if (index >= count - 1) return values[count - 1];      // past the end → last key
            var low = values[index];
            var high = values[index + 1];
            var ratio = (time - (float)index * s_delta_time) / s_delta_time;
            ratio = ratio <= 1f ? ratio : 1f;
            if (ratio < 0f) ratio = 0f;
            return low + (high - low) * ratio;
        }

        // case 1 — Discreate: (time, value) pairs, linear between the bracketing keys.
        private static float SolveLinearPairs(float[] values, float time, ref int seeker_position)
        {
            var count = values.Length / 2;
            if (count == 0) return 0f;
            var last = count - 1;
            if (values[2 * last] > time)
            {
                if (values[0] >= time) return values[1];
                var index = FindSegment(values, 2, count, time);
                if (index < 0) return values[1];
                seeker_position = index;
                var start = values[2 * index];
                var end = values[2 * (index + 1)];
                var ratio = 0f;
                if (start != end)
                {
                    ratio = (time - start) / (end - start);
                    ratio = ratio <= 1f ? ratio : 1f;
                    if (ratio < 0f) ratio = 0f;
                }
                var low = values[2 * index + 1];
                var high = values[2 * (index + 1) + 1];
                return low + (high - low) * ratio;
            }
            return values[2 * last + 1];
        }

        // case 2 — Const: one value, never interpolated.
        private static float SolveConst(float[] values)
        {
            return values.Length > 0 ? values[0] : 0f;
        }

        // case 3 — FCurve: (time, value, inTangent, outTangent) keys. The native segment
        // uses key[i][3] as the outgoing tangent and key[i+1][2] as the incoming tangent
        // and scales both by the key span; the basis is the standard cubic Hermite.
        private static float SolveHermite(float[] values, float time, ref int seeker_position)
        {
            var count = values.Length / 4;
            if (count == 0) return 0f;
            var last = count - 1;
            if (values[4 * last] <= time) return values[4 * last + 1];
            if (values[0] >= time) return values[1];
            var index = FindSegment(values, 4, count, time);
            if (index < 0) return values[1];
            seeker_position = index;
            var baseIndex = 4 * index;
            var start = values[baseIndex];
            var end = values[baseIndex + 4];
            var span = end - start;
            var u = 0f;
            if (span != 0f)
            {
                u = (time - start) / span;
                u = u <= 1f ? u : 1f;
                if (u < 0f) u = 0f;
            }
            var value0 = values[baseIndex + 1];
            var outTangent = values[baseIndex + 3];
            var value1 = values[baseIndex + 5];
            var inTangent = values[baseIndex + 6];
            // Native bails out to `value0` when either tangent is +-inf
            // (0x38A9500 case 3, old 0x37E80B8).
            if (float.IsInfinity(outTangent) || float.IsInfinity(inTangent)) return value0;
            var u2 = u * u;
            var u3 = u2 * u;
            var h01 = 3f * u2 - 2f * u3;         // -2u^3 + 3u^2
            var h00 = (2f * u3 - 3f * u2) + 1f;  //  2u^3 - 3u^2 + 1
            var h10 = (u3 - 2f * u2) + u;        //  u^3 - 2u^2 + u
            var h11 = u3 - u2;                   //  u^3 - u^2
            return value1 * h01 + value0 * h00 + span * (outTangent * h10) + span * (inTangent * h11);
        }

        // case 4 — Step: (time, value) pairs, hold the previous value (no interpolation).
        private static float SolveStepPairs(float[] values, float time, ref int seeker_position)
        {
            var count = values.Length / 2;
            if (count == 0) return 0f;
            var last = count - 1;
            if (values[2 * last] <= time) return values[2 * last + 1];
            if (values[0] < time)
            {
                var index = FindSegment(values, 2, count, time);
                if (index < 0) return values[1];
                seeker_position = index;
                return values[2 * index + 1];
            }
            return values[1];
        }

        // case 6 — FullFrameOffset: values[0] is the start time, then one sample per 1/60 s.
        private static float SolveFullFrameOffset(float[] values, float time)
        {
            var count = values.Length - 1;
            if (count <= 0) return 0f;
            var start = values[0];
            var position = (time - start) / s_delta_time;
            var index = Mathf.FloorToInt(position);
            if (index < 0) return values[1];
            if (index >= count - 1) return values[count];
            var low = values[index + 1];
            var high = values[index + 2];
            // Native 0x38A9500 case 6 (old 0x37E80B8), confirmed from the
            // current-binary decompile: the sample index uses
            // (time - values[0]) / dt, but the interpolation fraction is
            // (time - index * dt) / dt — it does NOT subtract values[0].
            // motion.py computes (time - start - index*dt)/dt instead. The
            // shipped snapshot has no key_type==6 curve, so this is not
            // observable yet; the port keeps the native expression.
            var ratio = (time - (float)index * s_delta_time) / s_delta_time;
            ratio = ratio <= 1f ? ratio : 1f;
            if (ratio < 0f) ratio = 0f;
            return low + (high - low) * ratio;
        }

        // case 7 — DeltaFrame: values[0] is the frame length in seconds, then samples.
        private static float SolveDeltaFrame(float[] values, float time)
        {
            var count = values.Length - 1;
            if (count <= 0) return 0f;
            var frame = values[0];
            if (frame == 0f) return values[1]; // native divides by zero → negative-index branch
            var position = time / frame;
            var index = Mathf.FloorToInt(position);
            if (index < 0) return values[1];
            if (index >= count - 1) return values[count];
            var low = values[index + 1];
            var high = values[index + 2];
            var ratio = (time - frame * (float)index) / frame;
            ratio = ratio <= 1f ? ratio : 1f;
            if (ratio < 0f) ratio = 0f;
            return low + (high - low) * ratio;
        }

        // Largest index in [0, count-2] whose key time is <= time, or -1.
        // Equivalent to the native seeker scan; the seeker is only a speed hint.
        private static int FindSegment(float[] values, int stride, int count, float time)
        {
            var low = 0;
            var high = count - 2;
            var result = -1;
            while (low <= high)
            {
                var middle = low + ((high - low) >> 1);
                if (values[stride * middle] <= time)
                {
                    result = middle;
                    low = middle + 1;
                }
                else
                {
                    high = middle - 1;
                }
            }
            return result;
        }
    }

    /// <summary>
    /// `Imas.CharaOptionalImoData` (TypeDefIndex 9765): the second, independent asset pair
    /// (`kind == "optional"`) that carries the HandToHand curves. length 0x10, curves 0x18.
    /// </summary>
    public sealed class CharaOptionalImoData
    {
        /// <summary>`CharaOptionalImoData.Property` (TypeDefIndex 9764).</summary>
        public enum Property
        {
            None = -1,
            HandToHand_RH = 0,
            HandToHand_LH = 1,
            Num = 2,
        }

        public float length;
        public CharaImasMotion.Curve[] curves;

        /// <summary>
        /// `CharaOptionalImoData.CreateFromImoAsset` — 0x37FE7B4.
        /// Allocates `curves[Property.Num]` (2), keeps only `property_type == General`
        /// curves and places each at the index named by its `property_name`
        /// (`HandToHand_RH`/`HandToHand_LH`); everything else is ignored.
        /// </summary>
        public static CharaOptionalImoData CreateFromImoAsset(CharacterImasMotionAsset imo_asset)
        {
            if (imo_asset == null) return null;
            var data = new CharaOptionalImoData();
            data.curves = new CharaImasMotion.Curve[(int)Property.Num];
            var curves = imo_asset.curves;
            if (curves != null)
            {
                for (var i = 0; i < curves.Length; i++)
                {
                    var curve = ImoCurveConverter.AssetCurveToRuntimeCurve(curves[i]);
                    if (curve == null) continue;
                    if (curve.property_type != CharaImasMotion.PropertyType.General) continue;
                    Property property;
                    if (!Enum.TryParse(curve.property_name, false, out property)) continue;
                    if (property == Property.None) continue;
                    var index = (int)property;
                    if (index < 0 || index >= data.curves.Length)
                    {
                        Debug.LogWarning("CharaOptionalImoData: property index " + index + " for '" +
                                         curve.property_name + "' does not fit curves[" + data.curves.Length + "]");
                        continue;
                    }
                    data.curves[index] = curve;
                }
            }
            data.length = imo_asset.time_length;
            return data;
        }
    }

    /// <summary>
    /// `Imas.CharacterImasMotionPlayerDance` (TypeDefIndex 9730): the dance player. It keeps
    /// a list of registered motions (imo data + optional data + binders + loop flag), one
    /// seeker (per-curve search hints), one results array and the current/next time
    /// accumulators, and writes the solved Euler angles / positions onto the transforms of
    /// the registered curve sets.
    /// </summary>
    public class CharacterImasMotionPlayerDance
    {
        /// <summary>Native `Create` allocates Result[64] and Seeker.Node[64] (0x37EDC60);
        /// the 64 is the fixed animated-bone table size. The port grows past it if a data
        /// set has more paths (same shape, just a capacity, no behavioural change).</summary>
        public const int kCapacity = 64;

        /// <summary>`CharacterImasMotionPlayerDance.Result` (TypeDefIndex 9723): angle 0x10, position 0x1C.</summary>
        public sealed class Result
        {
            public Vector3 angle;
            public Vector3 position;
        }

        /// <summary>`CharacterImasMotionPlayerDance.Seeker` (TypeDefIndex 9726): nodes 0x10, opt_curves 0x18.</summary>
        public sealed class Seeker
        {
            /// <summary>`Seeker.Curve` (TypeDefIndex 9724): a single int search hint.</summary>
            public struct Curve
            {
                public int position;
            }

            /// <summary>`Seeker.Node` (TypeDefIndex 9725): px, py, pz, rx, ry, rz.</summary>
            public struct Node
            {
                public Curve px;
                public Curve py;
                public Curve pz;
                public Curve rx;
                public Curve ry;
                public Curve rz;
            }

            public Node[] nodes;
            public Curve[] opt_curves;
        }

        /// <summary>`CurveBinder` (TypeDefIndex 9721): curve_set 0x10, tr 0x18.</summary>
        public sealed class CurveBinder
        {
            public CharacterImasMotionData.CurveSet curve_set;
            public Transform tr;
        }

        /// <summary>`RegisteredMotion` (TypeDefIndex 9722): imo_data 0x10, curve_binders 0x18,
        /// opt_imo_data 0x20, is_loop 0x28.</summary>
        public sealed class RegisteredMotion
        {
            public CharacterImasMotionData imo_data;
            public CurveBinder[] curve_binders;
            public CharaOptionalImoData opt_imo_data;
            public bool is_loop;
        }

        /// <summary>`BookMark` (TypeDefIndex 9720): time 0x10, seeker 0x18. The native copy
        /// only stores the per-node seeker positions (0x37ED48C).</summary>
        public sealed class BookMark
        {
            public float time;
            public Seeker.Node[] nodes;
        }

        protected List<RegisteredMotion> registered_motions = new List<RegisteredMotion>(); // 0x10
        protected RegisteredMotion initial_pose;                                             // 0x18
        protected Result[] results;                                                          // 0x20
        protected Seeker seeker;                                                             // 0x28
        protected int current_motion_index = -1;                                             // 0x30
        protected GameObject go;                                                             // 0x38
        protected bool status_is_play_idle;                                                  // 0x40 (Status)
        public float current_time;                                                           // 0x44
        public float next_time;                                                              // 0x48
        protected float[] step_keys;                                                         // 0x50
        public float[] opt_results;                                                          // 0x58

        /// <summary>
        /// Port-only seam. Native `register_imo_data` (0x37ECCE4) first maps a curve path to
        /// a `CharacterSkeleton.GetAnimatedBones()` index and then calls
        /// `go.transform.Find(path)`. The spike does not carry the common-skeleton table, so
        /// the index is replaced by "slot = curve set order" (equivalent for transform writes)
        /// and path resolution is delegated here. Default = native `go.transform.Find(path)`.
        /// </summary>
        public Func<Transform, string, Transform> path_resolver;

        /// <summary>
        /// Port-only data hook for the `status.is_play_idle` branch of `SolveCurves`
        /// (0x38AF7CC, old 0x37EE384). Native copies the cached pose of
        /// `CharacterCommonSkeleton.GetStatic()` (0x38AA2B8); that table is a game
        /// resource the spike does not have. Set this to a captured pose to reproduce
        /// idle exactly; null keeps the last solved results.
        /// </summary>
        public Result[] idle_results;

        public bool IsPlayIdle => status_is_play_idle;
        public int CurrentMotionIndex => current_motion_index;
        public int MotionCount => registered_motions.Count;
        public float[] StepKeys => step_keys;

        /// <summary>`CharacterImasMotionPlayerDance..ctor` — 0x37EDA28 (fields only).</summary>
        public CharacterImasMotionPlayerDance()
        {
            opt_results = new float[(int)CharaOptionalImoData.Property.Num];
        }

        // ------------------------------------------------------------------ setup

        /// <summary>
        /// `CharacterImasMotionPlayerDance.Create` — 0x37EDC60.
        /// Native also seeds every Result from `CharacterCommonSkeleton.GetStatic()` (its
        /// per-bone bind position/angle). That table is unavailable in the spike, so results
        /// start at zero. This is not observable on the shipped dance assets: every curve set
        /// that has angle channels has all three, and likewise for position, so every slot is
        /// overwritten by the first solve. Recorded as a data-gap in the notes.
        /// </summary>
        public void Create(GameObject go)
        {
            this.go = go;
            seeker = new Seeker();
            EnsureCapacity(kCapacity);
            seeker.opt_curves = new Seeker.Curve[(int)CharaOptionalImoData.Property.Num];
        }

        /// <summary>
        /// `register_imo_data` / `RegisterImoData` — 0x37ECCE4 / 0x37ECCE0.
        /// Builds one CurveBinder per curve set whose transform resolves; stores the motion
        /// at `index` in the registered list (padding with nulls like the native List does).
        /// </summary>
        public void RegisterImoData(int index, CharacterImasMotionData imo_data, CharaOptionalImoData opt_imo_data)
        {
            if (index < 0) return;
            EnsureCapacity(kCapacity);
            var motion = new RegisteredMotion
            {
                imo_data = imo_data,
                opt_imo_data = opt_imo_data,
                is_loop = false,
            };
            var setCount = imo_data != null && imo_data.curve_sets != null ? imo_data.curve_sets.Count : 0;
            var capacity = Math.Max(kCapacity, setCount);
            var binders = new CurveBinder[capacity];
            EnsureCapacity(capacity);
            for (var i = 0; i < setCount; i++)
            {
                var set = imo_data.curve_sets[i];
                if (set == null) continue;
                var tr = ResolveTransform(set.path);
                // Native skips a curve set when the path has no animated bone or
                // Transform.Find returns null (0x37ECCE4).
                if (tr == null) continue;
                binders[i] = new CurveBinder { curve_set = set, tr = tr };
            }
            motion.curve_binders = binders;
            while (registered_motions.Count <= index) registered_motions.Add(null);
            registered_motions[index] = motion;
        }

        private Transform ResolveTransform(string path)
        {
            if (path_resolver != null) return path_resolver(go != null ? go.transform : null, path);
            if (go == null) return null;
            return go.transform.Find(path);
        }

        /// <summary>`GetRegisteredImoData` — 0x37ED180.</summary>
        public CharacterImasMotionData GetRegisteredImoData(int index)
        {
            var motion = GetRegisteredMotion(index);
            return motion != null ? motion.imo_data : null;
        }

        /// <summary>`get_registerd_motion` — 0x37ED2AC.</summary>
        protected RegisteredMotion GetRegisteredMotion(int index)
        {
            if (index < 0 || registered_motions == null || index >= registered_motions.Count) return null;
            return registered_motions[index];
        }

        /// <summary>`get_current_motion` — 0x37ECC74.</summary>
        protected RegisteredMotion GetCurrentMotion()
        {
            return GetRegisteredMotion(current_motion_index);
        }

        /// <summary>`SetLoopToMotion` — 0x37ED238.</summary>
        public void SetLoopToMotion(int index, bool is_loop)
        {
            var motion = GetRegisteredMotion(index);
            if (motion != null) motion.is_loop = is_loop;
        }

        // ------------------------------------------------------------- transport

        /// <summary>
        /// `PlayMotion` — 0x37EC6EC. Resets time to 0, clears the seeker and the idle flag,
        /// and installs the per-dance step-key table selected by the imo asset name.
        /// </summary>
        public void PlayMotion(int index)
        {
            if (index < 0) return;
            if (registered_motions == null || registered_motions.Count <= index) return;
            current_motion_index = index;
            current_time = 0f;
            next_time = 0f;
            SetSeekerToStart();
            step_keys = null;
            status_is_play_idle = false;
            var motion = GetCurrentMotion();
            if (motion != null && motion.imo_data != null) step_keys = StepKeysFor(motion.imo_data.name);
        }

        /// <summary>`PlayInitialPose` — 0x37ECBD8: only flips `status.is_play_idle`.</summary>
        public void PlayInitialPose()
        {
            status_is_play_idle = true;
        }

        /// <summary>`SetTime` — 0x37ECBE4. Note that it stores into `next_time`: the external
        /// caller (music sync) offers the next time and the next `UpdateTime` transfers it.</summary>
        public void SetTime(float time)
        {
            next_time = time;
        }

        /// <summary>`GetTime` — 0x37ECBEC.</summary>
        public float GetTime()
        {
            return current_time;
        }

        /// <summary>`TimeLength` — 0x37ECBF4.</summary>
        public float TimeLength()
        {
            var motion = GetCurrentMotion();
            return motion != null && motion.imo_data != null ? motion.imo_data.length : 0f;
        }

        /// <summary>
        /// `UpdateTime` — 0x37EDF1C. Two accumulators: every call transfers `next_time` into
        /// `current_time` and then advances `next_time` by delta. When the previous
        /// `current_time` has run past the motion length it is clamped (non-loop) or wrapped
        /// with `floor` (loop) first; the seeker then jumps to the matching end. The dance
        /// system calls this with delta 0 after `SetTime` (0x1EDD228); the offline/patched
        /// callers can pass a real delta.
        /// </summary>
        public void UpdateTime(float delta_time)
        {
            if (current_motion_index < 0) return;
            var motion = GetCurrentMotion();
            if (motion == null || motion.imo_data == null) return;
            var length = motion.imo_data.length;
            var time = current_time;
            if (time >= length)
            {
                if (!motion.is_loop)
                {
                    next_time = length;
                    SetSeekerToEnd();
                }
                else
                {
                    var wrapped = time - length * Mathf.Floor(time / length);
                    var candidate = length;
                    if (wrapped <= length) candidate = wrapped;
                    if (wrapped < 0f) candidate = 0f;
                    next_time = candidate;
                    SetSeekerToStart();
                }
            }
            else if (time < 0f)
            {
                if (motion.is_loop)
                {
                    var wrapped = time - length * Mathf.Floor(time / length);
                    var candidate = length;
                    if (wrapped <= length) candidate = wrapped;
                    if (wrapped < 0f) candidate = 0f;
                    next_time = candidate;
                    SetSeekerToEnd(); // native LABEL_26 (0x37EDF1C) does this for the negative loop case
                }
                else
                {
                    current_time = 0f;
                    SetSeekerToStart();
                }
            }
            var transfer = next_time;
            current_time = transfer;
            next_time = transfer + delta_time;
        }

        // ----------------------------------------------------------------- solve

        /// <summary>
        /// `SolveCurves(bool dontInterpolateThisFrame = false)` — 0x38AF7CC
        /// (old 0x37EE384).
        ///   * normal: solve the curves at the exact current time; with a step-key
        ///     table temporarily snap `current_time` to `step_keys[index] / 60`
        ///     (`Array.FindIndex` on the current frame number), solve, restore.
        ///   * dontInterpolateThisFrame: temporarily snap `current_time` to a whole
        ///     1/60 frame, solve, restore. UNKNOWN(native 0x38AF7CC): the native
        ///     rounding helper `sub_66D7C10(5,0,0,time*60)` has no identified
        ///     managed method; the port keeps the Math.Round reading (report marks
        ///     this branch needs-runtime-probe), including the native
        ///     int.MinValue/60 (-35791396) sentinel for the infinite-frame case.
        ///   * idle (`status.is_play_idle`): copy the common-skeleton pose (see
        ///     `idle_results` / CopyIdleResults).
        /// </summary>
        public void SolveCurves(bool dontInterpolateThisFrame = false)
        {
            if (!status_is_play_idle)
            {
                if (!dontInterpolateThisFrame)
                {
                    if (step_keys == null)
                    {
                        SolveCurvesEntity();
                        return;
                    }
                    // native <SolveCurves>b__0 (0x37EEF00): cfrm < key + 1 && cfrm >= key
                    var cfrm = current_time * 60f;
                    var found = -1;
                    for (var i = 0; i < step_keys.Length; i++)
                    {
                        if (cfrm < step_keys[i] + 1f && cfrm >= step_keys[i])
                        {
                            found = i;
                            break;
                        }
                    }
                    var saved = current_time;
                    // native: step_keys[found] / 60.0 (double divide, then narrowed to float)
                    if (found >= 0) current_time = (float)((double)step_keys[found] / 60.0);
                    SolveCurvesEntity();
                    current_time = saved;
                    return;
                }
                var saved_time = current_time;
                // native: Math.Round((double)current_time * 60.0, 0, MidpointRounding.ToEven)
                var rounded = Math.Round((double)current_time * 60.0, 0, MidpointRounding.ToEven);
                current_time = (float)((int)rounded / 60.0);
                SolveCurvesEntity();
                current_time = saved_time;
                return;
            }
            CopyIdleResults();
        }

        /// <summary>
        /// `solve_curves_entity` — 0x37EE6AC: for every binder, evaluate the six channels
        /// that exist and overwrite only those fields of the previous result (channels the
        /// motion does not animate keep their previous value, exactly like native).
        /// </summary>
        protected void SolveCurvesEntity()
        {
            var motion = GetCurrentMotion();
            if (motion == null || motion.curve_binders == null) return;
            var binders = motion.curve_binders;
            for (var i = 0; i < binders.Length; i++)
            {
                var binder = binders[i];
                if (binder == null) continue;
                var set = binder.curve_set;
                if (set == null) continue;
                if (results == null || i >= results.Length || results[i] == null) continue;
                var result = results[i];
                var node = seeker.nodes[i];
                var px = result.position.x;
                var py = result.position.y;
                var pz = result.position.z;
                var rx = result.angle.x;
                var ry = result.angle.y;
                var rz = result.angle.z;
                if (set.px != null) px = CharacterImasMotionPlayer.SolveCurve(set.px, current_time, ref node.px.position);
                if (set.py != null) py = CharacterImasMotionPlayer.SolveCurve(set.py, current_time, ref node.py.position);
                if (set.pz != null) pz = CharacterImasMotionPlayer.SolveCurve(set.pz, current_time, ref node.pz.position);
                if (set.rx != null) rx = CharacterImasMotionPlayer.SolveCurve(set.rx, current_time, ref node.rx.position);
                if (set.ry != null) ry = CharacterImasMotionPlayer.SolveCurve(set.ry, current_time, ref node.ry.position);
                if (set.rz != null) rz = CharacterImasMotionPlayer.SolveCurve(set.rz, current_time, ref node.rz.position);
                seeker.nodes[i] = node;
                result.position = new Vector3(px, py, pz);
                result.angle = new Vector3(rx, ry, rz);
            }
        }

        /// <summary>
        /// `SetResultToTransforms` — 0x37EE99C. Rotation is always written for a bound bone
        /// (`Quaternion.Euler(angle)`, the native call is Internal_FromEulerRad on
        /// angle*Deg2Rad). Position is written only when the curve set has at least one
        /// Position curve (px/py/pz != null).
        /// </summary>
        public void SetResultToTransforms()
        {
            if (current_motion_index < 0) return;
            var motion = GetCurrentMotion();
            if (motion == null || motion.curve_binders == null) return;
            var binders = motion.curve_binders;
            for (var i = 0; i < binders.Length; i++)
            {
                var binder = binders[i];
                if (binder == null || binder.tr == null || binder.curve_set == null) continue;
                if (results == null || i >= results.Length || results[i] == null) continue;
                var result = results[i];
                binder.tr.localRotation = Quaternion.Euler(result.angle.x, result.angle.y, result.angle.z);
                if (binder.curve_set.HasPosition) binder.tr.localPosition = result.position;
            }
        }

        /// <summary>
        /// `SolveOptionalCurves` — 0x37EEB2C. Solves exactly the first two optional curves
        /// (HandToHand_RH then HandToHand_LH) and stores them in `opt_results[0..1]`; the
        /// hand IK consumer reads those two floats (0x1EDD380). Skipped while idle.
        /// </summary>
        public void SolveOptionalCurves()
        {
            if (status_is_play_idle) return;
            var motion = GetCurrentMotion();
            if (motion == null) return;
            var optional = motion.opt_imo_data;
            if (optional == null || optional.curves == null || optional.curves.Length == 0) return;
            if (seeker == null || seeker.opt_curves == null || seeker.opt_curves.Length == 0) return;
            if (optional.curves.Length >= 1)
            {
                var position = seeker.opt_curves[0].position;
                var solved = CharacterImasMotionPlayer.SolveCurve(optional.curves[0], current_time, ref position);
                seeker.opt_curves[0].position = position;
                if (opt_results != null && opt_results.Length >= 1) opt_results[0] = solved;
            }
            if (optional.curves.Length >= 2 && seeker.opt_curves.Length >= 2)
            {
                var position = seeker.opt_curves[1].position;
                var solved = CharacterImasMotionPlayer.SolveCurve(optional.curves[1], current_time, ref position);
                seeker.opt_curves[1].position = position;
                if (opt_results != null && opt_results.Length >= 2) opt_results[1] = solved;
            }
        }

        /// <summary>
        /// Native 0x38AF7CC idle branch (old 0x37EE384): when status.is_play_idle
        /// is set, native takes CharacterCommonSkeleton.GetStatic() (0x38AA2B8)
        /// and, per binder index, copies the source node's angle (Vector3 at
        /// source +0x30) and position (Vector3 at source +0x24) into the result
        /// objects (result angle +0x10, position +0x1C) — exactly this loop.
        /// Port data gap: the common-skeleton table is a game resource the spike
        /// does not carry, so `idle_results` is the captured substitute; when it
        /// is null the last solved pose is kept.
        /// </summary>
        private void CopyIdleResults()
        {
            if (idle_results == null || results == null) return;
            var count = Math.Min(idle_results.Length, results.Length);
            for (var i = 0; i < count; i++)
            {
                var source = idle_results[i];
                if (source == null) continue;
                if (results[i] == null) results[i] = new Result();
                results[i].angle = source.angle;
                results[i].position = source.position;
            }
        }

        // --------------------------------------------------------------- results

        /// <summary>Port-only probe seam (native has no accessor): the binder at a result
        /// slot, i.e. the curve set and the transform it drives. Used by NativeMotionProbe.</summary>
        public CurveBinder GetBinder(int index)
        {
            var motion = GetCurrentMotion();
            if (motion == null || motion.curve_binders == null) return null;
            if (index < 0 || index >= motion.curve_binders.Length) return null;
            return motion.curve_binders[index];
        }

        /// <summary>Port-only probe seam: number of binder slots of the current motion.</summary>
        public int BinderCount
        {
            get
            {
                var motion = GetCurrentMotion();
                return motion != null && motion.curve_binders != null ? motion.curve_binders.Length : 0;
            }
        }

        /// <summary>Port-only probe seam: the result at a binder slot (no copy).</summary>
        public Result GetResult(int index)
        {
            if (results == null || index < 0 || index >= results.Length) return null;
            return results[index];
        }

        /// <summary>`GetResults` — 0x37ED7C4 (deep copy of the per-bone results).</summary>
        public Result[] GetResults()
        {
            if (results == null) return null;
            var copy = new Result[results.Length];
            for (var i = 0; i < results.Length; i++)
            {
                var source = results[i];
                copy[i] = source == null ? null : new Result { angle = source.angle, position = source.position };
            }
            return copy;
        }

        /// <summary>`SetResults` — 0x37ED96C.</summary>
        public void SetResults(Result[] src_results)
        {
            if (src_results == null || results == null) return;
            var count = Math.Min(src_results.Length, results.Length);
            for (var i = 0; i < count; i++)
            {
                var source = src_results[i];
                if (source == null) continue;
                if (results[i] == null) results[i] = new Result();
                results[i].angle = source.angle;
                results[i].position = source.position;
            }
        }

        /// <summary>`GetCurrentMotionImoData` — 0x37ED5CC.</summary>
        public CharacterImasMotionData GetCurrentMotionImoData()
        {
            var motion = GetCurrentMotion();
            return motion != null ? motion.imo_data : null;
        }

        /// <summary>`GetCurrentMotionOptionalImoData` — 0x37ED644.</summary>
        public CharaOptionalImoData GetCurrentMotionOptionalImoData()
        {
            var motion = GetCurrentMotion();
            return motion != null ? motion.opt_imo_data : null;
        }

        /// <summary>`SetCurrentMotionOptionalImoData` — 0x37ED6BC (hot-swaps accessory data).</summary>
        public void SetCurrentMotionOptionalImoData(CharaOptionalImoData opt_imo_data)
        {
            var motion = GetCurrentMotion();
            if (motion != null) motion.opt_imo_data = opt_imo_data;
        }

        /// <summary>`HasCurrentMotionOptionalImoData` — 0x37ED744.</summary>
        public bool HasCurrentMotionOptionalImoData()
        {
            var motion = GetCurrentMotion();
            return motion != null && motion.opt_imo_data != null;
        }

        // ------------------------------------------------------------- bookmarks

        /// <summary>`CreateBookMark` — 0x37ED310.</summary>
        public BookMark CreateBookMark()
        {
            var bookmark = new BookMark();
            if (seeker == null || seeker.nodes == null) return bookmark;
            bookmark.nodes = new Seeker.Node[seeker.nodes.Length];
            GetTimeToBookMark(bookmark);
            return bookmark;
        }

        /// <summary>`GetTimeToBookMark` — 0x37ED48C.</summary>
        public void GetTimeToBookMark(BookMark bookmark)
        {
            if (bookmark == null) return;
            bookmark.time = current_time;
            if (bookmark.nodes == null || seeker == null || seeker.nodes == null) return;
            var count = Math.Min(bookmark.nodes.Length, seeker.nodes.Length);
            for (var i = 0; i < count; i++) bookmark.nodes[i] = seeker.nodes[i];
        }

        /// <summary>`SetTimeFromBookMark` — 0x37ED52C. Writes `next_time` (not current_time),
        /// the same accumulator `SetTime` uses.</summary>
        public void SetTimeFromBookMark(BookMark bookmark)
        {
            if (bookmark == null) return;
            next_time = bookmark.time;
            if (bookmark.nodes == null || seeker == null || seeker.nodes == null) return;
            var count = Math.Min(bookmark.nodes.Length, seeker.nodes.Length);
            for (var i = 0; i < count; i++) seeker.nodes[i] = bookmark.nodes[i];
        }

        // --------------------------------------------------------------- seeker

        /// <summary>`set_seeker_to_start` — 0x37ECB60.</summary>
        protected void SetSeekerToStart()
        {
            if (seeker == null) return;
            if (seeker.nodes != null)
            {
                for (var i = 0; i < seeker.nodes.Length; i++) seeker.nodes[i] = default(Seeker.Node);
            }
            if (seeker.opt_curves != null)
            {
                for (var i = 0; i < seeker.opt_curves.Length; i++) seeker.opt_curves[i] = default(Seeker.Curve);
            }
        }

        /// <summary>`set_seeker_to_end` — 0x37EE0D8.</summary>
        protected void SetSeekerToEnd()
        {
            if (seeker == null) return;
            var motion = GetCurrentMotion();
            if (motion == null) return;
            if (motion.curve_binders != null && seeker.nodes != null)
            {
                var count = Math.Min(motion.curve_binders.Length, seeker.nodes.Length);
                for (var i = 0; i < count; i++)
                {
                    var binder = motion.curve_binders[i];
                    if (binder == null || binder.curve_set == null) continue;
                    var set = binder.curve_set;
                    var node = seeker.nodes[i];
                    if (set.px != null) node.px.position = CharacterImasMotionPlayer.GetLastSeekerPosition(set.px);
                    if (set.py != null) node.py.position = CharacterImasMotionPlayer.GetLastSeekerPosition(set.py);
                    if (set.pz != null) node.pz.position = CharacterImasMotionPlayer.GetLastSeekerPosition(set.pz);
                    if (set.rx != null) node.rx.position = CharacterImasMotionPlayer.GetLastSeekerPosition(set.rx);
                    if (set.ry != null) node.ry.position = CharacterImasMotionPlayer.GetLastSeekerPosition(set.ry);
                    if (set.rz != null) node.rz.position = CharacterImasMotionPlayer.GetLastSeekerPosition(set.rz);
                    seeker.nodes[i] = node;
                }
            }
            if (motion.opt_imo_data != null && motion.opt_imo_data.curves != null &&
                seeker.opt_curves != null)
            {
                var curves = motion.opt_imo_data.curves;
                var count = Math.Min(curves.Length, seeker.opt_curves.Length);
                for (var i = 0; i < count; i++)
                {
                    var curve = curves[i];
                    if (curve == null) continue;
                    var hint = seeker.opt_curves[i];
                    hint.position = CharacterImasMotionPlayer.GetLastSeekerPosition(curve);
                    seeker.opt_curves[i] = hint;
                }
            }
        }

        // -------------------------------------------------------------- capacity

        private void EnsureCapacity(int required)
        {
            if (seeker == null) return;
            // Native allocates 64 (0x37EDC60). Grow to the required size so a motion with
            // more paths does not lose tracks; every slot is one curve set / one result.
            if (results == null || results.Length < required)
            {
                var size = Math.Max(required, kCapacity);
                var old = results;
                results = new Result[size];
                for (var i = 0; i < size; i++)
                {
                    if (old != null && i < old.Length) results[i] = old[i];
                    if (results[i] == null) results[i] = new Result();
                }
            }
            if (seeker.nodes == null || seeker.nodes.Length < required)
            {
                var size = Math.Max(required, kCapacity);
                var old = seeker.nodes;
                seeker.nodes = new Seeker.Node[size];
                if (old != null) Array.Copy(old, seeker.nodes, old.Length);
            }
        }

        // ------------------------------------------------------------- step keys

        /// <summary>
        /// `PlayMotion` (0x37EC6EC) selects one of eight hard-coded step-key tables by imo
        /// asset *name* (string switch, ComputeStringHash 0x315B2CC + String.op_Equality).
        /// The tables live in the `.cctor` (0x37EEC98) as float arrays of frame numbers.
        /// Only these eight dances are affected; `dan_loveig_*` is not in the table.
        /// </summary>
        private static readonly Dictionary<string, float[]> s_step_keys = new Dictionary<string, float[]>(StringComparer.Ordinal)
        {
            { "dan_bbvolb_01_apa.imo", new[] { 500f } },              // s_step_keys_dan_bbvolb_01_apa
            { "dan_bbvolb_02_apa.imo", new[] { 340f, 500f } },        // s_step_keys_dan_bbvolb_02_apa
            { "dan_lastac_01_apa.imo", new[] { 300f } },              // s_step_keys_dan_lastac_01_apa
            { "dan_flyer+_01_dan.imo", new[] { 3880f } },             // s_step_keys_dan_flyer13_01_dan
            { "dan_flyer+_06_dan.imo", new[] { 3880f } },             // s_step_keys_dan_flyer13_06_dan
            { "dan_flyer+_07_dan.imo", new[] { 3880f } },             // s_step_keys_dan_flyer13_07_dan
            { "dan_mosqui_01_dan.imo", new[] { 599f, 6869f } },       // s_step_keys_dan_mosqui_01_dan
            { "dan_mosqui_02_dan.imo", new[] { 6869f } },             // s_step_keys_dan_mosqui_02_dan
        };

        private static float[] StepKeysFor(string imo_name)
        {
            if (string.IsNullOrEmpty(imo_name)) return null;
            return s_step_keys.TryGetValue(imo_name, out var keys) ? keys : null;
        }
    }
}
