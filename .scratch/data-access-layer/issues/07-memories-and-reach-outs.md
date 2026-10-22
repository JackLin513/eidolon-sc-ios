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

### 票 04 交接

- 「`add_reach_out` 改成接收『她在不在通话里』」这一项已经做了：`Store.add_reach_out(conversation_id, said, contact, in_call: bool)`。
  - 正在进行的文字回合（`taking_turn`）和 `in_call` 都由 `add_reach_out` 在事件循环上、交写任务之前查。
  - 写任务 `_add_reach_out` 只重新确认库里的条件：还是当前对话、没结束、上次联系没变、之后没搭过话。
  - `ReachOuts._reach_out` 传的是 `self._in_call(conversation.id)`。
- `Store.current_conversations`、`reach_out_recorded_as` 已经走层；`ReachOuts` 里对它们的 `to_thread` 删了。还剩 `_due`、`_within_the_day`、`_put_off` 的 `to_thread`，是 `ReachOuts` 自己的连接。
- 搭话的提示词读取并进了 `ConversationEngine._read_before_asking`，和回合共用一个读任务。
- `ReachOuts._due` 在 `to_thread` 里调 `_talking`，所以 `Store.is_taking_turn` 和 `Calls.in_call` 是在线程里读的。`_due` 改成 async 以后，把 `_talking` 挪回循环上。

### 票 05 交接

- `ReachOuts` 不再收 `usage`。`_due` 用模块函数 `usage.read_user_limits(self._db, …)` 读用户自己的限额，`_within_the_day` 用 `activity.read_reached_out_since(self._db, …)` 数今天搭过几次话。两处都在 `ReachOuts` 自己的连接上、拿着它的锁读。迁移时把这两个事务体放进层的读任务里调，连同 `read_profile`。

### 票 06 交接

- `ReachOuts._tier` 现在先看 `affinities.on`（在 `_due` 所在的线程里看），再在 `ReachOuts` 自己的连接上、拿着它的锁调事务体 `affinities.read_status(self._db, …)`。
  - 迁移时，把 `read_status` 放进 `_due` 的读任务里，和 `read_profile`、`read_user_limits`、`read_reached_out_since` 一起读。
  - `affinities.on` 改到循环上、交读任务之前看，作为参数传进去。ADR-0028 要求事务体里不读循环那边的状态。
