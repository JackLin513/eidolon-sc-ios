# S3 就绪度调研：多内容包 / 复合身份 / MLTD 小样本（2026-11-14）

> 只读调研。分支 `feat/componentization`，HEAD `e2ebf3be`。除本文件外未改动任何代码、配置或 issue。
> 结论以仓库代码与 `JackLin513/eidolon-sc-ios` issue 为准；文档与代码冲突时以代码为准并单独标注。

## 0. 结论摘要

1. **S3 的「骨架」已完成，「数据层」几乎没开始。** Phase A（多根 `Content/<franchise>/current`、kind 路由、`CharacterKey` 进 manifest、设置页切包）已于 2026-11-11 提交（`b3fe38d3` + `dbdca70b`），并被 `ContentRegistryTests` 的双包切换用例覆盖；Phase B（复合用户身份、跨包隔离、删除恢复、检索作用域）至今没有设计文档、没有迁移、没有测试（ADR-0036:21 要求「必须进入 Phase B」，而 Phase B 的 ADR-0037 在 `docs/adr/` 中不存在）。
2. **S3 的核心风险点一个都没被验证：同 local id 的用户数据不串。** 用户库仍是单库 `User/eidolon.sqlite`（`Eidolon.swift:17`），`affinities`、`current_conversations`、`cycle_seeds`、`achievement_progress`、`achievement_stages` 五张表的键仍是裸 `character_id`（`UserSchema.swift:79-80, 252-253, 288-289, 332-342`），会话查询也是裸 id（`Conversation.swift:237, 276`）。值得注意：`ContentRegistryTests.twoFranchisesSwitch` 的两个 fixture 包其实用了**相同**的 local id（`Fixture.swift:90, 125` 固定 `mano`/`hiori`），证明内容库按 franchise 分库、角色不互相覆盖；但该测试没有创建任何用户数据，因此证明不了用户库隔离。真机 SC+Sakura 验证则是 local id 不重叠的「安全路径」（ADR-0036:26）。两条路径都没有覆盖「同 id 用户数据隔离」。
3. **v24 迁移编号已被占用，S3 spec 需要改号。** `UserSchema.version = 24`（`UserSchema.swift:7`）的内容是 `turn_debug_snapshots`（`UserSchema.swift:549-560`、ADR-0039），与 #135 里写的「v24 复合身份迁移」冲突；Phase B 实际必须做 v25，且迁移前要先补 ADR。这是文档债，也是排期风险。
4. **身份边界没进运行时。** `CharacterKey` 只出现在安装元数据（`ContentManifest.swift:84-85` 的 `characterKeys`）和一个测试里（`ContentRegistry.swift:5-15`），`Eidolon` 的公开 API 仍全部接收裸 `String`（`EidolonTurn.swift:118-120`、`Conversation.swift:237`），运行时角色模型 `CharacterConfig.id` 是裸 local id（`CharacterConfig.swift:6-7`）。因此 UI 和用户库都无法表达「shiny:sakura 与 mltd:sakura 是两个角色」。
5. **包管理只有「导入/切换」，没有「删除」。** 全仓 grep 无 `removeContent`/`uninstall` 之类 API；设置页内容包区只列包 + 切换（`SettingsView.swift:471-497`），导入按钮是「重新导入内容包」（`SettingsView.swift:529`）。#135 的 user story 15/16（删除包保留用户数据）完全没有落地代码。
6. **galgame 适配让「加第二个包」变便宜了，但没让「多包可用」变近。** 真正被 v5/totsulover 打通的是：内容包自带的企划身份（`FranchisePrompt` + `characters/franchise.json`，ADR-0040）、按企划归属的立绘目录（ADR-0038）、`contentSetID` 绑定与跨包 embedding 一致性拒装（`ContentRegistry+Eidolon.swift:41-47`）、真机 39 MB 内容包与 14 个静态立绘 base 的导入/渲染路径。这些都没有压到「同 id 冲突 / 用户数据隔离 / 删包恢复」这条 S3 关键路径；ADR-0040 自己也写明「只处理提示词与显示层，不改裸 id 语义」。
7. **粗估 S3 剩余约 60%。** 按 #132 的验收总门槛（两个企划包可同时安装；旧库回填正确；单角色 golden 不变；第二个纯文本内容包能 1:1 聊天），当前只稳定满足第 1 条，第 4 条只有合成 Sakura fixture 层面的满足；第 2、3 条完全未做。最短路径是「ADR → v25 迁移 → 同 id 隔离测试 → 删包/恢复 → 检索作用域 → 最后再做 MLTD 小样本」，而不是先做 3D 或 MLTD 内容。

## 1. S3 的目标与验收口径

### 1.1 范围（#135 / #132）

#132 定义的 S3 是「一个 App 能装多个企划，复合 `CharacterKey` + v24 迁移；用 MLTD 春香小样本（日文 1–2 段剧情 + 3D，无语音）做手工验收」。拆到 #135 后分两段（#135 2026-11-11 修订评论）：

- **Phase A**（两天骨架，已落）：registry 多根、installer kind 分流、`CharacterKey` 进清单与查询边界、`FranchiseID` 按作品、设置页切换、运行时 webgl-three 预留；明确「不承诺跨包用户数据已隔离」。
- **Phase B**（未开始）：复合身份 v24（现应为 v25）迁移、跨包隔离、删除/恢复、检索作用域。

依赖与边界：#132 规定 S3 依赖 S1 的运行时/内容契约，S4（#136）依赖 S3 的复合身份与 `conversation_participants`；S3 不做 S4 的 Universe/Scene 类型。#143（Gakumas）、#140（macOS）、#146（Duo）不阻塞 S3。

### 1.2 验收口径（三处来源取交集）

`docs/roadmap.md:29`（M3 多企划并存）：

1. 两个企划包可同时安装；
2. 旧库回填正确；
3. 单角色 golden 不变；
4. 第二个纯文本内容包能 1:1 聊天。

#135「测试要求」补充：v23 fixture 跑迁移后断言回填 `shiny`、五表不丢、单角色 golden 不变；两个合成 fixture 包（不同 franchise、**故意同 local id**）同时安装并切换；删除/重导入恢复；MLTD 手工验收（mltd content + model3d 与 Shiny 并存、春香 1:1 命中 1–2 段日文、3D 显示、无语音不报错）。

#132「测试决策」：S3 最终集成验收 = 双包并存/迁移；真实设备人工验收由用户完成，证据放 issue 评论。

### 1.3 spec 要求 vs 当前实现（差异表）

| #135 / #132 要求 | 当前实现 | 状态 |
| --- | --- | --- |
| `Content/<franchise>/current`，旧 `current/` 迁移为 `shiny/current` | `ContentRegistry+Eidolon.swift:97-117, 126-147` | 已实现 |
| 各 franchise 独立 content DB | 每包目录各自 `content/eidolon.db`，切 symlink 重开（同上） | 已实现 |
| 多包 embedding model/dim 必须一致，不一致拒装 | `ContentRegistry+Eidolon.swift:41-47` | 已实现 |
| `CharacterKey` 进入查询/写入边界 | 仅 manifest 元数据 + `ContentRegistry.swift:5-15`；运行时 API 与用户库仍裸 id | **未实现** |
| `FranchiseID` 类型 | 无该类型，只有字符串 + `normalizedFranchise`（`ContentRegistry+Eidolon.swift:25, 81…`） | **未实现（以字符串近似）** |
| 用户库复合身份迁移（五表重建、回填 shiny、备份、单向） | 无；v24 被调试快照占用 | **未实现** |
| `conversation_participants` + `messages.speaker_*` | 无（ADR-0036:19 明确 Phase A 不新增） | **未实现** |
| 删除包：只隐藏角色，用户数据保留为孤立数据 | 无删除 API/UI | **未实现** |
| 检索只在当前 content DB | content DB 随 symlink 切换，天然如此 | 已满足（但无跨包合并需求测试） |
| 记忆全局但带 source franchise 标签 | 记忆全局，但只有 `source_character_id`，无 franchise（`Memory.swift:8-9`） | **部分/未实现** |
| 主界面只显示当前 franchise 角色 | `characters()` 读 active 包 `characters.json`（`Eidolon.swift:472-480`） | 已实现 |
| 设置页：列表/导入/删除/设为当前 | 列表 + 切换 + 重新导入；无删除（`SettingsView.swift:471-497, 529`） | **部分** |
| MLTD 春香内容包 + model3d 独立包 | build 无 mltd 内容包；#142 无评论、未开工；现有 3D 测试包是旧 `001har` 多角色包 | **未开始** |

## 2. 已完成（带证据）

### 2.1 Phase A 骨架

- **多根 registry**：`Content/<franchise>/current` 布局；`initialize` 时把旧 `Content/current` 目录搬成 `Content/shiny/current`（`ContentRegistry+Eidolon.swift:126-147`）；`activateContent` 只重指相对 symlink、写 `content.activeFranchise`、重开 content DB、重装 `FranchisePrompt`（`:97-117`）。
- **kind 路由**：`installContent` 显式 `guard kind == .content`（`ContentRegistry+Eidolon.swift:26-28`）；stand/bar/model3d/static-stand 各有独立 installer（`Eidolon.swift:113, 229, 363`；`Model3DInstaller.swift`、`StandBundleInstaller.swift`、`StaticStandBundleInstaller.swift`）。
- **manifest v5 字段**：`formatVersion = 5`（`ContentManifest.swift:9`）；`Characters.ids` + 可选 `characterKeys`（`:16-33`）；`kind`/`franchise`/`engineFamily`/`contentSetID`；`ContentBundleInfo` 持久化 `franchise`/`kind`/`characterKeys`/`contentSetID`（`:69-90`）。
- **安装校验**：多包时要求 `characterKeys` 数量与 `ids` 一致、local id 集合相等（`ContentRegistry+Eidolon.swift:67-92`）；跨包 embedding 不一致拒装（`:41-47`）；导入失败保留旧包（`ContentBundleImportTests.testFailedImportKeepsPreviousBundle`）。
- **提交与验证**：#135 评论（2026-11-11T16:00）记录 `b3fe38d3` + `dbdca70b`；SC/Sakura 双包模拟器验证通过（SC 30 角色、Sakura 1 角色、可进聊天）；iPad Air 已装该构建。

### 2.2 现有自动化覆盖到哪

- `EidolonCore/Tests/EidolonCoreTests/ContentRegistryTests.swift`（93 行，5 个用例）：`twoFranchisesSwitch`（shiny fixture + totsulover fixture 先后安装，两个包使用同一组 local id `mano`/`hiori`，断言 activeFranchise、`installedContentPackages == ["shiny","totsulover"]`、切换后 `characters().count == 2`、symlink 指向 `shiny/current`）、`autoRouting`、`rejectsOtherKinds`、`characterKey`（`totsulover:sakura != shiny:sakura`）、`legacyInfoDefaults`。
- `ContentBundleImportTests.swift`（约 30 个用例）：格式/内容 schema/embedding/文件校验、坏包拒绝、失败保留旧包、`testInstallLeavesUserDataAlone` 等，全部是**单包 fixture 语义**，没有跨包隔离断言。
- `RealBundleSmokeTests.swift`：`EIDOLON_TEST_BUNDLE` 开启时断言真实包 episode/passage/character 数、1024 维、`Qwen/Qwen3-Embedding-0.6B`。
- `FranchisePromptTests` / `PromptFidelityTests` / `ReplyFormatTests`：SC 提示词逐字不变、vocabulary 最长优先、totsulover 内置身份；`AdultModeJudgeGoldenTests` 覆盖成人模式 golden。
- `docs/testing.md:13-15`：`EIDOLON_IMPORT_BUNDLE` + `EIDOLON_IMPORT_CONTENT_FRANCHISE`（默认 shiny）、`EIDOLON_ACTIVE_FRANCHISE` 启动切包——这是当前唯一的多根手工验证入口。

**缺口**：双包用例只断言「内容侧可切换、角色数对」，没有在用户库里创建会话/好感/成就来断言隔离；没有 v24→v25 迁移 fixture；没有删除/恢复用例；没有记忆/检索跨包断言；没有「同 id 两包都产生用户数据」的用例。

### 2.3 galgame / totsulover 适配已落地的接缝

- **真实 v5 内容包**（`build/eidolon-totsulover-full-v5.eidolonpkg`，只读检查）：manifest v5、`franchise=totsulover`、`engineFamily=t-script`、4 角色（sakura/katan/sophia/suisen）、255 集 / 39803 行 / 13351 passages、`characters/franchise.json`。四位角色 `characterKeys = ["totsulover:sakura", …]`，与 manifest `ids` 一一对应。
- **企划身份来自内容包**：`FranchisePrompt.swift` 的可选字段（`workName`/`organization`/`producerRole`/`protagonistTerm`/`userSection`/`adultBoundary`/`worldPrompt`/`vocabulary`/`photoSeries`）由 `characters/franchise.json` 解码（`FranchisePrompt.swift:150-153`），`activateContent` 时装载（`ContentRegistry+Eidolon.swift:113-114`）；ADR-0040 明确「内容包仍是唯一身份来源；改称呼不需要改 Swift 代码」。
- **按企划归属的立绘**：Spine `Content/<franchise>/stand`、静态 `Content/<franchise>/static-stand`（ADR-0038；`Eidolon.swift:36-42` 的 `standDirectory` 直接按 `activeContentFranchise` 拼）；静态立绘安装校验 `info.franchise == 当前 franchise` 且 `contentSetID` 双方都有值时相等，否则拒装（`ContentRegistry+Eidolon.swift:213-245`）；切包清 stand 缓存防旧图谱泄漏（`Eidolon.swift:59-62`、ADR-0038）。
- **静态立绘 v2 与渲染器无关的接缝**：`AppearanceSelection`（`Appearance.swift:33`）与 `AppearanceSource` 协议（`Appearance.swift:101`）已存在；totsulover 14 base × 7 情绪已打进 `build/eidolon-totsulover-sakura-7emotion-allbases.eidolonpkg` 并在真机验证（#144 评论）。
- **真机/大包路径**：v5 内容包 39 MB（#144 评论），iPhone Air 已装 14 个静态立绘 base；导入/校验/覆盖/`previous` 保留在真机路径上跑通。

### 2.4 属于 #144/#145、不属于 S3 的完成项

剧情目录与用语集浏览（`aa29ce92`/`2a7a4efa`/`c2d4687c`）、facts/gifts/places/世界设定补完（`6cc2abbf`/`51102f31`）、每回合调试快照（ADR-0039）、Duo 适配（`5e346b24`/`e2ebf3be`）、按回复的调试入口等，都与 S3 身份/隔离无关，不应算进 S3 进度。

## 3. 未完成 / 阻塞（按优先级）

### P0-1 设计缺失：Phase B 没有 ADR，v24 编号冲突

- ADR-0036:21：「Phase A 结束后必须进入 Phase B：ADR-0037 的 v24 复合身份迁移、跨包隔离、删除/恢复与检索作用域」。
- `docs/adr/` 实际只有 `0036`、`0038`、`0039`、`0040`，**没有 0037**；`roadmap.md:11` 却写成「Phase B 的 v24 复合身份迁移仍未完成（ADR-0036）」，编号引用也不一致。
- `UserSchema.version = 24`（`UserSchema.swift:7`）已被 `turn_debug_snapshots` 占用（`:549-560`，ADR-0039）。因此 #135 的「v24 迁移」必须改成 v25；迁移前要先补 ADR（含五表重建 SQL、回填、备份、单向、删除语义、participants 是否纳入 S3）。
- 影响：没有这份 ADR，任何实现都会在「participants 和 `messages.speaker` 属于 S3 还是 S4」「删包后孤立数据是否可恢复」这些边界上反复。

### P0-2 用户库复合身份迁移未做（最高风险）

- 单库：`Location.userDatabase = User/eidolon.sqlite`（`Eidolon.swift:16-17`），不随 franchise 分库。
- 五张键表全部裸 `character_id`：`affinities`（`UserSchema.swift:79-80`，PRIMARY KEY）、`current_conversations`（`:288-289`，PRIMARY KEY）、`cycle_seeds`（`:252-253`，PRIMARY KEY）、`achievement_progress`（`:332-335`，复合唯一键之一）、`achievement_stages`（`:339-342`）。
- 会话查询按裸 id：`Conversation.swift:237`（`conversations(characterID:)`）、`:276`（`WHERE c.character_id = ?`）；`conversations.character_id` 同时是「owner/primary」。
- 后果：两个企划若出现同名 local id，好感/当前会话/周期/成就会**并成一行**；迁移后无法区分来源，事后不可拆。`docs/research/cross-franchise-model-2026-11-09.md:132-196` 已把「五表必须重建、其余表加 `franchise_id DEFAULT 'shiny'`」写成 P0 结论，并注明「现在做小，等第二个企划落地再做要拆已合并的行，不可逆」。
- 另：`conversations`/`messages`/`memories` 都还没有 `franchise_id`，`messages` 也没有 `speaker_*`。

### P0-3 没有「同 local id」隔离测试，风险未被覆盖

- `twoFranchisesSwitch` 的两个 fixture 用同一组 local id，但它只验证内容侧（角色数、active franchise、symlink）；没有创建会话/好感/成就，因此「切换可用」不等于「用户数据隔离」。
- `ContentRegistryState.legacyFranchise` / `normalizedFranchise` 默认把缺失 franchise 读成 `shiny`，旧用户库行也全按 `shiny` 解释——这条向后兼容路径目前没有任何测试。
- S3 的 user story 14（同名 id 不串数据）与 16（删包不丢数据）在测试里完全没有对应项。

### P0-4 `CharacterKey` 未进入运行时边界

- `CharacterKey` 定义在 `ContentRegistry.swift:5-15`（`franchise` + `localID`，`description = "franchise:localID"`），但生产代码无引用，仅 `ContentRegistryTests.swift:67-71` 使用。
- `Eidolon.sendTurn(characterID: String, …)`（`EidolonTurn.swift:118-120`）、`conversations(characterID:)`（`Conversation.swift:237`）、`characters()` 返回的 `CharacterConfig.id`（`CharacterConfig.swift:6-7`）都是裸 local id。
- 结果：即使 manifest 里有 `characterKeys`，UI 也无法把「当前 active franchise + local id」组合成稳定身份；一旦切换 franchise，同一个 local id 的会话/好感会被当作同一个角色。

### P1-1 删除包 / 孤儿数据 / 恢复未实现

- 无 `removeContent`/`uninstall` API；设置页无删除按钮（`SettingsView.swift:471-497`）；导入只有「重新导入内容包」。
- ADR-0036:20-21 把「删除/恢复」列为 Phase B；#135 要求「删除包只隐藏角色，用户数据保留为孤立数据，不级联删」。
- 现状可做到「隐藏」：删除 `Content/<franchise>` 目录后 `characters()` 自然为空；但没有受支持的入口，也没有「孤立数据在切回/重导入后复原」的测试。

### P1-2 记忆与检索的跨包作用域未定义

- 记忆设计为全局共享，只带 `sourceCharacterID`（`Memory.swift:8-9`；`memoriesPrompt` 无 franchise 过滤，`Retrieval.swift:365, 409`）。
- 剧情/事实检索走当前 content DB（`Retrieval.swift:129` 起，`storyCandidates`/`factsCandidates`/`workCandidates`），切包后天然只命中当前企划——这一条已满足；但**记忆**会把 SC 时期的内容带进 totsulover 的提示词，且没有 source franchise 标签可供过滤/展示。
- #135 要求「记忆全局但带 source franchise 标签」；`Memories` 列表也没有按企划分组的能力。

### P1-3 `conversation_participants` / `messages.speaker_*` 未实现

- S3 spec 要求新增 `conversation_participants(conversation_id, franchise_id, character_id, role, joined_at)` 与 `messages.speaker_franchise/speaker_character`；ADR-0036 明确 Phase A 不做。
- 这是 S4（#136）的硬依赖；S3 关闭可以不要求 S4 能用，但表结构最好在 v25 一次做掉，避免 S4 再迁一次 v26。

### P1-4 包管理 UI 缺口

- 列表只在 `contentPackages.count > 1` 时出现（`SettingsView.swift:472`），只有当前包显示完整信息（剧情/段落/角色/地点/向量模型/维度/content schema/内容族/静态立绘绑定/安装时间/剧情目录/用语集）。
- 没有删除；导入 kind 只有 `.content`/`.stand`/`.bar`（`SettingsView.swift:66-70`），`model3d` 与静态立绘只能走 DEBUG 环境变量（`EIDOLON_IMPORT_MODEL3D_BUNDLE`、`EIDOLON_IMPORT_STATIC_STAND_BUNDLE`，`docs/testing.md:15, 36`）。
- 没有「当前企划」显式标识以外的切换反馈，也没有切包后「旧会话不可达」的说明。

### P2-1 MLTD 小样本内容包不存在

- `build/` 只有旧 `eidolon-model3d-3dtest.eidolonpkg`（`franchise=mltd`、`runtime.unity-uaal`、多角色 localID `001har`/`002chi`/`003mik`），**没有 mltd 的 content 包**。
- #142 0 评论、无提交；#135 的排期把 Haruka 放进 Phase A 验证组合，但实际只验了 SC+Sakura。三包（Shiny+Sakura+Haruka）并存从未验证。

### P2-2 model3d 是全局单槽，且 haruka3d 调试 id 仍在产品路径

- `Eidolon.swift:24`：`model3DDirectory = Content/model3d`（不分 franchise）；`Model3DInstaller.swift:12-14` 同样单目录，安装时整体替换（`model3d-previous` 备份）。
- `EidolonIOS/Runtime/BundledModel3D.swift:54-60` 仍会在 `mltd` 包里没有 `haruka3d` 时合成一个 `localID: "haruka3d"` 的角色——正是 #142 要求「不再出现在产品路径」的调试遗留。
- 结果：即使做了 MLTD content 包，3D 包也无法与 Shiny 的 3D 包并存；#142 的验收条件在结构上未满足。

### P2-3 可延后

- #143 Gakumas（webgl-three runtime、200–400 MB）、#136 S4 Universe/Scene、#142 的 Unity 构建/真机性能与全量动作、#145 全表情/ExpressionCatalog、#140 macOS、其他企划内容包。
- 这些都不阻塞 S3 的四条 M3 验收；S3 的「多包可用」不需要 3D 或 S4。

## 4. galgame 适配对 S3 测试的帮助与误导

### 4.1 已被 v5 / 身份 / 内容包验证打通的接缝

| 接缝 | 证据 | 对 S3 的价值 |
| --- | --- | --- |
| 第二个真实包可导入、可切换、可聊天 | #135 评论；`ContentRegistryTests.twoFranchisesSwitch`；`docs/testing.md:13-15` | 证明「加一个包」不需要改核心 |
| 企划身份来自内容包，不写死 Swift | ADR-0040；`FranchisePrompt.swift:150-153`；v5 的 `characters/franchise.json` | 未来第二个 franchise 的提示词/称呼可复用同一条路径 |
| 立绘/静态立绘按 franchise 归属，`contentSetID` 绑定 | ADR-0038；`ContentRegistry+Eidolon.swift:213-245` | 多包不会互相覆盖资产；切包清缓存 |
| 跨包 embedding 一致性拒装 | `ContentRegistry+Eidolon.swift:41-47` | 多包共用一个用户检索库的前提 |
| 大包/真机导入 | v5 39 MB；iPhone Air 14 base（#144 评论） | 导入/校验/覆盖/previous 路径已被真实数据打过 |
| 静态立绘渲染器无关接缝 | `Appearance.swift:33, 101` | 第二个 2D/3D 渲染器未来复用同一选择值类型 |

### 4.2 S3 关键路径仍未验证

- **同 local id 的用户数据冲突**：内容侧有 Fixture 同 id 的双包切换测试，但没有任何用户数据隔离测试；真机验证则全在 local id 不重叠的「安全路径」上（ADR-0036:26 自己写明）。
- **用户数据隔离**：`conversations`/`messages`/`memories`/好感/成就仍是裸 id 单库；切包只换 content DB 与 symlink。
- **删除/恢复**：无 API、无 UI、无测试。
- **记忆作用域**：记忆全局、无 franchise 标签，跨企划会互相进入提示词。
- **三包并存**：只验过两包（SC+Sakura）；第三个（Haruka）从未存在。
- **`FranchisePromptContext` 是进程级全局**（`FranchisePrompt.swift:156-173`）：切包时会被 `activateContent` 覆盖，单 active 语义下安全；但切包前启动的后台任务（记忆/标题/判断）在切包后读提示词时可能读到新企划——未验证，属于 Phase B 的并发/作用域问题。

### 4.3 误导点

1. **「双包验证通过」≠「多包可用」。** 两次通过的都是「内容包可装、可切、各包内角色可聊」，与 S3 要证明的「同名角色不串数据」「删包不丢数据」不是同一件事。ADR-0036 的后果段已经预警，但 issue/roadmap 的措辞容易被读成 S3 已过大半。
2. **Sakura 是合成 fixture（#141），totsulover v5 是同一 franchise 的真实大包。** 前者证明「第二个 franchise 的最小路径」，后者证明「同 franchise 的内容量/真机路径」；两者都不证明「两个真实企划并存」的复杂度。
3. **静态立绘真机验收与 S3 无关。** 14 个 base、7 情绪、衣柜选择器属于 #144/#145 的渲染与资产工作。
4. **`characterKeys` 出现在 manifest 里容易被误认为身份边界已落地。** 它只是安装元数据；运行时和用户库仍是裸 id。

**判断**：galgame 适配让 S3 的「安装/资产/提示词身份」三条接缝变便宜，也让手工测试有了真实包可用；但 S3 剩余工作的主体是数据层（v25 迁移、五表重建、删除/恢复、记忆作用域），这部分一行都没开始。可以把 galgame 的验证结果当作 Phase B 的回归基线，不能当作 Phase B 的进度。

## 5. 建议下一步与最小验收清单

### 5.1 建议验收顺序（先数据层，后 MLTD；先自动，后手工）

> 如果只能先做一件事：给现有 `ContentRegistryTests.twoFranchisesSwitch` 加上用户数据断言——切到 totsulover 后给 `mano` 开一场对话、加一点好感，再切回 shiny，断言 shiny 侧看不到这场对话、好感不共享。按当前 schema（`conversations`/`affinities`/`current_conversations` 都只按裸 `character_id`）这个断言应当立刻变红；它把 S3 的缺口变成一条可执行的失败测试，比继续手工切包更有信息量（此为推断，未实际运行）。

**第 0 步：补 ADR-0037（Phase B 设计）** — 半天
定稿：v25（不是 v24）迁移、五表重建与回填、`franchise_id` 默认 `shiny`、备份与单向、删除语义（隐藏 + 孤立数据 + 重导入恢复）、`conversation_participants`/`messages.speaker` 是否纳入 S3（建议纳入，给 S4 留一次迁移）、记忆 `source_franchise` 与 scope。
验收：ADR 合入；`docs/adr/` 出现 `0037-*`；roadmap/#135 的编号勘误。

**第 1 步：v25 迁移 + 回填测试（最高优先级）** — 1–1.5 天
用 v24 fixture 跑 v25：五表重建后旧行全为 `shiny`、无行丢失、`conversations`/`messages`/`memories` 加列默认 `shiny`、迁移前备份文件存在、重复迁移幂等。
验收：`swift test --package-path EidolonCore --filter UserSchemaTests`；新增 `testV25BackfillsShiny`、`testV25KeepsEveryRow`、`testV25IsNotRunTwice`、`testV25LeavesGoldenPromptUnchanged`。

**第 2 步：`CharacterKey` 进运行时边界 + 同 id 隔离测试** — 1–1.5 天
`Eidolon` 查询/写入改为接受 `CharacterKey`（或内部组合 active franchise），用户库查询带 `franchise_id`；新增两个合成 fixture 包（不同 franchise、**故意同 local id**，如 `shiny:mano` 与 `mltd:mano`），断言两包同时安装后：好感/当前会话/周期/成就各自独立、删 A 包不影响 B、切回 A 数据完整。
验收：`swift test --package-path EidolonCore --filter ContentRegistryTests`、新增 `IdentityIsolationTests`；这是 S3 的「核心断言」，必须先绿。

**第 3 步：删除/重导入恢复** — 0.5–1 天
core 增加删除 API（只删包目录 + registry 记录，不动用户库）；设置页删除按钮 + 二次确认；重导入后孤立数据重新可达。
验收：`testRemovingAPackageKeepsUserData`、`testReimportingRestoresTheOrphanedConversation`；手工：删 totsulover → SC 数据完好 → 重导入 → 旧会话回来。

**第 4 步：检索/记忆作用域** — 1 天
`memories` 加 `source_franchise`（v25 一并做），`memoriesPrompt` 按当前 franchise 过滤或至少带标签；确认剧情/事实检索只用当前 content DB，并有测试。
验收：`testMemoriesFromAnotherFranchiseDoNotEnterThePrompt`（或按 spec 的「带标签」版本）；手工：切包后调试上下文里不出现另一企划记忆。

**第 5 步：包管理 UI 收口** — 0.5 天
列表加删除、当前企划标识、切包提示（旧会话在另一企划下不可见/仍保留）；`model3d`/静态立绘是否需要用户入口，按 #142 再定。
验收：设置页可完成「导入 → 切换 → 删除 → 重导入」全流程，截图放 #135。

**第 6 步：MLTD Haruka 小样本（数据层绿了再做）** — 2–3 天（素材/打包为主）
mltd content 包（日文 1–2 段 + `franchise=mltd` + `characterKeys=["mltd:haruka"]`）；model3d 包改按 franchise 存（`Content/<franchise>/model3d`）或明确单槽取舍；去掉 `BundledModel3D.swift:54-60` 的 `haruka3d` shim；设置页或调试入口可导入 3D 包。
验收：SC + MLTD 并存、切包、春香 1:1 命中 1–2 段日文、3D 显示、无语音不报错；切回 SC 后 SC 的 3D/2D 均正常。

**第 7 步：手工验收与回归** — 0.5 天
按 #135 手工清单 + `tools/oracle/run.sh` 六场景 identical + 全量 `swift test` + iOS 测试。

> 不建议把 MLTD/3D 放在第 1–2 步之前：3D 依赖 Unity 产物、素材与单槽改造，且完成后也只能证明「能装第三个包」，证明不了「同 id 不串数据」；而 v25 迁移拖得越久，已合并的用户数据越多，越不可逆（`cross-franchise-model-2026-11-09.md:196`）。

### 5.2 最小验收命令 / 测试

```sh
# Core 全绿（不联网）
swift test --package-path EidolonCore

# 现有 S3 相关
swift test --package-path EidolonCore --filter ContentRegistryTests
swift test --package-path EidolonCore --filter ContentBundleImportTests
swift test --package-path EidolonCore --filter UserSchemaTests
swift test --package-path EidolonCore --filter FranchisePromptTests

# 真实包冒烟（需要本机 build/ 里的包）
EIDOLON_TEST_BUNDLE=build/eidolon-totsulover-full-v5.eidolonpkg \
  swift test --package-path EidolonCore --filter RealBundleSmokeTests

# 导出工具 / 上游提示词对照
python3 -m unittest discover -s tools/tests
tools/oracle/run.sh

# iOS 测试（模拟器名以 docs/testing.md:104-137 为准）
xcodebuild test -project EidolonIOS.xcodeproj -scheme EidolonIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

手工多包（DEBUG 构建，`docs/testing.md:13-15`）：

```sh
# 1) 装到 totsulover 根
EIDOLON_IMPORT_BUNDLE=eidolon-totsulover-full-v5.eidolonpkg \
EIDOLON_IMPORT_CONTENT_FRANCHISE=totsulover
# 2) 启动切到 totsulover
EIDOLON_ACTIVE_FRANCHISE=totsulover
# 3) 设置 → 内容包：切回 shiny，确认 SC 角色/会话/好感完好；再切回 totsulover
# 4) 删包（实现后）：确认 totsulover 角色消失、SC 数据不动；重导入后 totsulover 会话恢复
```

### 5.3 每步证据要求

- 自动：新增测试名 + `swift test` 输出；oracle `identical`。
- 手工：截图/日志放 #135 评论（按 #132「证据放对应 issue 评论，不提交资源」）。
- 文档：ADR-0037、roadmap `M3` 状态、#135 编号勘误（v24 → v25）。

## 6. 剩余工作量估计（推断）

以「S3 可按 #132 关闭」为 100%：

| 工作项 | 状态 | 占 S3 工作量（估） |
| --- | --- | --- |
| Phase A 骨架（registry/kind/CharacterKey 元数据/切包/设置页） | 已完成 | ~35% |
| ADR-0037 + spec 勘误 | 未开始 | ~3% |
| v25 迁移 + 五表重建 + 回填测试 | 未开始 | ~18% |
| `CharacterKey` 边界 + 同 id 隔离测试 | 未开始 | ~15% |
| 删除/重导入恢复 | 未开始 | ~7% |
| 记忆/检索作用域 | 未开始 | ~7% |
| 包管理 UI 收口 | 部分 | ~3% |
| MLTD 小样本内容包 + model3d 按 franchise + 导入入口 | 未开始 | ~10% |
| 手工验收/文档/回归 | 未开始 | ~2% |

即 **剩余约 60–65%**；按 M3 四条验收，当前稳定满足 1 条（双包可安装），第 4 条只有合成 fixture 层面满足，第 2/3 条未做。

**最短路径**：ADR-0037 → v25 迁移 → 同 id 隔离测试 → 删包/恢复 → 记忆作用域 → 包管理 UI → MLTD 小样本 → 手工验收。数据层（前五步）估 4–5 个工作日，MLTD 小样本 2–3 个工作日（素材/打包为主），手工验收 0.5 天——这是估算，不是承诺。

## 7. 未确认 / 推断

- **MLTD 内容包是否存在**：`build/` 未发现 mltd content 包，#142 无评论；推断为未开始（未确认是否有本机私有产物）。
- **真机安装状态**：v5 包 39 MB、iPhone Air 14 个 base 来自 #144 评论，未独立核对真机。
- **旧库真实数据量与迁移耗时**：未测；v25 迁移的备份/耗时需要真机样本。
- **切包时后台任务读提示词的竞态**：`FranchisePromptContext` 进程级全局（`FranchisePrompt.swift:156-173`），推断单 active 下安全，未做并发测试。
- **剩余比例**：基于代码缺口与 issue 验收项的估算，不是实测。
- **#135 的「v24」与代码 v24 的冲突**：以代码（ADR-0039）为准，推断 spec 需要改号，未确认是否已有意为之。

## 8. 来源

### 仓库文件

- `docs/roadmap.md:10-11, 29`（S3 状态、M3 验收）
- `README.md:190, 194-202`（现状与边界）
- `docs/adr/0036-s3-phase-a-content-registry.md:21, 26-27`（Phase A/B 边界、local id 风险）
- `docs/adr/0038-per-franchise-stand-packages.md`（立绘按企划归属）
- `docs/adr/0039-turn-debug-snapshot.md`（v24 = 调试快照）
- `docs/adr/0040-franchise-user-identity.md`（提示词层身份；明确不改裸 id）
- `docs/research/cross-franchise-model-2026-11-09.md:132-196`（P0 复合身份、五表重建、不可逆）
- `docs/research/content-packs-galgame-gakumas-2026-11-11.md`（galgame 素材调研；非 spec）
- `docs/testing.md:9, 13-15, 31, 104-137, 154-172`（多根环境变量、iOS 测试与手工清单）
- `EidolonCore/Sources/EidolonCore/Eidolon.swift:8-25`（Location：Content/current、User 单库、model3d 单槽）、`:36-47`（stand 目录/缓存）、`:113, 363`（安装入口）、`:472-480`（角色只来自 active 包）
- `EidolonCore/Sources/EidolonCore/ContentRegistry.swift:5-15`（`CharacterKey`）
- `EidolonCore/Sources/EidolonCore/ContentRegistry+Eidolon.swift:25-28, 41-47, 67-92, 95-117, 126-147, 184-245`
- `EidolonCore/Sources/EidolonCore/ContentManifest.swift:9, 16-33, 69-90`
- `EidolonCore/Sources/EidolonCore/CharacterConfig.swift:6-7`（裸 `id`）
- `EidolonCore/Sources/EidolonCore/EidolonTurn.swift:118-120`（`sendTurn(characterID: String, …)`）
- `EidolonCore/Sources/EidolonCore/Conversation.swift:237, 276`
- `EidolonCore/Sources/EidolonCore/UserSchema.swift:7, 79-80, 252-253, 288-289, 332-342, 549-560`
- `EidolonCore/Sources/EidolonCore/Memory.swift:8-9`（记忆全局共享）
- `EidolonCore/Sources/EidolonCore/Retrieval.swift:129, 365, 409`
- `EidolonCore/Sources/EidolonCore/FranchisePrompt.swift:150-153, 156-178`
- `EidolonCore/Sources/EidolonCore/Appearance.swift:33, 101`（AppearanceSelection/Source）
- `EidolonCore/Sources/EidolonCore/Model3DInstaller.swift:12-14`
- `EidolonCore/Sources/EidolonCore/Presentation.swift:243-249`（ContentKind 含 universe，未接线）
- `EidolonIOS/Runtime/BundledModel3D.swift:54-60`（haruka3d shim）
- `EidolonIOS/App/AppModel.swift:1779-1800, 2241, 2250`
- `EidolonIOS/Features/Settings/SettingsView.swift:66-70, 471-497, 529`
- 测试：`EidolonCore/Tests/EidolonCoreTests/ContentRegistryTests.swift`、`ContentBundleImportTests.swift`、`RealBundleSmokeTests.swift`、`FranchisePromptTests.swift`、`PromptFidelityTests.swift`、`AdultModeJudgeGoldenTests.swift`；`EidolonIOSTests/ResponsiveLayoutTests.swift`、`RuntimeRegistryTests.swift`
- 产物（只读检查，不入库）：`build/eidolon-totsulover-full-v5.eidolonpkg`、`build/eidolon-totsulover-sakura-7emotion-allbases.eidolonpkg`、`build/eidolon-model3d-3dtest.eidolonpkg`

### GitHub issue（`-R JackLin513/eidolon-sc-ios`）

- [#135 S3 多内容包、复合身份与 MLTD 小样本](https://github.com/JackLin513/eidolon-sc-ios/issues/135)
- [#132 S1–S4 组件化 spec（S3 验收与依赖）](https://github.com/JackLin513/eidolon-sc-ios/issues/132)
- [#141 S3 Galgame 角色包 MVP](https://github.com/JackLin513/eidolon-sc-ios/issues/141)
- [#142 S3 MLTD Haruka model3d](https://github.com/JackLin513/eidolon-sc-ios/issues/142)
- [#143 S3 Gakumas model3d](https://github.com/JackLin513/eidolon-sc-ios/issues/143)
- [#136 S4 Universe/Scene](https://github.com/JackLin513/eidolon-sc-ios/issues/136)
- [#144 内容包补完与静态立绘](https://github.com/JackLin513/eidolon-sc-ios/issues/144)
- [#145 静态立绘全表情与 totsulover 剩余适配](https://github.com/JackLin513/eidolon-sc-ios/issues/145)
- [#134](https://github.com/JackLin513/eidolon-sc-ios/issues/134) / [#138](https://github.com/JackLin513/eidolon-sc-ios/issues/138) / [#139](https://github.com/JackLin513/eidolon-sc-ios/issues/139)（S2，CLOSED）
- [#140 macOS](https://github.com/JackLin513/eidolon-sc-ios/issues/140) / [#146 iPhone Duo](https://github.com/JackLin513/eidolon-sc-ios/issues/146)（不阻塞 S3）

### 提交

- Phase A：`b3fe38d3`、`dbdca70b`（#135 评论）
- v5/身份/静态立绘：`f8ece524`、`51102f31`、`4d4c9995`、`bee7097f`、`a26e22ab`、`2a7a4efa`、`aa29ce92`、`6cc2abbf`、`c2d4687c`、`33b55c31`、`711261cf`、`828070a1`、`5f14ee09`
- Duo：`5e346b24`、`e2ebf3be`（HEAD）
