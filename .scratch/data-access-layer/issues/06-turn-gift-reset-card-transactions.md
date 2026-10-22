# 06: 记录回合、送礼、用重置卡各合成一个事务

**What to build:** `Affinities`、`Gifts`、`Happenings`（连同成就）迁到数据访问层，几处跨模块的写入各合成一个事务：
- **记录回合**：消息、照片、对话事件、好感度变化、每日任务和成就；
- **送礼**；
- **用重置卡**；
- **通话结束**：记下通话，再结算每日任务和成就。

用户发的一条消息、送的一份礼物，要么完整记下，要么什么都没留下。记录回合不再在事件循环上写库。一个回合让她进入冷却时，正在进行的通话照样马上被她挂断。

**Blocked by:** 04, 05

**Status:** ready-for-agent

- [ ] 三个模块不再自己开连接、不再持有锁；`Happenings` 不再借 `Gifts` 的连接写。
- [ ] 上面四处各是一个写任务、一个事务：一个事务体调用别的模块的事务体，把同一条连接传过去。原来 `Affinities` 拿着锁去回调 `Store.add_turn`、两次提交的做法去掉。
- [ ] 送礼、用重置卡的补偿写入删掉。
- [ ] 删掉 `on_cooldown`：写入返回「这一步让她进入了冷却」和冷却到什么时候，由记录回合的一方在 await 之后、在循环上通知通话模块。通话模块读到的「正在进行的是不是这一回合」和现在一样。
- [ ] 运行记录（`daily_task_done`、`achievement_unlocked` 等）仍然在事务之外单独写，失败只记日志。
- [ ] 礼物余额、成就的「检查加写入」都在写任务里判断。
- [ ] 新测试：记录回合、送礼、用重置卡在中途失败时（比如成就结算抛异常），什么都没留下；冷却照样挂断进行中的通话，结束原因和现在一样。
- [ ] 受影响的测试通过，CI 绿。

## Comments

### 票 01 交接

- `LiveConfig.on_change` 的监听器已经是 async（`Callable[[], Awaitable[None]]`）。`assembly` 里暂时是 `config.on_change(lambda: asyncio.to_thread(gifts.notice))`，`Gifts` 迁完后把 `notice` 改成 async，直接 `config.on_change(gifts.notice)`，那句注释一起删。

### 票 03 交接

- `/api/admin/gifts` 的 `gifts.last_grant` 在 `run_in_threadpool` 里。`/api/stats` 的 `affinities.tier`、`happenings.tally` 在 `summed_up` 里，也在线程池里跑。

### 票 04 交接

- `Store.add_turn`、`add_gift`、`keep_call` 还是同步方法：SQL 已经搬进模块级事务体 `_add_turn`、`_add_gift`、`_keep_call`，经 `Database.prepare` 阻塞地交给写线程。合并事务时，直接在新的写任务里调这三个事务体，把同一条连接传进去；然后删掉这三个同步方法，`prepare` 文档里那半句也一起删。
- 回合开头的读取已经收成一个读任务 `ConversationEngine._read_before_asking`（回合和搭话共用）。里面的 `self._affinity(conversation)` 现在调的是 `Affinities.status`，用的还是它自己的连接。迁完后改成接收同一条读连接的事务体。
- `engine._reply` 里还有两处 `to_thread`：`_cools`（`Affinities.cools`）和 `happenings.turn_recorded`。
- `/api/stats` 的 `summed_up` 里只剩 `affinities.tier` 和 `happenings.tally` 还在线程池里读库。`Store` 那三项已经在 handler 里 await 了。
- `/api/ice-servers` 整个 `calls.ice_servers` 放在 `run_in_threadpool` 里，是因为 `refuse_while_cooling` 要读冷却。
- 注意：`add_turn`（`engine._record`）和 `keep_call`（`CallOutcome._settle`）现在是在事件循环上经 `prepare` 等写队列。层的检查只看交出连接的线程，查不到这种等待，所以这一张必须把它们改成 await。
