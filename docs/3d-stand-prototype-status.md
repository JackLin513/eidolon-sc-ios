# 3D 立绘雏形状态（2026-11-09）

本文件给「现在能验证到什么程度」一个入口。详细研究/计划见
[3d-stand-integration-plan.md](3d-stand-integration-plan.md)、[ADR-0033/0034](adr/)。

## 已完成

- **B5 收口（#126）**：lipParam、材质写色、JBH 装配验证与关闭，证据在 `~/mltd-work/out/b5-126/`。
- **UaaL 嵌入**：Unity 6000.3.27f2 → `UnityFramework.framework` 只 embed 不 link，`Data/` 放在
  App bundle 根；`UnityStandRuntime` 懒加载，`UnityStandRenderer` 实现 `StandRenderer`，
  2D Spine（`StandWebRenderer`）与 3D 并存、设置里「3D 立绘（实验）」切换。
- **内容**：57 位 MLTD 角色 × 常服 `pr001` + 演出服 `ss003`，`build/Unity3DContent/`（约 227MB），
  设置里可选角色/衣装；真机安装包约 500MB。
- **通话页**：3D 整屏（2D 的舞台/头像/模糊背景在 3D 模式全部隐藏），取景可选
  全身/膝盖以上/腰以上（设置里的「3D 取景」，`EIDOLON_3D_FRAMING` 可覆盖）；全身时标题下移避开
  头部；真机与模拟器同一套代码。截图 `call-page-3d-waist.png`。
- **真实 API**：
  - 文字对话：App 内真实引擎 + SiliconFlow `deepseek-ai/DeepSeek-V4.1-Flash` 回复正常；
  - 通话：真实 LLM + 真 TTS（Fish）+ 百炼判断，验证「判断 → `StandEmotion`（shy/calm）+
    点头/摇头 → `StandDirector` → 3D 表情/动作」整条链路；证据
    `~/mltd-work/out/3d-stand/real-emotion-call.log`。
- **调试开关**（仅 DEBUG）：`EIDOLON_3D_STAND/_FORCE`、`EIDOLON_3D_DIAG`（整屏诊断页）、
  `EIDOLON_3D_IDOL/_OUTFIT`、`EIDOLON_3D_DIAG_CALL`、`EIDOLON_3D_DIAG_SAY`、`EIDOLON_DIAG_CHAT`、
  `EIDOLON_CALL_FAKE_SPEECH`、`EIDOLON_BAILIAN_*`、`EIDOLON_CHAT_API_KEY/_BASE_URL/_MODEL`。

## 3D 立绘预览（新增）

设置 → 立绘 → **3D 立绘预览**：一个不用打电话就能看 3D 的地方——角色选择、常服/演出服切换、
**取景（全身/膝盖以上/腰以上）**、平静/微笑/害羞/惊讶/难过/生气/认真 表情按钮、说话（口型）、
点头/摇头。截图：
`~/mltd-work/out/3d-stand/playground-pr001.png`、`playground-002chi-ss003.png`。
调试入口：`EIDOLON_3D_PLAYGROUND=1`（可直接启动到该页）、`EIDOLON_3D_PLAYGROUND_DEMO=1`
（自动依次切换表情，用于截图/回归）。表情在 App 内实测有效：平静/害羞/惊讶 等截图见
`~/mltd-work/out/3d-stand/playground-face-*.png`。

对话页入口：聊天页「⋯」菜单 →「看她 3D 立绘」，不用打电话就能看当前 3D 角色。

## 演示视频（模拟器，无需真机）

- `~/mltd-work/out/3d-stand/demo-playground.mp4`：3D 立绘预览页，自动轮播表情 + 说话口型；
- `~/mltd-work/out/3d-stand/demo-call.mp4`：通话页 3D 立绘待机动作。

（`xcrun simctl io recordVideo` 录制，已压到 540p。）

## 单开的 3D 测试角色（2026-11-09）

- 对话列表新增「天海春香」条目（内容包由 `tools/add_3d_test_character.py` 追加
  `haruka3d`，人设/声音为占位；`write` 后需重算 manifest 的 size/CRC）。
- **只有 haruka3d 走 3D**：SC 的 28 位偶像继续用 2D Spine 立绘和换衣装（真机已验证 mano 2D）。
- 3D 相关入口：她的通话页自动 3D；聊天页「⋯」→「3D 衣柜 / 立绘」；设置 → 立绘 → 衣装/取景。
- 3D 亮度：按 `_AmbientColor`/`_IllumiColor`/`_DiffuseColor` 材质抬亮，并把 shader 的 `_Light`
  指向镜头侧；真机对比明显变亮，截图 `device-haruka-bright.png`。
- Unity 启动画面：ProjectSettings 关闭 splash 画面/logo；真机快速连拍未见 Unity logo。
- 证据：`device-roster-haruka.png`、`device-haruka-bright.png`、`device-mano-2d.png`。

## 3D 立绘预览页（2026-11-09 修复）

之前进入预览页整页像卡死、按不动：Unity 视图盖住了控件，且引擎在主线程首帧里启动。
现在：Unity 视图只当背景层（`allowsHitTesting(false)`、容器 `isUserInteractionEnabled=false`），
引擎在首帧后异步启动；表情按钮改成两行网格（原来横向滚动把「生气」挤出屏幕）。
UI 测试 `EidolonIOSUITests/Stand3DPlaygroundUITests` 在模拟器上断言表情/口型/点头按钮
可点且页面有响应（已通过）。真机截图 `~/mltd-work/out/3d-stand/device-playground-fixed.png`。

## 触摸/布局/光照二次修复（2026-11-09 11:20）

- **触摸**：Unity 启动时会建自己的 UIWindow，窗口透明地盖在应用窗口上——画面看得见，
  但所有触摸都被它吃掉（真机上表现为「整页卡死、退不出去」）。桥接层新增
  `EidolonUnityDetachWindow`：隐藏 Unity 窗口、降到应用窗口之下，渲染继续走嵌进页面的 rootView。
- **布局**：控制面板可收起/展开（右上角箭头），导航栏加「关闭」，不再永久挡住角色下半身。
- **高光**：之前把 `_DiffuseColor/_Color` 也乘了系数、又加了 3.5 强度的面部点光，高光被打爆成白斑。
  现在只抬 `_AmbientColor/_IllumiColor`（1.35），去掉面部点光，主光 1.75/补光 0.45/环境 0.55，
  光向更偏上方。模拟器截图 `playground-toned-lighting.png`（肤色与衣服恢复自然明暗，无白斑）。
- 待真机确认：触摸是否恢复（模拟器不受 Unity 窗口影响，只能真机验证）。

## 色彩空间：按游戏原样改回 Gamma（2026-11-09 12:20）

一手证据在 `spikes/porting-3d/notes.md`「2026-10-29 色彩空间：已验证是 Gamma」：
游戏 `Data/data.unity3d` 里 `PlayerSettings.m_ActiveColorSpace == 0`（Gamma），
且 `Chr_Basic/Face/Hair/Glow/Bi_CharEye` 五个角色 shader **没有任何色彩空间转换**
（无 `ColorSpaceDouble` / `LinearToGammaSpace`），数学直接跑在 sRGB 值上。

我们之前用 Linear，等于把中间调压暗、色相整体偏移；再叠加“材质抬亮”把
`_Color`/`_IllumiColor`（游戏里是中性 0.5，shader 内 ×2）乘大，就出现了
「害羞表情脸像淤血」的紫红色块。现在的做法：

- `PlayerSettings.colorSpace` → **Gamma**；
- 撤掉所有材质颜色乘法与 `SetLightDirection`/补光/环境光覆写；
- 场景恢复单平行光 1.1，光向仍由材质里的 `_Light`（游戏值）决定。

模拟器验证：害羞表情腮红是自然的粉色、肤色回暖、衣服不再发灰
（`playground-gamma-shy.png`），无需再靠加灯提亮。

## 装到 iPad（2026-11-09 待开启开发者模式）

iPad Air 11-inch (M4) / iPadOS 27.0.1 已连线，但设备 **Developer Mode 关闭**，iOS 直接拒绝
挂载开发者镜像（`Installing cryptex ... disallowed because developer mode is not enabled`），
所以 App 与内容包都推不进去。开关这时还不出现在「设置 → 隐私与安全性」里，是因为这台
设备还没被 Xcode “准备”过一次；用 Xcode 的 Devices 窗口连一次就会出现该开关。
开好之后跑 `tools/install_ipad.sh`：构建（自动签名会把 iPad 加进描述文件）→ 安装 App →
推送三个内容包（内容包 73MB / 立绘包 560MB / 酒吧包 195MB）→ 自动导入内容包与酒吧包。

## 真机验证（2026-11-09 已通过）

证书信任后，在 iPhone Air 上实测：

- 3D 诊断页：`001har/pr001` 加载成功（`event: {"type":"loaded"...}`），整屏渲染；
  截图 `~/mltd-work/out/3d-stand/device-3d-diag.png`；
- 通话页：真实 DeepSeek（SiliconFlow `DeepSeek-V4.1-Flash`）回复 + 3D 立绘同屏，
  文字通话模式（`EIDOLON_CALL_FAKE_SPEECH` 代替麦克风）；截图
  `~/mltd-work/out/3d-stand/device-call-3d.png`。

## 真机验证步骤（需要用户先做一次证书信任）

App 已安装到 iPhone Air（`00008150-00183D380C08401C`），但 iOS 拒绝启动：

> 设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任 `linlong0513@gmail.com`

开发者模式已开（devicectl 查询 `Developer Mode Status: Enabled`）；只差证书信任：

0. 在手机上**点一下 Eidolon 图标**，出现「不受信任的开发者」提示后，按提示去
   设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任 `linlong0513@gmail.com`。
   （也可以直接到该设置页手动信任。）之后 App 即可启动；重新签名/换电脑后可能需要再信任。

信任后：

1. 打开 App → 设置 → 找到「3D 立绘（实验）」打开 → 选角色/衣装（默认 001har/pr001）。
2. 进任意角色通话层（或由开发用 `EIDOLON_3D_DIAG=1` 起整屏诊断页）。
3. 观察：3D 人物整屏出现、情绪变化时表情/点头跟随；长按录音说话可跑真实对话。

## 加载与失败兜底

- 3D 首帧到达前显示她的模糊立绘/背景，不再是纯黑舞台；
- Unity 加载失败时自动退回 2D/头像路径（调试开关 `EIDOLON_3D_FORCE_FAIL=1` 可复现）；
  截图 `~/mltd-work/out/3d-stand/call-page-3d-fallback.png`。

## 已知限制

- 模拟器里麦克风属于宿主 macOS 权限；真机正常。
- Unity 视图目前**不透明**（深色舞台底），UaaL 默认不透帧缓冲 alpha，透明合成待研究。
- 3D 全屏时标题下移后顶部有一条同色留白（可接受）。
- 每个角色目前只有一件常服 + 一套演出服；衣柜 UI 不在本阶段范围。
- 对话（文字）页本身不显示 3D 立绘：本阶段把 3D 接在通话页；文字页仍按 SC 的聊天形态。
- MLTD 角色独立进对话名册（人设/头像/语音）尚未做，当前是「SC 角色框架 + 可选 MLTD 3D 形象」。
