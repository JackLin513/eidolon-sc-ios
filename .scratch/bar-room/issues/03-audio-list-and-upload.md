# 03: 曲目表和 `eidolon bar upload`

**What to build:** 原版的曲目和音效能放进立绘存储桶的 `bar/` 前缀，浏览器从那里读。音频不进仓库，进仓库的只有一份清单；上传是部署者在本机跑的一次性命令。这是这份规格唯一的后端改动。

- **曲目表和音效清单** `characters/bar_audio.json`（规格「点唱机」第一条）：
  - 曲目 59 首，每首有编号、原版文件名、显示名（原版 `jukebox_list` 的英文缩写名），顺序照原版；
  - 默认的 12 首，就是原型里那 12 首（从 Every Day is Night、Dusk、Last Call 开始，不放和剧情、结局绑定的）；
  - 音效 15 个，每个有名字和原版文件名（调研笔记 5.2 节，含 `jukeselect`、`jukepick`、`jukechange`、`mouse_hover`、`prompt`、`door`）。
  - 来源是原型分支的数据和点唱机代码，加调研笔记。前端（票 07、11）和这个命令共用这一份。
- **命令**照 `eidolon stand upload`、`eidolon greeting upload` 的写法：
  - 参数是本机原版提取目录的 `audio/`；曲目传到 `bar/music/<编号>.ogg`，音效传到 `bar/sfx/<名字>.ogg`；
  - 存储桶里已经有、ETag 等于文件 MD5 的跳过；找不到的文件报出来，别的照传；
  - 最后写 `bar/manifest.json`，只列真上传成功的和本来就在的，所以浏览器不会读到列了却还没上传的文件；
  - 缓存头：曲目和音效长期缓存，manifest 每次检查；
  - `eidolon` 的用法说明加一行。
- **`docs/deploy.md`**：部署前在本机跑一次（命令、参数、要有本机的原版提取目录）；它不在每周的 `stand-sync` 里。清空 `bar/` 前缀就把音频下线了，酒吧照常静音（ADR-0003 修订）。
- 本机 `.env` 配的就是线上存储桶：不要自己往里传，要真跑先问用户。

见规格「`eidolon bar upload`」「声音和存储桶」。

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] JSON 有一条 vitest 守住：59 首编号唯一、每首都有显示名、默认 12 首都在表里、音效 15 个且名字唯一。
- [ ] 测试照 `test_stand_upload.py` 的假存储桶：清单里的都传到对的键；已有且 MD5 相同的跳过，不同的重传；缺的文件报出来、别的照传；manifest 最后写，只列桶里有的；缓存头对。
- [ ] 命令读仓库里的 JSON，不另抄一份清单。
- [ ] `docs/deploy.md` 写了上传这一步和下线的办法。
- [ ] 没有往线上存储桶传任何东西。pyright、ruff 通过；提交前跑 affected-tests。
- [ ] 收尾：Comments 写下存储桶里的键名和 manifest 的形状，给票 07。
