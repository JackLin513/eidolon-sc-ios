# 06: 暖礼物和热水袋

**What to build:** 她经前、经期时，送暖的礼物额外加好感度，她心里也更暖；其他礼物照常，没有礼物会因此少加或扣分，哪里都不提示。**礼物目录**加可选字段 `warm = true`（布尔，启动时照常校验），标热可可、蜂蜜热饮和新加的热水袋三件。红茶、奶茶、咖啡有咖啡因，不标。**热水袋**：类别小物件，稀有度少见，平时也能抽到、能送，进少见那一档的抽奖池。插画照礼物插画署名文件里的提示词骨架，用 magpie-image 的 `generate_image` 生成，**生成前先向用户报张数、等点头**，生成后写进署名文件。**加分**：送出时她在经前或经期（两个开关和好感度都开着），且礼物是暖的，额外 +0.3。这笔和「她喜欢」叠加，不设每天上限，和体贴的上限无关。冷却中照旧一律 `COOLDOWN_GIFT_STEP`，不额外加。**她知道**：给她的送礼那句，在暖礼物、且送出时她在经前或经期时多半句「这几天你不太舒服，收到暖的东西，你心里很暖。」。送礼事件不存「因为这几天」，所以这半句在拼对话记录时，按事件的时刻用同一个周期入口现算；开关现在关着时不加。不暖的礼物不加话。**不留痕**：礼物页、送礼确认、好感度箭头、送礼记录、成就、统计、运行记录都不提、不记。见规格「礼物」和 Testing Decisions。

**Blocked by:** 01

**Status:** done

- [x] 目录测试（`test_gift_catalog.py`）：`warm` 是可选的布尔，三件标了；热水袋在少见档、类别是小物件；插画文件存在
- [x] 这几天送热可可多加 0.3，和喜欢叠加（她喜欢的少见暖礼物一次 1.1）；冷却中不多加；平常日子不多加；任一开关关着时不多加（先例 `test_gift_giving.py`）
- [x] 给她的送礼那句：这几天的暖礼物多半句；不暖的不加；关掉开关后，同一条事件不再带这半句（先例 `test_gift_responses.py`）
- [x] 送礼接口的返回、送礼记录、好感度箭头和平时一样，没有任何「因为这几天」的痕迹
- [x] 插画张数先报给用户、得到点头后才生成
- [x] 词汇表「礼物」那条和实现一致
- [x] pyright、ruff、前端类型检查过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 票收尾：推一次让 CI 跑、跑 `code-review`

## Comments

### 票 02 交接

- 入口 `Cycles.her_day(user_id, character_id, at, timezone)` 现在是异步的，自己看部署者和用户两个开关（用户开关读表 `cycles_off`），`user_on` 参数去掉了；返回 None 就是「不受周期影响」，不用另判开关。
- 给她拼对话记录时按每条送礼事件的时刻现算：每次调用都读一次用户开关，事件多时先读一次开关再算，或者在 `Cycles` 上加一个同步的、接收开关值的入口。
- 测试里要她在某一天：用 `tests/test_her_days.py` 的 `on_a_day`（先注册制作人、找好日子，再用拨到那天的时钟登录）；直接拨 `FakeClock` 跨过 30 天会话就过期，返回 401。用户关开关：`tests/test_cycles_switch.py` 的 `switch`。

### 实现说明（票 06）

- **目录**：`gift_catalog.Gift` 加 `warm`（可选布尔，启动时校验）；`described()` 不带它，礼物页读不到。`characters/gifts.toml` 标热可可、蜂蜜热饮，新加热水袋（小物件、少见、warm）。插画 `frontend/public/gifts/hot-water-bag.webp`，用户点头后生成 1 张（gpt-image-2，透明底），提示词写进 `CREDITS.md`。
- **加分**：`affinity.WARM_GIFT_STEP = 0.3`，`_gift_step` 和 `receive_gift` 多一个 `warmed`；冷却中照旧 `COOLDOWN_GIFT_STEP`。`Gifts.warms(user, gift, character, device_timezone)` 在写事务之前判断「是暖的，而且她此刻在经前或经期」（档案时区 → 设备时区 → 上海，送礼接口读 `X-Timezone`），结果作为参数传进 `Happenings._give` → `Gifts.give`，不存库（ADR-0028、ADR-0029）。`Gifts` 构造时多一个 `cycles`，`assembly` 里 `Cycles` 挪到 `Gifts` 前面。
- **她知道**：`engine._narration` 给暖礼物按事件的 `created_at` 和这个回合的有效时区现算，在经前、经期时接上 `WARMED`「这几天你不太舒服，收到暖的东西，你心里很暖。」，接在「这是你喜欢的东西。」后面。`narrations`、`_since_last_turn` 多一个 `her_days` 参数，回合和搭话都传。
- **周期入口**：`Cycles.her_day` 换成 `Cycles.her_days(user, character) -> HerDays`：开关只读一次，返回一个同步函数 `(at, timezone) -> HerDay`；没有周期时是 `always_neither`。回合、搭话、送礼都用它。
- **判断题**：
  - 仓库目录测试原来要求每件礼物都有角色喜欢（而且有出处），热水袋没人喜欢，也不该编出处。改成只豁免 `hot-water-bag`：断言「没人喜欢的」正好是它。
  - 测试里事件的时刻是 store 按真实时间记的，所以 `test_warm_gifts` 把假时钟拨到真实的现在，再找一把让她这天在想要位置的密钥（`a_key_when`，和 `test_her_days` 里通话的做法一样）。正好在上海零点前后几秒跑可能偶发失败。
  - 加分用的是送礼请求的设备时区，那半句用的是后来那个回合的设备时区。档案里没填时区、两台设备时区不同、又正好在换天附近时，两边可能差一天。和规格「改时区她最多整体挪一天」的口径一样，没处理。
- **审查后的修改**：两处不分支的参数化各留一行（加分测经期，那半句测经前）；`her_day` 并进 `her_days`；`nowhere` 改名 `always_neither`；`narrations` 的 `her_days` 去掉默认值；三处 docstring 重新折行；目录测试改成只豁免热水袋。
- **审查里只报告、没改的**：部署者关、用户关两条测试走的是同一个守卫，按票的验收项留着；`_gift_step` 连着三个布尔参数；`Gifts.warms` 自己读档案算时区（engine 里也有一套「档案 → 时区 → 她的日子」）；`user_id, gift_id, character_id` 这个参数团又多了一项。
