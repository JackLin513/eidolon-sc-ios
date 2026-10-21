# 03: Store（一）：账号、会话、删账号

**What to build:** `Store` 里账号这一块迁到数据访问层，包括用户、会话、登录方式、制作人档案、封禁。

- **登录**：OAuth 回调、每个请求的会话续期、后台用户页，都不再在事件循环上碰库。平时的请求只读不写，不进写队列。
- **删账号**：删除是一个事务，提交后就回复用户。之后的 checkpoint 只等约 100 ms；有读者没做完，就隔几秒重试。这样删账号不会再把所有写入挡几十秒，旧页也不会悄悄留在库文件里（ADR-0006 的 2026-10-21 修订）。

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] 这一块的方法改成 async，SQL 留在私有的同步事务体里。`Store` 其余的方法暂时照旧用自己的连接（04 再迁）。
- [ ] `signed_in_user`、`admin_user`、后台用户页的 handler 改成 async。登录回调里建用户、加登录方式、建会话都经过这一层。
- [ ] `use_session` 先在读连接上读，到了续期间隔或已过期时再交写任务，并在写任务里重新确认。两个并发请求只续一次，有测试。
- [ ] 层提供 `checkpoint()`：在写线程上把这一次的忙等调到约 100 ms，再做 `wal_checkpoint(TRUNCATE)`，并检查返回值。没做完就隔几秒作为新的写任务再试；超过约 10 分钟仍未做完，记一条 error，然后继续重试。层启动时先做一次。
- [ ] 删账号：封禁记录和删除各是一个写任务，提交后就回复，然后调 `checkpoint()`。原来那种整个过程一直拿着 `Store` 的锁的做法去掉。
- [ ] 新测试：另一条连接开着读事务时删账号，另一位用户的回合照常记下、不用等这个读者；读者结束后 WAL 被清空。
- [ ] 层的测试：有读者时 `checkpoint` 不挡后面的写入，读者结束后重试成功；一直做不完时记 error。
- [ ] 命令行里用到这一块的地方改成用 `asyncio.run`。
- [ ] 受影响的测试通过，CI 绿。

## Comments

### 票 01 交接

- `/api/account` 已经改成 `async def`：先 `await backend.sponsor.state()`，剩下读 `Store`、`ReachOuts` 的部分整段放在 `run_in_threadpool(lambda: {...})` 里。`Store` 这一块迁完后，把这里改成直接 await。
- 层的形状：`Database.write` 在写线程上先 `BEGIN IMMEDIATE`；`prepare` 给构造时建表、迁移用（同步等）；`ON_THE_LOOP_RAISES` 在 `conftest` 里设成真。`checkpoint()` 还没做。
