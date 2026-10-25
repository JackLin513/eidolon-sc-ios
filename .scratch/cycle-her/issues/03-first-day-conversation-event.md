# 03: 第一天的对话事件

**What to build:** 她经期里用户第一次来，打字或在通话里说第一句话之前，对话里留下一条「{她}好像从前天起就不太舒服」。这条事件只给用户看，她不知道。**对话事件**多一种 `unwell`，记下时存两样，之后不再变：这次经期的第一天（日历日），以及它比记下那天早几天（从 0 起）。**什么时候记**：用户在她这次经期里的第一个回合之前记，和这个回合在同一个写事务里，和其他事件一样排在它前面。「这次经期里还没有过」是指：这个用户和这位角色的任何对话里，都没有第一天等于这次经期第一天的 `unwell` 事件。她的搭话、只打开对话页、送礼都不触发。整个经期没有回合就错过，以后也不补。任一开关关着时不记；经期中途打开开关后的第一个回合照样记。**措辞**：早 0、1、2 天分别写「从今天起 / 从昨天起 / 从前天起」，3 天及以上写日期「从 10月21日 起」，名字照其他对话事件用的那个。**显示**：照现有对话事件的分隔线（两边细线，中间图标、一句话、时间）。图标在对话事件图标那一组里加一个中性的 Lucide 图标，表示「不太好」，不用她的颜色、不用心形。对话列表的「最后一句」照样显示这句。通话层照旧不显示对话事件。**不告诉她**：给她拼对话记录时跳过这种事件。词汇表「对话事件」那条的列举里加上「她不太舒服了」，并写明这一种只给用户看、她之后的回复不知道（调 `domain-modeling`）。这条事件不进记忆、不经过判断、不计入限额，随对话一起导出、导入、删除。**数据包**升到格式 3：格式 3 的对话可以带 `unwell` 事件，格式 1、2 照旧能读。周期页那份规格会在同一个格式 3 里再加「周期记录」，所以数据包格式文档只写这一半。见规格「第一天的对话事件」「数据包」和 Testing Decisions。

**Blocked by:** 01

**Status:** done

- [x] 经期第 3 天的第一个回合前有一条，之后的回合不再有；换一个对话、或者在通话里先开口，这次经期也只有一条
- [x] 措辞四种都对：今天、昨天、前天、日期
- [x] 只搭话、只送礼时不记；整个经期没有回合时，下一次经期照常记新的一条；任一开关关着时不记
- [x] 给她的对话记录里没有这条，她读到的提示词里也没有（先例 `test_conversation_events.py`）
- [x] 数据包导出为格式 3，`unwell` 事件导出再导入后不变；格式 2 的包照旧能导入（先例 `test_data_package_conversations.py`）
- [x] 前端：这种事件的那句（四种措辞）、图标、列表的「最后一句」，用 `lib/` 的纯函数测
- [x] 词汇表「对话事件」开了例外；`docs/data-package-format.md` 写上格式 3 的这一半
- [x] 本地构建版上用 Playwright 看：用开发口子让她进经期第 3 天，打一个回合，看到对话里的分隔线和列表的最后一句；通话层里不显示
- [x] pyright、ruff、前端类型检查和 lint 都过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 票收尾：推一次让 CI 跑、跑 `code-review`

## Comments

### 票 01 交接

- 这次经期的第一天从 `Cycles.her_day(...)` 返回的 `Period.first_day` 拿。开发口子强制「经期第 N 天」时 `first_day` 按当天往回推 N−1 天，强制着过夜会挪一天，验收时同一天里做完。
- 测试里要她在经期：`tests/test_her_days.py` 的 `a_noon_when`（拨假时钟）和 `a_key_when`（时钟拨不动时换密钥）；`conftest` 默认 `cycles=False`，要自己打开。

### 票 02 交接

- 入口 `Cycles.her_day(user_id, character_id, at, timezone)` 现在是异步的，自己看部署者和用户两个开关（用户开关读表 `cycles_off`），`user_on` 参数去掉了；返回 None 就是「不受周期影响」，不用另判开关。
- 它在里面 `await self._db.read(...)`，所以不能在写事务的函数里调：在回合的写事务之前算好她今天在哪（连同 `Period.first_day`），再把结果带进事务。
- 测试里要她在某一天：用 `tests/test_her_days.py` 的 `on_a_day`（先注册制作人、找好日子，再用拨到那天的时钟登录）；直接拨 `FakeClock` 跨过 30 天会话就过期，返回 401。用户关开关：`tests/test_cycles_switch.py` 的 `switch`。

### 实现说明（票 03）

- **后端**：`conversation_events` 多两列 `first_day`、`days_ago`（旧库补列）；`EventKind` 多 `unwell`；`ConversationEvent`、`KeptEvent` 带这两样，`shown()` 只在 `unwell` 上给出。新函数 `store.add_unwell`：在回合的写事务里、`add_turn` 之前调，跨这个用户和这位角色的所有对话查有没有同一个 `first_day` 的 `unwell`，没有才记。`ConversationEngine` 在写事务前算好 `her_day`（提示词和记事件共用这一次），`_record` 返回记下的事件，`TurnDone` 多 `unwell`（打字的流和通话的数据通道都带）。列表的「最后一句」是它时也带上 `first_day`、`days_ago`。
- **排序**：事件时刻取用户说话时刻（`said_at`）减 1 微秒，这样 `read_record` 和列表 `_last` 的现有规则不改就排在这个回合前面。没改「同一时刻的事件排在用户的话前面」这条通用规则，是因为 Windows 上粗时钟可能让 `ended` 和 `said_at` 撞在同一刻，改了会把它挪到回合前面。
- **不告诉她**：`store.told_her(entry)` 一处判断；`narrations`、`_since_last_turn`、对话标题读的记录都用它跳过。
- **对话标题**：起标题时也跳过这种事件（判断题：规格没写；不跳的话 `_event_line` 会把它当成送礼）。
- **数据包**：`FORMAT = 3`、`UNWELL_SINCE = 3`；`PackagedEvent` 多可选的 `first_day`（只认 `YYYY-MM-DD`）、`days_ago`（≥ 0），只在 `unwell` 上有、它也必须有；格式 3 之前的包里有 `unwell` 当坏包。前端 `lib/dataPackage.ts` 的 `FORMAT` 同步成 3。
- **前端**：那句话挪进 `lib/conversationEvents.ts`（`eventText`、`unwellOf`、`Unwell`），`EventIcon.tsx` 只留图标表；图标 `UnwellIcon` = Lucide `CloudDrizzle`。`conversationLog` 收到带 `unwell` 的 `done` 时把它插到这个回合的用户那句前面，不刷新就看得到。
- **验收**（本地构建版、Playwright，开发口子强制经期第 3 天）：打一个回合后对话里出现「櫻木真乃好像从前天起就不太舒服」的分隔线，刷新后仍是一条；记录顺序 `unwell, user, character`；通话层里没有它。列表的最后一句是她的回复，不是这条事件：它总记在回合之前，正常走不到「最后」，只有导入的包把它放在最后时才会显示（后端有测试）。
- **审查后的判断题（没改）**：后端 `first_day`、`days_ago` 没像前端那样收成一个类型（Data Clumps）；`DESIGN.md`「对话事件」那条没加这一种的图标和文案，规格写明 `DESIGN.md` 归周期页那份规格。
- `test_call_turns.py::test_each_segment_of_each_reply_goes_to_tts_under_its_numbers` 在 affected-tests 的 16 进程并行下失败过一次（两句之间的 `SleepFrame(0.5)` 被挤掉），单独和 4 进程重跑 3 次都过；基点 36366d8 上用同一组 16 个测试文件 `-n auto` 跑两次也都这样失败，是原有的、随负载出现的偶发失败，和这张票无关。

