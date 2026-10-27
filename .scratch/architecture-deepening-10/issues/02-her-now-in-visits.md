# 02: 光顾时的「此刻」也由 HerNow 给出

**What to build:** 酒吧里她进门时被告知的「此刻」（GLOSSARY「此刻」「光顾」）改由 HerNow 给出，酒吧不再自己拼。

制作人在光顾时看到的和现在一样：

- 她知道今天在东京是谁的生日、是不是节假日、往年今天她站过的演出；
- 她对制作人的态度按好感度档位来；
- 她不被告知现在几点，因为酒吧的故事只发生在夜班；
- 她不知道今天是制作人的生日，不受周期影响，也不知道这周排了哪些工作；
- 如果她今天做完了一项工作，那项照旧会成为她来店里的缘由，而且照常已经计入好感度。

背景和设计见 `../spec.md`。

**Blocked by:** 01

**Status:** done

## 已定的设计（2026-10-27 grilling，详见 spec）

- 酒吧进门时先调用 HerNow 的第一步。这一步读出今天做完的那项和好感度档位。之后酒吧不再自己去读日程和好感度。
- 「这次光顾」一节里的好感度几行和今天几行，从 HerNow 第二步取，场合填「光顾」。这几行在这一节里的位置不变。
- 酒吧自己找「今天做完的那项」的代码删掉。来意用 HerNow 给出的那项。
- 组装时把 HerNow 交给酒吧。

## 验收

- [x] 酒吧进门时，日程、好感度档位和「此刻」那几行都从 HerNow 来。酒吧里不再有自己找「今天做完的那项」的代码。
- [x] 补一条走 HTTP 的测试：「这次光顾」一节里有今天那几行（比如某位角色的生日）和好感度那几行，没有时间、制作人生日、日程和周期。做法参照现有光顾测试读假 LLM 提示词的方式。
- [x] 测到「今天做完了一项工作，她因此来店里」时，好感度档位已经计入了这项工作（如果 HTTP 测试不便触发，就在 HerNow 上测，并写进实现说明）。
- [x] 现有的光顾测试照常通过，来意、话题、她的资料、醉、奖励都和原来一样。
- [ ] 本机跑类型检查，以及 `scripts/affected-tests.sh` 找出的测试；推分支，看 CI。

## Comments

### 票 02 交接

- `HerNow` 在 `backend/src/eidolon/her_now.py`，assembly 里已经建好（`her_now`），还没交给酒吧：给 `Bar` 加参数，在 assembly 里传进去。
- 进门时调 `her_now.read(user_id, character.id, device_timezone, "visit")`：`Known.done_today` 是今天做完的那项（`Job | None`），`Known.affinity` 是好感度（`Status | None`，好感度关着时为空）。拿到以后酒吧里的 `self._schedules.hers(...)` 和 `self._affinities.status(...)` 两次读都可以删；`Bar` 的 `schedules` 参数可能就用不上了（assembly 里 `Bar(..., schedules=schedules, ...)` 一起删）。
- 「这次光顾」一节：`her_now.lines(known, "visit", now, timezone, profile, None, affinity_prompt(status.tier, None))` 给出的就是 `[*好感度几行, *今天几行]`，顺序和现在 `visit_prompt` 里 `*affinity_lines, *today` 一样；`visit_prompt` 的这两个参数可以合成一个。光顾不带时间，`timezone`、`profile`、`last_contact` 在这个场合不会用到，传什么都行（`profile` 酒吧在 `_hers` 里已经读了 `about_producer`，没有现成的 `ProducerProfile`，可以传 `ProducerProfile()`，或者把第二步这几个参数改成可选，自己判断）。
- 酒吧原来的 `_done_today` 已经在票 01 删了，现在调的是 `her_jobs.done_today()`；改成用 `known.done_today` 即可。
- 「先后顺序」在 HerNow 上已经测过（`test_her_now.py::test_jobs_done_are_counted_before_her_affinity_is_read_after_the_first_step`，用的正是 `"visit"`），光顾的 HTTP 测试不便触发时可以引用这条。
- 场合表里光顾那一列也已在 `test_her_now.py::test_visiting_the_bar_she_is_told_only_how_she_feels_and_the_day_in_tokyo` 测过。

### 实现说明（票 02）

- `Bar`：构造参数 `schedules` 换成 `her_now`（`HerNow | None`）。进门时先调 `her_now.read(..., "visit")`，来意用 `Known.done_today`；酒吧自己读日程、读好感度的两处都删了（`_affinities` 只剩发奖励用）。「这次光顾」一节里的几行由新的小函数 `bar._now_lines` 从 `her_now.lines(known, "visit", ...)` 取，好感度几行按 `Known.affinity.tier` 由 `affinity_prompt` 给。
- `bar_prompt.visit_prompt`：`affinity_lines`、`today` 两个参数合成一个 `now_lines`，在这一节里的位置不变。
- assembly：`Bar(..., her_now=her_now, ...)`，不再传 `schedules`。
- `HerNow` 本身没改。

测试：

- `test_bar_draws.py` 新加一条走 HTTP 的：制作人生日、日本节假日、她在经期、这周排了一项还没做的工作，进门时「这次光顾」一节有好感度档位那行、以节假日那行收尾，整段里没有时间、制作人生日、日程和周期。临时把场合表里光顾的日程、周期改成带，这条会红。
- 「今天做完一项、她因此来店里时，档位已计入这项」不便在 HTTP 上触发（要卡在档位边上），引用票 01 的 `test_her_now.py::test_jobs_done_are_counted_before_her_affinity_is_read_after_the_first_step`（用的正是 `"visit"`）；来意本身仍由 `test_bar_draws.py::test_her_job_done_today_is_her_reason_half_the_time` 守着。
- 跑过：ruff、pyright；`sh scripts/affected-tests.sh c6b05b97`（180 passed）；另跑全部 `test_bar_*.py`（179 passed）。

判断题：

- 光顾不带时间、制作人的事和周期，`HerNow.lines` 的 `timezone`、`profile`、`last_contact` 用不上；没改它的签名，`_now_lines` 里传 `"Asia/Tokyo"`、`ProducerProfile()`、`None` 占位，docstring 写明原因。
- 没有 `her_now` 时（只在不经 assembly 直接建 `Bar` 时）「此刻」几行全无，原来没有日程时仍有「今天」几行；assembly 总会传，线上没有区别。
