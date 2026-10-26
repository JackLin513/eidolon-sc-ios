# 07: 声音

**What to build:** 店里有声音：进门响门声，从默认 12 首的第 1 首放起，一首接一首；她和制作人说话时有打字音效。存储桶里没有音频、或者浏览器放不了 Ogg 时，静音照常玩。选曲界面和小播放器是票 11；调酒台、配方书的音效在各自的票里接。

- **清单**：前端构建时读 `characters/bar_audio.json`。照落地页读 `characters/` 的先例，Docker 构建也要拿得到。
- **manifest**：
  - 进酒吧时读一次立绘存储桶（`EIDOLON_STAND_ASSETS_URL`）的 `bar/manifest.json`，清单和 manifest 里都有的才算有。
  - 读不到、或者放不了 Ogg（Safari 18.4 以前）时当作没有音频，不提示。
  - 纯函数：给清单、manifest 和能不能放 Ogg，返回哪些曲目和音效能用。
- **音效**：
  - 第一次点击（进门那一下）时建 `AudioContext`，音效解码成缓冲区；给后面的票留一个「放这个音效」的口子。
  - 打字音效：她用 0.11 秒的 `bleep_high`，制作人用 0.16 秒的 `bleep_low`。打字期间无缝循环（用 Web Audio 的循环缓冲；HTMLAudio 的 loop 有空隙），打完立刻停。
  - 进门响 `door`。
- **曲目**：
  - 只用一个 `<audio>`，只下载正在放的那一首。
  - 进门那一下从第 1 首放起，这一下点击让浏览器放行播放。一首完了放下一首，12 首完了从头。
  - 这一张放默认的 12 首、只按顺序放；票 11 换成本机存的选择，再加随机和单曲循环。
  - 「离开」才停；营业中不停，以后的结束卡、「再营业」也不停。
- 不加音量开关，不放进 Service Worker 缓存，靠浏览器的 HTTP 缓存。CSP 应该已经允许这个地址，核对一下。

见规格「声音和存储桶」，以及「文本框和打字」里打字音效那一条。

**Blocked by:** 03（曲目表和存储桶里的键名）、06（店门口和文本框）

**Status:** ready-for-agent

- [ ] 纯函数（vitest）：清单和 manifest 的交集；没有 manifest、放不了 Ogg 时什么都没有；下一首，12 首完了从头。
- [ ] Playwright：把存储桶的 `bar/*` 请求拦到本机原版提取目录的音频，或给一份假 manifest。进门后只请求了 `door` 和第 1 首；第 1 首放完才请求第 2 首；打字时打字音效在放（查 `AudioContext` 或打桩）；manifest 404 时没有任何音频请求，照常走到点单。不往线上存储桶传。
- [ ] 前端 typecheck、vitest 通过。
- [ ] 收尾：Comments 写下放音效和控制曲目的口子，给票 08、09、11、12。

## Comments

### 票 03 交接

- 清单：`characters/bar_audio.json`，形如 `{"tracks": [{"id": 22, "file": "022_every_day_is_night.ogg", "title": "Every Day is Night"}, …], "default_playlist": [22, 21, 38, …], "sfx": [{"name": "door", "file": "095_door.ogg"}, …]}`。曲目的 `id` 是原版的声音编号，不是在点唱机里的位置；`tracks` 的顺序才是点唱机的顺序。音效 16 个，名字是文件名去掉编号前缀：`addingredient`、`iceadd`、`ageadd`、`mixdone`、`glassserve`、`buttonclick`、`buttonnoclick`、`bleep_high`、`bleep_low`、`boot_up`、`jukeselect`、`jukechange`、`jukepick`、`mouse_hover`、`prompt`、`door`。
- 存储桶（`EIDOLON_STAND_ASSETS_URL` 下）的键：曲目 `bar/music/<id>.ogg`，音效 `bar/sfx/<name>.ogg`，都是 `audio/ogg`、长期缓存；`bar/manifest.json` 是 `{"tracks": [id…], "sfx": [name…]}`（按清单的顺序，只列桶里有的），`no-cache`。
- 本机 `.env` 的存储桶是线上的，里面还没有 `bar/`：验收时把 `bar/*` 请求拦到本机提取目录（`E:\Download\others\VA11_extract\audio`，文件名见清单的 `file`），或给一份假 manifest。
