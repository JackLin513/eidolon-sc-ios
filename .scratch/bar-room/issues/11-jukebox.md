# 11: 点唱机

**What to build:** 每次进酒吧先过点唱机的选曲界面，上次的 12 首已经填好，Ready! 到店门口；店里点侧边菜单的「点唱机」打开小播放器换曲目。选择和播放器状态只存在这台设备上。

- **`lib/barJukebox`**：
  - 默认 12 首，取自清单。
  - 存取：选的 12 首和播放器状态（暂停、随机、单曲循环）存在这台设备的 localStorage，按用户分开，照 `lib/seenOnDevice` 的存法（读不出、存不进去时这次页面里记着）。读不懂的（编号不在表里、不是 12 个）用默认的。不存服务器，不进数据包。
  - 点曲名放进第一个空槽（可以重复），点两个槽对调，清掉一个；12 个槽满了 Ready! 才可用。
  - 上一首、下一首、随机、单曲循环，随机和单曲循环互斥；暂停记住。
  - 没有可用的音频时整块不可用。
- **选曲界面**照原型：
  - 从上往下擦出，「JUKEBOX 3」横向长出来；标题框写「请选择一首曲子」。
  - 左边 5 首一页，共 12 页，页码照实写 /12。电脑上右键清掉一个槽，手机上长按右边的槽清掉一个。
  - 说明文字电脑和手机各一句。手机那句：「长按左侧曲名试听，长按右侧曲目移除，点两首曲目可替换顺序。」
  - 槽一进来就填好了，所以 Ready! 一进来就是绿的。点 Ready! 只存下选择、到店门口，不放音乐，试听停掉。
- **试听**：电脑上悬停在曲名上 2.5 秒试听，移开就停。手机上长按左边的曲名试听（等待动画同电脑），松手接着放，点任何地方或长按另一首就停。只下载正在试听的那一首。
- **放**：进门从选好的第 1 首放起，替换票 07 放的默认 12 首。暂停着的，下次进来也不放。
- **小播放器**：侧边菜单下排「点唱机」点了开关，开着时那一格是橙黄的。播放器在右上角，盖在 logo 上：上一首、暂停、下一首、随机、单曲循环，曲名白字带灰影。
- **没有音频时**：「点唱机」是灰的、点不开，也跳过选曲界面。
- 不加音量开关。

见规格「点唱机」。

**Blocked by:** 07（曲目怎么放；店门口在 06）

**Status:** done

- [x] `lib/barJukebox`（vitest）：默认 12 首；存取（读不懂的回默认、按用户分开）；放进第一个空槽、对调、清掉、满了 Ready!；下一首、上一首、随机、单曲循环互斥；暂停记住；没有可用音频时不可用。
- [x] Playwright（存储桶请求拦到本机音频）：进来是选曲界面，槽已经填好；放进、对调、右键清掉、Ready!；悬停满 2.5 秒才请求试听的那一首，移开就停；手机上下文里长按试听、长按清掉；进门放的是选的第 1 首；小播放器各个按钮；暂停后刷新再进不放；manifest 404 时直接到店门口，「点唱机」是灰的。截图给用户看。
- [x] 前端 typecheck、vitest 通过。
- [x] 收尾：Comments 写下怎么打开选曲界面、怎么换掉侧边菜单「点唱机」那一格，给票 12。

## Comments

### 票 03 交接

- 清单：`characters/bar_audio.json`，形如 `{"tracks": [{"id": 22, "file": "022_every_day_is_night.ogg", "title": "Every Day is Night"}, …], "default_playlist": [22, 21, 38, …], "sfx": [{"name": "door", "file": "095_door.ogg"}, …]}`。曲目的 `id` 是原版的声音编号，不是在点唱机里的位置；`tracks` 的顺序才是点唱机的顺序。音效 16 个，名字是文件名去掉编号前缀：`addingredient`、`iceadd`、`ageadd`、`mixdone`、`glassserve`、`buttonclick`、`buttonnoclick`、`bleep_high`、`bleep_low`、`boot_up`、`jukeselect`、`jukechange`、`jukepick`、`mouse_hover`、`prompt`、`door`。
- 存储桶（`EIDOLON_STAND_ASSETS_URL` 下）的键：曲目 `bar/music/<id>.ogg`，音效 `bar/sfx/<name>.ogg`，都是 `audio/ogg`、长期缓存；`bar/manifest.json` 是 `{"tracks": [id…], "sfx": [name…]}`（按清单的顺序，只列桶里有的），`no-cache`。
- 本机 `.env` 的存储桶是线上的，2026-10-26 已经传好了 `bar/`（59 首、16 个音效都在）；验收时仍然把 `bar/*` 请求拦到本机提取目录（`E:\Download\others\VA11_extract\audio`，文件名见清单的 `file`），或给一份假 manifest。

### 票 11 交接

- 来自票 05：侧边菜单下排「点唱机」(445,312) 那一格加进 `components/play/bar/BarScreen.tsx` 的 `SideMenu`（现在只有「离开」），没有悬停效果；像素字、`HitArea` 见票 05 的「给票 06–12」。

### 票 07 交接

- 曲目都在 `components/play/bar/useBarSound.ts`：一个 `new Audio()`（`music.current`），`start()` 在进门那一下里调，等 manifest 读完后放 `available.current.playlist[0]`；`ended` 时用 `nextTrack(available.current.playlist, 当前)` 放下一首。这一张的曲单是 `availableAudio` 给的默认 12 首（`playlist`），`tracks` 是桶里有的全部曲目（照点唱机的顺序），选曲界面用它。
- 要加的：
  - 曲单换成本机存的选择：让 `start` 或一个新的 `setPlaylist` 接曲单，`ended` 读它；单曲循环、随机在 `ended` 里分（`nextTrack` 旁边加纯函数，测在 `lib/barJukebox`）；暂停、上一首、下一首直接操作那个 `<audio>`。
  - 「没有音频」：hook 现在不往外给状态（审查时删了没人用的那个）。选曲界面要分「manifest 还在读」和「没有音频」，加一个 `audio: BarAudio | null`（null 是还在读），在 manifest 的 `then` 里 set；读不到时是全空的 `BarAudio`。
  - 试听：规格说曲目和试听共用一个 `<audio>`。选曲界面在进门之前，那时 `AudioContext` 还没建，但 `<audio>` 的试听是悬停 / 长按触发的，浏览器要有过点击才放行；电脑上悬停之前没点过的话放不出来，要验一下。

### 票 10 交接

- 结束卡上「再营业」（`useBarVisit.again`）只响 `door`，不调 `sound.start()`：曲目接着放是靠这个。点唱机接管播放以后，再营业时同样不能从第 1 首重放。
- 结束卡盖着整个画面（`BarEndCard` 的遮罩会挡住侧边菜单），点唱机按钮在结束卡出着时点不到。

### 实现说明（票 11）

- `lib/barJukebox`（新）：`defaultSlots`、`pickTrack`、`swapSlots`、`clearSlot`、`isReady`；`jukeboxPages`、`jukeboxPage`（5 首一页，页数照桶里的曲目算）；`hasJukebox(audio)`；播放器按**槽的位置**走（可以重复，按编号找会错）：`slotAfter`（放完接哪个）、`nextSlot`、`previousSlot`、`toggleMode`。随机和单曲循环是一个 `mode: "order" | "shuffle" | "loop"`，所以天然互斥；随机总是换一个别的槽。存法 `storedJukebox(userId, audio)` / `keepJukebox`，键 `eidolon.barJukebox.<用户 ID>`，值 `{ slots, isPaused, mode }`，每项各自校验，读不懂的那项用默认；这次页面里记着的先读。
- `lib/barAudio`：删了 `nextTrack`（按编号找下一首，曲单有重复时会错），换成上面的按位置。
- `useBarSound`：不再管曲目，多给一个 `audio: BarAudio | null`（null 是 manifest 还在读，读不到是空的）。`start()` 只建 `AudioContext`；这一页被点过（`navigator.userActivation.hasBeenActive`）时第一次放音效也会建，所以选曲界面上的音效（悬停、放进、对调、boot_up）在进门前就响。
- `useBarJukebox`（新）：曲目和试听共用的一个 `<audio>`、选择、小播放器。`start()` 在进门那一下里调（`BarSubpage` 把它和 `sound.start()` 合成一个交给 `useBarVisit`），开始过就不动，所以「再营业」、410 回店门口再进门都不从头放；暂停着的不放。
- `BarJukebox.tsx`（新）：`BarJukeboxSetup`（选曲界面）、`BarJukeboxPlayer`（小播放器），照原型 `jukebox.tsx`。音效照原型：悬停 `mouse_hover`、放进 `jukeselect`、选中和翻页 `jukepick`、对调和翻到头 `jukechange`、清掉 `prompt`、Ready! 和打开小播放器 `mixdone`、收起和点不了的 `buttonnoclick`、小播放器按钮 `buttonclick`。
- `SideMenu` 多一个 `jukebox: JukeboxCell`（`{ state: "open" | "closed" | "none", onToggle } | null`），`HitArea` 多一个 `pressed`（读屏的开关状态）。
- 判断：
  - 「点唱机」那一格和小播放器只在店里（`visit`、`next`）出，店门口不出：店门口整张是霓虹招牌，小播放器盖在上面不像样，进门前也没在放。
  - 手机长按曲名：按下 0.55 秒认作长按（这时才出等待动画、松手不算点了曲名），从按下算满 2.5 秒放；没满就松手不放。长按右边的槽 0.55 秒清掉。手机长按会弹 `contextmenu`，长按自己会清，那一下不再清。
  - 电脑说明照手机那句的样子写：「悬停在曲名上试听，右键点击右侧曲目移除，点两首曲目可替换顺序。」；粉字那行「点击左侧的曲名来添加曲目。」两边都有（原型）。
  - manifest 在读、或者有曲目但还不知道是谁时，盖一层黑的，免得店门口闪一下又换成选曲界面。
  - 试听不淡出，移开立刻停（票里写「移开就停」；原型是淡出）。
- 验收（本地构建版、Playwright，存储桶的 `bar/*` 拦到本机提取目录）37 项全过（审查后补了「试听过以后一首完了照样接下一首」）：填好、右键清掉、放进、对调、页码 2/12、悬停 2 秒不请求、满 2.5 秒只请求那一首、移开就停、Ready! 存下不放、进门放选的第 1 首、上一首 / 下一首 / 随机 / 单曲循环互斥 / 暂停、刷新后槽和模式记着、暂停着进来不放、manifest 404 直接到店门口且「点唱机」灰；手机上下文（CDP 触摸）长按 2.5 秒试听、松手接着放、长按不算点、点别处停、长按槽清掉。
- 留给真机：整页直接打开 `/play/bar`（没点过页面）时悬停试听放不放得出来。Playwright 的 Chromium 怎么都放行，验不出来；放不出来时什么都不提示，页面上点过一下以后就正常。

### 审查（票 11）

修了的：试听先建了 `<audio>` 时没挂 `ended`，进门后放完第 1 首就停（`useBarJukebox` 改成一处 `audioElement()` 建、挂监听）；选曲界面的说明跟着指针类型变（`BarScreen` 的 `usePointer` 导出来用）；小播放器的按钮改用 `HitArea`；停 `<audio>` 的三行收成 `silence()`；`halo`、`flash` 改函数式更新；改名（`at` → `playing`、计时的 `later` → `after`）；测试删掉走同一条路的几行、`unstubAllGlobals`。

只报告、没改（判断题）：

- 标题「请选择一首曲子」：`GLOSSARY.md` 里「曲子」算「歌曲」一类要避开的词，但票和规格都写明了这句，照票写。要改的话改成「请选择曲目」一类。
- 电脑的说明是自己拟的：「悬停在曲名上试听，右键点击右侧曲目移除，点两首曲目可替换顺序。」
- 店门口不画「点唱机」那一格：验收项「manifest 404 时直接到店门口，『点唱机』是灰的」在店里成立，店门口没有这一格。
- 默认曲单有几首不在桶里时，默认的槽不满，Ready! 一进来不是绿的（线上 59 首都在，碰不到）。
- 没给曲目设音量（原型是 0.3），跟系统音量走，会比原型响。
- `AudioContext` 在页面被点过时就建（为了选曲界面的音效），规格写的是进门时建。
- `account` 一直读不到时，有音频的话黑层一直盖着（导航外壳里 `account` 总会到）。
- 「点唱机」格子的状态（开 / 关 / 灰）和开关音效在 `BarSubpage` 里算，可以挪进 `useBarJukebox`。

### 验收（票 11）

- 2026-10-27 用户在本地构建版上看过，没问题；审查报告里的判断题（标题「请选择一首曲子」、电脑的说明、店门口不画「点唱机」、不设音量）照现在的留着。
- 还没在真机上看：手机长按试听、长按清掉的手感；整页直接打开 `/play/bar`、没点过页面时悬停试听出不出声。

