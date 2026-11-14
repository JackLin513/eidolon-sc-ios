# 贴图 alpha 的端到端追踪：0 → 128 到底发生在哪一步

调查日期：2026-10-30。分支 `spike/mltd-3d-static`。只读调查 + `/tmp` 实验：仓库实现未改，
`build/` 里的语料只被读取/复制，没有写回；`/tmp` 里的工程副本与产物在本轮结束后删除。

---

## 结论

1. **0 → 128 只发生在一个地方：`export_character.add_image()` 里的 `cutout_safe()`。**
   它把 `alpha < 128` 的像素 `paste((0,0,0,255))`，于是透明区的 alpha 被写成 **255**，
   整张图的最小 alpha 变成 128（或更大：046rio 是 131，因为它没有 128–130 的值）。
   这一步之后，PNG → glTF 引用 → Blender `.usdc` → `pack_usd` → usdz 内嵌 PNG
   **逐字节不变**（实测 sha256 相同），后面的阶段没有任何一处再动 alpha。

2. **不是"材质引用了另一张同名纹理"，也不是解码路径差异。**
   `cb_pr001_001har_02alp_m` / `cb_pr001_003mik_02alp_m` 的 `_MainTex` PPtr 的 path_id
   分别等于 bundle 里唯一一张同名 `Texture2D` 的 path_id；两张都是
   `ASTC_RGBA_6x6`（format 56），UnityPy 解出来都是 `(0, 255)`。

3. **001har 与 003mik 的不对称，真正原因是 shader 家族不同：**
   - `001har` 的 `cb_pr001_001har_02alp_m` 用 **`Custom/Chr_CutOff`**
     （queue `AlphaTest`，`RenderType=TransparentCutout`，`_AlphaTestValue=0.5`）。
   - `003mik` 的 `cb_pr001_003mik_02alp_m` 用 **`Custom/Chr_Alpha`**
     （queue `Transparent`，`RenderType=Transparent`，无 `_AlphaTestValue`）。
   - HEAD（44c9908）里 `keep_alpha` 的条件是 `info.shader == "Custom/Chr_Alpha"`，
     所以同一段代码下 003mik 保留 `(0,255)`，001har 仍然被 `cutout_safe` 压成 `(128,255)`。
   - **当前工作树把 `keep_alpha` 关掉了**（`git diff` 里那 5 行未提交改动），
     所以 11:53 重导的语料里 **003mik 的实际产物也是 `(128, 255)`**，
     不是 `(0, 255)`。现在磁盘上唯一 `(0,255)` 的 `02alp` 是 11:44 导出的
     `202xxx-gs001`——它的兄弟材质 `02cut` 在**同一次运行**里仍是 `(128,255)`，
     正好证明差异来自 `keep_alpha` 判据（shader 名），而不是纹理本身。

4. **128 不是原画设计出的下限，是导出器造出来的。** 源纹理：
   001har 的 `02alp` 有 17.6% 的像素 `a=0`；003mik 有 41.3%；
   202xxx 的 `02alp` 有 24.0%。`a=0` 处的 RGB 是暗红/杂色（例：`(129,90,90)`、
   `(87,54,47)`、`(36,71,102)`），不是黑色。`cutout_safe` 把这些像素改成不透明黑，
   是为了让 shader 的"近黑即丢弃"能顶替 alpha test。

5. **开混合后的观感**（按源数据推算，端上未跑）：
   - 轮廓不变：当前硬边 = `a ≥ 128`；游戏 alpha test 阈值是 `0.5`，也是 `a ≥ 128`，
     两者边界一致（`cutout_safe` 的 128 正是 `0.5×255` 向上取整）。
   - 真正变化的是边缘：`a ∈ [1,127]` 的像素（各角色 0.5%–11.7%）以前被丢弃，
     以后会淡淡地显出来；`a ∈ [128,254]` 的软边（0.6%–15.4%）以前硬切，
     以后平滑过渡。
   - `a=0` 的区域从"被近黑测试丢掉"变成"真实透明"，视觉上等价；但观察背景会从
     "透过洞看到后面的身体"变成"和身体做 50% 混合"，这是游戏里本来就有的效果。

6. **范围和顺序**：端上只能对 `Chr_Alpha` 开混合，且**导出器和端上必须同一次切换**。
   语料里已经存在一个"半切换"的实例：`202xxx-gs001` 在 11:44 用 HEAD 代码导出了
   真 alpha（usdz 里 opacity 已接上），但端上仍把它当 cutout（`_IsCutOff=1` + 近黑
   discard），而它的隐藏色不是黑色，所以这个子网格现在会画成一块不透明暗色。
   反方向也不行：老语料的透明区已经被写成 `(0,0,0,255)`，端上先开混合会得到实心黑块。

---

## 一次性落地清单

### A. 导出器（Python）

1. `spikes/porting-3d/export_character.py:236-240` —— 恢复 `keep_alpha`
   （就是当前工作树 revert 掉的那一行）：
   ```python
   pbr["baseColorTexture"] = {
       "index": add_image(info.image, key, keep_alpha=info.shader == "Custom/Chr_Alpha")
   }
   ```
   只对 `Chr_Alpha` 生效；`Chr_CutOff` / `Chr_Basic_NoOutline` 的 `02alp` 继续走
   `cutout_safe`（它们本来就该被裁掉）。

2. `spikes/porting-3d/material_atlas.py:82-95` —— `SHADER_KINDS["Custom/Chr_Alpha"]`
   从 `1` 改成新的 `6`（Metal 侧同步加 `kKindAlpha = 6.0`）。

3. `spikes/porting-3d/material_atlas.py:113-125` —— `_IsCutOff` 必须先判断
   `shader == "Custom/Chr_Alpha"` 并返回 0。**只删掉 `shader.endswith("Chr_Alpha")`
   不够**：下面的 `"cut" in name or "alp" in name` 回退会把 `_02alp_m` / `_02cut_m`
   重新标成 1（202xxx 的材质名正好是 `02alp`、贴图名是 `02cut`）。
   顺带：006mak 这类 `Chr_Basic_NoOutline` 材质其实**存了** `_IsCutOff=1.0`（还有
   `_ISCUTOFF_ON` 关键字），比按名字猜更可靠，可以顺手改成"先读浮点/关键字，再回退"。

4. `spikes/porting-3d/pack_usd.py` **不改**。已验证：谓词
   `table[name]["shader"] == "Custom/Chr_Alpha"` 在真实 stage 上把 003mik 的
   `cb_pr001_003mik_02alp_m` 接上了 opacity；全语料 14 个 `Chr_Alpha` 材质
   14/14 都能找到 `diffuseColor ← UsdUVTexture`，没有遗漏。

### B. 端上（Metal / Swift）

5. `spikes/porting-3d/ios/ToonShading.metal:65-69` —— 加 `constant float kKindAlpha = 6.0;`。

6. 同一文件的分发必须**同时**给 Eye、Hair、Face、Glow 四个分支加"排除 6"的条件：
   - `:344` `if (kind > kKindEye - 0.5f)`：`6 > 4.5` 会直接进 `Bi_CharEye` 分支
     （读 `_IrisColor` / `_SubTex.r`），画面会变成错误的虹膜色。
   - `:455` `if (kind > kKindGlow - 0.5f && hasParams)`：`6 > 1.5` 会再套一层
     `_GlowColor` / `_WhityCol` 混合；`Chr_Alpha` 没有 `_SubTex`，结果是错的。
   - 最省事的写法：Eye 条件改成 `kind > kKindEye - 0.5f && kind < kKindAlpha - 0.5f`，
     Glow 条件同样加 `< kKindAlpha - 0.5f`，其余落到 Basic 分支。

7. 同一文件 `:479` `writeColour(params, result);` 之后，只对 alpha kind 设置不透明度：
   ```metal
   if (kind > kKindAlpha - 0.5f) {
       params.surface().set_opacity(float(mainTexRaw.a));   // = mainTex.a，alpha 未做 gamma
   }
   ```
   **不要对所有材质都设**：001har 的 `01` 身体贴图 alpha 范围是 `(229,255)`，
   全设会让整个身体变成 90% 不透明并进入透明队列。

8. `spikes/porting-3d/ios/MaterialParameters.swift:51-58` —— 这是一个**清单里原先没有的
   第四处**：`Document.Material` 已经把 `shader` 解出来了，但只用于计数校验，随后丢弃。
   Swift 侧需要知道"哪些材质要开混合"，建议加
   `func isBlended(for:) -> Bool`（`shader == "Custom/Chr_Alpha"`）或 `shader(for:)`。
   靠材质名（`_02alp`）判断不稳，202xxx 的贴图还叫 `02cut`。

9. `spikes/porting-3d/ios/ToonShading.swift:23-90` —— 在 `toon.custom = custom` 之后：
   ```swift
   if parameters?.isBlended(for: name) == true {
       toon.blending = .transparent(opacity: .init(floatLiteral: 1))
   }
   ```
   `opacity` 参数必须是 1：实测透明管线自己乘一次 opacity，shader 里再乘就成 `a²`。

10. `spikes/porting-3d/ios/ToonShading.swift:94-120` —— `applyOutline` 必须**跳过**
    混合材质。游戏里 `Custom/Chr_Alpha` 只有一个 `BASE` pass，**没有 `OUTLINE` pass**
    （`Chr_Basic` 才有 `BASE + OUTLINE`）。现在 `Model3DPreview.swift:345-346` 会克隆
    整个模型再套 outline；壳是 front-cull + 外推的，会从半透明处透出来，变成一圈黑影。
    可以在 `applyOutline` 里检查 `if let source = material as? CustomMaterial,
    case .transparent = source.blending { return material }`，或者把
    `MaterialParameters` 一起传进去按 row/名字判断。

11. `spikes/porting-3d/ios/ToonShading.metal:178` —— outline 里的 `_IsCutOff` 判断不用动：
    第 3 步之后 `Chr_Alpha` 的该字节已经是 0，而且第 10 步会直接不画它的壳。

### C. 重导哪些

`_params.png`（材质参数图集）里 `Chr_Alpha` 的 kind 和 `_IsCutOff` 字节都会变，
所以下面这些模型**必须重导**（不只是换贴图）：

| 模型 | 说明 |
|---|---|
| `003mik, 019min, 022ser, 023aka, 029umi, 030iku, 037nao, 038chz, 041fuk, 042miy, 045kar, 046rio, 050jul`（pr001） | 语料里全部 13 个 pr001 `Chr_Alpha` |
| `202xxx-gs001` | 第 14 个 `Chr_Alpha`，且已带真 alpha，只需删掉旧 usdz 重导 |

其余 24 个 `02alp` 不用动：12 个 `Custom/Chr_CutOff`、12 个
`Custom/Chr_Basic_NoOutline`（它们本来就该是 alpha test / 近黑裁切）。
重导方式（`export_corpus.py` 默认跳过已存在的 usdz）：

```sh
# 只让这 14 个重跑
for m in 003mik 019min 022ser 023aka 029umi 030iku 037nao 038chz \
         041fuk 042miy 045kar 046rio 050jul; do
    rm -f "build/mltd-corpus/$m-pr001/$m-pr001.usdz"
done
rm -f build/mltd-corpus/202xxx-gs001/202xxx-gs001.usdz

build/mltd-spike/venv/bin/python spikes/porting-3d/export_corpus.py \
    --index build/mltd-index.jsonl --out build/mltd-corpus \
    --blender /path/to/Blender.app/Contents/MacOS/Blender
# 202xxx-gs001 用当初生成 11:44 那批 gs001 的同一条命令重跑
```

（本机实际用的 UnityPy 1.25.4 venv 在
`/Users/jacklin/Developer/IdeaProjects/eidolon-sc-ios/build/mltd-spike/venv`，
Blender 4.5.15 在
`/Users/jacklin/Developer/IdeaProjects/eidolon-sc-ios/build/mltd-spike/Blender.app`。）

### D. 可选护栏

12. `spikes/porting-3d/check_corpus.py` 可以加一条：`shader == "Custom/Chr_Alpha"` 的
    材质，如果对应 PNG 的最小 alpha 是 128（或 131），说明还是 `cutout_safe` 的产物，
    报 warn/error。这个 bug 正是这样被发现的，值得固化。

---

## 证据链

### 1. 材质引用的是不是"同名纹理"？是

```
001har  textures named cb_pr001_001har_02alp count 1 [(512550850918269813, ...)]
        material cb_pr001_001har_02alp_m  _MainTex PPtr -> 512550850918269813
003mik  textures named cb_pr001_003mik_02alp count 1 [(-3740006927931345059, ...)]
        material cb_pr001_003mik_02alp_m  _MainTex PPtr -> -3740006927931345059
```

- 两张都是 `ASTC_RGBA_6x6`（format 56），256×128 / 256×256，mip 9。
- `environment.m_Texture.read().m_Name` 与按名字搜到的 `Texture2D` 同名且同 path_id。
- 没有平台覆盖纹理参与：`m_StreamData.path` 指向同一个 `.resS`，
  `read().image` 直接给 RGBA。
- 对照：003mik 的 `01` 身体贴图才是 `ASTC_RGB_6x6`（format 50，无 alpha），
  说明解码器确实按每张纹理的 format 走，但两张 `02alp` 的 format 一样、结果也一样。

### 2. 逐阶段 alpha extrema

| 阶段 | 001har（`Chr_CutOff`） | 003mik（`Chr_Alpha`） |
|---|---|---|
| UnityPy `info.image`（材质真正引用的那张） | **(0, 255)** | **(0, 255)** |
| `add_image` 处理（当前工作树，`keep_alpha` 关） | **(128, 255)** ← `cutout_safe` | **(128, 255)** ← `cutout_safe` |
| `add_image` 处理（HEAD 44c9908，`keep_alpha` 只给 `Chr_Alpha`） | **(128, 255)**（shader 不是 Chr_Alpha） | **(0, 255)** |
| `textures/NN_*.png` | 同上 | 同上 |
| glTF `images[].uri` | 同一个 PNG 文件（外部引用，不重编码） | 同 |
| Blender `.usdc` `UsdUVTexture.inputs:file` | `@./textures/00_cb_pr001_001har_02alp_m.png@` | `@./textures/02_cb_pr001_003mik_02alp_m.png@` |
| `.usdz` 内嵌 PNG | `(128,255)`，sha256 与导出 PNG **相同** | `(0,255)`（keep 版）/ `(128,255)`（现语料），sha256 **相同** |

复现实验的四个变体（同一套 bundle、同一台机器）：

| 变体 | 导出代码 | 001har 02alp | 003mik 02alp |
|---|---|---|---|
| `har-cut` | 当前工作树（无 keep_alpha） | (128, 255) | — |
| `mik-cut` | 当前工作树 | — | (128, 255) |
| `har-keep` | HEAD 44c9908 | (128, 255) | — |
| `mik-keep` | HEAD 44c9908 | — | **(0, 255)** |

也就是说：**只要材质是 `Chr_Alpha` 且 keep_alpha 打开，0 就能一路活到 usdz；
`Chr_CutOff` 永远在第 2 步被改成 128。** 这和"纹理不是同一张"没有关系。

额外证据：11:44 那批 gs001 里，`202xxx-gs001` 的 `05_cb_gs001_202xxx_02alp_m.png`
是 `(0,255)`（`Chr_Alpha`），而同一个 bundle 的 `01_cb_gs001_202xxx_02cut_m.png`
及 `201/204/205xxx` 的所有 `02cut` 都是 `(128,255)`——同一次运行、同一段代码，
差异只在 shader 名。

### 3. `cutout_safe` 的 128 正好等于游戏的 alpha test 阈值

```python
transparent = image.getchannel("A").point(lambda a: 255 if a < 128 else 0)
black.paste((0, 0, 0, 255), mask=transparent)
```

- 001har 的 `Chr_CutOff`：`_AlphaTestValue = 0.5`，`QUEUE=AlphaTest`，
  `RenderType=TransparentCutout`。游戏丢弃 `a < 0.5`（≈127.5），
  导出器丢弃 `a < 128` 并写成不透明黑，shader 再用 `max(r,g,b) < 0.004` 丢弃。
  边界完全一致。
- 003mik 的 `Chr_Alpha`：`QUEUE=Transparent`、`_BlendSrc=5`（SrcAlpha）、
  `_BlendDst=10`（OneMinusSrcAlpha）、无 `_AlphaTestValue`、`_Color.a=1.0`。
  它本来就该混合，`cutout_safe` 是把它硬掰成 cutout。

### 4. 源数据里 alpha 到底是什么分布

| 模型 | a=0 | 1–127 | 128–254 | 255 | a=0 处的 RGB（抽样） |
|---|---|---|---|---|---|
| 001har `02alp` | 17.6% | 0.48% | 0.70% | 81.2% | `(129,90,90)` 为主 |
| 003mik `02alp` | 41.3% | 2.21% | 2.80% | 53.7% | `(87,54,47)`、`(36,71,102)` |
| 202xxx-gs001 `02alp` | 24.0% | 2.40% | 2.44% | 71.1% | `(85,40,13)`、`(97,48,6)` |

结论：透明区是**画出来的**（大片 a=0、隐藏色是暗红/杂色），不是"整张不透明、
只是导出时被误伤"。128 是人为下限。

### 5. `pack_usd` 的 alpha 接线

在 `/tmp` 的副本上跑（`pack_usd.main()` 会 `stage.GetRootLayer().Save()`，会写回
source，所以没有直接跑仓库里的 stage）：

```
$ uv run --with usd-core python pack_usd.py -- \
      /tmp/alpha-e2e/real/003mik/003mik-pr001.usdc .../003mik-pr001-repacked.usdz
alpha wired: ['cb_pr001_003mik_02alp_m']
```

- 001har 的副本：`alpha wired` 一行都没有（它没有 `Chr_Alpha`），符合预期。
- 202xxx-gs001：`alpha wired: ['cb_gs001_202xxx_02alp_m']`（11:44 的原始产物里就已经接上了）。
- 全语料静态检查（14 个 `Chr_Alpha` 材质）：每个都能在 stage 里找到同名 `Material`，
  `ComputeSurfaceSource()` 正常，`diffuseColor` 来自 `UsdUVTexture`，**0 problems**：

```
OK 003mik-pr001  cb_pr001_003mik_02alp_m  <- @./textures/02_cb_pr001_003mik_02alp_m.png@
...
OK 202xxx-gs001  cb_gs001_202xxx_02alp_m  <- @./textures/05_cb_gs001_202xxx_02alp_m.png@
Chr_Alpha materials: 14, problems: 0
```

- 接线后的图（打包后的 usdc）：

```
cb_pr001_003mik_02alp_m opacity=connected ->
  /root/_materials/cb_pr001_003mik_02alp_m/Image_Texture.outputs:a
  @./textures/02_cb_pr001_003mik_02alp_m.png@  outputs:a = True
其余 6 个材质 opacity = 常量 1.0
```

- 注意 `diffuse_texture()` 选的是 `diffuseColor` 的 `UsdUVTexture`，
  有 `_SubTex` 的材质（眼睛/头发）不会接错到 glow 图；实测眼睛的
  `diffuseColor ← Image_Texture_001`（03_...png），glow 是 `Image_Texture`。

### 6. 字节级不变

- `mik-keep`：源图（UnityPy 解出的 RGBA）与导出的 PNG **0 个像素不同**（256×256，
  含 a=0 处的 RGB），导出 PNG 与 usdz 内嵌 PNG 的 sha256 相同。
- `har-cut`、真实 `003mik` 副本同样：导出 PNG 与 usdz 内嵌 PNG 字节相同。
  Blender 的 USD 导出只是**引用** `./textures/xxx.png`，不重编码；`CreateNewUsdzPackage`
  原样打包。

### 7. 语料的实际状态（容易被文件名骗）

- 扫描全部 38 张 usdz 内嵌 `02alp`：36 张 `(128,255)`、1 张 `(131,255)`（046rio）、
  **1 张 `(0,255)`**（`202xxx-gs001`）。
- 当前 `003mik-pr001.usdz` 里是 `(128,255)`，不是 `(0,255)`。
- 因此"003mik 正常、001har 不正常"这个观察，对应的应该是 HEAD 代码的导出
  （或把 `202xxx-gs001` 记成了 003mik）。两条路都指向同一个判据：`Chr_Alpha`。

---

## 端上"三处"的遗漏与顺序陷阱

按原来的清单（atlas kind + Metal `set_opacity` + Swift `.transparent`）动手，会踩到：

1. **Metal 的 kind 分发顺序**（最硬的一处）。`kind = 6` 会先命中
   `kind > kKindEye - 0.5f`（6 > 4.5），进 `Bi_CharEye`；即使绕过，
   Basic 分支里的 `kind > kKindGlow - 0.5f` 也会命中，套上 glow 混合。
   Eye/Hair/Face/Glow 四个条件都要显式排除 6。
2. **Swift 需要第四处改动**：`MaterialParameters.Document.Material` 里的 `shader`
   字段被解码后丢弃了；不让它暴露出来，Swift 无法区分"哪些材质要 `.transparent`"。
   按名字猜（`_02alp`）会漏掉 202xxx 的 `02cut` 贴图 / `02alp` 材质这种组合。
3. **outline 必须跳过混合材质**。`Chr_Alpha` 在游戏里只有 `BASE` pass；
   `applyOutline` 会给克隆出来的每个子网格加一个 front-cull 的壳，半透明处会透出
   一圈黑影，透明区越大越明显。
4. **`_IsCutOff` 的名字回退**：删掉 `shader.endswith("Chr_Alpha")` 之后，
   `"alp" in name` / `"cut" in name` 仍会把 `_02alp_m`、`_02cut_m` 标成 1。
   必须先对 `Chr_Alpha` 返回 0。
5. **不能"只改导出"或"只改端上"**：
   - 只改导出（keep_alpha）→ 隐藏色不再是黑，近黑 discard 失效（003mik 的
     `(87,54,47)` 线性红 ≈ 0.096 ≫ 0.004），整块丝带变成不透明暗色；202xxx
     现在就是这个状态。
   - 只改端上（`.transparent` + kind 6）而素材还是旧语料 → 透明区是
     `(0,0,0,255)`，`set_opacity=1`，画出**实心黑块**。
   - 所以导出、`-params.png`、`-materials.json`、`-usdz` 必须和 App 同批更新。
6. **不要对所有材质 `set_opacity`**：001har 的身体贴图 alpha 是 `(229,255)`，
   会整体变半透明并进透明队列。只对 kind 6。
7. **`_Color.a` 目前全是 1**（14 个 `Chr_Alpha` 材质逐个查过），所以
   `opacity = mainTex.a` 就够；`LAYOUT` 里 `_Color` 只存了 r/g/b，没有 a 列。
   将来若出现 `_Color.a ≠ 1`，要么加一列，要么在导出时预乘。
8. **202xxx-gs001 是 premultiplied 变体的坑**：它的 `Chr_Alpha` 材质带
   `_ALPHAPREMULTIPLY_ON`，`_SrcBlend=1`（One）/ `_DstBlend=10`，
   `_ZWrite=0`，而 13 个 pr001 是 `_BlendSrc=5`（SrcAlpha）/ `_BlendDst=10`。
   如果它真是预乘混合，用 RealityKit 的 `C·a + dst·(1−a)` 会得到 `a²`，
   边缘偏暗。建议第一批先只处理 13 个直通 alpha 的 pr001，把 202xxx 排除，
   或者在导出时对它做 un-premultiply。**未确定**它的片段程序到底乘不乘 alpha
   （见下）。
9. **ZWrite 差异**：游戏的 `Chr_Alpha` 带 `_ZWRITE_ON`、`_ZWrite=1`；
   RealityKit 的 `.transparent` 默认不写深度（iOS 18+ 有 `writesDepth` 可以打开）。
   单层丝带影响很小，但多层重叠时排序会和游戏不同。**未确定**，需要真机/模拟器对比。
10. **渲染队列**：`.transparent` 会让这些子网格在不透明物体之后画；body 在这些
    丝带后面，背景透出量由 alpha 决定，和游戏一致。另外 `Chr_Alpha` 的
    `CullOff`（材质 `_CullMode=2`）、`ZTest Off` 在游戏里是关的，
    RealityKit 侧默认双面/深度测试的差异也值得在真机上看一眼。

---

## 未确定

- `CustomMaterial.opacityThreshold`（SDK 里存在，iOS 15+）能不能直接吃
  `custom.texture` 的 alpha。如果能，`Chr_CutOff` 可以改成"保留 alpha + 阈值 0.5"，
  不再需要 `cutout_safe` 的近黑 hack；本轮没测。
- 202xxx-gs001 的 `_ALPHAPREMULTIPLY_ON`：UnityPy 导出的 `Program "fp"` 是空的，
  看不到片段程序是否 `rgb *= a`，所以它的混合公式（One/OneMinusSrcAlpha 还是
  SrcAlpha/OneMinusSrcAlpha）未确定。
- 端上切过去之后，`ZWrite` / 深度排序 / win 窗口合成在真机上的实际观感（模拟器上
  之前验证过 `C·a + dst·(1−a)`，见 `research-alpha-survival.md`）。
- Blender 版本差异：本轮用 4.5.15，语料原始批次可能用的是 4.2；两者在
  `inputs:file` 引用和 PNG 字节上都没差异，但 `alphaMode` 一旦加进 glTF，
  Blender 是否自己写出 opacity 连接未验证（当前路线不依赖它）。

---

## 复现（全部在 `/tmp`，不写仓库）

```sh
# 1. 工程副本
rsync -a --exclude build --exclude .git --exclude 'EidolonCore/.build' \
    /path/to/eidolon-sc-ios-3dspike/ /tmp/alpha-e2e/repo/

# 2. 把 HEAD 的导出器另存一份，用来对照"keep_alpha 打开"的行为
git -C /path/to/eidolon-sc-ios-3dspike show HEAD:spikes/porting-3d/export_character.py \
    > /tmp/alpha-e2e/repo/spikes/porting-3d/export_character_head.py

# 3. UnityPy 1.25.4 + pillow（uv 环境即可）
uv run --with UnityPy --with pillow python export_variant.py \
    --module export_character_head --body <body bundle> --head <head bundle> \
    --out /tmp/alpha-e2e/out/mik-keep --name mik-keep

# 4. Blender → usdc
Blender --background --python gltf_to_usdz.py -- \
    /tmp/alpha-e2e/out/mik-keep/mik-keep.gltf /tmp/alpha-e2e/out/mik-keep/mik-keep.usdc

# 5. pack_usd（一定要在副本上跑，它会写回 source）
uv run --with usd-core python pack_usd.py -- \
    /tmp/alpha-e2e/out/mik-keep/mik-keep.usdc /tmp/alpha-e2e/out/mik-keep/mik-keep.usdz

# 6. 量每一阶段
#    - UnityPy: texture.image.getchannel("A").getextrema()
#    - PNG:     PIL.Image.open(path).getchannel("A").getextrema()
#    - usdc:    UsdUVTexture.inputs:file 指向的仍是同一个 PNG
#    - usdz:    zipfile 读 textures/*.png，直接量；并和源 PNG 比 sha256
```

关键产物（本轮已删除）：`/tmp/alpha-e2e/out/{har-cut,har-keep,mik-cut,mik-keep}/`、
`/tmp/alpha-e2e/real/{001har,003mik,gs001}/`。

---

## 还原与清理

- 仓库实现代码**未改动**：`git status` 里只有本文这一个新增未跟踪文件，
  外加调查开始前就存在的 `spikes/porting-3d/export_character.py` 未提交改动
  （把 `keep_alpha` 关掉的那 5 行）。
- `/tmp/alpha-e2e` 已删除；`build/` 下的语料只读，未写回。
- `pack_usd.py` 会 `stage.GetRootLayer().Save()`，所以本轮只在副本上运行，
  仓库里的 `.usdc` 时间戳没有变化。
- 本文和 `research-alpha-survival.md` 一样属于 spike 过程记录，不建议提交。
  建议把 `spikes/porting-3d/research-*.md` 加进 `.gitignore`（本次没有改 `.gitignore`）。
