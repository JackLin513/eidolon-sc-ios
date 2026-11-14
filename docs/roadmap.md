# 路线图（2026-11-09 重写）

旧版是「上游模块移植候选表」，1–9 项大多已完成，表格已删除；需要历史看 git history。当前路线来自四篇调研笔记（见文末），**调研结论不是已实现**，每一项都要再走 grill → spec → implement。

## 现在在哪

- App 已能独立运行：文字对话、通话、照片、朋友圈、立绘/换衣装、记忆与检索、搭话、酒吧、礼物/抽奖/成就、日历/周期/统计/用量、可选私有服务。现状以 README「现状与边界」为准。
- **S1 组件化 / 多运行时**：已完成（#133）。2D 五表面契约、可选 3D 适配器与运行时回退已落地。
- **S2 iPad**：已完成（#134/#137/#138/#139）。三断点三栏、通话 pane/胶囊、真机与模拟器验收通过。
- **macOS**：只保留平台化范围，完整支持拆到 #140；不阻塞 S3，也不承诺 Unity/UE。
- **S3 多内容包 / 复合身份**：代码与自动化测试完成（#135/#147，ADR-0037）。Phase A 多根 registry、kind 路由、`CharacterKey` 边界；Phase B v25 复合身份、用户库按企划隔离、内容包删除/重导入、每企划 3D 槽位已落地。待 iPhone Air 真机双包验收与 main 合并。
- **3D 立绘**：在本地分支 `feat/mltd-3d-stand`（未合入 main），资产管线在 `spike/mltd-3d-static`；先补 main 契约再 rebase，不直接合。

## 不变量（任何阶段都不破）

1. 自用、不上架；素材/密钥不进仓库，运行时只读用户本机生成的内容包。
2. 改提示词必须跑 `tools/oracle/run.sh`，六个场景与上游 `identical`；`swift test --package-path EidolonCore` 不联网。
3. 上游 checkout 只读；内容包/用户库分离、原子安装不破。
4. `EidolonCore` 不 import SwiftUI/UIKit/AVFoundation/WebKit；引擎进 App 构建变体，素材进内容包。
5. 不给未实现的运行时写空协议；不为「未来可能」造接口。UE 无官方嵌入路径，3D 同屏受 Unity UaaL 限制（单实例/全屏/不可重入）。

## 里程碑

| 阶段 | 目标 | 验收 |
|---|---|---|
| **M0 文档与 main 健康** | 本路线图、四篇调研、ADR-0034/0035 立项；main 干净 checkout 可构建（3D 内容/框架可选）；xcodeproj 与源码同步；仓库派生数据清理 | 无 Unity 产物可 `xcodegen` + 构建 + `swift test`；`git status` 干净；文档无死链 |
| **M1 组件化扩展点 + MLTD 适配器（S1，完成）** | Core `Presentation.swift`（5 类型 + `PackageHeader`）；App `PresentationRuntime`/`CharacterRenderer`/`RuntimeRegistry`；5 处构造点迁移；`project-3d.yml` 可选；3D 支线 rebase 成 `model3d` 内容包 | 2D 五表面行为不变；无 3D 构建通过；有 3D 产物时可选启用；失败回退 3D→2D→头像；oracle 六场景不变 |
| **M2 iPad（S2，完成；macOS 转 #140）** | device family `"1,2"`、iPad 方向表、`sidebarAdaptable`、对话/设置两栏、容器尺寸、酒吧缩放；Mac 用 My Mac (Designed for iPhone) 冒烟 | iPad 竖横屏/分屏/1/3 全屏不裁切；酒吧不进强制横屏；Mac 上能启动、导入包、跑 2D 与网络 |
| **M3 多企划并存（P0，S3）** | `Content/<franchise>/current` + `ContentRegistry`；`FranchiseID`/`CharacterKey`；`conversation_participants`/`messages.speaker`；v25 复合身份（旧库硬重置，不回填） | 两个企划包可同时安装；同 local id 的用户数据隔离；单角色 golden 不变；删除包后用户数据保留、重导入恢复 |
| **M4 跨企划文本场景（P1）** | `universe` 内容包、`ScenePlan`/`SpeakerPolicy`/`ScenePlanner`/`ScenePrompt`、记忆作用域；双角色纯文本 fixture | 4 轮 A→B→A→B 说话人/归属/好感正确；单角色 oracle 不变；不碰 ensemble 引擎 |
| **M5 多角色同屏（P2，可选）** | 先 `ZStack` 叠 N 个现有 `CharacterRenderer`（2D 优先） | 两个 2D 立绘同屏；暂停/恢复不互伤；3D 同台不承诺 |

## 明确不做（本路线范围内）

- UE 嵌入实现；星耀季节只留负向 `RuntimeID.unreal` / 离线转换。
- Unity 搬到 Mac Catalyst/原生 macOS；跨企划 3D 同屏。
- 动态插件/运行时下载代码；ensemble 回合引擎（等路线 A 的 fixture 证明必要）。
- 多窗口/多 scene（`AppModel` 单例 + 唯一通话与多窗口冲突）。
- 为未实现的运行时预造协议/空实现。

## 相关文档

- [组件化调研](research/componentization-2026-11-09.md)
- [迁移模板调研](research/migration-template-2026-11-09.md)
- [扩展点与平台适配](research/extension-points-and-platforms-2026-11-09.md)
- [多企划与跨企划场景模型](research/cross-franchise-model-2026-11-09.md)
- [调研笔记索引](research/README.md)
