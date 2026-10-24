# 01: 后端走通：她真实的周期、部署者开关、「此刻」状态几行、开发口子

**What to build:** 每位用户的每位角色各有一个周期，经前、经期她说话跟着变；用开发口子把一位角色放进经期第 N 天或经前还剩 N 天，打一个回合，就能在她读到的「此刻」里看到那几行。**她真实的周期**是一个新的纯模块：给（种子, 是否未满 18 岁, 日历日）得出 `Period(day, length, first_day)` / `Premenstrual(days_left)` / `None`（类型见规格「她真实的周期」）；参数、权重表、纪元日 2026-01-01、逐周期的哈希全部按规格写定并冻结，常量旁注明 ADR-0029。它上面一层是后端各处用的入口：给（用户, 角色, 此刻, 制作人有效时区：档案 → 设备 → 上海），先看开关和开发口子，再派生种子（有 `EIDOLON_SECRET_KEY` 时 HKDF，info `b"eidolon cycles"`，照账号模块派生封禁名单钥匙的写法，对用户 id 加角色 id 做 HMAC-SHA256；没设密钥时直接 SHA-256）、换算日历日、调纯函数；开关关着返回「不受周期影响」。用户开关这张票还没有，入口留好参数位，票 02 接上。**角色名单** 29 位每位加整数字段 `age`（照各自 facts 文件第三行核对），启动校验，按 `age < 18` 判断。**部署者开关** `EIDOLON_CYCLES`，写法同 `EIDOLON_SCHEDULE`（不填或 `1` 开、`0` 关、其他值启动报错），加进实时配置（后台改的优先，ADR-0013），后台配置接口能读写；后台的卡在票 02。**「此刻」**：经前、经期时在末尾、日程那几行之后，照规格「『此刻』里的状态几行」逐字加上分天的那几行和共用的几句；卵泡期、排卵期、开关关着时一句不加；打字、通话里的回合和搭话同一条「此刻」，她发照片的提示词不带。**开发口子**：只在 `EIDOLON_DEV_LOGIN=1` 时注册一个接口，给当前用户的某位角色强制「经期第 N 天」「经前还剩 N 天」「平常」或清掉，存在进程内存里；只替换「她今天在哪」，开关照常起作用；生产不注册。`docs/agents/local-acceptance.md` 补一句怎么用它。这是「她的周期」的第一张票：分支 `feat/cycle-her` 从当时的 main 开，第一个提交从 `feat/cycles` 取来 `.scratch/cycle-her/`（规格和这七张票）、ADR-0029、ADR-0030 和 `GLOSSARY.md` 的改动，然后推到 origin、开 draft PR。见规格「她真实的周期」「开关」「『此刻』里的状态几行」「开发口子」和 Testing Decisions。

**Blocked by:** None (can start immediately)

**Status:** done

- [x] 第一个提交带上规格和票、两份 ADR 和词汇表的改动（`git checkout feat/cycles -- <路径>`）；推到 origin、开 draft PR
- [x] 纯模块的测试：几个固定种子和日子得出写死的结果；同一天反复算、从不同的「今天」往回问同一天，结果一样；几千个种子的基准周期都在 25–34、峰在 28–29，经期 3–8，成年每周期在基准 ±3、未满 18 岁在 ±5、全部在 21–40，经前每位固定在 3–5；连续几百个周期首尾相接、没有缝和重叠；纪元前的日子按实现选定的行为测
- [x] 种子：有密钥、没密钥都能出结果且两者不同；同一用户不同角色、同一角色不同用户不同
- [x] 29 位都有 `age`，和 facts 文件第三行一致；缺了或不是整数启动报错
- [x] `EIDOLON_CYCLES` 不填为开、`0` 为关、其他值报错；后台配置改了优先（先例 `test_schedule_switch.py`、`test_live_config.py`）
- [x] 「此刻」（HTTP 接缝：用纯函数和测试配置的密钥替这位用户和角色找出对应日子、拨 `FakeClock`，不靠开发口子）：经期第 1–2 天、第 3 天起、经前还剩 3 天以上、1–2 天各自那几行和共用的几句，逐字对上；平常一句不加；部署者关着一句不加；通话里的回合和搭话同样有；她发照片的提示词里没有（先例 `test_dynamic_context.py`、`test_schedule_she_knows.py`、`test_reach_outs.py`）
- [x] 开发口子：开发登录开着时能强制、清掉，强制后「此刻」跟着变；没开时接口 404
- [x] 阶段不出现在任何接口、后台、看板、运行记录里
- [x] pyright、ruff 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 票收尾：Comments 里写下入口的签名、开发口子的接口形状、实时配置项名，给票 02–06 用；推一次让 CI 跑、跑 `code-review`

## Comments

### 实现说明（票 01）

- **纯模块** `backend/src/eidolon/her_cycle.py`：`her_day(seed, under_18, day) -> HerDay`（`Period(day, length, first_day)` / `Premenstrual(days_left)` / `None`）；`cycle_seed(secret_key, user_id, character_id) -> bytes`（HKDF info `b"eidolon cycles"`，HMAC-SHA256 过「用户 id、换行、角色 id」；没密钥时直接 SHA-256）；另有 `rhythm(seed)`（基准周期、基准经期、经前天数、偏移）和 `cycles(seed, under_18)`（从第 0 个周期往后），测试分布用。哈希选定为 SHA-256(种子 +「换行、项名、换行、k」) 取前 8 字节大端，权重表按 % 100 落档，均匀抽按 % n；全部冻结。纪元前的日子照常往前推（负的 k），不返回 None。
- **入口** `backend/src/eidolon/cycles.py` 的 `Cycles`，在 `Backend.cycles`：
  `Cycles.her_day(user_id, character_id, at: datetime, timezone: str, user_on: bool = True) -> HerDay`。`timezone` 传制作人有效时区（`effective_timezone(profile, device_timezone)`；搭话没有设备时区，和日程一样是档案 → 上海）。部署者开关、`user_on` 任一关着，或角色已不在配置里，返回 None。`user_on` 是给票 02 留的参数位，现在没有调用方传它。
- **「此刻」**：`cycles.cycle_lines(her_day)` 给两行（分天那一行；共用的几句连成一行，照原型 D 版的分法），`ConversationEngine._now_prompt` 接在 `schedule_lines` 后面；回合、通话里的回合、搭话都走它。她发照片的提示词只用标签，本来就不带。
- **实时配置项** `cycles`（`live_config.CYCLES`，`config.cycles_on`），字段 `{"enabled": bool}`；后台接口 `PUT/DELETE /api/admin/config/cycles`。`Settings.cycles` 来自 `EIDOLON_CYCLES`（`_switch`，默认开）。`.env.example` 已加。
- **开发口子** `backend/src/eidolon/cycles_api.py`，只在 `EIDOLON_DEV_LOGIN=1` 时注册：`PUT /api/dev/cycles/{角色 id}`，体 `{"phase": "period", "day": 1–8}` / `{"phase": "premenstrual", "day": 1–5}` / `{"phase": "neither"}`，204；`DELETE` 同一地址清掉，204；角色不存在 404，天数越界 422。强制「经期第 N 天」时 `first_day` 按问的那天往回推 N−1 天、`length` 取 max(N, 她的基准经期)，所以强制着过夜时 `first_day` 跟着挪。
- **角色** `Character.age`（必填正整数），`characters.toml` 29 位都加了，配置文档三语补了字段说明。
- **判断**：`tests/conftest.py` 的 `settings` 默认 `cycles=False`，免得哪条旧测试的假时钟碰巧落进她的经期；周期的测试自己打开（`replace(settings, cycles=True)`）。要她在某阶段：拨假时钟用 `test_her_days.a_noon_when`，时钟拨不动的（通话 `test_call_turns.NOW`、搭话）用 `a_key_when` 换一把密钥让她那天在那儿。
- 本机 `test_call_turns.py::test_call_hangs_up_after_its_last_allowed_turn` 在 main 上也失败（FakeLLM 回复用完，时序相关），和这张票无关；CI 上通过。

