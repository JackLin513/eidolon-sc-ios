# 04: 判断和好感度：体贴题、加倍扣分、体贴加分、感受句、挂断门槛

**What to build:** 她经前、经期时，体贴的话额外加好感度，不体贴扣得更重，她也更快警告、挂断或结束对话。其他日子一切照旧。**体贴题**（ADR-0030）：原有三道题（五档打分、不该说的话、操纵）和 `turn_state` 一字不改，仍然不看她的状态。判断入口多一个可选参数：她这几天在哪（经期、经前，或 None）。不是 None 时，同一个请求里多问一道三档的体贴题，题面分经期、经前两版，阶段只写在这道题的题面里。是 None 时，请求和现在逐字节相同。题面的大意、「平常聊天算无关」「两档一样可能时算无关」见规格「判断：体贴题」，最终措辞由票 05 用评测集调；这张票先写一版能用的。答案里多一个可选的体贴档（0 不体贴、1 无关、2 体贴），读法和五档保持一致。运行记录不记体贴的答案，也不记这一回合问没问。`affinity_judge` 开头「一个标准」那段说明照 ADR-0030 改。**好感度的数**：她在经前或经期、两个开关都开着、这一回合问了体贴题时才套用，整段一套数。
- 两个负档 ×2：伤到她 −3，不舒服 −1。
- 不体贴另扣 0.5，和负档叠加。
- 不该说的话 −10 不动。
- 体贴额外 +0.3，有单独一个每天 0.6 的上限。好感度表加一列「今天体贴加了多少」，和原有的「今天加了多少」共用同一个日期列（北京时间划天）、同时归零。在不在经前、经期按制作人时区判断。
- 判成操纵的回合不给这笔加分。

**感受句**：体贴、不体贴各一句，经期、经前各两句，措辞照规格逐字。接在五档那句后面，两句都给，不合并。操纵的回合不给「心里很暖」那句。好感度箭头照常只看总的升降。**挂断和结束对话**：她在经前或经期时，`WARNS_AT` 6 → 4，`FED_UP_AT` 12 → 8。判成不体贴的回合，这一回合的「伤」再加 2，和档位的「伤」叠加，存进消息上的就是加过的数。用哪套门槛看这一回合发生时她在哪。体贴不抵消已经记下的。一通电话两次不该说的话就挂断、冷却的规则都不动。通话挂断和打字的结束对话用同一套。新常量和原有的挨着放，注明出处。没有判断模型或好感度关着时不问体贴题。部署前要手动备份（好感度表加了一列），写进票 07 的清单。见规格「判断：体贴题」「好感度的数」「挂断和结束对话」和 Testing Decisions。

**Blocked by:** 01

**Status:** done

- [x] 平常日子的判断请求和现在逐字节相同；经期、经前的请求多了对应那一版体贴题（从假判断模型收到的请求里看）
- [x] 不舒服 −1、伤到 −3、不体贴另 −0.5、不该说的话 −10；体贴 +0.3，有自己每天 0.6 的上限，和回合的 0.6 各算各的，北京时间换天时一起归零；操纵的回合不给体贴加分、不给「心里很暖」（先例 `test_affinity_turns.py`、`test_affinity_prompt.py`）
- [x] 两句感受句的顺序和措辞；判成无关时不加
- [x] 运行记录里没有体贴的答案
- [x] 这几天不舒服两次就警告、四次就挂断（打字时是结束对话），不体贴记 2；平常日子 `test_she_hangs_up.py`、`test_she_ends_conversation.py`、`test_affinity_cooldown.py` 的断言不改，照样通过
- [x] 任一开关关着时：不问体贴题，倍数和门槛照平常
- [x] 好感度表的新列：旧库启动时自动补上
- [x] `affinity_judge` 开头的说明改好；词汇表「体贴」和实现一致
- [x] pyright、ruff 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 票收尾：Comments 里写下体贴题的题面和答案的读法，给票 05 用；推一次让 CI 跑、跑 `code-review`

## Comments

### 票 02 交接

- 入口 `Cycles.her_day(user_id, character_id, at, timezone)` 现在是异步的，自己看部署者和用户两个开关（用户开关读表 `cycles_off`），`user_on` 参数去掉了；返回 None 就是「不受周期影响」，不用另判开关。
- 引擎里已有 `ConversationEngine._her_day(conversation, now, timezone)`，回合里「此刻」用的就是它，判断和挂断可以复用同一次的结果，不必再读一次。
- 测试里要她在某一天：用 `tests/test_her_days.py` 的 `on_a_day`（先注册制作人、找好日子，再用拨到那天的时钟登录）；直接拨 `FakeClock` 跨过 30 天会话就过期，返回 401。用户关开关：`tests/test_cycles_switch.py` 的 `switch`。

### 实现说明（票 04）

- **判断入口**：`AffinityJudge.judge`、`RetrievalJudge.judge`、`Retrieval.retrieve` 以及它们的计量、换模型的包装（`activity.Metered*`、`live_config.Live*`、`memory_eval` 的假判断）都多了关键字参数 `days: Days | None`（`affinity.Days = Literal["period", "premenstrual"]`）。题目由 `affinity_judge.affinity_questions(days)` 给出：`days` 为 None 时就是原来的 `QUESTIONS` 对象本身，所以平常日子的请求逐字节相同；不是 None 时在三道题后面加 `CONSIDERATE_QUESTION = "considerate"`，再往后才是照片题。`retrieval.judge_questions(affinity, photo, days)` 同理。
- **引擎**：`her_day` 改成在判断之前算（读完记录、定好时区之后，用当时的时钟），判断、「此刻」、第一天的事件共用这一次。`engine._days(her_day)` 把 `Period` / `Premenstrual` 换成 `Days`；任一开关关着时 `her_day` 已是 None。好感度关着或冷却中本来就不问好感度的题，体贴题也就不问。
- **数**：`Judged` 多了 `days`、`considerate`（默认 `UNRELATED`）。`step` 是档位的那份（她这几天用 `HER_DAYS_LEVEL_STEPS`），`considerate_step` 是 +0.3 / −0.5 / 0 那份；`Affinities.change` 两份各按自己的每天上限截（`_limited`），`gained_today`、新列 `considerate_today` 共用 `gained_on`。新常量都在 `affinity.py` 原常量旁边，注明 ADR-0030（规格写的「票 03」是计划分支上 `.scratch/cycles/map.md` 的票 03）。
- **感受句**：`Judged.feeling` 换成 `Judged.feelings`（列表）：先档位那句，再体贴 / 不体贴那句。
- **挂断**：`hurt()` 不体贴加 `INCONSIDERATE_HURT`；`ends()` / `warns()` 按 `judged.days` 取 `HER_DAYS_FED_UP_AT` / `HER_DAYS_WARNS_AT`。通话和打字都走这两个函数。
- **旧库**：`affinity._open` 发现没有 `considerate_today` 就补一列（默认 0）。
- **测试**：新文件 `tests/test_considerate.py`；`fakes.FakeJudgeModel` 记下每次问的题（`questions`），`Judging` / `level()` 多 `considerate`（默认 1）。

**体贴题的题面**（给票 05 调；在 `affinity_judge._CONSIDERATE_QUESTIONS`）：Score 题，三档从低到高。`instructions` = 原有的 `_SCENE` + 阶段一句 + 共用的规则「只看制作人最新的一句话有没有顾及她现在的状态。平常的聊天、事务都算无关，不算不体贴；两档一样可能、拿不准时，也算无关。」

- 经期的阶段句：「她现在在经期：身体不舒服，容易累，没力气，提不起精神。」三档：
  0. 她流露了疲倦或身体不适，制作人却无视或者加重：催她去训练、加练、赶工作，嫌她没精神、动作慢，或者对她的不舒服冷淡、不耐烦
  1. 和她现在的状态无关：平常的聊天、打招呼、提问、请她讲事情，事务和工作安排，或者她没有流露出来时的普通对话
  2. 察觉并照顾到了她现在的状态：注意到她累了、不舒服，关心她的身体，让她休息、别勉强、喝点热的，替她分担、减轻负担
- 经前的阶段句：「她这几天在经前：情绪容易起伏，比平时敏感，容易烦躁、委屈。」三档：
  0. 她流露了烦躁、低落或委屈，制作人却无视或者加重：嫌她情绪化、小题大做，跟她较劲、讲道理压她，或者火上浇油
  1. （同经期的 1）
  2. 察觉并体谅了她这几天的心情：耐心地听她说，安慰她，包容她的小脾气，不和她计较

**答案的读法**：和五档一样取概率最高的一档，两档一样高时算无关（1）；只认 0、1、2 三档。体贴题的答案读不出时也算无关，阈值和倍数照这几天的套用，其他三道题照常读；不写日志，因为日志会透露问了这道题。

**判断题（没改，留给用户看）**：
- 不该说的话的回合照旧 −10、「伤」10，不再加不体贴的 −0.5、+2，也不给「更难受了」那句。规格写了「不该说的话 −10 不动」，这里把「不动」理解成整个回合都不叠加；「伤」10 已经超过门槛 8，挂断不受影响。
- 体贴的每天上限只算实际涨上去的那部分：同一回合又不舒服又体贴（−1 + 0.3）净跌，那 0.3 不占上限。这和原来 `gained_today` 的算法一致。
- 判成操纵的回合仍然扣不体贴的 −0.5，也给「更难受了」那句（规格只说操纵不给加分、不给「心里很暖」）。
- 审查提的几项没改：`Days` /「her days」这个统称词汇表里没有（经期、经前合称），要的话用 `/domain-modeling` 补；体贴的三档用 `int` 常量（`INCONSIDERATE, UNRELATED, CONSIDERATE`），没另开类型；`days` 参数穿过约十个判断签名，是 Protocol 决定的。
- `test_call_turns.py::test_turns_that_fail_or_are_rejected_do_not_count_and_the_call_goes_on` 本机单独跑会失败，在基点 5622237c 上单独跑也一样失败，和这张票无关。CI 上 830e466 那次 run 红在 `test_fish_segments.py::test_hanging_up_while_a_segment_finishes_closes_every_connection_at_once` 的计时（0.64s，限 0.5s），也是负载下的偶发失败。
