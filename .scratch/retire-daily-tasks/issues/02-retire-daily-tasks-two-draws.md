# 02: 用户那边整块下线每日任务，每天发 2 次抽奖

**What to build:** 用户再也看不到每日任务，每天北京时间 0 点发 2 次抽奖。**后端**：删每日任务的三项常量和类型（`DAILY_TASKS`、`DailyTask`、`DailyTasks`）、往来记账里算进度的那部分、进度表 `daily_task_progress`（连同它在 `USER_DATA` 的登记）；礼物状态接口去掉 `daily_tasks`、`renews_at`；「这次到账」（回合 `done`、送礼的返回）去掉 `daily_tasks`；做回合、送礼不再因任务到账。启动时一次删掉 `daily_task_progress` 表，表不在也不报错。留下往来记账模块（成就靠它接回合、送礼、通话结束、抽奖、档位变化）、幂等发奖入口、`rewarded_at`、到账记录表和它的旧行。`DRAWS_PER_DAY` 1 → 2，`MAX_DRAWS` 7 和补发逻辑不动。**前端**：玩法卡 `tasks` 改成 `achievements`，名字「成就」、图标照旧，平时写「已解锁 n 个阶段」，有新解锁时写「n 个新解锁」，名字旁的点规则不变；路由 `/play/tasks` 改成 `/play/achievements`，旧路径在 proxy 里跳转（同 `/gifts` → `/play/gifts`，参数留着）；子页只剩成就，页首标题「成就」。删每日任务的一节组件、`lib/dailyTasks` 和测试、`Rewarded` 里的 `daily_tasks`、文案里那一节（连同「去对话」「挑一件」两个键）。抽奖台那句改成「明天 0:00 再发 2 次，最多攒 7 次」，超过 7 次的「+n」和「每天发的已攒满」留着。留下 `lib/rewards`（「玩法」上的点）、`TaskOpenIcon`（成就「集齐」那一行在用）、`lib/achievements`。截图脚本里每日任务的假数据（今天的任务、往进度表写的那段）一起删，不然表删了以后脚本写不进去；截图本身留给票 03 重拍。**词汇表**：删「每日任务」条目；「抽奖」里「做每日任务得到的不受上限约束」改成「成就给的不受上限约束」，仍写「每天发」、不写几次；「数据包」「运行记录」「看板」各去掉每日任务那半句；「成就」「统计」不动（调 `domain-modeling`）。做完后代码里 grep 不到 `daily_task`、`dailyTasks`、「每日任务」（`.scratch/`、`DESIGN.md`、对外文档和 README 留给票 03）。见规格「后端删什么」「抽奖次数」「前端」「词汇表」、Testing Decisions。

**Blocked by:** 01

**Status:** done

- [x] 礼物状态接口没有 `daily_tasks`、`renews_at`；回合 `done`、送礼的返回没有 `daily_tasks`；做一个回合、送一件礼不再到账（`rewarded` 为 null、抽奖次数不变）
- [x] 抽奖：跨北京 0 点补 2 次；已有 6 次时补到 7、不多；已有 8 次（成就给的）时不压回；新用户第一份 2 次；`test_gift_draws.py` 里写 1 次的断言改掉
- [x] 成就照常：解锁到账、集齐给重置卡、`rewarded_at` 更新（`test_achievements*.py` 照过，`test_all_or_nothing.py` 里引用每日任务的随之改）
- [x] 迁移：带着 `daily_task_progress` 表的库启动后表没了，到账记录和成就记录都在；再启动一次不报错；`test_database.py` 的表登记里不再有它、库里也没有
- [x] 删 `test_daily_tasks.py`、`dailyTasks.test.ts`
- [x] 前端 `lib/` 测试：`achievements` 卡的两种状态和名字旁的点、没有 `tasks`；`/play/tasks`（带参数）跳到 `/play/achievements`；`lib/gifts` 抽奖台那句是 2 次、超过 7 次的「+n」照旧；`lib/rewards` 的 `Rewarded` 没有 `daily_tasks`、点的规则不变；`navShell`、`liveConversation` 里引用的随之改
- [x] 构建版前端看一眼：玩法页「成就」卡、子页只剩成就、旧地址跳转、抽奖台那句（`docs/agents/local-acceptance.md`）；整块的 Playwright 验收在票 03
- [x] 词汇表四条改完、「每日任务」条目删掉；代码里 grep 不到每日任务
- [x] pyright、ruff、前端类型检查和 lint 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 票收尾：给票 03 的交接（截图脚本改了什么、文案的新写法）写进票 03 的 Comments；推一次让 CI 跑；跑 `code-review`

## Comments

### 票 02 交接

- 运行记录和看板这边已经拆干净（票 01），`activity.py`、`dashboard.py`、前端 `lib/dashboard` 里没有每日任务了。`Rewarded.daily_tasks` 还在 `happenings.py` 里算，没人读，这张票删。
- 删 `daily_task_progress` 表的迁移可以挨着 `activity._forget_daily_tasks` 写，或者放在 `happenings._open` 里，看哪边顺。迁移测试可以接着写进 `backend/tests/test_daily_tasks_retired.py`。
- 词汇表「运行记录」（「做完一项每日任务也留一条」）和「看板」（「每日任务和成就」小节、三项各做完几次）票 01 后已经和代码对不上了，这张票改词汇表时一起改。
- `test_daily_tasks.py` 里 `test_a_turn_does_the_first_and_gives_a_draw_recording_no_task_done` 断言没有 `daily_task` 记录，随这个文件一起删就行。

### 实现说明（票 02）

- **后端**：`happenings` 只剩成就。`_happened` 改成收 `turns`、`gifts` 等关键字参数，`Counts`、`DailyTask(s)`、`DAILY_TASKS`、`_counts`、`_key` 都删了；`Rewarded` 没有 `daily_tasks`，构造时 `rewarded_at` 成了第三个位置参数。`Happenings` 不再要 `clock`，只有删掉的 `daily_tasks()` 用它，`assembly` 跟着改了。迁移写在 `happenings._open` 里：`DROP TABLE IF EXISTS daily_task_progress`。`database.USER_DATA` 去掉了这张表。`gifts_api` 的礼物状态不再给 `daily_tasks`，`renews_at` 原本就在它里面，一起没了。`affinity.DRAWS_PER_DAY = 2`。
- **前端**：`PLAY_SUBPAGES` 里 `tasks` 改成 `achievements`，`playRedirect` 把 `/play/tasks` 换成 `/play/achievements`，参数留着。`TasksSubpage` 改名 `AchievementsSubpage`，只剩 `AchievementsSection`。`lib/achievements` 新加了 `unlockedStages`，「成就」卡平时那句用它；`playCards` 里原来的 `unlockedCount` 改名 `unseenCount`。文案 `play.cards.tasks` 换成 `play.cards.achievements`（`name`、`unlocked`、`unseen`、`dot`），`gifts.dailyTasks` 整节删掉。
- **测试的辅助函数**：`draw_them`（test_gift_giving）、`holding_cards`（test_reset_cards）和 `test_stats` 的 `give_gifts` 改成一次抽一个，等的天数按 `DRAWS_PER_DAY` 算，不再靠「全部抽完」正好等于张数。`test_all_or_nothing` 让写入失败的表从 `daily_task_progress` 换成了 `achievement_progress`。
- **本地构建版看过**：玩法页「成就」卡先显示「2 个新解锁」，进过子页回来变成「已解锁 2 个阶段」；子页只剩成就；`/play/tasks?x=1` 跳到 `/play/achievements?x=1`；抽奖台写「明天 00:00 再发 2 次，最多攒 7 次」；新用户 2 次；本地开发库启动后 `daily_task_progress` 没了。

**判断题**（只报告）：

- grep 要求的例外：迁移代码（`activity._forget_daily_tasks`、`happenings._open` 的 DROP）、迁移测试（`test_daily_tasks_retired.py`）和断言看板里没有 `daily_tasks` 的那条（票 01 的）都必然带着这个词。隐私政策、使用条款的文案在 `zh.ts` 的 `legal` 里，归票 03。
- 顺带改的几处：「已经抽完了，… 再发 2 次」和「… 会发 2 次抽奖」不改就和次数对不上；`GiftsSubpage` 的 `#my-gifts` 滚动只有「挑一件」在用，一起删了，`MY_GIFTS_ID` 改成文件内常量；词汇表「玩法」条目的卡名也改成了「成就」。
- 成就子页页首是「成就」，下面那块描边块的标题还是「成就」，读起来重复。要不要去掉块标题交给用户定，可以在票 03 改 `DESIGN.md` 时一起决定。
- 审查建议把 `TaskOpenIcon` 改名，因为名字里的 Task 已经不成立。票里写明要留下它，所以没改。
