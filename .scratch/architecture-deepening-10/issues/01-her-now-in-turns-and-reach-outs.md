# 01: HerNow 给出打字、通话和搭话的「此刻」

**What to build:** 文字回合、通话、搭话里的「此刻」（GLOSSARY「此刻」）都改由新 module HerNow 给出，engine 不再自己拼。制作人在这三种场合里看到她知道的事，和现在一样：
- 现在几点、今天是不是制作人的生日、上次往来是什么时候；
- 今天在东京是谁的生日、是不是节假日、往年今天她站过的演出；
- 她这周和下周的日程，哪项做完了、哪项正在做；
- 她的周期到了哪；
- 好感度几行，文字回合里还包括判断后的警告和结束对话。

做完的工作照常计入好感度，并且已经反映在这一回合她的态度里。

除了下面这一点，她被告知的措辞、顺序、带不带的条件都不变：「此刻」里的周期按排提示词那一刻算，判断时仍用判断前那一刻算的那份。两者只在恰好跨零点的那几秒里可能差一天。

背景和设计见 `../spec.md`。

**Blocked by:** None (can start immediately)

**Status:** done

## 已定的设计（2026-10-27 grilling，详见 spec）

- HerNow 分两步：
  - 第一步「读」：传用户、角色、设备时区（搭话时为空）。它计入做完的工作，读出日程，读出周期并交还给 engine 做判断和对话事件。光顾时还会把好感度档位一起读出来，这条留给票 02 用。调用方必须在读好感度之前调用这一步，这条先后写进它的 interface。
  - 第二步「这几行」：传场合、排提示词的那一刻、时区、制作人档案、上次联系、好感度几行。它按场合表给出「此刻」的几行。
- 场合表在这张票里就把四种场合写全。光顾那一列只带「今天」和好感度，不带时间、制作人生日、日程、周期，但酒吧到票 02 才接上来。
- 「今天」那几行改为直接接收世界设定（没有世界设定时为空），由它自己去取她站过的演出和组合伙伴；去掉没用到的「怎么在说话」参数。
- 「这项工作做完了没有」只在日程里判断一处：计入好感度和告诉她日程都调用它，HerNow 用它给出「今天做完的那项」（有几项时取最晚的一项）。
- engine 里给三种场合拼「此刻」的方法，以及包着读日程、读周期的两个小方法，都删掉，改用 HerNow。
- 开头共用部分（人设、她的生日、世界设定）engine 和酒吧各写了一份，抽成一个小函数，两边都改用它。这部分不放进 HerNow。
- 组装处建好 HerNow，交给 engine。

## 验收

- [x] 新 module HerNow，两步 interface 如上。interface 的说明里写明：读好感度之前要先调第一步。
- [x] 场合表写在 HerNow 里，逐个列出打字、通话、搭话、光顾四种场合。
- [x] 文字回合、通话、搭话的「此刻」都来自 HerNow；engine 里原来的拼法和那两个小方法已删掉。
- [x] 「今天」那几行直接接收世界设定，不再有「怎么在说话」参数。
- [x] 「工作做完了没有」只在日程里判断一处。
- [x] 开头共用部分抽成一个小函数，engine 和酒吧都改用它。
- [x] 下面这些测试直接对 HerNow 测：HerNow 从组装好的后端里取出，日程照常经接口保存，用可以拨的假时钟和真数据库。
  - 今天：她的生日从东京零点开始；别人的生日不包括她自己；组合伙伴和其他人的生日分开说；节假日紧跟在时间后面；往年今天的演出说成过去，她没上场的和还没到的演出不说；平常日子什么都不说。
  - 日程：按今天、明天等说出是哪天；正在进行的那项单独说；早上 6 点前没有正在进行的；只有正在进行的一项时照样说；她一项都没排时不说；上周的不说；日程关着时不说；在北京以西的时区，周日就已经知道下周保存的。
  - 周期那几行和好感度几行出现在什么位置。
  - 场合表：光顾那一列不带时间、制作人生日、日程、周期。
  - 先后顺序：第一步之后紧接着读到的好感度档位，已经计入了刚做完的工作。
  - 今天做完的那项：有几项时取最晚的一项，没有时为空。
- [x] 打字、通话、搭话各保留一条走 HTTP 的测试，确认「此刻」这几行真的进了提示词，可以参照现有日历测试从假 LLM 的提示词里取「此刻」一节的写法。原来在三条路上各走一遍、检查某一行内容的 HTTP 测试删掉。节假日接口的测试不动。
- [x] 现有的周期、体贴、好感度、搭话、日程测试照常通过。
- [ ] 本机跑类型检查，以及 `scripts/affected-tests.sh` 找出的测试；推分支，开 draft PR，看 CI。

## Comments

### 实现说明（票 01）

- 新 module `backend/src/eidolon/her_now.py`：`HerNow`，两步。
  - `read(user_id, character_id, device_timezone, occasion) -> Known`：读日程（顺带计入做完的工作）、周期、今天做完的那项；`occasion == "visit"` 时再读好感度档位（`Known.affinity`，`Status`）。docstring 写明读好感度要在它之后。
  - `lines(known, occasion, now, timezone, profile, last_contact, affinity_lines) -> list[str]`：按 `CARRIES` 场合表给出「此刻」几行，按行连起来就是一节。周期按 `now` 现算。
  - 场合表 `CARRIES` 逐个列出 typing、in_call、apart、visit。`Occasion = Talking | "visit"`。
- `today.today_lines(now, character, characters, world)`：直接收世界设定，去掉 talking 参数。
- `today.always_known(character, world_prompt)`：开头共用部分（人设、她的生日、世界设定），engine 的 `_prompt` 和 `bar_prompt.shared_prompt` 都改用它。
- `schedule.is_done(...)` 是判断「做完了没有」的唯一一处；`HerSchedule.done(her)`、`HerSchedule.done_today()` 都调它。`_counted`（计入好感度）、`schedule_lines`（告诉她）都改用它。酒吧原来的 `_done_today` 已删，暂时改调 `her_jobs.done_today()`，票 02 再换成从 HerNow 取。
- engine：构造参数去掉 `schedules`、`cycles`，加 `her_now`（必填，排在 `clock` 后）；`_now_prompt`、`_her_days`、`_her_jobs` 已删。判断、对话事件、不舒服用的周期取自 `known.her_days`。
- assembly：建 `HerNow(characters, world, schedules, cycles, affinities)` 交给 engine，并挂在 `Backend.her_now` 上（测试从这里取）。

测试：

- 新 `backend/tests/test_her_now.py`（18 条）直接对 HerNow 测：今天的各种情况、日程的各种情况、周期和好感度几行的位置、场合表（光顾只有好感度几行和今天）、先后顺序（第一步后好感度已计入刚做完的工作；把读好感度挪到读日程前，这条会红）、今天做完的那项。
- `test_calendar.py` 只留节假日接口三条和打字、通话、搭话各一条走 HTTP 的；`test_schedule_she_knows.py` 只留搭话那条（它还守着搭话规则里关于日程的措辞）。其余搬进 `test_her_now.py` 后删掉。
- 跑过：ruff、pyright 全项目；`sh scripts/affected-tests.sh 8b323e7c`（280 passed）；另跑了 her_days、considerate、schedule_*、affinity*、she_is_unwell、warm_gifts、cycles_*、bar_*、dynamic_context、she_ends_conversation、she_hangs_up、world_setting、reach_outs_in_turns、text_turn 等（437 passed）。

判断题：

- 光顾时读出的好感度放的是 `Status`（档位和冷却），不只是档位，酒吧用 `.tier`。
- 第二步的参数里没有角色：角色由第一步带在 `Known.character` 里。
- `HerNow.lines` 返回几行（`list[str]`），不是连好的一节：engine 自己用换行连起来；光顾时酒吧把它们原样放进「这次光顾」一节。
- 搭话那条走 HTTP 的测试在 `test_calendar.py` 和 `test_schedule_she_knows.py` 里各留了一条（后者主要守搭话规则的措辞）。
