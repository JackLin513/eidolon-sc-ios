# 剩下的变体：Chr_Alpha 的混合、三个关键字、描边缺的两件事、全量覆盖

日期：2026-10-30　分支：`spike/mltd-3d-static`　仓库：`eidolon-sc-ios-3dspike`

> 本文逐行引用游戏自己编译出的 Metal 源码、bundle 里的材质/状态数据和我们自己的实现。
> 按 `spikes/porting-3d/.gitignore` 里 `research-mltd-shading-math.md` 的先例，
> 这类文件**不入库**（见文末提醒）。本次**没有修改 `spikes/porting-3d/ios/` 下任何实现，
> 也没有提交 git**；所有临时脚本都在 `/tmp/mltd-work`，读完已删。

标注约定：`【一手】`= 直接读到的游戏文件/我们自己的实测；`【推论】`= 由一手数据推出来的；
`【未确定】`= 现有证据不足，没有猜。

一手来源路径简写：

- `METAL/x.metal` = `/private/tmp/mltd-shading/out/metal/x.metal`（从
  `data.unity3d` 的 Shader 子程序 blob 里解出来的完整 Metal 源码）
- `SHADERS/x.txt` = `/private/tmp/mltd-shading/out/shaders/x.txt`（UnityPy 导出的
  ShaderLab 骨架；**注意它不导出 Blend 命令**，见 §1.2）
- `STATE` = `m_ParsedForm.m_SubShaders[].m_Passes[].m_State` 的原始 typetree
- 数据面：`Cache00` 里 1345 个含 `pr001` 的 bundle（8593 个材质）
  + 599 个非 pr001 采样 bundle + 171 个含 `MOSAIC_ON` 字符串的 bundle
  + 588 个含 `_ISREDDISH_ON` 字符串的 bundle

---

## 直接答案

1. **`Chr_Alpha` 是标准的直通 alpha 混合，没有预乘。**
   `out.rgb` 是普通的着色结果，`out.a = _MainTex.a × _Color.a`；混合因子由材质属性
   `_BlendSrc=5` / `_BlendDst=10` 决定，即 `Blend SrcAlpha OneMinusSrcAlpha`；
   **alpha 通道**的混合因子写死为 `Zero/One`（不写 RT alpha）。与 `Chr_CutOff` 的差别
   只有：discard 阈值（1/255 vs `_AlphaTestValue=0.5`）、输出 alpha（真 alpha vs 写 1），
   其余逐行相同。落地要三样东西一起改：图集加 `_AlphaTestValue`、`SHADER_KINDS` 加 kind 6、
   Swift 侧 `toon.blending = .transparent(...)` + Metal 侧 `set_opacity()`。

2. **三个变体里只有一个真正在用。**
   `_USEREFLECT_ON`：1749/8593 个 pr001 材质、6/55 套已导出模型（涉及 7 个材质），是**视空间 matcap 式
   立方体贴图叠加**（`col += cube(reflect(V,N)) × tex.a × _Reflection`），顶点着色器把反射
   向量塞进 `TEXCOORD3`。`MOSAIC_ON` 和 `_ISREDDISH_ON` **在整份本地缓存里没有任何材质真正
   开启**（MOSAIC 只找到 1 个开了 `_UseMosaic` 的 EX 配件，而且它的关键字拼写是
   `_USEMOSAIC_ON`，跟变体名 `MOSAIC_ON` 对不上），优先级最低。

3. **描边剩下两件事都能定死。**
   `TANGENT` = 顶点通道 **2**、`float32 × 4`、w 恒为 0、长度恒为 1（不是切线的 w=±1 手性），
   存的是"硬法线"。把它八面体编码进一个 UV 集（推荐 `primvars:st2` → `params.geometry().uv2()`，
   返回 `float4`，iOS 18+，我们部署目标是 iOS 26）就能完整还原。深度偏移和宽度链的**每一个
   常量都能从投影矩阵反推出来**（near/far/aspect/tan(fov/2)），只差 `_Outline`/`_TanFov`/
   `_OutlineZadj` 三个材质值没进图集。**`0.7` 这个因子在 Metal 上不生效**（它只在 OpenGL 风格
   `[-1,1]` 深度的分支里；Metal 走 `[0,1]` + reversed-Z），旧笔记里的 `0.7` 该删。

4. **全量覆盖：55 套里出现 6 种字符 shader；真正会改变程序的变体共 6 个，我们只完整实现了 1 个。**
   六个变体是 `_ISCUTOFF_ON` / `_USEREFLECT_ON` / `MOSAIC_ON` / `_ISREDDISH_ON` / `_SUBADD_ON` /
   `_NONZEROCUTOFF_ON`。我们完整实现 `_SUBADD_ON`；`_ISCUTOFF_ON` 只做了 discard、没做 rim
   简化；`_USEREFLECT_ON` 有 **6 套（7 个材质）**在用；`MOSAIC_ON` / `_ISREDDISH_ON` /
   `_NONZEROCUTOFF_ON` 零用户。另外 `Custom/Chr_Color` 这个 shader 我们完全没实现（1 套）。

---

## 改动清单（按优先级）

| # | 优先级 | 改什么 | 文件 | 代价 |
|---|---|---|---|---|
| 1 | **P0** | `Chr_Alpha` 混合：kind 6 + `set_opacity` + `.transparent` + 图集加 `_AlphaTestValue` | `material_atlas.py`、`ToonShading.metal`、`ToonShading.swift`、`MaterialParameters.swift` | 小，13/55 套直接受益 |
| 2 | **P0** | 描边用 TANGENT 硬法线：导出侧加八面体编码 + `pack_usd.py` 注入 `primvars:st2` | `export_character.py`、`gltf_to_usdz.py`、`pack_usd.py`、`ToonShading.metal` | 中；先做一次"uv2 到底有没有喂进来"的验证 |
| 3 | **P1** | 描边宽度链换成精确公式（`_Outline`/`_TanFov`/`_OutlineZadj` 进图集，`k` 从投影矩阵算） | `ToonShading.metal:194-217` | 小；顺手把当前写死的 `0.0014` 换成真值 |
| 4 | **P1** | `_USEREFLECT_ON`：`_Reflection`/`_UseReflect` 进图集 + 导出 `_Cube` 立方体贴图 + 采样 | 三处 + 导出器 | 中（立方体贴图要摊平成 2D 图集） |
| 5 | **P2** | `Chr_Hair` 的 `_SUBADD_ON` 关掉时的分支（`mix(mainTex, subTex, w)` 而不是相加） | `ToonShading.metal:355-400` | 小，9 套 |
| 6 | **P2** | `Custom/Chr_Color`（1 套）：`_SubColor0/1/2` + `_SubTex` 的换色 shader | 新分支 | 中，只有 1 套 |
| 7 | **P3** | `MOSAIC_ON` / `_ISREDDISH_ON`：数据里没人用，只把数学记在这里，不实现 | — | — |
| 8 | — | 顺手：`address::clamp_to_edge` 对 tiled UV 是错的（§5.3），值得单独确认 | `ToonShading.metal:73-85` | 小 |

---

## 1. `Chr_Alpha` 的混合数学

### 1.1 Metal 源码：alpha 从哪来，有没有预乘

`METAL/Custom__Chr_Alpha__blob4_MetalFS.metal`（`keywords=[]`，即默认变体）：

```metal
:55  u_xlat16_0 = _MainTex.sample(sampler_MainTex, input.TEXCOORD0.xy);
:56  u_xlat15 = float(u_xlat16_0.w) * FGlobals._Color.w;      // alpha = tex.a * _Color.a
:57  u_xlatb1 = u_xlat15 < 0.00392156886;                     // 1/255
:58  if (u_xlatb1) discard_fragment();                        // α=0 的像素直接丢
...
:81  output.SV_Target0.xyz = u_xlat16_2.xyz * half3(FGlobals._FadeColV.xyzx.xyz);
:82  output.SV_Target0.w   = half(u_xlat15);                  // 写的是真 alpha
```

- **`alpha = _MainTex.a × _Color.a`**【一手】。所有 32 个 `Chr_Alpha` 材质 `_Color.a = 1`，
  所以实际就是贴图 alpha。
- **没有预乘**：`:81` 的 rgb 后面没有乘 alpha，乘的是 `_FadeColV`（全局淡入淡出，实机全 1）。
- 默认变体里有一条 `α < 1/255 → discard`；`_NONZEROCUTOFF_ON` 变体
  （`METAL/Custom__Chr_Alpha__blob5_MetalFS.metal`）**整条 discard 被删掉**（`:59-60` 直接写 w），
  和属性名的日文注释「α=0でCutOffしない」一致。本地缓存里 **0 个材质**开这个关键字。

### 1.2 混合状态：`Blend` 的真值（这条纠正了旧笔记）

`SHADERS/Custom__Chr_Alpha.txt` 里**看不到任何 `Blend` 行**——UnityPy 的 ShaderConverter
根本没实现 blend 导出（`ShaderConverter.py:295` 就一行 `# TODO Blend`）。所以只能读
`m_State`。关键是每个状态字段都带一个 `name`：`name='<noninit>'` 表示 ShaderLab 里写死的字面值，
`name='_BlendSrc'` 表示**这个状态由材质的同名 float 属性在绘制时决定**。

`Chr_Alpha` 的 `STATE`【一手】（bundle `04/b4207e43…`，pathID 在手）：

```
cull    _CullMode=0.0      ztest   _ZTestMode=0.0    zwrite  _ZWrite=0.0
blend   src _BlendSrc=0.0  dst _BlendDst=0.0   op 0(Add)     colMask 15
alpha   srcA <noninit>=0.0 dstA <noninit>=1.0  opA 0
```

`val` 那一列是**占位值，不是默认值**（`_CullMode` 的属性默认是 2，这里写 0），真正生效的是材质：

| 材质属性 | 全 32 个 `Chr_Alpha` 材质的取值 | 含义 |
|---|---|---|
| `_BlendSrc` | **5** | `UnityEngine.Rendering.BlendMode.SrcAlpha` |
| `_BlendDst` | **10** | `OneMinusSrcAlpha` |
| `_ZWrite` | 0 或 1（`_ZWRITE_ON` 关键字 30/32） | ZWrite 开关 |
| `_ZTestMode` | 2 | `CompareFunction.Less` |
| `_CullMode` | 2 | `Cull Back` |
| `_NonZeroCutOff` | 0 | 保留 discard |

**结论【一手+推论】**：`Blend SrcAlpha OneMinusSrcAlpha`，`BlendOp Add`；**alpha 通道**
固定 `Zero / One`（即不写渲染目标的 alpha，保留背景 alpha）。`Cull Back` + `ZTest Less`
+ 材质决定 ZWrite（多数为 On），队列 `Transparent`（SubShader Tag）。

> 顺带纠正：`research-mltd-shading-math.md` §3 的表里写「`_CullMode`/`_ZWrite`/`_BlendSrc`/
> `_BlendDst`/`_ZTestMode` 无 shader 引用，状态是 pass 里编译死的」——对 `Chr_Basic_NoOutline`
> 这类只把 `_CullMode` 绑上去的 shader 成立（`STATE` 里 cull 的 `name='_CullMode'`，其余全是
> `<noninit>`，`research-mltd-shading-math.md` §4.1 的 `Cull Off` 其实是 `val=0` 的假象，
> 实机材质 `_CullMode=2` → **背面剔除**），但**对 `Chr_Alpha`/`Chr_CutOff` 不成立**：
> 这两个 shader 的 cull/ztest/zwrite/blend 全部由材质驱动。

各 shader 的 `STATE` 归类速查【一手】：

| shader / pass | cull | ztest | zwrite | blend | alpha blend |
|---|---|---|---|---|---|
| `Chr_Basic_NoOutline` BASE | `_CullMode` | LEqual | On | One/Zero | One/Zero |
| `Chr_Hair_NoOutline` BASE | `_CullMode` | LEqual | On | One/Zero | One/Zero |
| `Chr_Glow_NoOutline` BASE | `_CullMode` | LEqual | On | One/Zero | One/Zero |
| `Chr_Face_NoOutline` BASE | `_CullMode` | LEqual | On | One/Zero | One/Zero |
| `Bi_CharEye` | Back（字面） | LEqual | On | One/Zero | One/Zero |
| 所有 `OUTLINE` pass | Front（字面） | LEqual | On | One/Zero | One/Zero |
| **`Chr_Alpha` BASE** | `_CullMode` | `_ZTestMode` | `_ZWrite` | **`_BlendSrc`/`_BlendDst`** | Zero/One |
| **`Chr_CutOff` BASE** | `_CullMode` | `_ZTestMode` | `_ZWrite` | **`_BlendSrc`/`_BlendDst`** | One/Zero |

### 1.3 和 `Chr_CutOff` 的差别

`METAL/Custom__Chr_CutOff__blob3_MetalFS.metal`：

```metal
:56  u_xlat16_0 = _MainTex.sample(...);
:57  u_xlat15 = float(u_xlat16_0.w) * FGlobals._Color.w;
:58  u_xlatb1 = u_xlat15 < FGlobals._AlphaTestValue;    // _AlphaTestValue = 0.5
:59  if (u_xlatb1) discard_fragment();
:60  output.SV_Target0.w = (u_xlatb1) ? half(u_xlat15) : half(1.0);   // 活下来的永远是 1
```

| | `Chr_Alpha` | `Chr_CutOff` |
|---|---|---|
| discard 阈值 | 1/255（`_NONZEROCUTOFF_ON` 时取消） | `_AlphaTestValue = 0.5` |
| 输出 alpha | `tex.a × _Color.a` | 1.0 |
| 队列 | Transparent | AlphaTest |
| 其余（着色、fog、mono、fade） | — 逐行相同 — | — |

两边材质的 `_BlendSrc/_BlendDst` 都是 5/10，`_ZWrite=1`，`_CullMode=2`，`_ZTestMode=2`。
`Chr_CutOff` 是"alpha test + 半透明边"的混合体；`Chr_Alpha` 是纯混合。

**本地缓存里的用量【一手】**（`build/mltd-corpus`，扫描时 55 套）：

- `Chr_Alpha`：**13 套**，全部是 `cb_pr001_<idol>_02alp_m`（003mik / 019min / 022ser / 023aka /
  029umi / 030iku / 037nao / 038chz / 041fuk / 042miy / 045kar / 046rio / 050jul）。
- `Chr_CutOff`：**12 套**，同样都是 `*_02alp_m`（001har / 007ior / 008tak / 009rit / 010azu /
  013hib / 018ele / 028ari / 031tom / 039kon / 048rei / 051tmg）。

**每两个角色就有一个带 `02alp`**，所以 Chr_Alpha 不是边角料。

### 1.4 落地到我们的代码

现状：`material_atlas.py:77-92` 把 `Custom/Chr_Alpha` 映射到 kind 1（Basic），
并在 `:103-110` 强行把 `_IsCutOff = 1`，靠 `ToonShading.metal:242-245` 的"黑键 discard"
把贴图里的黑色区域打洞——因为之前没有混合。

现在要改成：

1. **图集（`material_atlas.py`）**
   - `SHADER_KINDS["Custom/Chr_Alpha"] = 6`（新 kind，`kKindAlpha`）。
   - `LAYOUT` 末尾加 `("_AlphaTestValue", "-")`（`Chr_CutOff` 的 0.5，将来做真 alpha test 用）。
   - `_IsCutOff` 的兜底（`:103-110`）只保留 `Chr_CutOff`，**去掉 `Chr_Alpha`**：
     开了混合以后黑键 discard 会把合法的黑色 texel 打穿。
     （`Chr_CutOff` 也建议改成真 alpha test：导出的 PNG **带 alpha**，§1.5 已验证。）

2. **`ToonShading.metal`**
   - 新常量 `kKindAlpha = 6.0`（`:63-67` 那组）。
   - `writeColour()`（`:156-163`）保持不动；在 `toonSurface` 的 `Chr_Alpha` 分支算完颜色后：

     ```metal
     // Chr_Alpha：alpha = tex.a * _Color.a，直通混合，不预乘
     float alpha = clamp(float(mainTexRaw.a) * colour.a, 0.0f, 1.0f);
     if (alpha < (1.0f / 255.0f)) { discard_fragment(); }   // 默认变体
     params.surface().set_opacity(half(alpha));
     ```
     `colour.a` 需要 `param(lut, row, kParamColor + 3)`——`LAYOUT` 目前只存了 `_Color` 的 r/g/b，
     要么补一列，要么直接写死 1.0（所有材质都是 1，见 §1.1）。
   - 采样器：`02alp` 的 UV 会跑出 `[0,1]`（§5.3），`Chr_Alpha` 分支建议用 `address::repeat`。

3. **`ToonShading.swift`**
   ```swift
   if parameters?.isBlended(name) == true {          // 新增：按 shader 名判断
       toon.blending = .transparent(opacity: .init(scale: 1))
       toon.writesDepth = true                       // 材质 _ZWrite=1 是多数派（iOS 18+）
       toon.readsDepth = true
   }
   ```
   `MaterialParameters`（`MaterialParameters.swift:33-49`）现在只暴露 `row(for:)`，
   给 `Document.Material` 加一个 `shader` 字段的 getter 即可（JSON 里已经有 `shader`）。

4. **`CustomMaterial.Blending` 没有自定义因子**（`RealityFoundation.swiftinterface:3554-3556`
   只有 `.opaque` / `.transparent(opacity:)`），所以只能用 `set_opacity` + 内置混合。
   `RealityKitSurfaceShader.h:592-598` 的文档只剩一句「transparent blending mode 时表示该
   fragment 有多不透明」，**没有说是否预乘**【未确定】。两套可能：
   - 若 RealityKit 内部是 `One / OneMinusSrcAlpha` 且**把颜色乘 opacity**（预乘管线）：
     我们这样写正好等于游戏。
   - 若它**不乘颜色**（直通管线）：边缘会偏亮，需要我们自己写 `colour * alpha` 并把 opacity 设 1。
   验证办法：拿一个 alpha=0.5 的 `02alp`，在已知背景色上取一个像素，
   比对 `0.5*c + 0.5*bg`。**这是落地后第一件要量的事。**

### 1.5 alpha 到底有没有丢

旧笔记说「alpha 不随 USD 走」。那是 `_SubTex`（emissive 槽）的问题。主贴图是单独一张 PNG
经 `CustomMaterial.Texture` 喂进 `custom` 槽的，**PNG 里 alpha 完好**【一手】：

```
build/mltd-corpus/003mik-pr001/textures/02_cb_pr001_003mik_02alp_m.png
  RGBA 256×256；alpha 有 121 个不同值，1836/65536 个 texel < 255，0 个 == 0
  该 mesh 实际 UV 覆盖到的顶点处 alpha ∈ [128, 255]，均值 253
```

【未确定】RealityKit 采样 `custom` 纹理时是否原样给出 `.a`。用 `EIDOLON_3D_DEBUG_CONST`
同样的套路加一个「把 `mainTex.a` 写进 emissive」的调试分支，一次就能看出。

---

## 2. 三个关键字变体

先给一张「谁在什么时候编译出来」的表，免得再被关键字名骗【一手，`data.unity3d` 的
`m_PlayerSubPrograms`】：

| shader | 实际编译出的变体 |
|---|---|
| `Chr_Basic_NoOutline` BASE | `{}` / `MOSAIC_ON` / `_ISCUTOFF_ON` / `_USEREFLECT_ON` 的**幂集**（8 个） |
| `Chr_Basic` OUTLINE | `{}` / `_USEREFLECT_ON` |
| `Chr_Color_NoOutline` | `{}` / `_ISCUTOFF_ON` / `_USEREFLECT_ON` / 两者 |
| `Chr_Face_NoOutline` BASE | `{}` / `_ISREDDISH_ON` |
| `Chr_Hair_NoOutline` BASE | `{}` / `_SUBADD_ON` |
| `Chr_Alpha` | `{}` / `_NONZEROCUTOFF_ON` |
| `Chr_Glow_NoOutline` | 只有 `_TESTMODE_NONE`（一个） |

因此材质上那些**没有对应变体**的关键字一律是死的，别管：
`_ZWRITE_ON`（53）、`_ALPHAPREMULTIPLY_ON`（436）、`_USESQRT_ON`（445）、`_EMISSION`（5）、
`_ANTILEVITATE_ON`（1）、`_WHITEMODE_*`、`_USEMOSAIC_ON`。

### 2.1 `_USEREFLECT_ON` —— 视空间 matcap 反射

**顶点着色器**（`METAL/Custom__Chr_Basic_NoOutline__blob6_MetalVS.metal`，`Chr_Color` /
`Chr_Basic` 的同名变体相同）：

```metal
:191  output.TEXCOORD3.xyz = fma(u_xlat4.xyz, (-float3(2*dot(V, N))), V);
      // u_xlat0 = normalize(viewPos) = 相机指向顶点的方向（视空间）
      // u_xlat4 = 视空间法线（还先过一遍 anti-crack 混合，见下）
      // 即 reflect(V, N)：视空间反射向量，直接把方向塞进 TEXCOORD3
```

**片元着色器**（`METAL/Custom__Chr_Basic_NoOutline__blob22_MetalFS.metal`）：

```metal
:100  u_xlat10.x = float(u_xlat16_2.w) * FGlobals._Reflection;      // tex.a * _Reflection
:107  u_xlat16_0.xyw = _Cube.sample(sampler_Cube, input.TEXCOORD3.xyz).xyz;
:108  u_xlat16_1.xyz = fma(u_xlat16_0.xyw, u_xlat10.xxx, u_xlat16_1.xyz);
      // col = 着色结果 + cubeColor * (mainTex.a * _Reflection)
```

**生效位置**：在"ramp × ambient/diffuse × illum"之后、flash/fog/mono 之前，**加法**，
不受 ramp 影响。用的是 `_MainTex` 的 **alpha** 当遮罩。

**参数真值**【一手，材质 `ch_ex052_a_acc01bref_m` 等】：

| 属性 | 值 |
|---|---|
| `_UseReflect` | 1（与关键字 1:1 对应，0 个例外） |
| `_Reflection` | 0.1 … 2.0，众数 0.35 / 0.5 / 1.0 / 0.3 |
| `_Cube` | **真 Cubemap 资源**，例如 `ch_ex052_a_acc06ref`（32×32），不是 `_Skybox` 默认值 |

**谁在用**【一手】：本地缓存里 1749/8593 个 pr001 材质开了 `_USEREFLECT_ON`
（`Chr_Basic` 1282、`Chr_Basic_NoOutline` 241、`Chr_Color` 226），材质名后缀清一色是
`_accNNref_m` / `_accNNbref_m` / `_accNNaref_m` / `_accNNrct_m` / `_accNNchr_m`——**镜面/亮片配件**。
已导出的 55 套里有 **6 套**：008tak（`ch_cr002_a_acc02ref_m`）、015siz（`ex017_acc01_m`）、
021mat（同上）、038chz（`ch_ex071_b_acc01aref_m`）、201xxx、202xxx。

**我们该怎么改**：
- 图集加 `_Reflection`（0..2，`u2`）和 `_UseReflect`（0/1）。
- 导出器现在**没有导出 `_Cube`**（`export_character.py` 只处理 `_MainTex`/`_SubTex`）。
  RealityKit 的 `CustomMaterial.Texture` 只吃 2D 纹理，需要把立方体贴图摊成 4×3 或 6 面
  的 2D 图集，在 shader 里手写方向→面→UV 的映射。32×32×6 很小，摊平代价可以接受。
- 在 `toonSurface` 的 Basic 分支里、`writeColour` 之前加一行
  `result += cubeSample * mainTex.a * reflection;`。
- 注意：反射向量是**视空间**的，等价于 matcap——不需要世界空间环境光。

### 2.2 `MOSAIC_ON` —— 演唱会解锁马赛克

**完整数学**（`METAL/Custom__Chr_Basic_NoOutline__blob19_MetalFS.metal:78-105`）：

```metal
uv2  = input.TEXCOORD2.xy;                       // 第三套 UV（VS 里 = uv1 * _MainTex_ST）
p    = uv2 - 0.5;
p    = float2(p.x + p.y, p.x - p.y) * 0.7071 + 0.5;   // 旋转 45°
cell = rint(p * _MosaicTiling) / _MosaicTiling;       // 对齐到格子
r    = fract(abs(dot(cell, _Rnds.yz)));               // 每格一个 0..1 随机数
t    = fract(r * _Rnds.z + _Rnds.y + _MosaicTime) * 7; // 演化到 0..7
col  = lerp(_MosaicCols[int(t)], _MosaicCols[int(t)+1], fract(t));   // 8 色循环插值
inside = all(fract(p*_MosaicTiling) >= 1 - _EachRatio);              // 格子内缩比例
on   = inside && (r < _MosaicRatio);                                 // 已解锁的格子
texel = on ? col : _MainTex.sample(uv0).rgb;         // 解锁 = 显示原贴图
...
:155 output.rgb = _ShowMosaicRatio ? r : 最终颜色;                    // 调试
:160 output.a   = on ? (1 - _IsLive) : 常态 alpha;                    // live 时把已解锁格子的 alpha 打 0
```

要点：
- 用的是**第二套 UV**（VS 里 `output.TEXCOORD2 = uv1 * _MainTex_ST`，
  `METAL/Custom__Chr_Basic_NoOutline__blob3_MetalVS.metal:131`），即 UV1，不是 UV0。
  我们的头发已经导出了 uv1，其它 mesh 没有。
- 8 个颜色 `_MosaicCols[8]`、`_Rnds(float2)`、`_MosaicTiling`、`_MosaicTime`、`_MosaicRatio`、
  `_EachRatio`、`_ShowMosaicRatio`、`_IsLive` **全部是运行时量**：8593 个材质里没有一个带
  `_MosaicTiling`/`_MosaicCols`；但 `global-metadata.dat` 里能 grep 到 `_MosaicTiling`、
  `_MosaicCols`、`_EachRatio`、`_MosaicRatio`、`_Rnds`（各 2 次），说明是 C# 侧
  `Material.SetXxx` 推的【一手】。`_IsLive` 是全局（`MainLoop` 进 live 置 1，见
  `research-mltd-runtime-uniforms.md`）。
- **没人用**【一手】：1345 个 pr001 bundle 里 `_UseMosaic` 全 0；专门扫了 171 个含
  `MOSAIC_ON` 字符串的 bundle（968 个材质），只有 **1 个** `cb_ex016_a_03ref_m`
  （`Custom/Chr_Basic`，`_UseMosaic=1`），而它的关键字是 `_USEMOSAIC_ON`
  （`[Toggle] _UseMosaic` 的自动名），跟变体名 `MOSAIC_ON` 差一个下划线——
  **这个变体大概永远选不中**【未确定：可能是数据问题，也可能是我对 UnityPy 关键字归类理解有误】。

**结论**：不实现。真要实现，需要再加一套 UV（UV2 在我们这里已经被描边占用了，见 §3）。

### 2.3 `_ISREDDISH_ON` —— 腮红

**完整数学**（`METAL/Custom__Chr_Face_NoOutline__blob6_MetalFS.metal:99-121`）：

```metal
d    = abs(uv - float2(_ReddishCenterX, 0)) - float2(_ReddishScaleX, _ReddishCenterY);
dx   = d.x * _ReddishOvalH;
L    = sqrt(dx*dx + d.y*d.y - d.y*dx*_ReddishOvalS);   // 斜椭圆
mask = clamp(1 - L * _ReddishRadius, 0, 1) * _ReddishIntensity;
tint = lerp(float3(0.5), _ReddishColor, mask);          // 0.5 是中性，×2 后正好是 1
base = _MainTex * _Color * tint * 2;                    // 替换后续 _Blending 的输入 x
```

- 注意 `d.y` 用的是 **`abs(uv.y) - _ReddishCenterY`**（源码 `:100-102`，`u_xlat0.y = -0.0`），
  也就是说椭圆在 y 方向以 0 为中心对称——**不是**以 `_ReddishCenterY` 为中心。
- 替换点在 `_Blending` 对比度之前，mask=0 时 `tint = 0.5`，`×2` 后完全还原，所以是纯叠加。
- 顺序是 `clamp(1 - L*R, 0, 1)` **之后**才乘 `_ReddishIntensity`，所以 intensity > 1 会把
  mask 推过 1（没有二次 clamp）。

**参数真值**【一手】：`_Reddish*` 属性在**全部 1291 个 Chr_Face 材质**上都有值
（例如 pr001 的 `_ReddishCenterX 0.5 / _ReddishCenterY 0.56 / _ReddishScaleX 0.16 /
_ReddishRadius 15 / _ReddishIntensity 1.5 / _ReddishOvalH 0.7 / _ReddishOvalS 0 /
_ReddishColor (0.529,0.467,0.471)`），但 `_IsReddish` **全是 0**，关键字 `_ISREDDISH_ON`
**一次都没开**。

**谁在用**【一手】：588 个含 `_ISREDDISH_ON` 字符串的 bundle、3654 个材质里，
`_IsReddish == 1` 的 **0 个**。也就是说本地缓存里所有脸都没腮红。

**结论**：不实现。数学留档，将来如果某张卡开出来，照抄上面的 6 行即可；
图集要新增 `_ReddishColor`(3) + 6 个 float。

### 2.4 三个变体的一句话总结

| 变体 | 数学量级 | 真值来源 | 用户 | 建议 |
|---|---|---|---|---|
| `_USEREFLECT_ON` | 4 行（加法） | 材质 + Cubemap 资源 | 1749 材质 / 6 套 | **做** |
| `MOSAIC_ON` | ~25 行 + 8 色数组 | 全运行时 | 0 套（1 个 EX 材质且拼写对不上） | 不做 |
| `_ISREDDISH_ON` | ~10 行 | 材质（但开关全 0） | 0 套 | 不做 |

---

## 3. 描边剩下的两件事

### 3.1 TANGENT 通道里的"硬法线"

**通道号与格式**【一手，`Mesh.m_VertexData.m_Channels`，Unity 2020.3】：

```
channel 0 Position  float32 dim3  stream0 offset 0
channel 1 Normal    float32 dim3  stream0 offset 12
channel 2 Tangent   float32 dim4  stream0 offset 24     ← 就是它
channel 4 UV0       float32 dim2  stream1 offset 0
channel 5 UV1       float32 dim2  stream1 offset 8      （只有 hair）
channel 3 Color     UNorm8  dim4  stream1 offset 0      （部分 mesh）
channel 12/13       混合形状（BlendWeight / BlendIndices）
```

`VertexAttribute.Tangent = 2`，`float32 × 4`。**在 Metal 的顶点布局里它是另一回事**：
hlslcc 会把它压成 `TANGENT0 [[attribute(N)]]`（`Chr_Basic_NoOutline` 里是 N=2，
`Chr_Basic` 的 OUTLINE pass 只有 position+tangent，所以是 N=1）。别拿 Metal 的
attribute 序号当 Unity 的通道号。

**数据特征**【一手，`UnityPy` 直读顶点】：

| mesh | 顶点 | `|T|` | `T.w` | `mean dot(N,T)`（有符号） | `mean |dot|` | `dot≈1` 占比 |
|---|---|---|---|---|---|---|
| pr001 face | 931 | 1.0000 | 恒 0 | 0.977 | 0.977 | 94.4% |
| pr001 hair | 1764 | 1.0000 | 恒 0 | 0.811 | 0.835 | 50.9% |
| pr001 body | 4422 | 1.0000 | 恒 0 | 0.868 | 0.874 | 68.9% |
| pr001 acc01 | 226 | 1.0000 | 恒 0 | 0.669 | 0.670 | 0% |
| pr001 acc02 | 50 | 1.0000 | 恒 0 | 0.953 | 0.953 | 28.0% |

`w` 恒等于 0（真切线应该是 ±1 的手性）→ 确认这 4 个分量里只有 xyz 有意义，
存的是"描边用的硬法线"，与 `NORMAL`（`SoftNormal 前処理` 平滑过）不同。

**描边 pass 怎么用它**（`METAL/Custom__Chr_Basic__blob2_MetalVS.metal:91-108`）：

```metal
u_xlat0 = WorldToObject[1] * MatrixInvV[0].y + WorldToObject[0] * MatrixInvV[0].x
        + WorldToObject[2] * MatrixInvV[0].z + WorldToObject[3] * MatrixInvV[0].w;
T.x = dot(u_xlat0, tangent.xyz);   // 三行拼起来 = mul((float3x3)(MV)^-1, tangent)
...                                // 对刚体变换 (MV)^-1 = (MV)^T = 法线矩阵
T   = normalize(T);                // 视空间硬法线
```

即 Unity 经典的 `mul((float3x3)UNITY_MATRIX_IT_MV, v.normal)`，只不过输入是 tangent。

**怎么搬进我们的管线（具体方案）**

现状：`export_character.py:266-277` 只写 `TEXCOORD_0`（和 hair 的 `TEXCOORD_1`），
`pack_usd.py` 再把第二套 UV 注入成 `primvars:st1`。**TANGENT 完全没导出**，
所以 `ToonShading.metal:214` 只能用 `params.geometry().normal()`。

方案（推荐，已确认 getter 存在）：

1. 导出侧：`export_character.py` 把 channel 2 的 xyz 做**八面体编码**成 2 个 float，
   写成第三个 UV 层（`TEXCOORD_2`），blender 依旧会丢，所以照 `-uv.json` 的套路进 side-car。
   编码（单位向量 → `[0,1]²`，精度由 float32 保证，不需要量化）：

   ```python
   def oct_encode(n):
       x, y, z = n
       l = abs(x) + abs(y) + abs(z)
       x, y = x / l, y / l
       if z < 0.0:
           x, y = (1.0 - abs(y)) * (1 if x >= 0 else -1), (1.0 - abs(x)) * (1 if y >= 0 else -1)
       return (x * 0.5 + 0.5, y * 0.5 + 0.5)
   ```

2. `pack_usd.py` 仿照 `inject_second_uv()`（`:121-157`）注入
   `primvars:st2`（`Sdf.ValueTypeNames.TexCoord2fArray`，`faceVarying`，与 st1 同长度/同序）。

3. Metal 侧读：

   ```metal
   static float3 octDecode(float2 e) {
       e = e * 2.0f - 1.0f;
       float3 n = float3(e, 1.0f - fabs(e.x) - fabs(e.y));
       if (n.z < 0.0f) {
           n.xy = (1.0f - fabs(n.yx)) * float2(n.x >= 0.0f ? 1.0f : -1.0f,
                                               n.y >= 0.0f ? 1.0f : -1.0f);
       }
       return normalize(n);
   }
   // 在 outlineVertex 里：
   float3 hardNormal = octDecode(params.geometry().uv2().xy);
   ```

   头文件确认：`RealityKitGeometryModifier.h:81` `RK_API float4 uv2(...) RK_AVAILABILITY_IOS_18`，
   访问器在 `:416-420` `geometry.uv2()`；surface shader 也有（`RealityKitSurfaceShader.h:307`），
   所以调试时可以直接在 `toonSurface` 里把解码结果当颜色画出来。
   我们 `project.yml:12` 的 `IPHONEOS_DEPLOYMENT_TARGET = 26.0`，满足 iOS 18+。

4. **【未确定】** RealityKit 是否把 `primvars:st2` 映射成 `uv2()`。`st1 → uv1` 我们已经在用
   （头发 sheen 走的 `params.geometry().uv1()`），所以映射规律大概率一致，但**必须先验一次**：
   加个 `EIDOLON_3D_DEBUG_UV2` 分支把 `uv2()` 画成颜色，若全是 0 就说明没喂进来。
   兜底方案（按代价排序）：
   - 把硬法线塞进 `primvars:st1`，只有**没有** `TEXCOORD_1` 的 mesh 用；
   - 给描边 material 单独复制一份 mesh，把硬法线写进 `normals`（顶点数翻倍）；
   - geometry modifier 里 `set_custom_attribute()` 之后 surface 读（只能同一次绘制内传递，除非
     基座 pass 也挂 geometry modifier）。

### 3.2 深度偏移与精确宽度链

**深度偏移**（`METAL/Custom__Chr_Basic__blob2_MetalVS.metal:148-152`，逐字）：

```metal
shift = lerp(_ZShift1000Min, _ZShift1000Max, T.z * T.z);   // T = 归一化视空间硬法线
out.z = clip.z - 0.001 * shift;                            // 0.001 是字面量
out.w = clip.w;
```

- `T.z` 是**视空间硬法线的 z 分量**，所以正对/背对镜头的顶点偏移最大，侧面为 0。
- `_ZShift1000Min/Max` 是材质常量：皮肤 `0.001 / 0.02`，`Chr_Glow`（ss003 演出服）`0.02 / 40`，
  相差 2000 倍。名字叫 "1000" 是因为再乘 0.001。
- 【推论】方向：唯一合理的解释是"把壳往后沉一点，别跟本体争深度"。在 reversed-Z 下
  `clip.z` 变小 = 变远；换算成视空间位移是 `Δz_view = -0.001*shift / P[2][2]`。
  因为 `P[2][2] ≈ near/far ≈ 1e-4…1e-2`，同样的 clip 偏移对应的世界位移很大（皮肤 ~cm 级，
  glow 的 40 会到米级）。**这个量级没法直接照搬**，我们只需要"往远推一点点"。
  【未确定】`_ZShift1000Max=40` 到底是给哪套相机调的。

**宽度链**（`METAL/Custom__Chr_Basic__blob2_MetalVS.metal:109-147`，逐行还原）：

```metal
T   = normalize(视空间硬法线);
nP  = float2(P[0].xy*T.x + P[1].xy*T.y + P[2].xy*T.z);      // 方向在裁剪空间的投影
nearZ = P[2].z * (-near) + P[3].z;                           // 两个分支的 z（见下）
depth = max(0, (1 - clip.z/near) * far);                     // = 视空间深度 d（reversed-Z 下）
k  = (nearZ + depth) / (_TanFov * P[1].y * _ProjectionParams.x);
k  = k * min(_ScreenParams.x/_ScreenParams.y, 1) - 1;        // 竖屏收窄
k  = _OutlineZadj * k + 1;                                   // 实机 1.0
out.xy = clip.xy + nP * k * _Outline * (1 - _FlashParams.y); // 实机 ×0.85
```

三个坑：

1. **`0.7` 只在 OpenGL 风格 `[-1,1]` 深度的分支里**。源码是
   `u_xlat4 = (P22*(-near)+P32 < 0) ? (0.7*nP, -(P22*near+P32)) : (nP, P22*(-near)+P32)`。
   代入：GL 风格（`m22=-(f+n)/(f-n), m23=-2fn/(f-n)`）该式 = `-n < 0` → 走 0.7；
   D3D/Metal 风格（`m22=-f/(f-n), m23=-fn/(f-n)`）该式 = `0`；reversed-Z
   （`m22=n/(f-n), m23=nf/(f-n)`）该式 = `+n`。后两者都不小于 0，**所以 0.7 在 Metal 上不生效**。
   `research-mltd-shading-math.md:459` 里那条 `nP * 0.7 * k * _Outline` 应该删掉 0.7。
2. **`1 - _FlashParams.y`**：`_FlashParams = (0, 0.15, 0.998, 0)`，所以实际宽度再乘 **0.85**。
3. **`depth` 只有在 reversed-Z 下才等于视空间深度**（`1 - clip.z/near ∈ [0,1]` 等价于
   `clip.z ∈ [0, near]`，只有 reversed-Z 的 `clip.z = n(f-d)/(f-n)` 满足）。非 reversed-Z
   时 `depth` 和 `nearZ` 都是 0，`k` 恒为 0——描边壳会完全不动。游戏显然不是这样，
   所以 **Unity 的 Metal 后端是 reversed-Z**【推论，但很硬】。
   （旁证：fog 用的是同一个 `UNITY_Z_0_FAR_FROM_CLIPSPACE` 表达式。）

**能查到的常量**（全部能从 `view_to_projection()` 反推）：

| 常量 | 来源 | RealityKit 里怎么拿 |
|---|---|---|
| `_ProjectionParams.y`（near） | 相机 | `near = P[3][2] / (P[2][2] + 1)`（reversed-Z 透视；代入 `n=0.1,f=100` 得 0.1 ✓） |
| `_ProjectionParams.z`（far） | 相机 | 只出现在被 `depth` 替换掉的式子里，**不需要** |
| `_ProjectionParams.x`（±1） | 平台翻转 | 正常取 1；`P[1][1] < 0` 时取 −1 |
| `_ScreenParams.x/y`（aspect） | 屏幕 | `aspect = P[1][1] / P[0][0]`（`P11 = 1/tan(fov/2)`、`P00 = 1/(tan·aspect)`） |
| `P[1].y` | 投影矩阵 | `P[1][1]` |
| `clip.z / clip.w` | — | 用 `model_to_view()` 的 `-z` 直接算 `d`，完全绕开 clip 空间 |
| `_Outline` | **材质** | 0.0005（全部）——**不在图集里** |
| `_TanFov` | **材质** | 0.221695（全部）——不在图集里 |
| `_OutlineZadj` | **材质** | 1.0（全部）——不在图集里 |
| `_FlashParams` | **材质** | 本批全是 `(0,0.15,0.998,0)`——不在图集里 |

**可以直接抄的 RealityKit 版本**（几何修饰器里，全部用模型空间结算）：

```metal
// —— 常量 ——
float4x4 P  = params.uniforms().view_to_projection();
float4x4 MV = params.uniforms().model_to_view();
float tanActual = 1.0f / max(P[1][1], 1e-6f);        // tan(fov/2)
float aspect    = P[1][1] / max(P[0][0], 1e-6f);     // w/h
float nearZ     = P[3][2] / (P[2][2] + 1.0f);        // reversed-Z 透视
//   万一算出来 ≤0 或离谱，说明 RealityKit 不是 reversed-Z：直接令 nearZ = 0
//   （near ≪ d，影响不到 0.1%），下面的公式照用。

// —— 顶点 ——
float3 hardNormal = octDecode(params.geometry().uv2().xy);   // 见 §3.1
float3 posView = (MV * float4(params.geometry().model_position(), 1.0f)).xyz;
float  d       = max(-posView.z, 1e-4f);              // 就是游戏里的 depth
float3 Tview   = normalize((MV * float4(hardNormal, 0.0f)).xyz);

// —— 宽度（逐字对应游戏，0.7 已证明不生效）——
float k = _OutlineZadj * ((d + nearZ) * min(aspect, 1.0f) * tanActual / _TanFov - 1.0f)
        + 1.0f;
float halfWidth = _Outline * k * 0.85f;               // 0.85 = 1 - _FlashParams.y

// —— 方向：游戏只推屏幕平面内的分量（P[2].xy = 0），我们照做 ——
float3 offsetView  = float3(Tview.xy, 0.0f) * halfWidth;
float3 offsetModel = transpose((float3x3)MV) * offsetView;   // 刚体逆 = 转置

// —— 深度偏移：把壳往远推一点点（游戏是 clip.z -= 0.001*lerp(min,max,T.z²)）——
//   Δz_view = -0.001 * lerp(_ZShift1000Min, _ZShift1000Max, Tview.z*Tview.z) / P[2][2]
//   量级不可靠（见 §3.2），实际用一个小的固定量，或者干脆只靠 writesDepth
offsetModel += transpose((float3x3)MV) * float3(0.0f, 0.0f, -kDepthBias);

params.geometry().set_model_position_offset(offsetModel);
```

对照我们现在的实现（`ToonShading.metal:194-217`）：
- 现在沿**完整模型空间法线**推（含 z），游戏只推**屏幕平面内的分量** → 正面/鼻子这类
  法线朝镜头的部位，我们会往镜头方向推、游戏往侧向推，轮廓会不一样。
- 现在是 8.5 行的经验常数 `outlineHalfWidth = 0.0014`；按上面公式、`d=10`、竖屏
  `aspect≈0.46`、`_Outline=0.0005`，`k ≈ 0.46×10.1 − 1 ≈ 3.6`，半宽 ≈ `0.0015`——
  **现在这个常数其实就是竖屏下的近似值**，横屏（`min(aspect,1)=1`）会差 2.5 倍。
- 现在 `modelScale` 那一步在公式化之后不需要了：`transpose((float3x3)MV)` 直接把视空间
  位移转回模型空间。

---

## 4. 全量覆盖核对（55 套已导出模型）

统计口径：`build/mltd-corpus/*/*-materials.json` 的每个材质名 → 回到源 bundle 读
`m_ValidKeywords` 得到关键字。**扫描时目录里有 55 套**（导出脚本还在跑，数量会继续涨；
任务描述里的"40 套"是更早的快照）。也因为导出在跑，个别刚写出的套可能没并进关键字表，
所以下面的套数会与目录里的文件数差 ±1；下表统计的是"材质组合"，同一套里两种组合会各记一行。

| 套数 | shader | 有效关键字 | 我们覆盖了吗 |
|---|---|---|---|
| 55 | `Custom/BultIn/Bi_CharEye` | `_GPU_TYPE_PIXEL_PROCESSING _LENS_ON _UP_SIDE_VECTOR_DANCE _VTC_ON` | ✅ kind 5 |
| 55 | `Custom/Chr_Basic` | `_RIMLIGHTON_ON` | ✅ kind 1 |
| 46 | `Custom/Chr_Hair` | `_RIMLIGHTON_ON _SUBADD_ON` | ✅ kind 4（只做了 ADD 分支） |
| 22 | `Custom/Chr_Face` | `_EXTRABIHAKU_ON _ISBIHAKU_ON _RIMLIGHTON_ON` | ✅ kind 3 |
| 17 | `Custom/Chr_Face` | + `_USESQRT_ON` | ✅（`_USESQRT_ON` 无变体，死关键字） |
| 16 | `Custom/Chr_Basic_NoOutline` | `_ISCUTOFF_ON _RIMLIGHTON_ON` | ⚠️ kind 1 + 黑键 discard；**rim 简化分支没做**（差异很小） |
| 13 | `Custom/Chr_Alpha` | `_ZWRITE_ON` | ❌ **只当 Basic+黑键，没有混合** ← P0 |
| 11 | `Custom/Chr_CutOff` | `_ZWRITE_ON _RIMLIGHTON_ON` | ✅（近似） |
| 9 | `Custom/Chr_Hair` | `_RIMLIGHTON_ON`（**无** `_SUBADD_ON`） | ❌ 我们永远走 ADD 分支 → 这 9 套的 sheen 偏亮 |
| 6 | `Custom/Chr_Basic` | `_RIMLIGHTON_ON _USEREFLECT_ON` | ❌ ← P1 |
| 1 | `Custom/Chr_Basic_NoOutline` | `_ISCUTOFF_ON _RIMLIGHTON_ON _USEREFLECT_ON` | ❌ |
| 1 | `Custom/Chr_Color` | `_RIMLIGHTON_ON`（013hib 的 `ch_ex035_a_acc03chr_m`） | ❌ shader 本身没实现 |

其它备选、但 0 套用到的：`Custom/Chr_Span`、`Custom/Chr_Color_NoOutline`、`Custom/Chr_Shadow`、
`Custom/Chr_OutlineOnly`、`Custom/PlusAO/*`（PlusAO 只是多一张 AO 图，数学与基座相同）。

**结论**：真正要补的只有四件事，按前面的优先级表：`Chr_Alpha` 混合（13 套）、
`_USEREFLECT_ON`（6 套 / 7 个材质）、`Chr_Hair` 的非 SUBADD 分支（9 套）、`Chr_Color`（1 套）。
MOSAIC / REDDISH / `_USESQRT_ON` / `_ALPHAPREMULTIPLY_ON` / `_ZWRITE_ON` / `_EMISSION` /
`_ANTILEVITATE_ON` 都没有对应变体，不用管。

---

## 5. 顺带发现的三个问题

### 5.1 `_ALPHAPREMULTIPLY_ON` 是噪音

436 个材质带它（`Chr_Basic_NoOutline` 396 / `Chr_Basic` 37 / `Chr_Alpha` 2 / `Chr_CutOff` 1），
但 `Chr_Basic_NoOutline` 的变体空间恰好是 `{MOSAIC_ON, _ISCUTOFF_ON, _USEREFLECT_ON}` 的
**幂集**（8 个，全部列出过），没有它。所以它选不中任何程序，不影响任何东西。
`Chr_Alpha` 那 2 个也不在已导出的 55 套里。

### 5.2 `_ISCUTOFF_ON` 的 rim 是另一条简化路径

`METAL/Custom__Chr_Basic_NoOutline__blob20_MetalFS.metal` 比 blob18 少了整段 `_RimCtrl`
重算，改成 `rim = clamp(TEXCOORD1.y,0,1) * _RimColor`，并且跳过 `TEXCOORD6`。
我们一直用完整路径。16 套带 `_ISCUTOFF_ON` 的材质会受影响，但 `_RimColor` 是白色、
rim 面积很小，肉眼难辨。

### 5.3 `address::clamp_to_edge` 和 tiled UV 冲突（**值得单独确认**）

`ToonShading.metal:73-77` 的 `kAtlas` 用 `clamp_to_edge`。但身体类 mesh 的 UV 是大范围平铺的
【一手，导出后的 glTF】：

```
003mik body/skin/02alp   u ∈ [-0.00, +4.61]   v ∈ [0, 1]
001har body/skin/02alp   u ∈ [-0.98, +2.01]
008tak body/skin/02alp   u ∈ [-3.50, +4.50]
```

如果贴图本身是四方连续的布料图，clamp 会把 `u>1` 的部分拉成边缘像素的条纹。
【未确定】端上目前看不出来，可能是贴图接近常量、也可能我没意识到。快速验证：给 body
换一张有明显棋盘格的贴图再看。真要修，就是"每个材质一张独立 PNG，本来就没有 atlas 串色
问题"→ 直接换成 `address::repeat`（mip 也一样）。

---

## 6. 复现方法

本次所有脚本都是 `/tmp` 里的一次性临时件（已删）。核心逻辑都很短，照下面重写即可：

```bash
# 1. 列出某个 shader 真正编译出来的变体（关键：m_PlayerSubPrograms → 子程序 blob）
#    UnityPy: env.objects → Shader → m_ParsedForm → 每个 pass 的 progVertex/progFragment
#    → m_PlayerSubPrograms[*][*].m_BlobIndex → 解 LZ4 → ShaderSubProgram(r).m_Keywords
uv run --with UnityPy python sub_kw.py data.unity3d "Custom/Chr_Basic_NoOutline"

# 2. 读 pass 状态的属性绑定（obj.read_typetree()，字段的 name = 材质驱动，<noninit> = 字面值）
uv run --with UnityPy python dump_state_names.py <bundle> "Custom/Chr_Alpha"

# 3. 扫 bundle 里的材质关键字（m_ValidKeywords / m_InvalidKeywords 分开存，别混）
uv run --with UnityPy python scan_materials.py bundle_list.txt out.json

# 4. 用字符串粗筛哪批 bundle 含某个关键字（3 秒扫完 6.8G）
grep -rla "_ISREDDISH_ON" ~/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents/Cache00

# 5. 读 mesh 顶点通道（通道号 / 格式 / 维度 / tangent 统计）
#    m_VertexData.m_Channels[i] = (stream, offset, format, dimension)，i 就是 VertexAttribute
uv run --with UnityPy python mesh_detail.py ch_pr001_014mir.unity3d
```

> 踩过的坑：`m_ShaderKeywords` 在 UnityPy 里经常是 `None`，真正的内容在
> `m_ValidKeywords` + `m_InvalidKeywords`；`m_ValidKeywords` ≠「shader 声明了它」，
> 上面 §2 的变体表才是唯一可信的「哪些关键字会改变程序」。

一手来源索引：

- 混合：`METAL/Custom__Chr_Alpha__blob4_MetalFS.metal:55-58,81-82`、
  `blob5_MetalFS.metal:59-60`、`METAL/Custom__Chr_CutOff__blob3_MetalFS.metal:56-60`、
  `STATE`（bundle `04/b4207e43…` 的 `Chr_Alpha` pass）、`bundle 材质 _BlendSrc=5/_BlendDst=10`。
- 反射：`METAL/Custom__Chr_Basic_NoOutline__blob6_MetalVS.metal:191`、
  `blob22_MetalFS.metal:100,107-108`、材质 `ch_ex052_a_acc01bref_m`（Cubemap `ch_ex052_a_acc06ref` 32²）。
- MOSAIC：`METAL/Custom__Chr_Basic_NoOutline__blob19_MetalFS.metal:78-105,155,160`、
  `blob3_MetalVS.metal:131`、`global-metadata.dat` 里的 `_MosaicTiling` 等字符串。
- 腮红：`METAL/Custom__Chr_Face_NoOutline__blob6_MetalFS.metal:99-121`。
- 描边：`METAL/Custom__Chr_Basic__blob2_MetalVS.metal:91-152`、
  `METAL/Custom__Chr_Basic_NoOutline__blob2_MetalVS.metal:62-68`（顶点输入含 TANGENT）、
  mesh `ch_pr001_014mir.unity3d` 的 `m_VertexData.m_Channels`。
- RealityKit：`RealityKitGeometryModifier.h:81,104-110,416-420`、
  `RealityKitSurfaceShader.h:307,592-598`、
  `RealityFoundation.swiftinterface:3554-3556`（`Blending` 只有 opaque/transparent）。
- 我们：`spikes/porting-3d/ios/ToonShading.metal:63-67,156-163,194-217,219-247,355-400`、
  `spikes/porting-3d/ios/ToonShading.swift:23-86,94-120`、
  `spikes/porting-3d/material_atlas.py:24-71,77-92,103-110`、
  `spikes/porting-3d/ios/MaterialParameters.swift:33-49`、
  `spikes/porting-3d/pack_usd.py:121-157`、`spikes/porting-3d/export_character.py:266-277`。

---

> **提醒**：本文含逐行反编译引用，按 `spikes/porting-3d/.gitignore` 里已有的三条先例
> （`research-mltd-shading-math.md` / `research-sheen-and-colour-gaps.md` /
> `research-face-and-normals.md`），**应当把 `research-remaining-variants.md` 加进同一个
> `.gitignore`**。我没有替你改，也没有 `git add`/`commit` 任何东西。
