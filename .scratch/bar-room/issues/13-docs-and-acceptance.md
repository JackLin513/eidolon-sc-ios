# 13: 收尾：文档和验收

**What to build:** 对外的文档写齐，整份规格在本地构建版上验一遍，列出留给用户的真机验收和部署前要做的事。

- **`DESIGN.md`** 新一节「酒吧」，照最后做出来的写：
  - 像落地页那样另立视觉世界（ADR-0016），不用 shadcn 组件，也不用应用的色板和字体；
  - 原版画框、640×360，电脑整数倍、手机小数缩放；
  - 像素字、canvas 二值化、「缝合像素」12px；立绘像素化；
  - 她的名字用官方色，是这里唯一用到「她的颜色」的地方。
- **`LICENSING.md`**：照 Spine 那段的写法，写明 `frontend/public/bar/` 里的原版素材（含配方卡上的官方中文描述）和存储桶 `bar/` 前缀里的原版音频不在 AGPL 范围内，版权归 Sukeban Games；「缝合像素」字体照 OFL。
- **README 三语**：
  - 功能列表加一行，「🍸 **VA-283**：她来酒吧光顾，你照她的点单调饮品」一类；
  - 一张酒吧截图：电脑宽度，用截图脚本拍，开着点唱机、她在说话；
  - 「致谢」加 VA-11 HALL-A（Sukeban Games），写明画面致敬、用了原版素材；页脚加一句它的版权声明。
  - 中文先写，用 humanizer-zh 过一遍再删减；英文、日文照中文定稿翻。
- **隐私政策**：「光顾」规格加的「酒吧」那条补半句「点唱机的曲目选择和酒吧的设置只存在这台设备上」，改「最后更新」日期。教程看没看过不写。
- **GLOSSARY**：「酒吧」一节和实现对一遍，要补就调 `domain-modeling`。
- **验收**（`docs/agents/local-acceptance.md`）：
  - 照规格 Testing Decisions 的验收清单整份走一遍：一次两杯的光顾、出错和「再试一次」、重试清句子、三种结束卡、429 的店门口、410 回店门口；第一次进来的教程（含 Piano Man 分支、跳过、店门口重看）；选曲界面；没有 manifest 时跳过选曲；电脑 1280×720 和 1920×1080 的整数倍、手机横屏的小数倍、手机竖屏的提醒；通话中进酒吧通话条还在；关掉酒吧后没有卡、`/play/bar` 是 not-found；票 14 的侧边菜单四格、调酒时文本框里的备忘、设置框（音量、扫描线）、电脑上进出全屏。
  - 再接真后端和本机 `.env` 的对话模型，从选曲到结束卡走完一次光顾。
  - 截图给用户看。

见规格「视觉和文档（这一份的收尾块）」「Testing Decisions」的验收两条和 Further Notes 的「部署」。

**Blocked by:** 01–12、14

**Status:** ready-for-agent

- [ ] 四份文档改好，README 截图进仓库。
- [ ] 验收清单逐条过，每条的结果写进 Comments；接真后端走完一次光顾。
- [ ] 前端 `next build` 通过，CI 绿。
- [ ] Comments 列出合并前留给用户的真机验收：手机上拖材料；小数缩放下的像素字清不清楚；安卓「全屏横过来」能进全屏并锁成横屏，返回手势退出全屏以后侧边菜单的「全屏」能再进；手机上拖设置里的音量滑块；iPhone 竖屏提醒；听一遍默认 12 首；走一遍教程（含跳过和重看）。
- [ ] Comments 列出部署前的事（两份规格都合进 main 以后一起做）：手动备份；在本机跑一次 `eidolon bar upload` 传进线上存储桶（先问用户）；确认 `EIDOLON_BAR` 开着；公告草稿在对话里给，不写进票。

## Comments

### 票 14 交接

- 票 12 交接里「教程里备忘前的小字是「备忘」」那条作废了：备忘挪进了文本框，侧边菜单上没有备忘和小字了。README 截图拍到调酒时，文本框里是这一单的备忘。
- `DESIGN.md` 的「酒吧」一节顺带写上：侧边菜单照原版四格（设置、全屏、点唱机、离开）、调酒时文本框写第一人称的备忘、设置框是原版的图、扫描线默认关。
- 隐私政策那半句已经在上面改成「点唱机的曲目选择和酒吧的设置只存在这台设备上」。设置存在 `localStorage` 的 `eidolon.barSettings.<用户 ID>`。
- `frontend/public/bar/img/` 多了 `set_*` 一组（原版设置框、滑条、字图），LICENSING 里「`frontend/public/bar/` 的原版素材」已经包括它们。

### 票 13 交接

- 来自票 04：`frontend/scripts/bar-logo.png`（外框右上角的「VA-283」logo）不在 `frontend/public/bar/` 下，但含原版外框的像素（小字「Cyberpunk Bartender Action」和大字「VA-」照搬原版，「283」照原版字形手画）。LICENSING.md 写原版素材时把它一起列进非 AGPL 素材，注明是取自 Sukeban Games 原版外框的衍生图。
- 来自票 05：酒吧的颜色是自己的 hex（`components/play/bar/ink.ts` 的 `BAR_INK`，和 `bar.css`、inline style），不走 `frontend/AGENTS.md` 的「只用具名主题变量」。`DESIGN.md` 的「酒吧」一节要写明这个例外（像落地页那样另立视觉世界，颜色、字体都不用应用的），审查时提过。

### 票 12 交接

- 教程看没看过存在 `localStorage` 的 `eidolon.barTutorialSeen.<用户 ID>`（`lib/barTutorial`），按规格不写进隐私政策。整份验收要重走教程时，先清掉这个键（或整个 localStorage）。
- 票 12 的验收脚本的写法可以照搬：`/api/bar/visits*` 拦下记数；调酒用键盘（Q W E R T 加材料、A 加冰、空格调制 / 停止 / 上酒，Moonblast 要等满 5 秒）；框上的字从 `role="img"` 的 `aria-label` 读。选曲界面有约 1 秒的刷开动画，等 Ready! 出现再判断。
- 教程里备忘前的小字是「备忘」（`copy.bar.tutorialMemo`），用户还没确认；截图写 README 时如果拍到教程，留意这一点。

