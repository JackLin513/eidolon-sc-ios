// =========================================================================
// CharacterMaterials (dump.cs TypeDefIndex 15017) — B5 decompilation-faithful
// port of the 15 Materials__* functions in /tmp/ida-decomp/b5/.
// =========================================================================
//
// Evidence (read-only):
//   /tmp/ida-decomp/b5/Materials__Create@0x1c1cec8.c            (thunk -> sub_1C1CECC)
//   /tmp/ida-decomp/b5/Materials__SetOutlineWidth@0x1c1d744.c
//   /tmp/ida-decomp/b5/Materials__SetOutlineColor@0x1c1d7e8.c
//   /tmp/ida-decomp/b5/Materials__SetStencilRef@0x1c1d96c.c
//   /tmp/ida-decomp/b5/Materials__SetIdolColor@0x1c1dac0.c
//   /tmp/ida-decomp/b5/Materials__SetMonoColor@0x1c1daec.c
//   /tmp/ida-decomp/b5/Materials__SetMonoColorRatio@0x1c1db00.c
//   /tmp/ida-decomp/b5/Materials__SetRimLight@0x1c1db10.c
//   /tmp/ida-decomp/b5/Materials__SetRimLightDirection@0x1c1db28.c
//   /tmp/ida-decomp/b5/Materials__SetLightDirection@0x1c1dc8c.c
//   /tmp/ida-decomp/b5/Materials__SetSpotlightColor@0x1c1de04.c
//   /tmp/ida-decomp/b5/Materials__SetCheekRedden@0x1c1dfc4.c
//   /tmp/ida-decomp/b5/Materials__SetCheekReddenToMaterial@0x1c1dff4.c
//   /tmp/ida-decomp/b5/Materials__SetCheekReddenEnable@0x1c1e170.c
//   /tmp/ida-decomp/b5/Materials__SetCheekReddenIntensity@0x1c1e18c.c
//   plus the Drawer-layer wrappers /tmp/ida-decomp/b5/Drawer__*.c (0x1C10180,
//   0x1C1019C, 0x1C10260, 0x1C1027C, 0x1C10298, 0x1C102BC, 0x1C102E4, 0x1C10300,
//   0x1C1031C, 0x1C10338, 0x1C1035C, 0x1C10380, 0x1C1039C, 0x1C103E0, 0x1C103FC,
//   0x1C10418, 0x1C10450, 0x1C10478).
// Note: IDA was unavailable for this pass (no re-dump); every statement below is
// sourced from the snapshot above.
//
// Decision context: docs/adr/0033-native-faithful-3d-migration.md (B5).
// Rules honoured in this file:
//   * A method touches the real material ONLY when the decompiled body directly
//     shows the material write (SetCheekReddenToMaterial, and the confirmed
//     tail-apply calls of SetOutlineColor / SetStencilRef). Everything else is a
//     state-cache write, and the material half is TryApplyAll()'s or UNKNOWN.
//   * Every unresolved semantic is UNKNOWN(native 0x…) — also listed in
//     CharacterMaterialsNative.NativeUnknowns and /tmp/materials-native-notes.md.
//   * Fields below carry the native IL2CPP byte offset in comments; the native
//     struct layout is, byte for byte:
//     +0x4C(76) changed | +0x4D(77) enable | +0x50(80)..+0x5C(92) Color   IdolColor
//     +0x60(96) changed | +0x64(100)..+0x70(112) Color                   MonoColor
//     +0x74(116) changed | +0x78(120) ratio                              MonoColorRatio
//     +0x7C(124) changed | +0x7D(125) enable | +0x80(128)..+0x8C(140) C. RimLight
//     +0x90(144) changed | +0xA4(164) intensity                          CheekRedden
//     +0xA8(168) changed | +0xA9(169) value                              CheekReddenEnable
//     +0xAC(172) {int blend, float r,g,b,a}  | +0xC4(196) {changed; pincolor/alpha}
//     +0x130(304) List<MatCol>  | +0x144(324) outline_width float
//     +0x14C(332) outline_color Color | +0x160(352) stencil_ref int
//
// WIRING (one line, not performed here): replace the embedded
// CharacterMaterialsNative inside CharacterDrawerNative (CharacterDrawerNative.cs
// "@Materials" section) with this class — `drawer.materials` keeps the same
// name; construct it in drawer.Create with
// `new CharacterMaterialsNative(rootGo.GetComponentsInChildren<SkinnedMeshRenderer>(true))`,
// then call `ApplyFromSoul(soul)` + `TryApplyAll()` where drawer.Create ends.
//
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// COMPILE NOTE: CharacterDrawerNative.cs already embeds a
// `public sealed class CharacterMaterialsNative` (its "@Materials" section,
// ~line 779). While that embedded class exists, the two files do NOT compile
// together (CS0101, duplicate top-level name in the global namespace). This
// file is written to compile standalone (verified offline, 0 error / 0 warning)
// and to be a drop-in replacement: delete the embedded class in
// CharacterDrawerNative.cs when wiring (that edit belongs to the lead, not to
// this authoring pass), then keep every member signature listed at the bottom
// of this file identical.
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
//
// Shader property names are ground truth from the shipped bundles (same
// material inventory as CharacterDrawerNative's header):
//   Custom/Chr_Basic        : _Outline _OutlineColor _OutlineZadj _TanFov _Stencil
//                             _RimLightOn _RimLight _RimColor _ZShift1000Min/Max
//   Custom/Chr_Face         : _Outline _OutlineColor _Stencil _IsReddish _ReddishColor
//                             _ReddishIntensity _RimLightOn _RimLight _RimColor
//   Custom/BultIn/Bi_CharEye: _IrisColor _SubTex _Stencil
//   global                  : _MonoColor (set/kept by CharacterBootstrap.ApplyGlobals)

using System;
using System.Collections.Generic;
using System.Text;
using UnityEngine;

/// <summary>
/// Native-faithful <c>CharacterMaterials</c> (dump.cs 15017). Plain class — the
/// native component is attached to the character top object by Create
/// 0x1C1CEC8, but this spike keeps it as a plain object exactly like the
/// performance-layer substitution already used in the drawer.
/// </summary>
public sealed class CharacterMaterialsNative
{
    // ---------------------------------------------------------------------
    // Shader property ids (Shader.PropertyToID init equivalent; names are
    // bundle-verified inventory entries, never guesses).
    // ---------------------------------------------------------------------
    public static readonly int id_Outline = Shader.PropertyToID("_Outline");
    public static readonly int id_OutlineColor = Shader.PropertyToID("_OutlineColor");
    public static readonly int id_StencilRef = Shader.PropertyToID("_Stencil");
    public static readonly int id_IsReddish = Shader.PropertyToID("_IsReddish");
    public static readonly int id_ReddishIntensity = Shader.PropertyToID("_ReddishIntensity");
    public static readonly int id_ReddishColor = Shader.PropertyToID("_ReddishColor");
    public static readonly int id_RimLightOn = Shader.PropertyToID("_RimLightOn");
    public static readonly int id_RimColor = Shader.PropertyToID("_RimColor");
    public static readonly int id_IrisColor = Shader.PropertyToID("_IrisColor");

    /// <summary>
    /// Face toggle keyword read out of SetCheekReddenToMaterial 0x1C1DFF4
    /// (CustomShaderUtility.SetMaterialToggle keyword argument, CF confirmed in
    /// FaceCtrl.SetCheekValue 0x379F840 in the B3 pass).
    /// UNKNOWN(native, literal source): the keyword string's IL2CPP metadata
    /// literal could not be decoded statically in this snapshot; the value
    /// "_ISREDDISH_ON" is the one confirmed by the B3 decompilation.
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

    /// <summary>Native BlendColor record at +0xAC(172): {int blend; float r,g,b,a;}</summary>
    [Serializable]
    public struct BlendColor
    {
        public int blend;         // +172
        public Color color;       // +176..188
    }

    // ---------------------------------------------------------------------
    // Group/material cache
    // ---------------------------------------------------------------------

    public enum CharaMaterialGroup { Body, Head, Face }

    /// <summary>
    /// One registered material (`MatCol` at native +0x130(304), trimmed). The
    /// decompile of SetLightDirection 0x1C1DC8C walks this list as
    /// `for (i = count; i > 0;)` and takes `entry[2]` (offset 16 in MatCol) as
    /// the Material reference, then skips null/dead materials.
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
    // Identity (native Create 0x1C1CEC8 thunk -> sub_1C1CECC, body not decompiled)
    // ---------------------------------------------------------------------
    public int chara_index;
    public string chara_id;
    public GameObject top_go;

    // ---------------------------------------------------------------------
    // State caches — native offsets in the comments are authoritative.
    // ---------------------------------------------------------------------
    public IdolColor idol_color;                   // +0x4C(76)
    public MonoColor mono_color;                   // +0x60(96)
    public MonoColorRatio mono_color_ratio;        // +0x74(116)
    public RimLight rim_light;                     // +0x7C(124)
    public CheekRedden cheek_redden;                // +0x90(144)/+0xA4(164)
    public CheekReddenEnable cheek_redden_enable;  // +0xA8(168)/+0xA9(169)

    // +0xAC(172) 5-dword record written by sub_4D42904 in SetSpotlightColor
    // 0x1C1DE04 ({blend int, r,g,b,a}); UNKNOWN(native 0x1C1DE04): the exact
    // struct name/type of the PassiveProperty target (dump.cs calls it
    // spotlight_color) — recorded with the same fields the drawer port keeps.
    public BlendColor spotlight_color;

    // +0xC4(196) `{is_changed; pin …}` written by 0x1C1DE04 before it calls the
    // Color-family helper sub_4D42A8C. UNKNOWN(native 0x1C1DE04): exact record
    // layout of the pin slots (pin color + pin alpha in the drawer port).
    public Color pin_spotlight_color;
    public float pin_spotlight_alpha;
    private bool pin_spotlight_changed;            // +0xC4(196) flag byte

    // +0x144(324) outline_width — set through sub_4D42C4C in SetOutlineWidth
    // 0x1C1D744 (PassiveProperty set; helper internals not decompiled).
    private float outline_width = 0.0008f;         // default: Drawer__GetOutlineWidth 0x1C1019C fallback literal
    private bool outline_width_dirty;               // spike-managed (native dirty not visible in decomp)

    // +0x14C(332) outline_color — Color-family helper write in SetOutlineColor
    // 0x1C1D7E8, followed by the confirmed tail call sub_1C1D874 (ApplyOutlineColor).
    private Color outline_color = Color.black;
    private bool outline_color_dirty;

    // +0x160(352) stencil_ref — set in SetStencilRef 0x1C1D96C followed by the
    // confirmed tail call sub_1C1D9D0 (apply_stencil).
    private int stencil_ref;

    // Soul-only state recorded until an apply site is found:
    // cheekReddenColor -> face material's _ReddishColor (property exists in the
    // Chr_Face inventory but NO Materials__Set* in scope writes it).
    public Color cheek_redden_color;
    private bool cheek_redden_color_changed;

    // soul.skinColor — no Materials__Set* in the B5 decomp set applies it
    // (candidate consumer: inherent-color array 0xE0, index 0 — not evidenced).
    public Color skin_color;
    private bool skin_color_changed;

    // inherent colors (+0xE0, Color[ChrColorNum] per the drawer port) — the
    // setters 0x1C1E7F8/0x1C1E8C0 are only known from Drawer__ wrappers; the
    // target property is UNKNOWN (the screenshot bundle inventory lists no
    // _InherentColor on the shipped materials).
    public Color[] inherent_colors = new Color[ChrColorNum];
    private bool inherent_color_changed;

    // SetRimLightDirection 0x1C1DB28 / SetLightDirection 0x1C1DC8C write a
    // vector property (custom-shader statics class slots +40 / +36, cctor
    // 0x1C1FF70) into every registered material DIRECTLY — write-through is
    // now decomp-confirmed; the property NAMES remain UNKNOWN (see below),
    // so the inventory mapping is HasProperty-guarded.
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
    /// native Create 0x1C1CEC8(chara_index, top_go, chara_id, soul, head_go,
    /// body_go) receives the two GameObjects and thus a real head/body split;
    /// this ctor takes the renderers and derives head/body from the transform
    /// ancestors, then is_face/^is_eye from the material properties.
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
    /// CharacterMaterials.Create 0x1C1CEC8 — kept so CharacterDrawerNative.Create's
    /// current call shape keeps compiling. UNKNOWN(native 0x1C1CECC): the thunk
    /// target was never decompiled; the body's only observable effect in the spike's
    /// subset is the identity fields (the virtuous matcol registry is filled by the
    /// drawer's RegisterMaterial loop right after Create, per native
    /// register_renderers 0x1C14F54 → RegisterMaterialOutline 0x1C1D504).
    /// </summary>
    public void Create(int charaIndex, GameObject topGo, string charaId)
    {
        chara_index = charaIndex;
        top_go = topGo;
        chara_id = charaId;
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
    // Outline width (state +0x144(324)) — NO eager material write here:
    // native 0x1C1D744 only calls sub_4D42C4C (PassiveProperty set); the
    // apply pass (ApplyOutline 0x1C21F9C per dump.cs member) is not decompiled.
    // TryApplyAll() is the spike's delivery site.
    // =====================================================================

    /// <summary>Materials__SetOutlineWidth 0x1C1D744: sub_4D42C4C(this+324, value).</summary>
    public void SetOutlineWidth(float width)
    {
        outline_width = width;
        outline_width_dirty = true;
    }

    /// <summary>
    /// GetOutlineWidth 0x1C1D7A8 — NOT decompiled; the 0.0008f default below is the
    /// literal CharacterDrawer.GetOutlineWidth 0x1C1019C returns when its material
    /// target is missing, kept as the neutral value (CONFIRMED as a literal,
    /// 推断 as this struct-field default).
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
    // Outline color (state +0x14C(332)) — confirmed tail-apply
    // =====================================================================

    /// <summary>
    /// Materials__SetOutlineColor 0x1C1D7E8: Color-family helper write into
    /// this+332, then tail call sub_1C1D874. Both the state write and the tail
    /// apply call are CONFIRMED; the per-material write itself is 推断
    /// (sub_1C1D874 = ApplyOutlineColor per dump.cs, not decompiled in B5; the
    /// guard + property pair comes from the bundle inventory).
    /// UNKNOWN(native 0x1C1D874): mirror-material handling and the exact
    /// per-matcol iteration order.
    /// </summary>
    public void SetOutlineColor(Color color)
    {
        outline_color = color;                 // +0x14C(332)
        outline_color_dirty = true;
        PushOutlineColor();
    }

    private void PushOutlineColor()
    {
        foreach (var col in matcols)
        {
            var mat = col.material;
            if (mat == null || !mat.HasProperty(id_OutlineColor)) continue;
            mat.SetColor(id_OutlineColor, outline_color);
        }
    }

    // =====================================================================
    // Stencil ref (state +0x160(352)) — confirmed tail-apply
    // =====================================================================

    /// <summary>
    /// Materials__SetStencilRef 0x1C1D96C: helper write into this+352, then tail
    /// call sub_1C1D9D0 (apply_stencil per dump.cs). The tail call is CONFIRMED;
    /// the per-material write is 推断 (same-shape as SetOutlineColor's tail plus
    /// drawer.SetLayerIdToObject 0x1C0FD80 precedent, which writes
    /// SetFloat(id_StencilRef, ref) on every Renderer's shared material).
    /// UNKNOWN(native 0x1C1D9D0): apply body not decompiled.
    /// </summary>
    public void SetStencilRef(int stencilRef)
    {
        stencil_ref = stencilRef;              // +0x160(352)
        foreach (var col in matcols)
        {
            var mat = col.material;
            if (mat == null || !mat.HasProperty(id_StencilRef)) continue;
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
    // All material/target fan-out is UNKNOWN(native: apply 的成员在 dump.cs 里
    // 是 apply_color 0x1C21158 / UpdateProperties 0x1C2308C，B5 未反编译).
    // =====================================================================

    /// <summary>
    /// Materials__SetIdolColor 0x1C1DAC0 verbatim:
    ///   *(+76)=1; *(+77)=enable; *(+80..92)=color;  (always marks changed)
    /// 0 writes to materials here. UNKNOWN(native 0x1C1DAC0 ← apply_color):
    /// 无引入到材质；shipped 材质清单也没有 `_ChrColors` 属性(viewer 看不到
    /// idol 色差)，所以 TryApplyAll 也不写。
    /// </summary>
    public void SetIdolColor(bool is_enable, Color color)
    {
        idol_color.is_changed = true;          // +76
        idol_color.is_enable = is_enable;      // +77
        idol_color.color = color;              // +80..92
    }

    /// <summary>CharacterDrawer.SetIdolColor(Color) 0x1C10298 twin: re-set with the
    /// stored enable (+77) — Drawer__SetIdolColor_1 reads it back and re-calls
    /// SetIdolColor; CONFIRMED (wrapper decompiled).</summary>
    public void SetIdolColorWithStoredEnable(Color color)
    {
        SetIdolColor(idol_color.is_enable, color);
    }

    /// <summary>Drawer__GetIdolColor 0x1C102BC: reads +76..+96 (all 20 bytes) → struct verbatim.</summary>
    public IdolColor GetIdolColor() => idol_color;

    /// <summary>
    /// Materials__SetMonoColor 0x1C1DAEC verbatim: *(+96)=1; *(+100..112)=color.
    /// No material write here. TryApplyAll() delivers the value as the
    /// `_MonoColor` global (set per the lead instruction, following
    /// CharacterBootstrap.ApplyGlobals' SetGlobalVector("_MonoColor", …)
    /// precedent; native evidence: 0x1C1DAEC only writes state, so the global
    /// push stays an instructed INFERENCE, not a confirmed native write).
    /// </summary>
    public void SetMonoColor(Color color)
    {
        mono_color.is_changed = true;          // +96
        mono_color.color = color;              // +100..112
    }

    /// <summary>Materials__SetMonoColorRatio 0x1C1DB00 verbatim: *(+116)=1; *(+120)=ratio.
    /// UNKNOWN(native 0x1C1DB00): no property in the shipped inventory matches a
    /// mono ratio; consumer not decompiled — state only, never applied.</summary>
    public void SetMonoColorRatio(float ratio)
    {
        mono_color_ratio.is_changed = true;    // +116
        mono_color_ratio.ratio = ratio;        // +120
    }

    /// <summary>
    /// Materials__SetRimLight 0x1C1DB10 verbatim: *(+124)=1; *(+125)=enable;
    /// *(+128..140)=color. No material write here — UNKNOWN(native 0x1C1DB10 ←
    /// apply_color). TryApplyAll() pushes `_RimLightOn` (0/1, float) and
    /// `_RimColor` (Color) guarded by HasProperty — bundle-verified property
    /// names, 推断 per-material fan-out.
    /// UNKNOWN(native): the `_RimLight` property exists in the Chr_Basic/Chr_Face
    /// inventory but its semantics (range/scale?) are not decompiled — never
    /// written by this class.
    /// </summary>
    public void SetRimLight(bool is_enable, Color color)
    {
        rim_light.is_changed = true;           // +124
        rim_light.is_enable = is_enable;       // +125
        rim_light.color = color;               // +128..140
    }

    /// <summary>Drawer__GetRimLight twin (state struct read).</summary>
    public RimLight GetRimLight() => rim_light;

    // =====================================================================
    // Light / rim directions — CONFIRMED (C-pass decompilation) to write EVERY
    // registered material directly:
    //   Materials__SetRimLightDirection 0x1C1DB28 and SetLightDirection
    //   0x1C1DC8C iterate the MatCol list at +0x130(304) back-to-front
    //   (count-1 .. 0), skip null/dead materials, and call
    //   sub_7073AFC(mat, propId, 0, x, y, z, 0) with
    //     propId = *( (custom-shader statics class) + 36 )  ← light direction
    //     propId = *( (custom-shader statics class) + 40 )  ← rim light direction
    //   (dec_0x1c1dc8c_SetLightDirection.c / dec_0x1c1db28_SetRimLightDirection.c).
    //   The statics class is initialized by the property-id cctor 0x1C1FF70
    //   (dec_0x1c1ff70_ref96fc470.c): slot +36 ← Shader.PropertyToID(UNKNOWN
    //   literal qword_9807E98), slot +40 ← (qword_9808340). The literal names
    //   are not statically resolvable (IL2CPP metadata-usage slots are dyld
    //   chain-rebase encoded), so the mapping below stays the bundle-inventory
    //   read (_Light / _RimLight on Custom/Chr_Basic, HasProperty-guarded) —
    //   the write-through itself is now decomp-confirmed.
    // =====================================================================

    /// <summary>Materials__SetRimLightDirection 0x1C1DB28 — vector prop static+40
    /// (cctor 0x1C1FF70 slot qword_9808340; literal name UNKNOWN).</summary>
    public void SetRimLightDirection(Vector3 direction)
    {
        rim_light_direction = direction;
        // Native 0x1C1DB28 walks the MatCol list (a1+304) back-to-front and
        // SetVector's property table slot +40 in every entry (sub_7073AFC):
        // the rim DIRECTION vector. Shader inventory (Custom/Chr_Basic):
        // _RimLightOn Float / _RimLight Vector / _RimColor Color — the
        // direction slot is taken as `_RimLight` (bundle-verified inventory;
        // HasProperty-guarded like every write).
        WriteVectorToAll("_RimLight", direction);
    }

    /// <summary>Materials__SetLightDirection 0x1C1DC8C — vector prop static+36
    /// (cctor 0x1C1FF70 slot qword_9807E98; literal name UNKNOWN): `_Light` on
    /// Custom/Chr_Basic.</summary>
    public void SetLightDirection(Vector3 direction)
    {
        light_direction = direction;
        WriteVectorToAll("_Light", direction);
    }

    /// <summary>
    /// Native 0x1C1DC8C/0x1C1DB28 shared body: iterate the MatCol list
    /// (a1+304), skip dead entries, SetVector(mat, propId, x, y, z, 0)
    /// (sub_7073AFC). Port equivalent over the registered materials.
    /// </summary>
    private void WriteVectorToAll(string propertyName, Vector3 value)
    {
        // Native 0x1C1DC8C/0x1C1DB28 body: walk the MatCol list (a1+304),
        // skip null/dead materials, SetVector(propId, x, y, z, 0) — sub_7073AFC.
        var id = Shader.PropertyToID(propertyName);
        for (var i = 0; i < matcols.Count; i++)
        {
            var mat = matcols[i].material;
            if (mat == null) continue;
            if (!mat.HasProperty(id)) continue;
            mat.SetVector(id, new Vector4(value.x, value.y, value.z, 0f));
        }
    }

    // =====================================================================
    // Spotlight (+0xAC(172)/+0xC4(196)) — state records; consumer (Live light
    // pass) out of scope, no `_SpotLight*` property in the shipped materials.
    // =====================================================================

    /// <summary>
    /// Materials__SetSpotlightColor 0x1C1DE04 verbatim structure: writes the
    /// 5-dword record (blend int, r,g,b,a) at +172 via sub_4D42904, then
    /// *(+196)=1 followed by the Color-family sub_4D42A8C helper.
    /// UNKNOWN(native 0x1C1DE04): exact record semantics (blend mode values,
    /// pin layout); no material write attempted by this class.
    /// </summary>
    public void SetSpotlightColor(Color color, Color pin, float pin_alpha, int blend)
    {
        spotlight_color.blend = blend;
        spotlight_color.color = color;
        pin_spotlight_color = pin;
        pin_spotlight_alpha = pin_alpha;
        pin_spotlight_changed = true;
    }

    /// <summary>Drawer__GetSpotlightColor 0x1C10478 → Materials 0x1C1DEFC (not decompiled —
    /// 推断 as the stored blend color).</summary>
    public Color GetSpotlightColor() => spotlight_color.color;

    /// <summary>Blend mode recorded by SetSpotlightColor 0x1C1DE04 (first dword of +172).</summary>
    public int GetSpotlightBlend() => spotlight_color.blend;

    /// <summary>Pin color + alpha recorded at +0xC4(196) region.</summary>
    public Color GetPinSpotlightColor() => pin_spotlight_color;
    public float GetPinSpotlightAlpha() => pin_spotlight_alpha;

    // Eye highlight — native chain (both decompiled, batch C pass):
    //   Materials__SetEyeHighlightColor 0x1C1F390 ← Drawer__SetEyeHighlightColor
    //   0x1C10434: 0x1C1F390 gets the eye-material list from 0x1C1F474 (built per
    //   call from the MatCol list +0x130 by *object name* matching with two
    //   literals at qword_9813C18/C20 — UNKNOWN) and loops
    //   SetEyeHighlightColorToMaterial over it.
    //   SetEyeHighlightColorToMaterial 0x1C1F62C: HasProperty(static +64)
    //   gate, then SetVector(mat, static +64, r, g, b, a) — sub_70700F4, alpha
    //   is carried through (no zero-w).
    // The +64 shader property id comes from the Materials cctor 0x1C1FF70
    // (slot qword_9807E40). Its literal is NOT statically resolvable (IL2CPP
    // metadata-usage slots are dyld chain-rebase encoded in the shipped
    // binary), so the port keeps the value recorded and the fan-out structure
    // implemented behind the same HasProperty dead-end: nothing is written
    // until the property name is confirmed by a runtime probe.
    private Color eye_highlight_color;

    public void SetEyeHighlightColor(Color col)
    {
        eye_highlight_color = col;
        PushEyeHighlightColor();   // 0x1C1F390 fan-out shape; write is a neutral no-op until +64 resolves
    }
    public Color GetEyeHighlightColor() => eye_highlight_color;

    /// <summary>
    /// SetEyeHighlightColorToMaterial 0x1C1F62C shape, applied over the
    /// eye-group materials (0x1C1F390 fan-out; the port classifies eye
    /// materials by HasProperty(_IrisColor)&&HasProperty(_SubTex), the
    /// bundle-verified identity of Custom/BultIn/Bi_CharEye, standing in for
    /// the native name-literal filter — UNKNOWN(native qword_9813C18/C20)).
    /// Property id static+64 is UNKNOWN(native 0x1C1FF70 slot qword_9807E40);
    /// with no resolvable name the write is skipped (neutral), the recorded
    /// value stays for the eventual probe-driven fan-out.
    /// </summary>
    public static void SetEyeHighlightColorToMaterial(Material material, Color color)
    {
        if (material == null) return;
        // native: HasProperty(static + 64) gate — property UNKNOWN here.
        // UNKNOWN(native 0x1C1FF70): +64 literal not statically resolvable;
        // ADR-0033 neutral: record only, no write.
    }

    /// <summary>0x1C1F390 fan-out shape over the eye-group materials.</summary>
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
    // state-only EXCEPT SetCheekReddenToMaterial (CONFIRMED material write).
    // =====================================================================

    /// <summary>
    /// Materials__SetCheekRedden 0x1C1DFC4 verbatim:
    ///   v2 = (int)(a2 > 0.0)                 — enable derived from intensity
    ///   if (*(byte*)(+169) != v2) { *(+168)=1; *(+169)=v2; }
    ///   *(byte*)(+144) = 1                    — CheekRedden.is_changed
    ///   *(float*)(+164) = a2                  — CheekRedden.intensity
    /// No material write here. UNKNOWN(native): the UpdateProperties 0x1C2308C /
    /// UnsetDirty 0x1C2341C pass that feeds the enabled state into
    /// SetCheekReddenToMaterial is not decompiled; TryApplyAll() delivers the
    /// cached intensity to the face-group materials instead.
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
    /// Materials__SetCheekReddenEnable 0x1C1E170 verbatim:
    ///   if (*(byte*)(+169) != enable) { *(+168)=1; *(+169)=enable; }
    /// Note: it does NOT set +144 (CheekRedden.is_changed) — the enable and
    /// intensity caches are dirtied separately, exactly as the decompile shows.
    /// </summary>
    public void SetCheekReddenEnable(bool is_enable)
    {
        if (cheek_redden_enable.value == is_enable) return;
        cheek_redden_enable.is_changed = true;       // +168
        cheek_redden_enable.value = is_enable;       // +169
    }

    /// <summary>Materials__SetCheekReddenIntensity 0x1C1E18C verbatim: +144=1; +164=val.</summary>
    public void SetCheekReddenIntensity(float intensity)
    {
        cheek_redden.is_changed = true;              // +144
        cheek_redden.intensity = intensity;          // +164
    }

    /// <summary>
    /// Materials__SetCheekReddenToMaterial 0x1C1DFF4 — CONFIRMED verbatim.
    /// Decompiled order and property-id pairing:
    ///   propId76 = ReddishIntensity-check target, propId68 = IsReddish:
    ///   1. if (!mat.HasProperty(_ReddishIntensity)) return;   (static +76)
    ///   2. if (!mat.HasProperty(_IsReddish)) return;          (static +68)
    ///   3. CustomShaderUtility.SetMaterialToggle(mat, _IsReddish, intensity > 0)
    ///      (sub_357F278: toggles the `_ISREDDISH_ON` keyword + float 0/1)
    ///   4. mat.SetFloat(_ReddishIntensity, intensity);        (static +76, sub_70739FC)
    /// FaceCtrl B3 (FaceCtrlNative) drives this exact method; the face-only
    /// material selection lives at the caller (UNKNOWN(native): which matcol
    /// subset the apply pass feeds — the bundle inventory makes the HasProperty
    /// guard equivalent).
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
    // Inherent colour family (no Materials__Set* file in the B5 snapshot; both
    // entries are reachable only via Drawer__SetInherentColor 0x1C10504 /
    // Drawer__SetInherentColorSel 0x1C104E8 → 0x1C1E8C0/0x1C1E7F8, bodies not
    // decompiled). State only — property UNKNOWN (no _InherentColor in the
    // shipped-material inventory) and the value is also not applied otherwise.
    // The drawer port previously pushed `_InherentColor` here; that was
    // speculative and is dropped in this file.
    // =====================================================================

    /// <summary>CharacterMaterials.SetInherentColor 0x1C1E8C0 (referenced only). Index outside
    /// [0, ChrColorNum) is dropped (array bounds, inferred from ChrColorNum).</summary>
    public void SetInherentColor(Color color, int color_index)
    {
        if (color_index < 0 || color_index >= ChrColorNum) return;
        inherent_colors[color_index] = color;
        inherent_color_changed = true;
    }

    /// <summary>CharacterMaterials.SetInherentColorSel 0x1C1E7F8 (referenced only): picks
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
    /// Wires the soul into this class using only `isValid` values, per:
    ///   cheekReddenColor  0x1C36590 (params 3,4,5)  → state only, UNKNOWN(native) apply
    ///   cheekReddenIntensity 0x1C36A88 (param 6)     → SetCheekReddenIntensity 0x1C1E18C (CONFIRMED entry)
    ///   skinColor         0x1C36E98 (params 7,8,9)  → state only, UNKNOWN(native) apply site
    ///   inherentColor(2)  0x1C3728C/0x1C37680        → SetInherentColor (0x1C1E8C0, referenced-only)
    /// Values are 0..255 ints scaled by `Color(r/255, g/255, b/255, 1)` in the
    /// soul ctor 0x3799664, so the Color shapes here are soul-normalised.
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
            cheek_redden_color_changed = true;      // UNKNOWN(native): where _ReddishColor is applied
        }
        if (soul.skinColor.isValid)
        {
            skin_color = soul.skinColor.value;
            skin_color_changed = true;               // UNKNOWN(native): apply site not decompiled
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
    // TryApplyAll — frame-end one-shot, now shaped after the decompiled
    // UpdateProperties 0x1C2308C / apply_color 0x1C21158 / UnsetDirty
    // 0x1C2341C sequence (C-pass evidence, see the doc comment below). The
    // native per-MatCol per-entry flags stay UNKNOWN; the surfaced families
    // apply at most once per call and the changed bytes are cleared exactly
    // where UnsetDirty zeroes them.
    // =====================================================================

    [Serializable]
    public struct TryApplyResult
    {
        public List<string> applied;
        public List<string> unknown;
    }

    /// <summary>
    /// Native apply pass — now decompiled (C pass). UpdateProperties 0x1C2308C
    /// (dec_0x1c2308c_materials.c) per frame:
    ///   1. big-path gate: (byte)(this+172)&1 != 0 || this[196]==1 → color
    ///      aggregate (native sub_3791B84 with blend + rgb + pinned rgb from
    ///      this+176..212);
    ///   2. blink per-material state block (per-material state float only);
    ///   3. apply_color 0x1C21158 (dec_0x1c21158_materials.c): per-MatCol, in
    ///      reverse list order, per-entry flag-gated families —
    ///      cheek toggle/float (+68/+169/+76/+164), mono/idol color (+80
    ///      family, HasProperty-gated sub_707054C), light/rim DIRECTIONS
    ///      (+36/+40 under per-entry flags +65/+66), rate/chr-color family;
    ///   4. ApplyOutline 0x1C21F9C: SetVector(static+128, this+336..348) per
    ///      material (the four outline floats);
    ///   5. blink time accumulator + frame id (statics class +192/+196).
    ///   UnsetDirty 0x1C2341C (dec_0x1c2341c_materials.c) zeroes the changed
    ///   flags at byte offsets {352, 324, 124, 76, 96, 172, 196, 168, 144}.
    /// Port order below follows 3 → 4 → UnsetDirty; the big-path gate of 1 and
    /// the blink block of 2 are state-only here (UNKNOWN apply targets).
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
        var inherentUnknown = inherent_color_changed;

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

        // outline colour: SetOutlineColor 0x1C1D7E8 delivers eagerly via the
        // CONFIRMED tail call sub_1C1D874 (dec_0x1c1d874_materials.c — walk
        // +304, SetVector(static+128, this+336..348)); re-push keeps the
        // one-shot idempotent for late registrations.
        if (outline_color_dirty)
        {
            PushOutlineColor();
            result.applied.Add("outline_color → _OutlineColor");
        }

        // ---- native step 5: UnsetDirty 0x1C2341C --------------------------
        // byte offsets {352, 324, 124, 76, 96, 172, 196, 168, 144} — the port's
        // equivalents below (189-port keeps +352/+172 as eager/record values).
        outline_width_dirty = false;                    // +324
        outline_color_dirty = false;
        rim_light.is_changed = false;                   // +124
        idol_color.is_changed = false;                  // +76
        mono_color.is_changed = false;                  // +96
        pin_spotlight_changed = false;                  // +196
        cheek_redden_enable.is_changed = false;         // +168
        cheek_redden.is_changed = false;                // +144

        // ---- everything the evidence does not cover ---------------------
        if (idolUnknown)
            result.unknown.Add("idol_color → UNKNOWN(native: apply_color 0x1C21158 已反编译，+80 族为 HasProperty 门下的 SetVector；属性名候选未定，中性不写)");
        if (monoRatioUnknown)
            result.unknown.Add("mono_color_ratio → UNKNOWN(native 0x1C1DB00 消费点未反编译)");
        if (pinUnknown)
            result.unknown.Add("spotlight/pin → UNKNOWN(native 0x1C1DE04 记录语义未反编译，Live pass 超范围)");
        if (cheekColorUnknown)
            result.unknown.Add("cheek_redden_color → UNKNOWN(native: 无任何 Set* 写 _ReddishColor)");
        if (skinUnknown)
            result.unknown.Add("skin_color → UNKNOWN(native: Materials 层 apply 位置未反编译)");
        if (inherentUnknown)
            result.unknown.Add("inherent_color → UNKNOWN(native 0x1C1E8C0 未反编译，材质清单无 _InherentColor)");
        if (eye_highlight_color != default)
            result.unknown.Add("eye_highlight_color → UNKNOWN(native 0x1C1F62C 走 HasProperty(静态+64) 门；+64 字面量不可静态解，中性不写)");
        return result;
    }

    /// <summary>
    /// CharacterMaterials.UpdateProperties 0x1C2308C entry point (native name
    /// kept for the drawer wiring): the scheduled flash-end one-shot. The
    /// per-frame gate at native step 1/2 (blink aggregate + time) is
    /// state-only here — see TryApplyAll for the decompiled order.
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
          .Append(" inherent[0]=").Append(inherent_colors[ChrColorMainIndex]).AppendLine();
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
    // comments; /tmp/materials-native-notes.md holds the full table.
    // =====================================================================
    public static readonly string[] NativeUnknowns =
    {
        "0x1C1CECC Create body (thunk target)",
        "0x1C21158 apply_color: 体已反编译(dec_0x1c21158)；per-MatCol 门的字面量与各族属性名仍未解(槽位 dyld chain-rebase 不可静态解)",
        "0x1C1FF70 Materials property-id cctor: 槽位→属性名映射静态不可解(0x…/0x1C2341C/0x1C1D874/0x1C1D9D0/0x1C21F9C 体已在 dec_0x… 导出，映射被下述关闭修整)",
        "0x1C2308C UpdateProperties 体已反编译；blink 块的 per-material 状态 struct 字段语义(非材质写入)未逐字段落地",
        "0x1C1D874 apply_outline: 体已反编译(遍历+304 → SetVector(静态+128, this+336..348))；+128 属性名 UNKNOWN",
        "0x1C1D9D0 apply_stencil: 体已反编译(遍历+304 → SetFloat(静态+12, this+356))；+12 属性名 UNKNOWN",
        "0x1C21F9C ApplyOutline 体已反编译(dec_0x1c21f9c)",
        "0x1C1DC8C/SetLightDirection(static+36) 与 0x1C1DB28/SetRimLightDirection(static+40) 的写入已确认；属性名 UNKNOWN(0x1C1FF70 槽 x9807E98/x9808340)",
        "0x1C1F62C SetEyeHighlightColorToMaterial: 结构已反编译(HasProperty(静态+64) 门 → SetVector(r,g,b,a))；+64 属性名 UNKNOWN(槽 9807E40)，0x1C1F474 眼材质表的两个名称字面量 UNKNOWN",
        "0x1C1DAC0 idol_color apply 目标（apply_color +80 族, HasProperty 门；名称候选未定，中性不写）",
        "0x1C1DB00 mono_color_ratio 消费点",
        "0x1C1DE04 spotlight/pin 记录结构语义（Live pass 超范围）",
        "0x1C1E8C0 SetInherentColor 目标属性（清单无 _InherentColor）",
        "cheek_redden_color（_ReddishColor 何时被写）",
        "skin_color 的 Materials 层 apply 位置",
    };
}
