# 07: 记忆和搭话迁到数据访问层

**What to build:** `Memories` 和 `ReachOuts` 迁到数据访问层。以下这些的读写都经过这一层，事件循环上不碰库，行为和现在一样：
- 记忆的整理、检索、删除、清空，向量的读写；
- 搭话的调度、开关、记下。

`Store.add_reach_out` 不再拿着锁、在线程里读事件循环那边的通话集合。

**Blocked by:** 04

**Status:** ready-for-agent

- [ ] 两个模块不再自己开连接、不再持有锁，碰库的公开方法改成 async。
- [ ] 记忆和搭话里包读库的 `to_thread` 删掉；最近邻搜索这类纯 CPU 的活照样放在线程里。
- [ ] `add_reach_out` 改成接收「她在不在通话里」这个参数，由调用方先在循环上查好。事务体里不再调 `Calls.in_call`。
- [ ] 受影响的测试通过，CI 绿。

## Comments

### 票 02 交接

- `Reembeddable.forget_other_models` 改成了 async。`Memories.forget_other_models` 现在是在 `to_thread` 里跑原来的同步体，用 `Memories` 自己的连接和锁。迁移时改成一个写任务。

### 票 03 交接

- `ReachOuts._due` 拿着自己的锁，在自己的连接上调 `store.read_profile(self._db, …)` 读档案。迁移时改成在层的读任务里调。
- `/api/account` 里的 `reach_outs.switch_of` 还在 `run_in_threadpool` 里。
