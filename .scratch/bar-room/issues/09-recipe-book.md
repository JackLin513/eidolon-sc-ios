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

**Status:** ready-for-agent

- [ ] `lib/barRecipeBook`（vitest）：四个标签的分类和列表、每类最多 6 款、翻页不绕回、到头。
- [ ] Playwright（拦下的 SSE，走到点单）：调酒时配方书盖住客人窗；四个标签各点一遍，翻到头；调酒状态结束时收起（票 08 做完了就上一杯验，没做完就靠 `lib/barVisit` 的状态）。截图给用户看。
- [ ] 前端 typecheck、vitest 通过。

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
