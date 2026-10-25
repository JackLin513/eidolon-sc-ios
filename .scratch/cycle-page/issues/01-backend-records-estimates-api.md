# 01: 后端走通：记录、推算、接口

**What to build:** 用户能通过接口给任何一位角色记下一次经期（第一天加天数），之后能改、能删；读接口返回 29 位每位的记录和后端现算出来的推算。前端这张票不动，用接口就能验。前提是「她的周期」已经合进 main。

**记录表**（用户数据）：每行有记录 id、用户 id、角色 id、第一天（`YYYY-MM-DD` 的日历日，不存时区）、天数（1–10）、记下的时刻。登记进用户数据，删账号、删除全部数据时一起删；删一段对话不碰它。

**规则**：
- 角色必须在名单上。
- 第一天不能晚于今天。今天按制作人的有效时区算（档案 → 设备 → 上海），请求带设备时区，和日程一样。
- 天数 1–10。
- 同一位角色的记录不能重叠，首尾相接不算重叠；改一条时不和它自己比。
- 不合规时返回 422，带原因：未来、天数越界、重叠（重叠时带上和哪一次重叠了）。

**推算**是一个新的纯模块：输入一位角色的全部记录和今天，输出 `Estimate`（类型见规格「推算」）。规则整套照规格逐条写：
- 只记一次时用 28 / 5，记原因「只记一次」。
- 记满两次后取最近至多 8 个间隔，去掉 <15 天和 >60 天的。
- 锚点夹在 22–38 天，≥ 锚点 1.6 倍的间隔当作漏记剔除。
- 只有一两个间隔且都 ≥ 45 天时，按最接近的整数个 28 天折算；出现第三个这样的间隔就不折算，当她本来周期长。
- 周期取剩下间隔的中位数，四舍五入到整天。
- 最长最短差 >7 天记「长短不一」。
- 经期天数：有可用间隔时取最近 6 次的中位数；还没有时取最后一条记的天数和 5 中较大的。
- 推算 3 次经期；经前是每次经期第一天之前的 5 天。
- 过了推算的日子还没有新记录时记「这次可能还没记下」，推算不往后挪。
- 过去的估算平均差：只用当时之前的记录重算，能比的不少于两个时才给，保留一位小数。
- 今天在哪：记下的经期第几天、推算的经期、推算的经前，或者都不是。

推算不存库，每次读的时候现算；它从不读她真实的周期。

**接口**：
- `GET /api/cycles`（带设备时区）：两个开关任一关着时只返回「没开」。开着时返回今天，以及 29 位每位的记录（按第一天排）和推算（没记过的为 null），顺序照角色名单。
- 记一次：`POST /api/cycles/{角色 id}/records`。
- 改一次：`PUT /api/cycles/records/{记录 id}`。
- 删一次：`DELETE /api/cycles/records/{记录 id}`。
- 记、改、删都返回这位角色更新后的记录和推算。别人的记录、不认识的角色返回 404；开关任一关着时写 409。
- 开关关着时记录不删，再打开接着用。

**开分支**：这是「周期页」的第一张票。分支 `feat/cycle-page` 从当时的 main 开，第一个提交从 `feat/cycles` 取来 `.scratch/cycle-page/`（规格和这五张票），然后推到 origin、开 draft PR。见规格「记录」「推算」「接口」和 Testing Decisions。

**Blocked by:** None (can start immediately)：但要等「她的周期」合进 main

**Status:** done

- [x] 第一个提交带上规格和票；开工前核对 main 上已有「她的周期」（`EIDOLON_CYCLES`、账号接口的 `cycles`）；推到 origin、开 draft PR
- [x] 推算纯函数的测试，照规格 Testing Decisions 的每一条：
  - [x] 没有记录时没有推算；只记一次时用 28 / 5（记的天数大于 5 时用记的）
  - [x] 规律的一组记录：中位数、最近 8 个间隔的上限、最近 6 次的经期中位数、平均差
  - [x] 去掉 <15 和 >60 的间隔；按锚点的 1.6 倍剔除；锚点的夹取
  - [x] 折算：56 → 28、84 → 28、50 → 25；第三个长间隔出现后不折算
  - [x] 最长最短差 7 时不变淡、8 时变淡
  - [x] 过了日子：当天还不算过了，过了以后推算不往后挪
  - [x] 平均差：能比的不足两个时没有；不在 15–60 天或 ≥ 1.6 倍的不比
  - [x] 推算 3 次经期，每次前 5 天是经前；今天在哪的四种情形
- [x] 记、改、删（HTTP 接缝，`make_client` 加 `FakeClock`，档案接口设时区）：
  - [x] 合法的存下，并返回更新的推算
  - [x] 未来的日子被拒，用 `Pacific/Auckland` 测今天的边界
  - [x] 天数 0 和 11 被拒；重叠被拒；首尾相接不算重叠；改成和别的记录重叠被拒
  - [x] 不认识的角色、别人的记录返回 404
- [x] 读：29 位，顺序照名单，没记过的推算为 null；换一个她真实周期完全不同的密钥，接口返回不变
- [x] 开关：部署者关或用户关时，读返回「没开」、写 409；关了再开，记录还在（先例 `test_schedule_switch.py`、`test_reach_out_switch.py`）
- [x] 删账号后记录表不剩这位用户；删一段对话后记录还在（`test_database.py` 登记新表，`test_delete_account.py`）
- [x] pyright、ruff 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 票收尾：Comments 里写下读、写接口的形状和 422 的原因文案，给票 02、04 用；推一次让 CI 跑、跑 `code-review`

## Comments

### 实现说明（票 01）

**模块**
- `backend/src/eidolon/cycle_estimate.py`：推算，纯函数 `estimate(records: Sequence[Logged], today: date) -> Estimate | None`。不读她真实的周期，也不读库、开关、时钟。
- `backend/src/eidolon/cycle_records.py`：`CycleRecords`，挂在 `Backend.cycle_records` 上。新表 `cycle_records`（id、user_id、character_id、first_day、days、recorded_at），已登记进 `database.USER_DATA`。开关看的是 `Cycles.switch_of(user_id) is True`。
- `backend/src/eidolon/cycles_api.py`：下面四个接口，原来的开发用强制接口挪进 `_add_dev_routes`。

**读**：`GET /api/cycles`，带 `X-Timezone`
- 关着时返回 `{"enabled": false}`。
- 开着时返回 `{"enabled": true, "today": "2026-10-25", "characters": [Her, ...]}`。全部角色都在，按 `in_idol_order` 排，和 `/api/characters` 同序。
- `Her` 是 `{"character_id", "records": [{"id", "first_day": "YYYY-MM-DD", "days"}], "estimate": Estimate | null}`，记录按第一天从早到晚。
- `Estimate` 是 `{"cycle", "period", "reasons": ["once"|"irregular"|"missed"|"late"], "periods": [{"first_day", "days"}] × 3, "off_by": number | null, "today": {"kind": "recorded", "day": N} | {"kind": "estimated"} | {"kind": "premenstrual"} | null}`。
  - `reasons` 按 once、irregular、missed、late 的顺序排，空数组就是不变淡。
  - 经前是 `periods` 里每次第一天之前的 5 天，接口里不单独给。
  - `off_by` 保留一位小数，整数也照样是 2.0 这种形式，前端显示时去掉「.0」。

**写**：都带 `X-Timezone`，成功时返回这位角色的 `Her`
- `POST /api/cycles/{character_id}/records`，正文 `{"first_day", "days"}`。
- `PUT /api/cycles/records/{record_id}`，正文同上。
- `DELETE /api/cycles/records/{record_id}`。

**失败时**
- 开关任一关着：409 `{"detail": "周期没有开"}`。先查开关，再查 404。
- 角色不认识、记录不是自己的、记录所属的角色已经不在名单上：404 `{"detail": "没有这条记录或这位角色"}`。
- 不合规：422，带 `reason`。
  - `future`：`{"detail": "不能记未来", "reason": "future"}`，按档案 → 设备 → 上海的时区算今天。
  - `days`：`{"detail": "天数应在 1 到 10 天之间", "reason": "days"}`。
  - `overlap`：`{"detail": "和 M月D日 那次重叠了，要改就编辑那一次", "reason": "overlap", "overlapping": {"id", "first_day", "days"}}`。前端直接显示 `detail` 就是规格里的那句。
- 第一天写成不合法的日期时，是 FastAPI 自带的 422，不带 `reason`。前端用自己画的小月历，不会发出这种请求。

**实现中自己定的几处**
- 规格的测试例「84 → 28」：84 天超过 60，在折算之前就被去掉了，结果走的是「全被去掉时用 28，记可能漏记」。结果和测试例一致，所以单独写了一条测试，没算进折算的测试里。按规格的顺序，能被折算的间隔只有 45–60 天这一段。
- 「长短不一」看的是折算以后剩下的间隔。
- 中位数和平均差都用四舍五入，不用 Python 的 `round`：`round` 遇到正好一半时取偶数。
- 审查以后改的：`NotFound` 改名成 `NoSuchRecord`（`store.NotFound` 已经用了这个名字）；写入拆成记、改、删三个事务体，共用一个 `_check`；折算的测试按上面那条拆开。
- 审查里属于判断题、没改的：
  - `Refused`、`NoSuchRecord`、`CyclesOff` 的异常处理注册在整个应用上，以后哪个接口漏接了 `CyclesOff` 都会变成 409。这和 `ScheduleClosed` 的做法一样。
  - `Logged`、`Record` 和 `periods` 里的（第一天, 天数）是同一对字段，没有合成一个类型。
