# 03: 文档收尾和验收

**What to build:** 对外文档、设计规范和旧规格都不再提每日任务，截图重拍，整块用 Playwright 走一遍，公告和部署要点跟前三块合在一起。**隐私政策**：「每日任务和成就」那条改回「成就」（去掉「今天每日任务做到哪了」）；「运行记录」那条去掉「做完了哪项每日任务」；「看不到」那条去掉每日任务；改「最后更新」。**使用条款**：「玩法」那条去掉每日任务，成就给的抽奖次数和重置卡那句留着；改「最后更新」。**配置指南**三语：删「每日任务」那一条；「关掉时」、后台表格看板一行、「看不到的」一行各去掉半句；「每天 1 次」改 2 次。**`docs/deploy.md`** 后台那段、**`docs/data-package-format.md`**「不在数据包里」那句去掉每日任务。**README** 三语：功能句改成「解锁成就能多得抽奖次数」；玩法页截图重拍（`npm run readme-media -- --only gifts`，起后端和构建版前端），图下那句和 alt 随之改。**`DESIGN.md`**：「玩法页」一节里卡的名字改「成就」、子页只剩成就；每日任务那一条删掉；「礼物」子页抽奖台描述里「每日任务给的」改成「成就给的」；导航「玩法」上的点的说明改成「成就到账」；图标一节去掉每日任务相关（空圈 `Circle` 改写成成就「集齐」那一行在用）。**旧规格**：每日任务规格 Status 改 `retired`、开头加一句「2026-10 下线，见 `.scratch/retire-daily-tasks/spec.md`」，正文不改；好感度规格「推算」那段、礼物规格写抽奖次数的两处改成 2 次；成就规格里的位置描述不动。**公告和部署**：四块一起部署（地图 2026-10-23），所以玩法页（`.scratch/play-hub/issues/02` 的 Comments）、日程（`.scratch/schedule/issues/06` 的 Comments）和这一块的公告草稿、手动备份、前后端一起部署，合成一份写进 Comments。见规格「对外文档」、Further Notes。

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] 隐私政策三条和「最后更新」；使用条款「玩法」那条和「最后更新」
- [ ] `docs/configuration.md` 三语、`docs/deploy.md`、`docs/data-package-format.md` 不再提每日任务，抽奖写 2 次
- [ ] README 三语功能句、`gifts.webp` 重拍、图下那句和 alt
- [ ] `DESIGN.md` 五处；代码注释里引用 `DESIGN.md` 的节名都还在
- [ ] 每日任务规格标 retired；好感度、礼物规格里的抽奖次数
- [ ] 全仓库（`.scratch/` 的旧票和旧规格正文除外）grep 不到「每日任务」「毎日タスク」「daily task」
- [ ] 中文过 `humanizer-zh` 再删减；英日文照中文定稿
- [ ] Playwright 验收（`docs/agents/local-acceptance.md`）：玩法页「成就」卡两种状态和子页、`/play/tasks` 跳转、抽奖台那句、看板「成就」小节、配置页说明；本地库造旧进度表和几条 `daily_task` 记录、汇总行后启动，看迁移删干净、再启动不报错
- [ ] 四块合在一起的公告草稿和部署要点（部署前手动备份、前后端一起）写进 Comments
- [ ] 类型检查、lint 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`；跑 `code-review`；draft PR 描述补全（调 `pr`），转正式和合并等用户说
