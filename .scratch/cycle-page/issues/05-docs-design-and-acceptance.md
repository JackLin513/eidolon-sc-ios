# 05: 收尾：隐私、条款、配置、README、DESIGN.md、验收

**What to build:** 周期页可以合并。用户从隐私政策和条款里知道多存了什么、推算算不算数；部署者和维护者从文档里知道周期页是什么；整条路在本地构建版上走过一遍。

**隐私政策**：「存了什么」加一项周期记录：
- 存在服务器上，按用户和角色分开
- 进备份
- 删账号时一起删
- 管理者界面看不到内容

「看不到」那一节也补上记录。

**使用条款**：「玩法」那条加一句：周期页的推算只供参考，不作医疗或避孕的依据。

**配置指南**：`docs/configuration.md` 三语的「周期」一节补上周期页：
- 玩法里多一张卡，用户自己记录
- 推算在后端现算、不存库
- 开关关着时卡隐藏，记录留着

**README** 三语：
- 功能列表加一行周期
- 「致谢」在 LAPLACE Eidolon 旁加一行 LAPLACE Cycles
- 加一张周期页截图：在本地构建版上用开发登录和造好的几条记录截，图里不出现真实用户

**`DESIGN.md`**：
- 「The Her-Colour-Only-Here Rule」和「The Scoped Colour Rule」两条各加上周期子页这一处
- 新加周期子页一节：版式、月历的记号、筛选、记录、讲解、免责

**验收**：照 `docs/agents/local-acceptance.md`，在本地构建版上用 Playwright 把规格 Testing Decisions 的「验收」整条走一遍，电脑和手机两种宽度各一次。

**清单**：
- 人工验证项：版式好不好看、讲解措辞、真机
- 部署前手动备份：新的记录表，连同「她的周期」那几样
- 两份规格一起部署；公告草稿在对话里给，不写进票

见规格「文档（这一份的收尾块）」和 Testing Decisions。

**Blocked by:** 02, 03, 04

**Status:** ready-for-agent

- [ ] 隐私政策、使用条款改好，措辞守「文案要少」
- [ ] `docs/configuration.md`、`.en.md`、`.ja.md` 的「周期」一节补上周期页，三语一致
- [ ] README 三语的功能列表一行、致谢一行、截图一张；截图里没有真实用户
- [ ] `DESIGN.md` 的两条颜色规则和周期子页一节都加上
- [ ] Playwright 验收整条走过，结论写进 Comments
- [ ] 人工验证清单、部署前备份清单写进 Comments
- [ ] 这一波最后一次推送后 CI 是绿的
- [ ] 票收尾：跑 `code-review`；转正式 PR 和合并等用户当次说

## Comments

### 票 05 交接（从票 02）

- `DESIGN.md` 里还没有「玩法页 · 周期子页」这一节，`ui/button.tsx` 的 `ghost-destructive` 注释和 `CyclesSubpage.tsx` 已经指向它，补的时候用这个名字。另外，「玩法页」一节还写着「卡：三张」，子页列表里也没有 cycles。
- 要写进 DESIGN.md 的几处实现细节：
  - 她的颜色只注入月历格子、图例和弹窗。
  - 推算变淡时，经前用 `bg-muted/30`，虚线圈用 `outline-her-mark/50`。
  - 「删除这次」用 `ghost-destructive`。
  - 筛选键同对话列表（右上角中性小点）。

### 票 05 交接（从票 03）

- `DESIGN.md`「玩法页 · 周期子页」要写讲解和免责：
  - 两栏下面通栏一块描边的 Accordion（`rounded-xl border px-4`），块名用 Header 字号、min-h-11，正文用 Body 字号，最宽 `max-w-2xl`；导语 muted。
  - 每句的来源放在句末标点前，Meta 字号 muted，下划线，新标签页打开。
  - 示意图是 28 格横条：经期 `bg-foreground/60`、易孕期 `/20`、排卵日前景色（强调色等用户定），其余 `bg-muted`。
  - 免责是页面最后一行，Meta 字号 muted。
  - 右栏「长短不一」那句末尾的「见「青春期」」链接。

