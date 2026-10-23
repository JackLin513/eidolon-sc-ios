# 01: 走通：导航改「玩法」，`/play` 加两个子页，礼物页拆进去

**What to build:** 玩法页从头走通。导航中间那一项改叫「玩法」（图标 `Shapes`），电脑导航栏和手机 dock 一样；点进去是 `/play` 第一级：「礼物」卡铺满一行放最上面，下面「每日任务与成就」卡（窄屏独占一行、宽屏占两列网格的一格，留着给日历并排），每张卡一个圆底图标、名字、右端 ›、名字下面一行状态；状态读到之前卡片就在、那一行先空着。点卡进子页：`/play/gifts` 是预选的她、抽奖台、重置卡条、我的礼物，连同抽奖弹窗、送礼面板、送出后的提示，玩法一模一样；`/play/tasks` 是每日任务一节和成就一节。子页页首是返回键加卡的名字，两种宽度都有返回键，内容宽度和第一级一样。旧地址 `/gifts`（带 `?to=` 等参数照样带着）跳到 `/play/gifts`，不认识的 `/play/<xxx>` 跳到 `/play`，写法照设置页的旧地址跳转。对话页各处「送她一件礼物」进礼物子页并预选她；每日任务里「挑一件」跳到礼物子页并落在「我的礼物」上，「去对话」不变。导航「玩法」上的点意思不变（有新到的抽奖次数），但在玩法页的任何一级上不出；「礼物」卡的名字旁在有新到的抽奖次数时有点，进了礼物子页（且通话层没盖着）才算看过，只进第一级不算；「每日任务与成就」卡的名字旁在有新解锁的成就时有点，离开那个子页才算看过。两张卡和子页由一张注册表管（id、图标、名字、去哪、显示条件、状态怎么写、要不要点），日历那一块只加一行。好感度和礼物没开放时两张卡都不出现，第一级只剩「玩法暂时没有开放」的 `Empty`，两个子页在页首下面也是同一个 `Empty`；接口回 409 没开放时切成这个样子。不改后端、不改库。见规格「导航」「卡片注册表」「页面和路由」「看过」各节和 Testing Decisions；样子以 `DESIGN.md` 和原型 `prototype/play-hub`（`/gifts?variant=A`）为准。

**Blocked by:** None (can start immediately)

**Status:** done

- [x] 导航：中间一项是「玩法」、图标 `Shapes`（别名 `PlayIcon`，从图标文件导出），导航栏和 dock 一致；`/play` 和 `/play/<子页>` 都在外壳里、当前项都是「玩法」；在子页上再点「玩法」回 `/play`，已在 `/play` 时不动；通话中切到玩法页和子页通话不断、通话条照旧
- [x] 导航「玩法」上的点：条件不变，加「当前项是玩法时不出」；读屏名字「玩法，有新到的抽奖次数」；「礼物页在眼前」改成「礼物子页在眼前」（地址是 `/play/gifts` 且通话层没盖着），只有它成立时才把到账记成看过，玩法页第一级和每日任务与成就子页都不算
- [x] 旧地址跳转：`/gifts` → `/play/gifts`，`/gifts?to=mano` → `/play/gifts?to=mano`（别的参数一并带过去），`/play/xxx` → `/play`，`/play/gifts`、`/play/tasks` 不跳；规则是 `lib/` 里的纯函数，在 `proxy` 里用 `replace` 跳；`giftsHref` 生成 `/play/gifts?to=<角色 id>`
- [x] 路由 `/play`、`/play/gifts`、`/play/tasks` 照设置页 `[category]` 的写法：子页名字是枚举，`dynamicParams` 关掉；子页上刷新、分享链接仍打开子页，浏览器返回键从子页回到玩法页
- [x] 玩法卡注册表（新的 `lib/` 模块）：两张卡 `gifts`、`tasks`，显示条件都是好感度和礼物开着；「礼物」状态「还有 n 次抽奖」+ 背包有东西时「 · 背包 m 件」（m 是件数）+ 有重置卡时「 · 重置卡 k 张」；「每日任务与成就」状态「每日任务 今天 d/3」或「每日任务 今天都做完了」+ 有新解锁时「 · 成就 n 个新解锁」（n 和子页里带点的行同一套算法）；点：礼物卡随新到的抽奖次数，任务卡随 n > 0；接口没回来时状态为空；数据都从现有的礼物状态接口来，没有新接口
- [x] 第一级页面：页首「玩法」大标题同现在礼物页的页首；`PageShell`、`max-w-3xl`、居中、没有第二栏；卡是描边的 `rounded-2xl` 块，圆底 `bg-muted` 图标、名字 Header 字号、右端 muted 的 `ForwardIcon`、下面一行 muted 状态，「礼物」卡铺 `bg-muted` 不描边；整张卡是一个链接、手机上高度不低于 44px；名字旁的点 6px、`bg-foreground`，读屏名字「有新到的抽奖次数」「有新解锁的成就」；卡的顺序和版式写死在页面（第一张铺满一行，其余两列网格、窄屏一列），注册表只管内容；卡片图标礼物 `GiftIcon`、每日任务与成就 `Trophy`（`AchievementsIcon`）
- [x] 子页：页首用现有的 `SubpageHeader`，返回键回 `/play`、两种宽度都有（`isBackNarrowOnly` 不开），标题是卡的名字；内容同第一级的 `PageShell`
- [x] 现有的 `GiftsPage` 拆成两个子页组件和它们共用的状态读取；礼物子页里抽奖、送礼、用重置卡、抽奖弹窗、送礼面板、送出后的提示、送礼成功后重读礼物状态、点 ✕ 取消预选（地址变成 `/play/gifts`）都和现在一模一样；`lib/gifts`、`lib/dailyTasks`、`lib/achievements` 的显示函数不动
- [x] 每日任务与成就子页：每日任务一节、成就一节，顺序不变；「挑一件」跳到 `/play/gifts` 并滚到「我的礼物」（现有锚点 id），「去对话」照旧去对话列表；子页里新解锁的那几行名字旁照旧有点
- [x] 看过：进 `/play/gifts` 时记成看过新到的抽奖次数，在这个子页上发生的到账当场记成看过，不出点；离开 `/play/tasks` 时记成看过合起来的那几个成就；两处存法不变（`lib/seenOnDevice`）；别的设备、别的标签页到账的，这边玩法页上过一会儿也出点（现有轮询不变）
- [x] 没开放：第一级没有两张卡时是 `Empty`，标题「玩法暂时没有开放」、说明沿用现在礼物页那句；`/play/gifts`、`/play/tasks` 在页首下面显示同一个 `Empty`；接口回 409 没开放时切成这样；导航「玩法」照样在、不出点
- [x] `lib/` 测试：`navShell`（`/play`、`/play/gifts`、`/play/tasks` 在外壳里、当前项是 `play`；从子页点「玩法」回 `/play`、在 `/play` 上不动；「礼物子页在眼前」只在 `/play/gifts` 且通话层没盖着时成立；`/gifts` 不再是外壳里的地址），照 `navShell.test.ts` 现有写法改；旧地址跳转的四种情形，照 `settingsCategory.test.ts` 的跳转测试；玩法卡（开着两张、关着零张；礼物卡状态三种拼法；任务卡状态三种；点随到账和看过变化；接口没回来时为空）；导航上的点加「当前项是玩法时不亮」；`giftsHref` 生成新地址
- [x] 后端不改、没有新测试；提交前 `sh scripts/affected-tests.sh <开工前的提交>`，类型检查和 lint 过
- [x] 按 `docs/agents/local-acceptance.md` 在本地构建版上用 Playwright 自己验：宽屏和手机的第一级版式；进子页、返回键、浏览器返回；旧地址跳转；对话页「送她一件礼物」进子页并预选；每日任务「挑一件」落在「我的礼物」；在对话页做完一项任务后「玩法」出点、进第一级点还在礼物卡上、进礼物子页都消失；没开放的样子（本地后台关掉好感度和礼物开关）。能用接口造的状态自己造，只把要人看的留给用户

## Comments

### 实现说明（票 01）

**接口和模块**
- `lib/playRoute.ts`（新）：子页枚举 `PLAY_SUBPAGES`、`playHref`、`playSubpage`、`playRedirect`（只精确匹配 `/gifts`，所以 `/gifts/<id>.webp` 的插画不被跳走；`/play/<不认识的>` → `/play`，参数一并带着）。`proxy.ts` 里 `settingsRedirect(…) ?? playRedirect(…)`。
- `lib/navShell.ts`：`NAV_ITEMS` 的 `gifts` 改 `play`；`isInShell`/`currentNavItem` 用 `playRoute`（`/play` 和已知子页在外壳里，`/play/xxx` 不在）；`isGiftsInView` 改名 `isGiftsSubpageInView`（`/play/gifts` 且通话层没盖着）；新增 `navDots`（「玩法」在当前项是玩法时不亮）。`AppNav`、`ConversationDirectory` 照改。
- `lib/playCards.ts`（新，注册表）：`CARDS` 两张卡，`playCards({ state, newRewards, achievementsSeenAt })` 给出名字、去哪、状态、点；`playTitle(id)` 给子页页首标题。`lib/achievements.ts` 加 `unseenStages`（算「成就 n 个新解锁」，和 `unseenRows` 用同一个 `isUnseen`）。
- `components/play/`：`PlayPage`（第一级）、`PlayCardLink`、`PlayShell`（页面外壳、页首、`PlayClosed`）、`GiftsSubpage`（`GiftsPage` 用 `git mv` 搬来）、`TasksSubpage`、`usePlayState`（两级共用的读取：读状态、告诉外壳、别处到账重读）。路由 `app/(app)/(nav)/play/page.tsx` 和 `play/[subpage]/page.tsx`（`dynamicParams = false`，旧的 `gifts/page.tsx` 删了）。
- 文案：`copy.play`（标题、没开放、两张卡的状态和点的读屏名字）；`copy.nav.play`/`playRewarded`；`copy.gifts.title`、`closed`、`loading` 删了。`giftsHref` 生成 `/play/gifts?to=<id>`。

**判断**
- 「挑一件」用 `go("/play/gifts#my-gifts")`，礼物子页在礼物读到后按地址里的 `#my-gifts` 滚过去（跳过去时「我的礼物」还没渲染，靠浏览器自己滚不到）。内容不够长滚不到页首时停在能滚到的最底。
- 礼物子页不再显示每日任务和成就，所以送礼、抽奖后本地状态里不再改 `daily_tasks`、`achievements`；送礼做完任务的「打勾弹一下」（`justDone`）随之去掉。
- 两级各读一次礼物状态（没有共享缓存）；第一级不读礼物目录。

**验收**（本地构建版，Playwright，一次性脚本已删）：宽屏和手机的第一级、礼物卡铺满一行、任务卡占一格、手机卡高 ≥ 44px；进子页、返回键（两种宽度）、浏览器返回、刷新；旧地址四种情形和插画不被跳；对话页（冷却中）「送她一件礼物」进子页并预选、✕ 取消后地址是 `/play/gifts`；「挑一件」落在「我的礼物」；对话页上「玩法」有点（读屏名字对），第一级和任务子页上导航不出点、礼物卡有点、只进第一级和任务子页点还在、进过礼物子页卡和导航都没点；成就：任务卡「成就 1 个新解锁」和点、子页里那一行有点、离开子页后都没了；没开放（后端 `EIDOLON_AFFINITY_AND_GIFTS=0`）第一级和两个子页都是同一个 `Empty`、返回键在、导航「玩法」在且不出点；礼物子页上抽奖回 409 切成没开放。验收用户已删。

**代码审查**（固定点 096032c）：标准、规格两份报告，建议修的已修：子页里更新每日任务和成就的死代码、孤儿注释、残留的「礼物页」说法、`navShell` 硬写 `/play`、两个子页「正在读取」文案不一致。只报告、没改的判断题：
- 图标放在 `PlayCardLink` 的 `ICONS` 表里，不在 `lib/playCards`（`lib/` 不引图标）。日历那一块加一张卡要改：`PLAY_SUBPAGES`、`CARDS`、`ICONS`、`[subpage]/page.tsx` 里的分派和 `copy.play.cards`，不是一行；`ICONS` 是 `Record<PlaySubpage, …>`，漏了会过不了类型检查。要真做到一行，得让注册表出图标，由日历那一块的第一张票定。
- 礼物卡（铺 `bg-muted`）左边图标的圆底用 `bg-background`，不是 `bg-muted`：叠在一起看不见。原型里也是这样。
- 卡片版式是单行（圆底图标 | 名字加下面一行状态 | ›），照规格字面写；原型 A 的卡更高（`min-h-32`、状态在图标那一行下面），没有照原型。「两列网格」的断点用 `sm:`（640px）。
- `GiftsEmpty` 现在只有「还没有礼物」一处在用；两个子页都有「失败提示、读取中、没开放、内容」同一套判断，没抽出来。
- `components/gifts/` 里的 `DrawDialog`、`MyGifts`、`DailyTasksSection` 等还在原目录，`components/play/` 引用它们。
- `lib/dailyTasks.withDone`、`lib/achievements.withUnlocked` 现在没有生产调用方，只有测试在用，没删（票说显示函数不动）。

### 票 02 交接（这张票留下的）
- 代码里一批注释引用 `DESIGN.md「礼物页」`（`components/gifts/*`、`GiftsSubpage`、`zh.ts` 等）；新写的注释引用 `DESIGN.md「玩法页」`（`PlayPage`、`PlayCardLink`、`PlayShell`、`TasksSubpage`、`[subpage]/page.tsx`）。写 `DESIGN.md` 时「玩法页」一节要在，礼物页各小节的说明搬到子页下面后，把 `components/gifts/*` 里那些引用改成新的节名。
- `frontend/scripts/readme-media.mts` 第 545 行还是 `/gifts` 地址（`page.goto`），靠跳转能打开，但要改成拍 `/play` 第一级。
- 玩法页第一级的卡片版式（单行、礼物卡 `bg-muted` 不描边且图标圆底 `bg-background`、其余描边且圆底 `bg-muted`、状态行高度先占着）写进 `DESIGN.md` 时以代码为准。
