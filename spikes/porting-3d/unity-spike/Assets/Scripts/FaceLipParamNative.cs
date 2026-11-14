using System;
using System.Globalization;
using System.IO;
using System.Text;

// ========================================================================
// FaceLipParamNative — native `Imas.FaceCtrl.lipParam` (`float[11,14]`, native
// field @0x10) 数值接线（lipParam data-gap 补齐；只新建文件，不改既有文件）。
//
// 来源（一手证据，非猜）：
// * dump.cs 行 341014/341802：`private float[,] lipParam; // 0x10`
//   （il2cpp_array_new_full dims = {11,14}，B3 已实测 16 字节 = 11,14）；
//   cctor @0x379FD10 里由 RuntimeHelpers.InitializeArray（@0x6538050，B3）
//   从编译器静态数组（RuntimeFieldHandle token 0x800000d1）填充。
// * dump.cs 行 1030049：唯一的 616B 静态数组
//   `<PrivateImplementationDetails>.__StaticArrayInitTypeSize=616`，
//   字段 hash 888BFFFA9D5BC23A…，metadata offset 0x115FE40。
// * 数据本体：global-metadata.dat（…/io.playcover.PlayCover/Applications/
//   jp.co.bandainamcoent.BNEI0310.app/Data/Managed/Metadata/
//   global-metadata.dat）offset 0x115FE40 连续 616 字节 = 154 个
//   little-endian float32 = 11 行 × 14 列。全部有限、范围 0..100（百分数）。
//   2026-11-07 复核：与上面常量逐字节（float32 bit 级）一致。
// * 语义：行 = lip kind（0..10；muteLip kind 1..11 → lipParam[kind-1]），
//   列 = 口型混合槽 BS0..13。行 0..5 主对角 unit（kinds 0..5），行 6/7
//   半开（50 / 38.5），行 8..10 弱化对角（50）。
// * 原生数值域（重要）：UpdateFace @0x379E94C 的 lip/muteLip 段把 lipParam
//   行值**原样**写进 SetBlendShapeWeight / 与 mouthCloseBuff lerp
//   （mouthCloseBuff ← param32close[0..13]，同域 0..100，见
//   out/facial_chara.json 例如 60.0 / 90.0）。decompile 全函数唯一一次
//   `* 0.01f` 在 EyeTracking scale 段（param32open/close[32] → 100/val，
//   ida-decomp/FaceCtrl__UpdateFace.c L422；out.txt:1497 同）。因此接线
//   用 [Table]（原始 0..100），不要拿 GetWeight 的 0..1 归一值驱动 BS。
//   本文件仍按要求提供 GetWeight = Table[kind,slot] * 0.01f（0..1 归一
//   访问器，给需要归一值的调用方），并在注释与 notes 里写明上述证据，
//   以免被误当成 BS 写入系数。
//
// 规则依据：ADR-0033（docs/adr/0033-native-faithful-3d-migration.md）—
// 只做性能层替换，公式/常量/默认值/分支一律不改；本文件只装数据与
// 数据加载，不改任何原生分支。
// ========================================================================

/// <summary>
/// 接线（给 Lead；B3 <c>FaceCtrlNative</c> 已留 <c>LoadLipParam(float[,])</c>）：
/// <code>
/// face.LoadLipParam(FaceLipParamNative.Table);   // 一行（等价签名：
///                                                // LoadLipParam(FaceLipParamNative.Table)）
/// // 0..1 归一值调用方：FaceLipParamNative.GetWeight(kind, slot)
/// </code>
/// </summary>
public static class FaceLipParamNative
{
    /// <summary>来源 ID（与 out/face_lip_param.json 的 source 一致）。</summary>
    public const string Source = "throws-9.4-idalib,<PrivateImplementationDetails>=616 @0x115FE40";

    public const int Kinds = 11; // GetLength(0)：lip kind（muteLip kind 1..11 → 行 kind-1）
    public const int Slots = 14; // GetLength(1)：口型混合槽 BS0..13
    public const int Cells = Kinds * Slots; // 154 floats = 616 bytes

    // 编译期常量表：与 metadata 0x115FE40 的 616B blob 的 float32 逐位一致。
    static readonly float[] DefaultRows =
    {
        100f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, // row0
        0f, 77f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f,  // row1
        0f, 0f, 100f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, // row2
        0f, 0f, 0f, 100f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, // row3
        0f, 0f, 0f, 0f, 100f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, // row4
        0f, 0f, 0f, 0f, 0f, 100f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, // row5
        50f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f,  // row6
        0f, 38.5f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, // row7
        0f, 0f, 50f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f,  // row8
        0f, 0f, 0f, 50f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f,  // row9
        0f, 0f, 0f, 0f, 50f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f,  // row10
    };

    // 单写者模式（本批次不用并发）：只做引用整体替换/延迟初始化。
    static float[,] table;

    /// <summary>TryLoadJson 失败原因（成功后置 null）。</summary>
    public static string LastError { get; private set; }

    /// <summary>原生 [11,14] 表（0..100 百分数）。给 LoadLipParam 用这个。</summary>
    public static float[,] Table
    {
        get
        {
            if (table == null) table = BuildDefault();
            return table;
        }
    }

    /// <summary>
    /// kind/slot → 0..1 归一值（Table × 0.01f；本批次要求的接口）。
    /// 注意：原生 UpdateFace @0x379E94C 写 BS 时**不**乘 0.01（证据见文件头），
    /// 需要与 native 相同的数值时用 <see cref="GetRawWeight"/>。
    /// </summary>
    public static float GetWeight(int kind, int slot)
    {
        return Table[kind, slot] * 0.01f;
    }

    /// <summary>原生直接值（UpdateFace @0x379E94C 写进 BS 0..13 的那个数）。</summary>
    public static float GetRawWeight(int kind, int slot)
    {
        return Table[kind, slot];
    }

    /// <summary>11 行 × 14 列矩阵文本（断行）。</summary>
    public static string Describe()
    {
        var sb = new StringBuilder();
        var t = Table;
        for (int k = 0; k < Kinds; k++)
        {
            sb.Append("row").Append(k).Append(": ");
            for (int j = 0; j < Slots; j++)
                sb.Append(t[k, j].ToString("0.###", CultureInfo.InvariantCulture)).Append(' ');
            sb.AppendLine();
        }
        return sb.ToString();
    }

    // ------------------------------------------------------------------
    // 可选外部覆盖：{"layout":[11,14],"rows":[[...]]}
    // ------------------------------------------------------------------

    /// <summary>
    /// 从 JSON 文件覆盖默认表；layout 必须正好 [11,14]、154 格全有限，
    /// 否则填 LastError 并保持默认表。
    /// </summary>
    public static bool TryLoadJson(string path)
    {
        LastError = null;
        try
        {
            if (string.IsNullOrEmpty(path)) { LastError = "empty path"; return false; }
            if (!File.Exists(path)) { LastError = "file not found: " + path; return false; }
            if (!TryLoadJsonText(File.ReadAllText(path), out var loaded, out var err))
            {
                LastError = err ?? "unknown parse failure";
                return false;
            }
            table = loaded;
            return true;
        }
        catch (Exception e)
        {
            LastError = e.GetType().Name + ": " + e.Message;
        }
        return false;
    }

    /// <summary>恢复内置默认表（与 metadata 逐位一致）。</summary>
    public static void Unload()
    {
        table = null;
        LastError = null;
    }

    static float[,] BuildDefault()
    {
        var t = new float[Kinds, Slots];
        for (int k = 0; k < Kinds; k++)
            for (int j = 0; j < Slots; j++)
                t[k, j] = DefaultRows[k * Slots + j];
        return t;
    }

    // ---- 极小手写 JSON 扫描器（不引第三方库，只认本文件写的形状） ----

    static bool TryLoadJsonText(string text, out float[,] table, out string error)
    {
        table = null;
        error = null;
        var s = new Scanner(text ?? "");
        s.SkipWs();
        if (!s.Consume('{')) { error = "expect '{'"; return false; }

        bool haveLayout = false, haveRows = false;
        int layoutRows = -1, layoutCols = -1;
        float[,] parsed = null;

        while (s.SkipWsAndNotAt('}'))
        {
            if (!s.ReadString(out var key) || key == null) { error = "expect key"; return false; }
            if (!s.SkipWsAndExpect(':')) { error = "expect ':' after " + key; return false; }
            s.SkipWs();

            if (key == "layout")
            {
                if (!s.ReadNumberArray(out var layout, out error)) return false;
                if (layout != null && layout.Length == 2)
                {
                    layoutRows = (int)layout[0];
                    layoutCols = (int)layout[1];
                    haveLayout = true;
                }
            }
            else if (key == "rows")
            {
                if (!s.SkipWsAndExpect('[')) { error = "expect '[' for rows"; return false; }
                if (!ReadRows(ref s, out parsed, out error)) return false;
                haveRows = true;
            }
            else if (!s.SkipValue()) { error = "bad value for " + key; return false; }

            s.SkipWs();
            if (s.Consume(',')) continue;
            break;
        }
        if (!s.SkipWsAndExpect('}')) { error = "expect '}'"; return false; }

        if (!haveRows) { error = "rows missing"; return false; }
        if (haveLayout && (layoutRows != Kinds || layoutCols != Slots))
        {
            error = "layout [" + layoutRows + "," + layoutCols + "] != [" + Kinds + "," + Slots + "]";
            return false;
        }

        for (int k = 0; k < Kinds; k++)
            for (int j = 0; j < Slots; j++)
                if (!IsFinite(parsed[k, j])) { error = "non-finite at [" + k + "," + j + "]"; return false; }

        table = parsed;
        return true;
    }

    /// <summary>读 rows 外层；Scanner 是 struct，必须 ref 才能保留推进位置。</summary>
    static bool ReadRows(ref Scanner s, out float[,] table, out string error)
    {
        table = null;
        var rows = new float[Kinds][];
        int rowCount = 0;
        s.SkipWs();
        if (s.Peek != ']')
        {
            while (true)
            {
                if (rowCount >= Kinds) { error = "rows exceeds " + Kinds; return false; }
                if (!s.SkipWsAndExpect('[')) { error = "expect '[' at row " + rowCount; return false; }
                var row = new float[Slots];
                int n = 0;
                s.SkipWs();
                if (s.Peek != ']')
                {
                    while (true)
                    {
                        if (n >= Slots) { error = "row " + rowCount + " exceeds " + Slots; return false; }
                        if (!s.ReadNumber(out row[n], out error)) return false;
                        n++;
                        s.SkipWs();
                        if (s.Consume(',')) { s.SkipWs(); continue; }
                        break;
                    }
                }
                if (!s.SkipWsAndExpect(']')) { error = "expect ']' at row " + rowCount; return false; }
                if (n != Slots) { error = "row " + rowCount + " has " + n; return false; }
                rows[rowCount++] = row;
                s.SkipWs();
                if (s.Consume(',')) { s.SkipWs(); continue; }
                break;
            }
        }
        if (!s.SkipWsAndExpect(']')) { error = "expect ']' for rows"; return false; }
        if (rowCount != Kinds) { error = "rows has " + rowCount; return false; }

        var t = new float[Kinds, Slots];
        for (int k = 0; k < Kinds; k++)
            for (int j = 0; j < Slots; j++)
                t[k, j] = rows[k][j];
        table = t;
        error = null;
        return true;
    }

    static bool IsFinite(float v)
    {
        return !float.IsNaN(v) && !float.IsInfinity(v);
    }

    struct Scanner
    {
        readonly string s;
        int i;

        public Scanner(string text) { s = text; i = 0; }

        public bool AtEnd { get { return i >= s.Length; } }
        public char Peek { get { return AtEnd ? '\0' : s[i]; } }

        public void SkipWs()
        {
            while (!AtEnd && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) i++;
        }

        public bool Consume(char c)
        {
            if (Peek != c) return false;
            i++;
            return true;
        }

        public bool SkipWsAndExpect(char c)
        {
            SkipWs();
            return Consume(c);
        }

        /// <summary>跳过空白后必须还有内容且不是 c（对象体循环里用）。</summary>
        public bool SkipWsAndNotAt(char c)
        {
            SkipWs();
            return !AtEnd && Peek != c;
        }

        public bool ReadString(out string value)
        {
            value = null;
            SkipWs();
            if (Peek != '"') return false;
            i++;
            var start = i;
            while (!AtEnd && s[i] != '"')
            {
                if (s[i] == '\\') i++; // 宽进：跳过下一字节
                i++;
            }
            if (AtEnd) return false;
            value = s.Substring(start, i - start);
            i++;
            return true;
        }

        /// <summary>读一个 JSON 数字：支持 77、38.5、-0.5、1e2、0.5E-1。</summary>
        public bool ReadNumber(out float value, out string error)
        {
            value = 0f;
            error = null;
            SkipWs();
            var start = i;
            if (Peek == '-' || Peek == '+') i++;
            bool digits = false;
            while (!AtEnd && s[i] >= '0' && s[i] <= '9') { i++; digits = true; }
            if (!AtEnd && s[i] == '.')
            {
                i++;
                while (!AtEnd && s[i] >= '0' && s[i] <= '9') { i++; digits = true; }
            }
            if (!AtEnd && (s[i] == 'e' || s[i] == 'E'))
            {
                i++;
                if (!AtEnd && (s[i] == '-' || s[i] == '+')) i++;
                while (!AtEnd && s[i] >= '0' && s[i] <= '9') i++;
            }
            if (!digits || i == start) { error = "bad number"; return false; }
            var token = s.Substring(start, i - start);
            if (!float.TryParse(token, NumberStyles.Float, CultureInfo.InvariantCulture, out value))
            {
                error = "bad number: " + token;
                return false;
            }
            if (float.IsNaN(value) || float.IsInfinity(value)) { error = "non-finite: " + token; return false; }
            return true;
        }

        public bool ReadNumberArray(out float[] values, out string error)
        {
            values = null;
            error = null;
            SkipWs();
            if (Peek != '[') { error = "expect '['"; return false; }
            i++;
            SkipWs();
            var list = new float[8];
            int n = 0;
            if (Peek != ']')
            {
                while (true)
                {
                    if (!ReadNumber(out var v, out error)) return false;
                    if (n >= list.Length) Array.Resize(ref list, n * 2);
                    list[n++] = v;
                    SkipWs();
                    if (Consume(',')) { SkipWs(); continue; }
                    break;
                }
            }
            if (!Consume(']')) { error = "expect ']'"; return false; }
            values = new float[n];
            Array.Copy(list, values, n);
            return true;
        }

        /// <summary>跳过任意未知值（string/number/true/false/null/对象/数组）。</summary>
        public bool SkipValue()
        {
            SkipWs();
            if (AtEnd) return false;
            if (Peek == '"') { return ReadString(out _); }
            if (Peek == '[' || Peek == '{') return SkipBalanced();
            if (TrySkipWord("true") || TrySkipWord("false") || TrySkipWord("null")) return true;
            return ReadNumber(out _, out _);
        }

        bool SkipBalanced()
        {
            i++; // 已确认是 '[' 或 '{'
            int depth = 1;
            while (!AtEnd)
            {
                if (Peek == '"')
                {
                    i++;
                    while (!AtEnd && s[i] != '"')
                    {
                        if (s[i] == '\\') i++;
                        i++;
                    }
                    if (AtEnd) return false;
                    i++;
                    continue;
                }
                if (Peek == '[' || Peek == '{') depth++;
                else if (Peek == ']' || Peek == '}')
                {
                    depth--;
                    if (depth == 0) { i++; return true; }
                }
                i++;
            }
            return false;
        }

        bool TrySkipWord(string word)
        {
            if (Peek != word[0]) return false;
            if (s.Length - i < word.Length) return false;
            for (int j = 0; j < word.Length; j++)
                if (s[i + j] != word[j]) return false;
            i += word.Length;
            return true;
        }
    }
}
