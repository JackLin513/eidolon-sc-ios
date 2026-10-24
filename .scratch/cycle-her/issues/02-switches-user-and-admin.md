# 02: 两个开关的界面：用户开关全链路、后台「周期」卡

**What to build:** 用户在设置里能关掉周期，管理者在后台能关掉周期；任何一个关着，她的「此刻」不再带那几行（之后几张票的判断、挂断、礼物、对话事件也都看这同一个入口）。**用户开关**照搭话开关的写法存：一张只记着「关掉了周期」的用户的表，不在表里就是开；登记进用户数据，删账号一起删。账号接口多一项 `cycles`（用户自己的开关，部署者关着时为 None），另加一个改开关的接口（部署者关着时 409），照搭话的那一对。票 01 的入口接上它：部署者和用户两个开关都开着才起作用。**设置页**新分类 `cycles`（「周期」），放在第二组「搭话」后面；只在部署者开着时出现（像「搭话」一样，部署者关着时它的地址回到 `/settings`）；一级列表那一行下面写「开」或「关」；分类页一个开关加一行「关掉后她不受周期影响，玩法里不显示周期；记录会留着。」。**后台**配置页「限额与玩法」加一张「周期」卡：一行说明加开关，后台改的优先于 `.env`。周期本身一直在走，关掉再开她还在本来的位置。见规格「开关」和 Testing Decisions。

**Blocked by:** 01

**Status:** done

- [x] 账号接口的 `cycles`：默认 true，关了 false，部署者关着时为 None；改开关的接口，部署者关着时 409（先例 `test_reach_out_switch.py`）
- [x] 用户关掉后「此刻」一句不加；再打开，同一天她还在本来那一阶段
- [x] 删账号后那张表不剩这位用户（`test_database.py` 登记新表，`test_delete_account.py`）
- [x] 前端 `settingsCategory`：多一个 `cycles`，在「搭话」后面；部署者关着时不出现；一级列表的「开 / 关」
- [x] 前端 `adminConfig`：多一张「周期」卡
- [x] 设置分类页和后台卡照 shadcn 纪律，用现有的开关组件和卡片写法；文案只有那一行
- [x] 本地构建版上用 Playwright 看：设置里开关能切、一级列表跟着变；后台关掉后设置里的「周期」消失
- [x] 类型检查、lint 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 票收尾：推一次让 CI 跑、跑 `code-review`

## Comments

### 票 01 交接

- 入口 `Cycles.her_day(..., user_on: bool = True)` 已留参数位，现在没人传；这张票把用户开关读出来传进去（引擎的 `ConversationEngine._her_day` 是唯一调用处）。
- 实时配置项名 `cycles`（`live_config.CYCLES`、`config.cycles_on`），字段 `{"enabled": bool}`，后台接口已能读写；前端 `adminConfig.ts` 的「限额与玩法」还没有这张卡。
- `.env.example` 已写「后台配置页『周期』卡可以改」，这张票做完卡才对得上。

### 实现说明（票 02）

- 后端：用户开关放在 `Cycles`（`cycles.py`）：表 `cycles_off` 只记关了的用户，登记进 `database.USER_DATA`，删号一起删；数据包不读它。`switch_of(user_id)` 部署者关着时为 None，`switch(user_id, on)` 部署者关着时抛 `CyclesOff`。`Cycles` 现在要一个 `Database`。
- 票 01 留的 `her_day(..., user_on)` 没照交接从引擎传进去，改成 `her_day` 异步、自己读用户开关：之后几张票都只调这一个入口，不会有哪处漏看用户开关。引擎的 `_her_day` 跟着变成异步。
- 接口：`/api/account` 多 `cycles`；`PUT /api/account/cycles`（`{"on": bool}`，`StrictBool`），部署者关着时 409「周期没有开放」。
- 前端：`settingsCategory` 的 `SETTINGS_GROUPS` 第二组在 `reach-outs` 后面加 `cycles`；`settingsGroups` 改收 `SettingsSwitches`（`settingsSwitches(account)` 从账号读），按一张「类别 → 开关」表去掉部署者关着的类别，一级摘要也按这张表给开 / 关（文案键合成 `summaries.switchOn/switchOff`）。分类页 `CyclesSettings` 照 `ReachOutsSettings`：开关标签「她们的周期」，加那一行说明（`FieldDescription`）。图标 `CalendarSync`（`CyclesIcon`）。后台 `ITEM_SPECS.cycles` 只有一个开关，排在「限额与玩法」的日程后面。
- 顺手修了票 01 的测试偶发 401（单独提交 60e07888）：`a_noon_when` 找到的日子可能在 30 天会话期限之外，改成在那天登录（`on_a_day`）。
- 验收：本地构建版上用 Playwright 走过——一级列表「周期 开」、分类页开关和说明、拨关后列表变「关」、刷新仍是关、拨回开；后台卡关掉后一级列表没有「周期」，直接开 `/settings/cycles` 回到 `/settings`，账号里 `cycles` 为 null；恢复成 `.env` 后又出现。本地部署者没开搭话，带搭话时的顺序由单测覆盖。

### 审查留下的判断题（票 02）

- 后端开关的存取（表、`_switched_on`、`_switch`、`switch_of`、`switch`）、`CycleSwitch`、`switchCycles`、`CyclesSettings` 都和搭话那一套几乎一样，没有抽出共用的「按用户的开关」；两处时先照抄，第三个开关出现再收。
- 分类页除了那一行说明，还有开关自己的标签「她们的周期」（照搭话页的写法，开关要有可读的名字）；如果只要一行，可以把说明直接当标签。
- 后台卡说明写到了票 04、06 才做的好感度、挂断、暖的礼物（两份规格一起部署，用户看不到中间状态）。
- `Cycles` 现在管三件事：她在哪、开发口子、用户开关；和 `ReachOuts` 一样混在一个模块里。
