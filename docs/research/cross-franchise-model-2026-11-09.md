# 多企划并存、内容迁移与跨企划场景模型（2026-11-09）

调查日期 2026-11-09。**只读整理**：没有改代码、没有提交、没有读 `.env`。本文把此前三个问题（Spine/Unity 关系、内容迁移清单与步骤、多企划「串起来」要什么接口）整理成可执行结论；事实来源是本仓库 main `8c05c7de`、3D 支线 `feat/mltd-3d-stand`，以及三篇既有笔记：

- [组件化调研](componentization-2026-11-09.md)
- [迁移模板调研](migration-template-2026-11-09.md)
- [扩展点与平台适配](extension-points-and-platforms-2026-11-09.md)

推断处标「推断」；本文不重复三篇笔记的论证，只做结论整合与新增的「多企划」部分。

## 0 结论摘要

1. **Spine 和 Unity 不是「上游 vs 我们」的两套引擎。** Spine 是 2D 骨骼动画运行时（上游与本仓库 2D 都在用同一套 spine-webgl 3.6）；Unity 是本仓库 3D 支线嵌进来的 3D 引擎（UaaL）。3D 支线是**替代 2D 立绘**，不是「用 Unity 适配 Spine」；两者共用的是 App 层 `StandRenderer` 语义接缝。
2. **迁移不只是「剧情、语音、立绘」。** 必选还有：人设/提示词资料、`cast_meta`（名册/生日/组合/CV/称呼）、世界设定、翻译、法律元数据；语音要区分「原声播放」和「TTS 音色」两条互斥路线；3D 模型、BGM、玩法数据按产品取舍。最容易漏的是**人设**和**翻译**。
3. **「一个 App 装多个企划」的前置不是 crossover，而是多内容包并存。** 现在只有一个 `Content/current`，安装新内容包是原子替换；第二个企划会顶掉第一个。必须先做 per-franchise 内容目录 + registry，再谈跨企划同场。
4. **跨企划「串起来」不需要新引擎。** 路线 A（场景编排复用现有 1:1 回合引擎 + 纯函数 `SpeakerPolicy`）先做；路线 B（多角色 ensemble 引擎）留后手，等 A 的 fixture 证明「轮转生硬且它是核心体验」再评估。
5. **P0 现在做便宜、以后做贵**：复合身份（`FranchiseID` / `CharacterKey`）+ 会话参与者（`ParticipantSet` / `messages.speaker`）+ 多内容包。**五张把 `character_id` 写进主键/唯一键的表必须重建**，否则两个企划的同名 local id 会合并成一行、事后无法拆。
6. **P1 才需要 Universe/Scene 包、SpeakerPolicy、记忆作用域；P2 多角色同屏先「叠 N 个现有渲染器」**。3D 同屏受 Unity UaaL 单实例/全屏/不可重入限制，跨企划 3D 同场现实中不可行（推断）。
7. **ADR 编号**：0034 = UaaL、0035 = 组件化边界、0036 = 多企划命名空间与参与者（P0）、0037 = Scene/Universe 与 SpeakerPolicy（P1）、0038 = 多角色渲染（P2，暂缓）。

## 1 概念澄清：Spine 与 Unity 是什么关系

|  | 上游 | 本仓库 2D（默认） | 本仓库 3D 支线 |
|---|---|---|---|
| 运行时 | 浏览器 + vendored **spine-webgl 3.6** | WKWebView + 同一份 **spine-webgl 3.6** | **Unity 6（UaaL）** |
| 资产 | Spine 3.6 三件套（`data.json/.atlas/.png`） | 同一套 | MLTD 的 UnityFS bundle + 自写 C# 原生移植 |
| 接缝 | 上游 `StandEngine` | `EidolonIOS/Features/Stand/StandRenderer.swift:10-27`（`StandWebRenderer`） | 同一个 `StandRenderer`（`UnityStandRenderer.swift:16`） |
| 关系 | — | 与上游同一套 2D | **替代 2D，不是适配 Spine** |

- **Spine 不是「引擎」**，是 2D 骨骼动画运行时/播放器；上游只用了 Spine，没有 Unity。我们的 2D 是照上游的 spine-webgl 3.6 搬进 WKWebView。
- **3D 支线用 Unity 直接渲染 MLTD 的 3D 模型/动作/表情**，和 Spine 立绘是替代关系。两者共用的只有 `StandRenderer` 协议。
- 现有技术债恰恰是：3D 要反过来适配「Spine 形状」的接口——`StandPose.Report` 是「动画名→时长」，Unity 只能伪造整张 Spine 动画名表（`UnityStandRenderer.swift:226-244`）。所以准确说法是：**两个渲染运行时共用同一个语义接缝**，不是「Unity 适配 Spine」。

对应到未来目标：CGSS/学マス 与 MLTD 共用 **Unity 宿主外壳**；galgame 走 **2D 立绘/VN 运行时**；星耀季节只留负向 `RuntimeID.unreal`（UE 无官方嵌入路径，详见扩展点笔记 §4）。

## 2 内容迁移：到底迁什么

### 2.1 清单

| 迁移项 | 说明 | 必选性 |
|---|---|---|
| **人设/提示词资料** | 人设 sheet、口癖、称呼规则、关系、facts；没有它角色只会「像通用 AI」 | **必须**（比剧情更影响体验） |
| **角色元数据 `cast_meta`** | id、显示名/假名/罗马音、CV、生日、组合/班级、印象色、音色、头像 | **必须** |
| **世界/作品设定** | 组合、歌曲、live、日历、世界观；影响「她知道自己是谁」 | 建议 |
| **剧情 + 翻译** | 上游是 `episodes(ja, zh)` 线性表；别的作品很多没有官方中文（学マス/CGSS 商店语言仅 JA）；翻译是额外一大块 | **必须** |
| **语音** | 两条互斥路线：①原声播放（需解码 + cue/字幕对齐）；②TTS 音色（不能用原声数据训练/分发） | 视产品路线 |
| **2D 立绘/卡面/背景/CG** | 形态可能是 PNG 差分、Spine、Live2D；不是拷文件就行 | **必须**（2D 路线） |
| **3D 模型/动作/表情** | MLTD 这类 3D Live；引擎相关，最贵 | 可选/单独立项 |
| **BGM/音效** | 酒吧、电话质感、界面音 | 视玩法 |
| **玩法数据** | 礼物、酒吧、日程、朋友圈；只迁你要复刻的 | 可选 |
| **UI/品牌文案** | 欢迎页、tab、颜色、入口文案 | 小但显眼 |
| **术语/读音表** | 专有名词读音、翻译对照 | 建议 |
| **法律/来源元数据** | 来源说明、EULA/规约链接、生成时间；素材不进仓库、不分发 | **必须** |

### 2.2 四目标差异

| 目标 | 剧情/语音/2D | 3D | 额外大头 |
|---|---|---|---|
| **学マス** | ADV 脚本 + AWB 语音 + 卡面 PNG（社区容器事实） | Unity 2022.3 + URP；3D Live 不建议进模板 | protobuf master DB 解析、无官方中文 → 翻译 |
| **CGSS** | `.unity3d` + ACB/HCA + bdb/mdb；卡面/コミュ | Unity 3D Live | 内容已冻结，档案工作要尽早 |
| **星耀季节** | 剧情/语音在 UE 包里（落点未知） | UE4.24 + Toon 渲染，**明确负向用例** | 法律最严；3D 管线必须单独立项 |
| **galgame** | 脚本 → **中性 VN IR**；PNG 差分立绘/CG + 语音 + BGM | 无 | 每引擎一个脚本适配器；Ren'Py 不能嵌，只能编译成 IR |

（各目标的官方/社区证据见迁移模板笔记 §3。）

### 2.3 三个容易漏的点

1. **人设/提示词**：剧情是「回忆素材」，人设才是「她是谁」；`characters/sheets/*.md` + `facts/*.md` 要重写/适配，不能只搬剧情。
2. **翻译**：上游 Shiny Colors 有社区中文翻译；学マス/CGSS 没有官方中文。要么机翻 + 校对，要么只跑原文 + 界面翻译。翻译质量直接决定聊天体验。
3. **ID 映射与语音 cue**：角色/服装/卡/语音/剧情 id 在源作品里各有一套；`voice_set` 需要「语音 id → 文件 → 文本」的对齐，不是拿到音频就完事。

## 3 迁移流水线（Mac 生产 → 设备导入）

| 阶段 | 在哪 | 做什么 | 输出 |
|---|---|---|---|
| 0 法律与快照 | Mac | 用户自有副本、版本锁定、sha256；不绕过 DRM、不分布 | 快照记录 |
| 1 清点/ID 映射 | Mac | 角色/服装/卡/语音/剧情 id → 统一 `CharacterKey` | 映射表 |
| 2 元数据/人设 | Mac | 名册 + 人设 + 关系 + 世界设定 | `cast_meta` + prompt pack |
| 3 剧情 | Mac | 按作品容器/DB 解码 → 场景/说话人/文本 → 翻译（如需）→ 切段 + embedding | `adv_script` + 检索索引 |
| 4 语音 | Mac | ACB/HCA/AWB 等解码 → Opus/AAC → 语音 id/场景/行对齐（或改走 TTS） | `voice_set` |
| 5 2D 视觉 | Mac | 卡面/立绘/背景/CG → PNG/WebP + 差分/图集元数据 | `card_art` |
| 6 3D（可选） | Mac | 模型/动作/表情 → 选定 runtime → 内容包 | `model3d` |
| 7 玩法数据（可选） | Mac | 礼物/酒吧/日程等，只迁要复刻的 | 对应 kind |
| 8 打包 | Mac | `.eidolonpkg`（manifest + 逐文件 CRC + kind/runtime/capabilities/legal） | 内容包 |
| 9 导入/验收 | 设备 | 原子安装、2D 默认、3D 可选、失败回退、oracle/视觉/UI 测试 | 可运行 |

验收沿用迁移模板笔记 §4：旧包可读、失败保留旧包、`engine_version` 不匹配拒装、单角色 oracle 六场景保持 `identical`。

## 4 「一个 App 装多个企划」的前置：多内容包

这一条经常被跳过，但它比 crossover 更基础。

**现状（单内容包）**：

- `Eidolon.Location.contentDirectory = Content/current`（`EidolonCore/Sources/EidolonCore/Eidolon.swift:19-25`）。
- `install(bundleAt:)` 安装一个新内容包后写单条 `app_state['content.bundle']`，清空缓存的 world（`Eidolon.swift:92-121`）。
- `ContentBundleInstaller.currentDirectory` 固定 `current`，`swapIn` 原子替换（`ContentBundleInstaller.swift:11,16`）。
- `ContentBundleInfo` 是单份（`ContentManifest.swift:49-62`），只有一个 embedding model/dim、一个世界。

**所以第二个企划包会顶掉第一个。** 要「一个 App 适配多个企划」，先改：

1. **目录**：`Content/<franchise>/current`；安装按 franchise 分目录，互不替换；旧 `current/` 迁移为 `shiny/current`。
2. **注册表**：`ContentRegistry` 持 `[FranchiseID: ContentDatabase]`；`Eidolon` 的 `content` 从单值变成注册表；`characters()` 跨包返回并带 `CharacterKey`。
3. **manifest**：`ContentManifest` 加 `franchise`（`decodeIfPresent`，旧包读作 `shiny`）；`ContentBundleInfo` 加 franchise。
4. **检索**：每个包一个 `ContentDatabase`；跨包检索按 candidate 合并。**要求所有包的 embedding model/dim 一致**（`ContentBundleInfo.embeddingModel/dimensions`），否则要么每包一个 embedder，要么拒装。跨企划场景检索可限定 participants 所属包。
5. **素材包**：`stand`/`bar`/未来的 `model3d` 按 franchise 分目录；包内路径保持相对，不加全局前缀。
6. **用户库**：仍全局一份；角色键改为复合（§5.2）。

这是「独立企划聊天」的前提，也是 crossover 的前提；它不属于渲染协议，属于**内容注册与身份层**。

## 5 跨企划「串起来」：现状假设与 P0/P1/P2

### 5.1 现状：1 企划 = 1 世界 = N 角色，每角色一条 1:1 对话

| 层 | 现状 | 证据 |
|---|---|---|
| 会话 | `conversations.character_id` 单值；当前会话按角色一条 | `UserSchema.swift:13-19`、`:288-301` |
| 消息 | `role` 只有 user/character，没有「谁说的」 | `UserSchema.swift:23-35` |
| 记忆 | `memories.source_character_id` 有来源，但召回全局、按文本去重 | `UserSchema.swift:56-63`；`Memory.swift:160-181` |
| 好感 | `affinities` 主键就是 `character_id` | `UserSchema.swift:79-83` |
| 当前会话/周期/成就 | `current_conversations` / `cycle_seeds` / `achievement_progress` / `achievement_stages` 都把 `character_id` 写进主键 | `UserSchema.swift:288-292,252-255,332-345` |
| 通话 | `CallSession` / `CallController` 单角色 | `CallSession.swift`、`CallController.swift:9-17` |
| 渲染 | `StandRenderer` 每表面一个 view、单角色 | `StandRenderer.swift:10-27` |
| 内容包 | 单 `current/`、单 `world.json` | `ContentBundleInstaller.swift:11`；`Eidolon.swift:19-25,92-121` |
| 角色 id | `CharacterConfig.id` 是包内 local 字符串；`idolID` 是 Int | `CharacterConfig.swift:7,21` |
| 检索 | 事实向量 scope 是 `fact:<characterID>` 字符串 | `Retrieval.swift` |

**已经是多角色的四处**：① `episode_cast`（`ContentSchema.swift:18-23`）；② `episode_lines.speaker`（`:24-31`，文本字段）；③ 朋友圈 reaction 有 `character_id`（`MomentsView.swift:176-188`）；④ 群像图参与者数组（`MomentsImages.swift`，按 `id || name` 匹配——跨企划同名会错配）。

结论：**内容侧有「多角色」的词，用户侧没有；跨企划的成本主要在身份命名空间与消息归属，不在提示词。**

### 5.2 P0：复合身份 + 会话参与者（现在做）

**类型（Core 新增 `Identity.swift`）**：

```swift
public struct FranchiseID: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: String
    public static let shinyColors = FranchiseID("shiny")
    public static let mltd = FranchiseID("mltd")
    public static let cgss = FranchiseID("cgss")
    public static let gakumas = FranchiseID("gakumas")
    public static let galgame = FranchiseID("galgame")   // 引擎族，具体作品再分
}
public struct CharacterKey: Codable, Sendable, Hashable, CustomStringConvertible {
    public var franchise: FranchiseID
    public var localID: String          // = 现有 CharacterConfig.id，不动内容格式
    public var description: String { "\(franchise.rawValue):\(localID)" }
    public init(_ text: String) throws  // 解析 "shiny:mano"；无冒号按 shiny 读（旧数据）
}
```

`CharacterConfig` 不加 `id` 前缀（`id` 已被 638 个 facade 成员和全部 DB 行使用）；加载时由包上下文给出 `franchise`，key 在边界处组合。

**存储**：主键/唯一键表用「两列 + 复合主键」（SQLite 不能 `ALTER PK`，要建新表迁移）；自由文本列（`fact_vectors.scope`、日志）用字符串前缀。**必须重建 PK 的恰好五张表（`character_id` 在 PK 里）**：`affinities`、`current_conversations`、`cycle_seeds`、`achievement_progress`、`achievement_stages`。其余表只加 `franchise_id DEFAULT 'shiny'`。

建议的 `UserSchema` v24（`UserSchema.version = 23`，`UserSchema.swift:7`）：

```sql
ALTER TABLE conversations ADD COLUMN franchise_id TEXT NOT NULL DEFAULT 'shiny';
ALTER TABLE conversations ADD COLUMN scene_id TEXT;          -- P1 用，可空
ALTER TABLE messages ADD COLUMN speaker_franchise TEXT;      -- NULL = producer / 旧行
ALTER TABLE messages ADD COLUMN speaker_character TEXT;
CREATE TABLE conversation_participants (
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  franchise_id TEXT NOT NULL, character_id TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'speaker', joined_at TEXT NOT NULL,
  PRIMARY KEY (conversation_id, franchise_id, character_id)
);
-- 五张 PK 表：建新表 → INSERT ... SELECT 'shiny', ... → 改名；其余表加列默认 'shiny'
```

回填：旧行一律 `shiny`；`messages.role='character'` 的 speaker 取所在会话的 `character_id`。

**会话参与者**：

```swift
public enum ParticipantRole: String, Codable, Sendable { case speaker, listener, narrator }
public struct Participant: Codable, Sendable, Hashable, Identifiable {
    public var key: CharacterKey
    public var role: ParticipantRole
    public var id: String { key.description }
}
public struct ParticipantSet: Codable, Sendable, Hashable {
    public var all: [Participant]
    public var primary: CharacterKey?        // 1:1 语义：历史列表/当前对话按她分组
    public var speakers: [CharacterKey]
    public func contains(_ key: CharacterKey) -> Bool
    public static func solo(_ key: CharacterKey) -> ParticipantSet
}
```

`sendTurn` 只加默认参数，`nil = solo`，行为与今天逐字节一致（`EidolonTurn.swift:118-143`）；`ChatMessageRecord` 加 `speaker: CharacterKey?`（nil = producer，旧行按会话主角色读）。`conversations.character_id` 保留为「owner/primary」，不删——`current_conversations`、历史列表、朋友圈都依赖它。

成本：v24 迁移约 80 行 SQL + 回填测试；Core 类型约 120 行；受影响查询约 15 处。**现在做小，等第二个企划落地再做要拆已合并的行，不可逆。**

### 5.3 P1：Universe/Scene 与 SpeakerPolicy

```swift
public struct UniverseManifest: Codable, Sendable {
    public var id: String; public var formatVersion: Int
    public var franchises: [FranchiseRef]      // 引用本机已装的 franchise 包（不复制素材）
    public var relations: [Relation]           // 人物关系数据化
    public var timeline: Timeline              // epoch + dayZone + 每企划 asOf
    public var language: LanguageRules         // 回复语言/字幕/称呼
    public var rules: SceneRules               // 禁止提企划名、边界、成人分级取最小
    public var legal: LegalNotice
}
public struct ScenePlan: Codable, Sendable, Hashable, Identifiable {
    public var id: String; public var universeID: String
    public var participants: ParticipantSet
    public var location: String?; public var beat: String?; public var maxTurns: Int
}
public protocol SpeakerPolicy: Sendable {
    func nextSpeaker(in scene: ScenePlan, turn: Int, last: CharacterKey?) -> CharacterKey?
}
public struct ScenePlanner: Sendable {           // 纯函数，Core，可单测
    public func plan(scene: ScenePlan, turn: Int, last: CharacterKey?) -> PlannedTurn
}
public enum ScenePrompt {                        // 场景 section，插在 nowSection 前
    public static func section(_ scene: ScenePlan, universe: UniverseManifest,
                               speaker: CharacterKey) -> String
}
```

- **命名冲突**：`ReplyBlock.scene` 已占「scene」词（`ReplyParser.swift:24-29`）→ 用 `ScenePlan`；`StandDirector` 是姿势导演（`StandDirector.swift:65`）→ 本层叫 `ScenePlanner`。
- **作用域**：`memories` 加 `franchise_id` + `scope`（`character`/`universe`，默认 `universe`）；好感维持逐角色（P0 已复合键）；**角色之间的关系矩阵**先用 Universe 的静态 `relations`，不要混用现有 `affinity`（A 对 B 与 A 对制作人是两回事）。
- **内容包**：新 kind `universe`，`requires` 引用已装 franchise 包；不复制素材。

### 5.4 P2：多角色同屏

```swift
@MainActor public protocol StageRenderer: AnyObject {
    var view: UIView { get }
    var slots: Int { get }
    func prepare(_ cast: [StageSlot]) async throws
    func place(_ key: CharacterKey, slot: Int)
    func present(_ frames: [CharacterKey: PresentationFrame])
    func snapshot() async -> UIImage?
}
```

关键事实：Unity UaaL 单实例、全屏、退出后不可重载（扩展点笔记 §4.1）→ 「一次跑两个企划的 Unity 角色同屏」现实中不可行（推断：还要两个不同 Unity 工程/版本）。同一企划内多角色同屏也要改 Unity 场景/机位，不是 Swift 侧能解决。

**所以 P2 第一步不是新引擎，而是组合现有 `CharacterRenderer`**：`StageView` 用 ZStack 叠 N 个渲染器（2D 立绘天然支持；3D 只能 1 个 + 其余 2D/头像）。注意 Unity 的 `pause` 是全进程，组合器要仲裁，不能一个角色暂停把其他也暂停。

### 5.5 路线 A vs 路线 B

| 维度 | A：场景编排复用 1:1 引擎 | B：多角色 ensemble 引擎 |
|---|---|---|
| 改动面 | 新增 `ScenePlanner` + `participants`/`speaker` 参数；prompt 加场景 section | 重写 `PromptAssembler`（多 persona）、`ReplyParser`（`<line from>`）、好感归属、立绘/语音逐句路由 |
| 每次回复 | 一次一个角色（N 次模型调用） | 一次生成多角色接话 |
| 自然度 | 靠轮转策略，接话可能生硬 | 上限高，可真正互相接梗 |
| 可测性 | 纯函数 + 现有测试 + oracle 可对照 | 无法与上游 oracle 对照；需新 golden |
| 现有先例 | 与朋友圈「其他偶像反应」同构 | 无 |
| 成本（推断） | 低，周级 | 高，月级且高风险 |

**A 先做，B 留后手。**

### 5.6 最小双角色纯文本 fixture

数据（测试夹具，不进仓库）：

1. `shiny` 包：1 角色（可复用 `mano`，纯文本）；
2. `mltd` 包：1 角色（只造 `characters.json` + sheet/facts + 空剧情库；`voiceID`/`stand` 可空）；
3. `universe` 包：`franchises: [shiny, mltd]`、一条 relation、timeline/language/rules/legal。

验收：

- `CharacterKey` 往返、`UniverseManifest` 解码/校验（引用未安装 → 可读错误）、`SpeakerPolicy` 确定性、`ScenePrompt` 含两名参与者、`memories` scope 过滤；
- fake provider 跑 4 轮（A→B→A→B）：每轮 `speaker` 正确、消息 speaker 落库、transcript 显示两个名字、好感只动当前说话人；
- 单角色场景（`participants: nil`）与今天逐字节一致；
- v23 fixture 库升级 v24 后回填正确，`current_conversations` 行为不变；
- `tools/oracle/run.sh` 六场景仍 `identical`，`swift test --package-path EidolonCore` 全绿。

### 5.7 法律/设定风险

1. **人设与世界观冲突**：不同作品的事务所/时间线/称呼不同（`WorldSetting` 单 world；`ReplyFormatInstructions.swift:9` 写死语言对）。Universe 的 `rules` 要明确「不提对方作品名/不串梗」。
2. **同名与关系数据化**：朋友圈群像图按 `id || name` 匹配，跨企划同名会错配 → 必须用 `CharacterKey`；「人物关系」目前是非结构化文本，Universe 的 `relations` 是把它数据化的机会。
3. **时间线/日历**：各企划 asOf、时区、生日/节日不同；Universe 必须定义统一 epoch 与逐企划 asOf，否则「今天是她的生日」会跨企划错乱。
4. **素材混用**：跨企划同图/同台是双重衍生作品；**默认只做文本 crossover**，图/3D 混用另做许可评估。
5. **分发**：Universe 包只引用本机内容包、不复制素材；`legal` 必填；AGPL 约束代码不约束素材（组件化笔记 §7.7）。
6. **分级**：成人模式按角色 `age`（`CharacterConfig.swift:148`）；crossover 取所有参与者的最严格值（推断，需产品确认）。

## 6 分阶段路线图

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P0 单企划健康** | 三篇笔记里的 main P0：干净 checkout 可构建、3D 可选、ADR-0034/0035、iPad 最小提交 | 无 3D 产物可构建；2D/通话/酒吧回归；iPad 布局 |
| **P1 多包并存** | `Content/<franchise>/current` + `ContentRegistry` + manifest `franchise` + 复合身份 + 会话参与者 | 两个企划包可同时安装；旧库 v24 迁移；单角色 golden 不变 |
| **P2 文本 crossover** | Universe 包 + `ScenePlan`/`SpeakerPolicy`/`ScenePlanner`/`ScenePrompt` + 4 轮 fixture | 双角色文本同场；好感/记忆归属正确；oracle 不变 |
| **P3 多角色同屏（可选）** | ZStack 叠 N 个 `CharacterRenderer`；2D 立绘优先 | 两个 2D 立绘同屏；暂停/恢复不互伤 |
| **P4 3D 同台** | 暂不规划 | 受 Unity 单实例/全屏/不可重入限制；如未来做，只能独立场景/独立进程 |

## 7 与三篇笔记的关系

- 组件化笔记定义「内核/玩法/内容/App shell」边界；本文的复合身份与多包注册表属于**内容契约 + 内核**，Scene/Universe 属于**内容契约 + App**。
- 迁移模板笔记定义「Mac 侧适配器 + 输出 kind + 法律门」；本文补上「人设/翻译/语音 cue/ID 映射」这几个容易被漏的迁移项。
- 扩展点笔记定义 `PresentationRuntime`/`CharacterRenderer`/`RuntimeRegistry`；本文的 `StageRenderer` 是它之上的「场景组合器」，不是同一层。

## 8 下一步（不实施）

1. 评审 §5.2 的类型与迁移范围，确认「P0 重建哪五张 PK 表」；开 spike：`Identity.swift` + v24 迁移 + 回填测试。
2. 评审 §4 的多内容包目录/registry；这是第二个企划落地的前置，不是可选项。
3. P1 只做路线 A 的 `ScenePlan`/`SpeakerPolicy`/`ScenePrompt` + 4 轮 fixture；不碰 ensemble 引擎。
4. 明确「文本 cross 得、素材混用不得」的默认边界，写进 ADR-0037 的后果。
5. 3D/UE crossover 明确不做；P2 只做 2D 图层叠加。
6. 先做单企划迁移（MLTD 适配器 + 一个第二企划纯文本包），再谈双角色同场——否则会在场景模型上过早抽象。

## 附录 A 来源与证据索引

- 本仓库代码：`EidolonCore/Sources/EidolonCore/{UserSchema,Conversation,Memory,Affinity,Gifts,ContentSchema,ContentManifest,ContentBundleInstaller,Eidolon,EidolonTurn,CharacterConfig,StandRender,ReplyParser,StandDirector}.swift`；`EidolonIOS/Features/{Chat/ChatStore,Call/CallController,Stand/StandRenderer,Stand/UnityStandRenderer,Moments/MomentsView}.swift`。
- 关键行：`UserSchema.swift:7,13-19,23-35,56-63,71-77,79-83,252-255,288-301,332-345`；`ContentSchema.swift:18-31`；`ContentBundleInstaller.swift:11,16`；`Eidolon.swift:19-25,92-121`；`EidolonTurn.swift:118-143`；`ReplyParser.swift:24-29`；`StandDirector.swift:65`；`CharacterConfig.swift:7,15,21,30,148`；`StandRenderer.swift:10-27`；`UnityStandRenderer.swift:16,226-244`。
- 三篇笔记：[组件化](componentization-2026-11-09.md)、[迁移模板](migration-template-2026-11-09.md)、[扩展点与平台](extension-points-and-platforms-2026-11-09.md)。
- 运行时官方来源沿用前两篇：Unity UaaL <https://docs.unity3d.com/2022.3/Documentation/Manual/UnityasaLibrary.html>；UE as a Library <https://dev.epicgames.com/documentation/en-us/unreal-engine/building-unreal-engine-as-a-library?application_version=4.27>；Live2D 平台 <https://docs.live2d.com/en/cubism-sdk-manual/platform/>；Spine <https://esotericsoftware.com/spine-ios>；Ren'Py iOS <https://www.renpy.org/doc/html/ios.html>。

> 注：本文是整理性调研笔记，不是实现计划；没有改代码、没有提交、没有读 `.env`。ADR 编号建议见 §0 第 7 条。
