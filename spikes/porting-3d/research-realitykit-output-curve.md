# RealityKit 输出曲线：CustomMaterial 的 emissive 在出屏前被相机 tone mapping 压了一次

**测试环境**：macOS 27.2 / Xcode 27.1（Build 27A9275）/ iPhoneSimulator **27.1 SDK**（`iPhoneSimulator27.1.sdk`）/
模拟器 **iPhone 17 Pro Max, iOS 27.0 (24A434)**。截图链路 `xcrun simctl io screenshot` → `ffmpeg -pix_fmt rgb24` →
`/usr/bin/python3` 直接读字节。

> 本文件只做研究，**没有改动 `spikes/porting-3d/ios/` 下的任何实现代码**。所有实验都在两个仓库外的独立
> 工程里完成：`/tmp/rtkcurve/app`（最小实验室 App，运行时用同一份 `writeColour` 写法画 21 条灰度条），
> 以及把整个仓库复制到 `/tmp/rtkcurve/spike` 后做出的端到端验证（验证完已删除）。
> `git status` 在本仓库为空。

---

## 一、直接答案

**1. 那条曲线是 RealityKit 相机/场景级的 tone mapping（色调映射），不是 sRGB↔linear 换算，也不是曝光。**

- 位置：surface shader 输出之后。管线顺序是 `surface shader 写线性值 → 光照/合成 → tone map（线性光域）→ sRGB 编码 → 显示`。
  我们从两个方向同时验证了这个顺序：把 `emissive` 直接写成**线性值** L 时，屏幕读数是 `sRGB(f(L))`；
  而日历上独立测得的 `f`（见 §3）与之前用 `RealityRenderer` 离屏渲染（`research-realitykit-lighting-bypass.md`
  §2.6.2，`cameraSettings.isToneMappingEnabled = true`）得到的数值逐点吻合（0.5 → 0.3725 vs 0.3732，
  1.0 → 0.6667 vs 0.6654），所以这不是显示器的色彩管理，也不是截图链路。
- 命名：`ToneMappingComponent`（iOS 27）暴露了这条曲线的参数：`exposure / toeStrength / toeLength /
  shoulderStrength / shoulderLength / shoulderAngle`。**没有组件时**用的是某个内置默认曲线；
  **加了组件**就是这条可参数化曲线（两者形状不同，见 §4.3）。

**2. 能不能关掉？能，但只有一条路对 `CustomMaterial` 有效：**

```swift
// Model3DPreview.swift 里 RealityView 的 make 闭包里（任何场景根实体都行，不需要挂在相机上）
RealityView { content in
    content.add(container)
    if #available(iOS 27.0, *) {
        let tone = Entity()
        tone.components.set(ToneMappingComponent(toeStrength: 0, shoulderStrength: 0))
        content.add(tone)
    }
}
```

`toeStrength = 0` + `shoulderStrength = 0` 让整帧的 tone map 变成**恒等**（实测误差 ≤1.25/255），
之后 `set_emissive_color(toLinear(colour))` 才是真正的 sRGB 恒等，shader 一行都不用改。

这条路**不是文档承诺的行为**，是我们实测出来的（`ToneMappingComponent` 的文档只说了参数范围，没有任何
"identity / disable" 说明）。要在代码里留一个回归点（见 §7）。

**3. 端到端验证（真机未验，模拟器上整条链路走通）**

同一份模型、同一台模拟器，只加上面这 5 行：

| 部位（屏幕坐标） | 修复前 (RGB) | 修复后 (RGB) |
|---|---|---|
| 白衬衫 (660,1200) | 209, 187, 182 | **247, 217, 209** |
| 裙子 (660,1400) | 204, 149, 168 | **238, 170, 191** |
| 大腿皮肤 (600,1500) | 200, 141, 160 | **233, 160, 183** |
| 头发 (660,1000) | 120, 51, 25 | **138, 67, 43** |
| 鞋 (660,1650) | 83, 75, 177 | **99, 91, 202** |

角色区域内平均每个像素 +16.4 / +12.2 / +12.1（R/G/B）——暗部几乎不动，亮部抬得最多，正是"压高光"的反向。
白衬衫 247 与你记的游戏里的 246 差 1 码。修复后的画面：

- 修复前 `base_orig` 与修复后 `fixed` 的截图在 `/tmp/rtkcurve/`（`base_orig.png.png` / `fixed.png.png`）。

**4. 反函数补偿：可以做，但不推荐，而且有天花板**

- 曲线**不是**任何教科书函数：sRGB、Reinhard、ACES(Narkowicz/Hill)、Hable、Khronos Neutral、纯 gamma 都拟合不好
  （见 §5 表）。
- 最好的简单拟合是 `f(x) ≈ c·(1 - e^(-k·x))`，`k = 0.5050, c = 1.6932`，残差 **RMS 2.31 码 / 最大 5.22 码**（8 bit）。
- 但"拟合好"不等于"反解好"：用解析反函数补偿后，最终显示误差最大 **10–13 码**（因为 `f` 在高光段很平，
  反解会放大误差）。用 33 点查表反解可做到 **最大 2.7 码 / RMS 0.5 码**；65 点表 1.1 / 0.27。
- **天花板**：`f(1.0) = 0.6654`，也就是 emissive 写到 1.0 时屏幕最亮只能到 **213**。想输出 246 这种白，
  emissive 必须超过 1（实测 L=1.5 → 240，L=2.0 → 255），查表和 shader 都得按 [0, 2] 准备。
- **没有死黑截断**：`f(0.01) = 0.0034 → 11`，`f(0.005) ≈ 6`，一路平滑到 0。你记录的"≤0.2 → 0"我们复现不出来，
  见 §6.3。

---

## 二、这个"出来不是它自己"的算术

shader 的 `writeColour` 是 `set_emissive_color(toLinear(colour))`，所以送 `colour = 0.5` 时：

```
L = toLinear(0.5) = 0.2140          // shader 实际写进 emissive 的线性值
f(0.2140)         = 0.1576          // 相机 tone map（实测曲线，§3）
sRGB(0.1576)      = 0.431           // 显示编码
0.431 * 255       = 110             // 屏幕读数，和你的 110 完全一致
```

所以"送进去的是 0.5，出来是 110"整段（0.5 → 0.214 → 0.158 → 0.431）是两步：shader 自己做的 sRGB→linear，
加上相机 tone map。**恒等要求 f 是恒等**，而 `f` 在 0.214 处的增益只有 0.74。

---

## 三、实测曲线（默认 tone map，线性进 → 显示码值出）

方法：一个 `CustomMaterial`（`.unlit`，`base_color = 0`）在平面 UV 上画 21 条竖条，第 i 条把
`emissive = i/20`（线性值）直接写进去。一个平面同时画两种参数化（上行/下行），一次截图拿到 42 个样本；
再配合 `SHIFT/STEP` 扫 0.01 步长。

**输入 L 是线性值，输出是屏幕 sRGB 码值（0–255）**：

| L | 0.00 | 0.01 | 0.02 | 0.03 | 0.04 | 0.05 | 0.10 | 0.15 | 0.20 | 0.25 | 0.30 | 0.35 | 0.40 | 0.45 | 0.50 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 显示 | 0 | 11 | 22 | 32 | 40 | 47 | 74 | 92 | 107 | 119 | 130 | 140 | 150 | 157 | 164 |

| L | 0.55 | 0.60 | 0.65 | 0.70 | 0.75 | 0.80 | 0.85 | 0.90 | 0.95 | 1.00 | 1.50 | 2.00 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 显示 | 171 | 177 | 183 | 188 | 194 | 199 | 202 | 206 | 210 | **213** | 240 | 255 |

换成线性输出 `f(L) = toLinear(显示/255)`，并和恒等（`sRGB(L)`）对照：

| L | 0.05 | 0.10 | 0.20 | 0.30 | 0.40 | 0.50 | 0.60 | 0.70 | 0.80 | 0.90 | 1.00 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| f(L) | 0.0284 | 0.0685 | 0.1470 | 0.2232 | 0.3050 | 0.3712 | 0.4397 | 0.5029 | 0.5711 | 0.6172 | 0.6654 |
| f(L)/L | 0.569 | 0.685 | 0.735 | 0.744 | 0.762 | 0.742 | 0.733 | 0.718 | 0.714 | 0.686 | 0.665 |
| 若恒等，显示应为 | 63 | 89 | 124 | 149 | 170 | 188 | 203 | 218 | 231 | 243 | 255 |

特征：**全区间增益都 < 1**，中段最接近 1（0.40 处 0.762），两头各压一次——低端是 toe（0.05 处只剩 0.57），
高端是 shoulder（1.0 处 0.665）。这就是"压高光 + 暗部发闷"的观感来源。

复现性：同一条曲线在 `.unlit` / `.lit` / 开关 `dynamicRange = .standard` / 场景里加 20000 lux 平行光
四种情况下**逐码完全相同**——没有自动曝光，也不随场景亮度漂移。

---

## 四、逐条回答

### 4.1 在哪一步做 tone mapping，有没有开关

| 通道 | 能否关掉 tone map | 依据 |
|---|---|---|
| `CustomMaterial`（我们用的） | **不能**（没有属性/环境变量） | 见下 |
| `ToneMappingComponent(toeStrength: 0, shoulderStrength: 0)` | **能**（iOS 27+，场景级） | 实测 §4.3 |
| `UnlitMaterial(applyPostProcessToneMap: false)` | 能（只对 `UnlitMaterial`） | 实测：sRGB 0.5 → **128**（恒等） |
| `ShaderGraphMaterial` + `LightingModel.unlit(isTonemappingEnabled: false)` | 文档说能，**本次未实测**（要把 toon 模型重写成 MaterialX） | 头文件 |
| `RealityRenderer.cameraSettings.isToneMappingEnabled` | 能，但只对**离屏**渲染有效 | 头文件；上一轮研究实测过 |
| `RealityView` 的 `renderingEffects`（motionBlur/DOF/grain/antialiasing/dynamicRange/customPostProcessing） | **没有** tone mapping 项；`dynamicRange = .standard` 实测无变化 | 头文件 + 实测 |
| 环境变量 | 没找到 | 头文件里 `RealityKitConfig.h` 是空壳 |

头文件依据（`$(xcrun --sdk iphonesimulator --show-sdk-path)`，iPhoneSimulator27.1.sdk）：

- `RealityKit.framework/Headers/RealityKitSurfaceShader.h:484-486` — `base_color()` 注释：
  "For materials using the unlit lighting model, use set_emissive_color() instead."
- 同文件 `:492-494` — `set_base_color()` 同样的说明。
- 同文件 `:523-529` — `set_emissive_color()` 注释：
  "Use this to add light emitted for glowing materials, or as the output color when using the unlit lighting model."
  ——**没有任何一句提到色彩管理或 tone mapping**，头文件里搜不到 tone/gamma/sRGB/linear 相关表述。
- `RealityFoundation.framework/Modules/RealityFoundation.swiftmodule/arm64-apple-ios-simulator.swiftinterface`
  （下称 `.swiftinterface`）`1590-1597` — `ToneMappingComponent`，iOS 27 起，字段 `exposure`（F 档）、
  `toeStrength [0,1]`、`toeLength [0,1]`（1.0 = 白点的 50%）、`shoulderStrength [0,10]`、
  `shoulderLength [0,1]`、`shoulderAngle [0,1]`。
- `.swiftinterface:2054` — `RealityRenderer.CameraSettings.isToneMappingEnabled`（离屏渲染专用）。
- `.swiftinterface:12031-12036` — `CustomMaterial.LightingModel` 只有 `lit / unlit / clearcoat` 三个 case，
  **没有**任何 tonemapping 参数。
- `.swiftinterface:13554 / 13569` — `UnlitLightingModel.isTonemappingEnabled` 与
  `LightingModel.unlit(isTonemappingEnabled: Bool = true)`，只用于 `ShaderGraphMaterial`
  （`.swiftinterface:13489` 的 `init(shaderGraph:lightingModel:...)`）。
- `.swiftinterface:16900` — `UnlitMaterial.init(applyPostProcessToneMap:)`（iOS 18+）。

Apple 官方文档/论坛：

- [ToneMappingComponent](https://developer.apple.com/documentation/realitykit/tonemappingcomponent) —
  只写了参数含义和范围，没有 identity/关闭方法。
- [UnlitMaterial.init(applyPostProcessToneMap:)](https://developer.apple.com/documentation/realitykit/unlitmaterial/init(applypostprocesstonemap:)) —
  "Creates an UnlitMaterial with the given tone mapping setting"。
- Apple Developer Forums [thread 788076 "CustomMaterial disable unlit tone mapping"](https://developer.apple.com/forums/thread/788076) —
  有人试过 `CustomMaterial(from: UnlitMaterial(applyPostProcessToneMap: false), ...)`，**不生效**；
  Apple 工程师回复这条路 "will probably not work as you expect"，自定义材质要自己处理 tone mapping。
  我们实测复现了同一现象（`CustomMaterial` 无论如何都被映射）。

### 4.2 `.unlit` 和 `.lit` 两条曲线

**完全相同，逐码一致。** 同一份 shader、同一个值，只把 `lightingModel` 从 `.unlit` 换成 `.lit`：

| | 0.00 | 0.05 | 0.10 | … | 0.50 | … | 1.00 |
|---|---|---|---|---|---|---|---|
| `.unlit` 原始线性行 | 0 | 47 | 74 | … | 164 | … | 213 |
| `.lit` 原始线性行 | 0 | 47 | 74 | … | 164 | … | 213 |

这正是 `writeColour` 写 `base=0` + `emissive=结果` 的原因：**emissive 是唯一既不被光照污染、又两条路径都读的通道**，
所以 lighting model 成了一个纯粹的开关。

**`.lit` + `base_color` 就不同了**：它先走 PBR，再走同一条 tone map。实测（4 band 实验）：

- `base_color = s`、`emissive = 0`、场景没有方向光 —— **不是黑**，RealityView 默认环境给了 IBL，
  于是 base 被环境光照亮后再 tone map：显示值 `0, 42, 68, 87, 102, 115, 127, 138, 148, 159, 167,
  175, 183, 189, 197, 202, 208, 214, 218, 222, 227`（s = 0…1）。形状和 emissive 那条不一样，
  因为中间多乘了一个与 base 无关的辐照度；这条路径**不能**拿来当"可控输出通道"。
- 无光无 IBL 时 base 路径是黑（与上一轮结论一致）。

结论：**想让屏幕像素只由 shader 决定，只能用 emissive**；tone map 是它上面的最后一层。

### 4.3 有没有别的输出通道能绕开

都没有。tone map 是材质输出之后的阶段，任何 surface 参数（`base_color`、`opacity`、`custom`、`specular`…）
都逃不掉；`set_opacity` 也只会让结果和背景混合、再被映射。

唯一"官方"的旁路是按材质排除，但 `CustomMaterial` 拿不到这个开关。反过来这条旁路恰好**证明了曲线就是 tone map**：
同一个白色平面，`UnlitMaterial(applyPostProcessToneMap: true)` 显示 **110**，
`UnlitMaterial(applyPostProcessToneMap: false)` 显示 **128**（= sRGB 0.5，恒等）。
并且 `applyPostProcessToneMap: true` + 场景里加恒等 `ToneMappingComponent` 也是 **128** ——
两条路等价，说明曲线只有这一条，没有第二个隐藏变换。

### 4.4 用 ToneMappingComponent 把曲线调成恒等（推荐方案）

`ToneMappingComponent` 挂到场景里任何一个实体上即可（不必是相机；Apple 文档没规定挂载位置，
我们挂在场景根上一个空 `Entity` 上就生效），影响整个 RealityView 的合成。

实测参数扫描（`emissive = L` 原始线性行，显示码值）：

| 参数 `exposure,toeStrength,toeLength,shoulderStrength,shoulderLength,shoulderAngle` | L=0.05 | L=0.20 | L=0.50 | L=1.00 | 说明 |
|---|---|---|---|---|---|
| 不加组件（内置默认） | 47 | 107 | 164 | 213 | 现状 |
| `0, 0, 0, 0, 0, 0` | **64** | **124** | **189** | **255** | 恒等（sRGB(L) 应为 63.2/123.6/187.5/255） |
| `0, 0, 0, 1, 0.7, 1`（只保留 shoulder） | 56 | 111 | 167 | 214 | 去掉 toe |
| `0, 0.25, 0.37, 0, 0.7, 1`（只保留 toe） | 56 | 122 | 187 | 254 | 去掉 shoulder |
| `0, 0.25, 0.37, 1, 0.7, 1`（= Swift 默认参数） | 70 | 123 | 174 | 218 | **不等于内置默认**，黑被抬到 28 |
| `0, 0, 0, 10, 1, 1` | 23 | 51 | 80 | 109 | shoulder 拉满，整体压暗 |
| `0.5, 0, 0, 0, 0, 0` | 76 | 145 | 219 | 255(截断) | exposure +0.5 F 档 |

要点：

1. **`toeStrength = 0` + `shoulderStrength = 0` 就是恒等**，`toeLength / shoulderLength / shoulderAngle`
   这时取什么都无所谓。密集实测（0.01 步长）恒等误差 **≤1.25 码**，线性原始行 **≤1.12 码**。
2. `ToneMappingComponent()` 的 Swift 默认值（0, 0.25, 0.37, 1, 0.7, 1）**不是**"不加组件"时的内置默认曲线
   （加默认组件后黑会变成 28），两者是不同的映射。所以别用 `ToneMappingComponent()` 当"照旧"。
3. 恒等之后 HDR（>1.0 线性）会**硬裁到 255**（默认曲线是滚降）。我们的内容是 SDR，没有影响。
4. 需要 iOS 27（`@available(iOS 27.0, ...)`）。本项目 deployment target 是 26.0，必须加 `#available` 分支；
   iOS 26 上这条曲线是否存在、是否同形，**未验证**（本机没有 iOS 26 运行时）。

### 4.5 模拟器 vs 真机

**真机：未验证。** 环境里确实连着 iPhone Air（iOS 27.0.1），但这台 Mac 上没有可用的真机截屏路径
（`devicectl` 没有截图子命令，Xcode MCP 的设备会话只列出模拟器，`idevicescreenshot` 未安装），
所以没法读出真机像素。间接证据：同一条曲线在模拟器（RealityView + 屏幕合成）和上一轮 **macOS 27 的
RealityRenderer 离屏渲染**（完全不同的环境与输出格式）数值一致（0.5 → 0.3725 / 0.3732，1.0 → 0.6667 / 0.6654），
说明它来自渲染器实现而不是某块屏幕；但显示器的 EDR headroom 是否会让曲线变形，**没有证据，不要当成结论**。

---

## 五、这条曲线是什么函数？

对 101 个实测点（线性 L → 线性 f(L)）做拟合，误差以 8 bit 码值计：

| 候选 | 参数 | RMS (码) | 最大 (码) |
|---|---|---|---|
| gamma `c·x^g` | c=0.7704, g=1.0740 | 9.87 | 26.78 |
| Reinhard `x/(1+x)` | — | 23.6 | 39.2 |
| Reinhard extended `x(1+x/W²)/(1+x)` | W=1.756 | 3.51 | 7.98 |
| ACES (Narkowicz) | — | 46.87 | 62.85 |
| ACES (Hill 1D fit) | — | 6.46 | 12.64 |
| Hable / Uncharted2 | — | 57.49 | 92.67 |
| Khronos PBR Neutral | — | 45.14 | 81.68 |
| **`c·(1 - e^(-k·x))`** | **k=0.5050, c=1.6932** | **2.31** | **5.22** |
| 有理式 `(a x + b x²)/(1 + c x + d x²)` | a=0.753, b=1.903, c=2.0, d=0.98 | 2.17 | 5.34 |
| 无常数项五次多项式 | c1..c5 = 0.47676, 2.91076, -8.42792, 9.34241, -3.63959 | 1.60 | 4.05 |

**结论：不是 sRGB↔linear（那一步管线自己做完了），不是 Reinhard / ACES / Hable / Khronos / 纯 gamma 中任何一个。**
它是一条 toe + shoulder 的 filmic 曲线，最接近饱和指数 `c(1-e^(-kx))`，但要拿去反解还不够准。

### 5.1 反解补偿的实测误差

以实测曲线为准，把目标显示值反解成 emissive 再正向跑一遍：

| 反解方式 | 最大误差 (码) | RMS (码) |
|---|---|---|
| 解析反函数（指数模型） | 13.2 | 6.99 |
| 解析反函数（Reinhard-ext W=1.76） | 16.3 | 9.75 |
| 五次多项式数值反解 | 9.9 | 5.14 |
| 17 点查表 + 线性插值 | 3.1 | 0.71 |
| 33 点查表 + 线性插值 | 2.7 | 0.50 |
| 65 点查表 + 线性插值 | 1.13 | 0.27 |

（表按"目标显示码值"索引，索引范围 0–212 即可达到的上界；>213 的目标需要 emissive > 1。）
若一定要在没有 iOS 27 的机器上补偿，**用 33 点以上的查表**，别用解析式。
而且这张表是**用 iPhoneSimulator 27.1 SDK + iOS 27.0 运行时量出来的**，换 OS 版本要重测。

---

## 六、其它实测细节

### 6.1 `.lit` / `.unlit` 全等（原始记录）

```
== base (unlit)   A 0 3 11 23 36 49 61 74 86 98 110 122 134 146 157 168 178 188 197 205 213
                  B 0 47 74 92 107 119 130 140 150 157 164 171 177 183 188 194 199 202 206 210 213
== lit           A 0 3 11 23 36 49 61 74 86 98 110 122 134 146 157 168 178 188 197 205 213
                  B 0 47 74 92 107 119 130 140 150 157 164 171 177 183 188 194 199 202 206 210 213
```
（A 行 = 生产路径 `emissive = toLinear(s)`，B 行 = 原始线性 `emissive = s`；`s = 0, 0.05, …, 1`。
注意平面 UV 原点在下方，B 行在屏幕下半部分。）

### 6.2 截图链路本身是恒等的（对照组）

App 底部放了一排 `Color(white: i/20)` 的 SwiftUI 色块。截图读回：

```
期望 0,13,26,38,51,64,77,89,102,115,128,140,153,166,179,191,204,217,229,242,255（舍入前）
实测 25,25,38,51,64,77,89,89,102,115,128,140,153,166,166,179,191,204,217,229,229   （取样点偏移两格）
```
逐项都对得上**同一个 sRGB 码值**。所以显示器/截图不引入曲线，110 是 RealityKit 侧造成的。

### 6.3 关于你表里的 "0.2 → 0"

在受控实验里，生产路径（`emissive = toLinear(s)`）是：

| s | 0.2 | 0.3 | 0.4 | 0.5 |
|---|---|---|---|---|
| 本次实测 | **36** | **61** | **86** | **110** |
| 你上轮记录 | 0 | 56 | 79 | 110 |

0.5 完全一致；0.3/0.4 差 5–7 码；0.2 我们得 36，不是 0。**这条管线没有死黑截断**（0.01 → 11，0.005 ≈ 6）。
最可能的解释是那一行的取样点不在材质表面：描边外壳（`faceCulling = .front` 的黑色凸包）、
`_IsCutOff` 材质的 `discard_fragment()`、或者模型边缘和背景渐变混色。**建议当作测量误差处理，不要写进结论。**

---

## 七、给实现的建议（本次未改动仓库代码）

1. **主方案**：在 `Model3DPreview.swift` 的 `RealityView` make 闭包里加一个带
   `ToneMappingComponent(toeStrength: 0, shoulderStrength: 0)` 的空实体（`if #available(iOS 27.0, *)`）。
   实测颜色回到游戏值（白衬衫 209 → 247），shader 不动。
2. **回归点**：这是未文档化行为，换 OS 后可能失效。建议加一个 DEBUG 开关（比如
   `EIDOLON_3D_DEBUG_CONST` 那条路径）实测 `emissive = toLinear(0.5)` 是否读回 128；
   读回 110 就说明 Apple 改了曲线，需要重新确认。
3. **iOS 26 兜底**（如果还要支持）：只能在 shader 里做反解，用 33 点以上的查表（≤3 码），
   并且 emissive 要允许 > 1（到 2.0 才能到 255）。解析式不可用（10–13 码误差）。
4. **不要**走"`.lit` + base_color"来偷输出：base 会先乘 IBL/灯光，曲线不可控。
5. 若哪天改用 `ShaderGraphMaterial`，`LightingModel.unlit(isTonemappingEnabled: false)` 是官方旁路，
   但要把整个 toon 模型重写成 MaterialX，代价远大于第 1 条。

---

## 八、实验产物与可复现性

| 路径 | 内容 |
|---|---|
| `/tmp/rtkcurve/app/` | 最小实验室 App（`main.swift` + `curve.metal`），4 个 band × 21 条灰度条，`MODE/SHIFT/STEP/LIT/TONECOMP/TONECOMP_SPEC/LIGHT/DYNRANGE_STANDARD` 环境变量切换探针 |
| `/tmp/rtkcurve/{probe,shot,extract}.py|sh` | 启动、等画面就绪、读像素的工具 |
| `/tmp/rtkcurve/*.png` | 各探针截图（`base`/`dense_low`/`ident_base`/`tc_*`/`bands_*`/`hdr_*`/`unlit_*`） |
| `/tmp/rtkcurve/base_orig.png.png`, `fixed.png.png` | 真实 App 修复前 / 修复后的整机截图 |

端到端验证用的仓库副本在 `/tmp/rtkcurve/spike`（改的是副本里的 `Model3DPreview.swift`，
只加了那 5 行；验证完已删除）。**本仓库 `git status` 干净，没有任何实现改动。**
