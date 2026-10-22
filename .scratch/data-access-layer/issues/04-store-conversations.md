# 04: Store（二）：对话、消息、照片、通话记录

**What to build:** `Store` 余下的部分迁到数据访问层：对话列表、历史对话、删对话、对话标题、照片保存、通话的查询和记下、搭话的存取、回合开头的读取。回合、通话、搭话这些路径上，读库不再靠调用点零散地包 `to_thread`；照片保存（约 150 KB）也不再在事件循环上写。

**记录回合、送礼的写入不在这张票里**：`add_turn`、`add_gift`、`keep_call` 留给 06，这里只保证它们照常能被调用。

**Blocked by:** 01, 03（同一个文件，为了避免冲突，不是逻辑上的前置）

**Status:** ready-for-agent

- [ ] 这一部分的方法改成 async，SQL 留在私有的同步事务体里。
- [ ] 回合开头读的那一组（是否已结束、对话记录、上次联系、好感度、能不能发照片、制作人档案）收成一个读方法，回合和搭话共用。搭话里打包成元组的 lambda 删掉。
- [ ] 回合、建立通话、对话列表、标题这些地方包读库的 `to_thread` 删掉。
- [ ] 删对话仍是一个事务（连同把记忆的来源断开、删掉搭话日程），经过这一层。
- [ ] 照片保存是一个写任务；Pillow 转码照样在线程里做。
- [ ] 通话期间每 5 秒查一次「人还在不在」改成走读连接。
- [ ] 命令行里用到这一部分的地方改成用 `asyncio.run`。
- [ ] 受影响的测试通过，CI 绿。

## Comments

### 票 03 交接

- `Store(db)` 已经接收层，账号这一块走层，存在 `self._database`。其余方法还用自己的连接 `self._db` 和 `self._lock`。迁完去掉它们，再把 `self._database` 改名 `_db`。
- `call._hang_up_users_gone` 里的 `active_users`、`get_user` 已经 await，走读连接。「通话期间每 5 秒查一次改成走读连接」这一项可以直接勾掉。
- 回合开头、搭话的档案读取，现在是单独 `await self._store.get_profile`（`_BeforeAsking` 已经去掉 `profile` 字段）。收成一个读方法时，把它并进去。
- `/api/stats` 里的 `contacts`、`kept_calls`、`first_records` 在 `run_in_threadpool` 的 `summed_up` 里，迁完改成 await。
- 测试辅助：`tests.conftest.store_in`、`users_in`；`CallUnderTest.of` 和 `test_turns.turns_in` 经 `store_in` 读对话。
