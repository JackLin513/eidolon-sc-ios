# 01: 看板和运行记录不再有每日任务

**What to build:** 管理者这边先把每日任务拆掉，用户那边暂时照旧（任务照样做、照样到账，只是不再留运行记录）。做完一项任务不再写 `daily_task` 种类的运行记录；运行记录的种类里去掉 `daily_task`。启动时一次删掉 `activity_records` 里 `kind = 'daily_task'` 的行和 `record_rollups` 里同种类的汇总行，重复启动、行为零都不报错；成就的记录、别的种类的记录和汇总行都不动。看板接口的「好感度」那组：「每日任务和成就」那一小节改回「成就」，去掉 `daily_tasks` 和它的筛选，成就的几格照旧；看板不为旧记录留特判。前端看板：`Dashboard` 类型去掉 `daily_tasks`，那一小节的标题改回「成就」、去掉三格，「好感度」标签的显示条件去掉对 `daily_tasks` 的依赖，保留日程那一块加的条件（好感度关着、日程开着时照样显示）。配置页「好感度和礼物」卡的说明去掉「每日任务」半句。先对照当前的 main 找东西在哪：玩法页那一块搬过每日任务的位置，日程那一块改过看板的「好感度」标签；按「拆什么」找，不按规格写的位置找。见规格「后端删什么」的迁移、「前端」的看板一段、Testing Decisions。

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] 做完任务（一个回合、送一件礼、十个回合）仍到账，但库里不再多出 `daily_task` 的运行记录
- [ ] 迁移：带着旧 `daily_task` 记录和它的汇总行的库启动后，这些行没了，成就记录、回合和通话记录、别的汇总行都在；再启动一次不报错（先例 `test_activity_rollups.py`、`test_achievements_launch.py`）
- [ ] 看板接口没有 `daily_tasks`；好感度开着时「好感度」那组有「成就」小节、几格照旧；好感度关着、日程开着时那组照样有日程那一格（先例 `test_affinity_dashboard.py`、`test_achievements_dashboard.py`、`test_reach_outs_dashboard.py` 里引用 `daily_tasks` 的随之改）
- [ ] 删 `test_daily_tasks_dashboard.py`；`test_daily_tasks.py` 里断言运行记录的那几条随之改或删
- [ ] 前端 `lib/dashboard` 测试：没有 `daily_tasks`，「好感度」标签的显示条件照新的来
- [ ] 配置页「好感度和礼物」卡的说明不提每日任务
- [ ] 看板「成就」小节和配置页说明用构建版前端看一眼（`docs/agents/local-acceptance.md`）
- [ ] pyright、ruff、前端类型检查和 lint 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [ ] 票收尾：给票 02 的交接写进票 02 的 Comments；推分支开 draft PR 让 CI 跑；跑 `code-review`
