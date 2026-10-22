# 05: 限额、运行记录、清理迁到数据访问层

**What to build:** `UsageLimiter` 和 `ActivityLog` 迁到数据访问层。放行时的扣用量、回合和通话结束时的结算（退还用量、写运行记录），以及回合之外每一次计费服务调用的记录，都不再在事件循环上写库，也不再在循环上等线程拿着的锁。后台每 10 分钟的清理改成分批：停机后积压的那一次，也不会长时间占住写线程。限额照样准确；看板、统计、服务状态的数字不变。

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] 两个模块不再自己开连接、不再持有锁。`ActivityLog` 原来那条单独的快照读连接，由层的 `read`（一个读事务）代替。`spread_bucket` 由层注册到每一条连接上。
- [ ] 扣用量和放行的「检查加扣减」都在一个写任务里判断。新测试：两个同时到达的回合不会都占到最后一个名额。
- [ ] 回合、通话、搭话的结算改成 await。`TurnOutcome.over` 先在循环上给 `recording.calls` 拍快照，再 await 写入，不会丢掉回合结束后才记下的服务调用。c 步给「放行被取消」补的那次结算保留。
- [ ] 运行记录仍然单独写，失败只记日志，不影响回合和通话。
- [ ] housekeeping 分批删除过期用量、运行记录、服务调用记录和汇总，每批一个写任务。每批的行数实测确定，目标约 50 ms 以内，测量记在实现说明里。
- [ ] 看板、统计、服务状态的读取走读连接；后台用户页里读用量和运行记录的地方也一样。
- [ ] 受影响的测试通过，CI 绿。

## Comments

### 票 01 交接

- `spread_bucket` 用 `database.function("spread_bucket", 1, _bucket, deterministic=True)` 注册，在 `ActivityLog` 构造时调。它会把读连接全部借出来，所以只在构造时调。
- 看板（`dashboard.summed_up`）和后台价格（`admin_prices_api.described_by`）现在把读 `ActivityLog` 的同步部分整段放在 `run_in_threadpool` 里。迁完后改成直接 await，CPU 的汇总看情况留在线程里。

### 票 02 交接

- 价格目录的查找（`Pricing.find`、`listed`、`catalog_as_of`）都只读内存，不碰库。看板 `summed_up` 和后台价格 `described_by` 留在 `run_in_threadpool` 里的，只剩读 `ActivityLog`，加上纯 CPU 的汇总和定价。
- `refresh_soon` 必须在事件循环上调，现在在两个 handler 的 await 之后调。收掉 `run_in_threadpool` 时别把它挪回线程里。

### 票 03 交接

- 后台用户页（`admin_users_api`）里还放在 `run_in_threadpool` 里的有：`described` 和 `details` 读 `activity.taken_since`、`limiter.user_limits`、`activity.of_user` 的部分，以及 `set_limits`、`take_off_limits` 里的 `limiter.set_user_limits`。迁完改成 await。
- 命令行 `user usage` 还在 `asyncio.run` 里直接用同步的 `UsageLimiter`。

### 票 04 交接

- `/api/conversations/{id}/turns`（`app.text_turn`）改成了 `async def`，`admissions.turn` 暂时放在 `run_in_threadpool` 里。`admissions.turn` 改成 async 后直接 await。
  - 注意取消：handler 在等放行时被取消，放行拿到的用量和运行记录就没人结算了。通话那边（`Calls._admit_and_start`）用 `shield` 加 `never_set_up` 处理了这种情况，文字回合也要照样处理。
- `/api/ice-servers` 也改成了 `async def`，`calls.ice_servers` 整个放在 `run_in_threadpool` 里，因为它读冷却（`Affinities`，06）。
- `Photos.eligibility` 里的 `usage.check` 现在在回合开头那个读任务的事务体里调（`ConversationEngine._read_before_asking`），用的是 `UsageLimiter` 自己的连接。迁完后改成接收同一条读连接的事务体。
