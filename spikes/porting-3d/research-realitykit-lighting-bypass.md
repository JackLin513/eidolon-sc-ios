# RealityKit 对 CustomMaterial 的二次着色：能不能绕，怎么绕

调查日期：2026-10-30。所有实测都在本机跑过，不是从教程推的。

**测试环境**：macOS 27.0，Xcode 27 自带 iPhoneOS 27.1 / MacOSX 27.0 SDK，`RealityFoundation` + `RealityRenderer` 离屏渲染（`MTLTexture(.bgra8Unorm)`，`cameraSettings.isToneMappingEnabled` 显式开关，`MTLSharedEvent` 同步后再读回像素）。这不是 iPhone 真机，版本也不等于项目里的 iOS 26，见文末 `UNVERIFIED`。

**结论先行**：`.unlit` 并没有丢贴图绑定。黑剪影的真实原因是 `.unlit` 只认 `set_emissive_color()`，而当前 shader 只调了 `set_base_color()`。改成 `.unlit` + `set_emissive_color()` 是可行且最便宜的一条；如果真机上仍然异常，`.lit` + `base_color=0` + `emissive=最终颜色` 与 `.unlit` 实测逐像素一致，可以作为零风险回退。

---

## 1. 结论摘要

### 1.1 最推荐：`.unlit` + `set_emissive_color`（保留现有 Metal shader）

做法只有两处：

1. `ToonShading.metal` 的最终输出从 `set_base_color(result)` 改成 `set_base_color(0)` + `set_emissive_color(result)`（四个输出点都要改，包括三个 debug 分支）。
2. `ToonShading.swift` 把 `lightingModel` 固定成 `.unlit`（现成的 `EIDOLON_3D_UNLIT` 开关就是干这个的）。

补充：现有的 `EIDOLON_3D_UNLIT` 开关只切了 `lightingModel`，shader 仍然只写 `set_base_color`。打开它必然得到黑剪影——这正好就是探针里的用例 H。不是 unlit 坏了，是开关只切了一半。

代价与收益：

- 收益：RealityKit 的 PBR 光照完全不再参与，3 盏 `DirectionalLight`（2000/1100/700 lux）对角色不再有任何影响；`custom` / `emissiveColor` / `specular` 三个贴图槽在 `.unlit` 下实测都能正常采样。PBR 通道关掉后 unlit 也比 lit 便宜。
- 代价：`normal` / `roughness` / `metallic` / 光照/阴影都由 shader 自己负责（本来就是）；角色不再接收/参与 RealityKit 的光照与阴影计算。
- **无法关掉的东西**：tone mapping。`.unlit` 的 CustomMaterial 输出仍会被相机后处理 tonemap（实测 0.5 → 0.373，1.0 → 0.667）。CustomMaterial 没有 `applyPostProcessToneMap` 之类的开关。这是去掉 PBR 之后下一个要处理的问题，见 2.6。

### 1.2 零风险回退：`.lit` + `base_color=0` + `emissive=最终颜色`

同一份 shader 不改，只把 `lightingModel` 留在 `.lit`。实测在 3 盏灯、specular 槽还绑着 MLTD 参数 LUT（scale 1）的情况下，输出与 `.unlit` **完全相同**（M1/M2 vs L3/L4，见 3.4）。原因是：

- `metallic=0`、`specular=0`、`base_color=0` 时，diffuse 项 ∝ base_color = 0，specular 项 ∝ specular = 0；
- `emissive` 在 lit 里是加法项，不经过光照（`set_emissive_color` 文档原话："as the output color when using the unlit lighting model"，`RealityKitSurfaceShader.h:523-529`）。

所以这条路径的代价只是 PBR 通道仍然会跑（性能和现在一样），以及理论上环境 IBL 的残余（实测为 0，见 2.3）。

### 1.3 其余路线按性价比排序

| 路线 | 能否保留现有 Metal shader | 能否关 tonemap | 代价 |
|---|---|---|---|
| A `.unlit` + emissive | 能 | 不能 | 改 4 行 shader + 1 行 Swift |
| B `.lit` + zero-base + emissive | 能 | 不能 | 只改 shader |
| C `ShaderGraphMaterial` + `LightingModel.unlit(isTonemappingEnabled: false)`（iOS 27） | **不能**，必须把 toon 模型重写成 MaterialX 图 | 能 | 极大，且 iOS 27+ |
| D `LowLevelRenderContext` + 自定义 surface shader + `makeUnlitLightingFunction()`（iOS 27） | 能 | 未知（API 未暴露 tonemap 开关） | 大，要自己接低层渲染管线 |
| E `RealityRenderer` 离屏渲染 + 贴图合成（iOS 18+） | 能 | 能（`cameraSettings.isToneMappingEnabled = false`） | 中到大，失去 RealityView 内的深度/合成 |
| F 经验校准（反解 tonemap） | 能 | 不需要关 | 设备相关，只能近似 |

### 1.4 立刻要改的行

`spikes/porting-3d/ios/ToonShading.metal`：

- `:363` `params.surface().set_base_color(half3(toLinear(saturate(result))));`
- `:175` debug 常量分支
- `:184` debug 法线分支
- `:196` debug LUT 分支

四处都换成一个 helper：

```metal
static inline void set_surface_output(realitykit::surface_parameters params, half3 color)
{
    params.surface().set_base_color(half3(0.0h));      // 关掉 PBR diffuse
    params.surface().set_emissive_color(color);        // 唯一被 unlit 读取的输出
    params.surface().set_metallic(0.0h);
    params.surface().set_roughness(1.0h);
    params.surface().set_specular(0.0h);               // 关掉 PBR specular（lit 回退时用得上）
}
```

`spikes/porting-3d/ios/ToonShading.swift`：

- `:26-27` 把 `lightingModel` 固定成 `.unlit`（或继续用 `EIDOLON_3D_UNLIT` 开关，默认打开）。
- `:61-73` 不动：`custom.texture`、`emissiveColor.texture`、`specular.texture`（参数 LUT）在 unlit 下都实测可用。

`spikes/porting-3d/ios/Model3DPreview.swift`：

- `:365-376` 三盏灯对角色不再有影响。只预览角色时可以删；场景里还有别的 lit 内容就留着。

如果真机上 `.unlit` 仍然黑，把 `lightingModel` 拨回 `.lit` 即可，shader 不用再改（1.2 已验证等价）。

---

## 2. 逐条方法

### 2.1 问题 1：`.unlit` 为什么黑？贴图到底绑没绑？

#### 2.1.1 文档说了什么

Apple 对 `CustomMaterial.LightingModel.unlit` 的 Discussion 原文（Xcode 内置文档，`DocumentationSearch` 返回全文；URL 见文末）：

> The surface shader for a custom material has access to all of the custom material's properties as inputs, but only renders based on the value passed to `params.surface().set_emissive_color()`. RealityKit ignores any other property your shader sets on `params.surface().`

`Modifying RealityKit rendering using custom materials` 的表格也写：`.unlit` 的 "Supported Shader Outputs" 是 "Uses `set_emissive_color()` only"。

**注意文档自相矛盾**：`CustomMaterial.init(surfaceShader:geometryModifier:lightingModel:)` 的 Discussion 写的是 ".unlit ... only supports baseColor and blending"。这条和上面两条冲突，也和实测冲突。以 unlit case 页 + 实测为准：输出只认 emissive，baseColor 被忽略。

SDK 头文件里同样的提示出现两次：

- `RealityKitSurfaceShader.h:484-486`：`base_color()` 的注释 "For materials using the unlit lighting model, use set_emissive_color() instead."
- `RealityKitSurfaceShader.h:492-494`：`set_base_color()` 的注释 "For materials with the unlit lighting model, use set_emissive_color instead."
- `RealityKitSurfaceShader.h:523-526`：`set_emissive_color()` 的注释 "Use this to add light emitted for glowing materials, or as the output color when using the unlit lighting model."

#### 2.1.2 贴图绑定的直接证据

`RealityKitTextures.h` 把 `textures()` 定义为 "available in both geometry modifier and surface shader functions"（`:98-118`），每个 accessor 的文档都是 "Returns any X texture assigned to the model"，没有按 lighting model 分叉。`custom()` 的文档（`:216-223`）明确说这是你设置在 `CustomMaterial` 上的自定义贴图，"It is not otherwise used within RealityKit"；未设置时返回 `(0,0,0,1)`。

实测（完整代码见第 3 节）：同一个 `CustomMaterial`，`.unlit`，四个槽分别绑纯色贴图，surface shader 只做 `sample` 然后 `set_emissive_color`：

| 用例 | 着色模型 | 采样的槽 | 读回中心像素 (RGB) | 结论 |
|---|---|---|---|---|
| A | `.unlit` | `custom()`（红） | 0.824, 0.051, 0.020 | 绑定了 |
| B | `.unlit` | `base_color()`（绿） | 0.169, 0.914, 0.067 | 绑定了 |
| C | `.unlit` | `emissive_color()`（蓝） | 0.008, 0.031, 0.914 | 绑定了 |
| N1 | `.unlit` | `specular()`（蓝，即 MLTD 参数 LUT 槽） | 0.008, 0.031, 0.914 | 绑定了 |
| H | `.unlit` | `custom()`，但只调 `set_base_color()` | 0, 0, 0 | **黑剪影的复现** |
| I | `.unlit` | `custom()` + `emissive_color()` 相加后 emissive | 0.831, 0.082, 0.933 | 多张贴图可用 |
| L3 | `.unlit` + 3 盏灯 | `custom()` → emissive | 0.824, 0.051, 0.020 | 灯完全不影响 |

（贴图读回值不是纯 1.0/0.0，是因为 4x4 CGImage → `TextureResource(semantic: .color)` → 非 sRGB render target 的颜色空间处理；这里只关心哪个通道占优，绝对值不影响"绑没绑"的判断。）

**结论**：`.unlit` 丢贴图是误诊。黑的原因是 H：unlit 忽略 `set_base_color`，而 shader 从未设置 emissive，默认 emissive 是 `(0,0,0)`（`RealityKitSurfaceShader.h:517`）。

#### 2.1.3 风险与限制

- 该结论来自 macOS 27 的 RealityKit。项目目标是 iOS 26，两者核心渲染代码很可能一致，但没有 iOS 26 runtime 可测（本机只装了 iOS 27.0/27.1 模拟器 runtime），必须在真机上用 30 秒验证一次：
  1. 复制 `ToonShading.metal` 加一个只做 `params.surface().set_emissive_color(params.textures().custom().sample(...))` 的函数；
  2. `.unlit` 跑一次，贴图应当显示而不是黑；
  3. 再改成只 `set_base_color`，应当黑。
- `.unlit` 下 `set_normal` / `set_roughness` / `set_metallic` 都会被忽略，但本项目本来就不需要它们。
- `.unlit` 不接收光照/阴影；如果角色需要投影到地面，要另想办法（本项目目前没有）。

### 2.2 问题 2：`ShaderGraphMaterial` 行不行？

**能做的事**：`ShaderGraphMaterial` 是 "a material that comes from a shader graph in a Reality Composer Pro project, or a MaterialX shader"（文档 `ShaderGraphMaterial` 页）。它可以用 `Unlit Surface` 节点，任意数量的 `Image 2D` 贴图输入，iOS 27 起还能在 Swift 里程序化构造：

- `ShaderGraphMaterial.Program.Descriptor`（iOS 27）：`shaderGraph: ShaderGraph`、`lightingModel: LightingModel`、`isColorDitheringEnabled`、`blendMode`、`inputValues`、`constantValues`；`ShaderGraphMaterial(program:)`。
  见 `RealityFoundation.swiftinterface:13580-13606`。
- `LightingModel.unlit(isTonemappingEnabled: Bool = true)`（iOS 27），`UnlitLightingModel.isTonemappingEnabled` 文档："Whether to apply tonemapping to this material's output."
  见同文件 `:13654-13671`。
- `ShaderGraph` 本身可以程序化建图：`ShaderGraph(named:inputs:outputs:nodeLibrary:)`、`NodeLibrary(version: .materialX138/.materialX139)`、`makeNode(from:)`、`addNode`、`connect`、`encode()`。
  见 `.../SubFrameworks/ShaderGraph.framework/.../ShaderGraph.swiftinterface:189-215`、`:536-570`。

**不能做的事**：它不能承载你现有的 Metal surface shader。

- 节点来自内置的 MaterialX `NodeLibrary`；`NodeDefinition` 只有名字、输入/输出、平台可用性，**没有公开 init，也没有携带 Metal 函数体的字段**（`ShaderGraph.swiftinterface:120-188`）。
- 想用它，就得把 MLTD 的 toon 斜坡、rim、glow、逐材质参数图集、白肌椭圆等全部重写成 MaterialX 节点图。参数 LUT 这种"按行号读字节"的逻辑在节点图里也很难表达。
- 结论：这是"另一个引擎"，不是绕过。除非以后要彻底换渲染栈，否则不建议。

**它的独特价值**：`isTonemappingEnabled: false` 是唯一"官方支持、按材质关 tonemap"的开关（UnlitMaterial 的 `applyPostProcessToneMap` 只能贴一张图 + tint）。如果哪天 tonemap 成为主要障碍，而 shader 又能被图表达，这条路才值得考虑。

### 2.3 问题 3：`.lit` 在"没灯 / 没环境 / 参数退化"时到底算什么

#### 2.3.1 没有 Light 时 ambient/IBL 是 0

实测（`.lit`，`metallic=0`、`roughness=1`、`specular=0`，场景里没有任何 Light，`RealityRenderer.lighting` 保持默认 nil）：

| 输入 | 输出 |
|---|---|
| `set_base_color(0.5)`，emissive 0（D） | 0, 0, 0 |
| `environment_radiance(0.5, 1.0, 0, 0, N).diffuse + .specular` 直接当 base color（G） | 0, 0, 0 |
| `set_base_color(0)` + `set_emissive_color(0.5)`（E） | 0.502, 0.502, 0.502 |

所以在"无灯、无 IBL"时，`.lit` 没有环境兜底，就是黑；emissive 则原样通过。

#### 2.3.2 `RealityView` 有没有默认 `EnvironmentResource`

- `Scene` 本身没有 `environment` 属性（`RealityFoundation.swiftinterface:9763-9800` 的 `Scene` 声明里没有；环境不在 Scene 上）。
- `RealityViewCameraContent.environment` 的默认值是 `RealityViewEnvironment.default`，文档："The view uses any background style you apply via the view's background style." 它描述的是背景，没有说会提供 IBL。
- `RealityViewEnvironment` 只有 `.default` 和 `.skybox(_:)` 两个入口；要 IBL 得显式给 `EnvironmentResource` / `VirtualEnvironmentProbeComponent` / `ImageBasedLightComponent`。
- `RealityViewRenderingEffects` 的字段是 motionBlur、depthOfField、cameraGrain、antialiasing、dynamicRange（iOS 18+）、customPostProcessing（iOS 26+），**没有 tone mapping 开关**。
  见 `_RealityKit_SwiftUI.framework/.../arm64e-apple-ios.swiftinterface:637-670`。

因此默认 RealityView 不额外给环境光；但这一点没有在带窗口的 RealityView 里实测（我们的探针用的是 `RealityRenderer`），列进 `UNVERIFIED`。AR 模式下 ARKit 的 probe 是另一回事。

#### 2.3.3 PBR 退化成什么公式

Apple 没有公开 RealityKit 的 BRDF 公式。能确认的只有：

- `environment_radiance` 的注释："convolves environment lighting with RealityKit's physically based material model"（`RealityKitSurfaceShader.h:376-386`）。
- `DirectionalLightComponent.intensity` 单位是 lux（lumen/m²），默认 2145.7078；文档给了 lux 参考表（`DirectionalLightComponent/intensity`）。

实测关系（tone mapping 关闭，3 盏灯 2000/1100/700 lux，灯方向分别是 identity / 绕 X 0.5 rad / 绕 Y -0.5 rad，正面法线 +Z）：

| base_color | 输出 | 比值 |
|---|---|---|
| 0.25 | 0.349 | 1.40 |
| 0.50 | 0.776 | 1.55 |
| 0.75 | 1.000（截断） | ≥1.33 |

不是严格线性（原因为何未深究，可能是 sRGB/能量项/多次散射），但可以确定：**在你们的 3 灯场景里，lit 会把 base color 乘上一个 1.4–1.6 的因子，亮部直接截断**。这就是"偏饱和/偏亮"的主要来源，而且它在 shader 自己的 toon 斜坡之外又乘了一次 `N·L`，等于把方向光算了两遍。

同一组灯下：

- emissive 路径完全不受影响：`set_emissive_color(0.5)` 有灯/无灯都是 0.502（E2）。
- specular 槽绑着参数 LUT（scale 1）也不影响 emissive 路径（J）。

#### 2.3.4 结论

`.lit` 不是"base_color * (ambient + Σ N·L * lightColor)"这么干净；ambient 在有 IBL 时才存在，没有 IBL 时就是 0。想靠"把灯调小/关掉 + 只留环境"来退化成恒等，在默认环境（无 IBL）下会得到全黑，不可行。

### 2.4 问题 4：正向补偿（把光照除回去）

#### 2.4.1 `params.lighting()` 能给什么

`RealityKitSurfaceShader.h:362-410`：

```metal
struct lighting {
    struct separated_radiance { half3 diffuse; half3 specular; };
    separated_radiance environment_radiance(half3 base_color,
                                            half roughness,
                                            half metallic,
                                            half specular,
                                            float3 normal) const thread; // iOS 18+/macOS 15+
};
```

它只返回**环境光照（IBL）**卷积后的 diffuse/specular radiance。`normal` 是世界空间法线。没有方向光、点光、聚光灯的接口。

`params.uniforms()`（`RealityKitSurfaceShader.h:139-194`）只有：`time()`、`model_to_world()`、`model_to_view()`、`world_to_view()`、`view_to_projection()`、`projection_to_view()`、`custom_parameter()`。**没有 light 列表、没有 light color/intensity。**

`RealityKitMaterialParameters.h` 也只有材质常量（base_color_tint、roughness_scale、metallic_scale、specular_scale、emissive_color 等），没有场景灯光。

#### 2.4.2 可行性

- 如果你的场景**只有 IBL、没有方向光**：可以在 shader 里算 `environment_radiance()`，理论上能估出 IBL 的贡献。但 `environment_radiance` 的结果还依赖 base_color/roughness/metallic/specular/normal，而且你无法知道 RealityKit 在最终合成时是否又乘了 exposure/tonemap。
- 如果场景有方向光：shader 完全读不到灯。要除回去只能：
  1. 自己把灯的方向/强度通过 `custom_parameter` 或参数 LUT 传进 shader（你们本来就控制这 3 盏灯），在 shader 里复算同一个因子再除；或者
  2. 干脆不用方向光，转成纯 emissive（推荐）。
- 即使能算，除以一个接近 1.5 的因子会把噪声/量化放大，而且 lit 的响应并不是严格线性（2.3.3 的表），除回去也不会精确。

结论：正向补偿在理论上可做，但比"直接别让它乘"麻烦得多，没有理由选它。

### 2.5 问题 5：其它出口

#### 2.5.1 `geometryModifier` 不能改最终颜色

`CustomMaterial.GeometryModifier` 文档：geometry modifier 可以改顶点位置、顶点颜色、UV、法线等 per-vertex 数据，运行在 vertex stage；最终 surface 属性仍由 surface shader 决定。头文件 `RealityKitGeometryModifier.h:64-96` 的 `set_color` 是"current vertex's color"，不是输出颜色。**不能替代 surface shader。**

#### 2.5.2 `blending` / `readsDepth` / `writesDepth` 没有光照副作用

- `blending`：`.opaque` / `.transparent(opacity:)`，控制混合与排序。
- `readsDepth` / `writesDepth`（iOS 18+）：深度测试/写入开关。

它们都只影响光栅状态，不会改变 light 是否参与。没有可利用的副作用。

#### 2.5.3 `RealityRenderer` 离屏渲染（iOS 18+ / macOS 15+）

`RealityRenderer`（`RealityFoundation.swiftinterface:2021-2126`）可以把实体渲染到你自己的 `MTLTexture`：

```swift
let renderer = try RealityRenderer()
renderer.entities.append(entity)
renderer.activeCamera = camera
renderer.cameraSettings.isToneMappingEnabled = false
try renderer.updateAndRender(deltaTime: 0,
                             cameraOutput: try .init(.singleProjection(colorTexture: target)))
```

- 优点：`isToneMappingEnabled = false` 是实测有效的（K1/K6：0.5 → 0.502，1.0 → 1.0，八位量化内无损）。
- 代价：这条路是"自己渲染一张图再合成"，不在 `RealityView` 的场景图里；深度、遮挡、和别的 3D 内容的前后关系都要自己处理。适合"角色单独一层"的展示，不适合和场景混排。
- `CameraOutput` 只是它的输出描述（color textures + viewports），不是给 RealityView 挂自定义管线的接口。

#### 2.5.4 `LowLevelRenderContext`（iOS 27，`RealityCoreRenderer`）

iOS 27 新增了低层渲染 API（`RealityCoreRenderer.framework`，全部 `@available(iOS 27.0, macOS 27.0, ...)`）：

- `LowLevelRenderContext.makeSurfaceShader(descriptor:)`：从**用户自己写的 Metal 函数**编译 surface shader（`RealityCoreRenderer.swiftinterface:658-661, 766-769`）。
- `makeUnlitLightingFunction()`：文档原话 "Returns an unlit lighting function that emits the surface emissive color directly, without any lighting calculations."（`:684, 774`）。
- `makeImageBasedLightingFunction()`：IBL 版本。
- `LowLevelRenderer`（`:785`）把 mesh instance 的 draw call 编码进你自己的 `MTLCommandBuffer`。
- 还有 `LowLevelRenderContextShaderGraph`，可以把 ShaderGraph 编译成 Metal 函数。

这是"保留 Metal shader + 明确选 unlit lighting function"的最干净方案，但要求你把渲染循环、mesh instance、相机、深度、合成全部接管，且是 iOS 27+。是否暴露 tonemap 开关没有在公开接口里看到。本项目现在用的是 `RealityView` + `ModelComponent`，迁移成本很大；列在这里是作为 iOS 27 之后的长期出口。

#### 2.5.5 `ToneMappingComponent`（iOS 27）

`ToneMappingComponent`（`RealityFoundation.swiftinterface:1590-1597`）提供 per-entity / per-scene 的 tone curve 参数：`exposure`、`toeStrength`、`toeLength`、`shoulderStrength`、`shoulderLength`、`shoulderAngle`。

RealityKit 扩展文档说："Materials that manage their own color output can opt out of tone mapping. The `applyPostProcessToneMap` parameter on material initializers controls whether the tone mapping pass is applied to that material's output."

- `UnlitMaterial(applyPostProcessToneMap:)`（iOS 18+，`RealityFoundation.swiftinterface:17017-17035`）可以关。
- `ShaderGraphMaterial` + `LightingModel.unlit(isTonemappingEnabled: false)`（iOS 27）可以关。
- **`CustomMaterial` 没有这个开关**（检查过 iOS 27.1 interface 的全部 CustomMaterial 声明与 `Program.Descriptor`，只有 lightingModel 和 blendMode）。

`ToneMappingComponent` 只能改曲线形状，没有文档说可以设成恒等。理论上把 toeStrength 设 0、shoulderStrength 拉满可能接近线性，但这是猜的，列进 `UNVERIFIED`。

#### 2.5.6 完全自建渲染

`LowLevelMesh`（iOS 18+，`RealityFoundation.swiftinterface:10762-10894`）+ 自己的 `MTLRenderPipelineState` + `MTKView`/`CAMetalLayer`，可以完全绕开 RealityKit 的材质与 tonemap。代价是失去 RealityKit 的场景图、动画、碰撞、空间音效等，等于重写客户端渲染层。不建议为了这一个问题走这条路。

### 2.6 问题 6：兜底——在 `.lit`（或 unlit）下做经验校准

#### 2.6.1 先决条件

校准只在"传递函数与视角/法线无关"时成立。

- 如果保留 `.lit` + `base_color` 路径：因子随 `N·L`、灯的方向/强度变化（2.3.3），**不能**用一个全局曲线反解。除非 shader 自己按同样的灯参数复算因子——但那就等于正向补偿（2.4），不如直接走 emissive。
- 如果已经走 emissive（unlit 或 lit+zero-base）：剩下的只有 tonemap。tonemap 是相机后处理，**与视角/法线无关**，是 per-channel 的（P5 的 `(0.5,0.25,0.1)` 输出 `(0.3725,0.1843,0.0667)`，正好等于三个单通道结果），所以可以用一条一维曲线反解。

#### 2.6.2 实测的 tonemap 曲线

环境：macOS 27 `RealityRenderer`，默认相机 tonemap（`isToneMappingEnabled = true`），输出到 `.bgra8Unorm`，输入是 `set_emissive_color` 的常量（无贴图/颜色空间干扰）。输入 linear，输出 0–1：

| 输入 | 0.1 | 0.25 | 0.5 | 0.75 | 0.9 | 1.0 |
|---|---|---|---|---|---|---|
| 输出（tone ON） | 0.0667 | 0.1843 | 0.3725 | 0.5333 | 0.6157 | 0.6667 |
| 输出（tone OFF） | — | — | 0.502 | — | — | 1.0 |

- 曲线是单调的，且把 1.0 压到 0.667；0.5 压到 0.373。
- 逐通道独立（P5）。
- tone OFF 时 0.5 → 0.502、1.0 → 1.0，说明材质输出本身除了 8-bit 量化没有额外损失。

#### 2.6.3 怎么用

1. 在 shader 里对最终 linear 颜色做 `inverseToneMap()`（可以用 32 点 LUT + 线性插值，或者分段拟合）。
2. 校准数据要**在目标设备上**用同样的探针测（RealityView + 目标的 `RealityViewDynamicRange` / 显示 HDR 状态），不要直接抄上表。
3. 上限：
   - tonemap 把 1.0 压到 0.667，反解需要把 0.667 拉回 1.0，暗部/亮部的量化误差会被放大（8-bit 下 1/255 的误差在反解后可能变成 2–3/255）。
   - 超过 1.0 的 HDR 值已经被压掉，信息不可恢复；shader 里不要产生超过 1.0 的中间值再指望反解。
   - 曲线可能随设备、系统版本、EDR headroom 变化；换设备要重测。

#### 2.6.4 更彻底的替代

如果校准后仍不满意，再考虑 2.5.3（`RealityRenderer` 离屏 + 关 tonemap）或 2.5.4（iOS 27 低层渲染）。不要在 shader 里和 tonemap 硬碰硬。

---

## 3. 最小验证代码（已编译并实际运行）

### 3.1 编译/运行方式

```bash
# 1) Metal
xcrun -sdk macosx metal -std=metal3.0 -c probe.metal -o probe.air
xcrun -sdk macosx metallib probe.air -o probe.metallib

# 2) Swift（macOS 27）
xcrun swiftc -parse-as-library -sdk $(xcrun --show-sdk-path) \
  -target arm64-apple-macos27.0 -o probe main.swift \
  -framework RealityKit -framework Metal -framework AppKit -framework CoreGraphics

# 3) 运行
./probe
```

- 实际编译：通过（`metal` 与 `swiftc` 均无 error）。
- 实际运行：通过，下表就是它的输出。
- 注意两个坑（都踩过）：
  - 第一版用 `.rgba16Float` + 不等待，读回全 0；改成 `.bgra8Unorm` + `.shared`，并加 `MTLSharedEvent`（`actionsAfterRender: [.signal(event, value: 1)]` + `wait(untilSignaledValue:)`）同步后再 `getBytes`，正常。两者各自是不是必要条件没有单独隔离；写探针时建议两个都照做。
  - `updateAndRender` 的完成不是同步的，读回前一定要等完成信号。

### 3.2 关键 shader（节选，完整文件在 `/tmp/rkprobe/probe.metal`）

```metal
#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);

// unlit：采样 custom 贴图，只通过 emissive 输出
[[visible]]
void customOut(realitykit::surface_parameters params)
{
    float2 uv = params.geometry().uv0();
    params.surface().set_emissive_color(params.textures().custom().sample(s, uv).rgb);
}

// unlit 反例：只设置 base_color（应当黑）
[[visible]]
void unlitBaseOnly(realitykit::surface_parameters params)
{
    float2 uv = params.geometry().uv0();
    params.surface().set_base_color(params.textures().custom().sample(s, uv).rgb);
}

// lit 安全写法：base 置 0，最终颜色走 emissive
[[visible]]
void emissiveCustomZeroBase(realitykit::surface_parameters params)
{
    float2 uv = params.geometry().uv0();
    half3 c = params.textures().custom().sample(s, uv).rgb;
    params.surface().set_base_color(half3(0.0h));
    params.surface().set_emissive_color(c);
    params.surface().set_metallic(0.0h);
    params.surface().set_roughness(1.0h);
    params.surface().set_specular(0.0h);
}
```

### 3.3 Swift 探针（节选，完整文件在 `/tmp/rkprobe/main.swift`）

```swift
import Foundation
import Metal
import RealityKit
import AppKit

@main
struct Probe {
    static func main() async {
        do { try await MainActor.run { try run() } } catch { print("FAILED: \(error)") }
    }

    @MainActor
    static func makeTexture(_ c: (UInt8, UInt8, UInt8)) throws -> TextureResource {
        let w = 4, h = 4
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: CGFloat(c.0)/255, green: CGFloat(c.1)/255,
                                 blue: CGFloat(c.2)/255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try TextureResource.generate(from: ctx.makeImage()!, withName: nil,
                                            options: .init(semantic: .color))
    }

    @MainActor
    static func render(device: MTLDevice, lib: MTLLibrary, shader: String,
                       lighting: CustomMaterial.LightingModel,
                       customTex: TextureResource, baseTex: TextureResource,
                       emissiveTex: TextureResource,
                       lights: Bool, specTex: Bool, toneMap: Bool,
                       value: SIMD4<Float>) throws -> (Float, Float, Float, Float) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let target = device.makeTexture(descriptor: desc)!

        var m = try CustomMaterial(surfaceShader: .init(named: shader, in: lib),
                                   lightingModel: lighting)
        m.custom = .init(value: value, texture: CustomMaterial.Texture(customTex))
        m.baseColor = .init(tint: .white, texture: CustomMaterial.Texture(baseTex))
        m.emissiveColor = .init(color: .black, texture: CustomMaterial.Texture(emissiveTex))
        m.metallic = .init(scale: 0, texture: nil)
        m.roughness = .init(scale: 1, texture: nil)
        m.specular = specTex
            ? .init(scale: 1, texture: CustomMaterial.Texture(emissiveTex))
            : .init(scale: 0, texture: nil)

        let model = ModelEntity(mesh: .generateBox(size: 2), materials: [m])
        let camera = PerspectiveCamera()
        camera.position = [0, 0, 4]
        camera.camera.fieldOfViewInDegrees = 60
        camera.camera.near = 0.1
        camera.camera.far = 100

        let renderer = try RealityRenderer()
        renderer.entities.append(model)
        renderer.entities.append(camera)
        if lights {
            for (i, intensity) in [Float(2000), 1100, 700].enumerated() {
                let light = DirectionalLight()
                light.light.intensity = intensity
                light.position = [Float(i), 0, 3]
                renderer.entities.append(light)
            }
        }
        renderer.activeCamera = camera
        renderer.cameraSettings.isToneMappingEnabled = toneMap
        renderer.cameraSettings.colorBackground = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        let event = device.makeSharedEvent()!
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: target))
        try renderer.updateAndRender(deltaTime: 0, cameraOutput: output,
                                     actionsAfterRender: [.signal(event, value: 1)])
        _ = event.wait(untilSignaledValue: 1, timeoutMS: 5000)

        var px = [UInt8](repeating: 0, count: 4)
        target.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        return (Float(px[2])/255, Float(px[1])/255, Float(px[0])/255, Float(px[3])/255)
    }
}
```

### 3.4 运行结果（节选；完整输出在 `/tmp/rkprobe/result.txt`）

```
A  unlit custom->emissive              -> 0.824 0.051 0.020
B  unlit base->emissive                -> 0.169 0.914 0.067
C  unlit emissive->emissive            -> 0.008 0.031 0.914
H  unlit base-only (no emissive)       -> 0.000 0.000 0.000
N1 unlit specular texture->emissive    -> 0.008 0.031 0.914
D  lit const base .5, no light         -> 0.000 0.000 0.000
D2 lit const base .5, 3 lights         -> 0.776 0.776 0.776
E  lit emissive .5 only, no light      -> 0.502 0.502 0.502
E2 lit emissive .5 only, 3 lights      -> 0.502 0.502 0.502
J  lit emissive .5 + spec tex + lights -> 0.502 0.502 0.502
F2 lit custom->base, 3 lights          -> 1.000 0.067 0.024
G  lit env_radiance as base            -> 0.000 0.000 0.000
K1 unlit emissive .5, tone OFF         -> 0.502
K2 unlit emissive .5, tone ON          -> 0.373
K3 unlit emissive 1.0, tone ON         -> 0.667
K4 lit emissive .5, tone ON            -> 0.373
K6 lit emissive 1.0, tone OFF          -> 1.000
L3 unlit custom->emissive, 3 lights    -> 0.824 0.051 0.020
L4 unlit custom->emissive, tone ON     -> 0.573 0.027 0.008
M1 lit zero-base emissive, tone OFF    -> 0.824 0.051 0.020
M2 lit zero-base emissive, tone ON     -> 0.573 0.027 0.008
M3 unlit zero-base emissive, tone ON   -> 0.573 0.027 0.008
```

关键对比：

- **H vs A**：同一个 `.unlit`、同一张贴图，只差 `set_base_color` / `set_emissive_color`，前者黑、后者红 → 黑剪影的原因是输出函数，不是绑定。
- **M1 = L3、M2 = L4（逐位相同）**：`.lit` + zero base + emissive 与 `.unlit` 等价，即使 3 盏灯 + specular LUT 都在。
- **E2 = E = 0.502**：emissive 不经过光照。
- **D = 0、G = 0**：没有灯、没有 IBL 时 lit 没有环境兜底。

### 3.5 对真实 `ToonShading.metal` 的改动也编译过

把 `spikes/porting-3d/ios/ToonShading.metal` 复制到 `/tmp`，只改最终三行（改成 `set_base_color(0)` + `set_emissive_color(toLinear(...))` + `set_specular(0)`），用 iPhoneOS SDK 编译：

```bash
xcrun -sdk iphoneos metal -std=metal3.0 -c ToonShading.mod.metal -o ToonShading.mod.air
# exit=0，只有原本就存在的 unused constant 警告
```

注意：那三个 debug 分支（`:175`、`:184`、`:196`）也得一起改，否则 `.unlit` 下 debug 模式会黑。上面的 helper 就是为此准备的。

helper 本身也单独编译验证过（`/tmp/rkprobe/helper_test.metal`，iPhoneOS SDK，exit=0），按值传 `realitykit::surface_parameters` 没问题。

---

### 3.6 依据清单（SDK 路径与官方链接）

SDK 根目录（下文简写）：

- `IOS_SDK = /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk`
- `RK_HEADERS = $IOS_SDK/System/Library/Frameworks/RealityKit.framework/Headers`
- `RF_IFACE = $IOS_SDK/System/Library/Frameworks/RealityFoundation.framework/Modules/RealityFoundation.swiftmodule/arm64e-apple-ios.swiftinterface`
- `SG_IFACE = $IOS_SDK/System/Library/SubFrameworks/ShaderGraph.framework/Modules/ShaderGraph.swiftmodule/arm64e-apple-ios.swiftinterface`
- `RCR_IFACE = $IOS_SDK/System/Library/SubFrameworks/RealityCoreRenderer.framework/Modules/RealityCoreRenderer.swiftmodule/arm64e-apple-ios.swiftinterface`
- `SUI_IFACE = $IOS_SDK/System/Library/Frameworks/_RealityKit_SwiftUI.framework/Modules/_RealityKit_SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface`

头文件行号：

- `$RK_HEADERS/RealityKitSurfaceShader.h`
  - `:98-118` `textures()` 的说明（geometry modifier / surface shader 都可用）
  - `:116-124` `environment_radiance` 的 C API 签名
  - `:139-194` `uniforms`（只有 time/matrices/custom_parameter）
  - `:362-410` `lighting` 与 `environment_radiance` 的 C++/Metal 包装
  - `:484-494` base_color 的 unlit 提示
  - `:517` emissive 默认 `(0,0,0)`
  - `:523-529` `set_emissive_color`
  - `:709-712` `params.lighting()`
- `$RK_HEADERS/RealityKitTextures.h`
  - `:126-132` `base_color()`
  - `:151-157` `emissive_color()`
  - `:183-189` `specular()`
  - `:216-223` `custom()`（"It is not otherwise used within RealityKit"；未设置返回 `(0,0,0,1)`）
- `$RK_HEADERS/RealityKitMaterialParameters.h:46-112`（材质常量，无场景灯光）
- `$RK_HEADERS/RealityKitGeometryModifier.h:64-96`（`set_color` 是顶点色）

Swift 接口行号：

- `$RF_IFACE:12112-12215` `CustomMaterial`（`lightingModel` 只读；`custom` / `emissiveColor` / `specular`）
- `$RF_IFACE:1590-1597` `ToneMappingComponent`
- `$RF_IFACE:2021-2126` `RealityRenderer` / `CameraSettings` / `CameraOutput`
- `$RF_IFACE:13558-13606` `ShaderGraphMaterial.Program` / `Descriptor`
- `$RF_IFACE:13654-13671` `UnlitLightingModel` / `LightingModel`（iOS 27）
- `$RF_IFACE:16950-17040` `UnlitMaterial(applyPostProcessToneMap:)` 与 `Program.Descriptor`
- `$RF_IFACE:10762-10894` `LowLevelMesh`
- `$SG_IFACE:120-188` `NodeDefinition`（无公开 init，无 Metal 函数体）
- `$SG_IFACE:189-215` `ShaderGraph` 的 init / addNode / connect / encode
- `$SG_IFACE:536-570` `NodeLibrary(version:)`、`makeNode(from:)`
- `$RCR_IFACE:658-661, 766-769` `makeSurfaceShader(descriptor:)`
- `$RCR_IFACE:684, 774` `makeUnlitLightingFunction()`
- `$RCR_IFACE:785` `LowLevelRenderer`
- `$SUI_IFACE:637-670` `RealityViewEnvironment` / `RealityViewRenderingEffects` / `RealityViewPostProcessEffect`

Apple 官方文档（`DocumentationSearch` 拿到全文；网页为 JS 渲染，直接抓 HTML 只有标题）：

- CustomMaterial.LightingModel.unlit — <https://developer.apple.com/documentation/realitykit/custommaterial/lightingmodel-swift.enum/unlit>
- CustomMaterial.lightingModel — <https://developer.apple.com/documentation/realitykit/custommaterial/lightingmodel-swift.property>
- Modifying RealityKit rendering using custom materials — <https://developer.apple.com/documentation/realitykit/modifying-realitykit-rendering-using-custom-materials>
- CustomMaterial.emissiveColor — <https://developer.apple.com/documentation/realitykit/custommaterial/emissivecolor-swift.property>
- CustomMaterial.init(surfaceShader:geometryModifier:lightingModel:) — <https://developer.apple.com/documentation/realitykit/custommaterial/init(surfaceShader:geometrymodifier:lightingmodel:)>
- CustomMaterial.GeometryModifier — <https://developer.apple.com/documentation/realitykit/custommaterial/geometrymodifier>
- ShaderGraphMaterial — <https://developer.apple.com/documentation/realitykit/shadergraphmaterial>
- LightingModel（iOS 27） — <https://developer.apple.com/documentation/realitykit/lightingmodel>
- UnlitLightingModel — <https://developer.apple.com/documentation/realitykit/unlitlightingmodel>
- ShaderGraphMaterial.Program.Descriptor.lightingModel — <https://developer.apple.com/documentation/realitykit/shadergraphmaterial/program-swift.struct/descriptor-swift.struct/lightingmodel>
- ToneMappingComponent — <https://developer.apple.com/documentation/realitykit/tonemappingcomponent>
- RealityKit Extended API Documentation（Tone Mapping 一节） — <https://developer.apple.com/documentation/realitykit/realitykit_extended_api_documentation>
- RealityRenderer — <https://developer.apple.com/documentation/realitykit/realityrenderer>
- RealityRenderer.CameraSettings — <https://developer.apple.com/documentation/realitykit/realityrenderer/camerassettings-swift.struct>
- RealityViewEnvironment — <https://developer.apple.com/documentation/realitykit/realityviewenvironment>
- RealityViewRenderingEffects — <https://developer.apple.com/documentation/realitykit/realityviewrenderingeffects>
- DirectionalLightComponent.intensity — <https://developer.apple.com/documentation/realitykit/directionallightcomponent/intensity>
- EnvironmentLightingConfigurationComponent — <https://developer.apple.com/documentation/realitykit/environmentlightingconfigurationcomponent>
- LowLevelRenderContext — <https://developer.apple.com/documentation/realitykit/lowlevelrendercontext>
- LowLevelRenderContextLighting.makeUnlitLightingFunction() — <https://developer.apple.com/documentation/realitykit/lowlevelrendercontextlighting/makeunlitlightingfunction()>
- Construct an immersive environment for visionOS（`applyPostProcessToneMap` 的建议） — <https://developer.apple.com/documentation/realitykit/construct-an-immersive-environment-for-visionos>
- Metal RealityKit APIs PDF — <https://developer.apple.com/metal/Metal-RealityKit-APIs.pdf>

---

## 4. UNVERIFIED

以下内容没有在目标环境（iOS 26 真机 / 带窗口的 RealityView）里实测，使用前请单独验证：

- **iOS 26 的 RealityKit 是否与 macOS 27 的探针行为一致**。本机只有 iOS 27.0 / 27.1 模拟器 runtime，没有 iOS 26 runtime；项目目标 iOS 26。建议真机上跑 2.1.3 的两行验证。
- **RealityView 默认环境是否提供 IBL**。`RealityRenderer` + nil IBL 实测无环境光，`RealityViewEnvironment.default` 的文档只谈背景；但没有在真实 `RealityView` 窗口里用 `environment_radiance` 探针确认。
- **RealityView 的 tonemap 曲线是否等于上面那张表**。表来自 `RealityRenderer.cameraSettings.isToneMappingEnabled = true`；RealityView 的默认 HDR/EDR、`RealityViewDynamicRange` 可能改变曲线。校准必须在目标设备上重测。
- **`ToneMappingComponent` 能否配出恒等曲线**。公开字段只有 exposure/toe/shoulder；没有文档说可以完全关闭 tonemap。
- **`LowLevelRenderContext` / `LowLevelRenderer` 的运行时可行性**。接口（iOS 27）和 `makeUnlitLightingFunction()` 的文档都在，但没有跑过完整管线，也不知道它是否暴露 tonemap 开关。
- **`ShaderGraphMaterial.Program` 的程序化建图能否覆盖 MLTD 的全部逻辑**。接口存在（iOS 27），但节点集是内置 MaterialX；没有实测过复杂 toon 图。
- **贴图读回值为何不是纯主色**（0.824/0.051/0.020 而非 1/0/0）。可能是 CGImage → TextureResource 的色彩空间（P3/sRGB）与非 sRGB render target 的组合；不影响"绑没绑"的判断，但做精确颜色校准前需要先确认管线的色彩空间。
- **lit 的 base color 响应为何不是严格线性**（0.25→0.349、0.5→0.776）。没有去反推 RealityKit 的 BRDF/Fresnel/能量项，只把它当作"不要用 base color 路径"的证据。
- **`.unlit` 下阴影投射/接收的行为**。文档说 unlit 不做光照和阴影计算；如果角色需要投影，未测试。
