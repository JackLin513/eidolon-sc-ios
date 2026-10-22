# 09: 收口和验收

**What to build:** 删掉旧的写法，确认整个后端只经过数据访问层碰库。然后在本地构建版上走一遍主要路径，并为上线前后的对比准备好要看的日志。

**Blocked by:** 01, 02, 03, 04, 05, 06, 07, 08

**Status:** done

- [x] 各模块残留的连接、锁和包读库的 `to_thread` 都删掉。除了数据访问层、健康检查、备份导出和 `restore` 换库文件，没有别的地方再调 `connect`。
- [x] `Backend.aclose` 里按模块倒序关连接的那一串，只剩关闭这一层（以及非库的资源）。
- [x] `test_off_the_event_loop.py` 删掉，它由事件循环上的检查取代。
- [ ] 本机跑一次完整测试（输出写文件、包 timeout），CI 绿。
- [x] 按 `docs/agents/local-acceptance.md`，在本地构建版上用 Playwright 验收：发消息、打一通电话、送礼、删账号；看一眼后端日志，没有事件循环检查的 error。
- [x] 在实现说明里列出上线前后要对比的日志：`event loop ran`、写队列和读池的 warning、checkpoint 的 error，各自用什么 grep。

## Comments

### 票 01 交接

- 票 01 留下的过渡写法：`dashboard.summed_up`、`admin_prices_api.described_by`、`/api/account` 的 `run_in_threadpool`，`assembly` 里 `gifts.notice` 的 `to_thread`。02、03、05、06 各自收掉；收口时 grep 一遍 `run_in_threadpool` 和 `to_thread`，确认只剩纯 CPU 的活。
- `database.py` 模块说明里「the data access layer's, and those of the modules not yet moved onto it」那句，到这时改成只有层（和健康检查、备份导出、restore）。

### 票 03 交接

- `test_off_the_event_loop.py` 只剩回合读库和线程数两个用例。

### 票 04 交接

- `Store.close` 已经删了。`conftest.store_in`、命令行 `_user_command`、`memory_eval._Scratch` 现在只是开 `Database`、建 `Store`、最后 `await db.close()`。
- `test_off_the_event_loop.py` 只剩线程数一个用例：回合读库那个用例删了，由层的检查代替。

### 实现说明（票 09）

**收口。** 01–08 已经把各模块的连接、锁和包读库的 `to_thread` 都收掉了，这张票只剩收尾：

- `grep connect(`：除了数据访问层，只剩 `database.readable`（健康检查）、`backup._export`（`VACUUM INTO` 和校验副本）、`backup.abandon_unfinished` 和 `restore`（换库文件时改的是解开的副本）。
- `grep to_thread / run_in_threadpool`：剩下的都不碰连接——健康检查、备份导出、照片和收款码转码、记忆和设定的相似度、价格目录解析、数据包打包和解包、S3 上传算哈希、`stats.summed_up` 的计数。`threading.Lock` 只剩 `service_clients`（客户端租约，和库无关）。
- `Backend.aclose` 的那串关闭里，库只剩 `database.close` 一处（最先登记、最后关）；其余都是任务、HTTP 客户端和通话。
- `database.py` 模块说明改成「层是唯一入口，健康检查、备份副本、restore 各自开连接」；`connect` 里的注释和 `readable` 的说明一起改了。`assembly.THREADS` 的说明改成读任务和纯 CPU 的活。
- `test_off_the_event_loop.py` 删了。它最后那个用例测的是 32 个线程能同时等，`THREADS` 本身不变。

**测试。** 本机全量（`timeout 550`，输出写文件）：2008 过、1 个失败——`test_proxy.py::test_tunnels_whose_tls_timed_out_leave_the_pool_room` 在高负载下 `ConnectTimeout`，单跑这个文件 33 条全过，和本分支无关。本机这一轮 450 秒，比平时慢；CI 上本分支前几次都是 6–7 分钟，和 main 一样。

**验收**（本地构建版、Playwright、开发登录的一次性用户，走代理连 Fish）：发消息（回复记下 2 条）、打一通电话（接通、挂断后 `calls` 多一行）、送礼（背包 2 → 1，好感度 50 → 53，「送出一件礼物」打勾，三样同一个事务）、删账号（用户和对话都没了，跳回首页）都过。后端日志里没有「on the event loop's thread」的 error，也没有 `event loop ran`。启动时有一条 `write task _open took 922 ms`：冷启动时第一个建表任务读 190 MB 的库文件，开始服务之前就做完了，看日志时不用算它。

**上线前后要对比的日志。** 日志格式是 `时间 级别 logger: 消息`，下面都在服务器上跑，`--since` 按要看的天数改：

```sh
# 事件循环延迟（loop_lag，上线前的基线也用这条）：条数，以及延迟的分布
ssh vps 'cd eidolon-sc && docker compose logs --since 72h backend | grep -c "event loop ran"'
ssh vps 'cd eidolon-sc && docker compose logs --since 72h backend | grep "event loop ran" | grep -oE "ran [0-9]+ ms late, [0-9]+ calls" | sort | uniq -c | sort -rn | head'

# 写队列：排队超过 200 ms、执行超过 200 ms，按任务名数（启动时的 _open 不算）
ssh vps 'cd eidolon-sc && docker compose logs --since 72h backend | grep -E "write task .* (waited|took) [0-9]+ ms" | grep -oE "write task [^ ]+ (waited|took)" | sort | uniq -c | sort -rn'

# 读池：读连接都占着、等了超过 200 ms
ssh vps 'cd eidolon-sc && docker compose logs --since 72h backend | grep -E "read .* waited [0-9]+ ms for a connection"'

# checkpoint：超过 10 分钟没做完的 error，做 checkpoint 本身出错的
ssh vps 'cd eidolon-sc && docker compose logs --since 72h backend | grep -E "the checkpoint has been left undone|checkpointing the database failed"'

# 事件循环检查：漏网的、在循环上拿了连接的（应该一条都没有）
ssh vps 'cd eidolon-sc && docker compose logs --since 72h backend | grep "on the event loop.s thread"'
```

想一次看层的全部日志，`grep "eidolon.data_access"` 即可（`checkpointing the database was held up` 是 info，删账号碰上备份时会有，正常）。
