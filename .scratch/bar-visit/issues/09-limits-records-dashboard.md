# 09: 限额、准入、运行记录和看板

**What to build:** 光顾跟文字回合一样管得住：
- **限额**：「光顾」有自己的每小时次数，默认 5 次，不占文字回合和通话的次数。环境变量、后台限额卡都能改；管理者可以在某位用户的页面上单独设：数字、不限或 0。用了自带 LLM 的不计数，只记下来。进门那次计一次，重试、「再试一次」、重写点单都不再计。第一次调用彻底失败、一句也没写出来就结束的，这次退回。超了回 429，带什么时候能再来。
- **准入**：照 `Admissions` 加一种 `visit`，**不检查冷却**。自带 LLM 的钥匙照文字回合拿。
- **运行记录**：每次光顾一条 `visit`，结束时写。这次几次调用的服务调用都挂在它下面，花费和服务状态跟着它走。
- **看板**：「用量」加一小节「酒吧」：光顾了几次、玩完几次、失败几次。

见规格「限额和准入」「运行记录和看板」和票 09、10 的答案。

**Blocked by:** 05

**Status:** ready-for-agent

- [ ] `usage` 加一种 `visit`。`user_limits` 加一列 `visits_per_hour`，照 `photos_per_hour` 那样加列，旧库能自动补上。新加环境变量 `EIDOLON_VISITS_PER_HOUR`，默认 5，`.env.example` 也补上。实时配置的限额项加「每小时光顾次数」。`OverLimit` 的名字表加「光顾」。
- [ ] 后台：限额卡加「光顾 / 小时」。管理者的用户页上，单独设的限额多这一项（前端 `adminUsers`、`adminConfig` 的测试跟着改）。
- [ ] 准入：先拿钥匙、开运行记录，再占一次限额；超了就记成被拒，回 429。冷却中照样放行。带了自带 LLM 的用它的钥匙，思考强度用用户自己设的文字回合那一项。
- [ ] 运行记录：`RecordKind` 加 `visit`，一次光顾一条，结束时写，记 `character_id`、`own_keys`。这一张里能造出的结果：玩完 `success`、离开和被新光顾顶掉 `left`、被拒 `rejected`；`failed` 和作废留给票 10。不记台词和判定。`TURNS_AND_CALLS` 不含它，管理者用户页的「用了多少」照旧。
- [ ] 看板：「用量」里一小节「酒吧」，三个数是光顾了几次（不算被拒的）、玩完几次、失败几次，从汇总好的格子里取，不新增写入。酒吧开着、或者这段时间里有过光顾才给，否则为 null。前端的 `lib/dashboard` 和「用量」标签画出这一小节。
- [ ] 测试（先例 `test_rate_limit.py`、`test_exempting_keys.py`、`test_admin_users.py`、`test_own_llm.py`、`test_llm_effort.py`、`test_reach_outs_dashboard.py`、`test_activity_records.py`、`test_activity_rollups.py`）：
  - 第 6 次进门 429，带上时刻；
  - 中途离开的照常计；
  - 自带 LLM 的不计数，但记下了；
  - 管理者单独设的生效（数字、不限、0）；
  - 不占文字回合和通话；
  - 冷却中能进门；
  - 自带 LLM 的钥匙和思考强度；
  - 每种结果各一条运行记录，服务调用挂在下面；
  - 看板三个数，关着又没有记录时为 null。
- [ ] 把 GLOSSARY「限额」「运行记录」「看板」和实现对一遍。pyright、ruff 通过，前端类型检查和测试通过；提交前跑 affected-tests。

## Comments

### 票 05 交接

- 现在没有准入：钥匙在 `bar._call` 里每次调用 `own_keys.for_turn(brought)` 拿、写完 `keys.release()`；进门和上一杯的正文都带 `own_keys`。没有运行记录，也不占限额。服务调用照常被 `metered_llm` 记下，但不挂在任何记录下面。
- 「部署者没有对话模型」现在不存在（`CHAT_LLM_*` 必填），票 05 的那一条落到这里的「限额设成 0 时只能用自带密钥」。
- 结束的地方：玩完在 `_call` 里 `yield VisitDone()` 之前；离开是 `Bar.leave`；被顶掉是 `Bar.enter` 里 `self._visits[user_id] = visit` 那一刻（旧的那次没有显式结束）。
