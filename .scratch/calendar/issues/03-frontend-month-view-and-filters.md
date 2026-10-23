# 03: 前端月视图：筛选、翻月、「今天」、点一天

**What to build:** 日历子页成形：在票 02 的页首和「这一天的清单」之间铺上筛选和月视图。筛选是月历上方一排 `ToggleGroup`（`sm`、多选、按下的中性 `bg-muted`）：角色生日、我的生日、节假日，各带图标（蛋糕、蛋糕、旗子）；制作人没设生日时没有「我的生日」，也没有任何「去填生日」的提示；默认全开，改了就存进票 02 的本机存储，刷新、换页、下次来都还是；筛选只影响日历和卡的状态。月视图：标题「2026年10月」，两边上个月、下个月的图标键，后面一个 ghost 的「今天」只在不是当月时出现，翻多远都行；周一到周日七列、表头一行周几，行数按这个月要几周；非当月的格子淡下去但照常显示事；今天的格子（制作人时区）日期数字加中性圆底（`bg-foreground` 配 `text-background`）。电脑（≥ 768px）每格最多三行，一行 16px 图标加一句（蛋糕加她的显示名、旗子加节假日名、蛋糕加「我的生日」），超过三件时第三行写 muted 的「还有 n 项」；手机（< 768px）每格日期下一排 6px 记号，角色生日是她的 `--her-mark` 圆点、节假日和我的生日是中性 `bg-muted-foreground` 圆点，最多四个，多了不再加。点一天，下面的清单换成那一天，默认选中今天；选中的格子不上她的颜色。全筛掉时月历还是空格子、下面一句「没有要显示的」。节假日按当前显示的月所在的年取，跨年翻页时再取那一年，取过的留着；没回来之前先画生日。格子（哪天、是不是当月、是不是今天）、电脑上三行怎么截都加进 `lib/calendar`，页面只管画。见规格「日历子页」的筛选、月视图两段和 Testing Decisions；样子照原型 `prototype/calendar-schedule`（提交 44838ac，`/gifts?variant=A&col=calendar&cal=D`）的月视图部分，视觉以 `DESIGN.md` 为准，先读 `frontend/AGENTS.md` 的「shadcn 纪律」。

**Blocked by:** 02（`lib/calendar` 的形状、存储模块、子页的骨架和清单）

**Status:** done

- [x] 筛选：三个按钮带图标、按下的是开着的、`bg-muted`；制作人没生日时只有两个；默认全开；改了存本机，刷新和下次打开都还是；筛掉的类在月历、清单和玩法卡状态里都不出现
- [x] 月视图：标题、上下月键、翻多远都行；「今天」只在不是当月时出现、点了回当月并选中今天；周一起七列、表头周几；行数随月份；非当月格子淡下去照常显示事；今天的格子圆底
- [x] 电脑：每格最多三行、16px 图标加一句、超过三件第三行「还有 n 项」；手机：一排 6px 记号、她的圆点和中性圆点、最多四个；两种宽度在 768px 切换
- [x] 点一天：清单换成那一天（日期、一行一件，票 02 的样子）；默认今天；选中的格子不上她的颜色；全筛掉时格子空、下面「没有要显示的」
- [x] 她的颜色只在角色生日的蛋糕图标和手机上的记号上，每一项单独注入 `herVars`；节假日、我的生日、选中格子、今天的圆底都中性
- [x] 节假日按显示的年取，翻到另一年再取、取过的留着；没回来之前先画生日；取失败不报错、只是没有节假日
- [x] `lib/calendar` 加：某个月的格子（首尾补的非当月天数、今天）、电脑上超过三件时的截法；测试补这两样
- [x] 读屏：上下月键、「今天」、格子（日期加这天有几件）、筛选按钮都有名字；用键盘能翻月、能选格子
- [x] 类型检查、lint 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 按 `docs/agents/local-acceptance.md` 在本地构建版上用 Playwright 自己验：电脑和手机的月视图、翻月和「今天」、点一天的清单、筛选记住（刷新后还在）、全筛掉的样子、跨年翻页节假日跟上、她的颜色只在蛋糕和记号上；用接口或改本地库凑同一天两位生日、生日碰节假日、超过三件的格子
- [x] 票收尾：Comments 里写下组件和 `lib/calendar` 最终的形状给票 04 写 `DESIGN.md` 用，以及留给日程那一块的两处位置（页首末端、清单的样子）；跑 `code-review`

## Comments

### 票 03 交接

- `lib/calendar` 的形状、筛选存储和数据怎么读，都写在票 02 的「实现说明（票 02）」里。这张票要接着做的几件事：
  - **节假日按显示的年取**：`useCalendar({ years })` 现在收的是相对今年的偏移。子页翻月时要改成按显示的年取，比如给它一个 `shownYear`，或者改成直接收绝对年份。卡那边是 `[0, 1]`，改的时候一起顺过来。`lib/holidays` 已经把取过的年留着了。
  - **筛选的界面**：用 `calendarKinds(profile.birthday)` 决定出哪几个按钮，改了调 `keepShownKinds`。`useCalendar` 现在每次渲染都直接读 `shownKinds(account.id)`，改了以后要让它重画：在 hook 里放一个 state，或者按改动重读一遍。
  - **这一天的清单**：在 `CalendarSubpage` 的 `DayEvents` 里，日期是传进去的，点一天时换成那一天就行。角色行「生日」前面那个她颜色的蛋糕是票 02 的判断题，见票 02 的 Comments。
  - **全筛掉时**写「没有要显示的」，不是「这一天没有事」。现在子页全筛掉时显示的是后者，这张票里要分开。

### 实现说明（票 03）

- **`lib/calendar` 加了**：`CalendarMonth = {year, month}`（month 是 1–12）、`CalendarCell = {date, isInMonth, isToday}`；`monthOf(date)`、`shiftMonth(month, step)`、`monthCells(month, today)`（周一起，首尾补前后月的天凑满整周，4–6 行）；`cellLines(events)` 返回 `{events, more}`：三件以内全写，多了写前两件，第三行是「还有 `more` 项」。手机上的记号最多四个，是子页里的常量 `CELL_MARKS`。
- **`useCalendar` 改了**：`years` 改成 `(today) => 年份[]`，给出的是绝对年份。卡给今年和明年，子页给月视图首尾两格所在的年。**这里有意偏离规格**：规格说只取显示的月所在的年，现在 12 月、1 月补上的那几天也能看到节假日。筛选改成 hook 里的 state，`keepShown(kinds)` 负责存下来并重画。另外多返回一个 `hasHolidaysOf(year)`：子页看选中那天所在的年取回来没有；卡还是看 `holidaysRead`。
- **子页的组件**（`CalendarSubpage.tsx`）从上到下依次是：
  - `Filters`：`ToggleGroup`，`multiple`、`outline`、`sm`，按下时是 `aria-pressed:bg-muted`；图标是蛋糕、蛋糕、旗子，都不上色。
  - `MonthView`：上个月键、标题（`text-header`，`min-w-28` 居中，翻月时两边的键不跳）、下个月键、ghost 的「今天」。下面是 `grid-cols-7 gap-px` 的网格：`bg-border` 当格线，外面一圈 `rounded-lg border`，表头一行是 Meta muted 的「一…日」。
  - `DayCell`：原生 `<button>`，`aria-pressed` 表示选中，`aria-current="date"` 表示今天，读屏名字写成「10月27日 周二，2 项」。格子手机上最矮 `min-h-14`，电脑上 `md:min-h-24`。非当月的格子里面一层是 `opacity-50`。日期是 `size-6` 的圆，今天铺 `bg-foreground text-background`。手机（`md:hidden`）是一排 `size-1.5` 的圆点；电脑（`max-md:hidden`）是 `text-meta` 的几行，每行 16px `EventIcon` 加一句。
  - `DayEvents` 和 `EventRow`：样子和票 02 一样，非角色那几行的图标改成复用 `EventIcon`。全筛掉时（「开着的」和「有的」两类没有交集），下面只有一句「没有要显示的」，没有日期。
- **她的颜色**：一共三处，每一项各自在自己那一小块上注入 `herVars`：电脑格子里的蛋糕、手机上的圆点、清单里「生日」前面那个 12px 的蛋糕。
- **新图标**：`PreviousMonthIcon`、`NextMonthIcon`（lucide `ChevronLeft`、`ChevronRight`）。
- **验收**：在本地构建版上用 Playwright 验过，接口用拦截凑数据：三位角色、我的生日和文化の日都在 11-03。
  - 电脑：11-03 显示两位加「还有 3 项」，读屏名字是「11月3日 周二，5 项」。
  - 手机：11-03 有四个 6px 的点，前三个是她们各自的颜色，第四个中性。
  - 清单五行，顺序对。
  - 翻月、跨年：翻到 12 月时取了 2027 年，1 月 1 日有元日。一直翻到 2028 年 3 月，「今天」能回到当月并选中今天。
  - 键盘：在上个月键上按 Enter 能翻月，在格子上按空格能选中。
  - 筛选：关掉节假日刷新后还是关着；全关时格子是空的，下面写「没有要显示的」，玩法卡的状态也是空的。
  - 制作人没设生日时只有两个按钮，也没有「去填生日」的提示。
  - 她的颜色只出现在蛋糕和圆点上；旗子、今天的圆底、选中的格子都是中性色。
- **判断题，留给用户**：
  - 翻月以后，选中的那天不变，下面的清单还是原来那天，月视图上可能已经看不到那一格。要改的话，可以翻月时改选这个月的 1 号，或者回到当月时选今天。
- **审查里没改的**：
  - `rounded-lg` 没换成 `rounded.control` 的 token：别处的边框容器也是这样写的。
  - `month ?? monthOf(today)` 在 `years` 回调和 `MonthView` 里各算一次，`monthCells` 也算了两次：只是一个月的格子，算两次很便宜。
  - 合并筛选的那一行写在页面里，没有搬进 `lib/calendarFilter`。
  - `MonthView` 有 8 个 props。
  - 格子用的是原生按钮，不是 `ui/toggle`：要的是格子的版式，不是按钮的样子。
- **留给日程那一块的两处位置**：
  - 页首末端：`PlaySubpageHeader` 现在只有标题，月 / 周切换放在 `SubpageHeader` 的末端。要给 `PlaySubpageHeader` 加一个 `end` 之类的 prop。
  - 清单：`DayEvents` 一行一件，`<li class="flex items-center gap-2 text-body">`，前面是 24px 的头像或者 `size-6` 里一个 16px 的图标，后面是名字。日程的条目照这个样子往 `CalendarEvent` 里加一类，`EventIcon`、`eventText`、`eventKey`、`EventRow` 各补一个分支就行。
