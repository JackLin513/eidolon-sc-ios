# 12: 教程

**What to build:** 第一次进酒吧时，はづき 照原版点两杯，教制作人调酒，收尾讲正式营业会碰到什么，再带去选曲。纯前端：不调模型、不占限额、什么都不给。台词用票 02 用户校对过的那份。

- **`lib/barTutorial`**：教程的流程写成纯函数。
  - 顺序：开场 → 第一课讲解 → 第一杯（讲解打完才开调酒台）→ 第二课 → 第二杯 → 收尾 → 点唱机那句 → 选曲界面（填好默认 12 首）→ Ready! 回店门口。
  - 上酒时用 `lib/barMixer` 的匹配判一次，然后都往下走：第一杯分调对 Sugar Rush、调成 Piano Man、调成别的，第二杯分调对 Moonblast、调成别的，各接一段反应。调坏的照常上不了，不判。
  - 第一杯调成 Piano Man，跳过第二课，直接收尾。
  - 没有可用的音频时省掉点唱机那句，直接回店门口。
  - 每一步给出侧边菜单上排要显示的备忘。
- **第一次**：
  - 本机没记「看过」时，进 `/play/bar` 跳过选曲界面，直接到店门口。
  - 点一下进门：响 `door`，放固定曲 Every Day is Night（循环，取不到就静音），はづき 用她的选中衣装剪影淡入，照台词往下走。
  - 文本框、打字音效、立绘情绪都和正式光顾一样。
- **看过**：走完或跳过都记「看过教程」，存在这台设备的 localStorage，按用户分开（照 `lib/seenOnDevice`）。中途离开、刷新不记，下次从头来。
- **提示**：只靠台词和备忘。不高亮、不画箭头、不加遮罩、不额外锁按钮。
- **跳过**：教程期间，侧边菜单「点唱机」那一格换成「跳过」，点了直接去选曲界面，不弹确认。
- **重看**：店门口那一屏放一个小像素按钮「教程」，和安卓的「全屏」按钮在一起，点了从头走一遍；重看时也能跳过。
- 不调 `/api/bar/visits`，所以没配对话模型的部署也能走，只要 `GET /api/bar` 开着。「光顾」规格的「新手头 3 次」是后端按光顾记录数的，教程不进记录，前端不用另外做什么。

见规格「教程」。

**Blocked by:** 02（台词，用户校对过）、08（调酒台和匹配）、09（第一课教配方书）、11（选曲界面和「点唱机」那一格）

**Status:** ready-for-agent

- [ ] `lib/barTutorial`（vitest）：两杯的流程；三种反应、两种反应各接得上；Piano Man 跳过第二课；调坏的不判；跳过去选曲；没有音频时省掉点唱机那句；每一步的备忘；「看过」的存取（走完和跳过记、中途不记、按用户分开）。
- [ ] Playwright：清掉 localStorage 后进来是店门口，进门是はづき；照讲解调对两杯，走完到选曲，Ready! 回店门口，再进门发了 `POST /api/bar/visits`；Piano Man 分支；调成别的也往下走；中途「跳过」去选曲；刷新后教程重来；看过以后进来是选曲界面；店门口点「教程」重看。整个教程期间没有发出 `/api/bar/visits*` 请求。截图给用户看。
- [ ] 前端 typecheck、vitest 通过。

## Comments

### 票 12 交接

台词数据在 `frontend/src/lib/barTutorialLines.ts`（票 02，用户校对过再用）：

- `TUTORIAL: Record<TutorialSectionId, TutorialSection>`，从 `TUTORIAL_START`（`"opening"`）开始。段的 id：`opening`、`lesson1`、`first.sugar-rush`、`first.piano-man`、`first.other`、`lesson2`、`second.moonblast`、`second.other`、`closing`、`jukebox`。
- `TutorialSection = { memo: string; lines: readonly TutorialLine[]; then: TutorialThen }`。`memo` 是这一段的备忘，显示在侧边菜单上排；`then: mixer` 那一段，调酒时也显示它。
- `TutorialLine` 是 `{ who: "her"; ja; zh; emotion }` 或 `{ who: "producer"; zh; emotion }`，`emotion` 是 `lib/standAnimations` 的 `Emotion`。
- `TutorialThen`：
  - `{ type: "section", section }`：接着打这一段。
  - `{ type: "mixer", reactions }`：打完打开调酒台，上酒以后用匹配出的饮品 id（`sugar-rush`、`piano-man`、`moonblast`，同 `GET /api/bar` 的目录）查 `reactions`，查不到就接 `reactions.other`。
  - `{ type: "done" }`：台词完了，接着去选曲界面。
- 流程都写在 `then` 里了：`first.piano-man` 直接接 `closing`，`closing` 接 `jukebox`。没有音频时省掉点唱机那句，由 `lib/barTutorial` 做：`closing` 的 `then` 是 `jukebox` 时不进那一段，直接回店门口。

### 票 06 交接

`lib/barVisit` 的形状（`BarVisitState`）：

- `stage`：`door` | `entering`（`POST /api/bar/visits` 在路上）| `visit`；`notice`：店门口写的话；`visit`：`{ id, characterId }`。
- `shown`：文本框上那一页 `{ line, page, isLast, typing: { startedAt, finished } }`；`queue`：还没上框的页（`LinePage[]`，一句话分好页以后一页一项）；`isAwaitingLine`：玩家已经点过最后一页，下一句一来马上打。
- `isOrderTyped`、`isWaiting`：点单句（最后一页）打完了、`waiting` 到了；两样都有时 `openCounter` 把 `isMixing` 设成 true、`pendingMemo` 挪进 `memo`，两个标记清掉。
- `mood`：她最近一句的情绪。

动作（`BarVisitAction`）：`enter`、`refused { notice }`、`line { line, pages, now }`（组件用 `paginate` 分好页）、`event { event }`（其余事件；`retrying`、`failed`、`done` 现在原样返回）、`tap { now }`、`tick { now }`（组件在一页打完的时刻发）、`left`。派生：`shownText`、`isSpeaking`、`isArrowShown`。组件这边是 `components/play/bar/useBarVisit.ts`：调用的 `AbortController` 在 `call`、光顾 id 在 `visitId`；`enter` 的 `catch` 里光顾已经开始（`visitId` 有值）的错误现在直接忽略。

- 教程不走接口，可以直接往同一个 reducer 发 `event { visit }`（visit id 用一个假的、离开时别发 `DELETE`）和 `line`，`TutorialLine` 的 `who` 要转成 `speaker`；或者另起状态，只复用 `lib/barText` 和 `BarTextBox`、`BarGuest`。`isMixing` 由点单句打完 + `waiting` 打开，教程的「打完讲解才开调酒台」可以照样发一个 `waiting`，但要有一句带 `order: true` 的。

### 票 07 交接

- 进门那一下：`useBarVisit` 的 `enter` 开头调 `sound.start()` 和 `sound.play("door")`（`useBarSound`）。教程的进门也要在点击里调这两样；`start()` 现在放默认曲单的第 1 首（正好是 22 Every Day is Night），但放完会接第 2 首。教程要单曲循环 22，得给 `start` 加参数（或用票 11 加的曲单 / 单曲循环口子），别靠默认曲单的顺序。
- 打字音效不用管：`BarSubpage` 按 `typingVoice(state, now)`（`lib/barVisit`）循环，教程的文本框只要也给出同样形状的状态，或者在教程那边算出谁在打字，照样调 `sound.loop(…)`。
- 「没有可用的音频」：看票 11 交接里加的 `audio` 状态（null 是还在读，空的是没有）。
