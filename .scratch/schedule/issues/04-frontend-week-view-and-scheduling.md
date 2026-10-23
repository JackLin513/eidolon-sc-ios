# 04: 前端：周视图和排日程（电脑先挑再放、手机抽屉、待排、保存条、确认框）

**What to build:** 日历子页能排一周的日程：默认周视图，先在草稿里摆、点「保存」确认一次、保存即锁住。先读 `frontend/AGENTS.md`「shadcn 纪律」，视觉以 `DESIGN.md` 为准，文案要少。**`DESIGN.md` 先改**她的颜色规则（The Her-Colour-Only-Here Rule）加日程三处：保存过的格子底、月视图的圆点和底、选中待排时亮起的格子；没有新的固定颜色。**`lib/schedule`**：排日程的规则全是纯函数、页面只管画：`timeOf`、`whyNot`（照规格里来自原型的那段，和后端同一套，原因文案一样）、某项能从哪些格子开始、还能排几格（本周 future 且没被占）、待排（这周的工作减去草稿和已保存）、保存时剔掉已开始的、作废那句、确认框的列表、草稿的本机存法（`localStorage` 按用户按周号一个键，读到的周号变了就丢旧的，存不进去退回内存；保存成功后去掉存下的、退回的留在待排）、周号和「下周」是否已发布的判断（给北京周一 0 点和制作人时区）、「只看她」的筛法（这张票只写函数，页面上的「只看她」是票 05）。**页首末端**：`PlaySubpageHeader` 加末端 prop 传给 `SubpageHeader`，放月 / 周切换（`ToggleGroup` 两项、图标加字），日程开着时才有；默认周，上次选的记本机（同筛选的存法，`lib/calendar` 加偏好的存取）。**周视图**：一行一天三列，表头「上午 6–12」「下午 12–18」「晚上 18–24」；行首周几和日期（今天的加圆底），日期下面 Meta 字号 muted 写当天的节假日和角色生日（生日带 16px 头像；节假日按年取的函数照子页现在的给法，跨年也给）；上周 / 下周翻页键，下周只在已发布时能翻；没发布的本周整块中间一句 muted「本周的工作北京时间周一 0:00 发布」。格子：空的 future 格描边；past / now 的空格铺 `bg-muted/40`、写「已过」「进行中」、不可点。有工作的块横跨 `length` 列：第一行她 20px 头像加短名（保存过的末尾 14px `LockedIcon`），第二行类别图标加工作名（截断）；保存过的铺 `--her-wall`，草稿一圈 `border-dashed border-foreground/40` 不上色，正在进行的外面 2px `--her-mark`，做完的 `opacity-60`，已开始的草稿描 `border-destructive`、写「开始了，存不了」；每个块单独注入一次 `herVars`。**电脑（≥ 768px）**：左边待排一列（约 16rem）、右边周视图；选中一项待排时能放的格子铺她的 `--her-wall`、描 1px `--her-mark`，别的格子 `opacity-50`；点亮着的格子放进去成草稿并取消选中；点草稿块拿回待排并保持选中；点保存过的块弹 `Popover` 看说明。**手机（< 768px）**：周视图在上、待排在下；点空格弹底部 `Drawer`（标题「周三 下午」，列出所有待排，能从这一格开始的排前面、点了就放，排不了的 `opacity-50` 右边写原因）；点待排一项弹「排到…」`Drawer` 列出所有放得下的时间段；点草稿块弹 `Drawer`（说明加「拿回待排」）；点保存过的块弹说明；三个抽屉都带她的头像和 `herVars`。**待排**：标题「待排 n 项」（Header 字号）、后面 muted「还能排 n 格 · 周日 24 点后作废」，制作人那边已是周日时改成 `font-medium text-foreground` 的「今晚 24 点后作废」；按偶像分组（24px 头像加全名），不带边框的行：类别图标、名字、Meta 字号 muted「2 段 · 只能下午、晚上」，选中的行铺 `bg-muted`；全排完写一句 muted「本周的工作都排好了」；没发布时不显示待排。**保存条**：有草稿时固定在内容底部（手机上在 dock 上方）「草稿 n 项 · 保存后她才知道」加 default 的「保存」。**确认框** `AlertDialog`：标题「保存这 n 项？」、说明「保存后不能更改，也不能撤掉。」、每项一行（她 24px 头像、「周三 下午」、名字、工作名）、按钮「再看看」「保存」（default）；已开始的在确认前用 `whyNot` 重算剔掉、不列，列表下面一句 muted「〇〇的拍摄广告：已经开始了，不保存，退回待排。」；保存成功后收起、重读日程；服务器退回了哪项，页上方出一句同样的提示。**图标**按 `DESIGN.md` 规则导出：`Music`（`PracticeJobIcon`）、`Camera`（`AppearanceJobIcon`）、`Briefcase`（`BusinessJobIcon`）、`Coffee`（`PrivateJobIcon`）中性色、`Lock`（`LockedIcon`）；周视图的翻页键沿用月视图的两枚。日程关着时：没有切换、只有月视图。读和保存走票 02 的接口（设备时区的带法和回合一样）；`useCalendar` 给卡和子页共用，日程的数据怎么并进去这张票定。月视图的记号、筛选「日程」、只看她、入口、玩法卡前缀是票 05。见规格「界面」一节。

**Blocked by:** 02（接口形状）

**Status:** done

- [x] `DESIGN.md` 她的颜色规则加日程三处，先于代码改
- [x] `lib/schedule` 纯函数和测试：`timeOf` 各情形（下周、昨天、今天 0–6 点、当前段前后）；`whyNot` 每一种原因和能放的情形、原因文案和后端一致；能从哪些格子开始；还能排几格；待排；保存时剔掉已开始的；作废那句（周日前后）；确认框列表；草稿按周号存取、换周丢弃、存不进去退回内存；周号和下周是否已发布（北京周一 0 点、制作人时区）；「只看她」
- [x] `lib/calendar` 测试：月 / 周偏好的存取、默认周
- [x] 页首末端月 / 周切换，记住上次选的；日程关着时没有切换、只有月视图
- [x] 周视图电脑和手机两种排法、四种块状态、过去 / 进行中的空格、没发布的提示、下周只在已发布时能翻、行首的节假日和生日
- [x] 待排、保存条、确认框、已开始的草稿退回和提示、服务器退回的提示；保存后块上有锁、不能再动
- [x] 文案照规格，不多一句；`themeContrast.test.ts` 预计不用加，核对没有新的固定色
- [x] 类型检查、lint、前端测试过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 票收尾：Comments 里写下子页组件和 `lib/schedule` 的形状给票 05、06 用；推一次让 CI 跑、跑 `code-review`

## Comments

### 票 02 交接

- 接口形状、原因文案见票 02 的「实现说明」。`timeOf` 要用 `GET /api/schedule` 回的 `timezone`（档案优先于设备），不是浏览器自己的时区。
- 周几 `day` 0 是周一；`slot` 0 是上午。工作的 `slots` 是名字（`morning` / `afternoon` / `evening`），不是下标。
- 保存一次传这次新加的几项，返回 `saved` 和 `returned`（带 `reason`）；409 带 `schedule_closed` 表示关着。

### 实现说明（票 04）

**`lib/schedule`**（`frontend/src/lib/schedule.ts`）：接口的类型（`Job`、`Placement`、`Week`、`Schedule` / `OpenSchedule`、`Returned`、`Saved`）和 `getSchedule`、`saveSchedule`（带 `X-Timezone`，走 `api`）。排日程看的是一个 `Board`：`{ week, drafts, now }`，`now` 是 `localNow(接口给的 timezone, 时刻)` 给的 `LocalNow`（`date`、`week`、`day` 0 是周一、`hour`）。规则：`timeOf`、`occupantOf`（保存过的先于草稿）、`whyNot`（原因文案和 `schedule.py` 常量一字不差，顺序同后端）、`startsFor`、`freeSlots`、`pendingJobs`、`toSave`（`saving` / `started`）、`confirmRows`、`whenText`（「周三 上午到下午」「周三 一整天」）、`cellText`（「周三 下午」）、`jobNote`（「2 段 · 只能下午、晚上」）、`startedNote`、`returnedNote`、`expiry`、`weekGrid(board, who)`（每行是 `block` / `empty` / `hidden`，块带 `BlockState`：`done` / `now` / `saved` / `started` / `draft`）、`isShown(job, who)`（只看她）、`publishedAt`、`weeksAt`、`isOutdated`。草稿：`readDrafts(userId, weeks)`、`keepDrafts(userId, week, placements)`，键 `eidolon.scheduleDrafts.<用户>.<周号>`，读时删掉这位用户别的周的键，存不进去记在内存；`draftsOf(week, stored)` 去掉不在这周的、已保存的、放不进的、撞上的；`afterSave(drafts, attempted)`。文案在 `copy.play.schedule`。

**`lib/calendar`**：`CalendarMode`（`"month" | "week"`）、`calendarMode(userId)`（默认周）、`keepCalendarMode(userId, mode)`，键 `eidolon.calendarMode.<用户>`；`addDays` 导出给 `lib/schedule` 用。

**`useCalendar`**（卡和子页共用）多给：`schedule`（读到之前 null；读不到当作关着、`scheduleFailure` 说原因）、`scheduleNow`（每分钟走一次）、`draftsOn(周号)`、`keepDraftsOn(周号, 放置)`、`readSchedule()`（读到了返回 true）、`closeSchedule()`。制作人那边换周、或本周 / 下周的工作在读过以后发布了（`isOutdated`），每走一次最多重读一次。

**组件**：`components/play/ScheduleWeek.tsx` 导出 `ScheduleWeek`（props：`board`、`isNext`、`hasNext`、`onWeek`、`characterOf`、`calendar`（行首的节假日和生日）、`who`、`isWide`、`onDrafts`）、`SaveBar`（`board`、`characterOf`、`isSaving`、`onSave(saving, started)`）和类型 `CharacterOf` / `ScheduledCharacter`。`CalendarSubpage` 管月 / 周切换（`ModeToggle`，日程关着时没有）、本周 / 下周、保存流程和页上方的提示（`ScheduleNotice`，带 ✕），现在给 `ScheduleWeek` 传 `who={null}`。`PlayShell` 加 `footer`（保存条），`PlaySubpageHeader` 加 `end`。`MarkedAvatar` 加 `xs`（20px）、`2xs`（16px）。图标：`MonthViewIcon`（`CalendarDays`）、`WeekViewIcon`（`Rows3`）、`PracticeJobIcon`、`AppearanceJobIcon`、`BusinessJobIcon`、`PrivateJobIcon`、`LockedIcon`。`ApiError` 加 `scheduleClosed`（409 的 `schedule_closed`），保存时收到就切成关着。

**短名**（用户当场定的，规格里原来没有数据源）：`characters.toml` 每位加 `short_name`（29 位的初稿：真乃、冬優子、はづき……，等维护者改），加载时校验是 `name` 末尾的一段且比它短，`/api/characters` 带出 `short_name`，前端 `Character.short_name`；块上写短名，没有时写全名。三语配置指南的示例各加一行。

**验收**（本地构建版、Playwright，验完删了脚本、截图和两个验收用户）：电脑选中→亮格子→放下→点草稿拿回并保持选中→确认框→保存后锁住→保存过的块弹说明；月 / 周切换刷新后记得；手机点空格抽屉（能放的排前面、排不了的写原因）、「排到…」抽屉、草稿块抽屉「拿回待排」、保存条在 dock 上方；已开始的草稿描红、确认框下那句；另一台设备抢先存了同一格时页上方「…：格子里有别的工作，不保存，退回待排。」；只有已开始的草稿时不弹框直接退回；`EIDOLON_SCHEDULE=0` 时只有月视图、没有切换。没能现场造的：下周（北京以西周日）和本周没发布（北京以东周一凌晨），这两种只有 `lib/schedule` 的测试。

**判断题**（审查后没改的）：

- 规格要「三个抽屉都带她的头像和 `herVars`」、每个块注入 `herVars`：注入以后子树里的焦点环（`--ring`）和 outline 按钮也是她的颜色，DESIGN.md 她的颜色规则没列这两处。点空格的抽屉一格对应好几位，头像在每一行、不注入颜色；电脑上保存过的块的说明 Popover 里没用到她的颜色，也不注入。
- `returnedNote` 靠服务器给的原因文案（「已经过了」「正在进行」）认出「已经开始了」，后端没有原因代码；两边文案改的时候要一起改。除了这两种，其余原因照原话写成「…：{原因}，不保存，退回待排。」，规格只写了已开始的那一句。
- 玩法页第一级的「日历」卡也用 `useCalendar`，所以现在也读一次 `/api/schedule`、每分钟走一次；票 05 的前缀要用。
- 页上多出的几句：周视图标题「本周 / 下周 10月19日 – 10月25日」（照原型）、「排到…」抽屉的标题带工作名、放不下时「没有放得下的时间段」、草稿都已开始时不弹确认框直接在页上方说。下周全排完时也写「本周的工作都排好了」。
- 内容宽度沿用玩法页的 `max-w-3xl`（原型用的是更宽的 `max-w-5xl`）：电脑上一格约 8rem，放得下头像、短名和锁。
- 保存后重读失败时草稿先不动（页上方说读不到），下次读到时存下的那几项由 `draftsOf` 去掉。
