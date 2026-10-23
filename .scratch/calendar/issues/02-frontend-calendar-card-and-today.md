# 02: 前端走通：「日历」卡、没开放只剩它、子页看今天

**What to build:** 从玩法页能走到日历、看到今天有什么。先改 `DESIGN.md`：The Her-Colour-Only-Here Rule 加上「日历里角色生日的蛋糕图标和手机上的记号（她的 `--her-mark`）」（日程那一块再加格子底、圆点和亮起的格子），「玩法页」一节里「两张卡」「未开放只剩『玩法暂时没有开放』」两处改成三张卡、没开放只剩日历卡。玩法卡注册表加 `calendar`：一直显示（不看好感度和礼物的开关）、图标 lucide `CalendarDays`（别名 `CalendarIcon`）、去 `/play/calendar`、名字旁不出点；加之前先对照 main 上注册表的现状（加一张卡要改子页枚举、`CARDS`、图标表、子页分派和文案五处）决定要不要让注册表出图标和子页组件，决定写进 Comments，哪种都行、但要在这张票里定。卡的状态在没筛掉的几类里找今天（制作人时区）及以后最近的一件：「下一个：10月27日 樋口円香的生日」「下一个：11月3日 文化の日」「下一个：M月D日 我的生日」，今天就有写「今天：…」；同一天几件取角色生日、我的生日、节假日的顺序，同类取偶像顺序靠前的；三类全筛掉状态为空。日历卡要角色列表（带 `birthday`）、制作人档案（生日）和当年的节假日，第一级怎么读由这张票定（能复用别处已经读到的就复用）；接口没回来之前状态为空、卡照样在。好感度和礼物没开放时第一级不再是「玩法暂时没有开放」的 `Empty`，只剩日历卡；礼物、任务两个子页没开放时照旧。日历的计算收进 `lib/calendar` 纯函数：某一天有哪几件事（三类合在一起、按上面的顺序排）、筛选、「下一个」、2 月 29 日没有 29 日的年份落在 28 日、制作人没生日时没有「我的生日」这一类；页面只管画。筛选的本机存储单独一个 `lib/` 模块：`localStorage` 一个键存开着的几类，默认全开，坏值回默认，存不进去时只在这次页面里记着，写法照列表偏好、公告已读；这张票还没有筛选的界面，只有模块和读取。子页 `/play/calendar`：页首 `SubpageHeader`、标题「日历」、返回键回 `/play`（两种宽度都有），页首末端留空给日程的月 / 周切换；内容 `PageShell`、`max-w-3xl`；这张票的内容只有「这一天的清单」且只列今天：Subtitle 字号 muted 的日期（「10月27日 周二」），下面一行一件：角色生日是她 24px 的头像加显示名加 Meta 字号 muted 的「生日」，节假日是旗子图标（lucide `Flag`，别名 `HolidayIcon`）加名字，我的生日是蛋糕（lucide `Cake`，别名 `BirthdayIcon`）加「我的生日」；什么也没有时一句 muted 的「这一天没有事」。蛋糕图标用她的 `--her-mark`，每一项单独注入一次 `herVars(官方色)`（同统计页的排行、对话列表没看过的搭话的圆点）；节假日和我的生日不上色。不改后端。见规格「玩法页的『日历』卡」「日历子页」（数据、怎么算、这一天的清单、她的颜色）、「没开放和开关」和 Testing Decisions。

**Blocked by:** 01（`birthday` 字段和节假日接口的形状）

**Status:** done

- [x] `DESIGN.md`：她的颜色规则先加日历那一处（提交里在代码之前）；「玩法页」一节「两张卡」「未开放」两处改过；图标还不写（票 04）
- [x] 注册表：`calendar` 卡一直显示、不出点、去 `/play/calendar`、图标 `CalendarIcon`；子页枚举加 `calendar`，`/play/calendar` 不被跳到 `/play`；要不要让注册表出图标和子页组件在 Comments 里写下决定和理由
- [x] 卡的状态：「下一个：M月D日 〇〇的生日」「下一个：M月D日 文化の日」「下一个：M月D日 我的生日」「今天：…」；按制作人时区的今天找；同一天几件的顺序；跨年能找到明年的；全筛掉为空；数据没回来为空；文案进 `copy.play.cards`
- [x] 没开放：好感度和礼物关着时第一级只剩日历卡、没有 `Empty`；接口回 409 切成这样时也一样；礼物、任务子页没开放时照旧是 `Empty`；导航「玩法」照旧
- [x] `lib/calendar`：某一天的事（两位同一天、生日碰节假日的顺序、2 月 29 日落在 28 日、制作人没生日没这一类）、筛选、「下一个」（今天就有、跨年、全筛掉）；输入是角色列表、制作人生日、节假日列表和筛选，不读接口
- [x] 筛选存储模块：默认全开（三类，制作人没生日时「我的生日」这一类不算）、存和读、坏值回默认、存不进去退回内存；测试照 `listPreferences.test.ts`、`announcements.test.ts`
- [x] 子页：页首、返回键（两种宽度、`getByRole("button", { name: "返回" })` 能点）、浏览器返回键回玩法页、刷新还在子页；内容只有今天的清单；头像、显示名、「生日」、旗子、蛋糕、「这一天没有事」照上面；蛋糕上她的颜色、别的不上色
- [x] 节假日按子页显示的年取（这张票只有今年）、取过的留着；没回来之前先画生日
- [x] `lib/` 测试：玩法卡（`calendar` 一直显示、状态几种写法、没开放时只剩它）；`lib/calendar` 上面各条；存储模块；`playRoute` 认 `calendar`；`themeContrast.test.ts` 预计不用动
- [x] 类型检查、lint 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 按 `docs/agents/local-acceptance.md` 在本地构建版上用 Playwright 自己验：宽屏和手机的第一级三张卡（日历卡在网格里和任务卡并排）、状态一行；没开放（本地后台 `EIDOLON_AFFINITY_AND_GIFTS=0`）只剩日历卡；进子页、返回、刷新；今天的清单（用接口或改本地库凑一个今天有生日的角色、再凑一个节假日看三类都画对、她的颜色只在蛋糕上）
- [x] 票收尾：Comments 里写下 `lib/calendar` 的形状（事、筛选、类别的类型）和子页数据怎么读给票 03 用；跑 `code-review`

## Comments

### 票 01 交接

- 角色列表 `GET /api/characters` 每位有 `birthday: "MM-DD"`（前端类型 `Character.birthday: string` 已加）。2 月 29 日的落点规则和制作人生日一样（平年算 2 月 28 日）；目前 29 位里没有 2 月 29 日的。
- 节假日：`GET /api/calendar/holidays?year=YYYY`，要登录，回 `[{"date": "YYYY-MM-DD", "name": "文化の日"}, …]`，按日期排；年份不合法或库算不出（1949 年前、2099 年后）回 `[]`；浏览器缓存一天（`private, max-age=86400`）。
- 制作人的生日还是从 `GET /api/profile` 的 `birthday: {month, day} | null` 读。

### 实现说明（票 02）

- **注册表的决定：不让 `lib/playCards` 出图标和子页组件。** `lib/` 只放纯数据和纯函数（能在 vitest 里不带 React 地测），图标表留在 `PlayCardLink`、子页分派留在路由页。两处都改成 `Record<PlaySubpage, …>`（路由页原来是 `if`，现在是 `SUBPAGES` 表），加一个子页枚举时，漏了哪一处类型检查都会报错。所以加一张卡还是改五处（枚举、`CARDS`、图标表、`SUBPAGES`、文案），但一处都漏不掉。
- **注册表接口改了一处**：`status(state, context)` 改成 `status(context)`，每张卡自己判断数据回来没有（礼物、任务看 `state`，日历看 `calendar`）。`PlayContext` 多了 `calendar: CalendarCardContext | null`。
- **`lib/calendar` 的形状**（纯函数，不读接口）：
  - 日期一律是 ISO 日 `YYYY-MM-DD` 字符串，不带时区；`todayIn(timeZone, now)` 给制作人时区的今天；`partsOf(date)` 拆成 `{year, month, day, weekday}`（0 是周日）。
  - `CALENDAR_KINDS = ["character", "producer", "holiday"]`，类型 `CalendarKind`，也就是同一天里排列的顺序。`calendarKinds(producerBirthday)` 给出有哪几类，没生日时没有 `producer`。
  - `Holiday = {date, name}`，和接口给的一样。`CalendarData<C> = {characters, producerBirthday, holidays}`，`C` 是任何带 `birthday: "MM-DD"` 的东西，角色按偶像顺序。`CalendarView<C> = {today, data, shown}`。
  - `CalendarEvent<C>`：`{kind: "character", character}`、`{kind: "producer"}`、`{kind: "holiday", name}` 三种。
  - `eventsOn(date, data, shown)` 返回某一天的事，已经排好序、筛过。`nextEvent(today, data, shown)` 返回 `{date, event} | null`，最多往后找一年。2 月 29 日的落点在 `eventsOn` 里处理。
- **筛选存储** `lib/calendarFilter`：`shownKinds(userId)` / `keepShownKinds(userId, kinds)`，键 `eidolon.calendarKinds.<用户 ID>`，值是开着的类别数组（`[]` 是全关）。不是数组、或者数组里有认不得的值，都回到全开。存不进去时记在模块内存里。这里不管制作人有没有生日，那一类由 `calendarKinds` 略去。
- **节假日** `lib/holidays`：`getHolidays(year)` 每年只取一次，取到的留在模块里，整个页面都用这一份；失败的那一年下次再取。
- **数据怎么读**：`components/play/useCalendar({ years })` 由第一级和子页共用。
  - 角色用外壳的 `useDirectory().characters`，头像已经按外观换好。档案自己 `getProfile()` 读一次；读不到就当作没生日，用浏览器的时区。
  - `years` 是相对今天所在那一年的偏移：卡用 `[0, 1]`，跨年能找到明年的节假日；子页用 `[0]`。
  - 返回 `{calendar: CalendarView<Character> | null, holidaysRead}`。卡在 `holidaysRead` 之前状态为空；子页在节假日回来之前先列生日，这一天没有生日时显示「正在读取」，不先说「这一天没有事」。
- **判断题，留给用户**：
  - 清单里角色生日那一行写的是「24px 头像 + 显示名 + Meta muted『生日』」，规格这里没有蛋糕。但票里要求蛋糕用她的颜色、每项注入一次，所以我在「生日」前加了一个 12px、她颜色的蛋糕（`herVars` 注入在这一小块上）。不要的话，删掉 `CalendarSubpage` 里 `EventRow` 的那个图标就行，规则里的「蛋糕」那时就只剩月格里的。
  - 第一级只剩日历卡时（没开放），它是第一张，所以铺 `bg-muted`、占满一行，照「第一张铺满一行」的写法。
- **审查里没改的**：
  - `event.kind` 的分支在 `EventRow`、`eventKey` 和卡的 `eventText` 里各写了一遍（三处要的东西不同，就不收成一张表了）。
  - `useCalendar` 用 `wantedKey` 字符串让依赖保持稳定。
  - 卡取今年和明年的节假日，12 月 31 日往后找一年会碰到后年 1 月 1 日，那一年没有取，影响可以忽略。
  - 页面开着跨过午夜，「今天」会随下一次渲染更新，但节假日不会去补取新的一年。
- **验收**（本地构建版，Playwright）：
  - 宽屏下第一级三张卡，日历卡和任务卡并排；手机上一列。状态写的是「下一个：10月27日 樋口円香的生日」。
  - `EIDOLON_AFFINITY_AND_GIFTS=0` 时第一级只剩日历卡、没有 `Empty`；礼物、任务子页照旧是 `Empty`；日历子页照常。
  - 进子页，返回键（两种宽度）、浏览器返回、前进、刷新都对。
  - 拦接口凑了一个今天，有两位角色生日、我的生日和一个节假日：顺序对，头像 24px；蛋糕取各自的官方色，我的生日和旗子是中性的 muted。节假日晚回来时先显示「正在读取」，不出现「这一天没有事」。
