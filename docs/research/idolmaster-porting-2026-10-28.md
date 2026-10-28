# 把ミリシタ / 星耀季节素材迁到当前 iOS 项目的可行性调查（2026-10-28）

调查日期：2026-10-28。范围：只读调查，不改代码、不接触游戏安装包、不提供解包/绕过 DRM 的步骤。方法：优先读官方站点、商店页、官方 EULA、官方活动资料；技术细节不足时用社区仓库作“社区事实”，并明确标注不是官方。当前项目侧只对照本仓库的内容包、立绘和语音接口。

## 结论摘要

**两个作品都不能直接套进现在的 Shiny Colors 管线。**

- **ミリシタ（MLTD）**：官方是 iOS/Android 手游（引擎社区资料标为 Unity），剧场和 Live 用 3D，官方还提供过低配设备的 2D 模式；当前项目要的“Spine 3.6 骨骼立绘”并没有官方证据。它的优势是仍在运营、移动端数据组织相对集中、社区工具多；难点是 3D/2D 资产都不是 Spine，剧情与语音需要从 Unity 资产和 ACB/HCA 音频里重建索引。[官方站](https://millionlive-theaterdays.idolmaster-official.jp/) / [App Store](https://apps.apple.com/jp/app/id1238569156) / [2D 模式报道](https://gamebiz.jp/news/187239)
- **星耀季节（Starlit Season）**：官方平台是 PS4/Steam，UE4.24，角色是 cel-look 3D，不是 2D Spine；当前 WebView + Spine 3.6 完全不能复用，必须换成 3D 管线。剧情/语音在 UE4 资产和社区观察到的 `.pak` 里，社区有 mod 管理器但没有官方导出。[官方站](https://starlit-season.idolmaster.jp/) / [Steam](https://store.steampowered.com/app/1046480/THE_IDOLMSTER_STARLIT_SEASON/) / [UE4.24 报道](https://game.watch.impress.co.jp/docs/news/1414931.html)
- **法律上**：未找到两款游戏的官方素材导出/再利用授权；星耀季节的 Steam EULA 明确禁止 reverse engineer、修改/衍生、绕过安全措施；官方“游戏实况政策”只许可实况/配信，不等于素材抽取或再分发。[Steam EULA](https://store.steampowered.com/eula/1046480_eula_0) / [星耀季节实况政策](https://starlit-season.idolmaster.jp/game_commentary_policy/)
- **相对更值得做最小验证的是ミリシタ**：移动端、Unity、社区资料更多，且至少存在 2D 卡面可以走“静态/轻动画立绘”路线；但这不是当前 Spine 立绘包，必须新增一种资产类型。星耀季节除非愿意做 UE4→iOS 3D 的完整转换，否则不建议先做。
- **当前项目的最大改造点不是剧情库，而是立绘和语音索引**：现有内容包只认 `data.json`/`data.atlas`/`data.png` 三件套（`EidolonCore/Sources/EidolonCore/Stand.swift:3-22`、`docs/adr/0017-stand-on-device-webview.md`），而两款作品都不是这套格式；现有 `SpeechSynthesis.synthesize(_:voice:)` 只返回音频 Data，没有游戏语音的 cue/字幕对齐层（`EidolonCore/Sources/EidolonCore/CallSession.swift:86-92`）。

### 可信度标记

| 级别 | 本文中的例子 | 依据 |
|---|---|---|
| 官方事实 | ミリシタ是 iOS/Android、3DCG 剧场/Live；星耀季节是 PS4/Steam、UE4.24、cel-look 3D | [ミリシタ官方站](https://millionlive-theaterdays.idolmaster-official.jp/)、[App Store](https://apps.apple.com/jp/app/id1238569156)、[星耀季节官方站](https://starlit-season.idolmaster.jp/)、[GAME Watch](https://game.watch.impress.co.jp/docs/news/1414931.html) |
| 社区事实 | ミリシタ用 Unity、ACB/HCA 工具、星耀季节 mod 以 `.pak/.sig` 为主 | [MLTDTools](https://github.com/OpenMLTD/MLTDTools)、[维基百科](https://zh.wikipedia.org/zh-hans/%E5%81%B6%E5%83%8F%E5%A4%A7%E5%B8%88_%E7%99%BE%E4%B8%87%E4%BA%BA%E6%BC%94%E5%94%B1%E4%BC%9A%EF%BC%81%E5%89%A7%E5%9C%BA%E6%97%B6%E5%85%89)、[StarlitSeasonMO2](https://github.com/MakotoIchinose/StarlitSeasonMO2) |
| 未确认/推测 | ミリシタ卡面是否是 Spine、语音 cue 是否能逐行对齐、星耀季节音频中间件 | 没有一手规范；只能拿到实际资产后验证 |

## ミリシタ

### 官方平台与服务状态

- 官方站写明平台是 **App Store / Google Play**，类型是“アイドルライブ&プロデュースゲーム”，基本免费、部分付费；页面仍写“App Store、Google Playにて配信中”。[官方站](https://millionlive-theaterdays.idolmaster-official.jp/)
- App Store 元数据（2026-10-28 读取）显示：版本 **9.0.350**，当前版本发布日 **2026-10-15**，2017-06-28 首发，12+，最低 iOS 15.0，发行商 Bandai Namco Entertainment Inc.。[App Store](https://apps.apple.com/jp/app/id1238569156)
- 2026-08-01 的 Famitsu 采访称 2026-06-29 迎来 **9 周年**，并谈到 10 周年准备；这支持“日服仍在运营”，但不能替代官方公告。[Famitsu 采访](https://www.famitsu.com/article/202608/82317)

> 可信度：平台、运营状态、版本号是官方商店/官方站事实；9 周年是准官方媒体事实。未找到“日服终止”的一手公告。

### 引擎、3D/2D 与立绘

- App Store 介绍明确写“**３Ｄで表現された劇場内**”“**３ＤＣＧで表現されたアイドルたちのライブパフォーマンス**”，并强调“フルボイス”。[App Store](https://apps.apple.com/jp/app/id1238569156)
- 官方站也写 Live 是 **3DCG**，衣装“8,000着以上”，可换衣装/发型。[官方站](https://millionlive-theaterdays.idolmaster-official.jp/)
- 2017 年官方曾宣布 Live 部分追加 **2D 模式**，目的是让性能较低的设备也能玩；报道只说明“2D 模式”，没有说它是 Spine 或 Live2D。[gamebiz 报道](https://gamebiz.jp/news/187239)
- 维基百科把游戏引擎标为 **Unity**（二手来源，不是官方）。[维基百科](https://zh.wikipedia.org/zh-hans/%E5%81%B6%E5%83%8F%E5%A4%A7%E5%B8%88_%E7%99%BE%E4%B8%87%E4%BA%BA%E6%BC%94%E5%94%B1%E4%BC%9A%EF%BC%81_%E5%89%A7%E5%9C%BA%E6%97%B6%E5%85%89)
- 社区工具 **MLTDTools** 提供 Unity 资源生成项目、模型/动作导出（MillionDance）、ACB 解包等；它是社区事实，不是官方 SDK。[MLTDTools](https://github.com/OpenMLTD/MLTDTools)
- 社区还有 Blender 模型脚本、UE4/5 machinima 框架等项目，进一步说明社区处理的是 **3D 模型/动作**，而不是 Spine 骨骼。[MLTD_BlenderScripts](https://github.com/MakotoIchinose/MLTD_BlenderScripts) / [MillionFramework](https://github.com/MakotoIchinose/MillionFramework)

**判断**：ミリシタ的“立绘”要分三类看：

1. **剧场/Live 的偶像**：3D 模型 + 动作/表情，当前 WebView/Spine 管线不能直接用；需要 SceneKit/RealityKit/Metal 或把模型/动作转成 glTF/USDZ 后在 iOS 渲染。
2. **卡面插画**：官方页面能看到 2D 卡面，但没有官方材料说它是 Spine 3.6 骨骼；不能假定 `data.json/data.atlas/data.png` 兼容。若只做静态卡面，当前项目可以新增“图片立绘”类型，但会失去现有的骨骼动作/口型/表情系统。
3. **官方 2D 模式**：只确认是低配 Live 的 2D 表现，未确认其运行时/格式；不能把它当成 Spine 兼容层。

> 可信度：3D 是官方商店/官方站事实；Unity 与社区工具是二手/社区事实；“卡面不是 Spine”是**未确认**，不是已证伪。需要拿到实际资产后才能定论。

### 剧情数据结构

- 官方只公开“コミュ”“イベント”“カード”等玩法层信息；官方站没有公开剧情数据库 schema、脚本格式或导出 API。[官方 STORY](https://millionlive-theaterdays.idolmaster-official.jp/story)
- 社区工具 MLTDTools 的说明是“查看 MLTD database files 的 card/costume 信息”“Manifest Tools”“MillionDance”等，面向资源与模型，不是官方剧情文本导出。[MLTDTools](https://github.com/OpenMLTD/MLTDTools)
- 社区卡牌数据库项目（如 mltd-searcher）说明社区能整理卡牌元数据，但这仍是社区整理，不是官方剧本包。[mltd-searcher](https://github.com/shadowdreamer/mltd-searcher)
- 因此，剧情迁移至少有四步：从 Unity 资产/manifest 找到剧本资源 → 解析章节/台词/说话人 → 处理日文编码与翻译 → 映射到当前 `episodes / episode_cast / episode_lines / episode_passages`（`EidolonCore/Sources/EidolonCore/ContentSchema.swift:5-37`）。当前导出器直接读 Shiny Colors 的 DB/stand 树（`tools/export_content_bundle.py`），没有通用游戏资源导入层。

> 可信度：官方没有公开 schema 是“未找到”的事实；具体资源格式未能从一手来源确认。任何“直接导出全部剧情”的说法都应视为社区推测。

### 语音

- MLTDTools 明确包含 **ACB Packer / HCA Decoder / ExtractAcb**，其中 ExtractAcb 从 `song3_*.acb.unity3d` 提取 ACB，HCA Decoder 默认使用 MLTD 的 HCA cipher；这是社区工具文档，不是官方格式规范。[MLTDTools](https://github.com/OpenMLTD/MLTDTools)
- `libcgss` 也声称支持 HCA/ACB，并适用于 MLTD；同样是社区实现。[libcgss](https://github.com/yhs0602/libcgss)
- 这说明技术上“音频可以从 ACB/HCA 解出”在社区层面成立；但**游戏语音是否全部走 ACB/HCA、是否按台词一文件一 cue、是否能和剧本行稳定对齐**，没有一手来源确认。语音还涉及声优表演者权利与音乐版权，不能只按“音频文件”处理。

> 可信度：ACB/HCA 工具是社区事实；“可解码”不等于“可合法再利用/可稳定对齐”。具体容器与 cue 结构需在合法取得的样本上验证。

## 星耀季节

### 官方平台与规格

- 官方站写明平台 **PlayStation 4 / STEAM**，2021-10-14 发售，类型“アイドルプロジェクトプロデュースゲーム”，CERO B；页面提示需同意游戏内服务利用规约。[官方站](https://starlit-season.idolmaster.jp/)
- Steam 商店页：开发者 **ILCA, Inc.**，发行 **BANDAI NAMCO Entertainment**，2021-10-14，单人，4 语言（日/简中/繁中/韩），日语音频 **Full Audio**，需要同意第三方 EULA。[Steam](https://store.steampowered.com/app/1046480/THE_IDOLMSTER_STARLIT_SEASON/)
- Steam 系统需求：Windows 10 64-bit、15 GB 可用空间、DirectX 11；没有 macOS 版。[Steam](https://store.steampowered.com/app/1046480/THE_IDOLMSTER_STARLIT_SEASON/)

### 引擎与立绘

- GAME Watch 对 **UNREAL FEST EXTREME 2022 SUMMER** 官方分享的报道明确写“本作は **UE4.24** で実装”，角色是 **セルルック**，背景偏写实，使用 Deferred Rendering；登坛者是 BNE 久多良木勇人 + ILCA 岩本東治郎。[GAME Watch](https://game.watch.impress.co.jp/docs/news/1414931.html)
- Epic Games Japan 官方 Docswell 的同一场分享也以“グラフィックス実装事例と最適化事例”为题，标签包含 **UE4 / UnrealEngine4 / ToonShading**。[Docswell](https://docswell.com/s/EpicGamesJapan/5G68XZ-UE_UFE22S_BNE_ILCA)
- 因此星耀季节的“立绘”实际是 **UE4 的 3D 角色 + 卡通着色 + 骨骼/面部动画**，不是 Spine 3.6 的 `data.json/data.atlas/data.png`。当前项目的 `StandRenderer`/WebView 只能加载 Spine 立绘，不能直接显示 UE4 资产（`docs/adr/0017-stand-on-device-webview.md`）。

> 可信度：UE4.24、3D、cel-look 有官方活动报道/官方账号资料支撑；具体模型/材质/动画资产格式没有一手公开规范。

### 资源格式与 mod 现状

- 社区 **StarlitSeasonMO2** 的 README 说，多数星耀季节 mod “packaged inside `.pak/.sig` files and not as loose `.uasset/.uexp` files”；这是社区 mod 管理器作者的观察，不是官方文档。[StarlitSeasonMO2](https://github.com/MakotoIchinose/StarlitSeasonMO2)
- 这说明星耀季节沿用 UE4 常见的 `.pak` 打包思路；但 `.pak` 是否加密、AES key、版本、内部 asset 命名等，未能从一手来源确认。
- 社区存在 Mod Organizer 2 插件、mod 包等（非官方），但没有找到 Bandai Namco 官方提供的素材导出/模组 SDK。官方站没有 mod/导出入口。[官方站](https://starlit-season.idolmaster.jp/)
- **不要**把“社区有 mod”理解为“可以自由提取/再分发”；见法律节。

### 剧情与语音

- Steam 页把游戏标为 Visual Novel / Dialogue Heavy / Story Rich，日语音频为 Full Audio，字幕有日/简中/繁中/韩；官方还有 STORY01–05 等剧情 DLC 包。[Steam](https://store.steampowered.com/app/1046480/THE_IDOLMSTER_STARLIT_SEASON/)
- 剧情是 UE4 资产中的对话脚本/关卡序列，语音是随剧情播放的音频；具体文本表、音频中间件、cue 命名未能从一手来源确认。社区 mod 讨论多集中在对话自动、存档、DLC 等，不是官方剧本导出。
- 对当前项目的映射难度高于ミリシタ：需要 UE4 资产解析 + 3D 角色/动画 + 语音 cue 对齐，且没有移动端运行时。**不建议先做。**

## 与当前项目的映射

### 立绘

| 维度 | 当前项目 | ミリシタ | 星耀季节 |
|---|---|---|---|
| 形态 | Spine 3.6 骨骼，`data.json`/`data.atlas`/`data.png` | 3D 剧场/Live；另有 2D 低配模式；卡面为 2D 插画（是否为骨骼未确认） | UE4.24 3D cel-look 角色 |
| 当前 WebView/Spine 能否直接渲染 | 能 | **不能**（需 3D 或新增图片/2D 适配） | **不能**（需 3D 管线） |
| 动作/表情 | 现有 Spine 动画名、嘴型、情绪映射 | 3D 动作/表情；2D 模式格式未确认 | UE4 动画/面部系统，需重做状态机 |
| 迁移工作量 | — | 中—高：新增资产类型 + 渲染器/动作映射 | 很高：UE4→iOS 3D 转换或重做 |
| 建议 | 保持现有 Spine 包 | 先做“静态卡面”或“2D 轻动画”验证，不冒充 Spine | 暂不投入 |

当前 `StandConfig` 只存默认衣装和衣装清单路径，`CharacterStand` 只认 `OutfitList`；立绘包 manifest 也只描述 `stand/` 树（`EidolonCore/Sources/EidolonCore/Stand.swift:3-22`、`docs/adr/0020-stand-bundles-split-and-incremental.md`）。要接ミリシタ/星耀季节，必须先决定是**新增一种 asset kind**（例如 `portrait`/`model3d`）还是另开一个渲染管线；不要把非 Spine 资产硬塞进 `stand/`。

### 剧情包

当前 schema 是：

- `episodes(id, category, source, title, imported_from, imported_at)`
- `episode_cast(episode_id, character_id)`
- `episode_lines(episode_id, seq, speaker, ja, zh)`
- `episode_passages(episode_id, seq, text, model, embedding)`

见 `EidolonCore/Sources/EidolonCore/ContentSchema.swift:5-37`。

| 维度 | ミリシタ | 星耀季节 |
|---|---|---|
| 文本形态 | Unity 资产/manifest 中的剧情/台词；社区工具偏向资源而非剧本 | UE4 资产中的对话/脚本；Visual Novel 结构 |
| 章节/卡剧情 | 有コミュ/活动/卡剧情，但无公开 schema | 主线 + 角色剧情 + 剧情 DLC |
| 翻译/编码 | 日文原文；需要翻译/对齐 | 官方有简中/繁中字幕，但文本在 UE4 资产里 |
| 映射到当前 schema | 可做，但要写专用 adapter；需要 speaker/seq/ja/zh 对齐 | 可做，但 UE4 解析成本更高 |
| 检索段落 | 需要重新切 passage + embedding | 同上 |

`tools/export_content_bundle.py` 是 Shiny Colors 专用：直接读上游 DB/stand 树，没有通用游戏资源导入层。迁移任一款都需要新的导出适配器，而不是改几行路径。

### 语音

当前接口：

```swift
public protocol SpeechSynthesis: Sendable {
    func synthesize(_ text: String, voice: CallVoice) async throws -> Data
}
```

见 `EidolonCore/Sources/EidolonCore/CallSession.swift:86-92`；现有实现是 Fish Audio TTS，不是播放游戏语音。

| 维度 | ミリシタ | 星耀季节 |
|---|---|---|
| 容器/编码 | 社区工具显示 ACB/HCA（含 MLTD HCA cipher）；具体语音 cue 结构未确认 | 未能从一手来源确认；UE4 常见音频中间件/pkg，不能据此断定 |
| 按台词索引 | 可能，但需从 ACB cue/剧本行建立映射 | 需从 UE 资产/音频包建立映射，成本更高 |
| 与当前 schema | `episode_lines` 没有 audio id/offset；要加列或旁表 | 同上 |
| 授权 | 声优表演者权利、音乐版权另计；无官方再利用许可 | 同上，且 EULA 更明确禁止改造 |
| 当前 TTS 是否可保留 | 可以：把游戏语音作为“已授权音频”注入 `SpeechSynthesis`，TTS 作为兜底 | 同上 |

**结论**：语音迁移不是“解码成 mp3 就完了”。即使能解码，也要解决“哪句台词对应哪段音频、从哪个时间点播放、情绪/语速是否匹配”的索引问题；当前 `episode_lines` 只有文本，没有音频字段。

### 工具

| 工具 | 现状 | 对迁移的意义 |
|---|---|---|
| `tools/export_content_bundle.py` | Shiny Colors 专用 | 需要新 adapter，不建议直接改造成多游戏巨型脚本 |
| `EidolonCore` 内容包/Stand | 只认 Spine + 当前 schema | 需要新 asset kind / importer |
| `WKWebView` + `spine-webgl` | Spine 3.6 专用 | 不能渲染 3D；也不要试图把 UE4 模型塞进 Spine |
| Fish Audio TTS | 当前语音实现 | 可保留为兜底；游戏语音应作为另一种 `SpeechSynthesis` 实现 |

## 法律与分发边界

- 两款作品的页面都标注 **©窪岡俊之 / ©Bandai Namco Entertainment Inc.**；角色、插画、模型、剧情、语音、音乐的权利属于 Bandai Namco 及其授权方。[ミリシタ官方站](https://millionlive-theaterdays.idolmaster-official.jp/) / [星耀季节官方站](https://starlit-season.idolmaster.jp/)
- 星耀季节 Steam 版 **第三方 EULA** 明确禁止（原文）：
  - “reverse engineer, decompile, disassemble, or attempt to discover the source code for the Game”
  - “modify, alter, or create any derivative works of the Game”
  - “circumvent, or attempt to circumvent, any security measures in the Game”
  - “use the Game for any purpose other than your own personal, noncommercial use”
  - 第 4 条说 Game 内容归 BANDAI NAMCO 或其 licensors。

  来源：[Steam EULA](https://store.steampowered.com/eula/1046480_eula_0)
- 星耀季节官方 **ゲーム実況ポリシー**（2021-10-14 制定，2024-10-07 改定）允许个人对游戏内全部内容做游戏实况/配信，但这是**实况/配信许可**，不是素材抽取、改造或再分发许可；政策还要求剧透提示。[官方政策](https://starlit-season.idolmaster.jp/game_commentary_policy/)
- ミリシタ的公开官方站没有给出素材再利用/导出许可；游戏内服务利用规约需要在 App 内查看。App Store 页面是官方分发页，但不等于素材授权。[App Store](https://apps.apple.com/jp/app/id1238569156)
- BNEI 通用“サービス利用規約”入口：[官方 EULA 页面](https://www.bandainamcoent.co.jp/cs/kiyaku/eula/)。本次未能从该公开页直接取到可引用的正文（页面由脚本加载），因此不逐条引用；以游戏内/Steam EULA 为准。
- **边界**：本项目“自用、不上架、不分发”降低的是分发风险，并不自动获得 reverse engineering / 修改 / 提取素材的授权；把素材打进 `.eidolonpkg` 再在设备上使用，仍然是复制和改造。若要做，应先取得权利人许可，或只使用官方公开、明确可再利用的素材（例如官方宣传图/试听，仍需看各自条款）。
- 不提供绕过 DRM、解密 `.pak`、提取 ACB/HCA 的具体步骤；这不是本调查的目标。技术上“社区有工具”不等于法律上允许。

## 建议的最小验证

### 先做哪款

**建议先做ミリシタ的“静态/2D 立绘 + 单段剧情 + 单条语音”验证，而不是星耀季节。**

理由：

1. ミリシタ是移动端 Unity，官方仍在运营，社区资料多；星耀季节是 UE4 3D 主机/PC 游戏，当前项目没有 3D 管线。
2. ミリシタ至少有 2D 卡面可作为“图片立绘”验证；星耀季节的立绘是 3D 角色，绕不开模型/材质/动画转换。
3. 剧情和语音两边都要专用 adapter；但ミリシタ的移动端资产粒度更接近“单卡/单コミュ”，适合先做一条垂直切片。

### 最小切片（建议顺序）

1. **法律前置**：确认你拥有游戏、只自用；确认不把素材提交到仓库、不发布包；如果要做可分发版本，先取得许可。没有这一步，不要开始提取。
2. **立绘（最小）**：选 1 个角色、1 张卡面，按“静态图片立绘”接入一个新的 `portrait` 资产类型；不做 Spine 兼容假设。验证：能显示、能换人、能随通话状态做淡入/表情替换（如果只有一张图，就先不做骨骼动作）。
3. **剧情（最小）**：选 1 段短コミュ，手工整理成 `episodes/episode_lines`（不写自动解包器），验证 `episode_lines` 的 `speaker/ja/zh` 和检索 passage 能否工作。若连一段都映射不了，就不值得写全量 adapter。
4. **语音（最小）**：选 1 条已合法取得的语音，写一个 `SpeechSynthesis` 的“本地音频”实现，验证播放/中断/和字幕对齐；暂时不碰 ACB/HCA 批量解码。
5. **星耀季节（可选）**：只做**不落地**的技术评估——用官方公开视频/截图验证 3D 管线需求；不要在未解决 UE4 资产授权前投入模型转换。若未来要做，先评估 SceneKit/RealityKit + glTF/USDZ，而不是 WebView。

### 需要的前置条件

- 一个**中立的中间格式**：`characters.json` + `episodes.jsonl`（或 SQLite）+ `audio/` + `portrait/` 清单；不要直接让导出器依赖某款游戏的资产布局。
- 一个新的立绘 asset kind（`portrait` 或 `model3d`），以及对应的 `StandRenderer`/`PortraitRenderer`；当前 `StandConfig` 只认 Spine 路径，不能复用。
- 语音表：`episode_lines` 增加 `audio_id`/`audio_offset`（或旁表），否则无法按台词播放。
- 版权/来源元数据：每个包记录 `source_game`、`source_asset_id`、`license_note`；当前 manifest 没有这些字段。
- 先在 Mac 上做离线转换，iOS 端只读转换后的包；不要把游戏原始 `.pak`/AssetBundle 直接搬进 App。

## 来源

### ミリシタ

- [アイドルマスター ミリオンライブ！ シアターデイズ（ミリシタ）官方站](https://millionlive-theaterdays.idolmaster-official.jp/) — 平台、3DCG、8000+ 衣装、版权。
- [App Store：ミリシタ](https://apps.apple.com/jp/app/id1238569156) — 版本 9.0.350、2026-10-15、3D 剧场/Live、全语音、iOS 15。
- [Famitsu 2026-08-01 9 周年采访](https://www.famitsu.com/article/202608/82317) — 2026-06-29 9 周年、仍在运营（准官方媒体）。
- [gamebiz 2017-06-20：Live 2D 模式](https://gamebiz.jp/news/187239) — 官方曾宣布 2D 模式，未说明 Spine/Live2D。
- [维基百科：ミリシタ](https://zh.wikipedia.org/zh-hans/%E5%81%B6%E5%83%8F%E5%A4%A7%E5%B8%88_%E7%99%BE%E4%B8%87%E4%BA%BA%E6%BC%94%E5%94%B1%E4%BC%9A%EF%BC%81_%E5%89%A7%E5%9C%BA%E6%97%B6%E5%85%89) — Unity 引擎（二手）。
- [OpenMLTD/MLTDTools](https://github.com/OpenMLTD/MLTDTools) — 社区工具；ACB/HCA、模型/动作、manifest；非官方。
- [libcgss](https://github.com/yhs0602/libcgss) — 社区 HCA/ACB 库，声称适用于 MLTD；非官方。
- [mltd-searcher](https://github.com/shadowdreamer/mltd-searcher) — 社区卡牌数据库；非官方。
- [MLTD_BlenderScripts](https://github.com/MakotoIchinose/MLTD_BlenderScripts) — 社区 3D 模型脚本；非官方。
- [MillionFramework](https://github.com/MakotoIchinose/MillionFramework) — 社区 UE4/5 machinima；非官方。

### 星耀季节

- [アイドルマスター スターリットシーズン 官方站](https://starlit-season.idolmaster.jp/) — PS4/Steam、2021-10-14、CERO B、游戏内规约提示、版权。
- [Steam：THE IDOLM@STER STARLIT SEASON](https://store.steampowered.com/app/1046480/THE_IDOLMSTER_STARLIT_SEASON/) — ILCA/BNE、2021-10-14、单人、4 语言、日语音频 Full Audio、15 GB、Windows。
- [Steam 第三方 EULA](https://store.steampowered.com/eula/1046480_eula_0) — 禁止 reverse engineer/decompile、修改/衍生、绕过安全措施、非个人非商业使用；内容归 BNEI/licensors。
- [GAME Watch：UNREAL FEST EXTREME 2022 SUMMER 报道](https://game.watch.impress.co.jp/docs/news/1414931.html) — UE4.24、cel-look 3D、Deferred Rendering、PS4/PC 帧率。
- [Epic Games Japan Docswell：星耀季节图形实现与优化](https://docswell.com/s/EpicGamesJapan/5G68XZ-UE_UFE22S_BNE_ILCA) — 官方活动资料，UE4/ToonShading。
- [星耀季节 游戏实况政策](https://starlit-season.idolmaster.jp/game_commentary_policy/) — 允许实况/配信，不等于素材再利用。
- [StarlitSeasonMO2](https://github.com/MakotoIchinose/StarlitSeasonMO2) — 社区 mod 管理器；README 提到 `.pak/.sig` 与 `.uasset/.uexp`；非官方。
- [BNEI 服务利用规约入口](https://www.bandainamcoent.co.jp/cs/kiyaku/eula/) — 官方入口；正文由脚本加载，本次未逐条引用。

### 当前项目

- `EidolonCore/Sources/EidolonCore/ContentSchema.swift:5-37` — episodes/cast/lines/passages schema。
- `EidolonCore/Sources/EidolonCore/Stand.swift:3-22` — `StandConfig` 只存默认衣装/衣装清单路径。
- `EidolonCore/Sources/EidolonCore/CallSession.swift:86-92` — `SpeechSynthesis.synthesize` 只返回音频 Data。
- `docs/adr/0017-stand-on-device-webview.md` — Spine 3.6 + WKWebView 立绘管线。
- `docs/adr/0020-stand-bundles-split-and-incremental.md` — 立绘包/内容包拆分与增量。
- `tools/export_content_bundle.py` — Shiny Colors 专用导出器，没有通用游戏资源导入层。

> 说明：本文把“官方页面明确写的”标为事实；把 GitHub README、维基、媒体报道标为“社区/二手”；把没有一手来源、只能从格式/平台推断的内容明确写“未确认/推测”。没有引用盗版下载站或破解教程，也没有给出绕过 DRM 的步骤。
