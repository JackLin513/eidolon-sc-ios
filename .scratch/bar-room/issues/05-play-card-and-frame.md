# 05: 玩法卡和画框

**What to build:** 玩法页多一张「VA-283」卡，点进 `/play/bar` 是全屏的原版画框：吧台、外框、电视，按设备缩放；手机竖着时盖一层「请横过来」；「离开」回玩法页。店门口和她是票 06。

- **先对一遍**：照规格 Further Notes，拿 main 上 `playCards` 和玩法子页的写法、通话条在外壳里的位置去对规格，对不上就在这张票里改规格。光顾的接口已经在 0cf40998 对过了。
- **读 `GET /api/bar`**：`lib/api` 加它的类型（`enabled`、饮品目录、`reward_today`）。
- **玩法卡**：
  - 卡片注册表加一张 `bar`，名字「VA-283」，排在最后，没有点；
  - 只在读到开着时显示，没读到时不显示，免得出来又消失；
  - 状态三种：`reward_today` 时「今天第一次光顾有奖励」；好感度和礼物开着、今天已经玩完过「今天的奖励领过了」；好感度和礼物关着「调一杯给来店的她」。
- **子页**：`/play/bar` 加进玩法子页，读到关着时用 Next 的 not-found。酒吧的代码和字体只在这一页加载。
- **盖住外壳**：
  - 酒吧在导航外壳里，所以通话不挂断（ADR-0018）。画面盖住导航栏和 dock；正在通话时通话条照旧横在最上面，酒吧占下面那一块。
  - 点通话条展开的通话层盖在酒吧上面，收起回到酒吧；挂断后通话条消失，画面重新算缩放。
  - 怎么盖由实现定：固定定位的一层，或者外壳在这一页不画导航栏和 dock。`lib/navShell` 里外壳的规则要跟着对上。
  - 这一层不滚动，`touch-action: none`。
- **`lib/barScreen`**：
  - 给视口尺寸、安全区、通话条高度和指针类型，返回倍数和画面的位置。电脑（`pointer: fine`）取放得下的最大整数倍，放不下 1 倍时退成小数；手机（`pointer: coarse`）取放得下的最大小数倍，`image-rendering: pixelated`。
  - 给浏览器能力，返回有没有「全屏」按钮：Screen Orientation 的 `lock` 能用时才有。
- **竖屏提醒**：`(orientation: portrait) and (pointer: coarse)` 时整层盖「请横过来」，下面的画面不卸下，横过来接着玩。安卓多一个「全屏横过来」：先进全屏，再锁成横屏。iPhone 没有这个按钮。
- **像素字**：画面里所有字都先画在逻辑像素大小的 canvas 上，二值化去掉抗锯齿，再跟画面一起放大。用「缝合像素」12px，按 2 倍画；英文标签、短名用等宽。后面每张票的字都走它。
- **画框**：逻辑画面 640×360，分五层（吧台背景、客人立绘、配方书、外框、按钮和文字）。这一张画吧台背景、外框和最上面那层，各区坐标照原型和调研笔记。
- **电视**：点一下换台，共 10 个台（第 10 台关机）；换台时左上角亮一下绿字「ChN」。台号只在这一次营业里记着。
- **侧边菜单**：下排「离开」放在原版「退出」的位置，没有悬停效果。「离开」和浏览器返回都回玩法页。上排的备忘是票 06 的，下排「点唱机」那一格是票 11 的，这一张先空着。

见规格「入口、路由和外壳」「画框和缩放」「像素字」「侧边菜单、备忘、电视、鼠标」。

**Blocked by:** 01（素材和字体）

**Status:** done

- [x] `lib/playCards`（vitest）：「VA-283」卡只在开着时显示，排在最后，没有点，三种状态各自的写法。
- [x] `lib/barScreen`（vitest）：电脑整数倍、放不下 1 倍退小数、手机小数倍、扣掉安全区和通话条；有没有「全屏」按钮。
- [x] 只在这次起的后端上设 `EIDOLON_BAR=0`：玩法页没有卡，`/play/bar` 是 not-found。
- [x] Playwright（本地构建版）：1280×720 和 1920×1080 是整数倍、像素清楚；手机横屏（如 844×390）按小数倍铺满；手机竖屏只看到提醒；通话中进酒吧，通话条还在，展开、收起、挂断都对；电视换台；「离开」和浏览器返回都回玩法页。截图给用户看。
- [x] 前端 typecheck、vitest 通过。
- [x] 收尾：Comments 写下画面怎么分层、像素字怎么用、坐标从哪里抄，给票 06–12。

### 实现说明（票 05）

- **对一遍**：main 上玩法子页都走 `play/[subpage]` 一个路由（静态参数、`SUBPAGES` 表），关着的子页用 `closedPlayRedirect` 跳回玩法页；通话条画在 `NavShell` 内容区的顶上，展开的通话层盖内容区（电脑上 `absolute`、手机上 `fixed`）。据此改了规格两处：怎么盖住外壳（见下）、「全屏」按钮还要粗指针和能进全屏。
- **玩法卡**：`lib/playRoute` 的 `PLAY_SUBPAGES` 加 `bar`；`lib/playCards` 的 `PlayContext` 加 `bar: { rewardToday } | null`（关着、没读到、读不到都是 null，不出卡）。状态：`rewardToday` → 「今天第一次光顾有奖励」；礼物状态还没读到时空着；好感度和礼物开着 →「今天的奖励领过了」，关着 →「调一杯给来店的她」。卡片图标 `BarCardIcon`（lucide Martini）。
- **`lib/api`**：`Drink`、`DrinkFlavor`、`DrinkKind`、`BarState` 和 `getBar()`。饮品的 `page` 可以是 null（目录里没有配方卡的）。读取的 hook 是 `components/play/useBar`（玩法页和酒吧共用，`{ bar, failed }`）。
- **路由**：`/play/bar` 单独一个静态路由 `src/app/(app)/(nav)/play/bar/page.tsx`，引入同目录的 `bar.css`（`@font-face` 缝合像素、`.bar-layer`、`.bar-stage`、`.bar-hit`、吊扇转、竖屏提醒的媒体查询）；`[subpage]` 的静态参数和 `SUBPAGES` 表里排掉 `bar`（类型 `SharedSubpage`）。读到关着时在客户端组件里调 `notFound()`，构建版上是 Next 的 404 页。
- **盖住外壳**：`lib/navShell` 加 `showsNav(href)`，`/play/bar` 上为 false，`NavShell` 不画导航栏和 dock；酒吧那一层 `absolute inset-0` 铺满内容区（就是通话条下面那一块）。展开的通话层是内容区里排在后面的兄弟节点，自然盖在酒吧上面；收起、挂断时那一块大小变了，`ResizeObserver` 重新算缩放。
- **`lib/barScreen`**：`barScreen({ width, height, insets, callBar, pointer })` 返回 `{ scale, left, top }`，位置从通话条下面那一块的左上角算；`hasFullscreenButton({ canLockOrientation, canFullscreen, pointer })`。组件里视口宽用那一层的宽，高用「那一层的顶（=通话条高）+ 那一层的高」，安全区用一个 `padding: env(safe-area-inset-*)` 的探针元素读（应用没开 `viewport-fit=cover`，现在都是 0）。

**给票 06–12：画面怎么分层、像素字怎么用、坐标从哪里抄**

- **分层**：`components/play/bar/BarScreen` 的 `<BarScreen room guest book portrait>{children}</BarScreen>`。画面是一块 640×360 的 div，`transform: scale(s)`，里面的东西都按逻辑像素 `position: absolute` 摆；从下往上是 `room`（`BarRoom`：吧台背景、电视、吊扇）、`guest`（票 06 的立绘）、`book`（票 09 的配方书）、外框 `frame.png`、`children`（按钮和字）。`portrait` 是竖屏提醒，盖在整层上面。`useBarScale()` 拿当前倍数（立绘的像素比压到 1/倍数用）。
- **点击**：`.bar-stage` 里的 `img`、`canvas` 都 `pointer-events: none`（外框整张盖在上面，点电视要穿过它）。能点的地方用 `HitArea`（透明按钮、带读屏名字、没有悬停效果）或自己的 `button.bar-hit`。
- **图**：`Sprite`（`name` 是 `/bar/img/<name>.png`，给 `x y width height`），`barImage(name)` 拿地址。
- **像素字**：`PixelText`（`x y runs color lineHeight width align mono label`）。`runs` 是字符串或 `{ text, color }[]`，`
` 换行；`y` 是行顶，字在 `lineHeight`（默认 16）里竖着居中，所以照原型 `Txt` 的 `y` 原样抄就对得上（原型 13px 的字最后也是落在 y+2）。`mono` 每字定宽（窄 6、宽 12），给英文标签、短名用。折行它不管，交给 `lib/barText`（票 06）分好行再一行行（或用 `
`）给它。`label=""` 是不给读屏读（旁边有 `HitArea` 读的时候）。颜色在 `components/play/bar/ink.ts` 的 `BAR_INK`。
- **坐标**：照原型 `prototype/bar` 1c8a26d9 的 `frontend/src/components/play/bar-prototype/VariantA.tsx` 和 `pieces.tsx`（`git show 1c8a26d9:<路径>`），那里的数字就是原版 640×360 的逻辑像素；出处是调研笔记（`research/bar-screen` 分支）第 1、2 节。图的名字和尺寸见票 01 的表。
- **侧边菜单**：`SideMenu` 现在只画「离开」(543,312) 72×20；上排的备忘（票 06）和下排「点唱机」(445,312)（票 11）照原型 `VariantA.tsx` 的 `SideMenu` 加进它里面。
- **全屏**：`PortraitGuard.tsx` 导出 `useFullscreenButton()`、`goFullscreenLandscape()`，店门口的「全屏」按钮（票 06）用它们。

**判断**

- 「离开」用 `router.push("/play")`，和别的子页页首的返回键一样；从卡进来的，浏览器返回也回玩法页。代价是在玩法页再按返回会回到酒吧（审查提过，没改）。
- 读 `GET /api/bar` 失败时照样画画面（「离开」能用），不当作关着；进门出错由票 06、10 处理。
- 进来时电视的台号也亮一下（照原型），台号从开着的九个台里随便挑一个。
- 竖屏提醒的字按固定 3 倍画，不跟画面的倍数走（竖着时画面很小）。

**审查后（固定点 4c902e7f）**：读 `/api/bar` 抽成 `useBar`；电视改用 `HitArea`；指针判断只在 `primaryPointer` 一处；底色只在 `BAR_INK.ground`；类型 `BarScreen` 改叫 `BarPlacement`；测试去掉不分支的参数行；规格补了实际做法。判断题、没改的：酒吧用自己的 hex 颜色（`BAR_INK`、inline style），`frontend/AGENTS.md` 的颜色规则只给应用、`DESIGN.md` 现在只写了落地页另立视觉世界，酒吧的例外在规格里，`DESIGN.md` 的「酒吧」一节是票 13 的事（已交接）；`BarScreen` 的 `guest`、`book` 插槽和 `useBarScale` 这张票没用到，留给票 06、09。
