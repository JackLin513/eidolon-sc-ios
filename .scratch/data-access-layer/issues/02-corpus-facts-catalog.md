# 02: 剧情库、资料、价格目录迁到数据访问层

**What to build:** 剧情库（`StoryCorpus`）、角色资料和作品资料的两个 `EmbeddedTexts`、价格目录（`Catalog`）都迁到数据访问层。回合里的剧情检索、资料检索，后台的价格目录，命令行的剧情同步，行为都和现在一样，只是读写不再经过各自的连接和锁，事件循环上也不再碰库。

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] 四个模块不再自己开连接、不再持有 `threading.Lock`；碰库的公开方法改成 async，SQL 留在私有的同步事务体里。
- [ ] 价格目录自己的刷新线程改成 asyncio task：取数照样走 HTTP，写库经过这一层；关停时等它结束。
- [ ] 检索和资料里包读库的 `to_thread` 删掉；纯 CPU 的相似度计算照样放在线程里。
- [ ] 命令行（剧情同步等）用 `asyncio.run` 走同一个层。
- [ ] 直接构造这些模块的测试改成把层传进去、改成 async，照样通过。
- [ ] 受影响的测试通过，CI 绿。

## Comments

### 票 01 交接

- `Pricing.find`、`Pricing.listed` 还直接调 `Catalog.state()`、`Catalog.find()`（同步、碰库）。所以看板（`dashboard.summed_up`）和后台价格（`admin_prices_api.described_by`）先 `await prices.pricing()`，再把整段同步部分放进 `run_in_threadpool`。`Catalog` 迁完以后，`Prices.pricing()` 要在一次读里连目录一起读好，交给 `Pricing`；这两处的 `run_in_threadpool` 等 05 迁完 `ActivityLog` 再一起收掉。
- 刷新目录的 handler 现在是 `await run_in_threadpool(prices.catalog.refresh)`。
