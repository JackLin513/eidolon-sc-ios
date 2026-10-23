# 01: 看板和运行记录不再有每日任务

**What to build:** 管理者这边先把每日任务拆掉，用户那边暂时照旧（任务照样做、照样到账，只是不再留运行记录）。做完一项任务不再写 `daily_task` 种类的运行记录；运行记录的种类里去掉 `daily_task`。启动时一次删掉 `activity_records` 里 `kind = 'daily_task'` 的行和 `record_rollups` 里同种类的汇总行，重复启动、行为零都不报错；成就的记录、别的种类的记录和汇总行都不动。看板接口的「好感度」那组：「每日任务和成就」那一小节改回「成就」，去掉 `daily_tasks` 和它的筛选，成就的几格照旧；看板不为旧记录留特判。前端看板：`Dashboard` 类型去掉 `daily_tasks`，那一小节的标题改回「成就」、去掉三格，「好感度」标签的显示条件去掉对 `daily_tasks` 的依赖，保留日程那一块加的条件（好感度关着、日程开着时照样显示）。配置页「好感度和礼物」卡的说明去掉「每日任务」半句。先对照当前的 main 找东西在哪：玩法页那一块搬过每日任务的位置，日程那一块改过看板的「好感度」标签；按「拆什么」找，不按规格写的位置找。见规格「后端删什么」的迁移、「前端」的看板一段、Testing Decisions。

**Blocked by:** None (can start immediately)

**Status:** done

- [x] 做完任务（一个回合、送一件礼、十个回合）仍到账，但库里不再多出 `daily_task` 的运行记录
- [x] 迁移：带着旧 `daily_task` 记录和它的汇总行的库启动后，这些行没了，成就记录、回合和通话记录、别的汇总行都在；再启动一次不报错（先例 `test_activity_rollups.py`、`test_achievements_launch.py`）
- [x] 看板接口没有 `daily_tasks`；好感度开着时「好感度」那组有「成就」小节、几格照旧；好感度关着、日程开着时那组照样有日程那一格（先例 `test_affinity_dashboard.py`、`test_achievements_dashboard.py`、`test_reach_outs_dashboard.py` 里引用 `daily_tasks` 的随之改）
- [x] 删 `test_daily_tasks_dashboard.py`；`test_daily_tasks.py` 里断言运行记录的那几条随之改或删
- [x] 前端 `lib/dashboard` 测试：没有 `daily_tasks`，「好感度」标签的显示条件照新的来
- [x] 配置页「好感度和礼物」卡的说明不提每日任务
- [x] 看板「成就」小节和配置页说明用构建版前端看一眼（`docs/agents/local-acceptance.md`）
- [x] pyright、ruff、前端类型检查和 lint 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 票收尾：给票 02 的交接写进票 02 的 Comments；推分支开 draft PR 让 CI 跑；跑 `code-review`

## Comments

### 实现说明（票 01）

- 后端：`happenings.write_records` 不再写每日任务的运行记录；`ActivityLog.daily_task_done` 删掉，`RecordKind` 去掉 `daily_task`。`Rewarded.daily_tasks` 还在算（任务照样到账），只是没人读去写记录，票 02 连同它一起删。
- 迁移：`activity._forget_daily_tasks`，在 `_open_rollups` 里建完汇总表之后、`_roll_up_all` 之前跑。删 `activity_records` 的那句只在有 `daily_task` 行时才发：测试里的库可能没有 `users` 表，`REFERENCES users(id)` 会让 DELETE 报错。测试在 `backend/tests/test_daily_tasks_retired.py`。
- 看板：`dashboard.py` 去掉 `daily_tasks` 和 `section_shown`；好感度开着，或者范围内有成就解锁，就有 `achievements`。
- 前端：`Dashboard` 去掉 `daily_tasks`，`DailyTasksSection`、`dailyTaskTiles` 删掉。`dashboardTabs` 的条件改成 affinity、achievements、scheduled_this_week 三者有一个不为 null，原来对 `daily_tasks` 的依赖换成了和它同时出现的 `achievements`。组件改名 `AchievementTiles`，文案键 `tasksAndAchievements` 改名 `achievements`。配置页「好感度和礼物」说明改成「成就不出现也不记进度」。
- 验收：本地库原有 7 条 `daily_task` 记录、14 份汇总，用这个分支起后端以后全没了，其他种类的数目不变。构建版看板「好感度」标签里「成就」三格后面接「日程」那一格。配置页说明的字在页面上核对过。
- 审查后的判断题，没改：`_forget_daily_tasks` 每次启动都跑，`activity_records` 和 `record_rollups` 的 kind 上没有索引，迁移完以后每次启动各扫一遍表。90 天的量很小，文件里别的迁移（`_forget_own_llms`）也是每次启动都跑，所以没加「跑过一次」的标记。

