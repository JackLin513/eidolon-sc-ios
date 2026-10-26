# 09: 限额、准入、运行记录和看板

**What to build:** 光顾跟文字回合一样管得住：
- **限额**：「光顾」有自己的每小时次数，默认 5 次，不占文字回合和通话的次数。环境变量、后台限额卡都能改；管理者可以在某位用户的页面上单独设：数字、不限或 0。用了自带 LLM 的不计数，只记下来。进门那次计一次，重试、「再试一次」、重写点单都不再计。第一次调用彻底失败、一句也没写出来就结束的，这次退回。超了回 429，带什么时候能再来。
- **准入**：照 `Admissions` 加一种 `visit`，**不检查冷却**。自带 LLM 的钥匙照文字回合拿。
- **运行记录**：每次光顾一条 `visit`，结束时写。这次几次调用的服务调用都挂在它下面，花费和服务状态跟着它走。
- **看板**：「用量」加一小节「酒吧」：光顾了几次、玩完几次、失败几次。

见规格「限额和准入」「运行记录和看板」和票 09、10 的答案。

**Blocked by:** 05

**Status:** done

- [x] `usage` 加一种 `visit`。`user_limits` 加一列 `visits_per_hour`，照 `photos_per_hour` 那样加列，旧库能自动补上。新加环境变量 `EIDOLON_VISITS_PER_HOUR`，默认 5，`.env.example` 也补上。实时配置的限额项加「每小时光顾次数」。`OverLimit` 的名字表加「光顾」。
- [x] 后台：限额卡加「光顾 / 小时」。管理者的用户页上，单独设的限额多这一项（前端 `adminUsers`、`adminConfig` 的测试跟着改）。
- [x] 准入：先拿钥匙、开运行记录，再占一次限额；超了就记成被拒，回 429。冷却中照样放行。带了自带 LLM 的用它的钥匙，思考强度用用户自己设的文字回合那一项。
- [x] 运行记录：`RecordKind` 加 `visit`，一次光顾一条，结束时写，记 `character_id`、`own_keys`。这一张里能造出的结果：玩完 `success`、离开和被新光顾顶掉 `left`、被拒 `rejected`；`failed` 和作废留给票 10。不记台词和判定。`TURNS_AND_CALLS` 不含它，管理者用户页的「用了多少」照旧。
- [x] 看板：「用量」里一小节「酒吧」，三个数是光顾了几次（不算被拒的）、玩完几次、失败几次，从汇总好的格子里取，不新增写入。酒吧开着、或者这段时间里有过光顾才给，否则为 null。前端的 `lib/dashboard` 和「用量」标签画出这一小节。
- [x] 测试（先例 `test_rate_limit.py`、`test_exempting_keys.py`、`test_admin_users.py`、`test_own_llm.py`、`test_llm_effort.py`、`test_reach_outs_dashboard.py`、`test_activity_records.py`、`test_activity_rollups.py`）：
  - 第 6 次进门 429，带上时刻；
  - 中途离开的照常计；
  - 自带 LLM 的不计数，但记下了；
  - 管理者单独设的生效（数字、不限、0）；
  - 不占文字回合和通话；
  - 冷却中能进门；
  - 自带 LLM 的钥匙和思考强度；
  - 每种结果各一条运行记录，服务调用挂在下面；
  - 看板三个数，关着又没有记录时为 null。
- [x] 把 GLOSSARY「限额」「运行记录」「看板」和实现对一遍。pyright、ruff 通过，前端类型检查和测试通过；提交前跑 affected-tests。

## Comments

### 票 05 交接

- 现在没有准入：钥匙在 `bar._call` 里每次调用 `own_keys.for_turn(brought)` 拿、写完 `keys.release()`；进门和上一杯的正文都带 `own_keys`。没有运行记录，也不占限额。服务调用照常被 `metered_llm` 记下，但不挂在任何记录下面。
- 「部署者没有对话模型」现在不存在（`CHAT_LLM_*` 必填），票 05 的那一条落到这里的「限额设成 0 时只能用自带密钥」。
- 结束的地方：玩完在 `_call` 里 `yield VisitDone()` 之前；离开是 `Bar.leave`；被顶掉是 `Bar.enter` 里 `self._visits[user_id] = visit` 那一刻（旧的那次没有显式结束）。

### 票 06 交接

- 名字检查不过时，`bar._rewritten` 用同一把钥匙（`keys.llms.chat`）再调一次，只重写点单句。这次服务调用也要挂在这次光顾的运行记录下面，但不占限额（规格「重写点单都不再计」）。

### 实现说明（票 09）

- **限额**：`usage.UsageKind` 加 `visit`，`user_limits` 加 `visits_per_hour` 列（`_open` 和照片那列一起补），`UserLimits.visits_per_hour`；`config.UsageLimits.visits_per_hour`（`EIDOLON_VISITS_PER_HOUR`，默认 5）；`live_config` 限额项加「每小时光顾次数」；后台两处 `LimitsInput` 各加一项；`OverLimit` 说「光顾」。超了走 `app.py` 原有的 429 处理，带 `retry_at` 和 `Retry-After`。
- **准入**：`Admissions.visit(user_id, character_id, brought)`，钥匙照 `for_turn`（自带 LLM 的用它的 text 设置，思考强度就是文字回合那一项），不查冷却。`_COUNTED["visit"]` 是 success、left、failed；`Admission.settle` 多一个 `given_back`，退回不只看结果。`Bar.enter` 先抽出今天是谁（不耗随机数，或者当天玩完后抽一次），再过准入，然后抽其余的（`Bar._drawn`）。抽的时候出错记 `failed` 并退回；页面断开记 `left`。
- **钥匙**：进门时拿一次，持有到这次光顾结束，跟通话一样。每次调用（包括重写点单）都用 `visit.admission.llms.chat`，在 `visit.admission.recording.current()` 里跑，服务调用都挂在这条运行记录下面。**判断题**：所以 `POST .../serves` 的正文不再带 `own_keys`（`ServeInput` 去掉了这一项，带了也会被忽略）。规格「接口」那一句已经改了。这样做，免不免限额在进门时就定下，和「进门那次计一次」对得上；但用户自带的 key 在两次请求之间也留在内存里。ADR-0017 要补一句，交给票 12。
- **结算**（`bar.py`）：`_over(visit, result)` 先移出「进行中」，再结算。结算放在一个受保护的任务里（`_settling`），等的那边被取消也照样写得进去，`Bar.aclose` 等它们写完；后端关闭时，还在进行的光顾按 `left` 结掉。`BarCall` 包着每次调用的事件，`bar_api._CallResponse` 照 `_TurnResponse` 的做法在响应结束时关掉它，正文没开始读就断开的也算。她的台词还在写（`step == "writing"`）时关掉，就按 `left` 结（`_left_off`）。玩完是在写光顾记录之前就移出「进行中」，所以写库期间来的离开回 410，不会把这次记成 `left`。
- **运行记录**：`RecordKind` 加 `visit`，`OWN_LLM_KINDS`（turn、visit）记的是自带 LLM，不进 `TURNS_AND_CALLS`，所以管理者用户页的「用了多少」、活跃用户、趋势都不算它。
- **看板**：`dashboard.bar` 从 `record_rollups` 里取 visit 那几格：`visits`（不算 rejected）、`done`、`failed`；`config.bar_on` 或范围内有记录时才给。前端是 `lib/dashboard.barTiles` 和「用量」标签里的 `BarTiles`。
- **前端限额**：`LIMIT_FIELDS` 加 `visits_per_hour`；`AdminUserLimits.visits_per_hour`，`limitsInput` 多一个参数，`describeLimits` 单独设了时接「· 光顾 …」，`UserLimitsDialog` 多一项「每小时的光顾次数」。
- **超出票面的**：现在一次调用失败就结束这次光顾（票 05 的做法），所以已经会出现 `failed`。第一次调用一句没写出来就失败的会退回（`_given_back`），测试在 `test_bar_activity.py`。票 10 改「停在调用之前」时要接着用这条规则。
- 冷却中能进门：`test_bar_draws.py::test_she_comes_in_a_cooldown_cold_with_the_producer` 现在也走准入。
- **审查里没改的判断题**：管理者单独设的三档参数化（票里点名要的）没并；两条自带 LLM 的测试一条看用量、一条看记录，没合并；`usage.py` 里按种类分的三张表、前端 `limitsInput` 四个并排的参数都没重构。
