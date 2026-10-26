# 08: 调酒台和上酒

**What to build:** 点单以后调酒台打开，照原版拖材料、加冰、陈化、摇、上酒；上酒交给服务器判，她接着反应、点下一单，一直走到告别。配方书是票 09，结束卡是票 10。

- **`lib/barMixer`**：
  - 状态：五种材料各几份、冰、陈化、摇的阶段（没摇、慢摇、快摇、停了）、停下时的结果（一款饮品加是不是大杯，或者调坏了）、拖进来的瓶装。
  - 动作：加一份（总共 20 份为止）、减一份、开关冰、开关陈化、开始摇、停（不到 5 秒 mix，满 5 秒 blend）、重来、拖进瓶装（只在摇酒器空着时，之后材料变灰）、上酒（停了而且没调坏才行）。
  - 匹配照「光顾」规格的规则，数据用 `GET /api/bar` 的目录：份数（可选的 Karmotrine 不比）、冰、陈化、调法完全一致；大杯是份数全部翻倍；本身就大的没有翻倍版；都对不上是调坏的。前端算的只用来显示，判定以服务器为准。
  - 上酒的正文照规格：`method` 是 `mix`、`blend` 或 `bottle`。份数槽停下后写短名，调坏的写乱码（原型的写法）。
- **调酒台的画面**照原型和调研笔记：
  - 材料瓶拖进摇酒器，每拖一次 +1 份、放一圈光；点一下不加。
  - 份数格加了的亮、没加的 30% 透明，11–20 份叠一条。冰、陈化是开关。
  - 「调制」开始摇，满 5 秒转快摇；「停止」停下。
  - 调坏了出故障瓶、飘「失败」、显示 `mix_no`；「上酒」变灰，按了只响一声。「重来」次数不限。
  - 4 款瓶装放在台上。
  - 按钮大小照原版，手机上不另外放大。一单只点一杯，没有原版的栏位 1/2。
- **拖和键盘**：
  - 用 pointer 事件，鼠标和手指一样，拖到摇酒器上松手才加。
  - 键盘：Q W E R T 加五种材料，按住 Shift 减；A 冰，S 陈化；空格依次是调制、停止、上酒。
  - 通话层展开（页面 inert）时快捷键不响应。
- **上酒**：
  - 调 `POST /api/bar/visits/{visit_id}/serves`。422（`broken_drink`）照服务器的显示故障瓶，别的什么都不发生；410（`visit_gone`）回店门口，写「这次光顾已经结束了」；409 忽略（双击）。
  - 上酒后调酒台收起，「请慢用」和她的反应照 `lib/barVisit` 往下打；下一单的点单句打完再打开。
- **音效**照调研笔记的表（`addingredient`、`iceadd`、`ageadd`、`mixdone`、`glassserve`、`buttonclick`……），走票 07 的口子。
- **鼠标**：电脑上用原版的手套，平时、按下、停在材料上张开、拖动时握拳、停在文本框上是会动的 NEXT 气泡；按缩放取 1/2/3 倍的图。手机上没有。

见规格「调酒台」「接光顾的接口」里上酒那一条，以及「侧边菜单、备忘、电视、鼠标」里鼠标那一条。

**Blocked by:** 07（音效的口子；店门口、说话和调酒状态在 06）

**Status:** ready-for-agent

- [ ] `lib/barMixer`（vitest）：加到 20 份为止、减到 0 为止；冰、陈化开关；摇不到 5 秒 mix、满 5 秒 blend；每款匹配到自己；每款的大杯；本身大的没有翻倍版；可选 Karmotrine 加 0 份和加几份；差一样就调坏；Flaming Moai 的配方调坏；瓶装只能拖进空的摇酒器、之后不能加材料；调坏了不能上；上酒的正文；份数槽写什么。
- [ ] `lib/barVisit` 补上上酒（vitest）：422 显示故障瓶、410 回店门口、409 不变。
- [ ] Playwright（拦下的 SSE，两杯的光顾）：鼠标拖、触屏拖（`hasTouch` 的上下文）、点一下不加、键盘调；mix 和 blend；调坏的上不了；瓶装；上酒的请求体对；422 和 410。截图给用户看。
- [ ] 接真后端和本机的对话模型，一杯杯上到告别。
- [ ] 前端 typecheck、vitest 通过。
- [ ] 收尾：Comments 写下 `lib/barMixer` 的匹配怎么调用，给票 12（教程用它判两杯）。

## Comments

### 票 08 交接

- 来自票 01：提取目录里没有 Frothy Water 的成品图（饮品图 24 张里是 Flaming Moai，没有它），原型的 `drink_fwater` 是坏图。调好 Frothy Water 时画哪张，这张票定（比如借 `drink_beer`），定了写进规格。

### 票 06 交接

`lib/barVisit` 的形状（`BarVisitState`）：

- `stage`：`door` | `entering`（`POST /api/bar/visits` 在路上）| `visit`；`notice`：店门口写的话；`visit`：`{ id, characterId }`。
- `shown`：文本框上那一页 `{ line, page, isLast, typing: { startedAt, finished } }`；`queue`：还没上框的页（`LinePage[]`，一句话分好页以后一页一项）；`isAwaitingLine`：玩家已经点过最后一页，下一句一来马上打。
- `isOrderTyped`、`isWaiting`：点单句（最后一页）打完了、`waiting` 到了；两样都有时 `openCounter` 把 `isMixing` 设成 true、`pendingMemo` 挪进 `memo`，两个标记清掉。
- `mood`：她最近一句的情绪。

动作（`BarVisitAction`）：`enter`、`refused { notice }`、`line { line, pages, now }`（组件用 `paginate` 分好页）、`event { event }`（其余事件；`retrying`、`failed`、`done` 现在原样返回）、`tap { now }`、`tick { now }`（组件在一页打完的时刻发）、`left`。派生：`shownText`、`isSpeaking`、`isArrowShown`。组件这边是 `components/play/bar/useBarVisit.ts`：调用的 `AbortController` 在 `call`、光顾 id 在 `visitId`；`enter` 的 `catch` 里光顾已经开始（`visitId` 有值）的错误现在直接忽略。

- 上酒后要接「请慢用」和她的反应：上酒时 `isMixing` 清掉，同时把 `isAwaitingLine` 设成 true（调酒时箭头不显示，玩家没理由去点），这样「请慢用」一到就顶掉点单句开始打。下一单的点单句照现在的规则打完再开。
- `memo` 一直留着，下一单的 `memo` 事件来了 `openCounter` 才换。
