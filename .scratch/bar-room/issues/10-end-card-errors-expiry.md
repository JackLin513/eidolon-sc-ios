# 10: 结束卡、出错和作废

**What to build:** 一次光顾怎么结束：她告别后看到得到了什么，可以「再营业」或「离开」；模型出错时能「再试一次」；这次光顾没了时回到店门口。

- **结束卡**：
  - `done` 以后，打完最后一句才出。
  - 当天第一次写「抽奖 +1」「♥ 好感度上升」：`rewarded.draws` 为 1 才写抽奖，`affinity_up` 才写好感度。`rewarded` 为 null 或者两样都没有时，只写「她走了」。
  - 按钮「再营业」和「离开」。再营业直接进门迎下一位，不回店门口，音乐不停。
  - 得了抽奖时照「到账」的做法，让导航「玩法」上的点亮起来。
- **`retrying`**：清掉这次调用推来的句子，没打完的和已经打过的都清，从这次调用开始前的那一页接着。
- **`failed`**：
  - 文本框写事件里的 `message`，加「再试一次」。
  - 点了调 `POST …/retry`：先清掉出错这次调用推来的句子。上酒时「请慢用」那一句不在里面，留着；重推的从这次调用的第一句起。
  - `retry` 回 409（`not_failed`）忽略，回 410 就回店门口。
  - 告别写完却没能记下时也推 `failed`，这时光顾已经结束，再试一次得 410。
  - 告别那次两次都失败时，服务器推写死的兜底句（这次已经推过句子的话，先推 `retrying`），照常 `done`。
- **这次光顾没了**：任何请求得 410（另一个标签页开了新的、太久没动、后端重启）时回到店门口，写「这次光顾已经结束了」。网络断了、重连不回来时同样回店门口。

见规格「一次营业的流程」的结束卡一条，以及「接光顾的接口」里出错那几句。

**Blocked by:** 08（上酒才走得到告别）

**Status:** done

- [x] `lib/barVisit`（vitest）：`done` 后打完最后一句才出结束卡，结束卡三种写法；`retrying` 清掉这次调用的句子；`failed` 和「再试一次」（「请慢用」留着、409 忽略、410 回店门口）；兜底告别照常结束。
- [x] Playwright（拦下的 SSE）：两杯的光顾走到三种结束卡；「再营业」直接进门、音乐不断（拦下的音频没有重新请求第 1 首）；得了抽奖后导航「玩法」亮点；出错和「再试一次」；重试清句子；SSE 中途断掉回店门口；410 回店门口。截图给用户看。
- [x] 前端 typecheck、vitest 通过。

## Comments

### 票 06 交接

`lib/barVisit` 的形状（`BarVisitState`）：

- `stage`：`door` | `entering`（`POST /api/bar/visits` 在路上）| `visit`；`notice`：店门口写的话；`visit`：`{ id, characterId }`。
- `shown`：文本框上那一页 `{ line, page, isLast, typing: { startedAt, finished } }`；`queue`：还没上框的页（`LinePage[]`，一句话分好页以后一页一项）；`isAwaitingLine`：玩家已经点过最后一页，下一句一来马上打。
- `isOrderTyped`、`isWaiting`：点单句（最后一页）打完了、`waiting` 到了；两样都有时 `openCounter` 把 `isMixing` 设成 true、`pendingMemo` 挪进 `memo`，两个标记清掉。
- `mood`：她最近一句的情绪。

动作（`BarVisitAction`）：`enter`、`refused { notice }`、`line { line, pages, now }`（组件用 `paginate` 分好页）、`event { event }`（其余事件；`retrying`、`failed`、`done` 现在原样返回）、`tap { now }`、`tick { now }`（组件在一页打完的时刻发）、`left`。派生：`shownText`、`isSpeaking`、`isArrowShown`。组件这边是 `components/play/bar/useBarVisit.ts`：调用的 `AbortController` 在 `call`、光顾 id 在 `visitId`；`enter` 的 `catch` 里光顾已经开始（`visitId` 有值）的错误现在直接忽略。

- `retrying` 要「从这次调用开始前的那一页接着」、`failed` 后重试要「先清掉出错这次调用推来的句子」：`LinePage` 现在不知道自己是哪次调用推来的，得加一个调用的标记（比如每次 `enter`、`serves`、`retry` 开头记一个调用序号，`line` 动作带上），再按它从 `queue` 和 `shown` 里清。
- 光顾中途调用断了（`for await` 抛错、流提前结束）回店门口写一句，在 `useBarVisit` 的 `enter` 的 `catch` 里那个「票 10」注释处接。

### 票 08 交接

- 上酒在 `useBarVisit.serve`：服务器收下以后（`served`）事件流断了现在直接忽略（`catch` 里 `isTaken` 就 return），归票 10 的「网络断了回店门口」。
- 上酒得 410 已经回店门口、写「这次光顾已经结束了」（`copy.bar.visitGone`，`serveRefused`）；票 10 做其余请求的 410 时可以共用这句。

### 实现说明（票 10）

- **`lib/barVisit`**：
  - 每页带上推它的调用（`LinePage.call`），状态里 `call` 是正在写的那次。`served` 后下一句是「请慢用」（`isEnjoyNext`），它记在上一次调用名下、之后 `call` 才加一，所以清句子时留着。翻页离开上一次调用的页时记下它和当时的情绪（`resume`），清掉这次调用的句子时框回到它（打完、箭头不出、下一句一来马上打），情绪也回去；进门那次没有前一页，框空、情绪回 `calm`。
  - `retrying` 和服务器接下 retry（`retried`）都走这个清法。
  - `failed` 记 `failure`，文本框改写出错的话；这时点文本框没用、不开口、没箭头。新动作 `retry`（请求在路上，按钮收起）、`retried`、`retryRefused { status }`（410 回店门口，别的照旧）、`gone`（回店门口写「这次光顾已经结束了」）。
  - `done` 记 `done.rewarded`；派生 `endCard(state)`：`done` 到了、队列空了、最后一页点过（`isAwaitingLine`）或者框上没有页时，给 `{ draws, affinityUp }`。新动作 `again`：结束卡出着时进 `stage: "next"`（店里等下一位，不画店门口），`visit`、`refused` 照进门那样接。
- **`useBarVisit`**：进门和再营业共用 `startVisit`（先关掉还开着的上一次调用）；再营业只响门声、不调 `sound.start()`，曲目接着放。`follow` 没等到 `waiting`、`failed`、`done` 就完了算断了，抛错；光顾已经开始后断了（进门、上酒收下后、retry 接下后）都 `gone`。各个 catch 只处理还是当前那次的调用（`call.current === controller`）。`done` 时清掉 `visitId`（离开不再 DELETE），`rewarded.draws` 大于 0 时调 `onDraws`。新增 `retry`、`again`。
- **`api.ts`**：`retryBarVisit(visitId, signal)`。
- **组件**：`BarEndCard`（照原型 `EndPanel`，遮罩色 `BAR_INK.veil`）；`BarButton`（白框按钮，结束卡和「再试一次」共用）；`BarTextBox` 多一个 `failure`，出错的话按 `TEXT_WIDTH` 减按钮宽折行，右下角「再试一次」。`BarSubpage` 的 `onDraws` 重读 `/api/gifts` 交给外壳的 `giftsRead`，外壳在玩法页上不出点，离开玩法页就看得到。
- **几处判断**：
  - 结束卡在 `done` 到了、最后一页「点过」以后出（照原型的 `advance`），不是一打完就盖上去，留时间读告别。
  - 「她走了」写成她的简称加「走了」（照原型 `${HER.name}走了`），没读到她是谁时写「她走了」。
  - `retrying` 时也留着「请慢用」：后端把它作为 `first` 在两次尝试之前推一次，`Retrying` 后不再推。
  - `failed` 一来出错的话立刻顶掉文本框，这次调用排着的句子不再打（retry 接下时一起清掉）。
  - retry 没有回答（网络错误，还没有响应）时留在出错框、按钮回来可以再点，不回店门口：服务器那边光顾还停在出错，再点能接上。只有调用中途断了才回店门口。
- **验收**：本地构建版、Playwright 拦下事件流，18 项都过：两杯的光顾，第二杯 `retrying` 清掉她的反应、框回到「请慢用」；`done` 前没有结束卡；结束卡三种写法（抽奖 +1 和 ♥ 好感度上升、只有好感度、「真乃走了」）；得了抽奖后重读一次 `/api/gifts`，离开到对话页导航「玩法」有点；「再营业」不回店门口、又 POST 一次 `/api/bar/visits`、音乐没有重新请求；出错写 `message` 和「再试一次」，retry 409 照旧，200 时 POST `…/v3/retry`、清掉出错那次的句子、重推的从第一句起，410 回店门口；事件流中途断了回店门口。
- **审查后没改的**（判断题）：`serve` 和 `retry` 的「POST、收下、跟着读、按状态拒」结构一样，可以抽一个共用的；`again`、`retry`、`serve` 里手抄 `latest.current` 防双击，是票 08 的写法；`onDraws` 和外壳的 `checkRewards` 是同一件事，外壳没有对外给它；她的名字（`short_name ?? name`）在 `BarSubpage` 和 `useBarVisit` 各取一次。
