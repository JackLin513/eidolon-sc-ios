# ADR-0035：组件化边界——渲染、内容、身份、平台四层

日期：2026-11-09
状态：已接受

## 背景

组件化调研（`docs/research/componentization-2026-11-09.md`）的结论：`EidolonCore` 的引擎边界基本成立（零 UIKit/AVFoundation/WebKit import），但「换一种立绘运行时」没有真正成立：

- `StandRenderer` 只有一个消费者，且 5 个界面各自 `new StandWebRenderer`；
- 协议语义是 Spine 形状（动画名→时长），3D 只能伪造；
- 内容契约是三套独立 manifest，没有 `franchise`/`runtime`/`capabilities`；
- 没有构建变体，3D 产物会弄坏干净 checkout。

同时，未来要接 CGSS/学マス（Unity）、星耀（UE，无官方嵌入路径）、galgame（2D/VN）、多企划并存与跨企划场景。不能为每个目标造一套协议，也不能现在把未来接口全部写死。

## 决定

组件化只沿四条稳定边界扩展：

1. **内容契约**：`PackageHeader` + `ContentKind`（content/stand/bar/model3d/universe）；`model3d` 用独立的 `Model3DManifest`，带 `franchise`、`runtime`、`capabilities`、`files`（sha256/size）、`legal`、`engineVersion`。旧 manifest 只加可选字段，旧包照常读。
2. **渲染适配**：`CharacterRenderer`（每表面一个）+ `PresentationRuntime`（每引擎一个、进程单例）+ 编译期 `RuntimeRegistry`。`PresentationFrame` 是语义帧（情绪/说话/注视/点头/取景/减少动态），2D 适配器把它映射回 `StandPose`，3D 适配器映射成 Unity 消息。`StandRenderer` 删除；5 个构造点全部改为 registry 注入；页面不再认识 WebKit/Unity。
3. **能力协商**：包声明 `capabilities` 是上限，`prepare` 后的 `RuntimeReport.resolved` 是实测；页面只读实测。回退链固定为 runtime → `spine-webgl` → avatar；`avatar` 由页面绘制。主界面静默回退，调试页显示原因；3D 每会话最多重试 1 次。
4. **构建变体与平台能力**：引擎进 App 构建变体（默认不含 Unity，3D 用单独 scheme），素材进内容包；`PlatformCapabilities` 后续由 App 注入；`#if os`/`#if canImport` 只出现在 App 的 `Runtime/`/`Platform/`，Core 不加平台条件编译。

**不做**：动态插件/运行时下载代码；为未实现的运行时写空协议；`StageRenderer`（多角色同屏留到 S4 之后）；多角色 ensemble 引擎；UE 嵌入。

## 后果

- 新增一个运行时只需写一个 `PresentationRuntime` + 一个 `CharacterRenderer`，不改 5 个页面；这是 S1 的验收标准。
- 2D 的现有行为、Spine 动画表、oracle 六场景不变；`StandPose` 仍留在 Core 作为 2D 内部语义。
- 页面拿到的是能力/报告，不再是「有没有 3D」的布尔；`fullBleed` 取代 `standIs3D`。
- 默认 checkout 不需要 Unity；3D 的构建/内容/真机验收是单独的可选路径。
- 多企划并存（S3）与跨企划场景（S4）复用同一套内容/身份边界；S1 只预留 `ContentManifest.franchise`，不实现多包 registry 或参与者。

## 考虑过的选项

- **拆 SPM target**（`EidolonPresentation`/`EidolonRuntimeSpine`）：当前只有一个消费者和一个引擎，拆包只会增加 build graph；先用目录 + `public` 边界，S3 多企划落地后再评估。
- **每引擎一个协议**：会让页面按引擎分支；3D 支线已经证明这是伪造的源头。
- **动态加载运行时**：iOS 不允许合法动态代码，App Review 也不接受。
