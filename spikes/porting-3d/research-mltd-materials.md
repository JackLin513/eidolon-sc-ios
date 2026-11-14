# MLTD 角色的贴图与着色：原版做法，以及我们导出错在哪

调查日期：2026-10-29。只读调查：MLTDTools / LeadActress 克隆到 `/tmp` 后阅读，实机 bundle 只用 UnityPy 读、不写回。

## 结论摘要

1. **ss003 胸口那块红色、以及头/发的色块，根因是 UV 顶点通道的 offset 被写死。** ss003 的 body 没有顶点色通道、UV 在 `stream 1, offset 0`；pr001 有顶点色、UV 在 `offset 4`。写死 4 让 ss003 的 body 有 98.9% 顶点采到错误 UV，hair 有 81.9% 顶点塌到贴图最上面一行。这条已经在本仓库 `475aeed fix(3d): UV 通道 offset 不能写死`（2026-10-29 20:10）修掉，本文用实机数据复核了修复正确。
2. **原版每个材质只有两个贴图槽：`_MainTex` 和 `_SubTex`。** 没有 ramp 贴图、没有 shadow/mask 贴图。
3. **`_SubTex` 不是乘到 base 上的 alpha 蒙版，是加法发光/高光。** 我们完全没导出它，所以 ss003 全身的霓虹描边、头发和眼睛的高光都丢了。
4. **material index 与 submesh index 严格一一对应**，四个实机 bundle 里数量完全相等。
5. **角色 mesh 最多两套 UV**：只有 hair 有第二套，body / face / eyes / accessories 都只有一套。

## 证据来源

| 来源 | 版本 | 用途 |
|---|---|---|
| `OpenMLTD/MLTDTools` | `e2ba4cc`（2020-09-23） | 离线转换的事实标准 |
| `thirdparty/AssetStudio`（`hozuki/AssetStudio`） | `e81c66b`（2020-07-17） | `MeshWrapper` / `SkinnedMeshRenderer` 的字段定义 |
| `OpenMLTD/LeadActress` | `fb7bfff`（2020-07-27） | 运行时重放器的材质处理 |
| 实机 bundle（2018.4，iOS 缓存） | `ch_/cb_{pr001,ss003}_014mir.unity3d` | 通道表、材质属性、纹理内容 |
| UnityPy 1.25.4 | `build/mltd-spike/venv` | 只读解析 `m_Channels` / `m_SavedProperties` / `m_ParsedForm` |

角色：春日未来 `014mir`，衣装 `pr001`（私服）和 `ss003`（演出服）。四个 bundle 的结构：body 各 1 个 Mesh + 1 个 SkinnedMeshRenderer；head 各 5 个 SkinnedMeshRenderer（`acc01`、`acc02`、`face`、`hair`、`eyes`），每个各带 1 个 Mesh。

> 说明：MLTDTools 里并没有 `Core/Model*.cs`（`git log --all -- 'src/MillionDance/Core/Model*'` 为空）。模型相关代码在 `Core/PmxCreator.Model.cs`，材质解析在 `src/AssetStudio.Extended.CompositeModels/MeshWrapper.cs`。

---

## 1. 原游戏的材质模型

### 1.1 纹理属性表

对 `cb_ss003` / `ch_ss003` 的 `Shader.m_ParsedForm.m_PropInfo` 直接 dump 得到权威属性名与描述（游戏自带的字符串，不是猜的）。

| 属性 | 出现于 | 作用 | 来源 |
|---|---|---|---|
| `_MainTex` | 所有角色 shader | 基础色，“Base (RGB)” | 实机 `m_PropInfo`；MLTDTools `MeshWrapper.cs:214` |
| `_SubTex` | `Chr_Glow` / `Chr_Hair` / `Bi_CharEye` | 叠加发光：描述分别是 “SubTex (bloom)”、“SubTex”、“Highlight Tex” | 实机 `m_PropInfo`；`MeshWrapper.cs:216` |
| `_Cube` | `Chr_Basic` | “Reflection Cubemap”，实机中 `m_PathID = 0`（未使用） | 实机材质 |
| `_Color` | 全部 | “Main Color” | 实机 `m_PropInfo` |
| `_AmbientColor` | 全部 | 环境色；skin 材质是 `(0.980, 0.827, 0.788)` 暖色 | 实机 `m_Colors` |
| `_DiffuseColor` | 全部 | 漫反射色，实机多为 `(1,1,1,1)` | 实机 `m_Colors` |
| `_Light` | 全部 | “Light”，实机值 `(-0.3, -0.4, 1.0)` | 实机 `m_Colors` |
| `_IllumiColor` | 全部 | “Illumi Color”，实机 `(0.5,0.5,0.5)` | 实机 `m_Colors` |
| `_GlowColor` | `Chr_Glow` | 发光颜色 | 实机 `m_PropInfo` |
| `_Outline`, `_OutlineColor`, `_OutlineZadj`, `_TanFov` | 带描边的 shader | 描边宽度（屏幕空间，实机 0.0005）、描边色、Z 偏移、tan(fov/2)=0.2217 | 实机 `m_PropInfo` |
| `_RimLightOn`, `_RimLight`, `_RimColor`, `_RimOffset`, `_RimBorder` | 全部 | 边缘光开关/方向/颜色/偏移/边界 | 实机 `m_PropInfo` |
| `_ShadingOffset`, `_ShadingBorder` | Face / Hair | 两段式明暗的分界与过渡宽度 | 实机 `m_PropInfo` |
| `_VColWeight`, `_VColMin`, `_GradeMag`, `_GradeOffset`, `_MinKido` | Face / Hair | 顶点色权重、灰度/亮度阈值 | 实机 `m_PropInfo` |
| `_WhityCol`, `_WhiteMode`, `_Whitish`, `_Freq`, `_Luminance`, `_ColorBlendRate` | `Chr_Glow` | “白飛び”（过曝）目标色/模式/强度/频率/亮度，注记均为“自動設定” | 实机 `m_PropInfo` |
| `_SubColor`, `_SubAdd`, `_SpecTex_Fade/_Vector_X/_Vector_Y/_Move/_Move2`, `_Up` | `Chr_Hair` | 副贴图颜色与 UV 流动；`_SubAdd` 描述“Off=補間 On=加算”（关=插值，开=加算） | 实机 `m_PropInfo` |
| `_IrisColor`, `_SpecTex_Center_X/Y`, `_SpecTex_Scale_X/Y`, `_SpecTex_Offset_X/Y`, `_SpecTex_Rotate_Z`, `_SpecTex_Rotate_Offset`, `_Lens`, `_SpecTex_Lens_Zoom`, `_SpecTex_Lens_AngleField`, `_UP_SIDE_VECTOR`, `_GPU_TYPE`, `_VTC` | `Bi_CharEye` | 虹膜颜色、高光的位置/缩放/旋转/镜头参数 | 实机 `m_PropInfo` |
| `_IsBihaku`, `_BihakuCenterX/Y`, `_BihakuWidth/Height/Border`, `_IsReddish`, `_ReddishColor`, `_ReddishCenterX/Y`, `_ReddishScaleX`, `_ReddishRadius`, `_ReddishIntensity`, `_ReddishOvalH/S` | Face | 美白与腮红，全部是程序化参数（中心/尺寸/半径/强度），不是贴图 | 实机 `m_PropInfo` |

**MLTDTools 只认其中两个键**：`_MainTex` 与 `_SubTex`，其余一律丢弃 —— `MeshWrapper.cs:209-223` 遍历 `m_SavedProperties.m_TexEnvs` 时只比较这两个字符串。

### 1.2 没有 ramp 贴图

在所有实机材质的 `m_TexEnvs` 与所有 shader 的 `m_PropInfo` 里，**不存在** `_RampTex`、`_ShadowTex`、`_MaskTex`、`_AlphaTex`、`_Toon`、`_EmissionMap` 中的任何一个。明暗是 shader 里程序化算的，靠 `_ShadingOffset` / `_ShadingBorder` / `_Light` / `_AmbientColor` 这些标量驱动。

MLTDTools 的 toon 是**外挂的 MMD toon 文件**：`toon01..toon10`（`FMain.Designer.cs:470-508`），按材质名分类选择，默认皮肤 `toon05`（“looks closest to MLTD models”）、衣服 `toon04`（“less yellow-ish”）——`FMain.cs:247-248`。而且**头部不套 toon**：

> `// Only apply toon on body, not on head. (Shadows on head is pre-baked.)`
> —— `PmxCreator.Model.cs:601`

这解释了为什么脸部的明暗必须从贴图里来，也说明我们的头部不能套用身体的 toon 参数。

---

## 2. 三个明确回答

### 2.1 角色 mesh 用几套 UV？

**实测：最多两套，且只有 hair 有第二套。**

四个 bundle 里每个 mesh 的 `m_Channels`（UnityPy 只读）：

| bundle | mesh | 顶点数 | 顶点色 | UV0 | UV1 |
|---|---|---|---|---|---|
| `cb_ss003` | `body(SoftNormal前処理)` | 4123 | 无 | `stream1 off0` | 无 |
| `cb_pr001` | `body(SoftNormal前処理)` | 4422 | `stream1 off0`（dim4 UNORM8） | `stream1 off4` | 无 |
| `ch_ss003` | `face` / `hair` / `eyes` / `ss003_acc01` / `ss003_acc02` | 931 / 1764 / 92 / 340 / 18 | eyes 有，其余无 | face/hair/acc 在 `off0`，eyes 在 `off4` | **仅 hair**：`stream1 off8` |
| `ch_pr001` | `face` / `hair` / `eyes` / `pr001_acc01` / `pr001_acc02` | 931 / 1764 / 92 / 226 / 50 | eyes 有，其余无 | face/hair/acc 在 `off0`，eyes 在 `off4` | **仅 hair**：`stream1 off8` |

MLTDTools 的做法是两套都读：`m_UV0 → UV1`、`m_UV1 → UV2`（`MeshWrapper.cs:69-75`），UV2 只喂给高光，且只在开了 `AddHairHighlights` / `AddEyesHighlights` 时才输出（`ConversionConfig.cs:53-55`，两者在 MLTD 模板里默认 `true`，`ConversionConfig.cs:75-76`）。

注意 MLTDTools 里 `UV2` 的命名是“第二套 UV”，不是 Unity 的 `m_UV2`。`CompositeMesh` 合并多 mesh 时也是逐个把 `UV1` / `UV2` 串起来（`CompositeMesh.cs:140-141`）。

### 2.2 material index 怎么映射到 submesh？

**严格按下标一一对应，没有例外。**

```csharp
// MeshWrapper.cs:186-199
var meshRenderer = serializedObjectsLookup.Find<SkinnedMeshRenderer>(r => r.m_Mesh.m_PathID == mesh.m_PathID);
if (meshRenderer.m_Materials.Length <= meshIndex) {
    throw new FormatException("No corresponding material is associated with this SkinnedMeshRenderer.");
}
var materialPtr = meshRenderer.m_Materials[meshIndex];
```

`meshIndex` 就是 `mesh.m_SubMeshes` 的下标（`MeshWrapper.cs:17-23`）。材质数少于 submesh 数时它**抛异常**，不会静默回退。

实测四个 bundle 全部相等：`cb_ss003` 2 submesh / 2 材质，`cb_pr001` 3/3，`ch_ss003` 的各 mesh 1/1、2/2、1/1，`ch_pr001` 同理。所以在我们手上的资源里，**不存在“submesh 比材质多”的情况**——但我们的导出器在越界时会回退到 `materials[0]`（`export_character.py:178-184`），和 MLTDTools “宁可报错”的取舍相反，属于潜在静默错误。

材质名与 shader 的实际对应（ss003）：

| material | shader | submesh |
|---|---|---|
| `cb_ss003_014mir_01glw_m` | `Custom/Chr_Glow` | 0（14676 个 index，占 89%） |
| `cb_ss003_014mir_skin_m` | `Custom/Chr_Basic` | 1（1824 个 index） |
| `ch_ss003_014mir_acc01glw_m` | `Custom/Chr_Glow` | — |
| `ch_ss003_014mir_acc01_m` | `Custom/Chr_Basic` | — |
| `ch_pr001_014mir_face_m` | `Custom/Chr_Face` | — |
| `ch_pr001_014mir_hair_m` | `Custom/Chr_Hair` | — |
| `ch_pr001_014mir_eyer_m` / `_eyel_m` | `Custom/BultIn/Bi_CharEye` | — |

（`Custom/BultIn` 的拼写是游戏自己的。）

### 2.3 `_SubTex` 是必须乘上去的 alpha 蒙版吗？

**不是。它是加法叠加的发光/高光层。** 三条独立证据：

1. **贴图内容**。ss003 的 `cb_ss003_014mir_01glw_m`（`_SubTex`）是黑底白线的霓虹描边图，整图均值 RGB `(18,18,18)`、alpha 全 255——黑的地方不发光，白的地方发光。hair 的 `_SubTex`（`ch_pr001_014mir_hairh`）99.4% 像素全透明，只有几笔高光。
2. **LeadActress 的着色器**（`Assets/Materials/UnlitDual.shader:58-67`）：
   ```hlsl
   fixed4 col_main = tex2D(_MainTex, i.uv_main);
   fixed4 col_sub  = tex2D(_SubTex,  i.uv_sub);
   float3 rgb = saturate(col_main.rgb + i.color.rgb * (col_sub.a * col_sub.rgb));
   ```
   `i.uv_sub` 绑的是 **TEXCOORD1**（`UnlitDual.shader:28`），`i.color` 是 `_ShadeColor`。
3. **属性描述**：Glow 是 “SubTex (bloom)”，Eye 是 “Highlight Tex”，Hair 的 `_SubAdd` 写着 “OFF=補間 ON=加算”。

MLTDTools 的近似办法是把 `_SubTex` 烘成 PMX 的 **sphere texture**（`SphereTextureMode.SubTexture`，`PmxCreator.Model.cs:848-849`），并且复制顶点/面来承载它（`PmxCreator.Model.cs:734-798`）。眼睛更特殊，因为贴图尺寸与 base 相同，直接复用 base 的 UV：

```csharp
// PmxCreator.Model.cs:821-822
// Directly use base texture's UV for highlight UV (since texture sizes match)
v.Uva[0] = new Vector4(v.UV.X, v.UV.Y, 0, 0);
```

---

## 3. 原游戏的取图路径（MLTDTools 侧）

- **body**：取 bundle 文件里**第一个** `Mesh`（`ResourceLoader.cs:29-56`）。
- **head**：取文件里**所有** `Mesh`，合成一个 `CompositeMesh`（`ResourceLoader.cs:87-115`）。
- **贴图**：来自 `SkinnedMeshRenderer.m_Materials[i].m_SavedProperties.m_TexEnvs`，按 PPtr 在同一批已加载对象里解析（`MeshWrapper.cs:185-251`）。**没有“共享贴图 bundle”的概念**——贴图必须和 mesh 在同一个文件里，否则只打一条 warning 并退回 1×1 白图（`MeshWrapper.cs:233-247`、`PmxCreator.Model.cs:861-872`）。
- **UV 的 V 翻转**：body 翻、head 不翻（`PmxCreator.Model.cs:110-137`），代码里有 TODO 承认 head 各模型不一致。但贴图导出时用的是同一个 `ShouldFlip` 标志（`PmxCreator.Model.cs:864` / `882`），翻贴图 + 翻 V 互相抵消，所以**净映射两种分支等价**，不是语义差异。

---

## 4. 我们的导出错在哪

### 4.1 已修：UV 通道 offset 写死（`475aeed`，2026-10-29 20:10）

旧代码把顶点属性当成固定布局：`TEXCOORD0 = Channel(dimension=2, format=float32, offset=4, stream=1)`（旧 `unity_rig.py:24`），即假设每根顶点前面都有 4 字节顶点色。实测：

| mesh | 真实 UV | 写死 offset 4 的结果 |
|---|---|---|
| `cb_ss003` body | `stream1 off0`，无顶点色 | **4077/4123（98.9%）顶点 UV 改变**，最大偏差 0.981 |
| `cb_pr001` body | `stream1 off4`，有顶点色 | 正确（偏差 0） |
| `ch_ss003` hair | `stream1 off0`，stride 16（两套 UV） | **1445/1764（81.9%）顶点塌到贴图最上 10px 一行**（正确 UV 是 0%） |
| `ch_ss003` face | `stream1 off0` | UV 错位（最大偏差 0.950） |
| `ch_ss003` eyes | `stream1 off4` | 正确 |

失效机理：stride 为 8 时从 offset 4 读两个 float，拿到的是 `(v_i, u_{i+1})`——分量互换且错位一根顶点。hair 的 stride 是 16，第二个分量直接读到第二套 UV 的 u，于是几乎所有发丝都采样贴图最上面一行，表现为整片纯色；body 则是整张图集被乱采样。

**渲染对比已验证**（同一份 bundle，只切换 `unity_rig.py` 的版本，Blender headless 出图）：

- 旧版（`0d9ae4f`）：胸口正中一大块深红、胯部一块红、头发里夹黄色和深色斑——与报告的“ss003 胸口红色块 + 头/发色块”完全一致；
- 当前 HEAD：红块消失，胸口恢复成黑心形胸衣 + 白外套，发色连续。

数值复核（当前 HEAD 导出 → 按导出的 UV 采样贴图）：face 均值 `(223,190,182)`、hair `(119,61,39)`，分别吻合原贴图均值 `(209,156,142)` 与 `(112,57,34)`。

atlas 里确实存在一块约 260×150 的深红平面区（`cb_ss003_014mir_01`，约 x∈[700,960]、y∈[280,430]；按“深红”阈值整图占 3.5%）。旧版渲染里那块红与它颜色一致，应该是身体表面被错映射到了这一区域（颜色比对得出的推断，未逐面反查 UV）。

### 4.2 仍在：完全没导出 `_SubTex`

`read_material` 只找 `_MainTex`（`unity_rig.py:51-62`），`_SubTex` 被丢弃。后果：

- ss003 全身的霓虹描边（`cb_ss003_014mir_01glw_m` 的 `_SubTex`）丢失——这是演出服最有辨识度的部分；
- 头发高光、眼睛高光丢失；
- 与 MLTDTools 的差距：MLTDTools 至少烘了 hair 和 eyes 的 `_SubTex`（`PmxCreator.Model.cs:626-644`），但**也没处理衣服的 glow**（Clothes / BodySkin / Accessories 分支只取 base，`PmxCreator.Model.cs:598-672`）。

### 4.3 仍在：没有第二套 UV

只写 `TEXCOORD_0`（`export_character.py:192-194`）。头发的 `_SubTex` 必须用 UV1 采样（`UnlitDual.shader:28,52`），缺了就画不出高光。Eyes 例外：眼睛 mesh 只有一套 UV，`_SubTex` 应复用 base UV（见 §2.3）。

### 4.4 仍在：材质只剩 baseColorTexture

`export_character.py:156-166` 只写 `baseColorTexture` + 固定的 `metallicFactor: 0.0` / `roughnessFactor: 0.9`，其余属性全部丢弃：

- `_AmbientColor` / `_DiffuseColor` / `_Light` / `_IllumiColor` — 身体的明暗全靠它们；
- `_Outline` / `_OutlineColor` / `_OutlineZadj` — 描边；
- `_ShadingOffset` / `_ShadingBorder` — 脸和头发的两段式分界。

所以我们现在只能做通用两段式 ramp，做不出按材质调的明暗。头部按 MLTDTools 的说法是**明暗已烘进贴图**（`PmxCreator.Model.cs:601`），不应再套身体的 toon。

### 4.5 仍在（低风险）：材质按名字去重

`material_index` 用 `material.m_Name` 做 key（`export_character.py:147-155`）。本次四个 bundle 里 body 是 `cb_*`、head 是 `ch_*`，不冲突；但换装覆盖（LeadActress 的 `ProcessBodyCostumeOverride` 就是靠改 `_MainTex` 的 PPtr 实现的，`ModelLoader.cs:351-413`）可能让同名材质挂不同贴图，届时会静默串图。按 `path_id` 做 key 更稳。

### 4.6 UNVERIFIED 风险：索引宽度写死 16 位

`firstByte // 2 // 3` 与 `decode_triangles(..., True)`（`unity_rig.py:158-161`、`195`）都假定 UInt16 索引。实测的 12 个 mesh（4 个 bundle）`m_IndexFormat` 都是 0（UInt16），所以当下正确；其它角色/衣装未验证。

---

## 5. 忠实离线近似需要采样什么

按重要性排序：

1. `base = _MainTex(uv0)`
2. `rgb = saturate(base.rgb + shadeColor.rgb * (sub.a * sub.rgb))`，其中 `sub = _SubTex(uv1)`（hair / glow / eye）——**加算**，不是乘
3. 明暗：两段式；阈值取 `_ShadingOffset ± _ShadingBorder`（Face/Hair）或固定 ramp（衣服）
4. 环境/漫反射项：`_AmbientColor`、`_DiffuseColor`，方向取 `_Light`
5. 描边：`_OutlineColor` + 屏幕空间宽度 `_Outline`
6. 头部：**不要套 toon**，明暗已在贴图里；表情是 blend shape，不是材质

---

## 6. 无法验证的部分

- `_Color`（“Main Color”）的具体语义。没有 shader 字节码（实机 `Shader.m_Script` 长度为 0），且 MLTDTools（`PmxCreator.Model.cs:584` 直接把 Diffuse 设成 `Vector4.One`）和 LeadActress 都忽略它。
- `_Light` 的取值 `(-0.3,-0.4,1.0)` 落在 Color 槽里，坐标系/归一化方式不明。
- 其它角色/衣装是否存在超过两套 UV、或 submesh 数多于材质数的情况（只验证了 014mir 的 pr001/ss003 四个 bundle）。
- 是否存在 32 位索引的 mesh。
- `Chr_Face` 的 `_Blending` 混合模式。
- LeadActress 对眼睛启用 `Unlit/Dual`（`ModelFixer.cs:136-141`），但眼睛 mesh 只有一套 UV，`TEXCOORD1` 会退化为常量——与 MLTDTools “眼睛复用 base UV”的做法矛盾。二者必有一方在真实骨骼数据下不成立，未验证。

## 7. 复现方法

只读，产物写在仓库外。本文用到的探测脚本是一次性的（写在 `/tmp`，未入库），核心只是用 UnityPy 遍历 `env.objects`，按类型读：

- `Mesh.m_VertexData.m_Channels` —— 每个通道的 `dimension / format / stream / offset`，通道下标 4 就是 TEXCOORD0，index 3 是 COLOR（`dimension == 0` 表示该通道不存在）；
- `Mesh.m_SubMeshes` 与 `SkinnedMeshRenderer.m_Materials` —— 数一数是否相等；
- `Material.m_SavedProperties.m_TexEnvs / m_Floats / m_Colors` —— 属性名与实机取值；
- `Shader.m_ParsedForm.m_PropInfo` —— 游戏自带的属性名和描述字符串。

导出与渲染：

```bash
VENV=/Users/jacklin/Developer/IdeaProjects/eidolon-sc-ios/build/mltd-spike/venv
ASSETS=/Users/jacklin/Developer/IdeaProjects/eidolon-sc-ios/build/mltd-spike/assets

$VENV/bin/python -I spikes/porting-3d/export_character.py \
  --body "$ASSETS/cb_ss003_014mir.unity3d" \
  --head "$ASSETS/ch_ss003_014mir.unity3d" \
  --out /tmp/exp --name ss003
build/mltd-spike/Blender42.app/Contents/MacOS/Blender -b \
  -P spikes/porting-3d/render_gltf.py -- /tmp/exp/ss003.gltf /tmp/exp/render.png
```

要看旧版（有红块）的对比图，把 `spikes/porting-3d/` 复制到 `/tmp`，再把 `unity_rig.py` 换成 `git show 0d9ae4f:spikes/porting-3d/unity_rig.py`，其余不变。
