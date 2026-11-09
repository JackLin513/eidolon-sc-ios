# 组件化调研：把 Eidolon 客户端拆成「可换企划」的部件（2026-11-09）

调查日期 2026-11-09。**只读调查**：没有改代码、没有提交、没有读 `.env`；未运行本 App 与上游后端（只对 sc-new 跑过一次它自带的纯标准库离线测试，用于确认素材可跑）。三个来源：

| 来源 | 版本 | 用途 |
|---|---|---|
| 本仓库 | worktree `8c05c7de`（分支 `dsh-659b97a2-fcd2`） | 被调查对象 |
| 上游 [Sallyn0225/eidolon-sc](https://github.com/Sallyn0225/eidolon-sc) | 本地 checkout `caa71b63` | 参考实现与离线数据管线 |
| [r1ncu/eidolon-sc-new](https://github.com/r1ncu/eidolon-sc-new) | `main` `13ae3b3`（只读 clone） | 「内核 + 插件」重构版，组件化的直接参照 |

方法：读源码与一手文档（README、`docs/adr/`、`docs/design/`、上游 `backend/`、新仓库 `docs/architecture.md`），数字用 `wc -l` / `grep` 交叉核对，行数均为实测；分类行数有重叠，只用于看体量。推断处标「推断」。

## 0 结论摘要

1. **`EidolonCore` 不依赖 UI 是真的，但这不等于可复用。** 128 个文件里零 SwiftUI/UIKit/AVFoundation/WebKit import，27 个 `public protocol` 把音频、识别、合成、LLM、判断、向量化、生图都倒置了；没解决的是**企划轴**——语言契约、世界模型、立绘资产格式、玩法集合、数据管线，全都直接写在 Core 里。
2. **Core 已经有 46% 不是「引擎」，是这台作品的玩法。** 酒吧 25 文件 5,616 行、朋友圈 2,509、照片 1,936、立绘 1,327、好感/礼物/成就 2,221、日程/周期/日历 3,214。组件化的第一价值是让这一半**能整块不装**，不是把它改成通用。
3. **真正的 seam 只有一个，而且是 God facade。** `Eidolon` actor 由 23 个 `extension` 文件贡献了 638 个 `public func/var/let`；App 侧 `AppModel` 1,889 行持有一切，42 处 `@Environment(AppModel.self)`、35 处视图直调 `app.core.*`，`CallController` 还反向 `weak var app`。所以组件化的工作量不是「新建目录」，是**切这个 facade + 补一层应用服务**。
4. **eidolon-sc-new 值得抄四条契约，不值得抄粒度。** 回合四阶段、三种钩子（gate/enrich/observe）、提示词四槽即缓存边界、能力上报（capabilities）；但作者自己说「拆的太碎了」（`README.md:12`），碎在契约没收敛（string facts、order 魔数、capabilities 形状各异）。
5. **换企划的成本中心在数据管线与资产格式，不在回合引擎。** 上游把「角色是谁」做成了数据（`characters/`、`corpus/`），但仍有十余处企划文案写死在提示词里；本仓库又把 Spine 3.6 三件套、东京时间、日本节假日、`ja/zh` 两列剧情表固化进了 Core。这些才是换企划时真正要动的地方。
6. **建议顺序：先 shell，再契约，再切包，最后用「第二个企划」验收。** 在出现第二个真实消费者之前，不拆 6 个包、不把语言/世界模型参数化到「什么都可配」；先做最小两包 + 一套带类型的 feature 契约，再用一个纯文本的第二企划内容包跑通。理由见 §4、§6。

## 1 三个仓库的架构事实

### 1.1 本仓库：两层，但第二层已经膨胀

| 部分 | 文件 | 行数 | 备注 |
|---|---:|---:|---|
| `EidolonCore/Sources/EidolonCore` | 128 | 36,566 | 唯一 library target（`EidolonCore/Package.swift:11,18-24`），只依赖 GRDB + ZIPFoundation |
| 其中测试 | 95 | 26,957 | 1,155 个 `func test`，是拆包最大的安全网，也是最大的一笔迁移成本 |
| `EidolonIOS`（App） | 83 | 24,996 | `AppModel.swift` 1,889 行，占 `App/` 目录 2,448 行的 77% |
| `tools/`（Python） | — | — | 内容包/立绘包/酒吧包导出、oracle 对照；依赖上游 checkout 与 schema |
| `server/`（可选） | 14 个 py | — | 只管「包从哪来 / 公告在哪看」，不是运行依赖 |

Core 内部按功能看（`wc -l` 实测，分类有重叠）：

| 子系统 | 行数 | 关键文件 |
|---|---:|---|
| 回合、提示词、判断、检索 | ~6.3k | `EidolonTurn.swift` 1,719；`SystemOne.swift` 744；`Judge.swift` 512；`Retrieval.swift` 532；`ReplyFormatInstructions.swift` |
| 通话状态机 | 2,580 | `CallSession.swift` 1,688（音频走注入协议，ADR-0015） |
| 酒吧 | 5,616（25 文件） | `BarSession.swift` 836、`BarRules.swift`、`BarPrompt.swift`、`DrinkCatalog.swift` |
| 朋友圈 | 2,509 | `Moments.swift` 1,972 |
| 照片 | 1,936 | `ImageGeneration.swift`、`Photo*.swift` |
| 立绘 | 1,327 | `Stand*.swift`；`StandAnimator.swift:8-45` 写死 Spine 动画名 |
| 好感 / 礼物 / 成就 | 2,221 | `Achievements.swift` 818、`Gifts.swift` 680、`Affinity.swift` 363 |
| 日程 / 周期 / 日历 | 3,214 | `Schedule.swift` 1,050、`CycleGuide.swift` 561 |
| 内容包 / 用户库 / facade | 2,748 | `Eidolon.swift` 673、`UserSchema.swift`、`ContentBundleInstaller.swift` |
| provider / 用量 / 统计 / 追踪 / 私有服务 | 3,851 | `Usage.swift` 1,267、`Stats.swift`、`Server.swift` |

依赖形状：

- App 只通过一个 `Eidolon` actor 驱引擎（`EidolonCore/Sources/EidolonCore/Eidolon.swift:4-6` 自称「the single seam the app and its tests drive」）。
- 这个 seam 不窄：`Eidolon.swift` 本体 35 个 public 成员，另外 23 个 `extension Eidolon` 文件再贡献 603 个，合计 **638**。
- App shell：`AppModel` 是 `@MainActor @Observable`（`EidolonIOS/App/AppModel.swift:15-17`），持 `let core: Eidolon`（`:1218`）、provider、设置、缓存与若干 feature 控制器；`RootView.swift:18` 创建并 `.environment(app)`。已经有 `ChatStore`（`EidolonIOS/Features/Chat/ChatStore.swift`）、`CallController`（`Features/Call/CallController.swift`）、`ServerStore` 三个像样的 store，但边界是事后长的，不是设计出来的。

### 1.2 上游：模块化单体 + 星形组装

- 148 个顶层 Python 模块、55,193 行；`app.py` + 19 个 `*_api.py` 暴露 HTTP；`assembly.py` 的 `Backend`（`assembly.py:116`，70+ 字段）是唯一组装根，所有路由模块直接 `from eidolon.assembly import Backend`。
- 回合引擎 `ConversationEngine`（`engine.py:662`，文件 1,369 行）是唯一编排点；通话 `call.py` 用 Pipecat 包在外面；外部服务靠一组 `Protocol` 端口（LLM/判分/向量化/重排/STT/TTS/身份等）。
- 依赖是**星形**不是洋葱：没有领域接口，任何模块都不可单独替换（推断：换企划只能整仓 fork）。
- 通用/专属边界主要落在数据：`characters/characters.toml`、`sheets/*.md`、`facts/*.md`、`world.json`、`corpus/`（119 MB）都是数据；但提示词里有十余处写死的企划文案：`producer.py:141`、`memory.py:788`、`titles.py:50`、`retrieval.py:605` 与 `:626`、`affinity_judge.py:47`、`emotion.py:123`、`photo_judge.py:21`、`bar_prompt.py:54-55`（「283 事务所」「《偶像大师 闪耀色彩》」「VA-283」），`today.py:17` 写死 `Asia/Tokyo`。「闪耀色彩」出现在 10 个文件里——量不大，但全在提示词里，改错会直接改变人格。
- 前端 451 个 ts/tsx，负责展示与协议；没有可复用的引擎，只有协议与视觉规范。

### 1.3 eidolon-sc-new：内核-插件三层，边界成立但契约未收敛

- 规模：`core/` 2,249 行、`plugins/` 14 个文件 4,961 行、`channels/` 11,010 行；`channels/qq.py` 单文件 3,423 行。
- 依赖方向可 grep 验证：`serve.py/channels → app.py → core/`，`core/` 只 import `core/`，不 import 上层（`docs/architecture.md:62-105`）；内核定义是「给定一段话和一个人，走完固定四阶段，把过程以事件流吐出；它不知道角色是谁，也不知道消息从哪来」（`architecture.md:239-242`）。
- 回合七步：入口校验 → `before_turn` 闸门（第一个 Veto 赢）→ 收集所有 `Question` 一次判分 → 各插件交 `Section` 组提示词 → 流式生成/解析 → 同事务落库 → `after_turn` 观察者（`architecture.md:245-300`）。
- 三种钩子：gate（`before_turn`，只读判定、不许碰提示词）、enrich（`judge_questions` + `prompt_sections`，应是纯的，只能写 `TURN`/`PROFILE` 槽）、observe（`after_turn`，回复已落库，异常被吞）（`core/plugin.py:1-16,105-115`；`core/host.py:129-179`）。
- Host 做四件事：`requires` 拓扑排序（成环启动即抛）、依赖传递性下线、每个钩子 try/except、路由重名启动报错；下线插件仍报 `capabilities`（`enabled:false + why`）（`core/host.py:58-80,89-118,191-218`）。
- 提示词四槽 persona / profile / history / turn：槽位本身就是缓存决策，插件只能写后两个，防止悄悄打碎前缀缓存（`core/prompt.py:1-17,28-108`）。
- 判分总线：内核拥有调用，插件只写 `Question`，一次请求回答所有问题；失败时 facts 为空，每个功能自行决定 fail-open/closed（`core/judge.py`；`architecture.md:410-446`）。
- 角色是数据：`characters.toml` 名册 + `packs/<id>/`（`_LAYOUT` 是路径唯一真相，`packs.py:52-76`）+ `works/units/gifts` + world 三层知识 + facts（whole/vector）+ stories 确定性匹配。
- 作者自评「拆的太碎了」（`README.md:12`）；碎的证据：14 个插件里有 91–157 行的极小插件、跨文件的隐式约定（facts 是 `dict[str, Any]`、prompt order 是散落的魔数、capabilities 形状各写各的）、`gifts.py:33` 直接 import affinity 内部常量、为一个 QQ 通道给内核加 `start/stop`、`channels/qq.py` 3,423 行没拆、README 与 architecture 已漂移。
- 它没有通话后端：`capabilities.call` 只控制提示词与按钮（`architecture.md:2030-2039`）。这反过来证明**通话栈是 iOS 端自己的资产**，不属于可复用内核。

## 2 「组件化」到底要分开什么

### 2.1 两条轴

| 轴 | 问题 | 现状 | 换企划时 |
|---|---|---|---|
| **设备能力轴** | 音频、识别、合成、LLM、判断、向量化、生图、天气 | 已解决：27 个 `public protocol` 注入，Core 零 UI/音频 import | 基本不动 |
| **企划内容轴** | 她是谁、世界是什么、说什么语言、立绘什么格式、有哪些玩法、数据从哪来 | 未解决：语言/世界/资产/玩法直接写在 Core | 主要成本 |

企划轴再拆成四个可独立处理的子问题：

1. **语言与回复契约**：`ReplyFormatInstructions.swift:9` 逐字写「无论用户用中文还是日语说话，你都只用日语回答，并给每句日语附上中文字幕」；`ReplyParser.swift` 按 `<ja>…</ja><zh>…</zh>` 解析；内容库 `episode_lines` 是 `ja TEXT NOT NULL, zh TEXT`（`ContentSchema.swift:24-31`）。换语言不是改文案，是改引擎输出契约 + 检索表结构 + oracle。
2. **世界与角色模型**：`WorldSetting` 是 `Staff / Unit.members / Idol.cv / Release / Song / LiveDay.setlist`（`WorldSetting.swift:8-58`）——一个偶像事务所模型，不是通用 lore 容器；`CharacterConfig` 的 `unit/voiceID/idolID/birthday/photoTag/photoAppearance/placeLikes/likedGifts`（`CharacterConfig.swift:6-40`）把立绘、生图、礼物三套玩法交叉写在角色条目上。
3. **表现与资产格式**：Spine 3.6 三件套 + 动画名表（`StandAnimator.swift:8-45`）、构建期从上游 checkout 拷 `spine-webgl.js`（`project.yml` 的 postBuildScripts）、酒吧 640×360 像素约定（`BarScreen.swift`）、电话质感滤波（`PhoneTexture.swift`）。
4. **玩法集合**：酒吧、朋友圈、好感/礼物/成就、照片、日程/周期/日历——它们不是「引擎能力」，是这台作品的产品功能。

### 2.2 已经成立的三条边界（不要推翻）

- **Core ⟂ UI/音频**：128 个文件只 import `Foundation`、`GRDB`、`ZIPFoundation`、`CryptoKit`、`CoreGraphics`、`UniformTypeIdentifiers`、`ImageIO`；唯二碰 CoreGraphics 的是照片解码/重编码（`PhotoRecord.swift:1`、`ImageGeneration.swift:1`）。27 个 `public protocol` 是音频、识别、合成、LLM、判断、向量化、重排、生图、天气的注入点。ADR-0015 的「通话状态机在核心、音频与语音服务注入」是对的方向。
- **内容库/用户库分离 + 整包原子替换**：内容库只读、随包替换，用户库永不替换，跨库 `ATTACH`（ADR-0002）；内容包 zip + 版本/schema 校验 + 失败保留旧包（ADR-0003）；立绘包、酒吧素材包再拆开（ADR-0020/0021）。**这是现有最好的组件边界**，也是「换企划 = 换包」唯一已经跑通的实例。
- **行为接缝已经存在**：立绘只认 `StandRenderer`（`EidolonIOS/Features/Stand/StandRenderer.swift`，ADR-0017 明说换 Metal 只改一个 adapter）；通话层由 App 外壳持有、页面之间换页不挂断（ADR-0023）；渲染器、音频、识别、合成都是可替换实现。

### 2.3 七个泄漏点（为什么还不能算「可复用」）

| # | 泄漏 | 证据 | 后果 |
|---|---|---|---|
| 1 | 提示词把语言写死 | `ReplyFormatInstructions.swift:9`；`ReplyParser.swift` 的 `case ja/zh`；`ContentSchema.swift:24-31` 的 `ja/zh` 列 | 换语言穿透引擎、检索、内容 schema、oracle |
| 2 | 立绘动画名是这套资产的字面量 | `StandAnimator.swift:8-45`（`wait / smile1 / shy1 / surp1 / sad1 / anger1 / face_wait`） | 换立绘格式要改核心动画选择逻辑 |
| 3 | `AppModel` 是唯一跨边界通道，且被反向依赖 | 42 处 `@Environment(AppModel.self)`；35 处 `app.core.*` 直调；`CallController.swift:56,70` 的 `weak var app` + `AppModel.init` 里 `call.attach(self)`（`AppModel.swift:1225`） | Feature 无法独立成组件；包边界一合上就编译失败 |
| 4 | 缺一层显式的「应用服务」 | `ChatStore` 持 `Eidolon`；`CallSetup` 在 `AppModel.swift:498-524` 里拼 provider/hot words/readings/音频/立绘导演 | 装配逻辑散落，组件化后没人负责 wiring |
| 5 | 两个 `Eidolon` 实例共享同一 SQLite | `MomentsBackground.swift:39` 后台任务另开 `Eidolon(location:)`，并自己 `ChatSettings.load()` 建 provider | actor 隔离只覆盖单实例；设置/provider 装配被复制 |
| 6 | Core 有平台偏好存储的默认参数 | `RosterTidy.swift`、`StandOutfits.swift` 用 `UserDefaults = .standard` | 内核改设备全局状态，跨平台/多包时变成隐式依赖 |
| 7 | 企划素材进了 App 二进制 | `EidolonIOS/Resources/Welcome/` 32 MB，含真实偶像编号的立绘目录（如 `stand/stand-1030010010/`） | 与「内容包可换」前提冲突；换企划要重编 App |

## 3 分类：什么跟着企划走

### 3.1 四类（按行数粗分）

| 类别 | 占比 | 证据 | 换企划时 |
|---|---:|---|---|
| **D1 企划无关内核** | ≈42% | `EidolonTurn.swift`、`Judge.swift`、`Retrieval.swift`、`Memory`、`Conversation`、`ContentBundleInstaller`、`UserSchema`、`CallSession` | 基本不改；但语言与世界两个子轴嵌在里面（§2.1） |
| **D2 企划表现与玩法** | ≈46% | 酒吧 5,616、朋友圈 2,509、照片 1,936、立绘 1,327、好感/礼物/成就 2,221、日程/周期/日历 3,214 | 整块替换或整块不装 |
| **D3 App shell** | 24,996 行 | 导航、`AppModel`、设置、钥匙串、后台任务、立绘/欢迎页适配器、具体的 Soniox/Fish/LLM/生图实现 | 大体可留，摘掉写死的角色/文案/品牌 |
| **D4 数据与工具链** | 仓外 | `tools/` 导出器、oracle、上游 `characters/` + `corpus/`、`server/` | **全部按企划重做**，这是真正的成本中心 |

### 3.2 「看起来通用、其实内置本企划假设」清单

- `WorldSetting`（偶像事务所模型）、`CharacterConfig`（立绘/生图/礼物字段交叉）。
- `HolidayTable`（日本节假日）、`TodayPrompt`（东京的今天）、`MomentsWeather`（写死东京坐标）。
- `StandAnimator` + `StandRender` 的取景比例常数（`StandRender.swift`；0.85/0.66 是某套资产的骨骼比例，被当成引擎常量）。
- `AffinityBadge` 的四段中文文案（「亲近」「现在不想说话」）在 Core 里生成。
- `BarScreen` 的 640×360 + 缩放规则、`BarText` 的字幕节奏、`PhoneTexture` 的 300/3400Hz 滤波、`Readings` 的读音表。
- `EidolonIOS/Resources/Welcome/` 的 32 MB 欢迎页素材（真实偶像编号）。

## 4 三条路线与一个顺序

### 4.1 路线对比

| 路线 | 做法 | 优点 | 代价 / 风险 |
|---|---|---|---|
| A. 多 SPM 包 | `EidolonKit`（内核）+ `EidolonPlay`（玩法）+ 单 App target | 依赖图可检查、可整体不装、跨项目直接复用 | 95 个测试文件改 import；在 App shell 未分层前切包会撞上 35 处 `app.core.*` 与 `weak app` |
| B. 包内 typed 契约 | 回合四阶段 + 3 个 protocol + 槽位 enum + 判分总线 + capabilities | 保持单包、零迁移成本，先把「哪些是玩法」写进类型 | 单 target 内可见性边界仍敞开；契约设计错了会加一层抽象 |
| C. 只做 shell + 内容契约 | AppServices 分层 + 内容包 schema 泛化 | 风险最低、直接解决换企划的数据边界 | 不解决 46% 玩法与内核同层的问题 |

**这不是三选一，是顺序。** 推荐 **C → B → A**：

1. 先做 C：`AppModel` 拆成应用服务层（否则 A 的包边界一合上就是编译墙；`weak var app` 和 35 处 `app.core.*` 是第一批报错点）。
2. 再做 B：把玩法对回合的贡献变成带类型的契约（prompt section / judge question / after-turn observer / capability），让酒吧、朋友圈、礼物等**可整块不装配**；此阶段用 oracle 逐字对照锁行为。
3. 最后做 A：只切 2 个包（`EidolonKit` + `EidolonPlay`），不是 6 个。等真的出现第二种资产格式（比如 3D）再拆 `EidolonStand`。

### 4.2 可迁移的契约（eidolon-sc-new → Swift）

| sc-new | Swift 对应（推断） | 备注 |
|---|---|---|
| 回合七步 / 四阶段 | `TurnPipeline`（before/gate → judge → build → stream → store → observe） | 阶段固定，扩展点固定，不让功能随便插流程 |
| gate / enrich / observe | 三个 protocol：`TurnGate`、`TurnEnricher`、`TurnObserver` | 静态语言里比「有方法就算插件」更清楚，也避免一个 900 行类同时演三种角色 |
| `Section(slot, text, order)` | `enum PromptSlot { persona, profile, history, turn }` + `PromptSection` | 槽位不变量编译期可表达；oracle 逐字对照天然兼容 |
| `Question(key, kind, least, most)` | typed `JudgeQuestion` / `TurnFacts` 结构体 | 不要 `dict[str, Any]` + 字符串命名空间（sc-new 碎的主要来源） |
| `capabilities()` | `Capability` + `enabled(reason)` | UI 只读能力，缺 key/缺包时自动退化 |
| `requires` + Host 拓扑 | 编译期显式组合根（`FeatureSet` 列表） | Swift 单 App 不需要运行时插件表 |
| `migrations()` | 每个 feature 自己的 GRDB migration | 内核只管用户库基础表 |
| 事件流 | `AsyncStream<TurnEvent>` | UI 与通话都只消费事件 |
| 角色包 `packs/<id>/` + `_LAYOUT` | `ContentPack` 结构 + 校验器 + `required/inherited/using_defaults` 三态 | 换企划只换包 |

**不该照搬**：Python 的动态插件发现 / `enabled` allow-list（App 实际全量装配，没有运行时开关）；`start()/stop()` 生命周期（那是为 QQ 通道加的，iOS 用系统调度）；`serve.py` 的每请求一线程 + 全局 SQLite 锁；`web_compat.py` 兼容层；为了「零依赖」把向量检索降级——iOS 已有端上 embedding（ADR-0006），不要跟着退。

### 4.3 为什么先不拆细

- ADR-0013 当时的判断是「拆成多个包（自用规模下只是互相加依赖）」（`docs/adr/0013-project-structure.md:5`）。两个前提都变了：规模（Core 36.5k 行 / 128 文件 / 638 facade 成员）与目标（跨企划复用）；而「互相加依赖」正是切包要暴露的，不是代价。
- 但 eidolon-sc-new 证明另一边也成立：**拆碎 ≠ 好维护**。它的 core 只有 2,249 行，plugins 4,961 行，channels 11,010 行——引擎可以小、玩法可以重；但碎到 14 个 91–157 行的插件后，跨文件约定反而没有检查。Swift 的正确做法是「模块可以少，契约必须收敛」。

## 5 目标形态（建议，推断）

### 5.1 组件与依赖规则

```
EidolonKit   ← EidolonPlay   ← EidolonIOS(App/Shell)
      ↑              ↑
  内容包契约      玩法与表现
```

| 组件 | 职责 | 依赖 | 是否跨企划复用 |
|---|---|---|---|
| **EidolonKit** | 回合四阶段、提示词槽位、判分总线、检索、记忆、对话/事件、用户库、`CallSession` 状态机、provider 协议、内容包读取 | 仅 GRDB/ZIPFoundation + 注入协议；不 import SwiftUI/AVFoundation | 是（内核） |
| **内容契约**（先放 Kit，必要时拆 `EidolonContent`） | `.eidolonpkg` 格式、角色/世界/剧情/提示词包/schema 校验、语言对 | Kit 内部 | 是（换包） |
| **EidolonPlay** | 酒吧、朋友圈、照片、好感/礼物/成就、日程/周期/日历、立绘指令（纯规则） | 只依赖 Kit 的契约 | 可选：整块不装 |
| **EidolonIOS / Shell** | 导航、通话层持有、设置、钥匙串、后台、具体 provider（Soniox/Fish/LLM/生图）、`StandRenderer` 适配器、欢迎页 | 依赖 Kit + Play | 模板化，摘品牌 |
| **tools/ 与数据** | 导出器、oracle、语料 | 仓外 Python | **按企划重做** |

依赖规则（可写成 grep/CI 守卫）：

1. `EidolonKit` 不 import SwiftUI/UIKit/AVFoundation/WebKit，不 import `EidolonPlay`/App。
2. `EidolonPlay` 不 import App；只通过 Kit 的 protocol 参与回合。
3. App 只做 wiring 与平台能力实现；不允许反向 `weak var app`。
4. 内容契约只能由数据管线（Python）与 Kit 共享；玩法不能直接读包内 JSON 的企划字段。

### 5.2 落点：现有 23 个 `extension` 就是切分地图

`Eidolon` 的 638 个成员不是匀质的——23 个 `extension Eidolon` 文件天然按功能分组（`Usage.swift` 94、`Moments.swift` 75、`Schedule.swift` 66、`TurnTrace.swift` 58、`Stats.swift` 48、`CallSession.swift` 48、`Achievements.swift` 48、`Gifts.swift` 43、`EidolonTurn.swift` 39、`Conversation.swift` 25……）。**切分顺序可以直接照这些文件走**：先按 extension 文件把 facade 收窄成几个子 facade（`KernelAPI` / `PlayAPI` / `CallAPI`），再决定哪个扩展落哪个包。这比从零设计模块边界便宜得多。

### 5.3 内容契约要补的东西（换企划的真正接口）

1. **语言对与回复格式**：把「日语原文 + 中文字幕」从常量变成内容包配置（语言标签、字幕策略、解析规则）；`episode_lines` 的 `ja/zh` 列随格式版本迁移（推断：格式 6+）。
2. **人格/世界观包**：除了 `sheet/facts/world.json`，补一份 `prompt pack`（「她是谁/世界是什么/怎么称呼用户/作品名」），把上游散落在 10 个文件里的企划文案收进来。
3. **角色模型可空**：`WorldSetting` 的偶像事务所字段改成可选；新企划没有 live/组合时不能要求这些类型存在。
4. **资产清单化**：立绘包 manifest 声明格式（当前隐式 Spine 3.6）+ 语义动作表（`calm/happy/shy/...`），播放器只认语义；换格式 = 换 manifest + adapter。
5. **玩法能力**：每个玩法声明 `capabilities`（脸、酒吧、朋友圈……），缺包/缺数据时 `disabled(reason)`，UI 自动隐藏入口而不是崩溃。

## 6 迁移路径（每阶段独立验收）

| 阶段 | 内容 | 成本 | 验收信号 |
|---|---|---|---|
| **0. 写下来** | 把本笔记的分类/依赖规则落成 ADR（下一步，不是本次）；加 2 条 grep 守卫草案 | 低 | 评审通过；不动代码 |
| **1. App shell 分层** | `AppServices` 组合根 + 按 feature 拆 store；设置/provider/内容导入/缓存移出 `AppModel`；一个 `Eidolon` 实例（修 `MomentsBackground`）；去掉 `weak var app` 与 35 处 `app.core.*` | 中 | 编译通过；1,155 个 core 测试不变；UI 测试 + 手动冒烟；`grep -r 'weak var app\|app\.core\.'` 归零 |
| **2. typed 玩法契约** | 抽出 `TurnGate/TurnEnricher/TurnObserver`、`PromptSlot`、typed `JudgeQuestion`、`Capability`；把好感/记忆/礼物旁白/日程/照片的提示词贡献从 `EidolonTurn` 移进各自 feature | 中高 | `tools/oracle/run.sh` 六个场景仍与上游 `identical`；`swift test` 全绿；假模型 UI 冒烟 |
| **3. 最小两包** | 把 D1 移进 `EidolonKit`、D2 移进 `EidolonPlay`；测试随模块走；App 只依赖两个包 | 中 | 同样的测试/oracle/App 冒烟；依赖图无环；Kit 无 SwiftUI/AVFoundation |
| **4. 第二企划验收** | 做一个**纯文本**的第二企划内容包 fixture（新角色名/新世界/不同语言对；不带酒吧/朋友圈/立绘），只跑回合、判断、检索、记忆 | 中 | 不改 Kit 代码即可跑通一轮对话；列出的缺口就是下一步的通用化清单 |

**为什么第 4 步是纯文本**：既有调研已经说明，换企划的最大改造点是立绘与语音索引，不是剧情库（`docs/research/idolmaster-porting-2026-10-28.md`）。先证明「内容契约 + 内核」能脱离本企划，再处理资产格式；否则会在 3D/Spine 的细节里淹掉组件化本身。

## 7 风险与不该做的事

1. **不要先抽象一切。** eidolon-sc-new 的教训是「碎」的代价；在第二个消费者出现前，语言/世界模型只做「可缺省 + 可配置」，不做「任意 lore 引擎」。
2. **不要在 App shell 分层前切包。** 35 处 `app.core.*` 与 `weak var app` 会立刻变成编译错误；先做 Phase 1。
3. **不要把语言/世界模型改动当成文案改动。** `ja/zh` 列、`<ja><zh>` 解析、oracle 都是行为契约；任何改动都要 bump 内容格式 + 重跑六场景。
4. **不要保留两个共享 SQLite 的 `Eidolon` 实例。** 组件化时顺手收敛成一个（`MomentsBackground` 的独立实例是现有隐患）。
5. **不要让 Core 继续依赖 `UserDefaults` 默认参数。** 拆包时改成显式注入的偏好存储。
6. **不要把企划素材放进 App 二进制。** 32 MB 欢迎页已经与「内容包可换」冲突，后续应走可选包/按需下载（推断）。
7. **AGPL-3.0 是衍生作品的约束。** 复用/分发时要保持 AGPL；Spine 运行时、VA-11 HALL-A 素材、偶像立绘/剧情都不进仓库（README 已有声明）。如果未来某个企划是「联网提供」，AGPL 的网络条款会生效，需要单独评估（推断）。
8. **不要为了「零依赖」牺牲检索质量。** iOS 已有端上 embedding/rerank（ADR-0006），这是优势，不要向 sc-new 的降级实现看齐。

## 8 下一步建议（调研收尾）

1. **先确认起点**：建议从 Phase 1（App shell 分层）开始，而不是从切包开始；它的风险最低、收益最直接，也是后面所有步骤的前置。
2. **写 ADR**：按仓库惯例在 `docs/adr/` 新增一篇「组件化边界」（暂定 0035；ADR-0033 已被 3D 原生迁移占用，0034 留给 3D 支线引用的 UaaL 决策，见 `docs/research/migration-template-2026-11-09.md`），把 §5 的组件/依赖规则固定下来；本笔记作为调研依据，ADR 只写决策与后果。
3. **开两个 spike ticket**：① `AppServices` 骨架 + 去掉 `weak var app`；② 第二企划纯文本内容包 fixture 的字段清单。
4. **加守卫**：Phase 1 之后在测试/脚本里加「Kit 不 import UI/Play」「Play 不 import App」的检查，防止边界回潮。
5. **不要先碰 MLTD/星耀季节资产**：先把文本层跑通，再按 `docs/research/mltd-3d-pipeline-2026-10-31.md` 的静态蒙皮路线单独推进。

## 附录 A 来源与关键证据索引

- 本仓库：`EidolonCore/Package.swift:11,18-24`、`EidolonCore/Sources/EidolonCore/Eidolon.swift:4-6`、`EidolonTurn.swift`、`ReplyFormatInstructions.swift:9`、`ContentSchema.swift:24-31`、`StandAnimator.swift:8-45`、`EidolonIOS/App/AppModel.swift:15-17,1218,1225`、`EidolonIOS/Features/Call/CallController.swift:56`、`EidolonIOS/App/MomentsBackground.swift:39`、`docs/adr/0013-project-structure.md:5`、`docs/adr/0015/0017/0021/0023`。
- 上游：`backend/src/eidolon/{producer,memory,titles,retrieval,bar_prompt,today}.py` 的写死文案；`characters/`、`corpus/` 的数据边界；`assembly.py:116` 的 70+ 字段组装根；`engine.py:662`。
- eidolon-sc-new：`README.md:12`、`docs/architecture.md:62-105,239-300,302-364,365-408,410-446,2030-2039`、`core/plugin.py`、`core/host.py`、`core/prompt.py`、`core/judge.py`、`plugins/packs.py`。
- 既有调研：`docs/research/upstream-parity-2026-10-25.md`、`docs/research/idolmaster-porting-2026-10-28.md`、`docs/research/mltd-3d-pipeline-2026-10-31.md`。

> 注：本文是调研笔记，不是实现计划；没有改代码、没有提交 git。调研草稿是本机临时文件，不留在仓库。
