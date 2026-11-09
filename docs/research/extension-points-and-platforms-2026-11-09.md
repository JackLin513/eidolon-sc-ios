# 组件化扩展点与 iPad/macOS 适配调研（2026-11-09）

调查日期 2026-11-09。**只读调查**：没有改代码、没有提交、没有读 `.env`；没有运行 Xcode / 模拟器 / Unity / UE，也没有下载任何 SDK 或游戏资源。三份后台调研（扩展点设计、运行时官方边界、平台适配）加本机代码核对汇总；官方/社区/未知分开标注，推断处写「推断」。

| 来源 | 版本 / 范围 | 用途 |
|---|---|---|
| 本仓库 main | worktree HEAD `8c05c7de` | 现状与接口落点；承接 [组件化调研](componentization-2026-11-09.md)、[迁移模板调研](migration-template-2026-11-09.md) |
| 3D 支线 | `feat/mltd-3d-stand` `f9b09b8a` | 第一个真实运行时适配器 |
| 官方文档 | Unity Manual、Epic Developer Community、Apple Developer / HIG / TN3192、Live2D、Esoteric Software、Ren'Py | 「能不能嵌、能嵌到哪」的事实 |

## 0 结论摘要

1. **要预留的不是「每种引擎一个协议」，而是四条稳定边界**：① 内容包 kind / manifest（`runtime` + `capabilities` + `engine_version` + `legal`）；② 运行时适配器（`PresentationRuntime` 每引擎一个 + `CharacterRenderer` 每表面一个 + 编译期 `RuntimeRegistry`）；③ 能力协商与回退链（runtime → spine → avatar，数据驱动，不用布尔）；④ 构建变体与平台能力（**引擎进 App 构建变体，素材进内容包**；`project-3d.yml` / `#if canImport` / `PlatformCapabilities`）。
2. **CGSS / 学マス 与 MLTD 共用的是「Unity 宿主外壳」，不是整个 Unity 工程。** Unity 官方 UaaL 只支持 iOS / Android / Windows / UWP，iOS 上只能全屏、单实例、退出后本次会话不可重载、unload 仍残留 80–180 MB；每个作品仍需要自己的 Unity 工程、C# 加载器与内容适配器。共享的是 Swift 侧 host、消息协议、包 manifest 与回退逻辑。
3. **星耀季节不能按「UE 库」预留。** UE 官方没有「嵌入现有 iOS/macOS App」的路径：`UELibrary` 的 API 是 Win32 形态（`HINSTANCE` / `HWND` / `LRESULT`），文档明确其产物含受 EULA 限制的 "Engine Tools"；iOS 只有一个 DisplayName 标着 *(Experimental)* 的 `bBuildAsFramework`，没有官方集成指南。正确做法是留一个 `RuntimeID.unreal` 的「明确不支持 / 离线转换 / 独立进程」入口，而不是假实现。
4. **galgame 走「中性 VN IR + 2D 运行时」，不走引擎嵌入。** Ren'Py 官方只有整包 iOS 构建，没有库化嵌入；Live2D 官方支持 iOS/macOS（发布需 license）；Spine 官方 `spine-ios` 覆盖 iOS / macOS / Mac Catalyst，但项目现用 3.6、官方 Swift 封装是 4.x，**版本断层需要拍板**；PNG 差分立绘是零依赖的最终回退。
5. **MLTD 支线作为第一适配器，顺序必须是「先 main 契约，再 rebase 分支」。** 先落 Core 五个值类型 + App 两个协议 + registry + `project-3d.yml` 可选，再把 3D 支线的 16 个文件迁到协议上；反过来会让约 1/3 的适配代码返工（伪造 Spine 表、`standIs3D`、环境变量、Bundle 内内容）。
6. **iPad 先做，Mac 用最小路径先跑起来。** iPad 是同一 iOS 二进制，改 device family / 方向 / sidebar / 容器尺寸即可；Mac 上 Unity UaaL 无官方路径，所以「Mac 测试」主要是 Core 单测、oracle、内容导入、2D/WebView/TTS，以及 Xcode 的 My Mac (Designed for iPhone/iPad) 冒烟；Catalyst 次之，原生 macOS 最后。

## 1 把需求翻译成边界

| 目标 | 需要的入口 | 现在做到哪一步 |
|---|---|---|
| **CGSS / 学マス（Unity 3D）** | Unity 运行时 host + `model3d` 内容包 + 角色↔模型映射 + 表情/口型/动作能力声明 | MLTD 支线已证明 host 与 `StandRenderer` 接缝；缺内容包、能力声明、角色映射 |
| **星耀季节（UE）** | 只留 `RuntimeID.unreal`（负向用例）；资产离线转中性格式；或独立进程/独立 App | 不实现；文档明确不支持 |
| **galgame（2D 立绘/VN）** | `vn_scene`（IR）/ `card_art` / `voice_set` 内容包 + 2D 精灵/立绘运行时（PNG 差分、可选 Spine/Live2D） | 无；现有 `StandRenderer` 的相机只吃 aspect，可复用其取景数学 |
| **iPad** | `PlatformCapabilities` + 自适应布局 + 容器尺寸（不是屏幕尺寸） | `Tab` API 已就绪（ADR-0027）；device family 仍是 `"1"` |
| **macOS（测试）** | Core 已可在 mac 跑；App 用 My Mac / Catalyst 冒烟；Unity/UE 降级 | Core `Package.swift` 已声明 macOS 14；App 无 mac target |

**不预留的入口**：不做动态插件加载（iOS 无合法动态代码；编译期注册更简单）；不为每个引擎造一套协议；不把「未来可能用」的字段做成空实现——只留字符串 ID 与 manifest 字段，等第二个真实适配器落地再验证。

## 2 现状：需要插拔的位置

| 位置 | 现在怎么被写死 / 注入 | 证据 |
|---|---|---|
| 2D 渲染器 | `StandRenderer` 协议 + 唯一实现；`load/direct/pause/viewport` 四个动作 | `EidolonIOS/Features/Stand/StandRenderer.swift:10-27`；`StandWebRenderer.swift:85-107` |
| 渲染器构造 | **5 处直接 new `StandWebRenderer`**（通话、预览、换装、缩略图、酒吧） | `CallView.swift:202`、`StandPreviewView.swift:372`、`OutfitPickerView.swift:306`、`StandThumbnails.swift:124`、`BarGuest.swift:66` |
| 缩略图 | `snapshot()` 不在协议里，只有 Web 实现有 | `StandWebRenderer.swift:111` vs `StandThumbnails.swift:26,103` |
| 姿势语义 | `StandPose` 是 Spine 五轨形状；回报是「动画名→时长」 | `EidolonCore/Sources/EidolonCore/StandRender.swift:147-216`、`StandAnimator.swift:8-45` |
| 音频 | 4 个 `public protocol` 注入（采集/播放/识别/合成），状态机在 Core | `CallSession.swift`；ADR-0015 |
| 内容包 | 三个安装器、三个固定目录、三套 manifest，各自 `kind`/`formatVersion`，没有 `runtime` | `Eidolon.swift:92,122,213`、`ContentManifest.swift:28`、`StandManifest.swift:8-12` |
| 设置 | `ChatSettings.load()` 静态读；3D 支线引入首批 `@AppStorage` | `AppModel.swift:30`；分支 `SettingsView.swift:35-36` |
| 布局 | `horizontalSizeClass` → `StandFraming(compactWidth:)`；3D 用 `standIs3D` 布尔 + 46pt 下移 | `CallView.swift:14,171`；分支 `CallView.swift:57,70-105,195` |
| 后台任务 | `BGTaskScheduler` 自建第二个 `Eidolon` 与 provider | `MomentsBackground.swift:13,33,39` |
| 构建产物 | Spine runtime 构建期从上游拷（软失败）；Unity framework/Data/内容被当必需源目录 | `project.yml:54-60`、`tools/sync_stand_runtime.sh:13-23`；分支 `project.yml:30-33,49-54` |

Core 仍然干净：只 import `Foundation/GRDB/ZIPFoundation/CryptoKit/CoreGraphics/UniformTypeIdentifiers/ImageIO`，没有 SwiftUI/UIKit/AVFoundation/WebKit；`EidolonCore/Package.swift:6-8` 已声明 `.iOS(.v26)` + `.macOS(.v14)`。**这条边界不能为了平台适配而破坏。**

## 3 建议的扩展点（四层，8 个类型）

原则：**协议少、类型稳、实现藏在构建变体里**。以下命名是建议，评审后再定。

### 3.1 语义与内容契约（Core）

```swift
// EidolonCore/Sources/EidolonCore/Presentation.swift（新增，单文件）
public struct RuntimeID: RawRepresentable, Codable, Sendable, Hashable {
    public static let spineWebGL = RuntimeID("spine-webgl")
    public static let unityUaaL  = RuntimeID("unity-uaal")
    public static let realityKit = RuntimeID("realitykit")
    public static let vnLayered  = RuntimeID("vn-layered")
    public static let unreal     = RuntimeID("unreal")      // 只做负向用例
    public static let avatar     = RuntimeID("avatar")      // 恒可用，最终回退
}
public struct PresentationFrame: Codable, Sendable, Hashable {
    public var expression: Expression   // 沿用 StandEmotion 七档
    public var speaking: Bool
    public var gaze: Bool
    public var gesture: Gesture?        // .nod / .shake
    public var framing: Framing         // full / knees / waist
}
public struct RuntimeCapabilities: Codable, Sendable, Hashable {
    public var expressions: Set<Expression>
    public var framings: Set<Framing>
    public var lipSync, gaze, gesture, snapshot: Bool
    public var fullBleed: Bool          // 3D 整屏 vs 2D 下半屏；取代 standIs3D
    public var engine: String?          // "unity/6000.3" 等；nil = 内置/原生
}
public struct RuntimeRequirement: Codable, Sendable, Hashable {
    public var preferred: RuntimeID
    public var engineVersion: String?
    public var fallbacks: [RuntimeID]   // 建议 ["spine-webgl", "avatar"]
}
public struct PackageHeader: Decodable, Sendable {
    public var formatVersion: Int
    public var kind: ContentKind        // content / stand / bar / model3d / vn_scene
    public var runtime: RuntimeRequirement?
    public var capabilities: RuntimeCapabilities?
    public var legal: LegalNotice?      // 来源 / EULA / 生成时间
}
```

要点：

- `StandPose.Report` 从「Spine 名字→时长」升级为 `RuntimeReport`（`resolved: RuntimeCapabilities` + `bounds` + `extent`）。**Spine 动画名表降级为 Spine 适配器内部实现**，3D/UE/VN 不再伪造。
- 三个旧 manifest（content/stand/bar）**只加字段**，`decodeIfPresent` 默认 nil，旧包照常读；安装入口收敛成 `Eidolon.installPackage(at:progress:)`：先读 `PackageHeader`，校验 kind / engine_version，再分派给现有安装器。
- `model3d` 包示例：`runtime.preferred = unity-uaal`、`engine_version = unity/6000.3`、`characters[].model3d = {idol, outfits}`、`emotion_map`、`files` + CRC、`legal`。**227 MB 内容不再进 App 二进制**，也不再有 `haruka3d` 补丁角色。

### 3.2 运行时适配器（App）

```swift
@MainActor public protocol CharacterRenderer: AnyObject {   // 现 StandRenderer 的泛化
    static var runtimeID: RuntimeID { get }
    var view: UIView { get }
    var onReady: ((RuntimeReport) -> Void)? { get set }
    var onFailure: ((RuntimeFailure) -> Void)? { get set }
    func prepare(_ assets: RuntimeAssets)       // 取代 load(StandOutfit)
    func present(_ frame: PresentationFrame)    // 取代 direct(StandPose)
    func setPaused(_ paused: Bool)
    func setViewport(_ size: CGSize)
    func snapshot() async -> UIImage?           // 默认 nil；缩略图/验收
}
@MainActor public protocol PresentationRuntime: AnyObject { // 每引擎一个、进程单例
    static var runtimeID: RuntimeID { get }
    var capabilities: RuntimeCapabilities { get }
    var isAvailable: Bool { get }               // 编译期 + bundle 产物检查
    func makeRenderer(_ assets: RuntimeAssets) throws -> any CharacterRenderer
    func setPausedAll(_ paused: Bool)           // Unity 是全进程 pause
}
```

为什么分两层：表面有 5 处（通话、酒吧、预览、换装、缩略图），引擎只有一种且是全进程单例（3D 支线的 `UnityStandRuntime.shared` 已经证明）。让每个引擎直接实现 5 个表面 = 5 倍适配代码。`RuntimeAssets`（内容目录 + 模型/衣装清单）、`RuntimeReport`（resolved capabilities + bounds）、`RuntimeFailure` 是配套值类型，与 `Presentation.swift` 同文件。

`RuntimeRegistry` 用**编译期穷举**，不做反射/动态加载：

```swift
@MainActor struct RuntimeRegistry {
    init(platform: PlatformCapabilities) {
        var hosts: [RuntimeID: any PresentationRuntime] = [
            .spineWebGL: SpineRuntime(...), .avatar: AvatarRuntime(),
        ]
        #if canImport(UnityFramework)
        if UnityRuntime.bundled { hosts[.unityUaaL] = UnityRuntime(...) }
        #endif
        self.hosts = hosts
    }
    func resolve(_ need: RuntimeRequirement) -> (any PresentationRuntime)?
}
```

**Unity 的四条硬限制必须进协议语义**：全屏（`fullBleed`）、单实例、`Application.Quit` 后本次会话不可重载、unload 残留 80–180 MB。因此协议要允许「只隐藏、不卸载」，并把「终止」当作 App 级不可逆状态；不能靠视图生命周期去析构/重建 Unity。

### 3.3 能力协商与回退

固定链：**包声明 runtime → 平台可用引擎 → `spine-webgl` → `avatar`**。`avatar` 永不失败，所以「丢立绘不丢通话」。

页面只读 `report.resolved`：`fullBleed` 决定整屏/下半屏，`framings` 决定取景选项，`snapshot` 决定缩略图走真图还是卡片。禁止再从「声明」升级能力——**能力只能从实测 report 降级**。

### 3.4 构建变体与平台能力

| 东西 | 归属 | 规则 |
|---|---|---|
| Unity `UnityFramework.framework` + `Data` | **App 构建变体** | 只 embed 不 link；与 Data 同次导出；`project-3d.yml` include；默认构建不含 |
| UE 库 | 不实现 | 只留 `RuntimeID.unreal`；不建 target |
| Live2D / Spine runtime | **App 构建变体**（SPM/Carthage/SDK） | 默认不含；`#if canImport` + 独立 target |
| 3D 模型/动作/表情映射 | **内容包 `model3d`** | 带 CRC/版本/legal；可整包不装 |
| 2D 立绘/VN 资产 | **内容包** | `stand` / `vn_scene` / `card_art` |
| Spine 3.6 `spine-webgl.js` | App 构建变体（不进仓库） | 现状不变 |

`PlatformCapabilities`（Core 值类型，App 探测后注入）：

```swift
public struct PlatformCapabilities: Sendable, Hashable {
    public enum Family: String { case iPhone, iPad, mac, vision }
    public enum Availability: Sendable { case available, unavailable(String) }
    public var family: Family
    public var microphone: Availability
    public var resizableWindows: Bool
    public var engines: Set<RuntimeID>      // 本构建真能加载哪些
    public var memoryClass: Int?
}
```

规则：`#if os` / `#if targetEnvironment(macCatalyst)` 只允许出现在 App 的 `Platform/` 与 `Runtime/` 目录；Core 只读值类型，不加平台条件编译。

## 4 运行时官方边界（能不能嵌、嵌到哪）

### 4.1 Unity as a Library（UaaL）

- **官方平台只有 iOS / Android / Windows / UWP**（Unity 2019.3 起），**没有 macOS，也没有 Mac Catalyst**（<https://docs.unity3d.com/2022.3/Documentation/Manual/UnityasaLibrary.html>）。
- iOS 形态：`UnityFramework.framework`（embed）+ `Data`；`runEmbeddedWithArgc:argv:appLaunchOpts:`；`setDataBundleId:` 要在启动前调用；官方示例 <https://github.com/Unity-Technologies/uaal-example>。
- iOS 硬限制（官方）：只支持全屏；同进程只能一个 Unity runtime；`Application.Quit` 后本次会话无法再加载；unload 后仍占 80–180 MB；状态栏设置失效。
- 对本项目：MLTD、CGSS、学マス 都可以走同一 **Swift host**；但每个作品要自己的 Unity 工程/C# 加载器 + 内容适配器，**不是「装一个 Unity 就通吃」**。Mac 上没有官方 UaaL 路径。

### 4.2 Unreal Engine

- 官方有「Building Unreal Engine as a Library」（UELibrary），但 API 是 Win32：`UELibrary_Init(HINSTANCE, HWND, const char*)`、`UELibrary_WndProc(HWND, …)`；构建流程是 VS 解决方案；只能 Init 一次、不能多实例/多窗口、Shutdown 后不能重启；产物含 EULA 定义的 "Engine Tools"（分发有限制）（<https://dev.epicgames.com/documentation/en-us/unreal-engine/building-unreal-engine-as-a-library?application_version=4.27>）。
- iOS 侧只有引擎内 `bBuildAsFramework`（DisplayName 标 *(Experimental)*），没有官方集成指南；官方论坛多年无 Epic 答复。**结论：无官方「UE 嵌进现有 iOS/macOS App」路径。**
- 对本项目：星耀季节只能按「独立 UE App / 进程级 / 离线转中性格式」规划；`RuntimeID.unreal` 只作负向用例，**不要**为它预留会让人误以为可实现的空协议。

### 4.3 2D 立绘 / VN 运行时

| 方案 | 官方平台 | 结论 |
|---|---|---|
| **PNG 差分 / 图层**（SwiftUI/UIKit + CALayer/图片） | 全部 Apple 平台 | 零 SDK、零许可；只能表情差分/位移/淡入淡出，是最终回退 |
| **Spine `spine-ios`**（官方 Swift 包，Metal，SwiftUI/UIKit/AppKit） | iOS 13 / macOS 10.15 / **Mac Catalyst 13** / visionOS | 唯一「Apple 全家桶官方支持」的 2D 运行时；但 runtime 的 major.minor 必须与编辑器一致——项目现用 **3.6**，官方 Swift 封装是 **4.x**，需决策（升级导出 vs spine-c 3.6 自绘） |
| **Live2D Cubism SDK for Native** | iOS（仅 64 位）/ macOS（Metal 一格脚注为 Mac Catalyst） | 官方支持；发布前需签 Publication License；要判断是否属 Expandable Application |
| **E-mote** | iOS / Android / Unity / WebGL 等；macOS 未列 | 闭源商业 SDK，按平台付费；iOS 可用，macOS/Catalyst 未知 |
| **Ren'Py** | iOS 整包构建（launcher 生成 Xcode 工程），与 Ren'Py 版本绑定 | **无库化嵌入入口**；含 LGPL 组件；不在设备上跑 Ren'Py，走 IR |

### 4.4 中性 3D（偏 Mac / 跨平台路线）

- Apple 官方支持表：USD 的 **Skeletons / Skeleton animation / Blend Shapes 在 RealityKit 均支持**；RealityKit 覆盖 iOS 13+ / iPadOS / Mac Catalyst 13.1+ / macOS 10.15+。
- 限制（官方）：RealityKit 不使用 USD 灯光；材质只支持每材质一张打包贴图、最多两个 UV set；不支持 Draco。
- glTF 不是 Apple 官方运行时格式，只做离线中间格式，落地前转 USDZ。
- 对本项目：如果未来要「Mac 上也有 3D」，最现实是离线转 USDZ + RealityKit 自绘材质；但 MLTD 这种「原生一致」要求在 iOS 上仍应走 UaaL，Mac 上降级 2D/头像。

### 4.5 运行时矩阵（官方口径）

| 运行时 | iPhone / iPad | Mac Catalyst | 原生 macOS | 结论 |
|---|---|---|---|---|
| Unity UaaL | ✔（2019.3+） | ✘ | ✘ | 只做 iOS/iPadOS；Mac 降级 |
| Unreal（嵌入） | ✘ | ✘ | ✘ | 不实现 |
| Unreal（整包 App） | ✔ | — | ✔ | 独立进程/独立 App |
| Spine `spine-ios` | ✔ | ✔ | ✔ | 可选 2D 运行时（4.x） |
| Live2D Native | ✔ | △（Metal 脚注） | ✔ | 可选，需 license |
| E-mote | ✔ | — | — | 可选，需商业许可 |
| Ren'Py | ✔（整包） | ✘ | ✔（整包） | 不嵌入 |
| RealityKit + USDZ | ✔ | ✔ | ✔ | 中性 3D / Mac 3D 备选 |
| PNG 差分 | ✔ | ✔ | ✔ | 最终回退 |

## 5 MLTD 支线迁移到组件化平台（第一个真实适配器）

### 5.1 分支文件 → 新协议/落点

| 分支文件 | 迁移后 |
|---|---|
| `UnityStandRenderer.swift`（241 行） | `Runtime/Unity/UnityCharacterRenderer.swift` → `CharacterRenderer`；删伪造 Spine 表（`:226-244`）、`load` 绕过（`:96-100`）、30×1.5s 重试语义改为 `RuntimeReport`/`RuntimeFailure` |
| `UnityStandRuntime.swift`（73 行） | `Runtime/Unity/UnityEngineHost.swift` → `PresentationRuntime`；`#if canImport(UnityFramework)`；`contentRoot` 改注入 |
| `UnityStandBridge.h/.mm` | 同目录；`#if __has_include(<UnityFramework/UnityFramework.h>)`；窗口处理留在 host |
| `UnityStandCatalog.swift`（53 行） | 删除；改 Core `PackageCatalog` 读 `model3d` 包 |
| `UnityStandPlaygroundView.swift`（330 行） | `RuntimePlaygroundView`；按钮由 `RuntimeCapabilities` 生成，不再硬编码 7 表情 |
| `CallView.swift` | 删 `standIs3D`（`:57,70,89,101,195,259`）；渲染器从 registry 取；`fullBleed` 来自 report |
| `SettingsView.swift` | `RuntimeSettingsStore` 显式注入；入口由包能力控制 |
| `AppModel.swift` / `RootView.swift` | 调试注入收进 `#if DEBUG` 的 `DebugLaunch`；安装走 `installPackage` |
| `project.yml` | `project-3d.yml` include + `optional: true` + `-ObjC`/`ENABLE_DEBUG_DYLIB` 只在 3D 变体 |
| `tools/fetch_unity3d_content.py` / `add_3d_test_character.py` | 前者产出 `model3d` 包（加 kind/runtime/capabilities/legal）；后者删除，角色↔模型进包 |
| `EidolonIOSUITests/Stand3DPlaygroundUITests.swift` | 按「有/无 3D 产物」条件化 skip，并加回退用例 |

### 5.2 步骤与验收

| 步 | 做什么 | 验收 |
|---|---|---|
| M0-1 | Core 加 `Presentation.swift`（5 类型 + `PackageHeader`）；`StandAnimator` 出 `PresentationFrame`，旧 API 标废弃 | `swift test` 全绿；现有 Stand 测试断言不改仍过 |
| M0-2 | App 加 2 协议 + `RuntimeRegistry`；先只注册 spine + avatar；5 处构造点改注入 | `grep "StandWebRenderer("` 只剩 registry/factory；2D 五个表面冒烟不变 |
| M0-3 | `project-3d.yml` 骨架 + `optional: true`；3D 代码先不入 | 删 Unity 目录后 `xcodegen` 退出 0、`xcodebuild` 成功、`swift test` 全绿 |
| M0-4 | `PlatformCapabilities` + 引擎缺失回退单测 | preferred→fallback→avatar 三跳覆盖 |
| M0-5 | `installPackage` 按 `PackageHeader` 分派；旧 manifest 加字段 | 旧内容包/立绘包/酒吧包仍能装；`engine_version` 不匹配拒装 |
| M1-1 | 3D 支线 rebase，按 §5.1 迁移；删 `standIs3D`/伪造表/`@AppStorage`/Release 环境变量 | 有产物与无产物两种构建都成功；Release `grep -a EIDOLON_3D_` 无命中 |
| M1-2 | 3D 内容打 `model3d` 包；角色↔模型进包；删 `haruka3d` | 安装包不含 227 MB 内容；无包时 3D 入口 `disabled(reason)` |
| M1-3 | 失败回退验收 | 3D 失败 → 2D → 头像，通话不中断；UI 测试全绿 |
| M1-4 | ADR-0034（UaaL）+ ADR-0035（组件化边界）+ ADR-0022 标 supersede | 无死链；文档能分别构建 3D 版/无 3D 版 |

**禁止顺序**：先合 3D 再补契约。当前分支的适配代码里约 1/3（伪造表、`standIs3D`、环境变量注入、Bundle 内内容）在契约落地后要重写。

## 6 iPad / macOS 适配

### 6.1 iPad（先做）

现状：`TARGETED_DEVICE_FAMILY: "1"`（`project.yml:42`），Info.plist 只有通用方向表（`Info.plist:46`）、没有 `~ipad` 方向、没有多 scene；酒吧靠强制横屏（`EidolonIOSApp.swift:30-38`）；通话层按屏幕高度位移（`RootView.swift:84-91`）。

官方硬约束（TN3192）：`UIRequiresFullScreen` 自 iPadOS 26 起弃用；iOS/iPadOS 27 起即使设为 YES 也不再退出 resize（系统改为离散缩放，且要求用 iOS 27 SDK 构建）；scene 化生命周期用最新 SDK 会强制；方向锁定改用 `prefersInterfaceOrientationLocked`，是否生效由系统决定（不保证）。

改动清单：

1. **设备族与方向**：`"1,2"`；加 `UISupportedInterfaceOrientations~ipad`（四方向）；不要再靠 `UIRequiresFullScreen`。
2. **导航**：`TabView` 加 `.tabViewStyle(.sidebarAdaptable)`（iOS 18+/macOS 15+），同一套 `Tab` 在 iPad 变侧边栏、在 Mac 恒侧边栏；对话/设置按宽度拆两栏（`NavigationSplitView` 或现有 stack + 宽度判断）。
3. **容器尺寸**：通话层/酒吧/`RootView` 的位移改用容器尺寸，不用 `UIScreen`。
4. **酒吧**：640×360 逻辑屏别再依赖强制横屏；改等比缩放 + 边距（`BarCanvas` 填色），或提供「旋转/全屏」按钮。方向锁在窗口化下只是偏好，系统可取消。
5. **多窗口**：先不做。`AppModel` 单例式状态 +「只有一通电话」与多 scene 冲突（ADR-0023 §6）。
6. **输入**：外接键盘 Esc 已有（ADR-0023:26）；补 `keyboardShortcut`/`focusable`；指针 hover 只在需要时加。
7. **验收**：iPad 真机/模拟器竖横屏、分屏 1/2、1/3、全屏；通话收起/展开不丢状态；酒吧不裁切；动态字体最大档不截断；3D 在 iPad 上按全屏/取景能力显示。

**上游对照**：上游 Next.js 只有一个结构断点 **768px**（`NavShell` 的 `md:flex-row`；nav rail 72px），内容列最大 640px（`PageShell`），设置 320+640，对话列表 240–480 可拖（`DESIGN.md:176-200`、`frontend/src/components/app/{NavShell,PageShell}.tsx`、`lib/panelSizes.ts:9`）。映射到 iPad：768pt 以上「侧栏 + 两栏」，以下保持单栏；同一路由按宽度露哪一栏，不写两套页面。

### 6.2 macOS 三条路径

| 路径 | 官方定位 | 当前依赖 | 适合什么 |
|---|---|---|---|
| **Designed for iPhone / iPad**（Xcode My Mac） | 未修改的 iOS App 直接跑在 Apple Silicon Mac，无移植；Xcode 可直接 Build & Run/调试/测试；不是 Simulator | 全部 iOS 框架都在；**Unity UaaL 未验证**；麦克风/音频会话语义未知 | **重构期间最快跑起来**；iPhone-only 是固定窗口，支持 iPad 多任务后才可缩放 |
| **Mac Catalyst** | iPad App 的 Mac 版，共享工程/源码；自动加沙盒 | UIKit（23 个文件）可复用；AVAudioSession 13.1+；BGTaskScheduler 13.1+；WebKit 可用；**Unity iOS framework 需排除** | 想要一个真正的 Mac 测试壳；3D 降级 |
| **原生 macOS target** | SwiftUI 多平台 + AppKit；`EidolonCore` 已支持 macOS 14 | **AVAudioSession 不存在**；BGTaskScheduler 不存在（换 `NSBackgroundActivityScheduler`）；UIKit 23 个文件要重写；Unity/UE 都要 macOS 导出或放弃 | 长期正式 Mac 版；不在重构期做 |

**推荐顺序**：阶段 0 现在就能做的 `swift test` + oracle（Core 已 macOS 14）→ 阶段 0.5 Xcode My Mac (Designed for iPhone) 冒烟（零代码）→ 阶段 1 iPad → 阶段 2 Designed for iPad（iPad 支持多任务后）→ 阶段 3 Catalyst（需要 Mac 版时）→ 阶段 4 原生 macOS（只有 Catalyst 不够时）。

**Mac 上测不了**：麦克风/通话音频路由/回声消除/后台锁屏（Designed for iPad 与 Catalyst 的语义都不等于真机）；触屏/手势/触觉/Pencil；iPad 多任务与多窗口；Unity/UE 的真实渲染与性能；发热/功耗/网络切换。**Mac 上能测**：Core 单测、oracle、内容包导入与数据库迁移、WebView/Spine 2D、LLM/TTS/STT 网络请求解析、SwiftUI 布局预览、部分 UI 测试（未验证）。

**Unity/UE 在 Mac**：Unity 官方 UaaL 只有 iOS；Epic 官方文档另有一条「用 Designed for iPad 在 Apple Silicon Mac 上测 iOS UE 工程」的建议（本项未逐字核对原文，标记为待核）。因此 3D 的 Mac 验收只能走 Designed for iPad（若 UaaL 在 iOS-on-Mac 环境可用，需实测）或 iPhone/iPad 真机/模拟器；Catalyst/原生 macOS 没有 Unity 路径。

### 6.3 平台扩展点（避免 `#if os` 散落）

- **`PlatformCapabilities`**（Core 值类型，App 注入）：family、microphone、resizableWindows、engines、memoryClass。
- **能力协议放 Core、实现放 App**：现有 27 个 `public protocol` 的形状直接沿用；再补 `AudioSessionManaging`（iOS `AVAudioSession`，macOS 空实现 + `AVAudioEngine` 设备管理）、`BackgroundScheduling`（iOS BGTask，macOS `NSBackgroundActivityScheduler`）。
- **UI shell**：`PlatformShell` 统一 TabView(sidebarAdaptable) / NavigationSplitView；`SceneChrome` 封装方向偏好/多窗口；通话层、酒吧读容器尺寸。
- **runtime 降级**：无麦克风 → 文字通话（已有 typed 路径）；无 Unity → Spine/头像；无 BGTask → 前台补偿（`RootView` 的 `catchUpReachOuts` 已在做）；无多窗口 → 单窗口。
- **fixture runtime**：`#if DEBUG` 的 `FixtureRuntime` + `FixtureRenderer`（确定性帧），让渲染器生命周期在无引擎、无网络、Mac 上都能测；`EIDOLON_RUNTIME=fixture` 仅 DEBUG。

## 7 顺序与「不做」

**关键路径**：

1. **Phase A（main 准备，先做）**：A1 干净 checkout 可构建（3D 内容/框架改可选，`project-3d.yml`）；A2 仓库卫生（派生数据、xcodeproj 与源码同步）；A3 ADR-0034（UaaL）+ ADR-0035（组件化边界）+ ADR-0022 supersede；A4 Core `Presentation.swift` + `PackageHeader` + 纯函数测试；A5 App 2 协议 + registry + 5 处构造点迁移。
2. **Phase B（iPad 最小提交）**：device family `"1,2"` + 方向表 + sidebarAdaptable + 容器尺寸 + 酒吧缩放；不带 3D，验证 2D 与布局。
3. **Phase C（3D 支线 rebase）**：按 §5 迁移；`model3d` 包；iPhone/iPad 真机验证；Mac 上自动降级到 2D/头像。
4. **Phase D（未来运行时）**：galgame 先做 **纯文本 VN IR fixture**（不嵌 Ren'Py）；CGSS/学マス 复用 Unity host，但 Unity 工程与内容适配器各自立项；星耀只留 negative runtime。
5. **Phase E（真正的 Mac 版）**：Catalyst 或原生 macOS，等 Phase B/C 稳定后再做。

**明确不做**：

- 不做 UE 嵌入实现（无官方路径，别为它设计协议）。
- 不把 Unity 搬到 Mac Catalyst/原生 macOS（无官方 UaaL；3D 在 Mac 降级）。
- 不为每个引擎写一套协议（只留 2 个协议 + 5 个值类型 + 字符串 RuntimeID）。
- 不做动态插件/运行时下载代码（iOS 限制 + App Review 风险）。
- 不合入 3D 前先补契约；不把 227 MB 内容继续塞 App 二进制。
- 不在 Core 里加 `#if os`（会把「Mac 可测」变成「只能 iOS 测」）。

## 8 风险与未知

**风险**：

1. **协议过度设计**：最危险的不是漏接口，是为「未来可能」造一堆空协议。控制为 4 条边界，未实现的运行时只留 RuntimeID。
2. **Spine 3.6 ↔ 4.x 断层**：官方 Swift 封装（Catalyst/macOS 全支持）是 4.x；升级美术导出或自绘 spine-c 3.6 都要成本，需单独决策。
3. **Unity 许可/版本锁**：UaaL 的 `UnityFramework` 与 `Data` 必须同次导出；Unity 升级回归成本高；App 体积 +378 MB（framework 129 + Data 22 + 内容 227）。
4. **Mac 音频语义**：原生 macOS 没有 `AVAudioSession`；Designed for iPad/Catalyst 的麦克风/路由/打断行为未验证，不能把 Mac 当通话验收环境。
5. **iOS 版本/窗口 API 变化快**：iPadOS 26/27 的 `UIRequiresFullScreen`/方向锁只是偏好，布局必须按容器尺寸而不是屏幕尺寸。
6. **许可**：Live2D 发布前签约、E-mote 按平台付费、Spine runtime 版本、Unity 条款、UE Engine Tools、AGPL-3.0 衍生边界、游戏素材不进仓库。`legal` 字段进 manifest，但不代替法务判断。
7. **文档/证据漂移**：3D 支线的 integration-plan/prototype-status/README/审计已多处不一致；组件化文档要指定单一事实源。

**未知（需实测/拿 SDK 后验证）**：

- Designed for iPad 下 Unity UaaL 是否真的能跑（Unity 官方未把 Mac 列为 UaaL 目标）；Mac 上 Metal 渲染/性能。
- Catalyst 下 `AVAudioSession` 的真实语义、`WKWebView` + 自定义 scheme + WebGL（Spine）是否完整。
- iPad 上 `sidebarAdaptable` 与「对话页整屏隐藏 tab」的组合；酒吧「请求横屏」在窗口化下是否生效。
- Spine 3.6 是否有等价的官方 Swift 封装；Live2D native 在原生 AppKit + Metal 的官方样例。
- 各运行时真实包体积/内存；AVAudioEngine 实际可解码格式（官方无清单）。
- UE `bBuildAsFramework`（Experimental）在 iOS 的实际可用性——不作为架构前提。

## 9 下一步建议（不实施）

1. **评审 §3 的命名与落点**（先单文件，不拆包）；确认后开两个 spike：① Core `Presentation.swift` + `PackageHeader` + 纯函数测试；② App registry + Spine host + 5 处构造点迁移，2D 行为零变化。
2. **main 的健康先修**：3D 内容/框架改可选、提交同步后的 xcodeproj、删派生数据；这是「干净 checkout 可构建」的前提。
3. **iPad 单独一次提交**：device family + 方向 + sidebar + 容器尺寸；不带 3D，先验收布局。
4. **Mac 冒烟今天就做**：Xcode 选 My Mac (Designed for iPhone) 跑现有 App（零代码），记录能测/不能测清单；iPad 版后再切 Designed for iPad。
5. **3D 支线**：按 §5 rebase；先 `model3d` 包 + 角色映射，再谈 iPad 3D；最后补 ADR-0034/0035。
6. **未来目标只留位，不实现**：galgame 先做纯文本 VN IR fixture；CGSS/学マス 复用 Unity host 但各自立 Unity 工程；星耀留 negative RuntimeID。

## 附录 A 来源与证据索引

- 本地：`project.yml:42`（device family）、`Info.plist:31,46`（iPhoneOS/方向）、`EidolonIOSApp.swift:30-38`（强制方向）、`RootView.swift:84-91`（通话层位移）、`Features/Stand/StandRenderer.swift:10-27`、`StandWebRenderer.swift:85-111`、`CallView.swift:202` 等 5 处构造点、`MainTabsView.swift:12-24`（Tab API）、`StandRender.swift:36-60`（相机只吃 aspect）、`StandOutfits.swift:56`（可注入 defaults）、`ContentManifest.swift:28`（kind）、`MomentsBackground.swift:13,33`、`ChatReadAloud.swift:37,119`（AVAudioSession）、`EidolonCore/Package.swift:6-8`（macOS 14）、`EidolonIOSUITests`（9 文件/50 用例）。
- 3D 支线（`feat/mltd-3d-stand`）：`UnityStandRenderer`/`UnityStandRuntime`/`UnityStandBridge`/`UnityStandCatalog`/`UnityStandPlaygroundView`、`project.yml` 的 framework/源目录、`tools/install_ipad.sh`、`docs/3d-stand-prototype-status.md`。
- Unity：UaaL 总览 <https://docs.unity3d.com/2022.3/Documentation/Manual/UnityasaLibrary.html>、UaaL iOS <https://docs.unity3d.com/2022.3/Documentation/Manual/UnityasaLibrary-iOS.html>、示例 <https://github.com/Unity-Technologies/uaal-example>。
- Epic：UE as a Library（4.27）<https://dev.epicgames.com/documentation/en-us/unreal-engine/building-unreal-engine-as-a-library?application_version=4.27>。
- Apple：Mac Catalyst <https://developer.apple.com/documentation/uikit/mac-catalyst>、iOS apps on Mac <https://developer.apple.com/documentation/apple-silicon/running-your-ios-apps-in-macos>、`sidebarAdaptable` <https://developer.apple.com/documentation/swiftui/tabviewstyle/sidebaradaptable>、`NavigationSplitView` <https://developer.apple.com/documentation/swiftui/navigationsplitview>、TN3192 <https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key>、USD 能力 <https://developer.apple.com/documentation/usd/validating-usd-files>、RealityKit <https://developer.apple.com/documentation/realitykit>、AVAudioSession <https://developer.apple.com/documentation/avfaudio/avaudiosession>。
- 2D/VN：Live2D 平台 <https://docs.live2d.com/en/cubism-sdk-manual/platform/>、许可 <https://www.live2d.com/en/sdk/license/>；Spine runtimes <https://esotericsoftware.com/spine-runtimes>、spine-ios <https://esotericsoftware.com/spine-ios>；E-mote <https://emote.mtwo.co.jp/products/>；Ren'Py iOS <https://www.renpy.org/doc/html/ios.html>。
- 上游：`frontend/src/components/app/NavShell.tsx:46`、`AppNav.tsx:38,67`、`PageShell.tsx:31`、`lib/panelSizes.ts:9`、`DESIGN.md:176-200`。
- 前两轮：[componentization-2026-11-09.md](componentization-2026-11-09.md)、[migration-template-2026-11-09.md](migration-template-2026-11-09.md)。

> 注：本文是调研笔记，不是实现计划；没有改代码、没有提交、没有读 `.env`、没有下载 SDK 或游戏资源。ADR 编号建议：0034 = UaaL、0035 = 组件化边界（0033 已被 3D 原生迁移占用）。
