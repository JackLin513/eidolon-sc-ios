# ADR-0034：3D 立绘用 Unity as a Library，只进 iOS 的可选构建

日期：2026-11-09
状态：已接受

## 背景

3D 支线（`feat/mltd-3d-stand`）已经验证：MLTD 的原生 3D 模型/动作/表情可以在 iPhone 上通过嵌 Unity 运行时播放，且不需要把 Unity 工程搬进主仓库。它同时暴露出原型期的债务：Unity 内容塞在 App bundle、角色/衣装靠环境变量、`StandRenderer` 被伪造的 Spine 动画表撑满。

另一方面，组件化调研确认：Unity 官方 UaaL 只支持 iOS/Android/Windows/UWP，没有 macOS/Catalyst；UE 没有官方嵌入路径。S1 需要一个「默认 2D 不受影响、3D 可选」的边界。

## 决定

1. **3D 用 Unity as a Library（UaaL）**，只在 iOS/iPadOS 构建里可用；不进入 Mac Catalyst、不进入原生 macOS。
2. **默认构建不含 Unity**：`project.yml` 不依赖 framework；3D 变体由单独的 `project-3d.yml`/scheme 提供，需要本机导出的 `UnityFramework.framework` 与 `Data`。
3. **只 embed、不 link**：`UnityFramework.framework` 由原生 App 嵌入，启动时用桥接层 `EidolonUnityLoadFramework()` 懒加载；避免 dyld 在 `runUI` 之前初始化 Unity。
4. **3D 内容走 `model3d` 内容包**：模型、衣装、表情映射、引擎版本、文件校验和 legal 元数据由包声明；不再把 227 MB 内容塞进 App bundle，也不再用 `haruka3d`/`EIDOLON_3D_*` 决定角色。
5. **协议边界**：3D 适配器实现 `CharacterRenderer`/`PresentationRuntime`（ADR-0035），不再伪造 `StandPose.Report`；失败时按 runtime → spine → avatar 回退。
6. **S1 的验收**：无 Unity 产物的干净 checkout 可构建/测试；有产物时 3D scheme 可构建、真机可冒烟。3D 的完整性能/矩阵验收不在 S1。

## 后果

- 3D 只能作为可选构建分发；默认包可公开构建，3D 包只在本机装。
- 每个企划仍需要自己的 Unity 工程/C# 加载器和 `model3d` 包；UaaL 共享的是 Swift 宿主、消息协议与内容契约，不是「一个 Unity 通吃」。
- iOS 的硬限制进入产品语义：全屏、单实例、`Application.Quit` 后本会话不可重载、unload 后仍残留 80–180 MB。页面必须允许「只隐藏、不卸载」。
- macOS 上无官方 UaaL；Mac 的 3D 验收只能走 Designed for iPad（若可用，需实测）或真机，Catalyst/原生 macOS 不承诺。
- 3D framework/Data/内容不进仓库；构建脚本与内容包在用户本机生成/导入；spec 不写获取/脱壳/解密步骤。

## 考虑过的选项

- **RealityKit + 静态 USDZ**（ADR-0022 路线）：能绕开 Unity，但要把原生骨骼/曲线/蒙皮转到另一套骨架，已证明反复出问题，且 toon/材质/表情保真度低。
- **把 Unity 合进 main**：会让默认 checkout 依赖 378 MB 产物，且 main 的 2D 用户被迫下载引擎。
- **UE 嵌入**：官方 `UELibrary` 是 Win32 形态，iOS 只有 Experimental 的 `bBuildAsFramework`，无官方集成路径。
