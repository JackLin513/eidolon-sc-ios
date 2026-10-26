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

**Status:** done

- [x] `lib/barTutorial`（vitest）：两杯的流程；三种反应、两种反应各接得上；Piano Man 跳过第二课；调坏的不判；跳过去选曲；没有音频时省掉点唱机那句；每一步的备忘；「看过」的存取（走完和跳过记、中途不记、按用户分开）。
- [x] Playwright：清掉 localStorage 后进来是店门口，进门是はづき；照讲解调对两杯，走完到选曲，Ready! 回店门口，再进门发了 `POST /api/bar/visits`；Piano Man 分支；调成别的也往下走；中途「跳过」去选曲；刷新后教程重来；看过以后进来是选曲界面；店门口点「教程」重看。整个教程期间没有发出 `/api/bar/visits*` 请求。截图给用户看。
- [x] 前端 typecheck、vitest 通过。

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

### 票 08 交接

- 判两杯调成了什么：`lib/barMixer` 的 `matchDrink(drinks, mixture)`，`drinks` 是 `GET /api/bar` 的目录（`useBar()` 的 `bar.drinks`），`mixture` 是 `{ adelhyde, bronson_extract, powdered_delta, flanergide, karmotrine, ice, aged, method }`；回 `{ drink, big }`，调坏的回 null。调酒台停下时已经算好了，就在 `state.mixer.made`（`isFinished(state.mixer)` 时有效；null 是调坏的，调坏的本来就上不了）。
- 调酒台的状态和动作在 `lib/barVisit` 里（`mixer`、`mix`、`serve`）。教程不调接口：上酒那一下不要走 `useBarVisit.serve`，自己拿 `state.mixer.made` 判，然后照教程往下走；`BarCounter`、`useBarCounter` 只认 `mixer`、`isCounterOpen`、`onMix`、`serve` 这几样，教程给自己的就行。

### 票 09 交接

- 配方书是 `components/play/bar/BarRecipeBook.tsx`，放进 `BarScreen` 的 `book` 插槽：`<BarRecipeBook drinks isCounterOpen counter sound />`，`counter` 是 `useBarCounter` 的返回（瓶装从书里拖进摇酒器靠它的 `drag`）。教程照 `BarSubpage` 的写法，调酒台开着时挂上、收起时卸下；挂上时响 `boot_up`、刷开，每次挂上都从封面开始。
- 书里翻到哪一页是组件自己的状态（`lib/barRecipeBook` 的 `recipeBook`、`COVER`），外面读不到。教程只靠台词和备忘提示，用不着；真要按书的状态往下走，得把 `book` 状态提到外面。

### 票 10 交接

- 白框按钮有共用件 `BarButton`（`components/play/bar/BarButton.tsx`，72×22，原型 `EndPanel` 的样子），教程要按钮时可以用。
- 结束卡是 `BarEndCard`，按 `lib/barVisit` 的 `endCard(state)` 出；教程不调模型、什么都不给，要结束卡的话是「她走了」那种写法。

### 票 11 交接

- **打开选曲界面**：`BarSubpage` 里的 `isChoosing`（`useState(true)`）。为真、`jukebox.isAvailable`、`jukebox.jukebox` 读出来了时盖上 `BarJukeboxSetup`；Ready! 调 `jukebox.choose(slots)` 存下、`setChoosing(false)` 到店门口。教程第一次进来要跳过选曲界面：初值改成「看过教程」；收尾那句之后 `setChoosing(true)` 就弹出来（槽填的是 `jukebox.jukebox.slots`，第一次就是默认 12 首）。「填好默认 12 首」要是指不管存过什么都用默认的，用 `defaultSlots(audio)` 传给 `slots`。
- **没有音频**：看 `sound.audio`：`null` 是 manifest 还在读（这时 `BarSubpage` 盖一层黑的），曲目是空的是没有音频。`jukebox.isAvailable` 在读的时候也是假的，判「省掉点唱机那句」要等读完。
- **侧边菜单那一格**：`SideMenu` 的 `jukebox` 属性（`JukeboxCell`，`BarScreen.tsx`）：`{ state: "open" | "closed" | "none", onToggle }`，null 是不画。「跳过」要换掉它：给 `SideMenu` 加一种写法（例如 `jukebox` 换成一个更通用的 `{ label, color, onClick }` 格子），位置 (445,312) 72×20，字在 (450,313)。
- **曲目**：`useBarJukebox.start()` 开始过就不再动（`isStarted`），从选的第 1 首放。教程要循环放 Every Day is Night（22）：现在没有「放指定的一首」的口子，要给 `useBarJukebox` 加一个（同一个 `<audio>`，`loop = true`），并且教程结束后真正的第一次光顾进门时 `start()` 还能从第 1 首放起（把 `isStarted` 复位，或教程那首不算开始）。注意 `preview` / `stopPreview` 也用这个 `<audio>`：教程完了弹选曲界面时一试听就会停掉教程那首，`stopPreview` 只停 `loop` 的，教程那首也是 `loop` 的话会一起停（也正好：选曲界面上本来就安静）。

### 实现说明（票 12）

- `lib/barTutorial`（新）：`beginTutorial({ characterId, hasJukebox, layout, now })` 和 reducer `barTutorial(state, action)`，动作 `tap`、`tick`、`mix`、`serve`、`skip`。文本框、立绘情绪、调酒台都借 `lib/barVisit` 的状态（`state.visit`）：一段的台词一次排进队，最后一页点过以后接下一段；`then: mixer` 的那段最后一页打完就开调酒台（不借 `order` / `waiting`，制作人那句也能收尾）。上酒按 `mixer.made.drink.id` 查 `reactions`，查不到接 `other`；调坏的 `canServe` 为假，原样返回。结束时 `end` 是 `"jukebox"` 或 `"door"`（没有音频时省掉 `jukebox` 段、跳过也回店门口）。`tutorialMemo(state)` 是框上那段的备忘。「看过」：`hasSeenTutorial(userId)`、`keepTutorialSeen(userId, state)`（没结束不记），键 `eidolon.barTutorialSeen.<用户 ID>`，照 `lib/seenOnDevice` 存时刻。
- `useBarTutorial`（新）：reducer 加计时、声音、「看过」。`begin()` 在点击里响门声、建 AudioContext、`jukebox.loopTrack(22)`，等像素字载入后开始（期间再点不会开始第二次）。结束时记看过、停掉那首、调 `onEnd`。`isSeen` 在本机记录和角色列表读到之前是 null；没有 はづき 时没有教程，当作看过、店门口不出「教程」。
- `useTypingClock`（新文件，从 `useBarVisit` 抽出）：光顾和教程共用的打字计时。
- `useBarJukebox`：加 `loopTrack(id)`，循环放一首、顶掉正在放的、不算开始过（之后进门 `start()` 照样从第 1 首放）；没有这一首时静音。`stopPreview()` 一样停掉它。
- `SideMenu`：`jukebox: JukeboxCell` 换成通用的 `cell: MenuCell`（`{ label, color, pressed?, onClick | null }`），`jukeboxCell(state, onToggle)` 造「点唱机」那一格；加 `memoLabel`，教程里备忘前写「备忘」（`copy.bar.tutorialMemo`），不写「点单」。
- `BarDoor`：加 `onTutorial`，小像素按钮「教程」在「全屏」左边，没有「全屏」时占它的位置。
- `BarSubpage`：选曲界面的开关 `choosing: boolean | null`，null 时跟着「看过」走（看过才弹，第一次跳过）；看没看过读出来之前也盖一层黑的。教程进行时文本框、立绘、调酒台、配方书都画教程的状态，小播放器不出。
- 判断：
  - 收尾弹出的选曲界面填的是存着的选择（第一次就是默认 12 首），不是硬塞默认的：重看教程时不冲掉用户选好的曲目。
  - 教程不加「请慢用」：上酒后直接接她的反应。
  - 重看教程会顶掉点唱机正在放的曲目，教程结束后店门口是安静的，再进门才从第 1 首放。

### 验收（票 12）

本地构建版、Playwright（存储桶 `bar/*` 拦到本机提取目录，`/api/bar/visits*` 拦下记数并回 429）38 项全过：清掉 localStorage 后进来是店门口、进门是はづき 和开场第一句、备忘、「跳过」那一格、请求了 22 号曲目；第一课讲完开调酒台；调对 Sugar Rush、Piano Man、调成别的（Bad Touch）、调对 Moonblast 各接对的反应；Piano Man 不说第二课；走完说了点唱机那句、到选曲界面、记下看过；Ready! 回店门口、再进门发了 `POST /api/bar/visits`；看过以后进来是选曲界面；中途刷新回店门口、不记看过、再进门从开场来；中途「跳过」去选曲并记下；店门口「教程」重看、重看时也能跳过；manifest 404 时连点两下进门是开场、走完不说点唱机那句直接回店门口；所有教程期间都没有 `/api/bar/visits*` 请求。安卓（Pixel 7 横屏模拟）店门口「教程」和「全屏」并排。

### 审查（票 12）

修了的：manifest 里没有 22 号时 `loopTrack` 不停正在放的曲目（重看教程会接着放曲单）；等像素字时连点进门会开始两次；角色列表没读到时点门没反应（现在算「还在读」，盖黑层）；`useTypingClock` 挪进自己的文件；`loopTrack` 和 `preview` 抽出 `playLooped`；`keepTutorialSeen` 去掉没用的 `at`；`TUTORIAL_VISIT_ID` 不导出；`BarSubpage` 里 `shown` 改名 `scene`、`lesson` 改名 `tutorialState`；hook 文档注释对上实际的名字；删掉一段和 `walk` 重复的测试前缀。

只报告、没改（判断题）：

- 收尾的选曲界面填存着的选择，不是「不管存过什么都用默认」（见上面的判断）。
- 教程里备忘前的小字改成「备忘」，是新加的文案；不要的话删掉 `memoLabel`，就照旧写「点单」。
- `BarSubpage` 里「教程还是光顾」的分支有六七处，可以让两个 hook 返回同一种形状一次选好；现在没做。
- 停教程那首用的是 `stopPreview()`，名字说的是试听。
- `choosing: boolean | null` 用 null 表示「跟着看过走」，靠注释读懂。

