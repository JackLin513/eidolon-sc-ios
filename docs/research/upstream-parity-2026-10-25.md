# 上游对齐调查（2026-10-25）

只读比较。上游 `/Users/jacklin/Developer/IdeaProjects/eidolon-sc` 在 `bf82f226`；本地 `call-mvp`。方法：对现有 `build/oracle/*.json` 跑 `python3 tools/oracle/compare.py`（不联网、不用密钥），再把三个场景的六条消息逐一与上游比较；随后按源码追溯。`compare.py` 报出第一处就返回（`tools/oracle/compare.py:45-72`），所以“每个场景正好两处”来自补充的全量逐消息比较，不是 `compare.py` 的输出。

## 1. Oracle 报告的两处差异

三个场景（`scenario`、`scenario-call`、`scenario-call-directed`）都是同样两处，且都在 system 消息里。

### 1.1 message 0：缺她的生日

上游在所有人设之后、世界设定之前固定放一行（不是只有生日当天）：

```
你的生日是4月25日。
```

- 上游：`shared = [character.sheet, her_birthday(character)]`，见 `backend/src/eidolon/engine.py:1187`；生成见 `backend/src/eidolon/today.py:80-82`。生日字段已是必填，见 `backend/src/eidolon/characters.py:71`、`136-139`、`234-239`，数据见 `characters/characters.toml:67`。
- 本地：shared 只有 `[sheet] + world + format`，见 `EidolonCore/Sources/EidolonCore/EidolonTurn.swift:829-838`。
- 数据侧还有两层缺口：
  - 当前包 `build/eidolon-content.eidolonpkg` 的 `characters/characters.json` 里 29 个角色的 `birthday`、`age`、`short_name` 全是 `null`（本次直接读包确认；未核对该包的导出时间）。
  - 本地 `CharacterConfig` 没有这些类型化字段（`EidolonCore/Sources/EidolonCore/CharacterConfig.swift:6-22`），只把整个对象留在 `raw`（同文件 `60-87`）。导出器本身会原样复制 TOML 键（`tools/export_content_bundle.py:191`），所以重新导出即可带出数据；提示词只需要 `birthday`，端上补它的解码与传递即可。

### 1.2 message 4：缺“往年今天站过的 live”那一行

上游原文：

```
今天是7年前你站上「バンダイナムコエンターテインメントフェスティバル」第2天的日子（2019年10月20日，東京ドーム）。那是过去的事，今天没有这场演出；可以当回忆顺口提一句，不要说成今天的事。
```

- 上游：`_now_prompt` 在 `now_prompt` 之后接 `today_lines`，见 `backend/src/eidolon/engine.py:1143-1151`；live 周年行的生成见 `backend/src/eidolon/today.py:59-77`，按东京日期算（`today.py:24-26`）。
- 本地：`NowPrompt.text` 只有此刻、说话方式、上次联系、制作人生日和好感行（`EidolonCore/Sources/EidolonCore/NowPrompt.swift:26-64`），没有 `today_lines`。插入点在 `EidolonTurn.swift:249-261`（打字/通话）和 `ReachOut.swift:65-81`（搭话）。
- live 数据本地已有：`WorldSetting.swift:57-67` 的 `LiveDay.date/venue`、`80` 的 `lives`、`210-215` 的 `livesOf`。生日也可从重新导出的角色包取。
- 节假日没有本地实现：上游用 `holidays` 库的日本日历（`backend/src/eidolon/japan_holidays.py:13-26`），本地 `NowPrompt.swift` 无对应逻辑，需要补数据或算法。

### 需要改什么（本次未实现）

1. 用新上游重新导出包；给 `CharacterConfig` 增加 `birthday`（月/日）的类型化解码；在 shared 的 sheet 后加 `你的生日是X月Y日。`。`age`/`short_name` 只被周期和日历 UI 用（`backend/src/eidolon/cycles.py:150`、`backend/src/eidolon/app.py:488`），不是当前提示词所需。
2. 新增 `today_lines` 等价的 `TodayLines`：她的生日当天提醒（`backend/src/eidolon/today.py:19-21`、`42-43`）、其他偶像生日（`44-52`）、日本节假日（`53-54`）、她往年当天的 live（`55`、`59-77`）。统一按东京日期，打字、通话、搭话都追加在“此刻”之后。
3. 重新跑 oracle 三个场景；预期 message 0 与 message 4 都消失。

## 2. Oracle 三场景之外的提示词偏差

| 项 | 上游 | 本地 | 影响 |
|---|---|---|---|
| 搭话规则 | `REACH_OUT_RULES` 有“其次是你这周的工作（如果有）”，并要求过去 live“先对照现在的年份”（`backend/src/eidolon/engine.py:525-533`） | `ReachOut.swift:20-30` 缺少前半句；`27` 说“有日期的 live”，未限定“快到的”，也没有“已过去的只当回忆、先对照年份” | 独立于日程功能也应同步措辞 |
| 通话中的告别/警告措辞 | 通话里 `way = "hangs_up"`，用“要挂电话了”的台词（`engine.py:746-753`；两套台词见 `affinity.py:360-371`，选择在 `449-452`） | 无论是否通话都传 `.parts`（`EidolonTurn.swift:243-248`）；`.hangsUp` 的文案在 `Affinity.swift:220,225` 存在但从未使用 | 通话里达到结束/警告阈值时，她说的是“不想聊了”而不是“要挂电话” |
| 标题输入 | 读“events and all but her reach-outs and her being unwell”（`backend/src/eidolon/titles.py:1-16`、`124-127`、`184-192`），即包含对话事件 | 只把 `StoredMessage` 的时间线给模型，并过滤 `reach:`（`EidolonCore/Sources/EidolonCore/Title.swift:24-37`），没有事件 | 有挂断、通话失败等事件时标题可能少信息；不影响现有 oracle |
| 日程提示 | `schedule_lines` 在“此刻”之后（`backend/src/eidolon/engine.py:1149`；内容见 `backend/src/eidolon/schedule.py:367-394`） | 无日程功能，`NowPrompt.swift` 不输出 | 见第 5 节，日程整体超出首版 |

## 3. 好感度：数值和语义都要改

| 项 | 上游 | 本地 |
|---|---|---|
| 五档步长 | `LEVEL_STEPS = (-1.5, -0.5, 0, 0.1, 0.2)`（`backend/src/eidolon/affinity.py:93`） | `[-5, -2, 0, 1, 2]`（`EidolonCore/Sources/EidolonCore/Affinity.swift:45`） |
| 每日上限 | `GAINS_PER_DAY = 0.6`（`affinity.py:117`） | `6.0`（`Affinity.swift:48`） |
| 忍耐/受伤权重 | 单独的 `LEVEL_HURTS = (5, 2, 0, 0, 0)`（`affinity.py:97-101`）、`OUT_OF_LINE_HURT = 10`（`106-111`）；`hurt()` 独立计算（`456-466`） | `hurt = max(-step, 0)`（`Affinity.swift:133`），直接从好感步长推导 |
| 阈值 | 警告 6、结束 12，取最近 8 回合（`affinity.py:148-159`） | 同样是 6/12/8（`Affinity.swift:50-52`） |
| 上限取整 | `round(left, 9)`（`affinity.py:719-724`） | 直接 `min`（`EidolonTurn.swift:664-666`） |

**关键陷阱**：本地现在的 `hurt` 是从步长推出来的（`Affinity.swift:133`），只是碰巧因为旧步长 `[-5,-2,0,1,2]` 等于上游 `LEVEL_HURTS` 的 5/2/0/0/0 才“看起来对”；出格同理，`-10` 步长给出 10 的 hurt。若只把 `levelSteps` 换成上游五档，level 0/1 的 hurt 会一起变成 1.5/0.5，累计到警告线 6 要四次 level-0，累计到结束线 12 要八次，而上游三次 level-0 就结束。必须先拆出独立的 `hurt`，用 `LEVEL_HURTS`/`OUT_OF_LINE_HURT`，再改步长；出格的 10 本身不用改。

另外，上游的“出格次数”按“本次通话内”或“本对话最近打字回合”分别计数（`affinity.py:145-146`、`485-502`）；本地是整段对话最近 8 条角色消息统一计数（`EidolonTurn.swift:226-230`、`584-599`）。同一段对话多次通话时会串算。

**旧数据**：本地消息表只存 `hurt` 和 `out_of_line`（`EidolonTurn.swift:684-699`），不存 judge 的等级。但当前存下的 `hurt` 已经等于上游 `LEVEL_HURTS`/`OUT_OF_LINE_HURT` 的数值（旧步长恰好相同），所以拆出独立 `hurt` 后可以直接沿用旧值；只有以后调整权重才需要迁移。

## 4. 通话行为缺口

| 问题 | 本地 | 上游 | 后果 |
|---|---|---|---|
| 她中途挂断被丢掉 | `CallSession.answer` 收到 `.finished`（不绑定它带的 `TurnRecord`）直接 `break`（`EidolonCore/Sources/EidolonCore/CallSession.swift:294-303`） | 每回合后查 `she_hangs_up() or limit_reached()`（`backend/src/eidolon/call.py:1644-1654`）；原因与冷却消息见 `backend/src/eidolon/call_outcome.py:35-53`、`255-288` | 回合引擎已把对话标成结束并写 `ended` 事件（`EidolonTurn.swift:702-713`），但通话 UI 还在继续；下一回合在 `EidolonTurn.swift:175-176` 抛 `conversationEnded`，通话只显示失败 |
| 结束原因只有三种 | `CallEnd` 只有 `hungUpByProducer/timeLimit/failed`（`CallSession.swift:63-67`）；记录只映射 `hung_up`/`call_failed`（`448-459`） | 七种：`not_connected/dropped/duration_limit/turn_limit/own_key/she_hung_up/cooldown`（`call_outcome.py:35-53`） | 无法区分她挂断、冷却、掉线、未接通；UI 和事件都缺信息 |
| 她在通话里的台词错了 | 永远 `.parts`（`EidolonTurn.swift:243-248`） | `in_call` 时 `hangs_up`（`engine.py:746-753`） | 达到阈值时提示语与行为不一致 |
| 时长/回合上限 | 默认 3600 秒、无回合上限（`CallSession.swift:96,112`；README.md:18） | 默认 10 分钟、40 回合（`backend/src/eidolon/config.py:227-228`） | 可能是产品选择，不是 bug；但与上游默认不一致 |
| 打断/补充 | 她播放时关麦（`CallSession.swift:400-411`），这段时间用户说话被丢；README.md:23 已承认 | `InterruptionFrame` → `TurnTaking.user_started_talking`（`call.py:1536-1537`；`backend/src/eidolon/turn_taking.py:158-198`），丢回复后等补充，4 秒超时（`call.py:1714-1724`、`665-668`） | 没有 barge-in；ADR-0007 的决策却写了 4 秒补充宽限和打断语义（`docs/adr/0007-on-device-call.md:3`），与代码和 README 矛盾 |
| Fish 合成 | 每段一个 HTTP POST，MP3 一次性返回；请求体只有文本、音色、格式、normalize，模型在 header（`EidolonIOS/Core/Call/FishSynthesis.swift:10-25`） | 每段一个 Fish websocket 会话，带采样率、延迟、韵律、温度/top_p、发音词典，并预开下一段连接、留备用连接（`call.py:413-437`、`605-663`、`796-798`） | 协议与参数都更少；实际延迟、段间衔接和失败恢复的差距未测，见第 7 节 |
| Soniox / 文本输入 | 只有 1 秒重连（`CallSession.swift:98,113`）；无打字输入、静音、只看文字 | `user_typed`、`text_only_switched`（`turn_taking.py:186-197`） | 通话中不能用文字补充或切“只看文字”；v1 可暂缓，但要登记为差距 |
| 统计 | 无通话活动/结果统计 | `call_outcome.py` 的 `_ENDED_BY` 和通话记录（`45-59`） | 超出首版统计范围 |

优先级建议：先修“她挂断被丢掉”和 `.hangsUp` 台词（不改音频架构也能做），再决定上限和结束原因，最后做 barge-in/Fish 流式。

## 5. 最近 105 个上游提交的归类

`git log -105` 里只有 6 个需要端上关注（其中 2 个只是检索性能）；其余 99 个不影响端上或属于首版明确不做的功能。

### 直接相关

| 提交 | 内容 | 处理 |
|---|---|---|
| `e032badc` | 日历后端：角色生日、节假日接口、她当天知道 | 必做：生日和 `today_lines` 的数据与提示词 |
| `bf82f226` | 往年 live 明说“过去的事” | 必做：`today.py:73-75` 的措辞 |
| `12fe7bab` | 好感度放慢：步长、每日上限、独立受伤权重 | 必做，但按第 3 节的陷阱整套改 |
| `4fb782dc` | 她知道日程；搭话规则改两处；做完工作 +0.5 | 部分：`REACH_OUT_RULES` 两处措辞可独立同步；`schedule_lines`/`JOB_DONE_STEP` 随日程功能 |
| `c9b2ebd7` | 剧情库向量常驻内存，按版本号刷新 | 可选：按提交说明是纯性能；未逐项验证检索结果是否完全一致 |
| `694e96c7` | 上条的审查后重构 | 可选：同上 |

配套的 `d03c0b99`（好感度测试/文档）、`7d7bc4e8`（通话结算测试）等不改变运行时行为。

### 超出首版范围

| 组 | 数量 | 代表提交 | 判定 |
|---|---|---|---|
| 周期（her）与周期页 | 32（`#3`、`#8`、`#9-20`、`#21-38`） | `841dcbba`、`830e4667`、`5622237c`、`8aa0ac93`、`c6c94da4`、`0b7a679e`、`c13947f7` | 不做：首版无周期、无礼物、无数据包 |
| 日程 | 17（`#60-76`，其中 2 个直接相关） | `a7f71316`、`271089b8`、`e206ab87`、`4fb782dc`、`12fe7bab` | 功能不做；两个相关提交见上表 |
| 日历（后端 + 前端） | 12（`#77-88`，其中 `e032badc` 相关） | `d640f0c1`、`df7b5175`、`edf07d3b`、`e032badc` | 只取后端数据/提示词，不做日历 UI |
| 下线每日任务 | 12（`#48-59`） | `b422231f`、`1c1e7a79`、`9046772a`、`345237a5` | 端上没有每日任务，无需跟进 |
| 玩法页/成就/抽奖 | 5（`#89-93`） | `5e051e58`、`cd589fda` | 不做：首版无礼物、成就、统计 |
| 依赖升级 | 14（`#2`、`#4-7`、`#40-46`、`#94-95`） | `c079eb94`、`80232374`、`ab12cd74` | 无端上行为 |
| 测试/CI/文档/合并/外部仓库 | 10（`#39`、`#47`、`#96-103`） | `88fecb9a`、`e9df5170`、`eff4c5af` | 无端上行为；`102` 只是向量缓存的合并 |

（括号里是 `git log -105` 的序号；其余给的是哈希。六个关注项里，`#70`/`#74` 已计入日程组，`#86` 已计入日历组，另外三项是 `#1`、`#104`、`#105`；所以分组总数 102 + 3 = 105。`#82` 的 `df7b5175` 属于日历组，不在日程组。）

## 6. 建议同步顺序（不实现）

1. 重新导出内容包；`CharacterConfig` 加生日字段；shared 加“你的生日是…”。验证 oracle message 0。
2. 加 `TodayLines`（她生日、其他偶像、节假日、往年 live），接进打字/通话/搭话。验证 message 4；补一个生日当天、一个其他偶像生日的 oracle 场景。
3. 同步 `REACH_OUT_RULES` 的“本周工作”和“过去演出按年份回忆”两处。
4. 整套改好感度：先把 `hurt` 从 `step` 拆出（`LEVEL_HURTS`/`OUT_OF_LINE_HURT`），再换五档步长和 0.6 上限，最后处理旧数据。
5. 让 `CallSession` 消费 `TurnRecord.ended/cooldownUntil`，增加 `she_hung_up`/`cooldown` 结束原因；通话中改用 `.hangsUp` 台词。
6. 决定通话上限（10 分钟/40 回合还是保留 60 分钟/无限回合），再排 barge-in 和 Fish 流式。
7. 若要让标题与上游一致，把对话事件纳入标题输入。
8. 向量缓存只在大剧情库上证明有性能收益时再做。

## 7. 不确定

- 旧好感数据：`hurt` 数值可以沿用（见第 3 节）；但旧数据的 `gained_today` 是按 6.0 上限记的，改成 0.6 后当天剩余额度会按新上限算，是否需要迁移未定。
- 节假日：本地没有 `holidays` 等价库；需要确认是打包日本节假日表，还是实现算法，以及支持年份范围。
- Oracle 只覆盖 2026-10-20 的三个场景；她的生日、其他偶像生日、节假日、日程、通话结束阈值都没有 oracle 覆盖。上面的结论来自源码，不是逐字对照结果。
- 标题需要哪些“对话事件”：上游读 events and all，本地只读消息；具体事件种类是否全部要进标题，未逐项核对。
- 日程是否永远不在首版：项目说明只列文字对话 + 通话 MVP，本报告按“不做”归类；若以后要做，`4fb782dc` 的提示词和 `JOB_DONE_STEP` 需要重新评估。
- 当前内容包的导出时间未知；只能确认包里的 `birthday`/`age`/`short_name` 是 `null`，不能据此判断上游何时加了字段。
- Fish/Soniox 只比较了端点与关键策略，没有做网络行为、延迟和重连的逐项对齐测试。
