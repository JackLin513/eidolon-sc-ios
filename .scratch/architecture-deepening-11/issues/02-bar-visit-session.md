# 02: 光顾的会话搬出 React

**What to build:** 光顾时和服务器打交道的部分照旧这样走：

- 进门；进门被拒时，店门口说明原因；酒吧关着就回玩法页。
- 上酒被收下时响上酒的声音，然后接着显示她的台词；上不了的酒只响「不行」。
- 上了坏掉的酒（422），显示坏了，可以重调。
- 光顾没了（410），回到店门口，之后离开时不再发「离开这次光顾」。
- 出错以后「再试一次」。
- 中途调用断了，回到店门口并给出提示。
- 当天第一次玩完得了抽奖时，礼物那边马上刷新。
- 结束卡上点「再营业」，下一位直接进门；上一位那次调用晚到的错误不起作用。
- 离开、换页、关页面时关掉这次调用，离开这次光顾。

这些现在都写在一个 React hook 里：它在 reducer 之外另存了一份状态，「服务器收下了没有」有三种判断办法，而且没有测试。

这张票做三件事：

- 把这部分收进一个不依赖 React 的 `BarVisitSession`，接口调用从外面传进来；
- 进门、上酒、再试一次这三个接口调用统一成一种形状；
- hook 只负责把会话接到画面上。

用户看到、听到的都不变。

背景和设计见 `../spec.md`。

**Blocked by:** 01

**Status:** done

## 已定的设计（2026-10-27 grilling，详见 spec）

- 进门、上酒、再试一次统一成同一种形状：先等服务器回应，拒了就抛错（带状态码），收下了就返回这次调用的事件流。「离开」不变。
- `BarVisitSession` 的写法照对话页的 LiveConversation：
  - 自己保存光顾的状态，经 `barVisit` 转移；
  - 对外给 subscribe 和 snapshot，快照只在有变化时才换成新对象；
  - hook 用 useSyncExternalStore 读。不再用 useReducer，也不再有手动同步的那份副本和那几个 ref。
- 建 `BarVisitSession` 时传进去：
  - 接口调用：进门、上酒、再试一次、离开；
  - 分页要用的：角色列表、量字（票 01 的共用分页小函数）；
  - 此刻的毫秒数；
  - 三个通知：酒吧关着、得了抽奖、要响的音效（上了酒 `glassserve`、上不了 `buttonnoclick`）。
- 它对外提供：进门、再营业、点文本框、调酒、上酒、再试一次、离开，以及关掉（页面走开时带 keepalive）。
- 下面这些全部在它里面处理：
  - 服务器那边有没有这次光顾、她是谁；
  - 新调用开始时中止上一次；
  - 迟到的错误不起作用，不是当前这次调用的就丢掉；
  - 收下了以后，事件流在 waiting、failed、done 之外结束，算中途断了，回店门口；
  - 409 时通知酒吧关着；
  - 410 和她告别以后，离开时不再发「离开这次光顾」；
  - 「再营业」时关掉上一位还开着的调用。
- 下面这些留在 hook 里：
  - 门声和 `sound.start()`（必须在点击里同步调用）；
  - 打字的计时；
  - pagehide 时带 keepalive 关掉，组件卸载时关掉；
  - 「酒吧关着」时的路由跳转；
  - 把通知接到声音和礼物那边。

## 验收

- [x] 三个接口调用统一成上面那种形状；除了会话以外没有别的调用方，用 grep 确认。
- [x] `BarVisitSession` 写好；光顾的 hook 里不再有 useReducer、手动同步的副本，以及 visitId、herId 这类 ref。
- [x] 新加 `BarVisitSession` 的测试，用假的接口调用（测试自己造的事件流，可以挂着不结束、可以中途断）在 node 环境里跑，看快照和通知。照 LiveConversation 测试的写法，要覆盖：
  - 进门一路走到点单、开台、上酒、告别、结束卡；
  - 中途断了回店门口；
  - 409 时通知酒吧关着；
  - 进门被拒（429，包括有 retry_at 和没有的）时店门口的提示；
  - 410 和她告别以后，离开不再发「离开这次光顾」；
  - 「再营业」时上一位晚到的错误不起作用；
  - 上酒被收下时通知上了酒；上不了时通知上不了，并且什么都不发；
  - 上酒被拒（422、410、409）；
  - 再试一次被收下、被拒；
  - 关掉时中止调用并离开。
- [x] 在本地构建版上用 Playwright 验收（`docs/agents/local-acceptance.md`「酒吧」一节，在页面里换掉 fetch，手里拿着事件流）：
  - 一次光顾走到结束卡，再点「再营业」；
  - 上酒被拒 422（摇酒器显示坏了）、410（回店门口，之后离开不发 DELETE）；
  - 出错后再试一次；
  - 中途断了；
  - 「再营业」时让上一位那次调用晚一点报错；
  - 进门被拒 429、409（回玩法页）。
- [x] 本机跑类型检查和受影响的测试，推分支，看 CI。

## Comments

### 票 01 交接

- 光顾的状态已经带 `scene`（lib/barScene），场景的查询都对 `state.scene` 调。`useBarVisit` 交出 `current: CurrentScene`（`components/play/bar/sceneOnScreen.ts`），画面那层只挑一次 `tutorial.current ?? visit.current`；会话的快照接过来时保持这个形状。
- `useBarVisit` 多了一个 ref `pagesFor`：进门时 `await loadSceneLayout()` 存下分页函数，`follow` 每句来时用它。搬进会话时，分页那一项（角色列表加量字）照规格从外面传进来，可以把它换掉。
- 画面那一层直接读光顾的 `state.isServing`（锁台）和 `state.failure`（出错时她不开口、不响打字音效）。code-review 建议这两样交给 hook 或会话的快照，瘦身时可以一起做。

### 实现说明（票 02）

- **`lib/api`**：`enterBar` 从边读边抛的生成器改成和 `serveBarDrink`、`retryBarVisit` 同一个形状：`Promise<AsyncGenerator<VisitEvent>>`，先等回应，拒了照 `json` 抛 `ApiError`。三个只在 `useBarVisit` 里接给会话。
- **`lib/barVisitSession`（新）**：`BarVisitSession`，照 LiveConversation 给 `subscribe`、`snapshot`，快照就是 `BarVisitState`（`barVisit` 没变时不换对象，也不通知）。端口 `BarVisitPorts`：`enter`、`serve`、`retry`、`leave`（签名和 `lib/api` 的一样，hook 直接传进去）、`layOut`（交出分页函数，进门时等一次、之后留着；hook 传票 01 的 `loadSceneLayout`）、`characters`、`now`、`onClosed`、`onDraws`、`onSound`（`glassserve`、`buttonnoclick`）。方法：`enter(userId)`、`again(userId)`、`tap`、`mix`、`serve`、`retry`、`leave`、`close({ keepalive })`；`tap` 到 `leave` 是绑好的箭头属性，hook 原样交给画面。三种调用都走私有的 `runCall`：先关掉上一次，等回应，拒了按状态码交回（410 时清掉光顾），收下了跟着事件流，每个事件来时都核对还是不是当前这次调用。
- **`useBarVisit`**：用 `useState` 建一次会话，`useSyncExternalStore` 读。只剩门声和 `sound.start()`（点击里同步调用）、角色没读到时不进门、打字计时、pagehide 和卸载时关掉，以及通知的接法（409 时 `router.push`、`onDraws`、音效）。返回的形状没变，`BarSubpage` 只把 `onRetry`、`onAgain` 改成直接传函数。
- **测试**：`barVisitSession.test.ts` 共 20 条，用手里攥着的假事件流（可以挂着、可以中途断）在 node 里跑。
- **Playwright 验收**：在本地构建版上换掉 fetch，下面这些都照旧：
  - 光顾走到结束卡，礼物那边刷新，「再营业」，离开发 DELETE；
  - 422 摇酒器显示乱码，调酒台开着；
  - 410 回店门口，离开不发 DELETE；
  - 出错以后再试一次；
  - 中途断了；
  - 「再营业」以后上一位那次调用晚到的错误不起作用；
  - 429 两种提示；
  - 409 回玩法页。
- **行为上唯一的出入**：进门以后，服务器已经收下、但事件流在 `visit` 之前就断了，店门口原来写「没能进门，再点一下试试」，现在写「这次光顾已经结束了」。规格定的是「收下了」只有一种判断法，这是它带来的结果；这种情况本来就很少见。
- **审查后没改的（判断题）**：
  - 会话的 429 两条测试，和 `barVisit.test` 里「店门口的提示」走的是同一条分支，但票的验收点名要这两条，所以留着。
  - 门的守卫在 hook 和会话里各判一次：hook 要先判，才知道这一下点击该不该响门声。
  - hook 里还有一个 `latestProps` ref，用来同步最新的 props（角色列表、声音、`onDraws`、router），好让只建一次的会话拿到它们。它不是状态的副本。
  - `lib/api` 里三个函数都写着 `if (!res.ok) await json(res); return serverSentEvents(res)`，可以抽成一个小函数，这次没动。
  - 票 01 交接里提到「锁台、出错静音交给快照」：现在画面读的 `state` 就是会话的快照，没再另外加查询。
- **CI**：43071015 的 run 40469273210 全绿。
