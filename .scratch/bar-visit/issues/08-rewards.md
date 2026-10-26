# 08: 奖励：当天第一次玩完给抽奖和好感度

**What to build:** 每天（按进门那天的北京日期）第一次玩完的光顾给 1 次抽奖，并让她的好感度上升；当天之后的光顾什么都不给。好感度和礼物关着时照样能玩，也什么都不给。抽奖和每天发的一样受上限 7 约束，攒满了就不给。给了的话记一笔到账，导航「玩法」上的点照旧亮起来。好感度按这次每一杯的平均分加，最多 +0.5，从不降。冷却中的她照样加，到了解冻线就解除冷却。不留对话事件，不出胶囊。`GET /api/bar` 多一个 `reward_today`，`done` 的 `rewarded` 写上给了什么。见规格「玩完、光顾记录和奖励」里的「奖励」、接口一节的 `reward_today` 和 `done`，以及票 07 的答案。

**Blocked by:** 05

**Status:** done

- [x] 发奖励和写光顾记录在同一个写事务里。要同时满足三条才给：这一天还没有别的玩完的记录；好感度和礼物开着（`LiveConfig.affinity_on`）；告别写完了。记录上记下这次发没发奖励。
- [x] **抽奖**：先照常补上今天该发的，再加 1 次，最多到 `MAX_DRAWS`。加上了才往到账表记一笔，键按日期，比如 `bar:2026-10-26`；没加上就不记。成就的到账不受上限，这一条受，所以要新开一条受上限的发放路径，不改成就那条。
- [x] **好感度**：每杯上得最好 0.5、上对 0.4、上错 0.1；没有「上得最好」这一档的单（直说饮品名、打比方、老样子，或者范围里没有她爱喝的），上对记 0.5。取平均。走做完工作那条路（`_raise` 的通用化）：冷却中加的是这个数，不是冷却中礼物的固定 +3；不受每天上限约束。常量放在好感度模块里。
- [x] `done` 的 `rewarded`：给了抽奖时 `draws` 是 1，攒满了是 0；好感度加了时 `affinity_up` 是 true。关着，或者今天已经玩完过，`rewarded` 是 `null`。
- [x] `GET /api/bar` 的 `reward_today`：今天还没玩完过光顾，并且好感度和礼物开着。
- [x] 测试（先例 `test_schedule_job_done.py`、`test_gift_draws.py`、`test_affinity_cooldown.py`、`test_reset_card_grants.py`）：
  - 当天第一次玩完，抽奖 +1；好感度全上得最好 +0.5、全上错 +0.1，没有最好档的单上对记 0.5；
  - 攒满 7 次时不给、不记到账；
  - 冷却中加这个数，并在解冻线解除冷却；
  - 第二次玩完什么都不给，中途离开什么都不给；
  - 跨零点按进门那天算：前一天没玩完过的照给；
  - 好感度和礼物关着时 `rewarded` 为 null，库里没变；
  - 礼物状态里「最近一次到账」跟着酒吧的到账走；
  - 不留对话事件；
  - `reward_today` 在玩完前后的值。
- [x] 把 GLOSSARY「光顾」「抽奖」「好感度」和实现对一遍。pyright、ruff 通过；提交前跑 affected-tests，并 grep 断言礼物状态返回的测试一起跑（比如 `"max_draws"`）。

## Comments

### 票 05 交接

- 玩完时在 `bar._call` 里 `await self._db.write(_write_down, visit, now)`，奖励放进同一个写事务（`_write_down` 里），`rewarded` 列现在写 0。`VisitDone.shown()` 现在恒推 `"rewarded": null`。
- 「这一天有没有玩完过」是 `bar._before`（按 `entered_on` 查），`reward_today` 可以复用；`GET /api/bar` 的返回在 `Bar.read()`。

### 票 06 交接

- 「没有『上得最好』这一档的单」现在只能从说法看出一部分：直说名字、打比方、「老样子」一定没有。说口味、说种类、条件叠加、「来杯我喜欢的」、「你拿主意」，要看范围里有没有她爱喝的，`Serving` 没记这一点。建议在 `bar_rules` 里加一个 `has_best(order, character, catalog)`：名字加大杯恒有；其余看她爱喝的里，有没有一款不是讨厌的口味、满足 `order.said`、在 `_among` 里。条件里有 `big` 的，要看那一款有没有大杯，或者本身就是大杯。判定时一起记下来。
- 打比方换成模板句以后，`Serving.order.phrasing` 是 `conditions`，按条件叠加算。

### 实现说明（票 08）

- **好感度**：`affinity.SERVED_STEPS`（`best` 0.5、`right` 0.4、`wrong` 0.1）、`RIGHT_WITH_NO_BEST_STEP` 0.5，和别的好感度数值放在一起。新方法 `Affinities.visit_done(db, user_id, character_id, served: Sequence[DrinkServed]) -> bool` 取平均，走 `_raise`，返回值表示好感度有没有升。`_raise` 通用化以后返回改前改后两个 `Affinity`，送礼的 `Change` 挪回 `receive_gift` 里算，送礼的行为没变。
- affinity 模块里另写了一份 `HowWell = Literal["best", "right", "wrong"]`，没有导入 `bar_lines.Tier`：一导入就循环导入（affinity → bar_lines → drink_catalog → characters → … → store），而且 affinity 自己已经有一个 `Tier`。
- **抽奖**：新方法 `Gifts.reward_draw(db, user_id, key) -> bool` 先 `_notice`，再 `_give` 补今天该发的。`draws < MAX_DRAWS` 时才用 `_credit` 记一笔到账，加 1 次。成就那条 `Gifts.reward` 没动。键是 `bar:<进门那天>`。
- **没有最好档**：新函数 `bar_rules.has_best(order, character, catalog)`，把每一款能上的样子（瓶装；原杯和大杯；能选 Karmotrine 的，有酒和无酒都算）过一遍 `judged`，看有没有一杯是 `best`。这样直说名字、打比方、老样子恒为没有，名字加大杯恒为有，其余说法看她爱喝的里有没有一款上对。判定时没有存下来，写记录时现算：目录和口味在一次光顾里不会变。
- **酒吧**：`Bar` 构造多一个 `gifts` 参数（assembly 传进去），`_rewarding` 等于 `affinities.on`，两者都有才算。`_write_down` 改成方法，在同一个写事务里依次：用 `_done_on(进门那天)` 查这一天有没有玩完过、发奖励、写记录（`rewarded` 列写这次有没有轮到发奖励）。`VisitDone(rewarded)` 推 `{"draws", "affinity_up"}` 或 `null`。`Bar.read(user_id)` 改成 async，多了 `reward_today`；`_before` 复用 `_done_on`。
- 测试在 `backend/tests/test_bar_rewards.py`。`test_bar_switch` 读接口那条的键集合加上了 `reward_today`。
- GLOSSARY：「抽奖」补了「酒吧给的也一样受上限约束」；「光顾」补了「给一次抽奖（攒到上限就不给）」和「冷却中的她也照样升」；「好感度」原来就对得上，没改。

### 审查（票 08）

`code-review`（固定点 8f020836）两份报告里建议修的已经改了：
- `visit_done` 的参数原来是 `(tier, bool)` 元组，`bool` 的意思半路丢了，现在换成 `affinity.DrinkServed(how_well, has_best)`。
- `RIGHT_WITH_NO_BEST_STEP` 的 docstring 读不通，重写了。`HowWell` 的 docstring 写明了为什么不导入 `bar_lines.Tier`。
- `_write_down` 前多出来的一个空行删了。

留下没改的判断题：
- 档位那条参数化测试里，「上对，有最好档」两行（名字加大杯、说口味）和「上对，没有最好档」两行（直说名字、说种类，范围里没有她爱喝的），在 `visit_done` 里走的是同一条分支。不过它们在 `has_best` 里走的分支不同，票里也要求覆盖「范围里没有她爱喝的」，所以留着。
- `Rewarded.draws` 是 `int(reward_draw(...))`，只会是 0 或 1，和规格的 `draws` 一致。
- 要用户拍板：好感度到顶（100）而且抽奖攒满时，`rewarded` 是 `{"draws": 0, "affinity_up": false}`，光顾记录记 `rewarded = 1`。现在把 `rewarded` 列理解成「这次是当天领奖的那一次」，跟 `null` 的口径一致。要是想理解成「真拿到了东西」，就要改成记 0。
- 要用户拍板：冷却中好感度升了但还没到解冻线时，`affinity_up` 是 true。送礼那边冷却中不报变化，要等冷却结束才报，两边口径不同；规格只写「好感度加了时 `affinity_up` 是 true」。
