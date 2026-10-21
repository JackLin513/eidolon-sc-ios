# 09: 收口和验收

**What to build:** 删掉旧的写法，确认整个后端只经过数据访问层碰库。然后在本地构建版上走一遍主要路径，并为上线前后的对比准备好要看的日志。

**Blocked by:** 01, 02, 03, 04, 05, 06, 07, 08

**Status:** ready-for-agent

- [ ] 各模块残留的连接、锁和包读库的 `to_thread` 都删掉。除了数据访问层、健康检查、备份导出和 `restore` 换库文件，没有别的地方再调 `connect`。
- [ ] `Backend.aclose` 里按模块倒序关连接的那一串，只剩关闭这一层（以及非库的资源）。
- [ ] `test_off_the_event_loop.py` 删掉，它由事件循环上的检查取代。
- [ ] 本机跑一次完整测试（输出写文件、包 timeout），CI 绿。
- [ ] 按 `docs/agents/local-acceptance.md`，在本地构建版上用 Playwright 验收：发消息、打一通电话、送礼、删账号；看一眼后端日志，没有事件循环检查的 error。
- [ ] 在实现说明里列出上线前后要对比的日志：`event loop ran`、写队列和读池的 warning、checkpoint 的 error，各自用什么 grep。

## Comments

### 票 01 交接

- 票 01 留下的过渡写法：`dashboard.summed_up`、`admin_prices_api.described_by`、`/api/account` 的 `run_in_threadpool`，`assembly` 里 `gifts.notice` 的 `to_thread`。02、03、05、06 各自收掉；收口时 grep 一遍 `run_in_threadpool` 和 `to_thread`，确认只剩纯 CPU 的活。
- `database.py` 模块说明里「the data access layer's, and those of the modules not yet moved onto it」那句，到这时改成只有层（和健康检查、备份导出、restore）。
