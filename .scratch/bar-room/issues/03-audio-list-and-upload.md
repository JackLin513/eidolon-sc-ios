# 03: 曲目表和 `eidolon bar upload`

**What to build:** 原版的曲目和音效能放进立绘存储桶的 `bar/` 前缀，浏览器从那里读。音频不进仓库，进仓库的只有一份清单；上传是部署者在本机跑的一次性命令。这是这份规格唯一的后端改动。

- **曲目表和音效清单** `characters/bar_audio.json`（规格「点唱机」第一条）：
  - 曲目 59 首，每首有编号、原版文件名、显示名（原版 `jukebox_list` 的英文缩写名），顺序照原版；
  - 默认的 12 首，就是原型里那 12 首（从 Every Day is Night、Dusk、Last Call 开始，不放和剧情、结局绑定的）；
  - 音效 16 个，每个有名字和原版文件名（调研笔记 5.2 节，含 `jukeselect`、`jukepick`、`jukechange`、`mouse_hover`、`prompt`、`door`）。
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

**Status:** done

- [x] JSON 有一条 vitest 守住：59 首编号唯一、每首都有显示名、默认 12 首都在表里、音效 16 个且名字唯一。
- [x] 测试照 `test_stand_upload.py` 的假存储桶：清单里的都传到对的键；已有且 MD5 相同的跳过，不同的重传；缺的文件报出来、别的照传；manifest 最后写，只列桶里有的；缓存头对。
- [x] 命令读仓库里的 JSON，不另抄一份清单。
- [x] `docs/deploy.md` 写了上传这一步和下线的办法。
- [x] 没有往线上存储桶传任何东西。pyright、ruff 通过；提交前跑 affected-tests。
- [x] 收尾：Comments 写下存储桶里的键名和 manifest 的形状，给票 07。

## Comments

### 实现说明（票 03）

- `characters/bar_audio.json`：`tracks`（59 首，照原版点唱机的顺序，每首 `id`、`file`、`title`）、`default_playlist`（12 个 `id`）、`sfx`（16 个，每个 `name`、`file`）。由原型分支的 `SONGS`、`DEFAULT_PLAYLIST`、`AUDIO` 生成，生成时核对过每个文件在本机提取目录里都有。vitest 在 `frontend/src/lib/barAudio.test.ts`。
- 后端新模块 `eidolon.bar_upload`：`bar_audio_path`（角色配置旁边）、`load_bar_audio`、`upload_bar_audio(audio_dir, catalog, bucket)`；命令 `eidolon bar upload <audio 目录> [--characters]`，退出码 1 配置出错、2 存储桶出错（不写 manifest）、3 有文件找不到（其余照传、manifest 照写）。测试在 `backend/tests/test_bar_upload.py`，借用 `test_stand_upload.py` 的 `FakeBucket`。
- `docs/deploy.md`：存储桶结构表加一行，新一节「酒吧的音频」（命令、退出码、下线），原有「招呼 → 下线」那段的一键下线也把酒吧的音频算进去。ADR-0003 的 2026-10-26 修订已经写了音频清空存储桶就下线，没再改。
- 判断：
  - **编号**取原版的声音编号（文件名前三位，如 Every Day is Night 是 22），不是点唱机里的位置：调研笔记说 `fullplaylist` 就是声音编号，以后改顺序也不动键名。
  - **音效是 16 个**：规格和这张票原来写 15，是按调研笔记 5.2 节表格的行数数的（`jukechange`、`jukepick` 在同一行），而规格点名要这两个。已把规格和这张票的「15」改成 16。名字是文件名去掉编号前缀。
  - 默认 12 首照原型（第 12 首是 Heart of the City，调研笔记的表里第 12 首是 Good for Health…，以原型为准）。
  - manifest 每次运行都重写（便宜，也保证和桶里一致）。
  - 上传循环和 `stand_upload._upload_all` 的写法相近（审查提到可以抽共用件）；两处的键、缓存头、Content-Type 和缺文件的处理都不同，暂不抽。
- 实现时没有往线上存储桶传东西。关票后用户同意，2026-10-26 在本机跑了一次：上传 75 个文件（170.3 MB），线上 `bar/manifest.json` 列 59 首、16 个音效，`no-cache`、带 CORS；抽查的曲目和音效是 `audio/ogg`。
