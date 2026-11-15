// Native-faithful port of the *character-body* subset of CharacterDrawer (ADR-0033 B5):
//   CharacterDrawer            dump.cs TypeDefIndex 14986
//   CharacterDrawer.RendererAndMaterials      14979
//   CharacterDrawer.SubMesh                   14978
//   CharacterDrawer.Config                    14980
//   CharacterMaterials         dump.cs TypeDefIndex 15017 (the part the subset writes)
//   CharacterManager.ZShift    dump.cs TypeDefIndex 9549
//
// Scope (audit §2.5 P2-8): outline width/colour, idol colour, mono, rim light, z-shift
// face/other, cheek redden, eye highlight, spotlight, LOD / skin quality / layer /
// sub-mesh visibility, and the FaceCtrl -> CharacterDrawer cheek callback.
//
// OUT OF SCOPE (Live rendering pipeline, listed so the gap stays explicit — every one
// of these methods exists in the native class and is NOT ported here):
//   CreateDrawCommands 0x1C10A74, create_draw_separated_command 0x1C110DC,
//   create_draw_optimized_command 0x1C10E24, CreateDrawCommands_OutlineOnly 0x1C116E0,
//   CreateDrawCommands_OutlineOnly_torso 0x1C11F0C, create_draw_separated_command_torso 0x1C10B5C,
//   updateMirroredObjs 0x1C1094C, createMirrorMaterials 0x1C13D88, createMirrorMaterial 0x1C12F4C,
//   destroyMirrorMaterials 0x1C17D14, setupMirroredItems 0x1C149B8, createDepthMaterial 0x1C172DC,
//   add_outline_sub_meshes 0x1C178E4, add_outline_sub_meshes_torso 0x1C17570,
//   OptimizeHead 0x1C121F8 / DeOptimizeHead 0x1C1296C / OptimizeBody 0x1C12BB0 /
//   DeOptimizeBody 0x1C131C0, find_sub_mesh_by_category 0x1C12EFC, find_sub_meshes_by_category 0x1C125C0,
//   add_merged_sub_meshes 0x1C12738, FindSpotRenderers 0x1C133D0, align_spot_materials 0x1C1464C,
//   RegisterMaterialToGlobalColorCtrl 0x1C13720, drawCharaItems 0x1C17024, findCharaItems 0x1C16DD0,
//   create_additional_uv 0x1C16840, find_no_outline_shader 0x1C17408, Rebuild 0x1C17EBC,
//   EndMeshModify 0x1C106B4, RemoveTangents/RevertTangents 0x1C0F954/0x1C0FA74,
//   SetLayerCameraToObject 0x1C0FEC4, SetLoadResourceFromBundle 0x1C1068C,
//   LateUpdate 0x1C18838, OnDestroy 0x1C1890C, pre_create/post_create 0x1C14E70/0x1C15BA8.
//
// SPIKE-MAPPING (not native): the native class expresses visibility/outline/sub-mesh
// visibility by *skipping draw commands* inside its CommandBuffer passes. The spike
// renders through the normal pipeline, so the same recorded state is additionally
// pushed to the closest Unity switch (Renderer.enabled / SubMesh mask / `_Outline` = 0).
// State, API and defaults stay native; only the delivery target differs. Every such
// site is marked SPIKE-MAPPING in the comments.
//
// Material property names below are ground truth from the shipped bundles
// (cb_ss003_001har / ch_ss003_001har material inventory), never from guesswork:
//   Custom/Chr_Basic        : _Outline _OutlineColor _OutlineZadj _TanFov _Stencil
//                             _RimLightOn _RimLight _RimColor _ZShift1000Min/Max
//   Custom/Chr_Face         : _Outline _OutlineColor _Stencil _IsReddish _ReddishColor
//                             _ReddishIntensity _RimLightOn _RimLight _RimColor
//   Custom/BultIn/Bi_CharEye: _IrisColor _SubTex _Stencil
//   globals (CharacterBootstrap already sets the neutral values):
//                             _MonoColor _RimCtrl _Whiteness _Luminance

using System;
using System.Collections.Generic;
using System.Text;
using UnityEngine;

/// <summary>
/// The character-body subset of `CharacterDrawer` (dump.cs 14986).
///
/// Native object layout used here (IL2CPP offsets in parentheses):
///   m_layerId 0x20, onAdvancedCommu 0x24, visibleChangeEvent 0x28,
///   chara_index 0x34, camera_index 0x38, renmats 0x40, lod 0x48, quality 0x4C,
///   config 0x50 (8 bools), root_go 0x58, draw_info_head 0x60, draw_info_body 0x68,
///   eye_tracking 0x78, materials 0xB8, z_shift_min_array 0xC0, z_shift_max_array 0xC8,
///   drawer_eye 0xB0, isVisibleMirrorIdol 0xD1, itemRens 0xE8.
/// </summary>
public sealed class CharacterDrawerNative : MonoBehaviour, FaceCtrlNative.ICharacterDrawerSink
{
    // Native constants (dump.cs 14986).
    public const int MaxLOD = 1;
    public const int MIN_LAYER_STENCIL_REF = 2;
    public const float outlineWidthFactorThin = 0.5f;

    // =====================================================================
    // Nested native types
    // =====================================================================

    /// <summary>CharacterDrawer.Config (dump.cs 14980), field order preserved.</summary>
    [Serializable]
    public struct Config
    {
        public bool is_visible_external;        // 0x50
        public bool is_draw_outline_external;   // 0x51
        public bool is_draw_entity_external;    // 0x52
        public bool has_tangents;               // 0x53
        public bool is_body_optimized;          // 0x54
        public bool is_head_optimized;          // 0x55
        public bool is_as_torso;                // 0x56
        public bool isShadowCastEnabled;        // 0x57
    }

    /// <summary>CharacterDrawer.SubMesh (dump.cs 14978).</summary>
    [Serializable]
    public struct SubMesh
    {
        public Material material;
        public Material mirrorMaterial;
        public Material depthMaterial;
        public bool is_visible;
        public bool is_transparent;
        public bool has_outline;
        public bool use_extra_depth;
        public bool is_cutout;
        public int merge_type;      // CharacterDrawInfo.MergeType (not migrated)
        public int category;        // CharacterDrawInfo.SubMeshCategory (not migrated)
    }

    /// <summary>CharacterDrawer.RendererAndMaterials (dump.cs 14979).</summary>
    public sealed class RendererAndMaterials
    {
        public bool is_head;
        public SkinnedMeshRenderer renderer_;
        public SubMesh[] sub_meshes;
        public int sub_mesh_index_outline = -1;
        public int sub_mesh_index_low = -1;
        public int sub_mesh_index_merged = -1;
        public int sub_mesh_index_extra_depth = -1;
        public SkinQuality require_skin_quality;
        public bool thinOutline;

        public SkinnedMeshRenderer renderer
        {
            get { return renderer_; }
            set { renderer_ = value; }
        }
    }

    /// <summary>CharacterManager.ZShift (dump.cs 9549).</summary>
    [Serializable]
    public struct ZShift
    {
        public float min;
        public float max;

        public ZShift(float min, float max)
        {
            this.min = min;
            this.max = max;
        }
    }

    // Native z-shift slot indices, recovered from SetZShiftFace 0x1C6B090 /
    // SetZShiftOther 0x1C6B0D8 / GetZShiftCloth 0x1C6B118:
    //   SetZShiftFace  writes index 2 (array offset +40)
    //   SetZShiftOther writes index 0 (array offset +32)
    //   GetZShiftCloth reads index 1 (array offset +36)
    public const int ZSHIFT_OTHER = 0;
    public const int ZSHIFT_CLOTH = 1;
    public const int ZSHIFT_FACE = 2;

    // =====================================================================
    // Fields (dump.cs offsets in comments)
    // =====================================================================

    public int m_layerId;                              // 0x20
    public bool onAdvancedCommu;                       // 0x24
    public Action<bool> visibleChangeEvent;            // 0x28
    public int chara_index;                            // 0x34
    public int camera_index;                           // 0x38
    public readonly List<RendererAndMaterials> renmats = new List<RendererAndMaterials>(); // 0x40
    public int lod;                                    // 0x48
    public SkinQuality quality;                        // 0x4C
    public Config config;                              // 0x50
    public GameObject root_go;                         // 0x58
    public CharacterMaterialsNative materials;         // 0xB8
    public CharacterDrawerEyeNative drawer_eye;        // 0xB0
    public bool isVisibleMirrorIdol;                   // 0xD1
    /// <summary>Mirror/audience items whose layers ReloadDefaultLayers snapshots
    /// (native `mirroredItems` 0xD8 / `mirroredItemDefaultLayers` 0xE0). The spike has
    /// no mirror pass, so these stay empty unless a caller fills them.</summary>
    public GameObject[] mirroredItems;                 // 0xD8
    public int[] mirroredItemDefaultLayers;            // 0xE0
    /// <summary>The JointBodyHead this drawer belongs to (native Create argument, 0x1C13A84).</summary>
    public JointBodyHeadNative joint_body_head;

    /// <summary>`z_shift_min_array` 0xC0 / `z_shift_max_array` 0xC8 — length 3
    /// (other 0, cloth 1, face 2). Native allocates them in Create.</summary>
    public float[] z_shift_min_array = new float[3];
    public float[] z_shift_max_array = new float[3];

    /// <summary>Face material the cheek chain writes (native find_face_material 0x1C16C50).</summary>
    public Material faceMaterial;
    public SkinnedMeshRenderer faceRenderer;
    public Material[] eyeMaterials = Array.Empty<Material>();

    private bool created;

    /// <summary>True once <see cref="Create"/> ran (the native component is inert before).</summary>
    public bool IsCreated { get { return created; } }

    // =====================================================================
    // Create (constructor-side setup; native Create/Descriptor is trimmed to the
    // assembly the subset needs — the draw-command/material-optimisation half of
    // CharacterDrawer.Create is out of scope, see the header)
    // =====================================================================

    /// <summary>
    /// Binds the drawer to an already assembled character. Native entry points are
    /// `CharacterDrawer.Create(int, GameObject, string, GameObject, GameObject,
    /// JointBodyHead, CharacterDrawInfo, CharacterDrawInfo, …)` 0x1C13A84 and
    /// `Create(Descriptor)` 0x1C0DA64; both end in `register_renderers` 0x1C14F54
    /// (walk the model's SkinnedMeshRenderers, split sub-meshes, register materials),
    /// `find_eye_materials` 0x1C169B8 and `find_face_material` 0x1C16C50 — which is
    /// what this method reproduces. The `_drawInfo` half (CharacterDrawInfo categories,
    /// merged/outline sub-mesh indices, tangents) belongs to the draw pipeline.
    /// </summary>
    public void Create(int charaIndex, GameObject rootGo, string charaId, JointBodyHeadNative jointBodyHead)
    {
        chara_index = charaIndex;
        root_go = rootGo;
        joint_body_head = jointBodyHead;
        created = true;

        renmats.Clear();
        if (rootGo != null)
        {
            foreach (var rend in rootGo.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                if (rend == null) continue;
                var renmat = new RendererAndMaterials
                {
                    is_head = IsHeadRenderer(rend),
                    renderer_ = rend,
                    sub_meshes = new SubMesh[rend.sharedMaterials.Length],
                };
                for (var i = 0; i < renmat.sub_meshes.Length; i++)
                {
                    renmat.sub_meshes[i] = new SubMesh
                    {
                        material = rend.sharedMaterials[i],
                        is_visible = true,
                    };
                }
                renmats.Add(renmat);
            }
        }

        // CharacterMaterials 0x1C1CEC8 Create(chara_index, top_go, chara_id, soul,
        // head_go, body_go): native attaches the component to the top object and
        // registers every renderer material. The spike keeps it as a plain object.
        materials = new CharacterMaterialsNative();
        materials.Create(chara_index, rootGo, charaId);
        for (var i = 0; i < renmats.Count; i++)
        {
            var renmat = renmats[i];
            if (renmat.renderer_ == null) continue;
            foreach (var sm in renmat.sub_meshes)
            {
                if (sm.material == null) continue;
                materials.RegisterMaterial(sm.material, sm.mirrorMaterial,
                    force_skin: false,
                    outlineWidthFactor: renmat.thinOutline ? outlineWidthFactorThin : 1f);
            }
        }

        // find_eye_materials 0x1C169B8 / find_face_material 0x1C16C50.
        var eyes = new List<Material>();
        foreach (var renmat in renmats)
        {
            if (renmat.renderer_ == null) continue;
            foreach (var sm in renmat.sub_meshes)
            {
                if (sm.material == null) continue;
                if (sm.material.HasProperty("_IrisColor") && sm.material.HasProperty("_SubTex"))
                    eyes.Add(sm.material);
                else if (faceMaterial == null && sm.material.HasProperty("_IsReddish"))
                {
                    faceMaterial = sm.material;
                    faceRenderer = renmat.renderer_;
                }
            }
        }
        eyeMaterials = eyes.ToArray();

        drawer_eye = new CharacterDrawerEyeNative();

        // Native allocates the z-shift arrays in Create; the spike keeps the neutral
        // state until a caller (CharacterManager / probe) sets them.
        if (z_shift_min_array == null || z_shift_min_array.Length < 3) z_shift_min_array = new float[3];
        if (z_shift_max_array == null || z_shift_max_array.Length < 3) z_shift_max_array = new float[3];
    }

    private static bool IsHeadRenderer(SkinnedMeshRenderer rend)
    {
        // Native register_renderers 0x1C14F54 receives `is_head` from the descriptor;
        // it is not derivable from the renderer alone. The spike's head model is a
        // separate instantiated prefab named `ch_head` (CharacterBootstrap), so the
        // ancestor name is the equivalent signal.
        for (var t = rend.transform; t != null; t = t.parent)
            if (t.name == "ch_head") return true;
        return false;
    }

    // =====================================================================
    // Visibility / LOD / skin quality / layer / sub-meshes
    // =====================================================================

    /// <summary>
    /// CharacterDrawer.SetVisible 0x1C6A0E4: `config.is_visible_external = value;
    /// visibleChangeEvent?.Invoke(value);`. Nothing else happens in the native body.
    /// SPIKE-MAPPING: the flag is additionally pushed to Renderer.enabled because the
    /// spike has no draw-command pass to skip.
    /// </summary>
    public void SetVisible(bool is_visible)
    {
        config.is_visible_external = is_visible;
        visibleChangeEvent?.Invoke(is_visible);
        ApplyVisibleToRenderers();
    }

    /// <summary>
    /// CharacterDrawer.SetDrawOutline 0x1C6A114: `config.is_draw_outline_external = v;`
    /// (no other side effect in the binary).
    /// SPIKE-MAPPING: the outline is a shader pass inside the same material, so the
    /// flag is delivered as `_Outline = 0` / stored width.
    /// </summary>
    public void SetDrawOutline(bool is_draw_outline)
    {
        config.is_draw_outline_external = is_draw_outline;
        if (materials != null) materials.ApplyOutlineEnabled(is_draw_outline);
    }

    /// <summary>
    /// CharacterDrawer.SetDrawEntity 0x1C6A11C: `config.is_draw_entity_external = v;`
    /// No side effect in the binary. The entity/outline split is only meaningful to the
    /// command-buffer passes (out of scope), so this stays a pure state record — there
    /// is no Unity switch that removes "the entity" without also removing the outline.
    /// </summary>
    public void SetDrawEntity(bool is_draw_entity)
    {
        config.is_draw_entity_external = is_draw_entity;
    }

    /// <summary>
    /// CharacterDrawer.SetLODLevel 0x1C6A124: `if (lod <= 1) this.lod = lod;`
    /// (values above MaxLOD are ignored, not clamped).
    /// </summary>
    public void SetLODLevel(int lodLevel)
    {
        if (lodLevel <= MaxLOD) lod = lodLevel;
    }

    /// <summary>
    /// CharacterDrawer.SetSkinQuality 0x1C6A134 (decompiled):
    ///   quality (+0x4C/76) = value;
    ///   forward walk of renmats (+0x40) → if (item.renderer_ != null) set that
    ///   renderer's quality (sub_710AB64 = SkinnedMeshRenderer.set_quality).
    /// The body has NO `require_skin_quality` gate and does NOT call
    /// SkinQuality_To_Int 0x1C6A238 / Int_To_SkinQuality 0x1C6A258 — those are
    /// draw-pipeline helpers; the argument is stored as given.
    /// </summary>
    public void SetSkinQuality(SkinQuality skinQuality)
    {
        quality = skinQuality;                 // +0x4C(76)
        foreach (var renmat in renmats)
        {
            if (renmat.renderer_ == null) continue;
            // UNKNOWN(native 0x1C6A134): sub_710AB64's argument list was dropped
            // by Hex-Rays — `quality` is the only value in scope at that call.
            renmat.renderer_.quality = skinQuality;
        }
    }

    public static int SkinQuality_To_Int(SkinQuality q)
    {
        if ((int)q == 1) return 1;
        if ((int)q == 2) return 2;
        return 4;
    }

    public static SkinQuality Int_To_SkinQuality(int qualityAsInt)
    {
        if (qualityAsInt <= 1) return SkinQuality.Bone1;
        if (qualityAsInt == 2) return SkinQuality.Bone2;
        return SkinQuality.Bone4;
    }

    /// <summary>
    /// CharacterDrawer.SetSubMeshVisibleAll 0x1C6A690: `renmat.sub_meshes[i].is_visible
    /// = value` for every renderer and every sub-mesh (no other side effect in the
    /// binary — the value is read by `IsVisible` 0x1C1140C inside the draw passes).
    /// With the command-buffer path out of scope there is no Unity switch that hides a
    /// single sub-mesh while leaving the others drawn, so the state is recorded and NOT
    /// pushed; `GetSubMeshVisible` exposes it for the probe / the future draw pass.
    /// </summary>
    public void SetSubMeshVisibleAll(bool is_visible)
    {
        foreach (var renmat in renmats)
        {
            if (renmat.sub_meshes == null) continue;
            for (var i = 0; i < renmat.sub_meshes.Length; i++)
            {
                var sm = renmat.sub_meshes[i];
                sm.is_visible = is_visible;
                renmat.sub_meshes[i] = sm;
            }
        }
    }

    /// <summary>Sub-mesh visibility as recorded by SetSubMeshVisibleAll (per renderer).</summary>
    public bool GetSubMeshVisible(int renmatIndex, int subMeshIndex)
    {
        if (renmatIndex < 0 || renmatIndex >= renmats.Count) return false;
        var sub = renmats[renmatIndex].sub_meshes;
        if (sub == null || subMeshIndex < 0 || subMeshIndex >= sub.Length) return false;
        return sub[subMeshIndex].is_visible;
    }

    /// <summary>
    /// CharacterDrawer.SetLayerId 0x1C6A79C (decompiled):
    ///   m_layerId (+0x20/32) = id;
    ///   if (materials (+0xB8/184) != null) SetStencilRef(LayerIdToStencilRef(id))
    ///     → CharacterMaterials.SetStencilRef 0x1C785E4 (tail apply_stencil
    ///     0x1C78648: forward MatCol walk, SetFloat(_Stencil, ref), no guard);
    ///   then CharacterManager.Instance.RequestSortDrawer() (0x386CEEC, reached
    ///   through the MBSingleton statics at off_980F630) re-sorts the drawer after
    ///   the stencil change. The spike has no CharacterManager — this component is
    ///   driven directly by CharacterBootstrap/the probe — so the tail is
    ///   intentionally omitted rather than unknown.
    /// </summary>
    public void SetLayerId(int id)
    {
        m_layerId = id;                        // +0x20(32)
        if (materials != null) materials.SetStencilRef(LayerIdToStencilRef(id));
        // CharacterManager.Instance.RequestSortDrawer() 0x386CEEC — omitted (no
        // CharacterManager subsystem in the spike).
    }

    /// <summary>CharacterDrawer.LayerIdToStencilRef 0x1C6A7C4: id >= 0 ? id + MIN_LAYER_STENCIL_REF : 0.</summary>
    public static int LayerIdToStencilRef(int layerId)
    {
        return layerId >= 0 ? layerId + MIN_LAYER_STENCIL_REF : 0;
    }

    /// <summary>
    /// CharacterDrawer.SetLayerIdToObject 0x1C6A880: stencil ref = LayerIdToStencilRef,
    /// then for every Renderer in `go` (GetComponentsInChildren) and every shared
    /// material, `material.SetFloat(_Stencil, ref)` (HasProperty-guarded by the bundle
    /// inventory: _Stencil exists on Chr_Basic/Chr_Face/Bi_CharEye).
    /// </summary>
    public static void SetLayerIdToObject(int id, GameObject go)
    {
        var stencilRef = (float)LayerIdToStencilRef(id);
        if (go == null) return;
        foreach (var rend in go.GetComponentsInChildren<Renderer>(true))
        {
            if (rend == null) continue;
            foreach (var mat in rend.sharedMaterials)
            {
                if (mat == null) continue;
                if (mat.HasProperty("_Stencil")) mat.SetFloat("_Stencil", stencilRef);
            }
        }
    }

    // =====================================================================
    // Outline / colours
    // =====================================================================

    /// <summary>CharacterDrawer.SetOutlineWidth 0x1C6AC80 → materials.SetOutlineWidth
    /// 0x1C783BC (state only; apply site ApplyOutline 0x1C7CC14, out of batch).</summary>
    public void SetOutlineWidth(float width)
    {
        if (materials == null) return;
        materials.SetOutlineWidth(width);
    }

    /// <summary>
    /// CharacterDrawer.GetOutlineWidth 0x1C6AC9C: if the materials object is null or
    /// destroyed return the literal 0.0008f; otherwise materials.GetOutlineWidth
    /// 0x1C78420.
    /// </summary>
    public float GetOutlineWidth()
    {
        if (materials == null) return 0.0008f;
        return materials.GetOutlineWidth();
    }

    /// <summary>CharacterDrawer.SetOutlineColor 0x1C6AD60 → materials.SetOutlineColor
    /// 0x1C78460 (then ApplyOutlineColor 0x1C784EC, decompiled: forward MatCol walk,
    /// SetColor(_OutlineColor), no HasProperty guard).</summary>
    public void SetOutlineColor(Color color)
    {
        if (materials == null) return;
        materials.SetOutlineColor(color);
    }

    /// <summary>CharacterDrawer.SetIdolColor(bool, Color) 0x1C6AD7C → materials
    /// SetIdolColor 0x1C78738 (state record only).</summary>
    public void SetIdolColor(bool is_enable, Color color)
    {
        if (materials == null) return;
        materials.SetIdolColor(is_enable, color);
    }

    /// <summary>
    /// CharacterDrawer.SetIdolColor(Color) 0x1C6AD98: re-applies with the *stored*
    /// enable flag (`materials.idol_color`, set by 0x1C78738).
    /// </summary>
    public void SetIdolColor(Color color)
    {
        if (materials == null) return;
        materials.SetIdolColor(materials.GetIdolColor().is_enable, color);
    }

    /// <summary>CharacterDrawer.GetIdolColor 0x1C6ADBC → materials.idol_color.</summary>
    public CharacterMaterialsNative.IdolColor GetIdolColor()
    {
        return materials != null ? materials.GetIdolColor() : default;
    }

    /// <summary>CharacterDrawer.SetMonoColor 0x1C6ADE4 → materials SetMonoColor
    /// 0x1C78764 (state record only).</summary>
    public void SetMonoColor(Color color)
    {
        if (materials == null) return;
        materials.SetMonoColor(color);
    }

    /// <summary>CharacterDrawer.SetMonoColorRatio 0x1C6AE00 → materials
    /// SetMonoColorRatio 0x1C78778 (state record only; no id_MonoColorRatio exists).</summary>
    public void SetMonoColorRatio(float ratio)
    {
        if (materials == null) return;
        materials.SetMonoColorRatio(ratio);
    }

    /// <summary>CharacterDrawer.SetRimLight(bool, Color) 0x1C6AE1C → materials
    /// SetRimLight 0x1C78788 (state record only).</summary>
    public void SetRimLight(bool is_enable, Color color)
    {
        if (materials == null) return;
        materials.SetRimLight(is_enable, color);
    }

    /// <summary>
    /// CharacterDrawer.SetRimLightColor 0x1C6AE38: re-applies with the stored enable
    /// flag (same shape as SetIdolColor(Color)).
    /// </summary>
    public void SetRimLightColor(Color color)
    {
        if (materials == null) return;
        materials.SetRimLight(materials.GetRimLight().is_enable, color);
    }

    /// <summary>CharacterDrawer.SetRimLightEnable 0x1C6AE5C → materials.SetRimLight(enable, stored).</summary>
    public void SetRimLightEnable(bool is_enable)
    {
        if (materials == null) return;
        materials.SetRimLight(is_enable, materials.GetRimLight().color);
    }

    /// <summary>
    /// CharacterDrawer.SetRimLightDirection 0x1C6AE80 → CharacterMaterials
    /// SetRimLightDirection 0x1C787A0 (decompiled write-through): BACK-TO-FRONT walk
    /// of the MatCol list, SetVector(_RimLight, x, y, z, 0) on every material.
    /// </summary>
    public void SetRimLightDirection(Vector3 direction)
    {
        if (materials == null) return;
        materials.SetRimLightDirection(direction);
    }

    /// <summary>
    /// CharacterDrawer.SetLightDirection 0x1C6AE9C → CharacterMaterials
    /// SetLightDirection 0x1C78904 (decompiled write-through): BACK-TO-FRONT walk of
    /// the MatCol list, SetVector(_Light, x, y, z, 0) on every material.
    /// </summary>
    public void SetLightDirection(Vector3 direction)
    {
        if (materials == null) return;
        materials.SetLightDirection(direction);
    }

    // =====================================================================
    // Cheek redden (B3 FaceCtrl writes through ICharacterDrawerSink)
    // =====================================================================

    /// <summary>
    /// CharacterDrawer.SetCheekRedden 0x1C6AEE0 → CharacterMaterials.SetCheekRedden
    /// 0x1C78C3C (state record: enable = intensity > 0 only when changed, then the
    /// intensity cache; the material delivery is SetCheekReddenToMaterial 0x1C78C6C
    /// from the apply pass).
    /// </summary>
    public void SetCheekRedden(float intensity)
    {
        if (materials == null) return;
        materials.SetCheekRedden(intensity);
    }

    /// <summary>ICharacterDrawerSink — CharacterDrawer.SetCheekReddenEnable 0x1C6AEFC → 0x1C78DE8.</summary>
    public void SetCheekReddenEnable(bool enable)
    {
        if (materials == null) return;
        materials.SetCheekReddenEnable(enable);
    }

    /// <summary>ICharacterDrawerSink — CharacterDrawer.SetCheekReddenIntensity 0x1C6AF18 → 0x1C78E04.</summary>
    public void SetCheekReddenIntensity(float intensity)
    {
        if (materials == null) return;
        materials.SetCheekReddenIntensity(intensity);
    }

    // =====================================================================
    // Eye highlight / spotlight / inherent colours
    // =====================================================================

    /// <summary>
    /// CharacterDrawer.SetEyeHighlightColor 0x1C6AF34 → CharacterMaterials
    /// SetEyeHighlightColor 0x1C7A008, which fans out to
    /// SetEyeHighlightColorToMaterial 0x1C7A2A4 (decompiled: HasProperty(_IrisColor)
    /// gate, then SetColor(_IrisColor, colour including alpha)).
    /// </summary>
    public void SetEyeHighlightColor(Color col)
    {
        if (materials == null) return;
        materials.SetEyeHighlightColor(col);
    }

    /// <summary>
    /// CharacterDrawer.SetSpotlightColor 0x1C6AF50 → CharacterMaterials
    /// SetSpotlightColor 0x1C78A7C (decompiled: PassiveProperty&lt;BlendColor&gt; at
    /// +0xAC/+0xB0 and PassiveProperty&lt;Color&gt; at +0xC4/+0xC8; no character
    /// material is written). The consumption site is the Live-stage light pass — out
    /// of ADV scope; no `_SpotLight*` property exists in the shipped materials.
    /// </summary>
    public void SetSpotlightColor(Color color, Color pin, float pin_alpha, int blend)
    {
        if (materials == null) return;
        materials.SetSpotlightColor(color, pin, pin_alpha, blend);
    }

    public Color GetSpotlightColor()
    {
        return materials != null ? materials.GetSpotlightColor() : default;
    }

    public Color GetPinSpotlightColor()
    {
        return materials != null ? materials.GetPinSpotlightColor() : default;
    }

    public float GetPinSpotlightAlpha()
    {
        return materials != null ? materials.GetPinSpotlightAlpha() : 0f;
    }

    /// <summary>CharacterDrawer.SetInherentColor(sel, color_sel) 0x1C6AFE8 → materials
    /// SetInherentColorSel 0x1C79470.</summary>
    public void SetInherentColorSel(Imas.CharacterSoul soul, int color_sel)
    {
        if (materials == null) return;
        materials.SetInherentColorSel(soul, color_sel);
    }

    /// <summary>CharacterDrawer.SetInherentColor(color, index) 0x1C6B004 → materials
    /// SetInherentColor 0x1C79538 (decompiled: index 0..3, element write, forward
    /// MatCol fan-out to SetInherentColorToMaterial 0x1C796B0).</summary>
    public void SetInherentColor(Color color, int color_index)
    {
        if (materials == null) return;
        materials.SetInherentColor(color, color_index);
    }

    // =====================================================================
    // Z-shift (per-slot arrays; consumed by the out-of-scope depth draw path)
    // =====================================================================

    /// <summary>
    /// CharacterDrawer.SetZShiftFace 0x1C6B090: `z_shift_min_array[2] = z.min;
    /// z_shift_max_array[2] = z.max;` (bounds-checked, throws natively when the array
    /// is shorter than 3).
    /// </summary>
    public void SetZShiftFace(ZShift z_shift)
    {
        EnsureZShiftArrays();
        z_shift_min_array[ZSHIFT_FACE] = z_shift.min;
        z_shift_max_array[ZSHIFT_FACE] = z_shift.max;
    }

    /// <summary>CharacterDrawer.SetZShiftOther 0x1C6B0D8: index 0.</summary>
    public void SetZShiftOther(ZShift z_shift)
    {
        EnsureZShiftArrays();
        z_shift_min_array[ZSHIFT_OTHER] = z_shift.min;
        z_shift_max_array[ZSHIFT_OTHER] = z_shift.max;
    }

    /// <summary>
    /// CharacterDrawer.GetZShiftCloth 0x1C6B118 (decompiled): reads both arrays at
    /// this+0xC0/0xC8 (null → throw), requires length >= 2 in each (the native test is
    /// `(len &amp; 0xFFFFFFFE) == 0` → IndexOutOfRange for length 0/1), reads slot 1
    /// (`Arrays[1]`, data+36) and returns `new CharacterManager.ZShift(min[1], max[1])`
    /// (8-byte struct returned in x0/s0-s1 — Hex-Rays typed it as float).
    /// The cloth slot is seeded outside this class (the caller set is not in this
    /// batch); the port's EnsureZShiftArrays keeps length 3 so the read is safe.
    /// </summary>
    public ZShift GetZShiftCloth()
    {
        EnsureZShiftArrays();
        return new ZShift(z_shift_min_array[ZSHIFT_CLOTH], z_shift_max_array[ZSHIFT_CLOTH]);
    }

    private void EnsureZShiftArrays()
    {
        if (z_shift_min_array == null || z_shift_min_array.Length < 3) z_shift_min_array = new float[3];
        if (z_shift_max_array == null || z_shift_max_array.Length < 3) z_shift_max_array = new float[3];
    }

    // =====================================================================
    // Misc accessors
    // =====================================================================

    /// <summary>CharacterDrawer.GetCharacterDrawerEye 0x1C6B184: returns `drawer_eye` (0xB0).</summary>
    public CharacterDrawerEyeNative GetCharacterDrawerEye()
    {
        return drawer_eye;
    }

    /// <summary>CharacterDrawer.SetShadowCastEnable 0x1C6B194: `config.isShadowCastEnabled = v;`.</summary>
    public void SetShadowCastEnable(bool isEnabled)
    {
        config.isShadowCastEnabled = isEnabled;
    }

    /// <summary>CharacterDrawer.IsShadowCastEnabled 0x1C6B19C.</summary>
    public bool IsShadowCastEnabled()
    {
        return config.isShadowCastEnabled;
    }

    /// <summary>CharacterDrawer.GetMaterials 0x1C6B17C.</summary>
    public CharacterMaterialsNative GetMaterials()
    {
        return materials;
    }

    /// <summary>CharacterDrawer.GetNumOfRendererAndMaterials 0x1C6A3FC.</summary>
    public int GetNumOfRendererAndMaterials()
    {
        return renmats.Count;
    }

    /// <summary>
    /// CharacterDrawer.ReloadDefaultLayers 0x1C6B3B8 (decompiled): if
    /// `mirroredItemDefaultLayers` (+0xE0) is non-null, walk it BACK-TO-FRONT
    /// (len-1 .. 0) and store `mirroredItems[i].layer` (GameObject.get_layer,
    /// sub_71404D4) into `mirroredItemDefaultLayers[i]`. Pure mirror/audience-layer
    /// bookkeeping: it never touches renmats or character materials. Native throws on
    /// a null/short mirroredItems entry; the spike skips those defensively.
    /// </summary>
    public void ReloadDefaultLayers()
    {
        if (mirroredItemDefaultLayers == null) return;
        for (var i = mirroredItemDefaultLayers.Length - 1; i >= 0; i--)
        {
            if (mirroredItems == null || i >= mirroredItems.Length) continue;
            var go = mirroredItems[i];
            if (go == null) continue;
            mirroredItemDefaultLayers[i] = go.layer;
        }
    }

    /// <summary>SPIKE-MAPPING helper for SetVisible (see the method comment).</summary>
    private void ApplyVisibleToRenderers()
    {
        var visible = config.is_visible_external;
        foreach (var renmat in renmats)
        {
            if (renmat.renderer_ == null) continue;
            renmat.renderer_.enabled = visible;
        }
    }

    public string Describe()
    {
        var sb = new StringBuilder();
        sb.Append("CharacterDrawerNative chara_index=").Append(chara_index)
          .Append(" layer=").Append(m_layerId)
          .Append(" stencilRef=").Append(LayerIdToStencilRef(m_layerId))
          .Append(" lod=").Append(lod)
          .Append(" skin=").Append(quality)
          .Append(" renmats=").Append(renmats.Count)
          .Append(" eyeMats=").Append(eyeMaterials.Length)
          .Append(" faceMat=").Append(faceMaterial != null ? faceMaterial.name : "<null>")
          .AppendLine();
        sb.Append("  config visible=").Append(config.is_visible_external)
          .Append(" outline=").Append(config.is_draw_outline_external)
          .Append(" entity=").Append(config.is_draw_entity_external)
          .Append(" shadowCast=").Append(config.isShadowCastEnabled)
          .AppendLine();
        sb.Append("  zshift other=(").Append(z_shift_min_array[ZSHIFT_OTHER].ToString("F3")).Append(',')
          .Append(z_shift_max_array[ZSHIFT_OTHER].ToString("F3")).Append(") cloth=(")
          .Append(z_shift_min_array[ZSHIFT_CLOTH].ToString("F3")).Append(',')
          .Append(z_shift_max_array[ZSHIFT_CLOTH].ToString("F3")).Append(") face=(")
          .Append(z_shift_min_array[ZSHIFT_FACE].ToString("F3")).Append(',')
          .Append(z_shift_max_array[ZSHIFT_FACE].ToString("F3")).AppendLine(")");
        if (materials != null) sb.Append(materials.Describe());
        sb.Append("  drawer_eye: ").Append(drawer_eye != null ? drawer_eye.Describe() : "<null>").AppendLine();
        return sb.ToString();
    }
}

// =========================================================================
// CharacterMaterials — ported in its own file, CharacterMaterialsNative.cs.
// =========================================================================

// The embedded CharacterMaterialsNative stub (previously lines ~779-1209) was
// replaced by the native-faithful standalone file CharacterMaterialsNative.cs
// (same member signatures). That file carries the current-shipped-binary
// evidence table (create_sync 0x1C77B44, ApplyOutlineColor 0x1C784EC,
// apply_stencil 0x1C78648, the Set*/Get* wrappers, initStatic 0x1C7ABE8) and is
// the single place where the deferred apply pass
// UpdateProperties 0x1C7DD04 / apply_color 0x1C7BDD0 is documented.

// =========================================================================
// CharacterDrawerEye (dump.cs 14990) — identity + draw type only.
// =========================================================================

/// <summary>
/// `CharacterDrawerEye` (dump.cs 14990, Imas.ModelLib). Only the state the drawer subset
/// needs is ported: the current `CharacterEyeDrawType`, the two eye materials and the
/// loaded-texture result. Texture loading from the character's eye bundle
/// (`co_LoadTexturesFromBundle` 0x1C1A274 / `LoadTexturesFromBundle` 0x1C1A2FC /
/// `set_textures_to_material` 0x1C1B1D4) is B4/EyeTracking scope and stays out.
/// </summary>
public sealed class CharacterDrawerEyeNative
{
    public int load_bundle_result;      // 0x10 CharacterManager.Result.ID
    public string chr_id;               // 0x20
    public int current_type;            // 0x28
    public Material material_r;         // 0x30
    public Material material_l;         // 0x38

    /// <summary>CharacterDrawerEye.SetDrawType 0x1C19E4C / GetDrawType 0x1C1A26C.</summary>
    public void SetDrawType(int type)
    {
        current_type = type;
    }

    public int GetDrawType()
    {
        return current_type;
    }

    public bool has_materials()
    {
        return material_r != null && material_l != null;
    }

    public string Describe()
    {
        return "eye chr_id=" + (chr_id ?? "<null>")
               + " type=" + current_type
               + " r=" + (material_r != null ? material_r.name : "<null>")
               + " l=" + (material_l != null ? material_l.name : "<null>");
    }
}
