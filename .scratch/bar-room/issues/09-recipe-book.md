# 09: 配方书

**What to build:** 调酒时客人窗被配方书盖住，照原版能按名称、口味、种类和瓶装找饮品，看官方中文的配方卡。

- **`lib/barRecipeBook`**：
  - 四个标签：按名称、按口味、按种类、瓶装。
  - 按口味、按种类先是一个标题（如「按口味搜索」）加一列灰字分类；按名称是两列大写字母。点分类列出这一类的饮品，每类最多 6 款。
  - 点饮品看配方卡，底部左右翻页加「n/24」，不绕回，到头时箭头变淡。
  - 瓶装一栏列 4 款，点开看图和一句小字。不能组合筛选。
  - 口味、种类的中文用菜单分类名：甜味、苦味、酸味、辛辣、发泡；女性化、男性化、经典、时尚、宣传。数据用 `GET /api/bar` 的目录。
- **画面**照原型：白框顶上四个标签，当前的反白。饮品名用英文原名，和备忘、字幕一致；配方卡用票 01 生成的官方中文图。
- **什么时候出现**：进入调酒状态时盖住客人窗（她的立绘），调酒状态结束时收起。
- **音效**：悬停 `mouse_hover`，换标签 `jukeselect`，点分类 `jukepick`，点饮品 `jukechange`，翻页 `jukepick`（到头时 `jukechange`）。

见规格「配方书」。

**Blocked by:** 07（音效的口子；调酒状态在 06）

**Status:** done

- [x] `lib/barRecipeBook`（vitest）：四个标签的分类和列表、每类最多 6 款、翻页不绕回、到头。
- [x] Playwright（拦下的 SSE，走到点单）：调酒时配方书盖住客人窗；四个标签各点一遍，翻到头；调酒状态结束时收起（票 08 做完了就上一杯验，没做完就靠 `lib/barVisit` 的状态）。截图给用户看。
- [x] 前端 typecheck、vitest 通过。

## Comments

### 票 09 交接

- 来自票 05：配方书放进 `BarScreen` 的 `book` 插槽（在立绘上面、外框下面）。分层、`Sprite`、`PixelText`、`HitArea` 见票 05 的「给票 06–12」。

### 票 07 交接

- 放音效：`BarSubpage` 里的 `sound.play(name)`（`useBarSound`），名字照清单的 `name`：`mouse_hover`、`jukeselect`、`jukepick`、`jukechange`。没音频时什么都不做。悬停音效连着触发时每次都新起一个缓冲源，原版也是这样叠的，不用去重。

### 票 08 交接

- **瓶装从配方书拖进摇酒器**（用户在票 08 定的，规格「配方书」已改）：台上不放瓶装。拖的口子已经有了：`BarSubpage` 里的 `counter.drag`（`useShakerDrag`），在瓶装那一格上展开 `counter.drag.handlers({ bottle: drink })` 就能拖，跟着指针走的瓶子、摇酒器的悬停图、松手放进去、`addingredient` 都由调酒台画和处理；摇酒器不空时放不进去，响 `buttonnoclick`。`counter` 要从 `BarSubpage` 传给配方书。
- 瓶装的图用 `drinkSprite(drink.id)`（`components/play/bar/drinkSprites.ts`），35×53、中心在 (17,26)。
- 补上票 08 那条没做的 Playwright：瓶装拖进空的摇酒器、拖进去以后材料变灰、上酒的正文是 `{ method: "bottle", bottle: <id> }`；摇酒器里有东西时拖不进。
- 调研笔记里打开配方书响 `boot_up`，票 08 没放，配方书打开时放。
- 调酒台开没开：`state.isMixing`（`lib/barVisit`）；上酒请求在路上时 `state.isServing`。

### 实现说明（票 09）

- **`lib/barRecipeBook`**（新）：`RecipeBookState`（`tab`：null 是封面，`category`，`drink`）和归约 `recipeBook(state, action, drinks)`，动作 `tab`、`category`、`drink`、`page { step }`；什么都没变的动作（已经在这一栏第一层又点这个标签、翻过头、点了列表里没有的）原样返回同一个对象，组件据此响到头的 `jukechange`。派生：`categories(tab, drinks)`（按名称是有配方卡的饮品的首字母，口味、种类是菜单的五个，瓶装没有）、`drinksIn(tab, category, drinks)`（按名字排，最多 6 款；瓶装那一栏是 4 款瓶装）、`pageOf`（「n/24」，按配方卡的页码排，和字母序一致）。只有带配方卡的才按名称、口味、种类查得到。
- **组件**：`BarRecipeBook.tsx`，坐标照原型 `RecipeBook`；`BarSubpage` 在 `state.isMixing` 时放进 `BarScreen` 的 `book` 插槽，上酒被收下（`isMixing` 清掉）时收起，下一单再打开时从封面开始。打开时响 `boot_up`、照原型从上往下刷开（`bar.css` 的 `bar-wipe`）。瓶装点开是图加小字，图上挂 `counter.drag.handlers({ bottle })`，调酒台开着时才拖得动；摇酒器不空时由调酒台拒收、响 `buttonnoclick`。
- **测试夹具**：读 `characters/drinks.toml` 的函数从 `barMixer.test.ts` 挪到 `lib/barCatalogFixture.ts`，两份测试共用。
- **几处判断**：
  - 第四个标签写「瓶装饮品」（原型定稿和原版），不是票里简写的「瓶装」；口味、种类的分类写成「甜味饮品」这样（照原型）。
  - 点当前的标签回到这一栏的第一层，不响 `jukeselect`（照原型）。
  - 悬停音效只在鼠标上响，手指没有悬停；翻页箭头也响悬停音。
  - 按名称两列字母的点击区按列宽（92），原型的 200 宽会让右列盖住左列。
- **验收**：本地构建版、Playwright 拦下事件流：点单前没有书、调酒时盖住客人窗；四个标签各点一遍（口味五类、甜味 6 款、按名称两列字母、按种类、瓶装 4 款）；Sugar Rush 是 21/24，往后翻到 24/24 再翻不动，Bad Touch 1/24 往前翻不动；补上票 08 那条：Rum 拖进空的摇酒器、材料变灰、上酒正文 `{"method":"bottle","bottle":"rum"}`、上酒后书收起；下一单书回到封面，摇酒器里有 1 份 Adelhyde 时 Rum 拖不进。页面没有报错。
- **审查后没改的**（判断题）：按标签分支的判断在 `categories`、`drinksIn` 和组件的 `categoryName` 里各写了一次，可以并成一张按标签查的表；`category` 是一个字符串，同时装首字母、口味、种类，组件里要 `as keyof` 转一下，可以改成按标签区分的联合类型；口味、种类在 `api.ts` 的类型、`lib/barRecipeBook` 的数组和 `zh.ts` 的键里各列了一遍。
- **真机人工验收**（留给用户）：手机上手指从配方书拖瓶装进摇酒器；小数缩放下配方卡和灰字清不清楚。
