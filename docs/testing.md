# 测试与调试

```sh
swift test --package-path EidolonCore       # 不联网
python3 -m unittest discover -s tools/tests  # 导出工具
tools/oracle/run.sh                          # 与上游逐字对照提示词（需要上游 checkout 与内容包）
```

真实内容包冒烟测试需要环境变量开启（`EIDOLON_TEST_BUNDLE`）。

模拟器与真机上的调试验证可以用环境变量（仅 DEBUG 构建）注入识别与操作：

- `EIDOLON_IMPORT_BUNDLE`：导入这个内容包（裸文件名会在 Documents 里找），真机也能用
- `EIDOLON_CHAT_BASE_URL` / `_MODEL` / `_API_KEY` / `_EXTRA_BODY`：预置对话模型，并顺带保存下面这些设置；只在传了 `EIDOLON_CHAT_API_KEY` 时生效
- `EIDOLON_ADULT_MODE=1`：单独预置成人模式开关，不依赖对话模型密钥（只对内容包中 18 岁及以上的角色生效）
- `EIDOLON_RETRIEVAL_BASE_URL` / `_API_KEY`、`EIDOLON_EMBEDDING_MODEL`、`EIDOLON_RERANK_MODEL`：预置检索、向量化与重排
- `EIDOLON_STT_PROVIDER=soniox` / `bailian`：选实时识别服务（默认沿用已保存的设置）
- `EIDOLON_SONIOX_API_KEY` / `_MODEL`、`EIDOLON_DASHSCOPE_API_KEY`、`EIDOLON_BAILIAN_STT_MODEL`、`EIDOLON_FISH_API_KEY` / `_MODEL`：预置识别与配音
- `EIDOLON_CALL_FAKE_SPEECH='一行|另一行'`：不打开麦克风，按行注入识别结果
- `EIDOLON_CALL_SPEECH_INTERVAL_MS`：注入的句子按间隔重复，用来排练长通话
- `EIDOLON_CALL_DROP_ONCE=1`、`EIDOLON_CALL_RECONNECT_MS`：让首次识别连接断开、放慢重连
- `EIDOLON_CALL_HANGUP_MS`：到点自动挂断
- `EIDOLON_OPEN_CHARACTER` / `EIDOLON_OPEN_CALL=1`：直接打开某角色的聊天并发起通话
- `EIDOLON_WELCOME_ACT=<0–7>`：欢迎页直接翻到某一幕，只看那一幕的版式
- `EIDOLON_WELCOME=1`：不管看没看过，这次启动先放一遍欢迎页
- `EIDOLON_INSTALLED_SHA='{"content":"…","stand":"…"}'`：直接告诉 App 这台手机已经装着哪几份包（按 sha256），免得为了让它认出旧安装再下一次
- 调试注入开着时（上面任何一个 `EIDOLON_*`）不放欢迎页，免得它盖住界面把用例挡住；要单独看欢迎页就不要带注入
- `EIDOLON_SEND_TEXT='一句话'`：打开聊天后自动发一句
- `EIDOLON_REACH_OUT_HOURS`：把搭话间隔改短，方便看搭话
- `EIDOLON_NO_JUDGE=1`：不接判断模型，由对话模型自行决定是否调用「回顾剧情」
- `EIDOLON_OPEN_HISTORY` / `_TRACES` / `_LATEST_TRACE` / `_MEMORIES`：直接打开历史、追踪、最新追踪或记忆页
- `EIDOLON_IMPORT_STAND_BUNDLE`：导入这个立绘包（裸文件名会在 Documents 里找），真机也能用
- `EIDOLON_OPEN_STAND_PREVIEW=1`：启动时自动打开设置里的立绘预览（只自动进入一次；之后手动打开设置不会再自动跳转）
- `EIDOLON_OPEN_OUTFITS=1`：配合预览直接打开换衣装面板
- `EIDOLON_PREVIEW_WEAR=<outfit id>`：预览打开后直接换到这套衣装（回归检查用）
- `EIDOLON_BAILIAN_WORKSPACE` / `_REGION` / `_MODEL` / `_API_KEY`：预置百炼判断配置，其余设置不动；真机也能用 `xcrun devicectl device process launch --environment-variables` 传入
- `EIDOLON_API_ENV_FILE`：启动后直接打开「API 与模型」，并用这个 `.env` 文件的内容打开导入预览
- `EIDOLON_API_ENV_TEXT`：同上，但内容直接写在环境变量里（UI 测试用，不经过文件选择器）
- `EIDOLON_API_MODEL_LIST=a,b,c`：让「获取模型」用这份固定列表，不访问网络
- `EIDOLON_API_PROBE=success` / `failure`：让服务测试按钮返回注入的成功或失败结果，不访问网络
- `EIDOLON_FAKE_CHAT=1`：对话和通话都用内置的假模型回复，不访问网络（仅 DEBUG）
- `EIDOLON_FAKE_CHAT_DELAY_MS`：假模型先给文字，隔这么久才结束这一回合，用来看收起通话时的实时行（仅 DEBUG）
- `EIDOLON_GIFT_DRAWS` / `EIDOLON_GIFT_RESET_CARDS`：把抽奖次数和重置卡设成固定值，背包清空（仅 DEBUG）
- `EIDOLON_GIFT_BACKPACK=cake:2,black-tea:1`：把礼物放进背包（仅 DEBUG）
- `EIDOLON_GIFT_SEED=42`：让抽奖用固定种子的随机序列，同一种子每次启动给出同样的结果（仅 DEBUG）
- 玩法页真机验收：抽单抽/全抽、送礼分隔线与她的回应、重置卡确认框、她的成就面板、玩法成就页、补算汇总、通话中切玩法（抽奖可用、送礼禁用）、VoiceOver/大字号/暗色/减少动态效果
- 导航真机验收（#94）：四个 tab（朋友圈占位）、玩法五卡与状态行、手机一列/宽屏两列、日历与周期二级页、聊天「她的日程」跳到玩法日历、对话列表没有日历按钮、设置只留周期开关
- 统计与用量真机验收（#96）：设置两个入口、统计的空状态与有数据状态（认识天数、连续来访、热力图、好感度、成就、区间切换、角色排行、24 小时图、礼物）、用量按服务展开、币种合计、每日趋势、改单价与恢复内置价、清空确认、VoiceOver/大字号/暗色/减少动态效果
- `EIDOLON_CLEAR_USAGE=1`：每次打开用量页前清空服务调用记录，让页面从空状态开始（仅 DEBUG）
- `EIDOLON_SEED_USAGE=1`：清空后往用量记录里放三条固定调用（对话、语音合成、语音识别），不访问网络（仅 DEBUG）
- `EIDOLON_SEED_STATS=1`：在没有用户回合的库里放三条固定往来和一次接通通话，让统计页有数据（仅 DEBUG）
- `EIDOLON_GEMINI_API_KEY`：预置 Gemini 向量化密钥（配合 `EIDOLON_CHAT_API_KEY`）
- `EIDOLON_FAKE_GEMINI_BUNDLE=1`：让设置页按「内容包需要 Gemini 向量」显示，不改变真实内容包

真机上这些变量用 `xcrun devicectl device process launch --environment-variables` 传入（键值写成 JSON）。

这些值和真实密钥一样只用于本地验证，不要提交。

## 调试模式（App 内）

设置页最后一节「调试」里有一个「调试模式」开关，默认关闭，所有构建都有。打开后，角色对话页的 `⋯` 菜单末尾出现「调试」，点开可以：

- **清除这段对话的记忆**：只列当前打开的那段对话产出的记忆，勾选后批量删除。记忆是跨角色共享的，删掉后所有偶像都不再想起。
- **修改好感度**：0–100 的滑杆，实时显示档位；「回到 50」复位。设到 0 会开始冷却，设到 0 以上会结束冷却。
- **恢复或切换对话**：已结束的当前对话可以恢复；历史对话可以设为当前（已结束的会同时解除结束）。调试模式下也可以直接在「对话记录」里右滑一段历史对话设为当前，不必打开它再进调试页。
- **保持对话**：打开「不因好感度下降而结束」后，这段对话不会因为冷却、两次越界或累计伤害而结束或挂断，提示词里也不会再出现「不想聊/挂电话」这类结束方向；好感度照常下降，只对这一条对话有效，新对话默认关闭。

写操作在她正在回复或通话进行中会禁用；删除记忆、恢复和切换对话都要确认。这些操作直接写本机用户库，不写对话事件、回合追踪、标题或统计，也不能撤销；平时请保持关闭。领域规则的例外和 schema v14 的当前对话指针见 `docs/adr/0026-debug-mode.md`。


## 朋友圈与后台任务

朋友圈默认关闭。设置 →「朋友圈」打开后，用真机或模拟器上已配置的对话模型即可看到效果：

- 打开 App、回到前台、在前台停留时每分钟、打开朋友圈页时都会调用 `runMomentsDue`；补齐只处理今天到点的计划和回复，更早的丢弃。
- 想立刻看到一条动态，可以把系统时间调到东京的 20:00 左右再打开（日常动态的傍晚时段权重最高），或连点两次进入朋友圈页触发补齐；不要期待准点，计划本来就带随机。
- 后台任务用 LLDB 在已连接的真机上模拟（仅 DEBUG）：

  ```
  e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.jacklin.eidolon.moments"]
  ```

  也可以把 App 退到后台等系统调度；系统可能跳过，跳过了不补历史，下次打开补齐。
- 只有后台任务真的生成了新动态或她的回复才发本地通知；前台补齐不发。通知权限被拒绝时只保留导航点。
- 朋友圈数据在用户库（`moment_*` 表）和 `User/images/moments/`；30 天前的动态连同配图、赞、评论和未露出的回复一起删。删除对话不影响朋友圈。
- 提示词改动后照常跑 `tools/oracle/run.sh`：朋友圈关闭或没有动态时，聊天、通话、搭话的提示词必须与之前逐字一致（7 个场景全部 `identical`）。
