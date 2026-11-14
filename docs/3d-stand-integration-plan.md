# 3D 立绘接入计划（B6-lite：不含衣橱）

目标（用户 2026-11-09 指令）：完成 **除衣柜/换装 UI 外** 的 MLTD 3D 迁移流程。
每个角色先只放 **常服（pr001）+ 一套演出服（ss003）**；3D 立绘出现在**对话与通话页**，
情绪由 LLM 回复驱动（表情/口型/眨眼/可选动作）；先出可装到 iPhone 的初步雏形。

## 当前状态

| 项 | 状态 |
| --- | --- |
| ADR-0033 原生迁移 B1–B5 | 已完成，代码在 `spikes/porting-3d/unity-spike/Assets/Scripts`（23 个 Native 文件 + CharacterBootstrap），已并入本分支 |
| #126 B5 收口三原子件 | `FaceLipParamNative` / `CharacterMaterialsNative` / `JointBodyHeadAssemblyNative` 已落地（commit a1ad36f3/a9e94106/ba645662），待按 spec 跑验收探针并收口 |
| ADR-0034 Unity as a Library | 决策已定；本分支开始实现 |
| 主分支 App 立绘接缝 | `StandRenderer`（ADR-0017）；现有实现 `StandWebRenderer`（Spine 2D）；`CallView` 在 `loadStand()` 里只 new 了 `StandWebRenderer` |
| 内容包 | 3D 资产尚未进 App；spike 用 `$MLTD_WORK` 下的本地 bundle |
| iOS 构建 | Unity 6000.3.27f2 的 **iOS Build Support 未安装**，正在用 `unity install-modules -m ios` 安装 |

## 架构

```
EidolonIOS (SwiftUI)
  CallView / StandPreviewView
        │ StandRenderer（ADR-0017 不变）
        ▼
  UnityStandRenderer（新，第三实现）         StandWebRenderer（保留，2D）
        │ 消息：loadCharacter/outfit、setEmotion、setSpeaking、setNod、resize、pause
        ▼
  UnityFramework.framework（Unity 6000.3 导出，嵌入 App）
        │ 场景 StandScene：Camera(透明/深色底) + Light + EidolonStandHost
        ▼
  spikes/porting-3d/unity-spike 的 23 个原生 C# 文件（原样复用）
        │ 读 App 内置 3D 资源目录：
        ▼
  EidolonIOS/Resources/Unity3D/（原型内嵌，后续改内容包机制）
    cb_pr001_<idol>/cb_ss003_<idol>/ch_*  + facial_chara + chara_soul + chara_shadow
    motion/<idol>.imo.json（待机/情绪动作）  emotion-map.json
```

### 消息面（Swift ⇄ Unity）

Unity 侧 `EidolonStandHost`（MonoBehaviour）暴露：
- `LoadCharacter(string json)`：`{characterId, bodyBundle, headBundle, outfitId, contentRoot}`（绝对路径由 Swift 传，原型用 `Bundle.main` 内资源）。
- `SetEmotion(int index)`：0..6 = StandEmotion 顺序；映射表读 `emotion-map.json` → FaceCtrl 表情索引 + 可选 gesture。
- `SetSpeaking(bool)`：口型开合循环。
- `SetNod(int kind)`：0=yes 1=no，播一次。
- `SetPaused(bool)`、`Resize(w,h)`（Unity view 由 Swift 布局，直接 set view frame；可选）。
- Unity → Swift：`@_cdecl("EidolonUnityEvent")` C 函数，JSON `{type:"loaded", animations:[...]}` / `{type:"failure", reason}`。

Swift 侧：
- `UnityRuntime`：懒加载 `UnityFramework.getInstance()`，`runUI`，拿 `appController().rootView` 当 renderer.view。
- `UnityStandRenderer: StandRenderer`：把 `StandPose`（情绪/说话/点头/framing）翻译成上面的消息；
  `onLoaded`/`onFailure` 由 Unity 事件回填；`setPaused` 走 `UnityFramework.pause/unpause` 或消息。
- 设置里加「立绘风格：2D / 3D（实验）」：默认 2D；3D 可用时 `CallView.loadStand()` 选 `UnityStandRenderer`。
- `emotion-map.json` 数据表（内容包优先，缺失回落内置）映射 7 情绪 → MLTD `facialMenu` 表情名。

### 内容（原型内嵌）

`tools/build_unity3d_content.py`（新）从 NAS 资产服务器抓取并生成：
- 52 角色 × {pr001, ss003} 的 `cb_*`/`ch_*` bundle（约 50–60MB）
- 共享：`facial_chara`（表情表 JSON 由 spike 的导出脚本生成）、`chara_soul`、`chara_shadow`
- 每角色一个待机动作：`chr_anim_com_<idol>` 的 `act` 循环 → `eidolon.motion/1`（spike 已解码）
- `emotion-map.json` 初始版（7 情绪 → 28 表情名里的首选/备选）

## 进度（2026-11-09 01:55）

- **M1 Unity iOS 导出**：完成。`unity build --target iOS --execute-method iOSExport.Build` 产出
  `spikes/porting-3d/unity-spike/build/ios-export/`（iOS Build Support 已装），
  `xcodebuild -scheme UnityFramework` 编出 135MB 的 UnityFramework（arm64 device）。
- **M2 最小 UaaL 宿主**：完成一半：framework + `Data` 已进 App，App 能编译并装到 iPhone Air；
  首次启动被 iOS 拦成「不受信任的开发者」（需要用户在设置里信任开发证书后才能验证运行时）。
- 内容：`build/Unity3DContent/` 已生成（57 角色 × pr001/ss003、facial/soul/shadow、act/yes/noo 三段 60fps flat TSV，
  约 227MB；只保留待机+点头，其余动作先删掉减重）。
- **M0 #126**：完成。Unity Editor 运行态验证 lipParam/材质写色/JBH 装配，console 0 error；
  证据 `~/mltd-work/out/b5-126/`（README + 探针 dump + 截图），JBH 节点解析与装配顺序已修。
- **M3 运行时（Unity 侧）**：完成并在编辑器验证：StandHost/Motion/Face/Bridge + 场景，
  动作与 flat TSV 逐位一致、情绪/口型/脸红可用、JBH 装配通过。
- **M3 App 侧（已完成）**：`EIDOLON_3D_DIAG=1` 诊断页（整屏 Unity 3D，自动加载 001har/pr001，
  显示事件），设置 → 立绘 → 3D 开关下新增「3D 角色 / 3D 衣装」选择器（清单来自
  `Unity3DContent/manifest.json`，57 角色 × pr001/ss003）；`UnityStandRenderer` 读取设置。
  设备构建 `8bad4c28`，已重新装到 iPhone（仍等信任证书）。
- **M3 通话页（2026-11-09 03:13，模拟器验证）**：内容包装入模拟器 App 后，
  `EIDOLON_3D_FORCE=1 EIDOLON_3D_DIAG_CALL=mano` 直接挂起真乃的通话页（不拨号、不申请麦克风），
  Unity 侧懒加载并显示 **001har/pr001 3D 立绘**：`[stand] loaded 001har/pr001`。
  截图 `~/mltd-work/out/3d-stand/simulator-call-3d.png`。
  过程中修：早期 failure 事件不能直接判死（场景未就绪/重试竞态），改为加载成功前持续重试；
  `LoadCharacter` 在 StandHost 侧加 in-flight 去重；调试路径绕过 2D Spine 立绘的 `core.stand` 前置条件。
  剩余打磨：Unity 视图目前是 2D 立绘的「下 80%」布局里的一块不透明深底，需要改成整屏/透明合成
  并按 viewport 宽高比取景。
- **M5 真实 API 对话测试（2026-11-09 03:26，模拟器）**：新增调试入口
  `EIDOLON_DIAG_CHAT=<文本>`，在 App 内用真实引擎跑一轮文字对话（同一套 prompt/检索/判断），
  再用 `EIDOLON_API_ENV_FILE` 注入百炼判断服务跑情绪判断：
  - SiliconFlow `deepseek-ai/DeepSeek-V4.1-Flash` 回复：「那个……您是不是特别累呀？……」
  - 百炼 System One 情绪判断返回 `StandEmotion.calm`（nod=nil）
  证据 `~/mltd-work/out/3d-stand/real-api-chat.log`。
  这说明「真实 LLM 回复 → 情绪判断 → StandEmotion」在 App 内已打通；StandEmotion → 3D 表情
  （FaceCtrl 索引）已在 Unity 侧用 SetEmotion 验证过。
- **M3 布局打磨（2026-11-09 03:40，模拟器）**：通话页的 3D 视图改为**整屏**（忽略安全区、
  半透明压暗背景代替 2D 下 80% 舞台），取景用 full 全身；新增 `headroom 3%→8%` 避免头顶贴边。
  截图 `~/mltd-work/out/3d-stand/simulator-call-3d-fullscreen.png`。
  仍待打磨：Unity 背景不透明（暂用深色舞台底）、拨号态的头像气泡会盖在 3D 上（真实通话连上后消失）、
  人物整体偏暗（光照/材质全局量可调）。
- **M5 真实通话（2026-11-09 04:20，模拟器）**：用 `EIDOLON_CALL_FAKE_SPEECH` 绕开模拟器
  麦克风（宿主 Simulator 没给录音权限），真模型 + 真判断服务（百炼）跑通：
  `judge=true emotionJudge=true`、`session=true`、她的回复逐段出现、状态 thinking→speaking→listening，
  3D 立绘同时加载。**mood 仍为 calm**：大概率判断结果晚于片段说完被 `StandDirector` 丢弃，
  或百炼返回 calm；待下一步用 Core 探针/日志确认。证据 `~/mltd-work/out/3d-stand/real-call.log`。
- 调试经验：`bootstrap` 里 await 网络会被启动 watchdog 杀掉，长任务要 `Task {}` 放到 UI 起来之后；
  `applyDebugBailianSettings` 的 Keychain 写入失败时要回落到内存 settings（已修）。
- **M6 情绪联动（2026-11-09 04:33，模拟器，语音通话）**：用 `EIDOLON_CALL_FAKE_SPEECH`
  + `EIDOLON_FISH_API_KEY` 跑**语音**通话（textOnly=false），把百炼判断、LLM、TTS、3D 全串起来：
  `JUDGE r=0 s=0 -> shy`、`s=1 -> shy nod=yes`，随后 `mood -> shy`（speaking）
  与 `mood -> calm`、`nod=no` 都进入 StandDirector。说明 textOnly 通话里 mood 一直 calm 是
  **文字片段太短、判断结果晚于片段结束被丢弃**，语音通话里正常。
  证据 `~/mltd-work/out/3d-stand/real-emotion-call.log`。
- **M7 设置开关路径（2026-11-09 04:47，模拟器）**：修了两个真正影响用户手动体验的问题：
  1. 3D 渲染不再依赖 2D Spine 立绘包（`core.stand` 查不到时也能出 3D）——设置里打开
     「3D 立绘」即可，不必先装 900MB 的立绘包；
  2. 没有通话时（调试挂载/页面刚打开）`updatePause` 会把 Unity 暂停，导致场景永远不加载、
     屏幕全黑——现在 `.absent` 时不暂停。修完后仅靠 UserDefaults 开关就出 3D：
     `[stand] loaded 001har/pr001`，截图 `~/mltd-work/out/3d-stand/simulator-call-3d-toggle.png`。
- 设备端：device UnityFramework 已用最新 C#（headroom/去重）重编并重新打包安装，等证书信任。
- **M8 角色/衣装切换（2026-11-09 04:55，模拟器）**：设置项 `Eidolon3DIdol/Eidolon3DOutfit`
  与调试注入（`EIDOLON_3D_IDOL/_OUTFIT`）都能换角色与两套衣服：
  `EIDOLON_3D_IDOL=002chi EIDOLON_3D_OUTFIT=ss003` → `[stand] loaded 002chi/ss003`，
  即「每个角色常服 pr001 + 演出服 ss003」内容侧已验证（57 人 × 2 套）。
  截图 `~/mltd-work/out/3d-stand/simulator-call-3d-stage-outfit.png`。
  已知模拟器噪音：重装 App 后 iOS 会重新弹麦克风授权（宿主 Simulator 权限），不影响真机。
- **M9 3D 页面收尾（2026-11-09 05:02，模拟器）**：新增 `standIs3D` 状态——3D 模式下彻底
  隐藏 2D 头像气泡/模糊背景/下 80% 舞台，只留整屏 3D + 压暗层；`hasStand` 也认 3D，避免
  「没有 2D 立绘」时错误显示大头像。重装/清空模拟器后预授权麦克风，拿到干净截图：
  - `~/mltd-work/out/3d-stand/call-page-3d-pr001.png`（通话页 + 001har/pr001）
  - `~/mltd-work/out/3d-stand/diag-3d-002chi-ss003.png`（诊断页 + 002chi/ss003 演出服）
  - `~/mltd-work/out/3d-stand/diag-3d-001har-pr001.png`
  已知遗留：3D 全屏时角色头顶与页面标题重叠一点（可后续下移角色或标题）；背景仍是不透明深色舞台。
- **M10 光照与透明背景尝试（2026-11-09 05:26，模拟器）**：
  - 光照：平行光 1.1→1.45 + 补光 0.4 + 环境光 Flat(0.32)，人像明显变亮；
  - 透明背景：相机 clear alpha 0 + `UnityView.isOpaque=false`/`layer.isOpaque=false`，
    **实测仍是深色底**——UaaL 默认不把 Unity 帧缓冲 alpha 合到宿主视图，要继续做需要改
    Unity 渲染层（CAMetalLayer/framebuffer）配置，暂按「深色舞台底」保留。
  截图 `~/mltd-work/out/3d-stand/call-page-3d-lighting.png`。
- **M11 标题/头顶分离（2026-11-09 05:52，模拟器）**：3D 整屏视图整体下移 46pt，页面标题
  落在她头顶上方而不是盖在脸上；截图 `~/mltd-work/out/3d-stand/call-page-3d-title-clear.png`。
  device UnityFramework（新光照）已重编并重新打包安装；仍未跨过证书信任。
- 待验证/下一步：真机信任后截图；MLTD 角色进名册；更多角色/衣装抽查。
- **模拟器验证（成功，2026-11-09 02:48）**：`iOSExport.BuildSimulator`（SimulatorSDK +
  ARM64）导出 → `xcodebuild -sdk iphonesimulator -arch arm64` 构建 UnityFramework →
  App 换用 sim framework + **sim 版 Data**（device 的 Data 与 sim il2cpp 代码不匹配会崩在
  il2cpp metadata 初始化）→ iPhone Air 模拟器 `EIDOLON_3D_DIAG=1` 启动：
  `[stand] loaded 001har/pr001`、Unity 视图嵌入 SwiftUI、天海春香常服渲染成功。
  截图 `~/mltd-work/out/3d-stand/simulator-3d-stand.png`。
  关键修复：xcodegen 的 framework dependency 必须 `link: false`（只 embed），否则 dyld 在
  App 启动时自动加载 UnityFramework，Unity 静态初始化早于 runUI，App 白屏闪退。

## 里程碑与验收

1. **M0 #126 收口**：Unity Editor 跑 B5 探针（lipParam 数值、材质写色、JBH 装配），console 0 error，截图/日志落 `$MLTD_WORK/out/b5/`；更新 #126 issue 状态。
2. **M1 Unity iOS 导出**：装 iOS Build Support；`BuildScript.Build()` 产出 Xcode 工程；`UnityFramework` 能编过（模拟器可跳，真机 arm64 必须）。
3. **M2 最小 UaaL 宿主**：新建一个最小 iOS 验证 target 或直接在 EidolonIOS 里加 `UnityRuntime` + 一个诊断页，Unity view 显示 Haruka 静止站立（透明/深底），证明嵌入链路。
4. **M3 UnityStandRenderer + 2D/3D 开关**：通话页能切换 3D，加载常服/演出服，情绪驱动表情 + 说话口型 + 眨眼；通话流程其余不变。
5. **M4 对话页/预览页**：`StandPreviewView`（设置里的立绘预览）与对话相关页面能显示 3D；每个角色 2 套衣服可切换（不做衣橱 UI）。
6. **M5 DeepSeek 真实对话测试**：用 main 分支配置的 API 密钥跑文字对话 + 通话（至少一轮），确认情绪→表情链路。
7. **M6 装机**：`xcrun devicectl` 装到用户 iPhone Air，附验收清单；用户确认雏形。

## 风险 / 已知未知

- Unity iOS 模块下载 ~1.4GB（进行中）；Unity 6 UaaL 集成步骤以官方文档为准（需查证 `Data` 目录归属、`-ObjC`、`UnityFramework` 嵌入方式）。
- Unity view 叠加透明度：通话页背景是模糊立绘；先接受 Unity 渲染深色不透明背景（原型），后续再做透明合成。
- App 体积 +~200MB（ADR-0034 已接受）。
- 表情/口型在新衣装下的 Phase 0 验收（#128 要求）先做 ss003/pr001 两套。
- 旧 `spike/mltd-3d-static` 里 RealityKit 时代的 `spikes/porting-3d/ios` 不再作为 target（只留参考）。
