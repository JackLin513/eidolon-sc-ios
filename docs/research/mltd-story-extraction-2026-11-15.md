# 从 MLTD 原包提取剧情文本 / 语音 / 剧情动作（2026-11-15）

目标：不依赖 NAS、不依赖网络，直接从 PlayCover 里装的 `ミリシタ` 游戏数据取出
「剧情台词 + 语音 + 剧本里写的姿势」，配到现有 3D 立绘上播放。
本文件记录可复现的事实与算法；一次性脚本放在 `~/mltd-work/`（不进仓库，因为输入是
本机游戏容器）。产出物经 `tools/build_story_demo.py` 变成 App 可读的剧情包。

## 1. 数据在哪

- 游戏容器：`~/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents/`
  （约 9.4 GB）
  - `Cache00/` 20,106 个文件，全部是 `UnityFS` bundle，文件名是 64 位 hex（不是
    manifest 的 sha1），所以要按**对象名**反查而不是按文件名。
  - `ADX2/Commu/2_job/text/job_text_<idol>.acb`：52 个 CRI ACB（内含 AFS2/AWB）。
  - `ab.json`：1,924 条下载记录（只覆盖 .acb）。
  - **没有** masterdata / 数据库落盘；文本表不在这里。
- Il2CPP 二进制：`.../io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0310.app/Frameworks/UnityFramework.framework/UnityFramework`
  （165 MB，arm64 dylib），元数据 `Data/Managed/Metadata/global-metadata.dat`（34 MB）。
- 本机索引（一次性生成，供后续查询）：
  - `~/mltd-work/cache-names.tsv`：`relpath\tassetname`，20,113 个 bundle 的对象名。
  - `~/mltd-work/cache-index.json`、`cache_anims.jsonl`：剧情/动画相关子集。

## 2. 剧情文本：`_jp.gtx` 解密（关键）

剧情剧本里只有文本 id（`actor_text`），日文原文在单独的 `*_jp.gtx` 表里，
该文件是 **AES-192-CBC + PKCS7**，参数来自游戏代码：

| 项 | 值 | 来源 |
| --- | --- | --- |
| 口令 | `Millicon` | `MilliconSystem..cctor`，字符串字面量 `0x97F6068` |
| Salt | `DAISUL___` 的 UTF-8 字节 | 同函数，`0x97E9B78` |
| KDF | PBKDF2-HMAC-SHA1，迭代 1000 | `Rfc2898DeriveBytes`，`set_IterationCount(0x3e8)` |
| 密钥 | 派生 40 字节的前 24 字节 | `RijndaelManaged.KeySize = 192`（`0x84268A0`） |
| IV | 派生 40 字节的后 16 字节（同一个派生流继续 `GetBytes(16)`） | `BlockSize = 128` |
| 模式 | CBC，解整个文件（无文件头偏移） | `DecryptText(byte[]) → Dictionary<string,string>` |

```python
dk = hashlib.pbkdf2_hmac("sha1", b"Millicon", b"DAISUL___", 1000, 40)
key, iv = dk[:24], dk[24:40]
plain = AES.new(key, AES.MODE_CBC, iv).decrypt(open(path, "rb").read())
plain = unpad(plain, 16).decode("utf-8")
```

明文格式是 `key^value|key^value|…`，value 内部可以含换行，例如：

```
job_story_001har_9000_situation^グラビアのお仕事　休憩中|job_story_001har_9000_place^お屋敷|job_story_001har_9001_p^（アイドル雑誌『ViDaVo!』のグラビア撮影。…）
```

> 之前误以为「前 16 字节跨文件相同 = 固定 IV」：其实是明文都以 `job_story_<id>_` 开头，
> CBC 下首块自然相同。

工具链：Il2CppDumper v6.7.46（net7，`dotnet Il2CppDumper.dll <UnityFramework> <global-metadata.dat> <out>`）
拿 `dump.cs` / `stringliteral.json`；Mach-O 的 `__TEXT vmaddr = fileoff = 0`，
所以 il2cpp RVA 就是文件偏移，可直接 `xcrun llvm-objdump --disassemble --arch=arm64
--start-address=0x31A2244 --stop-address=0x31A2600 <UnityFramework>` 读 `.cctor`。
REA 的 `inspect_il2cpp_metadata` 对这个包不可用（`Mach-O chained fixups are not decoded`）。

规模：906 个 gtx 表 → 1,186 个文件、205,742 条 key→日文（`out/story-extract/text.json`）。

## 3. 剧本结构（`job_story_*.unity3d` / `job_text_*.unity3d` 里的 TextAsset）

`utf-8-sig`（9000 系带 BOM），JSON：

```
{"header": {"title": "job_story_001har_3000"},
 "datas": {"CutRecord": [...], "Scenario": [...]}}
```

每行 `{seq_id, label, command, arg1..arg20}`。`Scenario` 给出 cut 播放顺序，
`CutRecord` 是行内指令。`arg1` 一律是 **cut 标签**（不是 id）：

| 命令 | 字段 |
| --- | --- |
| `actor_text` | `arg2` 起始帧、`arg3` 结束帧、`arg5` 说话人（偶像 id 或 `p`＝制作人/旁白）、`arg6` 文本 id、`arg7` 文本表名 |
| `actor_pose` | `arg5` 姿势名（`p01/p05/…/a12/a14_p15/a16_p17/p18_p`） |
| `actor_facial` | `arg5` facialMenu 索引（1..26） |
| `actor_yes_no` | `arg5` `yes`/`no` + 帧区间 |
| `actor_cheek` | `arg5` 腮红等级 0/1/2 |
| 其它 | `create_cut` / `play_cut` / `actor_eye_blink` / `actor_eye_direction` / `actor_load_character` / `end_theater` |

**帧率 60**（line 9002 `end=643` ↔ 语音 10.73 s → 59.9 fps）。
组装结果：933 个故事、7,501 行台词（`out/story-extract/scenes.json`）。

## 4. 语音

`job_story_<id>_<n>.acb.unity3d` 里的 TextAsset 是完整 CRI ACB（`@UTF` 头 + 内嵌 AFS2），
取出来用 `vgmstream-cli` 解码即可：

```bash
vgmstream-cli -I -s 0 story.acb      # JSON：streamInfo {index, name, total}
vgmstream-cli -i -s 3 -o out.wav story.acb
```

**子流名字就是文本 id**（`job_story_001har_3001_001har`），所以可以精确对齐
`actor_text` 与语音，不需要猜。524 个故事、全部子流解成 `aac 48k 单声道 m4a`。

## 5. 剧情动作（姿势）与现有 3D 立绘的映射

- 主数据 `~/mltd-work/chara_commu_pose_set.json`：
  `sets.means = [SetName, Category, p02, p03, …]`，`sets.sets[].vals` 是**每角色每姿势
  的字母变体**（001har：`p05 → d`、`p08 → b`…），`assigns` 把角色 id 指到某个 set。
- 缓存里的 clip 名：`com_<variant>_<两位编号+字母>_<action>`，
  variant ∈ `cut|col|pas|sit`，action ∈ `act|yes|noo|str|lop|end|swt`。
- **语义**（重要）：`lop` 是**该姿势的循环**（46 帧 / 1.5 s），`str` 是进入（31 帧），
  `end` 是离开，`yes/noo` 是姿势内点头/摇头，`act` 只有一部分姿势有（160/377）。
  所以剧情播放应该用 `<pose>_lop` 作为姿势循环，而不是一味找 `act`。
- 解析规则：`p05` → 编号 `05` + 角色字母 `d` → `cut_05d`；`a12` → `12a`；
  `p01` → 兜底 `01z`；`p11/p13/p15/p17` 主数据没有，用字母 `a` 试（都存在）；
  `a16_p17` / `a10_p11` 取前半段；`p18_*` 目前解析不出（18 系是 `18y/18a…` 特殊集合），
  回退到上一姿势。
- 已把缓存里的姿势导成 1,539 个 `eidolon.motion/1` clip（`~/mltd-work/out/poses/`，35 MB），
  剧情包再按需转成 flat TSV（30 fps，46 帧 ≈ 287 KB/clip）。

## 6. 产出与 App 侧

`tools/build_story_demo.py` 选故事 → `build/Unity3DContent/stories/`：

```
index.json                     # {version, format: "eidolon.story/1", fps: 60, stories: [...]}
<story>/story.json             # 每行台词 + poses/faces/gestures/cheeks 事件（ms 时间轴）
<story>/audio/<textId>.m4a
motions/<clip>.tsv             # 共享的姿势循环（30 fps flat）
```

App 侧 `EidolonIOS/Features/Stand/StoryTheaterView.swift`（DEBUG）用 `AVAudioPlayer`
逐行播语音、30 Hz 定时器按脚本毫秒派发姿势/表情/手势/腮红，Unity 端通过
`PlayPose(path)` 加载剧情姿势并 0.25 s 交叉淡入。启动：`EIDOLON_STORY=<storyId>`。

## 7. 已知限制

- 说话人 `p`（制作人/旁白）没有语音，只有字幕。
- facialMenu 里 8/9/12/23 等编号不在 7 种情绪映射内，被丢弃。
- `p18_*` 姿势没有解析出来，回落。
- 文本只有日文，中文翻译不在游戏包里（现有内容包的中文是另一条线）。
- 语音整包约 240 MB，目前只解了 demo 用的故事。
