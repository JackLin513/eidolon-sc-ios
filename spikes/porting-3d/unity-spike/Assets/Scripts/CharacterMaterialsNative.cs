// =========================================================================
// CharacterMaterials (dump.cs TypeDefIndex 15017) — decompilation-faithful
// port of the current shipped binary (/tmp/unk2-decomp, old → new RVAs below).
// =========================================================================
//
// Evidence (read-only; every file is CharacterMaterials__old_<oldRVA>__new_<newRVA>.c
// and the body inside is the <newRVA> function):
//   0x1C1CECC -> 0x1C77B44   create_sync
//   0x1C1D874 -> 0x1C784EC   ApplyOutlineColor
//   0x1C1D9D0 -> 0x1C78648   apply_stencil
//   0x1C1DAC0 -> 0x1C78738   SetIdolColor
//   0x1C1DB00 -> 0x1C78778   SetMonoColorRatio
//   0x1C1DB10 -> 0x1C78788   SetRimLight
//   0x1C1DB28 -> 0x1C787A0   SetRimLightDirection
//   0x1C1DC8C -> 0x1C78904   SetLightDirection
//   0x1C1DE04 -> 0x1C78A7C   SetSpotlightColor
//   0x1C1E8C0 -> 0x1C79538   SetInherentColor
//   0x1C1F62C -> 0x1C7A2A4   SetEyeHighlightColorToMaterial (static)
//   0x1C1FF70 -> 0x1C7ABE8   initStatic (property-id cctor)
// Other current RVAs cited in comments come from dump.cs 15017.
//
// Decision context: docs/adr/0033-native-faithful-3d-migration.md.
// Rules honoured in this file:
//   * A method writes the real material only where the decompiled body shows
//     the material call: ApplyOutlineColor, apply_stencil, both direction
//     setters, SetEyeHighlightColorToMaterial, SetCheekReddenToMaterial. Every
//     other Set* entry only fills the native state record, exactly like the
//     binary; the deferred half belongs to apply_color 0x1C7BDD0 /
//     UpdateProperties 0x1C7DD04 (bodies outside this batch).
//   * A remaining unresolved semantic is written as `UNKNOWN(native 0x<newRVA>)`
//     and listed in CharacterMaterialsNative.NativeUnknowns.
//   * Fields carry the native IL2CPP byte offset in comments; the native layout
//     is, byte for byte (PassiveProperty<T> = changed byte, value 4 bytes later):
//     +0x4C(76) changed | +0x4D(77) enable | +0x50(80)..+0x5C(92) Color   IdolColor
//     +0x60(96) changed | +0x64(100)..+0x70(112) Color                   MonoColor
//     +0x74(116) changed | +0x78(120) ratio                              MonoColorRatio
//     +0x7C(124) changed | +0x7D(125) enable | +0x80(128)..+0x8C(140) C. RimLight
//     +0x90(144) changed | +0x94(148) Color | +0xA4(164) intensity      CheekRedden
//     +0xA8(168) changed | +0xA9(169) value                              CheekReddenEnable
//     +0xAC(172) PassiveProperty<BlendColor>  (value 176: int + Color)
//     +0xC4(196) PassiveProperty<Color>       (value 200..212, pin + alpha)
//     +0xE0(224) Color[4] inherent_colors   | +0x130(304) List<MatCol>
//     +0x144(324) PassiveProperty<float> outline_width (value 328)
//     +0x14C(332) PassiveProperty<Color> outline_color (value 336)
//     +0x160(352) PassiveProperty<int>   stencil_ref   (value 356)
//
// Shader property names are ground truth from the shipped bundles + the
// resolved initStatic 0x1C7ABE8 table (same material inventory as
// CharacterDrawerNative's header):
//   Custom/Chr_Basic        : _Outline _OutlineColor _OutlineZadj _TanFov _Stencil
//                             _RimLightOn _RimLight _RimColor _ZShift1000Min/Max
//   Custom/Chr_Face         : _Outline _OutlineColor _Stencil _IsReddish _ReddishColor
//                             _ReddishIntensity _RimLightOn _RimLight _RimColor
//                             _Colors _Color _TintColor _SubColor0..3 _Whiteness
//   Custom/BultIn/Bi_CharEye: _IrisColor _SubTex _Stencil
//   global                  : _MonoColor (set/kept by CharacterBootstrap.ApplyGlobals)

using System;
using System.Collections.Generic;
using System.Text;
using UnityEngine;

/// <summary>
/// Native-faithful <c>CharacterMaterials</c> (dump.cs 15017). Plain class — the
/// native component is attached to the character top object by Create
/// 0x1C77B40 -> create_sync 0x1C77B44, but this spike keeps it as a plain
/// object exactly like the performance-layer substitution already used in the
/// drawer.
/// </summary>
public sealed class CharacterMaterialsNative
{
    // ---------------------------------------------------------------------
    // Shader property ids — faithful initStatic 0x1C7ABE8 (the static cctor).
    // Native field offsets are in the comments. Every literal is confirmed
    // from the shipped IL2CPP metadata-usage string slots (script.json
    // ScriptString), so this is the native `id_*` static table, not a guess.
    // ---------------------------------------------------------------------
    public static readonly int id_Yoffsets = Shader.PropertyToID("_Yoffsets");                         // +0x00
    public static readonly int id_Colors = Shader.PropertyToID("_Colors");                             // +0x04
    public static readonly int id_BlendSrc = Shader.PropertyToID("_BlendSrc");                         // +0x08
    public static readonly int id_StencilRef = Shader.PropertyToID("_Stencil");                        // +0x0C (field name in dump.cs: id_StencilRef)
    public static readonly int id_IllumiColor = Shader.PropertyToID("_IllumiColor");                   // +0x10
    public static readonly int id_GlowColor = Shader.PropertyToID("_GlowColor");                       // +0x14
    public static readonly int id_Color = Shader.PropertyToID("_Color");                               // +0x18
    public static readonly int id_TintColor = Shader.PropertyToID("_TintColor");                       // +0x1C
    public static readonly int id_Irogae = Shader.PropertyToID("_Irogae");                             // +0x20
    public static readonly int id_Light = Shader.PropertyToID("_Light");                               // +0x24
    public static readonly int id_RimLight = Shader.PropertyToID("_RimLight");                         // +0x28
    public static readonly int id_RimLightOn = Shader.PropertyToID("_RimLightOn");                     // +0x2C
    public static readonly int id_RimColor = Shader.PropertyToID("_RimColor");                         // +0x30
    /// <summary>+0x38: int[ChrColorNum] built with String.Format("_SubColor{0}", i) — same as native.</summary>
    public static readonly int[] id_ChrColors = BuildChrColorIds();
    public static readonly int id_IrisColor = Shader.PropertyToID("_IrisColor");                       // +0x40
    public static readonly int id_IsReddish = Shader.PropertyToID("_IsReddish");                       // +0x44
    public static readonly int id_ReddishColor = Shader.PropertyToID("_ReddishColor");                 // +0x48
    public static readonly int id_ReddishIntensity = Shader.PropertyToID("_ReddishIntensity");         // +0x4C
    public static readonly int id_DiffuseColor = Shader.PropertyToID("_DiffuseColor");                 // +0x50
    public static readonly int id_MonoColor = Shader.PropertyToID("_MonoColor");                       // +0x54
    public static readonly int id_Whiteness = Shader.PropertyToID("_Whiteness");                       // +0x58
    public static readonly int id_UseReflect = Shader.PropertyToID("_UseReflect");                     // +0x5C
    public static readonly int id_Reflection = Shader.PropertyToID("_Reflection");                     // +0x60
    public static readonly int id_Outline = Shader.PropertyToID("_Outline");                           // +0x64
    public static readonly int id_OutlineZadj = Shader.PropertyToID("_OutlineZadj");                   // +0x68
    public static readonly int id_TanFov = Shader.PropertyToID("_TanFov");                             // +0x6C
    public static readonly int id_ZShift1000Min = Shader.PropertyToID("_ZShift1000Min");               // +0x70
    public static readonly int id_ZShift1000Max = Shader.PropertyToID("_ZShift1000Max");               // +0x74
    public static readonly int id_ZShift1000MinArray = Shader.PropertyToID("_ZShift1000MinArray");     // +0x78
    public static readonly int id_ZShift1000MaxArray = Shader.PropertyToID("_ZShift1000MaxArray");     // +0x7C
    public static readonly int id_OutlineColor = Shader.PropertyToID("_OutlineColor");                 // +0x80
    public static readonly int id_Luminance = Shader.PropertyToID("_Luminance");                       // +0x84
    public static readonly int id_ColorBlendRate = Shader.PropertyToID("_ColorBlendRate");             // +0x88
    public static readonly int id_WhiteMode = Shader.PropertyToID("_WhiteMode");                       // +0x8C
    public static readonly int id_Whitish = Shader.PropertyToID("_Whitish");                           // +0x90
    public static readonly int id_Freq = Shader.PropertyToID("_Freq");                                 // +0x94
    public static readonly int id_ForceNoSkin = Shader.PropertyToID("_ForceNoSkin");                   // +0x98

    private static int[] BuildChrColorIds()
    {
        var ids = new int[ChrColorNum];
        for (var i = 0; i < ids.Length; i++)
            ids[i] = Shader.PropertyToID(string.Format("_SubColor{0}", i));
        return ids;
    }

    /// <summary>
    /// Face toggle keyword used by SetCheekReddenToMaterial 0x1C78C6C (body not
    /// in this batch; the keyword value is the one confirmed in the B3 pass from
    /// FaceCtrl.SetCheekValue 0x379F840, which calls the same
    /// CustomShaderUtility.SetMaterialToggle helper).
    /// </summary>
    public const string ReddishKeyword = "_ISREDDISH_ON";

    /// <summary>CharacterMaterials global property: `_MonoColor` (bundle-verified global
    /// already written by CharacterBootstrap.ApplyGlobals as SetGlobalVector).</summary>
    public const string MonoColorGlobalShader = "_MonoColor";

    /// <summary>CharacterMaterials constants kept from the drawer port.</summary>
    public const int ChrColorNum = 4;
    public const int ChrColorMainIndex = 0;

    // ---------------------------------------------------------------------
    // Native state-cache structs (offsets are IL2CPP byte offsets inside
    // CharacterMaterials, confirmed against the decompiled Set* bodies).
    // ---------------------------------------------------------------------

    /// <summary>
    /// Native IdolColor record: +0x4C(76) is_changed, +0x4D(77) is_enable,
    /// +0x50(80)..+0x5C(92) color. Drawer__GetIdolColor 0x1C102BC returns
    /// exactly these 20 bytes, so the layout is confirmed end to end.
    /// </summary>
    [Serializable]
    public struct IdolColor
    {
        public bool is_changed;   // +76
        public bool is_enable;    // +77
        public Color color;       // +80..92
    }

    /// <summary>Native MonoColor record: +0x60(96) changed, +0x64(100)..+0x70(112) color.</summary>
    [Serializable]
    public struct MonoColor
    {
        public bool is_changed;   // +96
        public Color color;       // +100..112
    }

    /// <summary>Native MonoColorRatio record: +0x74(116) changed, +0x78(120) ratio.</summary>
    [Serializable]
    public struct MonoColorRatio
    {
        public bool is_changed;   // +116
        public float ratio;       // +120
    }

    /// <summary>Native RimLight record: +0x7C(124) changed, +0x7D(125) enable, +0x80..+0x8C color.</summary>
    [Serializable]
    public struct RimLight
    {
        public bool is_changed;   // +124
        public bool is_enable;    // +125
        public Color color;       // +128..140
    }

    /// <summary>Native CheekRedden record: +0x90(144) is_changed, +0xA4(164) intensity.</summary>
    [Serializable]
    public struct CheekRedden
    {
        public bool is_changed;   // +144
        public float intensity;   // +164
    }

    /// <summary>Native CheekReddenEnable record: +0xA8(168) is_changed, +0xA9(169) value.</summary>
    [Serializable]
    public struct CheekReddenEnable
    {
        public bool is_changed;   // +168
        public bool value;        // +169
    }

    /// <summary>
    /// Native PassiveProperty&lt;BlendColor&gt; value record: the property lives at
    /// +0xAC(172) (changed byte there) and its value is these 5 dwords at
    /// +0xB0(176). SetSpotlightColor 0x1C78A7C writes it via sub_4DCD004.
    /// </summary>
    [Serializable]
    public struct BlendColor
    {
        public int blend;         // +176 (0xB0)
        public Color color;       // +180..192 (0xB4..0xC0)
    }

    // ---------------------------------------------------------------------
    // Group/material cache
    // ---------------------------------------------------------------------

    public enum CharaMaterialGroup { Body, Head, Face }

    /// <summary>
    /// One registered material (`MatCol` at native +0x130(304), trimmed). The
    /// decompiled SetLightDirection 0x1C78904 / SetRimLightDirection 0x1C787A0 /
    /// ApplyOutlineColor 0x1C784EC / apply_stencil 0x1C78648 all walk this list
    /// and take `entry[2]` (offset 16 in MatCol) as the Material reference.
    /// </summary>
    private sealed class MatCol
    {
        public Material material;
        public Material mirrorMaterial;
        public float outlineWidthFactor = 1f;
        public bool isSkin;
        public bool isEye;
        public CharaMaterialGroup group;
    }

    private readonly List<MatCol> matcols = new List<MatCol>();  // native +0x130(304)

    // ---------------------------------------------------------------------
    // Identity (native Create 0x1C77B40 -> create_sync 0x1C77B44)
    // ---------------------------------------------------------------------
    public int chara_index;                        // +0x48(72)
    public string chara_id;                        // +0x40(64)
    public GameObject top_go;                      // +0x28(40)
    public GameObject head_model_go;               // +0x30(48)
    public GameObject body_model_go;               // +0x38(56)

    // ---------------------------------------------------------------------
    // State caches — native offsets in the comments are authoritative.
    // ---------------------------------------------------------------------
    public IdolColor idol_color;                   // +0x4C(76)
    public MonoColor mono_color;                   // +0x60(96)
    public MonoColorRatio mono_color_ratio;        // +0x74(116)
    public RimLight rim_light;                     // +0x7C(124)
    public CheekRedden cheek_redden;                // +0x90(144)/+0xA4(164)
    public CheekReddenEnable cheek_redden_enable;  // +0xA8(168)/+0xA9(169)

    // PassiveProperty<float> outline_width at +0x144(324): changed byte at 324,
    // value at +0x148(328). Set by SetOutlineWidth 0x1C783BC; the apply pass is
    // ApplyOutline 0x1C7CC14 (body outside this batch) -> TryApplyAll().
    private float outline_width = 0.0008f;         // default: Drawer.GetOutlineWidth 0x1C6AC9C fallback literal
    private bool outline_width_dirty;               // spike-managed (native changed byte at +0x144)

    // PassiveProperty<Color> outline_color at +0x14C(332): changed byte at 332,
    // value at +0x150(336..348). SetOutlineColor 0x1C78460 then tail-calls
    // ApplyOutlineColor 0x1C784EC (decompiled, applied below).
    private Color outline_color = Color.black;
    private bool outline_color_dirty;

    // PassiveProperty<int> stencil_ref at +0x160(352): changed byte at 352, value
    // at +0x164(356). SetStencilRef 0x1C785E4 then tail-calls apply_stencil
    // 0x1C78648 (decompiled, applied below).
    private int stencil_ref;

    // spotlight_color: PassiveProperty<BlendColor> at +0xAC(172) — changed byte
    // at +0xAC, value at +0xB0(176: blend int + Color). SetSpotlightColor
    // 0x1C78A7C marks it changed and writes the record via sub_4DCD004.
    public BlendColor spotlight_color;

    // pinspotlight_color: PassiveProperty<Color> at +0xC4(196) — changed byte at
    // +0xC4, Color at +0xC8(200..212) = (pin.r, pin.g, pin.b, pin_alpha). The
    // same method marks it changed and writes via sub_4DCD18C; Hex-Rays split the
    // 5th float argument into a double + float, so pin.a is unused (the alpha
    // ARGUMENT fills the 4th component instead).
    public Color pin_spotlight_color;
    public float pin_spotlight_alpha;
    private bool pin_spotlight_changed;            // +0xC4(196) changed byte

    // CheekRedden record +0x90(144): changed byte at 144, colour at +0x94(148),
    // intensity at +0xA4(164). create_sync 0x1C77B44 seeds the colour from a
    // 4-float rodata literal and copies soul.cheekReddenColor (+0x34); no
    // decompiled Materials Set* writes the face material's _ReddishColor, that
    // happens in apply_color 0x1C7BDD0 / the FaceCtrl chain (SetCheekReddenToMaterial).
    public Color cheek_redden_color;
    private bool cheek_redden_color_changed;

    // soul.skinColor: create_sync 0x1C77B44 copies it into lastSkinCol (+0x10C)
    // and then calls calcSkinBias 0x1C7B58C to fill skinBias (+0x11C). The spike
    // keeps the raw soul colour; the calcSkinBias body is outside this batch.
    public Color default_last_skin;                // +0xFC(252)
    public Color last_skin_col;                    // +0x10C(268)
    public Color skin_bias;                        // +0x11C(284)
    public Color glasses_color;                    // +0xE8(232)
    public float glasses_reflection;               // +0xF8(248)
    public Color skin_color;
    private bool skin_color_changed;

    // inherent_colors at +0xE0(224): Color[ChrColorNum]. SetInherentColor
    // 0x1C79538 writes the element then fans out through
    // SetInherentColorToMaterial 0x1C796B0 (body outside this batch; property
    // inferred as _SubColor{index} from the resolved cctor table).
    public Color[] inherent_colors = new Color[ChrColorNum];
    private bool inherent_color_changed;

    // SetRimLightDirection 0x1C787A0 / SetLightDirection 0x1C78904 write
    // _RimLight (cctor +0x28) / _Light (cctor +0x24) into every registered
    // material DIRECTLY. Neither body stores the vector on `this`; the two fields
    // below are port-only bookkeeping for Describe().
    public Vector3 rim_light_direction;
    public Vector3 light_direction;

    // ---------------------------------------------------------------------
    // Base-value capture (CaptureBaseValues/ResetBaseValues)
    // ---------------------------------------------------------------------
    private struct CapturedValue
    {
        public bool isColor;
        public Color color;
        public float number;
    }

    private readonly Dictionary<Material, Dictionary<int, CapturedValue>> baseValues =
        new Dictionary<Material, Dictionary<int, CapturedValue>>();
    private readonly Dictionary<Material, bool> baseReddishKeyword = new Dictionary<Material, bool>();
    private Color baseGlobalMonoColor;
    private bool baseValuesCaptured;

    // =====================================================================
    // Construction — renderer/material based, with the grouping the native
    // register_renderers 0x1C14F54 is_head flag maps to in the spike.
    // =====================================================================
    public CharacterMaterialsNative() { }

    /// <summary>
    /// Renderer-driven constructor (CharacterDrawerNative.Create equivalent). The
    /// native Create 0x1C77B40 -> create_sync 0x1C77B44(chara_index, top_go,
    /// chara_id, soul, head_go, body_go) receives the two GameObjects and thus a
    /// real head/body split; this ctor takes the renderers and derives head/body
    /// from the transform ancestors, then face/eye from the material properties.
    /// </summary>
    public CharacterMaterialsNative(IEnumerable<SkinnedMeshRenderer> renderers)
    {
        if (renderers == null) return;
        foreach (var rend in renderers)
        {
            if (rend == null) continue;
            var isHead = IsHeadRenderer(rend);
            var mats = rend.sharedMaterials;
            if (mats == null) continue;
            foreach (var mat in mats)
            {
                if (mat == null) continue;
                RegisterMaterialInternal(mat, null, false, 1f, hintHead: isHead);
            }
        }
    }

    /// <summary>Material-only constructor: classification falls to property/shader rules below.</summary>
    public CharacterMaterialsNative(IEnumerable<Material> materials)
    {
        if (materials == null) return;
        foreach (var mat in materials)
        {
            if (mat == null) continue;
            RegisterMaterialInternal(mat, null, false, 1f, hintHead: false);
        }
    }

    /// <summary>
    /// CharacterMaterials.Create 0x1C77B40 -> create_sync 0x1C77B44 (decompiled).
    /// Seeds the identity fields and the whole state cache to the native
    /// create-time values, then runs the native create_sub 0x1C7B6BC loop over
    /// the head_go and body_go hierarchies. In the spike both hierarchies hang
    /// under topGo, so the two native GetComponentsInChildren loops
    /// (sub_4422A84) collapse into one walk over topGo.
    /// </summary>
    public void Create(int charaIndex, GameObject topGo, string charaId)
    {
        Create(charaIndex, topGo, charaId, null);
    }

    /// <summary>
    /// create_sync 0x1C77B44 with the native CharacterSoul argument. Order of
    /// writes follows the decompiled body exactly:
    ///   identity → state seeds → soul copies (skinColor / inherentColor /
    ///   cheekReddenColor) → create_sub loop over head/body renderers.
    /// The native tail apply_on_awake 0x1C7BA50 / apply_color(true) 0x1C7BDD0 /
    /// ApplyOutline 0x1C7CC14 are outside this batch; TryApplyAll() is the
    /// spike's delivery site.
    /// </summary>
    public void Create(int charaIndex, GameObject topGo, string charaId, Imas.CharacterSoul soul)
    {
        chara_index = charaIndex;              // +0x48(72)
        top_go = topGo;                        // +0x28(40)
        chara_id = charaId;                    // +0x40(64)
        head_model_go = null;                  // +0x30(48) native head_go argument (folded into topGo)
        body_model_go = null;                  // +0x38(56) native body_go argument

        // ---- state seeds, in decompile order ------------------------------
        last_skin_col = default_last_skin;     // +0x10C <- +0xFC (OWORD copy)
        // UNKNOWN(native 0x1C77B44): sub_7124750(0) is a static Color getter —
        // white vs clear is not decidable statically; white is the neutral bias.
        skin_bias = Color.white;               // +0x11C(284..296)
        // UNKNOWN(native 0x1C77B44): the glasses_color preset is the 4-float
        // rodata literal xmmword_83FD830 (no StringLiteral slot) — left default.
        glasses_color = default;               // +0xE8(232)
        glasses_reflection = -1f;              // +0xF8(248) = 0xBF800000

        for (var i = 0; i < inherent_colors.Length; i++)
            inherent_colors[i] = Color.white;  // +0xE0 elements = (1,1,1,1)

        rim_light.is_changed = false;          // +124
        rim_light.is_enable = true;            // +125
        // UNKNOWN(native 0x1C77B44): sub_7124764(0) Color getter — white reading.
        rim_light.color = Color.white;         // +128..140

        idol_color.is_changed = false;         // +76
        idol_color.is_enable = false;          // +77
        idol_color.color = Color.white;        // +80..92 (same getter as above)

        mono_color.is_changed = false;         // +96
        mono_color.color = Color.white;        // +100..112

        cheek_redden.is_changed = false;       // +144
        // UNKNOWN(native 0x1C77B44): the CheekRedden colour preset is the 4-float
        // rodata literal xmmword_84BEF10 — left default; the value the face
        // material is driven with arrives from soul.cheekReddenColor below.
        cheek_redden_color = default;          // +148
        cheek_redden.intensity = 0f;           // +164
        cheek_redden_enable.is_changed = false;// +168
        cheek_redden_enable.value = false;     // +169

        if (soul != null)
        {
            if (soul.skinColor.isValid)
                last_skin_col = soul.skinColor.value;                // soul+0x4C/+0x50
            // UNKNOWN(native 0x1C7B58C): calcSkinBias body is outside this batch;
            // skin_bias keeps the neutral seed above.
            if (soul.inherentColor.isValid)
                inherent_colors[ChrColorMainIndex] = soul.inherentColor.value; // soul+0x60/+0x64
            if (soul.cheekReddenColor.isValid)
                cheek_redden_color = soul.cheekReddenColor.value;    // soul+0x30/+0x34
        }

        // ---- create_sub 0x1C7B6BC over the head + body hierarchies ----------
        if (topGo != null)
        {
            foreach (var rend in topGo.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                if (rend == null) continue;
                var mats = rend.sharedMaterials;
                if (mats == null) continue;
                var isHead = IsHeadRenderer(rend);
                foreach (var mat in mats)
                    RegisterMaterialInternal(mat, null, false, 1f, hintHead: isHead);
            }
        }
    }

    // ---------------------------------------------------------------------
    // Registration + classification
    // ---------------------------------------------------------------------

    /// <summary>Parity with the drawer port (used by CharacterDrawerNative.Create).</summary>
    public void RegisterMaterial(Material mat, Material mirrorMat, bool force_skin, float outlineWidthFactor)
    {
        RegisterMaterialInternal(mat, mirrorMat, force_skin, outlineWidthFactor, hintHead: false);
    }

    public int RegisteredCount => matcols.Count;

    private void RegisterMaterialInternal(Material mat, Material mirrorMat, bool force_skin,
        float outlineWidthFactor, bool hintHead)
    {
        if (mat == null) return;
        for (var i = 0; i < matcols.Count; i++)
            if (matcols[i].material == mat) return;
        matcols.Add(new MatCol
        {
            material = mat,
            mirrorMaterial = mirrorMat,
            isSkin = force_skin,
            outlineWidthFactor = outlineWidthFactor <= 0f ? 1f : outlineWidthFactor,
            isEye = IsEyeMaterial(mat),
            group = ClassifyGroup(mat, hintHead),
        });
    }

    public IReadOnlyList<Material> GetMaterials(CharaMaterialGroup group)
    {
        var list = new List<Material>();
        foreach (var c in matcols)
            if (c.group == group) list.Add(c.material);
        return list;
    }

    /// <summary>
    /// Classification rules (order fixed; first property hit wins):
    ///   1. HasProperty(_IsReddish)                 -> Face  (bundle: _IsReddish is
    ///      only on Custom/Chr_Face; this is the ONLY shader-independent face signal).
    ///   2. HasProperty(_IrisColor) && HasProperty(_SubTex) -> Head + isEye
    ///      (bundle: only Custom/BultIn/Bi_CharEye).
    ///   3. renderer hint (native register_renderers 0x1C14F54 is_head) -> Head/Body.
    ///      The spike derives is_head from a "ch_head" transform ancestor — the same
    ///      inference CharacterDrawerNative.IsHeadRenderer already uses (INFERENCE,
    ///      idle: the native flag comes from the load descriptor, not from the scene).
    ///   4. shader.name starts with "Custom/Chr_Face" -> Face (bundle inventory).
    ///   5. otherwise Body (default; shader name outside the three known families is
    ///      UNKNOWN as to side, so it deliberately maps to the broadest group).
    /// </summary>
    public static CharaMaterialGroup ClassifyGroup(Material mat, bool hintHead)
    {
        if (mat == null) return CharaMaterialGroup.Body;
        if (mat.HasProperty(id_IsReddish)) return CharaMaterialGroup.Face;
        if (IsEyeMaterial(mat)) return CharaMaterialGroup.Head;
        if (hintHead) return CharaMaterialGroup.Head;
        if (mat.shader != null && mat.shader.name.StartsWith("Custom/Chr_Face", StringComparison.Ordinal))
            return CharaMaterialGroup.Face;
        return CharaMaterialGroup.Body;
    }

    public static bool IsEyeMaterial(Material mat)
    {
        return mat != null && mat.HasProperty(id_IrisColor) && mat.HasProperty(id_SubTex);
    }

    private static readonly int id_SubTex = Shader.PropertyToID("_SubTex");

    private static bool IsHeadRenderer(SkinnedMeshRenderer rend)
    {
        for (var t = rend.transform; t != null; t = t.parent)
            if (t.name == "ch_head") return true;
        return false;
    }

    // =====================================================================
    // Outline width (PassiveProperty<float> +0x144/324) — NO eager material
    // write here: SetOutlineWidth 0x1C783BC only sets the PassiveProperty
    // (changed byte +0x144, value +0x148/328); the apply pass is
    // ApplyOutline 0x1C7CC14 (body outside this batch) and is delivered by
    // TryApplyAll().
    // =====================================================================

    /// <summary>CharacterMaterials.SetOutlineWidth 0x1C783BC: PassiveProperty set
    /// on this+0x148(328).</summary>
    public void SetOutlineWidth(float width)
    {
        outline_width = width;                 // +0x148(328)
        outline_width_dirty = true;            // +0x144(324) changed byte
    }

    /// <summary>
    /// CharacterMaterials.GetOutlineWidth 0x1C78420 — body outside this batch;
    /// the 0.0008f default below is the literal CharacterDrawer.GetOutlineWidth
    /// 0x1C6AC9C returns when its material target is missing, kept as the neutral
    /// value (CONFIRMED as a literal, 推断 as this struct-field default).
    /// </summary>
    public float GetOutlineWidth() => outline_width;

    /// <summary>
    /// SPIKE-MAPPING (not native): the outline pass is a shader pass inside the
    /// same material, so drawer.SetDrawOutline delivers the flag as _Outline = 0.
    /// Kept for drop-in parity with the drawer's current call.
    /// </summary>
    public void ApplyOutlineEnabled(bool enabled)
    {
        outline_disabled = !enabled;
        outline_width_dirty = true;
    }

    private bool outline_disabled;

    // =====================================================================
    // Outline color (PassiveProperty<Color> +0x14C/332) — decompiled tail-apply
    // =====================================================================

    /// <summary>
    /// CharacterMaterials.SetOutlineColor 0x1C78460: PassiveProperty set on
    /// outline_color (changed byte +0x14C/332, value +0x150/336..348), then tail
    /// call ApplyOutlineColor 0x1C784EC (decompiled, applied below).
    /// </summary>
    public void SetOutlineColor(Color color)
    {
        outline_color = color;                 // +0x150(336)
        outline_color_dirty = true;            // +0x14C(332) changed byte
        PushOutlineColor();
    }

    /// <summary>
    /// ApplyOutlineColor 0x1C784EC (decompiled): FORWARD walk of the MatCol list
    /// (+0x130/304) via List.get_Item, and
    /// `Material.SetVector(mat, statics+0x80 = _OutlineColor, this+336..348)` on
    /// every entry's material (MatCol+0x10). No HasProperty guard and no mirror
    /// material in the body.
    /// </summary>
    private void PushOutlineColor()
    {
        for (var i = 0; i < matcols.Count; i++)
        {
            var mat = matcols[i].material;
            if (mat == null) continue;
            mat.SetColor(id_OutlineColor, outline_color);
        }
    }

    // =====================================================================
    // Stencil ref (PassiveProperty<int> +0x160/352) — decompiled tail-apply
    // =====================================================================

    /// <summary>
    /// CharacterMaterials.SetStencilRef 0x1C785E4: PassiveProperty set on
    /// stencil_ref (changed byte +0x160/352, value +0x164/356), then tail call
    /// apply_stencil 0x1C78648 (decompiled, applied below). Called by
    /// CharacterDrawer.SetLayerId 0x1C6A79C with LayerIdToStencilRef(id).
    /// </summary>
    public void SetStencilRef(int stencilRef)
    {
        stencil_ref = stencilRef;              // +0x164(356)
        // apply_stencil 0x1C78648: FORWARD walk of MatCol (+0x130) and
        // SetFloat(mat, statics+0x0C = _Stencil, (float)this+356) on every
        // entry's material. No HasProperty guard, no mirror material.
        for (var i = 0; i < matcols.Count; i++)
        {
            var mat = matcols[i].material;
            if (mat == null) continue;
            mat.SetFloat(id_StencilRef, (float)stencil_ref);
        }
    }

    /// <summary>CharacterDrawer.LayerIdToStencilRef 0x1C0FD70 twin (drawer keeps its own copy).</summary>
    public static int LayerIdToStencilRef(int layerId)
    {
        return layerId >= 0 ? layerId + 2 : 0;
    }

    // =====================================================================
    // Idol / mono / rim — pure state writes in the decompiled Materials layer.
    // Every decompiled body here only fills the native record; the deferred
    // fan-out lives in apply_color 0x1C7BDD0 (reached through
    // UpdateProperties 0x1C7DD04), whose body is outside this batch.
    // =====================================================================

    /// <summary>
    /// CharacterMaterials.SetIdolColor 0x1C78738 (decompiled verbatim):
    ///   *(+76)=1; *(+77)=enable; *(+80..92)=color;  (always marks changed)
    /// No material write in the body. The consumer is apply_color 0x1C7BDD0
    /// (outside this batch); the resolved cctor table offers _Colors(+0x04),
    /// _Color(+0x18) and _SubColor0..3(+0x38) as candidates, but which one the
    /// idol colour lands in is not evidenced, so TryApplyAll() does not guess.
    /// </summary>
    public void SetIdolColor(bool is_enable, Color color)
    {
        idol_color.is_changed = true;          // +76
        idol_color.is_enable = is_enable;      // +77
        idol_color.color = color;              // +80..92
    }

    /// <summary>CharacterDrawer.SetIdolColor(Color) 0x1C6AD98 twin: re-set with the
    /// stored enable (+77) — the wrapper reads it back and re-calls SetIdolColor
    /// with the same colour (wrapper decompiled, drawer-side).</summary>
    public void SetIdolColorWithStoredEnable(Color color)
    {
        SetIdolColor(idol_color.is_enable, color);
    }

    /// <summary>CharacterDrawer.GetIdolColor 0x1C6ADBC: reads +76..+96 (all 20 bytes) → struct verbatim.</summary>
    public IdolColor GetIdolColor() => idol_color;

    /// <summary>
    /// CharacterMaterials.SetMonoColor 0x1C78764 (decompiled verbatim):
    /// *(+96)=1; *(+100..112)=color. No material write here. TryApplyAll()
    /// delivers the colour as the `_MonoColor` global, following
    /// CharacterBootstrap.ApplyGlobals' SetGlobalColor("_MonoColor", …): the
    /// cctor also has a per-material id_MonoColor (+0x54), so both routes exist;
    /// the global one matches the existing bootstrap and stays an INFERENCE for
    /// the deferred apply_color 0x1C7BDD0 body.
    /// </summary>
    public void SetMonoColor(Color color)
    {
        mono_color.is_changed = true;          // +96
        mono_color.color = color;              // +100..112
    }

    /// <summary>
    /// CharacterMaterials.SetMonoColorRatio 0x1C78778 (decompiled verbatim):
    /// *(+116)=1; *(+120)=ratio. State only. The cctor has NO id_MonoColorRatio
    /// field — +0x58 is PropertyToID("_Whiteness") — and the consumer is
    /// apply_color 0x1C7BDD0 (outside this batch), so no target property is
    /// invented here.
    /// </summary>
    public void SetMonoColorRatio(float ratio)
    {
        mono_color_ratio.is_changed = true;    // +116
        mono_color_ratio.ratio = ratio;        // +120
    }

    /// <summary>
    /// CharacterMaterials.SetRimLight 0x1C78788 (decompiled verbatim):
    /// *(+124)=1; *(+125)=enable; *(+128..140)=color. No material write in the
    /// body; the fan-out is apply_color 0x1C7BDD0. TryApplyAll() pushes
    /// `_RimLightOn` (0/1 float, cctor +0x2C) and `_RimColor` (Color, cctor
    /// +0x30) — bundle-confirmed names, INFERENCE for the deferred body's exact
    /// order/guards. `_RimLight` (vector) is written only by
    /// SetRimLightDirection 0x1C787A0 below.
    /// </summary>
    public void SetRimLight(bool is_enable, Color color)
    {
        rim_light.is_changed = true;           // +124
        rim_light.is_enable = is_enable;       // +125
        rim_light.color = color;               // +128..140
    }

    /// <summary>CharacterDrawer.GetRimLight 0x1C6AEB8 twin (state struct read).</summary>
    public RimLight GetRimLight() => rim_light;

    // =====================================================================
    // Light / rim directions — decompiled write-through bodies:
    //   SetRimLightDirection 0x1C787A0 → SetVector(mat, statics+0x28 = _RimLight,
    //                                        x, y, z, 0) on every MatCol
    //   SetLightDirection     0x1C78904 → SetVector(mat, statics+0x24 = _Light,
    //                                        x, y, z, 0) on every MatCol
    // Both walk the MatCol list (+0x130/304) BACK-TO-FRONT (count-1 .. 0), skip
    // Unity-null/dead materials (sub_7149F2C) and do NOT guard with
    // HasProperty. Neither body stores the direction on `this`; the two
    // direction fields above are port-only bookkeeping for Describe().
    // =====================================================================

    /// <summary>CharacterMaterials.SetRimLightDirection 0x1C787A0 — vector static
    /// +0x28 (_RimLight) write-through to every registered material.</summary>
    public void SetRimLightDirection(Vector3 direction)
    {
        rim_light_direction = direction;       // port-only record (native stores nothing)
        for (var i = matcols.Count - 1; i >= 0; i--)
        {
            var mat = matcols[i].material;
            if (mat == null) continue;
            mat.SetVector(id_RimLight, new Vector4(direction.x, direction.y, direction.z, 0f));
        }
    }

    /// <summary>CharacterMaterials.SetLightDirection 0x1C78904 — vector static
    /// +0x24 (_Light) write-through to every registered material.</summary>
    public void SetLightDirection(Vector3 direction)
    {
        light_direction = direction;           // port-only record (native stores nothing)
        for (var i = matcols.Count - 1; i >= 0; i--)
        {
            var mat = matcols[i].material;
            if (mat == null) continue;
            mat.SetVector(id_Light, new Vector4(direction.x, direction.y, direction.z, 0f));
        }
    }

    // =====================================================================
    // Spotlight (PassiveProperty<BlendColor> +0xAC/172,
    // PassiveProperty<Color> +0xC4/196) — state records only; the consumer is
    // the Live-stage light pass, and no `_SpotLight*` property exists in the
    // shipped materials of the ADV subset.
    // =====================================================================

    /// <summary>
    /// CharacterMaterials.SetSpotlightColor 0x1C78A7C (decompiled verbatim):
    ///   1. mark spotlight_color (+0xAC) changed and set {blend, color} at
    ///      +0xB0 via the PassiveProperty setter sub_4DCD004;
    ///   2. mark pinspotlight_color (+0xC4) changed and set
    ///      Color(pin.r, pin.g, pin.b, pin_alpha) at +0xC8 via sub_4DCD18C.
    /// No material of the character is touched here.
    /// </summary>
    public void SetSpotlightColor(Color color, Color pin, float pin_alpha, int blend)
    {
        spotlight_color.blend = blend;         // +0xB0(176)
        spotlight_color.color = color;         // +0xB4(180..192)
        pin_spotlight_color = new Color(pin.r, pin.g, pin.b, pin_alpha); // +0xC8(200)
        pin_spotlight_alpha = pin_alpha;
        pin_spotlight_changed = true;          // +0xC4(196) changed byte
    }

    /// <summary>CharacterDrawer.GetSpotlightColor 0x1C6AF78 → CharacterMaterials.GetSpotlightColor
    /// 0x1C78B74 (body outside this batch; returns the stored blend colour).</summary>
    public Color GetSpotlightColor() => spotlight_color.color;

    /// <summary>Blend mode recorded by SetSpotlightColor 0x1C78A7C (first dword of +0xB0).</summary>
    public int GetSpotlightBlend() => spotlight_color.blend;

    /// <summary>CharacterMaterials.GetPinSpotlightColor 0x1C78BB8 — Color at +0xC8
    /// (already carries the pin alpha).</summary>
    public Color GetPinSpotlightColor() => pin_spotlight_color;
    /// <summary>CharacterMaterials.GetPinSpotlightAlpha 0x1C78BFC — the alpha of the
    /// +0xC8 colour (kept as a separate field to match the drawer wrapper).</summary>
    public float GetPinSpotlightAlpha() => pin_spotlight_alpha;

    // Eye highlight — native chain (current RVAs):
    //   SetEyeHighlightColor 0x1C7A008 (body outside this batch) collects the
    //   eye-material list (0x1C1F390 / 0x1C1F474 outside this batch) and loops
    //   SetEyeHighlightColorToMaterial 0x1C7A2A4 (decompiled below). The helper
    //   gates on HasProperty(statics+0x40 = id_IrisColor) and then writes the
    //   colour with its alpha.
    // The spike's eye selection (HasProperty(_IrisColor) && HasProperty(_SubTex),
    // the bundle-verified identity of Custom/BultIn/Bi_CharEye) stands in for the
    // native name-literal filter, which is not in this batch.
    private Color eye_highlight_color;

    public void SetEyeHighlightColor(Color col)
    {
        eye_highlight_color = col;
        PushEyeHighlightColor();   // 0x1C7A008 fan-out shape over the eye materials
    }
    public Color GetEyeHighlightColor() => eye_highlight_color;

    /// <summary>
    /// SetEyeHighlightColorToMaterial 0x1C7A2A4 (decompiled verbatim):
    ///   if (material == null) throw;                 // native crashes; spike returns
    ///   if (!HasProperty(id_IrisColor)) return;
    ///   SetColor(id_IrisColor, r, g, b, a);           // alpha carried through
    /// </summary>
    public static void SetEyeHighlightColorToMaterial(Material material, Color color)
    {
        if (material == null) return;
        if (!material.HasProperty(id_IrisColor)) return;
        material.SetColor(id_IrisColor, color);
    }

    /// <summary>0x1C7A008 fan-out shape over the eye-group materials.</summary>
    private void PushEyeHighlightColor()
    {
        foreach (var col in matcols)
        {
            if (!col.isEye) continue;
            SetEyeHighlightColorToMaterial(col.material, eye_highlight_color);
        }
    }

    // =====================================================================
    // Cheek redden — the chain FaceCtrl drives. Every write in this family is
    // state-only EXCEPT SetCheekReddenToMaterial (decompiled material write,
    // 0x1C78C6C). The state consumers are apply_color 0x1C7BDD0 (outside this
    // batch); TryApplyAll() delivers the cached intensity to the materials.
    // =====================================================================

    /// <summary>
    /// CharacterMaterials.SetCheekRedden 0x1C78C3C (body outside this batch,
    /// entry confirmed; shape preserved from the earlier decompilation):
    ///   enable = intensity > 0
    ///   if (+169 != enable) { +168 = 1; +169 = enable; }   // CheekReddenEnable
    ///   +144 = 1;                                          // CheekRedden.is_changed
    ///   +164 = intensity;                                  // CheekRedden.intensity
    /// No material write here. The apply pass that feeds the enabled state into
    /// SetCheekReddenToMaterial via apply_color 0x1C7BDD0 is outside this batch;
    /// TryApplyAll() delivers the cached intensity to every material whose
    /// _ReddishIntensity property exists (helper is HasProperty-guarded).
    /// </summary>
    public void SetCheekRedden(float intensity)
    {
        var enable = intensity > 0f;
        if (cheek_redden_enable.value != enable)
        {
            cheek_redden_enable.is_changed = true;   // +168
            cheek_redden_enable.value = enable;      // +169
        }
        cheek_redden.is_changed = true;              // +144
        cheek_redden.intensity = intensity;          // +164
    }

    /// <summary>
    /// CharacterMaterials.SetCheekReddenEnable 0x1C78DE8 (body outside this
    /// batch; shape preserved from the earlier decompilation):
    ///   if (+169 != enable) { +168 = 1; +169 = enable; }
    /// Note: it does NOT set +144 (CheekRedden.is_changed) — the enable and
    /// intensity caches are dirtied separately, exactly as the decompile shows.
    /// </summary>
    public void SetCheekReddenEnable(bool is_enable)
    {
        if (cheek_redden_enable.value == is_enable) return;
        cheek_redden_enable.is_changed = true;       // +168
        cheek_redden_enable.value = is_enable;       // +169
    }

    /// <summary>CharacterMaterials.SetCheekReddenIntensity 0x1C78E04: +144=1; +164=val.</summary>
    public void SetCheekReddenIntensity(float intensity)
    {
        cheek_redden.is_changed = true;              // +144
        cheek_redden.intensity = intensity;          // +164
    }

    /// <summary>
    /// CharacterMaterials.SetCheekReddenToMaterial 0x1C78C6C (body outside this
    /// batch; shape preserved from the earlier decompilation of the same
    /// function family):
    ///   1. if (!mat.HasProperty(_ReddishIntensity)) return;   (cctor +0x4C)
    ///   2. if (!mat.HasProperty(_IsReddish)) return;          (cctor +0x44)
    ///   3. SetMaterialToggle(mat, _IsReddish, intensity > 0)
    ///      (toggles the `_ISREDDISH_ON` keyword + float 0/1)
    ///   4. mat.SetFloat(_ReddishIntensity, intensity);
    /// The caller is apply_color 0x1C7BDD0, outside this batch; the exact
    /// matcol subset it feeds is therefore not asserted — the HasProperty guard
    /// makes the port's all-materials loop equivalent for the ADV materials.
    /// FaceCtrl B3 (FaceCtrlNative) drives this exact method.
    /// </summary>
    public static void SetCheekReddenToMaterial(Material material, float intensity)
    {
        if (material == null) return;
        if (!material.HasProperty(id_ReddishIntensity)) return;
        if (!material.HasProperty(id_IsReddish)) return;
        var flag = intensity > 0f;
        material.SetFloat(id_IsReddish, flag ? 1f : 0f);
        if (flag) material.EnableKeyword(ReddishKeyword);
        else material.DisableKeyword(ReddishKeyword);
        material.SetFloat(id_ReddishIntensity, intensity);
    }

    // =====================================================================
    // Inherent colour family — SetInherentColor 0x1C79538 is decompiled: it
    // writes inherent_colors[index], then fans out through
    // SetInherentColorToMaterial 0x1C796B0 over every MatCol (forward order).
    // The helper body is outside this batch; initStatic 0x1C7ABE8 reveals the
    // property name table id_ChrColors (+0x38, int[4], String.Format(
    // "_SubColor{0}", i)), which is what an inherent-colour index indexes into.
    // The drawer port previously pushed a speculative `_InherentColor`; that is
    // dropped in favour of the cctor-backed _SubColorN family.
    // =====================================================================

    /// <summary>
    /// CharacterMaterials.SetInherentColor 0x1C79538 (decompiled):
    ///   if ((uint)color_index > 3) return;                  // unsigned gate 0..3
    ///   if (inherent_colors.Length <= color_index) throw;   // native throws
    ///   inherent_colors[color_index] = color;               // +0xE0 + 16*index
    ///   then forward loop over MatCol (+0x130/304) →
    ///   SetInherentColorToMaterial(mat, color, color_index) 0x1C796B0.
    /// </summary>
    public void SetInherentColor(Color color, int color_index)
    {
        if ((uint)color_index > (uint)(ChrColorNum - 1)) return;
        inherent_colors[color_index] = color;
        inherent_color_changed = true;
        foreach (var col in matcols)
        {
            if (col.material == null) continue;
            SetInherentColorToMaterial(col.material, color, color_index);
        }
    }

    /// <summary>
    /// CharacterMaterials.SetInherentColorToMaterial 0x1C796B0 — body outside
    /// this batch. The per-material write is a HasProperty-guarded SetColor on
    /// id_ChrColors[color_index] (`_SubColor{index}` per cctor 0x1C7ABE8 +0x38).
    /// </summary>
    public static void SetInherentColorToMaterial(Material material, Color color, int color_index)
    {
        if (material == null) return;
        if (color_index < 0 || color_index >= ChrColorNum) return;
        var id = id_ChrColors[color_index];
        // UNKNOWN(native 0x1C796B0): body not decompiled — the HasProperty
        // guard is assumed; the index→_SubColorN mapping is cctor-confirmed.
        if (!material.HasProperty(id)) return;
        material.SetColor(id, color);
    }

    /// <summary>CharacterMaterials.SetInherentColorSel 0x1C79470: picks
    /// soul.inherentColor / inherentColor2 after the Value.isValid gate.</summary>
    public void SetInherentColorSel(Imas.CharacterSoul soul, int color_sel)
    {
        if (soul == null) return;
        var v = color_sel == 0 ? soul.inherentColor : soul.inherentColor2;
        if (!v.isValid) return;
        SetInherentColor(v.value, color_sel);
    }

    // =====================================================================
    // ApplyFromSoul — the value-driven half (bodyScale / breast sway are NOT
    // character-materials concerns and stay OUT of this class, see JBH).
    // =====================================================================

    /// <summary>
    /// Wires the soul into this class using only `isValid` values. Field map
    /// (dump.cs CharacterSoul, Value&lt;T&gt;{isValid +0x0, value +0x4}):
    ///   cheekReddenColor     +0x30/+0x34 → cheek_redden_color state (+0x94);
    ///                         consumer apply_color 0x1C7BDD0, outside this batch
    ///   cheekReddenIntensity +0x44/+0x48 → SetCheekReddenIntensity 0x1C78E04
    ///   skinColor            +0x4C/+0x50 → last_skin_col (+0x10C), then
    ///                         calcSkinBias 0x1C7B58C (+0x11C) — body outside batch
    ///   inherentColor(2)     +0x60/+0x74 → SetInherentColor 0x1C79538 (decompiled)
    /// Values are 0..255 ints scaled by `Color(r/255, g/255, b/255, 1)` in the
    /// soul ctor, so the Color shapes here are soul-normalised.
    /// bodyScale / sway*b are deliberately ignored (JointBodyHead territory).
    /// </summary>
    public void ApplyFromSoul(Imas.CharacterSoul soul)
    {
        if (soul == null) return;
        if (soul.cheekReddenIntensity.isValid)
            SetCheekReddenIntensity(soul.cheekReddenIntensity.value);
        if (soul.cheekReddenColor.isValid)
        {
            cheek_redden_color = soul.cheekReddenColor.value;
            cheek_redden_color_changed = true;   // consumer: apply_color 0x1C7BDD0 (outside batch)
        }
        if (soul.skinColor.isValid)
        {
            // create_sync 0x1C77B44 copies defaultLastSkin → lastSkinCol, then a
            // valid soul skinColor overwrites it and calcSkinBias runs.
            last_skin_col = soul.skinColor.value; // +0x10C
            skin_color = soul.skinColor.value;
            skin_color_changed = true;
            // UNKNOWN(native 0x1C7B58C): calcSkinBias body (skinBias +0x11C) is
            // outside this batch; the port has no r185/lumi inputs to compute it.
        }
        if (soul.inherentColor.isValid)
            SetInherentColor(soul.inherentColor.value, 0);
        if (soul.inherentColor2.isValid)
            SetInherentColor(soul.inherentColor2.value, 1);
    }

    // =====================================================================
    // Base-value capture / restore
    // =====================================================================

    /// <summary>
    /// Snapshots, per registered material, every property this class or the
    /// drawer family can touch: _Outline, _OutlineColor, _Stencil, _ReddishColor,
    /// _ReddishIntensity, _RimColor, _RimLightOn, _IrisColor (bundle-only
    /// properties), plus the `_ISREDDISH_ON` keyword state and the `_MonoColor`
    /// global. Absent properties are simply not stored.
    /// </summary>
    public void CaptureBaseValues()
    {
        baseValues.Clear();
        baseReddishKeyword.Clear();
        baseGlobalMonoColor = Shader.GetGlobalColor(MonoColorGlobalShader);
        foreach (var col in matcols)
        {
            var mat = col.material;
            if (mat == null) continue;
            var snap = new Dictionary<int, CapturedValue>();
            CaptureFloat(mat, snap, id_Outline);
            CaptureFloat(mat, snap, id_StencilRef);
            CaptureFloat(mat, snap, id_ReddishIntensity);
            CaptureFloat(mat, snap, id_RimLightOn);
            CaptureColor(mat, snap, id_OutlineColor);
            CaptureColor(mat, snap, id_ReddishColor);
            CaptureColor(mat, snap, id_RimColor);
            CaptureColor(mat, snap, id_IrisColor);
            baseValues[mat] = snap;
            baseReddishKeyword[mat] = mat.IsKeywordEnabled(ReddishKeyword);
        }
        baseValuesCaptured = true;
    }

    /// <summary>
    /// Restores exactly what CaptureBaseValues() snapshotted (guarded by the
    /// same HasProperty checks). Returns true only if a capture existed.
    /// </summary>
    public bool ResetBaseValues()
    {
        if (!baseValuesCaptured) return false;
        foreach (var kvp in baseValues)
        {
            var mat = kvp.Key;
            if (mat == null) continue;
            foreach (var v in kvp.Value)
            {
                if (!HasProperty(mat, v.Key)) continue;
                if (v.Value.isColor) mat.SetColor(v.Key, v.Value.color);
                else mat.SetFloat(v.Key, v.Value.number);
            }
        }
        foreach (var kvp in baseReddishKeyword)
        {
            var mat = kvp.Key;
            if (mat == null || !mat.HasProperty(id_IsReddish)) continue;
            if (kvp.Value) mat.EnableKeyword(ReddishKeyword);
            else mat.DisableKeyword(ReddishKeyword);
        }
        Shader.SetGlobalColor(MonoColorGlobalShader, baseGlobalMonoColor);
        return true;
    }

    private static bool HasProperty(Material mat, int propertyId)
    {
        // PropertyToID is many-to-one on names, but integer ids stable enough for
        // `HasProperty` which Unity exposes only by name; the name tables below
        // cover every id used here. (Material.HasProperty(int) exists too.)
        return mat.HasProperty(propertyId);
    }

    private static void CaptureFloat(Material mat, Dictionary<int, CapturedValue> snap, int id)
    {
        if (!mat.HasProperty(id)) return;
        snap[id] = new CapturedValue { isColor = false, number = mat.GetFloat(id) };
    }

    private static void CaptureColor(Material mat, Dictionary<int, CapturedValue> snap, int id)
    {
        if (!mat.HasProperty(id)) return;
        snap[id] = new CapturedValue { isColor = true, color = mat.GetColor(id) };
    }

    // =====================================================================
    // TryApplyAll — frame-end one-shot, shaped after the CURRENT shipped
    // sequence UpdateProperties 0x1C7DD04 → apply_color 0x1C7BDD0 → ApplyOutline
    // 0x1C7CC14 → UnsetDirty 0x1C7E094 (those bodies are OUTSIDE this batch,
    // which only covered the 12 setter/helper entries listed in the header).
    // The surfaced families apply at most once per call and the changed bytes
    // are cleared where UnsetDirty is documented to zero them.
    // =====================================================================

    [Serializable]
    public struct TryApplyResult
    {
        public List<string> applied;
        public List<string> unknown;
    }

    /// <summary>
    /// Native apply pass — the CURRENT chain (bodies outside this batch):
    /// CharacterMaterials.UpdateProperties 0x1C7DD04 per frame → apply_color
    /// 0x1C7BDD0 → ApplyOutline 0x1C7CC14 → UnsetDirty 0x1C7E094. The 12 bodies
    /// this port was rewritten against are the setters/helpers themselves
    /// (header table), so the deferred fan-out targets below are port
    /// inference, flagged per family:
    ///   - cheek: SetCheekReddenToMaterial 0x1C78C6C — bundle-confirmed
    ///     _ReddishIntensity/_IsReddish pair, HasProperty-guarded helper;
    ///   - rim: _RimLightOn (cctor +0x2C) / _RimColor (cctor +0x30) — names
    ///     confirmed, fan-out location INFERENCE (apply_color 0x1C7BDD0);
    ///   - outline width: _Outline (cctor +0x64) — drawer applies it eagerly
    ///     too; the one-shot covers late registrations;
    ///   - mono: Shader.SetGlobalColor("_MonoColor") — follows the existing
    ///     CharacterBootstrap.ApplyGlobals precedent; the cctor also has a
    ///     per-material id_MonoColor (+0x54), so this is INFERENCE;
    ///   - outline colour: ApplyOutlineColor 0x1C784EC is decompiled (forward
    ///     MatCol walk, SetColor(_OutlineColor), no guard) — re-pushed here.
    /// UnsetDirty 0x1C7E094 zeroes the changed bytes this port tracks
    /// ({352, 324, 124, 76, 96, 172, 196, 168, 144} in the earlier
    /// decompilation of the same class; the current body is outside this batch).
    /// </summary>
    public TryApplyResult TryApplyAll()
    {
        var result = new TryApplyResult
        {
            applied = new List<string>(),
            unknown = new List<string>(),
        };

        var cheekDirty = cheek_redden.is_changed || cheek_redden_enable.is_changed;
        var monoDirty = mono_color.is_changed;
        var rimDirty = rim_light.is_changed;
        var outlineWidthDirty = outline_width_dirty;
        // unknown-coverage snapshot (before UnsetDirty clears the flags)
        var idolUnknown = idol_color.is_changed;
        var monoRatioUnknown = mono_color_ratio.is_changed;
        var pinUnknown = pin_spotlight_changed;
        var cheekColorUnknown = cheek_redden_color_changed;
        var skinUnknown = skin_color_changed;

        // ---- native step 3: per-MatCol families (single forward pass over
        //      the same entries the native loop walks in reverse) ------------
        foreach (var col in matcols)
        {
            var mat = col.material;
            if (mat == null) continue;
            if (cheekDirty) SetCheekReddenToMaterial(mat, cheek_redden.intensity);
            if (rimDirty)
            {
                if (mat.HasProperty(id_RimLightOn)) mat.SetFloat(id_RimLightOn, rim_light.is_enable ? 1f : 0f);
                if (mat.HasProperty(id_RimColor)) mat.SetColor(id_RimColor, rim_light.color);
            }
            if (outlineWidthDirty && mat.HasProperty(id_Outline))
            {
                var width = outline_disabled ? 0f : outline_width * col.outlineWidthFactor;
                mat.SetFloat(id_Outline, width);
            }
        }

        // ---- native step 1 colour aggregate, global pieces ----------------
        if (cheekDirty) result.applied.Add("cheek → SetCheekReddenToMaterial × " + matcols.Count);
        if (rimDirty) result.applied.Add("rim_light → _RimLightOn/_RimColor × " + matcols.Count);
        if (outlineWidthDirty) result.applied.Add("outline_width → _Outline × " + matcols.Count);
        if (monoDirty)
        {
            Shader.SetGlobalColor(MonoColorGlobalShader, mono_color.color);
            result.applied.Add("mono_color → Shader.SetGlobalColor(\"_MonoColor\")");
        }

        // outline colour: SetOutlineColor 0x1C78460 delivers eagerly via the
        // decompiled tail ApplyOutlineColor 0x1C784EC (forward MatCol walk,
        // SetColor(statics+0x80 = _OutlineColor, this+0x150 colour), no
        // HasProperty guard, no mirror material); re-push keeps the one-shot
        // idempotent for late registrations.
        if (outline_color_dirty)
        {
            PushOutlineColor();
            result.applied.Add("outline_color → _OutlineColor");
        }

        // ---- native step 5: UnsetDirty 0x1C7E094 (body outside this batch) --
        // byte offsets {352, 324, 124, 76, 96, 172, 196, 168, 144} from the
        // earlier decompilation of the same class; 189-port keeps +352/+172 as
        // eager/record values.
        outline_width_dirty = false;                    // +324
        outline_color_dirty = false;
        rim_light.is_changed = false;                   // +124
        idol_color.is_changed = false;                  // +76
        mono_color.is_changed = false;                  // +96
        pin_spotlight_changed = false;                  // +196
        cheek_redden_enable.is_changed = false;         // +168
        cheek_redden.is_changed = false;                // +144

        // ---- everything the decompiled bodies of this batch do not cover ----
        if (idolUnknown)
            result.unknown.Add("idol_color → apply target lives in apply_color 0x1C7BDD0 (outside batch); cctor candidates _Colors/_Color/_SubColorN unproven, 中性不写");
        if (monoRatioUnknown)
            result.unknown.Add("mono_color_ratio → consumer apply_color 0x1C7BDD0 (outside batch); cctor has NO id_MonoColorRatio (+0x58 is _Whiteness)");
        if (pinUnknown)
            result.unknown.Add("spotlight/pin → PassiveProperty record only (0x1C78A7C decompiled); consumer is the Live-stage light pass, out of ADV scope");
        if (cheekColorUnknown)
            result.unknown.Add("cheek_redden_color → no decompiled Set* writes _ReddishColor; apply site in apply_color 0x1C7BDD0 (outside batch)");
        if (skinUnknown)
            result.unknown.Add("skin_color → Materials-layer apply site outside batch (calcSkinBias 0x1C7B58C + lastSkinCol consumer)");
        return result;
    }

    /// <summary>
    /// CharacterMaterials.UpdateProperties 0x1C7DD04 entry point (native name
    /// kept for the drawer wiring): the scheduled one-shot. The native per-frame
    /// gate + blink block live inside that body, which is outside this batch;
    /// see TryApplyAll for the port's shaped order.
    /// </summary>
    public void UpdateProperties(float deltaTime)
    {
        TryApplyAll();
    }

    // =====================================================================
    // Describe
    // =====================================================================

    public string Describe()
    {
        var sb = new StringBuilder();
        sb.Append("CharacterMaterialsNative chara_id=").Append(chara_id ?? "<null>")
          .Append(" chara_index=").Append(chara_index)
          .Append(" registered=").Append(matcols.Count).AppendLine();
        CountGroup(CharaMaterialGroup.Head, sb);
        CountGroup(CharaMaterialGroup.Body, sb);
        CountGroup(CharaMaterialGroup.Face, sb);
        sb.Append("  outline: width=").Append(outline_width.ToString("G6"))
          .Append(" widthDirty=").Append(outline_width_dirty)
          .Append(" disabled=").Append(outline_disabled)
          .Append(" color=").Append(outline_color)
          .Append(" colorDirty=").Append(outline_color_dirty)
          .Append(" stencilRef=").Append(stencil_ref).AppendLine();
        sb.Append("  idol: changed=").Append(idol_color.is_changed)
          .Append(" enable=").Append(idol_color.is_enable).Append(' ').Append(idol_color.color).AppendLine();
        sb.Append("  mono: changed=").Append(mono_color.is_changed).Append(' ').Append(mono_color.color)
          .Append(" ratio: changed=").Append(mono_color_ratio.is_changed)
          .Append(" value=").Append(mono_color_ratio.ratio.ToString("F3")).AppendLine();
        sb.Append("  rim: changed=").Append(rim_light.is_changed)
          .Append(" enable=").Append(rim_light.is_enable).Append(' ').Append(rim_light.color).AppendLine();
        sb.Append("  cheek: changed=").Append(cheek_redden.is_changed)
          .Append(" intensity=").Append(cheek_redden.intensity.ToString("F3"))
          .Append(" | enable: changed=").Append(cheek_redden_enable.is_changed)
          .Append(" value=").Append(cheek_redden_enable.value)
          .Append(" | color=").Append(cheek_redden_color).AppendLine();
        sb.Append("  spotlight: blend=").Append(spotlight_color.blend).Append(' ').Append(spotlight_color.color)
          .Append(" pin=").Append(pin_spotlight_color).Append(" alpha=")
          .Append(pin_spotlight_alpha.ToString("F2")).AppendLine();
        sb.Append("  directions: rim=").Append(rim_light_direction).Append(" light=").Append(light_direction).AppendLine();
        sb.Append("  soul-state: skin=").Append(skin_color)
          .Append(" inherent[0]=").Append(inherent_colors[ChrColorMainIndex])
          .Append(" inherentDirty=").Append(inherent_color_changed).AppendLine();
        return sb.ToString();
    }

    private void CountGroup(CharaMaterialGroup group, StringBuilder sb)
    {
        var count = 0;
        var eyeCount = 0;
        foreach (var col in matcols)
        {
            if (col.group != group) continue;
            count++;
            if (col.isEye) eyeCount++;
        }
        sb.Append("  group ").Append(group).Append(": mats=").Append(count);
        if (group == CharaMaterialGroup.Head) sb.Append(" eye=").Append(eyeCount);
        sb.AppendLine();
    }

    // =====================================================================
    // UNKNOWN ledger — keep in lockstep with the per-method "UNKNOWN(native …)"
    // comments. Only entries whose body was NOT in this batch's decompilation
    // set are listed; every RVA below is a CURRENT (shipped-binary) RVA.
    // =====================================================================
    public static readonly string[] NativeUnknowns =
    {
        "0x1C7B58C calcSkinBias: body outside batch (skinBias +0x11C consumer)",
        "0x1C7BDD0 apply_color: deferred fan-out for idol / mono-ratio / cheek colour / skin",
        "0x1C7DD04 UpdateProperties: per-frame gate + blink block outside batch",
        "0x1C7E094 UnsetDirty: changed-byte set outside batch ({352,324,124,76,96,172,196,168,144} from earlier decomp)",
        "0x1C796B0 SetInherentColorToMaterial: index→_SubColorN confirmed by cctor 0x1C7ABE8; HasProperty guard assumed",
        "0x1C77B44 create_sync: sub_7124750/sub_7124764 colour getters and xmmword_83FD830 glasses const not statically resolvable",
        "0x1C7A008 SetEyeHighlightColor: out-of-batch fan-out over the eye-material list (0x1C1F390/0x1C1F474 older bodies)",
        "0x1C78A7C spotlight/pin: PassiveProperty record only; consumer is the Live-stage light pass",
        "0x1C78C3C SetCheekRedden / 0x1C78DE8 SetCheekReddenEnable / 0x1C78E04 SetCheekReddenIntensity: bodies outside batch (shape preserved)",
        "0x1C78C6C SetCheekReddenToMaterial: body outside batch; _ReddishIntensity/_IsReddish pairing bundle-confirmed",
        "0x1C783BC/0x1C78420 outline width setter/getter bodies outside batch",
    };
}
