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

**Status:** ready-for-agent

- [ ] `lib/barVisit`（vitest）：`done` 后打完最后一句才出结束卡，结束卡三种写法；`retrying` 清掉这次调用的句子；`failed` 和「再试一次」（「请慢用」留着、409 忽略、410 回店门口）；兜底告别照常结束。
- [ ] Playwright（拦下的 SSE）：两杯的光顾走到三种结束卡；「再营业」直接进门、音乐不断（拦下的音频没有重新请求第 1 首）；得了抽奖后导航「玩法」亮点；出错和「再试一次」；重试清句子；SSE 中途断掉回店门口；410 回店门口。截图给用户看。
- [ ] 前端 typecheck、vitest 通过。

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
