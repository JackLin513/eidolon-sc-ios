# 02: 后端走通：工作清单、每周发布、日程表、读和保存接口、开关、看板那一格

**What to build:** 日程的后端全链路，前端还不动，用接口就能验：维护者在仓库里写的一份约 40 项的工作清单（TOML，和礼物目录并列），每周北京时间周一 0 点发布一批工作（7 位、每位 2 到 3 项、总时长 24 到 27 段、はづき不排、四周里每位恰好轮到一次），同一部署所有用户拿到同样的；制作人按自己时区的 7 天 × 上午、下午、晚上把工作排进格子，保存即锁住。**清单**每项 `id`、`name`、`note`（一句说明，不点名角色、不写组合名）、`category`（`practice` / `appearance` / `business` / `private`）、`length`（1 到 3）、可选 `slots`（`morning` / `afternoon` / `evening` 的列表）；工作类和私人约 3:1，只给明显不合理的几项加时段限制，清单里不出现「演出」二字；由 agent 写初稿、维护者改。加载时校验：id 唯一、类别和时段合法、时长 1 到 3、三段的不能带时段限制、名字和说明单行。**每周怎么抽**：以北京时间周一 0 点为界、那个周一的日期作周号；周序号（从一个固定纪元周一数起）整除 4 得轮号、取余得组号，用轮号做种子把全部偶像（`characters.toml` 的 idol 顺序、不含はづき）打乱均分成 4 组（不整除时前几组多一位），这一周取第组号组；用周号做种子给每位配 2 到 3 项，同一周同一项不重复（跨偶像也不）、每位至少 1 项工作类、私人最多 1 项、总时长 24 到 27，不满足就换一组抽、最多试若干次，仍不行报错。**每周的工作表**（非用户数据）：周号、工作实例 id、角色 id、清单字段快照；第一次被读到时在写事务里生成并插入，读和生成同一个写事务，并发首读只生成一份；发布前读不到。**日程表**（用户数据）每行：用户 id、周号、工作实例 id、周几（0–6）、起始段（0–2）、保存时刻、好感度已算过的时刻（空）；唯一约束同一用户同一周同一项只一行；不重叠由写事务里检查。**时间段**上午 6–12、下午 12–18、晚上 18–24，按制作人有效时区（档案 → 设备 → 上海，和「此刻」同一套），0–6 点不属于任何段；「本周」是制作人时区的周一到周日。**能排的格子**按规格里来自原型的 `whyNot`（时长放不下、已经过了、正在进行、时段限制、格子里有别的工作）和 `timeOf`（下周全是 future；本周按今天和当前段；0–6 点全是 future）。**读** `GET /api/schedule`（带设备时区）回：开着没开着、本周和（已发布时）下周的周号、每个周的工作列表和这位用户已保存的放置、哪些周已发布、没发布的本周给出发布时刻（北京周一 0 点的 ISO）；读时顺带生成这周的工作。**保存** `POST /api/schedule/weeks/{周号}`，正文是这次新加的几项（工作实例 id、周几、起始段）带设备时区；写事务里逐项检查（周已发布、工作属于这周、没保存过、按 `whyNot` 能放，占用看库里已保存的加正文里排在它前面的），能放的存、不能放的退回并带原因，返回两组；没有改和删的接口。**开关** `.env` 加 `EIDOLON_SCHEDULE`（不填或 `1` 开、`0` 关、其他值启动报错，照 `EIDOLON_REACH_OUTS` 的 `_switch` 只是默认相反），实时配置加 `schedule`（字段 `enabled`）、后台改的优先（ADR-0013）、暴露 `schedule_on`，后台配置接口能读写；关着时读回「没开」、保存 409。**看板**「好感度」那组加 `scheduled_this_week`（本周排了日程的人数）：打开看板时直接对日程表查一次，数当前北京周里有保存过放置的不同用户数，不跟时间范围走；日程关着时为 null；好感度关着、日程开着时「好感度」那组照样有这一格（接口的显示条件随之改）。不新增运行记录、不加汇总行、不加遥测。**数据**：日程表登记进 `USER_DATA`（放 `affinities` 旁）、每周的工作表进 `NOT_USER_DATA`；删一段对话不碰日程；数据包不带日程、导入不动它。本周已发布的工作不因清单改动而变。她怎么知道、做完加好感度是票 03。见规格「工作清单」「每周怎么抽」「日程的规则」「开关」「后台和看板」「数据、删除和数据包」和 Testing Decisions。

**Blocked by:** None (can start immediately)

**Status:** done

- [x] 工作清单 TOML 约 40 项、四类、工作类和私人约 3:1、少数几项带时段限制、没有「演出」；加载校验上面六条，错了报配置错误并指出哪一项；真实清单通过校验；临时清单缺字段、时长 4、三段带时段限制被拒
- [x] 每周的工作：第一次读生成，7 位、每位 2 到 3 项、总时长 24 到 27、无はづき、同一周同一项不重复、每位至少一项工作类且私人最多一项；两位用户读到同一份；再读不变；改清单（临时配置）后本周不变、下周变；四个连续周合起来每位偶像恰好一次；对真实清单用几百个种子都能生成合法的一周（这条测试保证「换一组抽仍不行就报错」不会发生）
- [x] 发布时刻：北京周一 0 点前读不到下周、0 点后读得到；北京以西的制作人（档案时区 `America/Los_Angeles`）周日读到「本周」和「下周」两份；北京以东（`Pacific/Auckland`）周一 0:30 本周没发布、给出发布时刻
- [x] 保存：合法的几项存下；重叠的格子、时段限制、两段排在晚上、三段不从上午、已过去的格子、正在进行的格子、未发布的周、不属于这周的工作、已经保存过的那项，各自退回并带原因，其余照存；没有改、删的接口；两次并发保存同一格只成一项；改档案时区后读到的放置不变（周几、哪一段）；日程表的「好感度已算过的时刻」留空给票 03
- [x] 开关：`EIDOLON_SCHEDULE` 不填为开、`0` 为关、其他值报错；后台配置改了优先（先例 `test_reach_out_switch.py`、`test_live_config.py`）；关着时读返回没开、保存 409
- [x] 看板：那一格数本周有保存的用户数，不同周不算，关着时为 null，好感度关着、日程开着时「好感度」那组照样有（先例 `test_affinity_dashboard.py`、`test_reach_outs_dashboard.py`）
- [x] 数据：`test_database.py` 检查两张表都登记了；删账号后日程表不剩这位用户的行、每周的工作表还在；删一段对话后日程还在；数据包导出里没有日程、导入不动它（`test_data_package.py`）
- [x] 测试走现有 HTTP 接缝（`make_client` + `FakeClock`，档案接口设时区，库里的东西用 sqlite 直接查）；只测对外行为，不测洗牌内部
- [x] GLOSSARY.md 里「工作」「日程」「时间段」和实现一致，要补就调 `domain-modeling`；pyright、ruff 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 票收尾：Comments 里写下接口形状（读的响应、保存的正文和响应、退回的原因文案、周号格式、看板那一格的字段名、实时配置项）给票 03、04、05 用；推一次让 CI 跑、跑 `code-review`

## Comments

### 实现说明（票 02）

**模块**：`job_list.py`（清单加载和校验，照 `gift_catalog.py`；`ListedJob`、`SLOTS`、`WORK`）、`schedule.py`（周号、抽法 `draw_week`、两张表、`time_of` / `why_not`、`Schedules.read` / `save` / `scheduled_this_week`）、`schedule_api.py`（两个接口）。清单在 `characters/jobs.toml`（41 项：练习 10、出镜 11、事务 10、私人 10；7 项带时段限制；长度 1 的 30 项、2 的 7 项、3 的 4 项），初稿，等维护者改。`DeviceTimezone`（`X-Timezone`）从 `app.py` 挪到 `sessions.py`，和 `UserId` 并列。测试的 `CharacterConfig` 像礼物目录一样拷一份仓库的 `jobs.toml`。

**接口形状**（给票 03、04、05）：

- `GET /api/schedule`（带 `X-Timezone`）：关着时 `{"enabled": false}`；开着时 `{"enabled": true, "timezone": "<有效时区>", "this_week": 周, "next_week": 周 | null}`。`timezone` 是档案 → 设备 → 上海算出来的那个，前端的 `timeOf` 要按它算，不按设备。`next_week` 只在已发布时有。
  - 周：`{"id": "2026-09-21", "published": bool, "published_at": "2026-09-20T16:00:00+00:00", "jobs": [工作], "placements": [放置]}`。周号是那个周一的日期；`published_at` 每个周都给（北京周一 0 点，UTC 的 ISO）；没发布时 `jobs`、`placements` 都是空的。
  - 工作：`{"id": "2026-09-21-vocal-lesson", "character_id", "name", "note", "category": "practice" | "appearance" | "business" | "private", "length": 1–3, "slots": ["afternoon", "evening"] | null}`。实例 id 是「周号-清单 id」。按抽出的顺序排（同一位的挨在一起）。
  - 放置：`{"job_id", "day": 0–6（0 是周一）, "slot": 0–2（0 是上午）}`，按周几、哪一段排序。
- `POST /api/schedule/weeks/{周号}`（带 `X-Timezone`），正文 `{"placements": [放置, …]}`，按顺序逐项检查：返回 200 `{"saved": [放置], "returned": [放置 + {"reason": "…"}]}`。周号不是某个周一的 `YYYY-MM-DD` 时 404；`day`、`slot` 越界 422；关着时 409 `{"detail": "日程暂时没有开放", "schedule_closed": true}`。没有改和删的接口（PUT / DELETE 405）。
- 退回的原因文案（`schedule.py` 顶上的常量）：前端 `whyNot` 也有的六种是「一整天的工作只能从上午排」「当天排不下」「已经过了」「正在进行」「只能排在晚上」或「只能排在下午和晚上」（两项用「和」连，`SLOT_NAMES`），以及「格子里有别的工作」；只有服务器有的是「这一周的工作还没有发布」「这项工作不在这一周」「这项工作已经保存过了」。检查顺序同原型：长度 → 每格（过去 → 进行中 → 时段限制 → 占用）。
- 看板：顶层 `scheduled_this_week`（int，日程关着时 null），不放进 `affinity` 里，因为好感度关着时 `affinity` 是 null。
- 实时配置：项 `schedule`，字段 `enabled`，`PUT /api/admin/config/schedule`；`LiveConfig.schedule_on`；`Settings.schedule`；`.env` 的 `EIDOLON_SCHEDULE`（`.env.example` 已加）。

**表**：`weekly_jobs`（`id`、`week`、`position`、`character_id`、`listed_id`、`name`、`note`、`category`、`length`、`slots` 是 JSON 或 NULL；进 `NOT_USER_DATA`）；`schedule_placements`（`user_id`、`week`、`job_id`、`day`、`slot`、`saved_at`、`counted_at` 留空；主键 `(user_id, week, job_id)`；进 `USER_DATA`，在 `affinities` 后面）。

**判断**：

- はづき靠世界设定的职员名单排除（`idols_of` 用 `world.is_staff`），因为她在 `characters.toml` 里也有 `idol_id`。没有 `world.json` 的部署会把她也排进去；仓库里一直带着 `world.json`，所以没另加规则。
- 读是「先读，缺这周的工作才开写事务抽」（照 `Gifts.state`），写事务里再查一次，所以并发首读只抽一份，平常的读不占写线程。
- 保存时这周已发布、但还没人读过的，就在保存的写事务里先抽出来（浏览器总是先读，这条只是兜底，没单独测）。
- `DRAW_TRIES = 100`：真实清单一次就成的概率约 46%。纪元周一 `FIRST_WEEK = 2026-01-05`。
- 测试：保存的测试用 sqlite 直接写好一周的工作（`test_schedule_saving.publish`），这样每种原因都能确定地造出来；「几百个种子」那条直接拿真实清单和名单调 `draw_week`，跑 520 周。

**审查后没改的**（判断题）：`(user_id, device_timezone)`、`(day, slot)` 一起传，没收成类型；时间段在放置里是下标、在清单里是名字，靠 `SLOTS[s]` 转；`test_deleting_a_conversation_leaves_the_schedule` 审查说它照构造就成立，但票里点名要，留着。
