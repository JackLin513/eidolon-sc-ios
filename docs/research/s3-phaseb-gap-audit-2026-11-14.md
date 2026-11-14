# S3 Phase B 缺口审计（2026-11-14）

> 审计对象：worktree `.agents/worktrees/dsh-659b97a2-fcd2`（分支 `feat/componentization`，HEAD `e2ebf3be`）。
>
> 方法：只读阅读当前代码与 schema，逐表核对 SQL 与调用点；没有运行 App、没有读取任何真机/模拟器用户库、没有修改代码或 issue。凡未实际复现的行为均标「推断」或「未验证」。
>
> 旧报告 `docs/research/s3-readiness-2026-11-14.md`（350 行）只盘了 5 张「裸 `character_id` 主键表」；本次以当前代码重新枚举全部 39 张用户表，并覆盖 Phase A 之后新增的 debug 快照、朋友圈、照片、通话、礼物/成就、日程/周期、Bar、记忆/检索等。

---

## 0. 结论摘要（按严重度）

1. **P0｜复合身份仍完全未落库。** `CharacterKey` 在生产代码中零引用（只有 `ContentRegistry.swift:5` 定义与测试），`FranchiseID` 类型根本不存在；39 张用户表里 15 张直接持有裸字符键、11 张经 conversation/message/post 间接归属，13 张是全局单例/全局命名空间。切包不改任何用户数据（`activateContent` 只切 symlink 与 content DB），所以「同一 local id 的两个企划」会直接共用对话、好感、成就、日程、朋友圈、调试快照。

2. **P0｜对话在切包后会串或变孤儿。** `EidolonTurn.currentConversationID` 先按裸 `character_id` 查 `current_conversations`，再回退到该 id 的最新 conversation；`conversations(characterID:)` 也只按裸 id 过滤。切到同 id 的另一企划后，新角色会接着旧企划的聊天记录说话；切到不同 id 时，旧会话在 UI 上没有任何入口（`characters()` 只读 `Content/current`，聊天列表只渲染当前角色）。

3. **P0｜大量「聚合面」天然跨企划。** `momentsTimeline` 不带任何角色/企划过滤；记忆列表 `memories()` 全量；统计 `statsSummary` 的 turns/calls/gifts/heatmap 用 `conversations.character_id` 跨全部行汇总；`savedPlacements()` 全量；`giftState` 背包按当前 catalog 回填；`playSummary`、成就总览、日历也混入旧企划数据。切包后旧朋友圈会以裸 local id 或「新企划同名角色」的名字显示。

4. **P1｜日程是「全局周池」，切包后新企划当周无工可排。** `schedule_weeks` 只按 `week` 判断是否已抽（`Schedule.swift:719-748`），`weekly_jobs.id = "<week>:<listedJobID>"` 不含企划；第一个企划抽过某周后，第二个企划同一周不会再抽。`countDoneJobs`（:893-940）还会把旧企划未结算的 placement 按裸 `character_id` 给新企划同名角色加好感。

5. **P1｜debug 快照与 turn trace 没有企划边界。** `turn_debug_snapshots.character_id` 是裸 id，`latestFailedDebugSnapshot(characterID:conversationID: nil)` 会跨企划取最近失败快照（`TurnDebug.swift:248-280`）；`turn_traces` 的保留策略是全局最新 N 条、清空是全清（`TurnTrace.swift:301-305`、:275-279）。这些 payload 里含完整 prompt、世界书、记忆、检索文本与角色 id。

6. **P1｜删除/恢复语义不存在，内容管理还有两个一致性缺口。** 全仓库没有删除内容包 API/UI（grep `removeContent|uninstall|deleteContent|removePackage|deletePackage` 无结果）；设置页只有「切换」。`Content/previous` 只是单包安装回滚槽，不是切包历史。手动删目录后 registry 仍列该包，切换会抛错；没有「孤儿用户数据」概念。另外：对**当前 active** 企划重新导入时不会重开 content DB 句柄（推断会继续读旧 inode）；embedding 维度不匹配是在 installer 已 swap 文件**之后**才检查（推断会留下「导入失败但磁盘已替换」的状态）；同企划重导入还能绕过这项检查（推断）。

7. **P2｜全局单例与用户偏好仍按全库共享。** `producer_profile`、`gift_balances`、`cycle_settings`、`moment_state`、`achievements_launched` 都是 `id=1` 单例；`app_state` 里 `bar.*`、`model3d.bundle` 也是全局单槽；UserDefaults 里 `eidolon.standOutfits`、`eidolon.staticAppearance`、`roster.pinned/hidden` 都以裸 local id 为 key。切包后设置、抽卡次数、周期开关、朋友圈「今天已规划」、衣装/立绘选择、置顶/隐藏都会跨企划复用。

8. **P2｜检索缓存与文档/测试也没跟上。** `fact_vectors` 的 scope 是 `"fact:\(character.id)"` 与全局 `"work"`，缓存 key 不含企划；工作标题撞名时可能复用另一企划的向量（推断）。`memoriesPrompt` 的检索调用不传 characterID（`Retrieval.swift:365-371`），所以记忆检索本来就是全角色/全企划。`docs/roadmap.md:11` 仍写「v24 复合身份迁移」，但 v24 已经是 `turn_debug_snapshots`；`docs/adr/` 缺 ADR-0037；测试里 `ContentRegistryTests.twoFranchisesSwitch` 虽然故意用同一组 `mano`/`hiori`，却完全没有创建用户数据，没有任何隔离/迁移测试。

---

## 1. 用户库全表审计

用户库是单一 `User/eidolon.sqlite`（`Eidolon.swift:11-25`），当前 `UserSchema.version = 24`（`UserSchema.swift:7`），共 **39 张表**。角色本身不在 SQLite：`characters` 来自内容包 `Content/current/characters/characters.json`（`Eidolon.swift:472-480`），用户表里只有 TEXT 形式的 local id，没有任何指向 characters 的外键。这是 Phase B 必须补复合键的根本原因。

> 下表的「历史数据」只表示该表从哪个 schema 版本开始存在；实际行数需要读真机用户库，本次只读审计**未验证**。

### 1.1 A 类：直接持有角色键（15 张，Phase B 必须处理）

| 表 | 当前键 / 角色键 | 同 local id 会合并？ | Phase B 处理 | 需重建表？ | 历史数据 |
|---|---|---|---|---|---|
| `conversations` | `id` PK；`character_id TEXT NOT NULL`（owner，无 FK） | 会：会话列表、current、统计全按裸 id | 加 `franchise_id`；唯一性/查询改用 `(franchise_id, character_id)`；`character_id` 保留为 owner | 否（加列+索引+回填；若改语义再定） | v1 起 |
| `affinities` | `character_id` PK | 会：两个企划同名角色共用一条好感 | 重建 PK `(franchise_id, character_id)` | **是** | v1 起 |
| `call_ends` | `id`；`conversation_id` FK CASCADE；`character_id NOT NULL` | 会：stats/成就按 `character_id` 汇总 | 加 `franchise_id` + 复合索引；统计与成就同步过滤 | 否 | v6 起 |
| `bar_visits` | `id`；`character_id`；`entered_on` | 会：酒吧历史/连勤按裸 id | 加 `franchise_id`；历史、计数、今日一次性都按复合过滤 | 否 | v8 起 |
| `weekly_jobs` | `id` PK = `"<week>:<listedID>"`；`character_id` | 会，且跨角色/企划的 listed id 可能撞 PK | 重建 id 方案（至少含 franchise+character）或加 `franchise_id` 并改唯一键 | **是**（PK/ID 方案） | v10 起 |
| `schedule_placements` | PK `(week, job_id)`；`character_id` | 会：同一 job id 的排班跨企划混 | 重建 PK `(franchise_id, week, job_id)` | **是** | v10 起 |
| `cycle_seeds` | `character_id` PK | 会：同名角色共用周期种子 | 重建 PK `(franchise_id, character_id)` | **是** | v11 起 |
| `cycle_records` | `id`；`character_id` | 会：周期记录按裸 id | 加 `franchise_id` + 复合索引 | 否 | v12 起 |
| `current_conversations` | `character_id` PK；`conversation_id` FK CASCADE | 会：切包后直接复用旧企划的当前会话 | 重建 PK `(franchise_id, character_id)` | **是** | v14 起 |
| `achievement_progress` | PK `(achievement, character_id)` | 会：同名角色进度合并 | 重建 PK `(achievement, franchise_id, character_id)` | **是** | v16 起 |
| `achievement_stages` | PK `(achievement, character_id, stage)` | 会：同名角色解锁状态合并 | 重建 PK `(achievement, franchise_id, character_id, stage)` | **是** | v16 起 |
| `moment_posts` | `id`；`character_id` | 会：feed 不过滤，同名文章归新角色 | 加 `franchise_id`；feed/统计/角色页按它过滤 | 否 | v23 起 |
| `moment_reactions` | `id`；`post_id` FK；`character_id` | 会：评论者身份按裸 id 解析 | 加 `franchise_id` 或统一经 post 派生；显示名按 active 过滤 | 否 | v23 起 |
| `moment_plans` | `id`；`character_id`；`due_at` | 会：旧企划计划可能用同 id 新角色生成 | 加 `franchise_id`；切包时处理/清理 pending plan | 否 | v23 起 |
| `turn_debug_snapshots` | `id`；`conversation_id` FK（可 NULL）；`character_id NOT NULL`；payload | 会：失败快照按裸 id 回退可见 | 加 `franchise_id`；查询、保留、清空都按企划 scope | 否 | v24 起 |

### 1.2 B 类：经 conversation / message / post 间接属于某企划（11 张）

| 表 | 当前键 / 关联 | 同 local id 会合并？ | Phase B 处理 | 需重建表？ | 历史数据 |
|---|---|---|---|---|---|
| `messages` | `conversation_id` FK CASCADE；`role` 只有 user/character，无 speaker | 随 conversation 合并；不同 id 的旧消息不可达 | v25 只做 conversation 级隔离即可；若同时做 S4 多角色，再加 `speaker_franchise/speaker_character`（决策） | 若加 speaker 列则 ALTER+回填；否则否 | v1 起 |
| `conversation_events` | `conversation_id` FK；`kind/gift_id/liked/affinity` | 随 conversation | 无需加列，查询经 conversation 过滤 | 否 | v1 起 |
| `reach_outs` | `conversation_id` FK | 随 conversation；未读数按裸 id 分组 | 查询 JOIN conversations 过滤；或加 franchise | 否 | v1 起 |
| `pending_jobs` | `kind`；`conversation_id`/`message_id`（无 FK） | 随 conversation；memory job 无企划 | 加 franchise/payload 或在恢复时校验；删除包/切包时清理 | 否 | v1 起 |
| `turn_traces` | `conversation_id`；payload 含 `characterID` 与完整 prompt | 全局保留/清空会串企划 | debug-only：按 franchise/conversation 过滤与保留；决策是否纳入 v25 | 否 | v1 起 |
| `memories` | `id`；`source_character_id` 可空；`conversation_id` 可空；`text` 唯一 | **语义全局**；同文本去重会合并 | 决策：保持全局并加 `source_franchise_id`（#135 倾向），或按企划隔离 | 否 | v1 起 |
| `memory_vectors` | PK `(memory_id, model)` | 随 memory（全局） | 不改 | 否 | v1 起 |
| `photos` | `id`；`conversation_id`/`message_id` FK；无角色列 | 经 message 归属；切包后无画廊入口 | 加 franchise/character 或经 message 派生；包删除时孤儿清理 | 否 | v21 起 |
| `moment_images` | `post_id` FK | 随 post | 不改 | 否 | v23 起 |
| `moment_likes` | `post_id` PK | 随 post | 不改 | 否 | v23 起 |
| `moment_comments` | `post_id` PK | 随 post | 不改 | 否 | v23 起 |

### 1.3 C 类：全局单例 / 内容域 / 纯全局命名空间（13 张）

| 表 | 当前键 | 现状问题 | Phase B 处理 | 需重建表？ | 历史数据 |
|---|---|---|---|---|---|
| `producer_profile` | `id=1` 单例 | 制作人身份全库一份；ADR-0040 只在非 shiny 时**隐藏 UI** | 决策：继续全局，或按企划分身份 | 若分企划则**是** | v1 起 |
| `app_state` | `key` PK | `content.packages`、`content.activeFranchise`、`content.bundle` 是全局指针；含 `bar.*`、`model3d.bundle` | content.* 保持全局；per-franchise 值用 key 后缀（stand 已如此） | 否 | v1 起 |
| `fact_vectors` | PK `(scope, entry_id, model)` | scope 含裸 `fact:<id>`；`work` 全局；同名 work title 可能复用错误向量（推断） | scope 加 franchise；升级时清空缓存重建 | 否（可清缓存） | v1 起 |
| `schedule_weeks` | `week` PK | 全局周池：第一个企划抽过，第二个企划该周无工 | 重建 PK `(franchise_id, week)` | **是** | v10 起 |
| `cycle_settings` | `id=1` 单例 | 周期开关全局 | 决策：全局或按企划 | 若分企划则**是** | v11 起 |
| `gift_balances` | `id=1` 单例 | 抽卡次数/重置卡全库共享 | 决策：全局或按企划 | 若分企划则**是** | v16 起 |
| `gift_backpack` | `gift_id` PK | gift id 是内容相对 id；跨企划同名礼物共享库存 | 重建 PK `(franchise_id, gift_id)` | **是** | v16 起 |
| `gift_rewards` | `key` PK（字符串） | key 里无企划 | 重建/加企划前缀 | **是** | v16 起 |
| `achievements_launched` | `id=1` 单例 | 全库只 backfill 一次 | 保留全局；新企划是否需要重跑需决策 | 决策 | v16 起 |
| `achievement_play_seen` | `id=1` 单例 | 全局已读 | 保留全局 | 否 | v18 起 |
| `moment_state` | `id=1` 单例 | `planned_day` 全局：切包当天新企划不再规划 | 决策：按企划，或切包重置 | 若分企划则**是** | v23 起 |
| `service_calls` | `id`；`conversation_id`/`call_id` | 全局用量；无角色列 | 可选加 franchise 便于统计；不影响身份 | 否 | v19 起 |
| `price_overrides` | PK `(provider, model, unit)` | 全局价格覆盖 | 不改 | 否 | v19 起 |

### 1.4 旧报告「五张表」之外，本次必须补上的表

旧报告只列了 `affinities`、`current_conversations`、`cycle_seeds`、`achievement_progress`、`achievement_stages`。当前代码中至少还有以下角色相关表是它没盘的：

- `turn_debug_snapshots`（v24，`UserSchema.swift:553`；commit `828070a1`）：裸 `character_id`、保留 20 条/角色+会话、失败快照回退裸 id。
- 朋友圈 7 张：`moment_posts`(:469)、`moment_images`(:490)、`moment_reactions`(:503)、`moment_likes`(:516)、`moment_comments`(:521)、`moment_plans`(:531)、`moment_state`(:542)；`Moments.swift:292-370` feed 无过滤。
- `photos`（v21，:440）：照片只经 conversation/message 归属，没有角色/企划列；`User/images/photos` 平铺。
- `call_ends`（v6，:159）：除了 conversation FK 还冗余裸 `character_id`，被 stats/成就/最近联系直接查。
- `bar_visits`（v8，:188）：裸 `character_id`，酒吧历史/一次性判定/连勤都按它。
- 日程 3 张（v10，:216/:220/:233）：全局周池 + `weekly_jobs` 裸 id 方案 + placement 裸 `character_id`。
- 礼物 3 张（v16，:316/:322/:326）：全局抽卡/背包/奖励，gift id 内容相对。
- 成就 4 张（v16，:332/:339/:346；v18 :384）：进度/阶段裸 `character_id`，另有全局 `achievements_launched` / `achievement_play_seen`。
- `cycle_records`（v12，:266）与 `cycle_settings`（v11，:256）。
- `service_calls`（v19，:395）、`price_overrides`（v19，:416）：用量与价格，全局。
- `memories`（:56）/`memory_vectors`（:65）/`fact_vectors`（:71）：记忆语义全局，检索缓存 scope 含裸 id。
- `pending_jobs`（:85）/`turn_traces`（:94）：后台任务与 trace 没有企划列。
- `producer_profile`（:101）/`app_state`（:110）/`conversation_events`（:39）/`reach_outs`（:46）。

---

## 2. 运行时边界审计

### 2.1 `CharacterKey` / `FranchiseID` 的生产引用

- `CharacterKey` 定义在 `ContentRegistry.swift:5-15`（`franchise`、`localID`、`description`），文档明确说明 local id 不能单独作为全局用户库 key。但生产代码 **0 引用**：`grep -rn CharacterKey EidolonCore/Sources` 只命中定义本身；唯一使用在 `ContentRegistryTests.characterKey`。
- `FranchiseID` 类型不存在（`grep -rn FranchiseID EidolonCore/Sources` 为空）。当前「企划」只是字符串 `String`：`ContentBundleInfo.franchise`、`ContentRegistryState.activeFranchise`、`CharacterKey.franchise`。
- manifest 里的 `characters.characterKeys` 只在安装时校验数量/尾段 local id 与 `characters.ids` 对齐（`ContentRegistry+Eidolon.swift:67-91`）；**不写任何用户表**，也不进入运行时模型。

### 2.2 `Eidolon` 公开 API 中接收 `characterID: String` 的方法

| 领域 | 方法（文件:行） |
|---|---|
| 回合 | `sendTurn(characterID:…)`（`EidolonTurn.swift:119`）、`currentConversation`(:197)、`lastConversation`(:204)、`affinityStatus`(:210) |
| 会话 | `conversations(characterID:)`（`Conversation.swift:237`）、`beginNewConversation`(:352)、`startConversation`(:360) |
| 好感/调试 | `debugAffinity`（`DebugMode.swift:14`）、`debugSetAffinity`(:21) |
| 成就 | `herAchievements`（`Achievements.swift:749`）、`markAchievementsSeen`(:764) |
| 周期 | `cycleSeed`（`HerCycle.swift:252`）、`herCycle`(:282)、`cycleRecords`（`CycleEstimate.swift:245`） |
| 内容/立绘 | `episodeCount`（`Eidolon.swift:494`）、`avatarURL(for:)`(:612)、`stand(for:)`(:623)、`characterIDsWithStands()`(:639) |
| 立绘偏好 | `StaticAppearanceSelection.selection/remember`(:25/:33)、`StandOutfits.choice/remember`(:61/:68) |
| 花名册 | `RosterTidy.isPinned/isHidden`(:15/:17) |

核心代码中 `characterID`/`character_id` 共 152 处，集中在 `EidolonTurn`(57)、`Schedule`(52)、`Moments`(46)、`Achievements`(41)、`Gifts`(23)、`CallSession`(22)、`CycleEstimate`(17)、`RetrievalStore`(14)。iOS 侧 183 处、26 个文件（`AppModel`、`ChatStore`、`CallController`、`DebugView`、`MomentsView`、`ScheduleBoardView`、`StatsView` 等）。

> 结论：当前没有「复合身份」的 API 缝；Phase B 要么在 core 全面改签名（`CharacterRef`/`FranchiseID`+`localID`），要么在每个入口从「当前 active franchise」注入后再落库。前者更安全，后者会把隐式全局状态带进并发/后台任务。

### 2.3 模型如何携带角色身份

- `CharacterConfig`（`CharacterConfig.swift:6`）：`id` 是 local id，字段有 `speakers: [String]`、`voiceID`、`photoTag`、`photoLora`、`stand`、`birthday` 等，**没有 `characterKey`/`franchise`**。
- `ChatMessageRecord`（`EidolonTurn.swift:73`）：只有 `id, role("user"/"character"), text, segments, blocks, createdAt, affinityChange, photo, photoTag`。**没有 speaker/participants**；`messages` 表也没有 `speaker_*`。要做多角色同会话，必须新增列并回填（issue #135 已列，属 S4 边界）。
- `ConversationSummary`（`Conversation.swift:5`）：只有 `id/title/createdAt/ended/records/lastPreview/lastAt/isCurrent/hasPhoto`，**不携带 characterID/franchise**；调用方传裸 id 去查。
- `PhotoReference`（`PhotoRecord.swift:38`）：只有 `id/status/reason`；照片没有角色字段。
- `MomentPost`（`Moments.swift:227`）与 `MomentReactionRecord` 都带裸 `characterID`。
- `CallSession` / `call_ends`：通话以 conversation 为容器，`recordCallEnd(conversationID:characterID:…)` 仍额外写裸 `character_id`；统计/成就/最近联系都按裸 id 查。
- `MemoryRecord`（`Memory.swift:6`）：`sourceCharacterID: String?`，注释明确「所有角色共享制作人的记忆」。

### 2.4 `activateContent` 做了/没做什么

`ContentRegistry+Eidolon.swift:97-125`：

**做了**：校验 `Content/<franchise>/current` 存在 → 相对 symlink 写到 `Content/current` → `activeContentFranchise` → `invalidateStandCaches` → 写 app_state `content.activeFranchise`、`content.bundle` → `content = try openContent()` → `installFranchisePrompt()`（进程级）→ 清 `cachedWorld/worldCached`。

**没做**：没有任何用户表写入/回填/过滤；不重建 `current_conversations`；不清理或标记旧 conversation；不处理 `pending_jobs`/`turn_traces`/`turn_debug_snapshots`/`moment_plans`；不重置 `moment_state`；不重算日程周池；不刷新 `CharacterConfig` 缓存以外的 UI 级单例；不清理 iOS 侧每角色 store（`ChatStore`、立绘选择、花名册）。

`AppModel.activateContentPackage`（`AppModel.swift:1782-1797`）同样只做 symlink/内容刷新 + `conversationPath`/`padConversationID` 重置 + `load()`，源码注释直接写「Phase A intentionally does not migrate the user library」。

### 2.5 切包后旧数据在 UI 的可达性（读代码推断）

| UI 面 | 同 local id（A→B） | 不同 local id（A→B） |
|---|---|---|
| 角色列表/聊天入口 | 新企划角色复用旧会话与消息（`conversations(characterID:)` 裸 id） | 旧角色不再出现在 `characters()`，旧会话无入口 → 孤儿 |
| 最近消息/未读 | `latestActivities` 按裸 id 合并，旧活动挂到新角色 | 旧活动不显示（`app.latest[character.id]` 只查当前角色） |
| 朋友圈 | `momentsTimeline` 全量返回；同名文章显示新角色名/头像（`MomentsView:242-244` 有裸 id 回退） | 旧文章仍显示，名字回退为裸 local id，头像缺失 |
| 记忆 | `memories()` 全量；列表显示 `sourceCharacterID`，缺失名字时回退裸 id（`MemoryListView:32`） | 旧记忆仍可编辑/删除，来源显示裸 id |
| 统计 | turns/calls/gifts/heatmap 全量汇总；角色行只列当前角色 | 总量仍包含旧企划，角色维度看不到旧角色 |
| 礼物/背包 | 旧背包按当前 catalog 回填：同名 gift id 共享数量，旧 gift id 不可见 | 旧 gift id 全部不可见（库存仍存在） |
| 成就 | 同名角色进度合并；全局 `COUNT(*)` 含旧企划 | 旧阶段不显示，但全局计数仍包含 |
| 日程/日历 | 周池可能已被旧企划抽走；旧 placement 仍可能出现在日历并给新同 id 角色加好感 | 旧 placement 仍出现在日历（名字按当前 active 解析不到时表现待验证），旧 job 行不可排 |
| 酒吧 | `bar_visits` 与 `bar.facts` 按裸 id 合并 | 旧历史不显示 |
| 调试 | 失败快照按裸 id 回退可见；trace 全局可见 | 旧 trace/快照仍可全局查看与清空 |
| 设置 | 只显示当前包信息；无「当前企划」提示 | 同左 |

### 2.6 `ContentBundleInfo` / `app_state` 与用户数据的关系

- `app_state` 里 `content.packages` 是已安装包数组，`content.activeFranchise` 是当前指针，`content.bundle` 是当前包的 `ContentBundleInfo`（`Eidolon.swift:98-108`、`ContentRegistry+Eidolon.swift:97-125`）。
- `ContentBundleInfo`（`ContentManifest.swift`）只描述**内容包**（格式版本、franchise、contentSetID、embedding、episodes/passages/characters/stands/places 计数、`characterKeys`），**不携带任何用户数据范围或版本**。用户库没有「按 franchise 分区」的元数据，也没有「最后一次迁移源 franchise」标记。
- 当前 active franchise 只在 `app_state` + symlink 两处；`stand.bundle.<franchise>` / `static-stand.bundle.<franchise>` 已按企划分 key，但 `bar.bundle`、`model3d.bundle` 仍是单槽。这给 Phase B 的「v25 迁移默认回填 shiny」提供了依据：旧手册没有 franchise 信息，只能默认 `shiny` 或 `unknown`。

### 2.7 现有测试

- `ContentRegistryTests.twoFranchisesSwitch`（`EidolonCore/Tests/EidolonCoreTests/ContentRegistryTests.swift:15-39`）：同一个默认 `Fixture` 装到 `shiny` 与 `totsulover`，**两个包角色 id 完全相同**（`mano`/`hiori`），但测试只断言 registry/active/symlink/characters 数量，**没有创建任何 conversation/message/memory/affinity**。它能证明 Phase A 的命名空间/切换，不能证明隔离。
- 同文件还有 `autoRouting`（manifest 带 franchise+characterKeys 自动安装激活）、`rejectsOtherKinds`、`characterKey`（`totsulover:sakura` 描述）、`legacyInfoDefaults`。
- `UserSchemaTests` 有 v1→v2、v7、v8→v9、v13→v14、v15、v16 的手工旧库迁移测试；**没有 v24→v25 的用户数据迁移测试**。
- `Fixture.Options` 已支持 `franchise`、`kind`、`characterKeys`、`contentSetID`、`schemaVersion`、`model`、`dimensions` 等，`Fixture.swift:89-141` 固定 `mano`/`hiori`，很适合作为 Phase B「两包同 local id + 真实用户数据」隔离测试的基础。

---

## 3. 删除 / 恢复与内容管理

### 3.1 是否存在删除包 API/UI

**不存在。** `grep -rn "removeContent|uninstall|deleteContent|removePackage|deletePackage|removeBundle"` 在 `EidolonCore/Sources` 与 `EidolonIOS` 均为 0；`ContentRegistry+Eidolon.swift` 只有 `installContent`、`installContentPackage`、`activateContent`、`installedContentPackages` 等。设置页内容包区（`SettingsView.swift:468-536`）只有「当前/切换」和「重新导入内容包」。

### 3.2 设置页当前行为

- 仅当 `app.contentPackages.count > 1` 才显示「内容包」区块；只有一包时完全没有入口。
- 每行：franchise、kind、formatVersion、角色数、剧情节数；当前包显示「当前」，其他包显示「切换」按钮，点击直接 `activateContentPackage`，**没有确认弹窗、没有数据影响提示**。
- 当前包详情：剧情节/段落/角色/地点/旧包立绘/向量模型与维度/schema/内容族/静态立绘/安装时间，以及剧情目录/用语集链接。
- footer：「内容包只带剧情，不含立绘……导入失败时保留当前内容包；对话、记忆和好感度不受影响。」
- 没有包大小、没有删除、没有「当前企划」全局提示条；聊天/角色页没有任何 franchise 文案（`grep franchise EidolonIOS` 只命中设置/`AppModel`/`BundledModel3D.swift:69`）。

### 3.3 `previous` 目录 / 回滚语义

`ContentBundleInstaller.swift:12`：`previous = Content/previous`。`swapIn`（:386-403）在安装时：删除旧 `previous` → `current` 移到 `previous` → staging 移到 `current`；失败时把 `previous` 移回。它只是**单包安装回滚槽**，每个 franchise 根下各有一份，不是跨包/跨版本历史，也不能用来「恢复上一个企划」。

### 3.4 删除包后的用户数据（推断）

- 手动删除 `Content/<franchise>` 目录：`content.packages` 仍保留该包（app_state 没有清理），设置页仍列出；点击切换会在 `activateContent` 的「package root 存在」检查处抛错（`ContentRegistry+Eidolon.swift:97-125`）。没有自动修复/清理逻辑。
- 该 franchise 的用户数据全部留在 SQLite（没有任何级联到内容包）；重新导入同 franchise 后，配置/对话/记忆仍在。若新包角色 id 不同，这些数据变成真正孤儿；若同 id，直接继续复用。
- 当前没有「孤儿数据」命名、列表、清理或导出；只有照片文件级别的 `removeOrphanPhotoFiles`（`PhotoStore.swift:312`）按数据库行判断，和企划无关。

### 3.5 内容管理一致性缺口（本次新发现）

1. **active 包重导入不重开 content DB 句柄（推断）。** `installContent`（`ContentRegistry+Eidolon.swift:19-61`）在 `hadActive==true` 时不会走 `activateContent`，因此不会执行 `content = openContent()`；而 `Eidolon.content` 是惰性缓存（`Eidolon.swift:678-690`）。在 Unix 上旧 SQLite 连接继续指向被 rename 的旧 inode，`characters()` 却读新目录，可能出现「角色列表新、剧情节/检索旧」直到重启或再次切换。
2. **embedding 不匹配在 swap 之后才检查（推断）。** `installer.install` 先完成文件替换（`ContentBundleInstaller.swapIn`），随后 `installContent` 才比较新包的 model/dim 与现有包；不匹配直接 throw，但没有把 `previous` 恢复、也不回滚 `contentPackages` 之外的磁盘状态。设置页 footer 的「导入失败时保留当前内容包」在这一点上不成立。
3. **重导入同 franchise 会覆盖该企划的 `previous`**，旧包只保留一代；没有「内容包历史/回滚到上一版」UI。
4. **同 franchise 重导入可绕过 embedding 一致性检查（推断）。** 校验条件是 `existing.franchise != franchise`（`ContentRegistry+Eidolon.swift:41-47`），所以「当前包自己换一个不同 model/dim 的新版本」会通过；旧 `memory_vectors`/`fact_vectors` 不会按新模型重建，检索时可能混合不同维度/模型的向量。

---

## 4. 中途开发新增风险

### 4.1 Debug 快照与 turn trace

- `turn_debug_snapshots`（v24）持久化：`character_id`、conversation/message id、`status`、`model`、`providerHost`、`sections`（世界书/sheet/记忆/检索原文）、`judge`/`verdict`/`retrieval`、`requests`（完整 prompt messages + raw response）、`toolCalls`、`error`。只保留 20 条/「character+conversation」，但 **没有 franchise 列**。
- `latestFailedDebugSnapshot(characterID:conversationID: nil)` 在无 active conversation 时按裸 `character_id` 取「最近失败」；切包后同 id 的另一企划聊天页可能显示上一企划的失败 prompt（`ChatStore.refreshDebugSnapshots` 的调用路径）。
- `clearDebugSnapshots(conversationID: nil)` 会清空**所有**企划快照（`DebugView.swift:228`「清除全部」）。
- `turn_traces` 的 payload 也含 `characterID` 与完整 prompt；保留是全局最新 N（`TurnTrace.swift:301-305`），`clearTraces` 全清（:275-279），trace 列表全局可见。
- 结论：debug 功能本身在 `app.debugMode` 下才写，但一旦写入就跨企划可读/可清；Phase B 即使只做「用户库」，也应决定是否给这两者加 franchise 或至少按 conversation 派生过滤。

### 4.2 朋友圈 / 照片 / 通话 / 礼物 / 成就

- **朋友圈**：`momentsTimeline` 全量；`moment_state.planned_day` 全局导致切包当天新企划不再规划；`ensureMomentsPlans` 会按 7 天内所有 conversation/call 的裸 id 生成计划；`processMomentPlan` 对「当前 active 里不存在的 id」直接 return（plan 被 `defer` 删除），对同 id 存在则**用新企划角色/世界/记忆生成旧企划计划**。`momentsBadge` 全局未读。
- **照片**：`photos` 无角色/企划列；`User/images/photos` 平铺；`comfy-jobs.json` 只按 photoID；切包后旧照片只能从旧消息进入（不同 id 不可达），没有画廊聚合。照片本身不会「串角色名」，但删除包后成为孤儿文件；`deleteConversation` 才删文件。
- **通话**：`call_ends` 以 conversation 为主、裸 `character_id` 冗余；`latestContact`/stats/成就按裸 id 汇总 → 同名角色跨企划通话合并。
- **礼物**：`gift_balances` 全局，`gift_backpack` 按内容相对 `gift_id`；切包后旧礼物在新 catalog 不可见，同名礼物共享库存；`giveGift` 用当前 catalog + 当前角色 `likedGifts`，不会给旧企划角色送礼（旧角色不可选）。
- **成就**：`achievement_progress`/`achievement_stages` 裸 `character_id`；「全部角色」成就有 sentinel/`affinities` 跨企划计数（`Achievements.swift:487/508`）；`Stats` 的 `COUNT(*)` 与 `achievement_progress='complete'` 全局；`achievements_launched` 全局只 backfill 一次。

### 4.3 日程 / 周期 / 酒吧 / 搭话

- **日程**：`schedule_weeks` 全局周池（首次打开该周的企划决定 job pool）；`weekly_jobs.id` 不含 franchise，跨角色/企划撞 listed id 会 PK 冲突（推断，取决于两个包的 jobs.json 是否复用 id）；`savedPlacements` 全量、`countDoneJobs` 全量加好感；`schedule(characterID:)` 只按裸 id 读自己的 placements。
- **周期**：`cycle_seeds`/`cycle_records` 裸 id；`cycle_settings` 全局开关。同名角色会共用周期种子（同一「身体」），不同企划角色是否应共享是产品决策。
- **酒吧**：`bar_visits` 裸 id；`bar.bundle`/`bar.facts.*`/settings 全局单槽；酒吧是独立内容包，不随内容包切换。
- **搭话**：`reach_outs` 随 conversation；选择用 active `characters()` + 裸 `currentConversationID`；未读按裸 id 汇总；`ReachOut` 是少数按 `source_character_id` 过滤记忆的路径（`ReachOut.swift:350-355`）。

### 4.4 `FranchisePromptContext` 这类进程级全局

- `FranchisePromptContext.current`（`FranchisePrompt.swift:158-179`）在 `activateContent` 时被整体替换（`ContentRegistry+Eidolon.swift:254-256`），是进程级 static；所有 prompt builder 在**构造 prompt 时**读取它（Judge/EidolonTurn/Moments/RetrievalStore/BarPrompt/ProducerProfile/JudgeQuestions/Title，见 b9 摘要行号）。
- 影响：正在进行的 turn、后台 memory/title/judge/moments/photo 任务没有捕获「开始时」的 franchise；若切包发生在它们完成前，后续请求会混入新企划的术语/身份/场景。`pending_jobs` 没有 franchise 字段，重启恢复时也只能读当前 active。
- 同理 `Eidolon.activeContentFranchise` / `content` / `standDirectory` 都是 actor 级单值；切包与并发 turn 之间没有 generation/epoch 校验。

### 4.5 model3d 单槽与静态立绘

- `model3d`：`app_state` 单 key `model3d.bundle`（`Eidolon.swift:363-393`），整个 App 只有一个 3D 模型槽；`BundledModel3D.swift:54-70` 把内置模型硬编码为 franchise `"mltd"` 并追加 alias `"haruka3d"`；`AppModel.has3DModel(for:)`（:2115）只按裸 local id 判断，不校验当前 active franchise。切到别的企划后，同 id 可能错误地挂上 mltd 的 3D 模型。
- 静态立绘：ADR-0038 已按 franchise 分 `Content/<franchise>/stand` 与 `static-stand.bundle.<franchise>`，切换时读 active；这部分 Phase A 已做对。但 `eidolon.staticAppearance` / `eidolon.standOutfits` 的 UserDefaults key 是裸 local id，切包后同 id 复用旧选择。
- 结论：S3 Phase B 是否现在处理 model3d 多槽是决策项；静态立绘按 franchise 的差异已在 Phase A 解决。

### 4.6 检索缓存与全局聚合

- `fact_vectors` 的 scope 是 `"fact:<character.id>"` / `"work"`（`Retrieval.swift:426/450`），entry id 分别是 fact 文本 / world 标题；缓存永不按企划清理。同名 work 标题但不同正文 → 可能复用错误向量（推断）。
- 记忆检索：`memoriesPrompt` 调 `memoryCandidates` 不传 characterID（`Retrieval.swift:365-371`），所有角色的记忆都会进入当前回合的检索；这既是设计（共享制作人记忆）也是切包后的跨企划泄漏面。
- 统计/PlaySummary/日历/成就总览都使用全局 SQL，切包后「总量」包含所有企划；UI 的角色维度只显示当前企划，形成「总数对不上角色明细」的观感。

### 4.7 其它

- **Duo/多窗口 shell**：最近两个 commit（`5e346b24`、`e2ebf3be`）只改 iPhone/Duo 布局，不写用户表；不是 S3 Phase B 的 identity 表面，但切包时 `conversationPath`/`padConversationID` 只清当前 shell 的路径，其它窗口状态未见统一 reset（推断）。
- **公告**：`Server.swift` 的公告是服务端全局，只有单一 `latestSeen` cursor；不涉及用户库/franchise，S3 可忽略。
- **`price_overrides` / `service_calls`**：全局用量/价格，不影响角色身份；若未来统计按企划拆分才需要加列。

---

## 5. 需要用户决策的问题

> 以下每项都只给选项/推荐/理由，不替用户拍板。

### Q1. v25 的范围：只做「身份键」，还是同时做 `conversation_participants` / `messages.speaker`？

- A. **只做 franchise 复合键**（conversations/affinities/current/achievements/cycle/moments 等），不碰 messages 结构。推荐。
- B. 一次纳入 participants 表 + `messages.speaker_franchise/speaker_character`，为 S4 多角色同会话铺路。
- C. 先建 participants 表但 speaker 列留空/可空，分两步回填。

理由：v25 越大，回填/回滚/测试面越大；Phase B 的验收是「两包同 local id 不串数据 + 旧库回填正确」，speaker 属于 S4，可在身份键稳定后单独迁移。若产品近期就要群聊，选 B 可避免二次重建 messages。

### Q2. 旧数据回填默认 `shiny` 的兼容策略

- A. 全部旧行回填 `franchise_id='shiny'`，manifest 可覆盖/迁移时提示。推荐（与 #135 一致，最简单、单角色 golden 不变）。
- B. 回填 `unknown`，UI 单独显示「未归属企划」，允许用户手动指派。
- C. 首次启动让用户选择旧数据归属（默认 shiny，可改）。

理由：当前单包用户几乎都是 shiny 时代数据，A 的破坏面最小；B 更诚实但会让旧会话在默认视图消失；C 交互成本高且难以撤销。

### Q3. 「删除内容包」的语义

- A. **隐藏/可恢复**：删内容与立绘包，registry 移除可见性，用户数据保留为 orphan，重新导入可恢复（#135 用户故事）。推荐。
- B. 物理删除：内容包 + 该 franchise 的全部用户数据，二次确认，不可恢复。
- C. S3 不提供删除，只提供「停用/隐藏」，删除放 S4。

理由：当前没有删除 API，做 B 需要级联清理 15+ 张表与照片/朋友圈文件，风险大；A 与「孤儿数据」概念一致，但需要明确的 orphan UI/清理入口设计。

### Q4. 记忆是全局带来源标签，还是按 franchise 隔离？

- A. **保持全局**，新增 `source_franchise_id`，检索/展示可按当前企划加权或过滤（#135 倾向）。推荐。
- B. 按 franchise 物理隔离：`memories.franchise_id` 并默认只检索当前企划。
- C. 全局共享但默认检索只带当前+unknown，旧企划记忆需手动切换查看。

理由：记忆是「制作人」的跨角色资产，A 最符合现有产品语义；但切包后旧企划记忆仍会进入新回合，需要在 A 下明确「检索是否过滤」。

### Q5. 是否允许两个企划包使用相同 local id 共存？

- A. **允许**，用 `(franchise_id, local_id)` 复合身份，UI 以当前企划为准。推荐（也是 Phase B 测试 fixture 的前提）。
- B. 安装时禁止两个包共享 local id（registry 校验 + 报错），简单但限制内容包自由度。
- C. 允许安装但默认只激活一个，切包时警告「同 id 会共用历史」。

理由：#135 已明确用「两包故意同 local id」做验收；如果选 B，Phase B 的复杂度大降，但内容包生态会被锁死，且无法验证真正的隔离。

### Q6. 全局单例与派生数据（producer_profile / gift_balances / cycle_settings / moment_state / 日程周池 / 成就 all）怎么处理？

- A. **v25 只做「用户库身份」必需项**：conversations/messages/affinities/current/achievements/cycle/moments 等加 franchise；producer_profile、gift_balances、cycle_settings、moment_state 继续全局，日程周池加 franchise 但排在 v25 后半。推荐。
- B. v25 一次性把上述单例全部按 franchise 拆分（含 producer 身份/抽卡/周期开关/朋友圈规划状态）。
- C. 只加 franchise 列但先不切查询，等 S4 再切。

理由：A 能先消除「串角色/串会话」的硬伤，避免 v25 迁移一次改太多表；但「日程周池」是用户可感知的功能缺口，建议不晚于 v25 的同一批次。

### Q7. 现在是否处理 model3d 多槽？

- A. **现在不改**，保持单槽；3D 仍是实验分支，先在内容包声明/UI 上标注「仅当前企划」。推荐。
- B. v25 同步做 `model3d.bundle.<franchise>` 多槽 + 按 active 读取。
- C. 彻底后置到 3D 合并（feat/mltd-3d-stand）时再做，S3 只保证静态立绘正确。

理由：model3d 目前是全局单槽且带 mltd 内置回退，Phase B 的验收不依赖 3D；现在做多槽会增加「同一角色两套 3D」的资产/加载复杂度。

### Q8. debug 快照 / turn_traces 是否纳入 v25？

- A. **纳入**：`turn_debug_snapshots` 加 `franchise_id`，`turn_traces` 加 franchise 或按 conversation 过滤；查询/保留/清空按企划。推荐。
- B. 不纳入 v25，只把查询改成经 conversation 派生（`conversation_id` 已能定位 franchise），保留/清空暂时全局。
- C. 仅 debug 功能处理：快照加 franchise，trace 保持全局。

理由：debug payload 含完整 prompt 与角色 id，是审计/隐私面；A 最干净，但 `turn_traces` 是 debug-only、量小，B 可以少改一张表。需要用户决定「debug 数据是否算用户库」。

---

## 6. 建议的第一轮 grilling 议题（供 lead 使用）

1. 先确认 **v25 的验收句式**：是「两包同 local id 的对话/好感/记忆互不串」，还是还要包含「切包后旧朋友圈/统计不混」？后者会把 moments/stats/schedule 拉进 v25。
2. 确认 **「旧数据默认 shiny」是否可接受**：如果用户曾在旧版本给非 shiny 包写过数据（当前代码不可能，但历史分支可能有），回填策略需要例外。
3. 确认 **删除包的「可恢复」定义**：要恢复到什么程度（配置/对话/记忆/照片/快照全部？），以及 orphan 数据是否会在设置页出现。
4. 确认 **同 local id 共存**是否真的允许：若是，必须同时接受「日程周池/全局单例」的语义要么按企划、要么明确共享。
5. 确认 **记忆检索是否跨企划**：现在 `memoriesPrompt` 不传 characterID，Phase B 后是否仍保持。
6. 确认 **debug 数据是否纳入用户库迁移**：涉及 prompt/隐私与保留策略。
7. 确认 **内容包切换的 UI 语义**：是否要确认弹窗、当前企划提示条、切换后旧数据入口（孤儿查看）。
8. 确认 **model3d/静态立绘**在 S3 的边界：静态立绘已按 franchise，3D 是否明确「S3 不做」。

---

## 7. 来源

### 代码（本 worktree，HEAD `e2ebf3be`）

- `EidolonCore/Sources/EidolonCore/UserSchema.swift`：版本 :7；39 张表 `CREATE TABLE` 行号见 §1；迁移注册 :11–:549。
- `EidolonCore/Sources/EidolonCore/ContentRegistry.swift:5-15`（CharacterKey）、:19-29、:32-47。
- `EidolonCore/Sources/EidolonCore/ContentRegistry+Eidolon.swift:10`（installedContentPackages）、:19-61（installContent）、:67-91（installContentPackage）、:97-125（activateContent）、:217-245（installStaticStand）、:254-256（FranchisePrompt 安装）。
- `EidolonCore/Sources/EidolonCore/ContentBundleInstaller.swift:12`（previous）、:386-403（swapIn）。
- `EidolonCore/Sources/EidolonCore/Eidolon.swift:11-25`（Location）、:472-480（characters）、:528+（latestActivities）、:612/:623/:639（avatar/stand）、:363-393（model3d）、:678-690（openContent/contentDatabase）。
- `EidolonCore/Sources/EidolonCore/EidolonTurn.swift:73-103`（ChatMessageRecord）、:119（sendTurn）、:197/:204/:210、:928-984（current conversation 读写）。
- `EidolonCore/Sources/EidolonCore/Conversation.swift:5-18`、:237-320、:377-415、:417-454。
- `EidolonCore/Sources/EidolonCore/TurnDebug.swift:48-120`（snapshot 字段）、:183（保留数）、:186-228（写入/保留）、:248-280（failed 回退）、:300-315（清空）。
- `EidolonCore/Sources/EidolonCore/TurnTrace.swift:236`（turnTraces）、:275-279（clearTraces）、:301-305（全局保留）。
- `EidolonCore/Sources/EidolonCore/Moments.swift:227`（MomentPost）、:292-370（timeline）、:530（runMomentsDue）、:560-660（plans）、:781-801（active ids）、:887-940（process plan）、:1310-1328。
- `EidolonCore/Sources/EidolonCore/Memory.swift:6-9`、:162-180、:185-220、:450-500；`Retrieval.swift:365-371`、:426/:450；`RetrievalStore.swift:56-116`、:121-165。
- `EidolonCore/Sources/EidolonCore/Schedule.swift:509-536`、:618-680、:719-748、:750+、:893-940。
- `EidolonCore/Sources/EidolonCore/CalendarPage.swift:150-230`（events）。
- `EidolonCore/Sources/EidolonCore/Stats.swift:170-280`。
- `EidolonCore/Sources/EidolonCore/Gifts.swift:176-210`、:443-455；`Achievements.swift:269-409`、:487-585；`HerCycle.swift:245-282`；`ReachOut.swift:327/350-355`；`BarRecords.swift:83-222`。
- `EidolonCore/Sources/EidolonCore/CharacterConfig.swift:6-...`；`PhotoRecord.swift:38`；`FranchisePrompt.swift:158-179`。
- `app_state` / UserDefaults 键清单：见 §4.4/§5（grep 结果）。
- `EidolonCore/Tests/EidolonCoreTests/ContentRegistryTests.swift:15-39`、`Fixture.swift:89-141`、`UserSchemaTests.swift`。

### iOS

- `EidolonIOS/App/AppModel.swift:1013`、:1061、:1406-1415、:1782-1797、:2206-2280。
- `EidolonIOS/Features/Settings/SettingsView.swift:468-536`、`SettingsCategory.swift:30-31`。
- `EidolonIOS/Features/Moments/MomentsView.swift:242-244`；`EidolonIOS/Features/Memories/MemoryListView.swift:32`；`EidolonIOS/Features/Calendar/CalendarView.swift:58`。
- `EidolonIOS/Runtime/BundledModel3D.swift:54-70`；`EidolonIOS/App/AppModel.swift:2049/2092/2115`。
- `EidolonIOS/Core/ChatSettings.swift`（UserDefaults key 清单，见 §4.4）。

### 文档 / issue / commit

- `docs/research/s3-readiness-2026-11-14.md`（350 行，旧「五张表」报告）。
- `docs/adr/0036-s3-phase-a-content-registry.md`（Phase A 边界与「Phase B 完成前不把多包切换作为默认行为」）。
- `docs/adr/0038-per-franchise-stand-packages.md`（静态立绘按 franchise）。
- `docs/adr/0039-turn-debug-snapshot.md`（v24 debug 快照）。
- `docs/adr/0040-franchise-user-identity.md`（per-franchise prompt/identity；user profile 隐藏）。
- `docs/roadmap.md:11`（S3 状态，v24 表述已过期）；`:29`（M3 的 Phase B 条目）。
- GitHub issue `JackLin513/eidolon-sc-ios#135`（S3 Phase B 规格；本次只读抓取）。
- commits：`b3fe38d3`、`dbdca70b`（Phase A）；`33b55c31`（franchise user identity）；`828070a1`（debug snapshots）；`e2ebf3be`（当前 HEAD）。

---

## 8. 推断 / 未验证清单

- **未读取真机/模拟器用户库**：所有「历史数据」只按 schema 起始版本标注，实际行数未知；`User/eidolon.sqlite` 是否已有大量数据未验证。
- **未实际运行切包**：§2.5 的 UI 可达性、§4.2 的跨企划显示均来自读代码，未在 App 中复现。
- **删除包后行为**：§3.4 的「registry 仍列出、切换抛错」是代码路径推断；未实际删除目录验证。
- **active 包重导入的 stale content DB**：§3.5-1 为推断（依赖 `Eidolon.content` 惰性缓存与 SQLite inode 语义），未复现。
- **embedding 不匹配的磁盘回滚**：§3.5-2 为推断（`installer.install` 在检查前已 swap），未复现。
- **`fact_vectors` 同名 work title 复用错误向量**：§4.6 为推断；需实际造两个同标题不同正文的包验证。
- **`FranchisePromptContext` 在飞行中切包**：§4.4 为推断；未构造后台任务与切包竞态。
- **`weekly_jobs` PK 冲突**：§4.3 需两个包的 jobs.json 复用同一 listed id 才触发；未实际造包验证。
- **`processMomentPlan` 旧 plan 行为**：§4.2 的「id 不存在则删 plan、同 id 则用新角色生成」来自 `guard` + `defer` 阅读，未运行验证。
- **Duo/多窗口切包 reset**：§4.7 为推断，未在 Duo 模拟器验证。
- 本报告没有写入任何代码、issue 或配置；唯一写入是本文件。
