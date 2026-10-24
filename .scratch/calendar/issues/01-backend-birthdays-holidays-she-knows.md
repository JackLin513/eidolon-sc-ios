# 01: 后端：角色生日、节假日接口、她当天知道

**What to build:** 日历要的数据和她要知道的日子，全在后端做齐，前端还不动。`characters.toml` 每位角色加必填的 `birthday = "MM-DD"`，29 位（含はづき）都从各自角色资料第一段抄出初稿，资料正文不动；加载时缺了、写法不对、不是一年中的日子（2 月 29 日算）都报配置错误并指出角色 id，文件头的字段说明补上这一条。登录后读的角色列表接口每位多一个 `birthday`，前端的 `Character` 类型随之加字段（只加类型，不用）。后端装 `holidays` 库，新建节假日模块：给一年回这一年日本法定祝日（含振替休日、国民の休日；年末年始、お盆、GW 不算）的（日期，日文名）列表按日期排，给一天回当天的名字；新接口 `GET /api/calendar/holidays?year=YYYY` 要登录，回 `[{"date": "YYYY-MM-DD", "name": "文化の日"}, …]`，年份不是整数或库算不出时回空列表不报错，响应让浏览器缓存一天。她自己的生日固定写进共用固定部分（人设、世界设定、格式说明那一段）一句「你的生日是 M月D日」，所有用户同一位角色一样，不碰缓存断点（ADR-0020）。新建「今天的几句」纯函数：输入此刻、这位角色、全部角色、谈话方式（打字、通话、没在说话），按东京日期输出零到几句：她生日当天一句（自然提一两次、不讨礼物、祝福就接）、同伴生日当天一句（列几位显示名，含はづき、不含她自己，不替同伴讨祝福、不催）、节假日当天一句（名字，自然提到不必每句说）；都不成立一句不写。回合（打字和通话）和搭话都把它的结果紧跟在 `now_prompt` 的「此刻」后面、同一节里；搭话的由头顺序不改。2 月 29 日复用制作人生日的规则（没有 29 日的年份算 28 日）。不加开关、不加环境变量、不改库。见规格「角色生日」「节假日」「她怎么知道」三节和 Testing Decisions。

**Blocked by:** None (can start immediately)

**Status:** done

- [x] `characters.toml`：29 位都有 `birthday`，写法 `"MM-DD"`；文件头字段说明加 `birthday` 一条；初稿从各位资料第一段抄，提交说明里列出来源不清或资料没写的（如果有）让维护者核对
- [x] 加载校验：缺字段、不是两位月两位日、不是一年中的日子（2 月 30 日）都报 `CharacterConfigError` 并指出角色；2 月 29 日能过；`Character` 多一个生日（月、日）
- [x] 角色列表接口每位带 `birthday: "MM-DD"`；前端 `Character` 类型加 `birthday: string`
- [x] 节假日模块：按年给（日期，名）列表按日期排，按日给名或 None；只取库默认类别的日本祝日，名字用库的日文名；库算不出的年份回空列表
- [x] `GET /api/calendar/holidays?year=YYYY`：要登录（没登录同别的接口的回法）；2026 含 11-03 文化の日、05-06 振替休日，不含 12-31、01-02；年份不是整数或超范围回 `[]`；`Cache-Control` 一天
- [x] 她的生日在共用固定部分：一句「你的生日是 M月D日」，位置在世界设定旁或人设之后，实现时定并在说明里写下；`cache_breakpoint` 的位置不变
- [x] 「今天的几句」纯函数：三种句子各自判断，按东京日期；谈话方式三种都能传（她生日那句三种一样）；几位同伴同一天都列；什么都不是的日子返回空
- [x] 接入：回合（打字、通话）和搭话的 `about_turn` 里「此刻」后面紧跟这几句、同一节；别的提示词内容和顺序不动
- [x] 测试（HTTP 接缝，`make_client` + `FakeClock` + `FakeLLM`，从 `llm.prompts` 看提示词）：
  - 角色列表每位带 `birthday`；对真实配置断言 29 位都有、格式都对（照 `test_repository_configures_its_characters_with_their_voices` 的写法）；临时配置缺字段、写错、2 月 30 日都被拒并指出角色
  - 节假日接口上面四条；要登录
  - 共用固定部分有她的生日；假时钟拨到她生日当天东京 0:30（北京还是前一天 23:30）时「此刻」有「今天是你的生日」，前一刻没有；同伴生日当天列出几位（含はづき）、不含她自己；节假日当天有名字；什么都不是的日子一句不写；搭话提示词同样有（照 `test_reach_outs.py` 看搭话提示词的写法）；通话里的回合同样有（照 `test_dynamic_context.py` 通话那条）
  - 先例：`test_characters.py`、`test_producer_profile.py`、`test_dynamic_context.py`、`test_reach_outs.py`、`test_world_setting.py`
- [x] `pyproject.toml` 加 `holidays`，`uv lock` 过；pyright、ruff 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 票收尾：Comments 里写下接口形状（`birthday` 字段、节假日接口的路径和回法、「今天的几句」的签名）给票 02、03 用；按 `docs/agents/implementing.md` 推分支开 draft PR、跑 `code-review`

## Comments

### 实现说明（票 01）

- **角色生日**：`characters.toml` 每位加 `birthday = "MM-DD"`（放在 `color` 下面），29 位都从 `facts/<id>.md` 第一段抄来，逐个核对过，没有来源不清的。`Character.birthday` 是 `producer.Birthday(month, day)`（和制作人生日同一个类型，`is_birthday` 两边共用，2 月 29 日在平年落到 28 日）。加载校验：缺字段走必填字段的报法；写法用 `[0-9]{2}-[0-9]{2}` 加 `is_day_of_the_year`，错了报「角色 <id> 的 birthday 应为 MM-DD 格式……」。
- **角色列表接口** `GET /api/characters` 每位多 `"birthday": "04-25"`；前端 `Character` 类型加 `birthday: string`（只加类型）。
- **节假日模块** `eidolon/japan_holidays.py`：`holidays_of(year) -> tuple[(date, 日文名), ...]` 按日期排（`holidays.country_holidays("JP", language="ja")`，默认类别），库算不出的年份（1949 年前、2099 年后）回空；`holiday_on(day) -> str | None`。按年 `lru_cache(16)`。
- **节假日接口** `eidolon/calendar_api.py`：`GET /api/calendar/holidays?year=YYYY`，要登录（没登录 401），回 `[{"date": "2026-11-03", "name": "文化の日"}, …]`；`year` 只收 1–4 位 ASCII 数字，别的（含全角数字、空）回 `[]`；`Cache-Control: private, max-age=86400`。
- **她的生日**：一句「你的生日是4月25日。」放在共用固定部分里人设之后、世界设定之前（`today.her_birthday`）；`cache_breakpoint` 位置没动。
- **今天的几句** `eidolon/today.py`：`today_lines(now: datetime, character: Character, characters: Iterable[Character], talking: Talking) -> list[str]`，按东京日期，顺序是她的生日、同伴生日（偶像顺序，显示名用「、」连）、节假日。`talking` 现在不影响内容，留给日程那一块。引擎里 `ConversationEngine._now_prompt` 把 `now_prompt(...)` 和这几句用换行接在同一节，回合（打字、通话）和搭话都走它。
- **判断题（审查提出、没改）**：`Birthday` 和 `is_day_of_the_year` 还放在 `producer.py`（角色也用了，以后可以挪到单独模块）；MM-DD 的解析在 `characters.py`、格式化在 `app.py`，「M月D日」在 `producer_prompt` 和 `her_birthday` 各写了一次；`_now_prompt` 七个参数大多透传给 `now_prompt`。都是小重复，等日程那一块往「此刻」里加东西时再看要不要收拢。
- **测试**：`tests/test_calendar.py`（节假日接口、提示词里三类句子、通话和搭话）；`test_characters.py` 加生日几条；`test_text_turn.py`、`test_world_setting.py` 里断言共用固定部分全文的两处跟着加了生日那句。
