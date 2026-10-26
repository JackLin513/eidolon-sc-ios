# 06: 进门和她说话

**What to build:** 光顾的第一条通路：店门口点一下进门，她剪影淡入，和制作人一句句说话；点单以后侧边菜单出现点单备忘，进入调酒状态。调酒台是票 08，声音是票 07，结束卡和出错是票 10。这一张走到点单为止，能对着真后端走。

- **先对一遍** `Stand` 的 props（现在 `entrance` 只有 `rise`、`fade`），以及通话层的衣装和情绪映射，对不上就改规格。
- **店门口**：
  - 原版三帧霓虹，招牌写 VA-283。这一张里进 `/play/bar` 直接到店门口，选曲界面是票 11。
  - 点一下进门：调 `POST /api/bar/visits`，`own_keys` 照文字回合从本机取，照 `lib/api` 带上 `x-timezone`。
  - 429 时店门口写「这一小时的光顾次数用完了，HH:mm 以后再来」，不进门；`retry_at` 为 null 时照文字回合那时的写法。409 回玩法页。其他错误写一句短的出错提示，可以再点。
  - 安卓的店门口也有「全屏」按钮（`lib/barScreen` 说有才有）。
- **`lib/barVisit`**：把 SSE 事件和玩家的动作归约成画面状态。纯函数，组件只管画和计时。这一张做 `visit`、`line`、`memo`、`waiting` 和「点一下」：
  - 句子按到达顺序排队；打完一页、玩家点了才翻下一页；
  - 队列空了而这次调用还没完时，文本框等着；
  - 点单句（`order: true`）打完、而且 `waiting` 也到了，才显示备忘、进入调酒状态。
- **`lib/barText`**：
  - 文本框 412×65，13px，行距 16，最多 4 行。她一句是日语一行、中文一行起（各自折行），制作人一句中文；一页放不下就分页。
  - 名字接冒号，在同一行开头；她的名字用她的官方色，制作人的名字用原型的「我」色。
  - 每秒 30 字；点一下先打完整句，再点翻页；打完右下角 `arrow_text_2` 上下跳。
- **立绘**：
  - 复用通话层的 `Stand` 和情绪映射，衣装用她的选中衣装（`outfitsToTry`）。
  - 像素比压到 1/缩放，再 `pixelated`；裁在客人窗里到腰，单人位 x=185。
  - 进门先是剪影，再分两段淡入成彩色。她的句子在打字时 `speaking`。
  - 加载不到时客人窗里只剩吧台背景，照常走。
- **备忘**：侧边菜单上排写点单备忘（`memo` 的 `text`），一直看得到。
- **离开**：有进行中的光顾时调 `DELETE /api/bar/visits/{visit_id}`。刷新、关页面这次光顾就没了，下次从店门口开始。
- 界面上哪里都不显示她的口味、醉意和档位。
- **验收用的工具**：`docs/agents/local-acceptance.md` 补一节「酒吧」：怎么拦下 `/api/bar/visits*` 换成固定的 SSE 事件（分段推、挂着不回），怎么只在这次起的后端上关掉酒吧。后面每张票照它验。

见规格「一次营业的流程」「接光顾的接口」「文本框和打字」「立绘」。

**Blocked by:** 05（画框、缩放和像素字）

**Status:** done

- [x] `lib/barVisit`（vitest）：每种事件的归约；排队、翻页、队列空了等着；点单句打完且 `waiting` 到了才进调酒、出备忘，两样先后反过来也一样；429 写时刻，含 `retry_at` 为 null。
- [x] `lib/barText`（vitest）：分页（她两行起、制作人一行、超过 4 行分页、折行）；打到第几个字（每秒 30 字、点一下打完整句）。
- [x] Playwright（拦下的 SSE）：台词按节奏打出，点一下打完，再点翻页；台词迟到时文本框等着；点单后出现备忘；429 时的店门口；409 回玩法页；离开时发了 DELETE。截图给用户看。
- [x] 接真后端和本机 `.env` 的对话模型走一次：进门、她说话、点单出备忘，立绘按情绪换动作。
- [x] 前端 typecheck、vitest 通过。
- [x] 收尾：`local-acceptance.md` 那一节写好；Comments 写下 `lib/barVisit` 的状态形状和动作，给票 08、10、12。

## Comments

### 票 06 交接

- 来自票 05：画面怎么分层、像素字、坐标出处、`HitArea`、`useBarScale`、`useFullscreenButton` 见票 05 的「给票 06–12」。立绘放进 `BarScreen` 的 `guest` 插槽；它在 `transform: scale(s)` 的画面里，布局尺寸是逻辑像素，所以 Spine 画布的像素比照原型压到 `1/useBarScale()` 就是逻辑像素大小，再被 transform 按最近邻放大（`.bar-stage canvas` 已经 `pixelated`）。
- `BarSubpage` 现在读 `useBar()`，读不到（`failed`）时 `bar` 是 null 照样画画面；进门要用目录时记得处理这种情况。侧边菜单上排的备忘加进 `BarScreen.tsx` 的 `SideMenu`。

### 实现说明（票 06）

- **对一遍**：`Stand` 的 `entrance` 加了 `none`（一到就整个出现，不带自己的 0.3 秒淡入），进门的剪影和两段淡入由外面一层做（`bar.css` 的 `.bar-guest-in`：`filter: brightness` 0→1 就是彩色层叠在黑剪影上，`steps(4)` 每次加 1/4，各 0.5 秒），立绘到了才开始。立绘在 `transform: scale` 的画面里，布局尺寸就是逻辑像素，所以 `maxPixelRatio` 给 1，不是 1/缩放（规格「立绘」已改）。情绪直接用每句的 `emotion` 交给 `Stand`（它里面按 `lib/standAnimations` 换动作）；衣装用 `useStandOutfits(character).toTry`。
- **`lib/barText`**：`paginate(line, { names, measure })` → `TextPage[]`（`rows: { name, text, subtitle }[]`，最多 4 行；她日语一行起、中文字幕一行起，各自折行；名字接冒号只在一句的第一行）；`wrapText(text, width, measure, indent)`（英文单词不断开、句末标点挂行尾，备忘也用它）；打字 `typedChars`、`typedOutAt`、`isTypedOut`（`Typing = { startedAt, finished }`，每秒 `CHARS_PER_SECOND` 30 字），`shownRows(page, typed)`（字幕跟日语同比例出，照原型）。
- **`lib/barVisit`**：见下面给票 08、10、12 的状态形状。店门口的提示 `doorNotice(ApiError | null)`：429 写「这一小时的光顾次数用完了，HH:mm 以后再来」（不在今天时带「M月D日」，同文字回合），`retry_at` 为 null 用服务器的话，其余「没能进门，再点一下试试」。
- **`lib/api`**：读 SSE 的循环抽成 `serverSentEvents<T>`（`sendTurn` 也用它）；`enterBar(userId, signal)`（带 `turnOwnKeys`，`api()` 带 `x-timezone`）、`leaveBarVisit(visitId, { keepalive })`。
- **组件**：`useBarVisit({ userId, characters })`（reducer、打字计时、接口；角色没读到时点门不进）、`BarDoor`（三帧霓虹、招牌、提示、安卓「全屏」；等接口时提示收起）、`BarTextBox`（(17,276) 412×65，字从 (23,279) 起，`arrow_0..3` 每 111ms 一帧）、`BarGuest`（客人窗 (19,27) 410×241，立绘 x=45 宽 280，中线 185）、`SideMenu` 上排的备忘（(445,279) 宽 172，前面灰字「点单」，最多两行、截成「…」，读屏读全文）。`PixelText` 导出 `loadPixelFont`、`measurePixelText`（一个字一个字量，和画法一致）；进门前先等字体载入再量。
- **离开**：「离开」、换页（卸载）时关掉这次调用、`DELETE`；关页面、刷新时 `pagehide` 发 keepalive 的 `DELETE`。
- **验收**：本地构建版 + Playwright，拦下的 SSE 过了台词节奏、点一下打完、翻页、迟到等着、点单出备忘、429（含 null）、其他错误、409 回玩法页、离开发 DELETE；截图在 `.scratch/_accept/`（不提交）。接真后端和本机 `.env` 的对话模型走了一次：樹里进门说了五句、点了 Suplex，备忘「她要 Suplex。」出来，立绘换了动作；再进就是真的 429「这一小时的光顾次数用完了，00:03 以后再来」。`local-acceptance.md` 补了「酒吧」一节。

**判断**

- 情绪没照通话层「calm 的句子不改情绪」：酒吧每句都由模型标了情绪，calm 就是 calm。
- 「进门」不是单独一步：`visit` 到了就进店，台词来了就打，不等剪影淡完（立绘可能加载慢、也可能加载不到）。
- 翻过最后一页、下一句还没到时，文本框留着上一页（不清空），箭头收起；下一句一到马上打。
- 光顾中途调用断了（网络、流提前结束）现在什么都不做，是票 10 的事。

**审查后（固定点 de624f47）**：`Stand` 加 `entrance="none"` 免得两层淡入叠在一起；她的名字每句来时按 `character_id` 现找，hook 直接接 `characters`（不再绕回调）；备忘截到两行；429 跨天带日期；等接口时店门口提示收起；箭头的条件挪进 `lib/barVisit` 的 `isArrowShown`；`doorNotice` 直接接 `ApiError | null`；打字的计时用 `CHARS_PER_SECOND`；reducer 里的辅助函数改名（`showNext`、`afterTyping`、`openCounter`、`onEvent`）。没改的：上面两条判断；`TextLine` 和 `VisitLine` 两个类型分开（`barText` 不该知道情绪和点单）；两份测试里「点一下打完」各测各的一层，没合。
