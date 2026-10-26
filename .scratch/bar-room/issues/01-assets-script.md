# 01: 素材脚本、素材和字体

**What to build:** 酒吧画面要用的图和字都进仓库，并且能从本机的原版提取目录重新生成。这一张没有画面，后面每张前端票都从这里取素材。

- 原型分支 `prototype/bar`（1c8a26d9）的素材脚本改成正式的 `bar-assets.py`，放在前端的 scripts 下：原版提取目录作参数（本机是 `E:\Download\others\VA11_extract`），把用到的每张图写进 `frontend/public/bar/img/`；被裁掉的透明边照调研笔记 5.1 节（调研分支 `research/bar-screen`）和原型脚本补回，偏移记在脚本里。保持 PNG，不转 webp。
- 用到哪些图照规格「素材和素材脚本」的单子：吧台背景、外框（挖出 L 形的客人窗）、配方书（框、标签、有卡的 24 张中文配方卡）、调酒台全套、饮品成品图和故障瓶、瓶装 4 款、电视 10 个台、店门口三帧霓虹、点唱机界面、鼠标手套（1/2/3 倍）、`arrow_text_2`、扫描线。文件名尽量沿用原型的，后面的票照原型抄坐标时对得上。
- 外框右上角原版的 logo 先抹掉，用周围外框的像素补平。脚本给「贴 logo」留一步，票 04 把正式的「VA-283」烤进去。
- 「缝合像素」12px（zh_hans 版，含假名）放 `frontend/public/bar/fonts/`，旁边带 OFL 许可文件。
- 原版提取目录当不可信数据：脚本只读不执行，用 `python -I` 跑。

见规格「素材和素材脚本」。

**Blocked by:** None (can start immediately)

**Status:** done

- [x] 脚本从原版提取目录生成全部图；在已经生成过的仓库上再跑一次，`git status` 没有变化。
- [x] 原型变体 A 引用过的图都在，一共约 260 KB；只有变体 B、C 用的不生成。
- [x] 外框上看不到原版的 logo 文字。
- [x] 字体和 OFL 许可文件在；脚本用 `-I` 跑，不执行提取目录里的任何东西。
- [x] 收尾：Comments 写下图的清单和命名（哪张图对应原型的哪一块、偏移记在哪），给票 04–12 用。

## Comments

### 实现说明（票 01）

- 脚本 `frontend/scripts/bar-assets.py`：`uv run --no-project --with pillow python -I frontend/scripts/bar-assets.py E:\Download\others\VA11_extract`。只读提取目录的 `sprites/`，写 `frontend/public/bar/img/`，再删掉输出目录里不在清单上的 PNG；再跑一次 `git status` 不变（已验）。共 187 张、242 KB。
- 补透明边的偏移都在脚本的 `PAD`（逻辑宽高、偏移 x/y）和 `CURSORS` 里，来源是调研笔记 5.1 节和原型脚本；`COPY` 里的是原样拷的。
- 和原型 `prototype/bar`（1c8a26d9）的 `public/prototype-bar/img/` 比：同名的图除 `frame`、`scanlines` 外逐字节相同。`frame` 抹了 logo；`scanlines` 原版切出 640×359，补成 640×360。
- 没生成的（原型有、变体 A 不引用）：`ctc_0…7`（变体 B、C 的「点击继续」）、`tv_0…5`（和 `ch_news_*` 重复）、`ch_wrestle_0…1`（原型的十个台里没有它）、`slot_done`、`slot_off`（栏位 2，不做）、`pulse_white`（重做的白光圈，原型没用）、`recipe_0`（空白页）。
- 例外：原型 `data.ts` 的 Frothy Water（`drink_fwater`）在提取目录里没有成品图，原型里就是坏图；交给票 08 定画哪张。
- 配方书的四个标签原型是用像素字画的，不用原版的悬停条图（`179_hoverrecipe` 等），所以没生成。
- 外框里 logo 那块原版底色就是纯黑，「补平」就是整块填黑。
- 外框 logo：`LOGO_BOX` 是 (436,27)–(623,90)，即黑底那一块 187×63（不含右边框那列）；里面整块填黑。脚本旁边有 `frontend/scripts/bar-logo.png` 时，按 alpha 合成贴在 (436,27)。
- 字体 `frontend/public/bar/fonts/fusion-pixel-12px-zh_hans.woff2`（960 KB）和 `OFL-fusion-pixel.txt`，从原型分支原样带来，不由脚本生成。

**图的清单**（`/bar/img/<名字>.png`，名字沿用原型，坐标照原型 `pieces.tsx` 抄）：

| 名字 | 原型里的哪一块 | 尺寸 / 备注 |
|---|---|---|
| `frame` | 整张外框（客人窗、文本框是透明洞），logo 已抹 | 640×360 |
| `barground` | 吧台背景，画在 (11,18)；电视洞在 +(228,26) 99×41 | 424×257 |
| `fan` | 吊扇，背景 +(170,31) | 24×24 |
| `ch_<台>_<帧>` | 电视：burrito 3、wk 7、dollar 2、news 6、yiik 3、toku 3、mwj 4、hassy 1、ramen 3 帧；第 10 台关着画黑 | 99×41 |
| `scanlines` | 扫描线滤镜 | 640×360 |
| `intro_0…2` | 店门口霓虹三帧（招牌还是 VALHALLA，票 06 改） | 640×360 |
| `arrow_0…3` | 文本打完后的倒三角 arrow_text_2，偏移已补 | 8×8 |
| `cur_<spr\|clicked\|open\|closed\|next_0…3>@<1\|2\|3>` | 鼠标手套，1/2/3 倍；热点照原型 `HOTSPOT` | 17×24 等 |
| `ing_<a\|b\|d\|f\|k>[_hover\|_off]` | 五种材料瓶：常态 / 拖动中 / 不可用 | 20×38 |
| `cell_<键>`、`big_<键>` | 份数格（1–10 份）和 11–20 份叠上的窄条 | 8×17 |
| `ice`、`age` | 加冰、陈化开关 | 33×57 |
| `shaker`、`shaker_hover`、`shaker_shake` | 摇酒器：常态 / 拖材料悬停 / 摇动中 | 72×68 |
| `pulse_<键>` | 加料光圈 | 72×68 |
| `slot`、`slot_out` | 栏位 1 按钮 / 不可用（闲聊时所有按钮也是它） | 71×25 |
| `reset[_hover]`、`mix_yes[_hover]`、`mix_no[_hover]` | 重来；调制 / 停止 / 上酒（字另画），no=不能按 | 71×25 |
| `gauge`、`gauge_on`、`gauge_big` | 份数槽和里面的格 | 70×17、10×5 |
| `success`、`fail` | 停摇后飘起的「成功 / 失败」 | 59×12、102×15 |
| `drink_<id>` | 成品饮品，id 同原型 `data.ts` 的 `DRINKS`；瓶装 `abs`、`rum`、`tea`、`fed` 也放进 35×53、原点 (17,26)；`drink_glitch` 是故障瓶 | 35×53 |
| `recipe_bg`、`recipe_intro`、`recipe_1…24`、`arrow` | 配方书蓝底窗、首页、24 张中文配方卡（页号同 `DRINKS` 的 `page`）、翻页箭头 | 420×252、315×214、24×24 |
| `juke_frame`、`juke_startup`、`juke_slot_<blue\|red\|yellow>`、`juke_ready_<red\|green>`、`juke_preview_0…3` | 点唱机选曲界面 | |
| `juke_small_<paused\|playing>`、`juke_<shuffle\|loop\|back\|next>` | 小播放器底板和按钮高亮（高亮已补成整块 188×63） | 188×63 |
