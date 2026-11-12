# 全量迁移调研：`ディメンション凸ラバース!!`（T-Script / totsulover）

- 日期：2026-11-12
- 范围：`/Users/jacklin/Developer/IdeaProjects/Galgame support/ディメンション凸ラバース!!`（只读）、`Galgame support/totsulover_CHS_v1.1/`（新汉化组补丁，只读，见 §12）、本仓库 worktree `dsh-659b97a2-fcd2` 的 `EidolonCore`/`EidolonIOS` 现状接缝、Fish Audio 官方文档。
- 目的：把这部作品**全量**（角色 + 立绘 + CG/背景 + 文本 + 语音 + 世界数据）迁进 Eidolon 的 `kind=content` + `kind=stand` 双包形态，并给出可执行的阶段计划。
- 性质：**调研结论，不是 spec、不是 ADR、不是已实现设计**。落地仍要走 grill → spec → implement。
- 合规声明：本次调研**没有运行游戏**、没有绕过任何保护、没有把素材/译文/语音/密钥/UDID 写进本仓库。所有解析产物都在 `/tmp/eidolon-re-full/` 与 `/tmp/eidolon-re-chs/`。旧补丁（`.pswj`）只做了头部识别、未解码其内容；新补丁（CHS v1.1）的译文是**公开仓库里的明文 JSON**（CC BY-NC-SA 4.0），本节只做结构统计与 id 对齐验证，**未摘录任何译文句子**。

---

## 0. 摘要

| 维度 | 结论 |
|---|---|
| 引擎 | CRYSTALiA「T-Script System -DL」；exe = 脚本 VM + 文本表 + 存档；2D 层是同目录 `Pal.dll`（`Pal*` C API） |
| 归档 | `.pac` 明文索引（`PAC ` + count@8 + 索引@0x804 + 0x28/条 + 尾部 8 B）；**17 个归档、3.31 GB、30,555 条目全部可枚举** |
| 文本 | `TEXT.DAT` 明文 cp932，**70,111 条**（id 1..70111 连续），带 `<br>`、`<r…>` 注音、`<sNN>` 字号标记；**脚本里没有日文**，台词只能靠 id 关联 |
| 脚本 | `SCRIPT.SRC` 6,954,384 B，magic `Sv20`，代码段 0x334；**68 个原生命令**（id `0x20000`..`0x20043`）在 `sub_472480` 注册，文本命令是 `0x20013` → `sub_46DC50` |
| 场景点 | `POINT.DAT` = 11,104 个脚本偏移（8,786 个唯一，全部 4 字节对齐），是**恢复"幕/场景"边界的最佳锚点** |
| 图像 | 两种头：`GE `（完整图，type 3 = LZSS）与 `PGD3`（**带 (x,y,w,h) 的 XOR 差分补丁**，头部含 32 字节基图名 + 压缩尺寸）；**解码已跑通**（LZSS `sub_100C5820` + 分派 `sub_100C72E0`）：`ST01A_A010` 解出 19,662,856 B，12/12 抽样像素长度精确，补丁零像素 55.6–97.3% |
| 语音 | `voice.pac` **22,135 个真 Ogg，合计 24.55 小时**（平均 3.99 s，最长 23.4 s），按 `vo01..vo29/97/98/99` 分 29 个通道 |
| 特典 | 80 个 WAV（48 kHz / 单声道 / 24-bit，合计 5.1 分钟，4 角色各 20 条）+ 176 张壁纸 PNG |
| 汉化补丁（旧） | `.pswj` 自定义签名容器（UTF-16LE 头 `Package format made by …`，三份 + 三份 `.sign`）；LICENSE 明确**非商用 / 不得修改或衍生 / 不得逆向** → 不得作为译文或结构来源 |
| 汉化补丁（新，CHS v1.1） | 另一个组：DLL 内嵌 `RPCK` 覆盖层（486 条；补丁整包 275.7 MB）+ 明文 `STRINGS.JSON = {TEXT.DAT id → 中文}`；译文源仓库公开、**CC BY-NC-SA 4.0**、作者**允许做移植版**（须署名）→ 可作为中文文本来源（§12） |
| Eidolon 现状 | 已具备 `kind`/`franchise`/`engineFamily`/`contentSetID`/`characterKeys` 与 **`StaticStandManifest`（PNG-per-expression）**、`installStaticStand` 的 `contentSetID` 绑定；installer 已按 `expectedKind` 分流，但 `content` 仍强制 `episode_passages > 0` |
| 最大风险 | ~~"哪句话属于哪一幕、谁在说"~~ → **已由 CHS v1.1 的数据结构降到"可静态恢复"**：255 个脚本单元名是精确边界、说话人是紧邻台词的独立 id、译文键 = 文本 id − 1（差 1，2 万条规模 100% 可验）。剩下的真风险是 **"哪句话配哪条语音"**（voice id 不在 `TEXT.DAT` 里）+ 译文没有 `<br>` 的排版 |

---

## 1. 方法与证据等级

| 等级 | 含义 | 本文例子 |
|---|---|---|
| **实测** | 我在 `/tmp` 跑过解析，可复现 | `.pac` 索引自校验（`last == filesize-8`）、`TEXT.DAT` 70,111 条、Ogg granule 时长 24.55 h |
| **反编译** | IDA Hex-Rays 伪代码 + 地址，可复查 | `sub_472480` 命令注册、`sub_46DC50` 文本命令、`sub_100C5820` LZSS |
| **文件事实** | 直接读头部/版本资源/许可证 | `T-Script System -DL`、`Sv20`、CN 补丁 LICENSE |
| **推断** | 由事实推出、**未运行时验证** | `st01..st04` ↔ 四位女主、`POINT.DAT` 即"脚本点"表 |

地址约定：游戏 exe imagebase `0x400000`，`Pal.dll` imagebase `0x10000000`。

IDA 用法（headless，可复现）：

```sh
cp "…/totsulover_dl/totsulover_crack.exe" /tmp/eidolon-re-full/ida/game.exe
"/Applications/IDA Professional 9.5.app/Contents/MacOS/idat" \
  -A -c -S/tmp/eidolon-re-full/ida/game7.py /tmp/eidolon-re-full/ida/game.exe
# 脚本第一行必须 ida_auto.auto_wait()，否则 -S 在自动分析前执行
# IDA 9.5 只有 idat/ida（无 idat64）；ida_idaapi.get_inf_structure 已移除
```

原始 exe（`totsulover.exe`，1,410,560 B）是壳；`totsulover_crack.exe`（1,152,512 B）是**已脱壳镜像**，`.text` 0xc82bf。本报告所有 exe 地址都对应脱壳镜像。

---

## 2. 全量清单

### 2.1 引擎与目录

```
totsulover_dl/
  totsulover.exe                壳（.text 0x57a2，代码在 .data）
  totsulover_crack.exe          脱壳镜像（本文分析对象）
  dll/Pal.dll                   2D 引擎（370 导出，含 PGD/PNG/JPEG/zlib/Ogg）
  dll/{FX,RESOURCE,ogg,vorbis,vorbisfile}.dll
  *.pac                         17 个归档（见 2.2）
  SCRIPT.SRC                    6,954,384 B（与 data.pac 内同一文件）
  DimensionToTsuLovers_cn/      旧汉化补丁，仅作历史对照（见 2.10），不再使用
  movie/{LOGO,opening}.mpg      1.28 MB / 160.2 MB
  save/, save_cn/               空模板（868 + 560 个 0 长度/空记录）
  html_manual/playmanual.html   36 KB 说明书（无角色表）
../豪華版特典/                  417 MB：80 WAV + 176 PNG 壁纸
```

> 中文文本**只用** `Galgame support/totsulover_CHS_v1.1/`（Can/need，见 §12）。旧 `.pswj` 补丁只在 §2.10 / §4 / §12.6.4 作为对照出现，不进管线。

PE 版本资源：Company `CRYSTALiA`、Product `ディメンション凸ラバース!!`、FileVersion `1.17.0.0`、Comments **`T-Script System -DL`**。

### 2.2 归档 `.pac`（实测，全部 17 个）

布局：`"PAC "` + u32(0)@4 + **u32 count@8** + 0x10..0x803 零填充；`0x804 + i*0x28` = `char name[0x20]` + `u32 size` + `u32 offset`；数据区紧随索引；末尾 8 B 尾标记。自校验：`最后一条 offset+size == filesize-8`（17/17 通过）。

| 归档 | 字节 | 条目 | 内容 |
|---|---|---|---|
| `data.pac` | 10,104,358 | 160 | 139 `.ANI` + 14 `.MIX` + 6 `.DAT` + `SCRIPT.SRC` |
| `csv.pac` | 53,129 | 17 | 15 `.CSV` + `LIST_STAND.TXT` + `SYSTEM.INI` |
| `st.pac` | 369,258,716 | 2,732 | 立绘（49 个 stand 组，见 2.4） |
| `face.pac` | 26,440,973 | 1,244 | 头像/表情 |
| `ev.pac` | 331,094,834 | 714 | 事件 CG |
| `bk.pac` | 253,614,075 | 348 | 背景 |
| `etc.pac` | 393,970,627 | 425 | 403 `.PGD` + 20 `.JPG` + 2 `.MPG` |
| `em.pac` | 175,631,738 | 107 | 54 `.PGD` + **53 `.MPG`**（效果动画） |
| `battle.pac` | 278,438,485 | 305 | 战斗演出 |
| `system.pac` | 193,925,491 | 695 | 617 `.PGD` + 74 `.OGG` + 3 `.TGA` + 1 `.DAT` |
| `sd.pac` | 12,662,170 | 43 | SD 立绘 |
| `mask.pac` | 16,265,889 | 41 | 遮罩（全 `GE ` 头） |
| `tips.pac` | 10,772,832 | 256 | 用语集图 |
| `bgm.pac` | 64,752,367 | 34 | 全 Ogg |
| `se.pac` | 43,483,084 | 789 | 全 Ogg |
| `voice.pac` | **1,040,892,543** | **22,135** | 全 Ogg |
| `patch.pac` | 84,374,007 | 510 | 覆盖资源（389 `.PGD` + 116 `.OGG` + 4 `.JPG`） |

`data.pac` 内还有 `ARCHIVE.DAT`（287 B）——按模式列出要挂载的归档（`csv|tips|bgv|movie|bgm|mask|em|evx|ev|sd|etc|bk|se|system|face|voice|st|battle|patch|debug|test,…`），说明虚拟路径 `Script.src` 是经 `Pal.dll` 的 VFS 解析到具体 `.pac`。

### 2.3 角色

**立绘槽位 = 角色编号**：`STAND.CSV` 把 `st01..st20`（L 尺寸）一一对到 `vo01..vo20`，另有战斗 `st21..st25`、LL `st31..st35`、战斗 LL `st41..st45`（都回指 `vo01..vo05`）。所以**主线 5 人**有 LL/战斗差分，其余 15 人是配角。

语音通道（`voice.pac` 文件名 `VO<ch>_<4位序号>.OGG`）与实测时长：

| 通道 | 条目 | 时长 | 通道 | 条目 | 时长 |
|---|---|---|---|---|---|
| vo01 | 4,085 | 4.22 h | vo06 | 920 | 1.23 h |
| vo02 | 2,835 | 3.59 h | vo09 | 1,027 | 1.18 h |
| vo03 | 3,012 | 3.15 h | vo10 | 870 | 0.87 h |
| vo04 | 2,686 | 3.70 h | vo16 | 468 | 0.65 h |
| vo05 | 3,112 | 2.88 h | vo98（其他女性） | 386 | 0.46 h |
| 合计 | 22,135 | **24.55 h** | vo97（男性）/vo99 | 308 / 24 | — |

角色名（**公开 cast 表**，非从游戏文本抽取）：

| # | 角色 | CV | 备注 |
|---|---|---|---|
| 1 | 夜乃桜 | 北大路ゆき | 特典 `Sakura_omake1_*.wav`；兼 黒車掌 |
| 2 | 海漫華淡 | みたかりん | 特典 `Katan_omake1_*.wav` |
| 3 | ソフィア・ランカスター | 葉月ひかり | 特典 `Sophia_omake1_*.wav` |
| 4 | 崩月水仙 | しましまはかせ | 特典 `Suisen_omake1_*.wav` |
| 5 | 崩月槐 | 丸芽伊ず | 推定 `st05`（第 5 个有 LL/战斗差分） |
| 6+ | 羽鳥ミオ / 森道夢明 / N.a.v.i. / 崩月桧木 / 崩月清楓 / システム－大獄 / マシュー・ル・ブラン / 地罰の神官 / シャーロット・ランカスター / クララ・ランカスター / エレノア・ランカスター ほか | — | `st06..st20`，共 15 槽 |

> **待解**：`st05..st20` 与名字的**逐槽绑定**没有找到静态表（`MEM.DAT` 只有 0x731 个非零字节、无 cp932 串；`TEXT.DAT` 里没有独立的名字记录）。两条路：① 解出"名字板"opcode（与文本命令同族的 4 参命令之一）；② 人工看 20 张 `stNN A_A010` 首图对号（半天）。**不要**按 cast 表顺序硬猜。

### 2.4 立绘 / 表情 / CG / 背景 / SD / 遮罩 / UI / 影片

**命名规则（关键）**：`ST<角色2位><姿态字母><部件号4位>.PGD`，例如 `ST01A_A010`、`ST01A_A061`、`ST01A_B010`。
- 第三段 `A..I` = 姿态/衣装组（`st01a`、`st01b`…）；
- 第四段 `_A010`…`_A230` = **图块**：`010` 是整幅底图（`GE ` 完整图，1 MB 级），其余是**以 (x,y,w,h) 定位的差分补丁**（`PGD3`，2.4–25 KB）；
- 实测 `st.pac`：**169 张 `GE ` 底图 + 2,563 张 `PGD3` 补丁**（`face.pac`：94 + 1,150）——即"底图 + 打补丁"的表达差分体系，不是"每张独立图"。
- 同组里 `…061` 与 `…060`、`…081` 与 `…080` 这类"相邻号"是同一图块的变体。

`LIST_STAND.TXT` 给出每个 `st01a_a`..`st01a_i` 的**9 个表情**（`a..i`）及其"鼻子坐标"（用于漫符定位），即 **每姿态 9 个表情**，而不是 20 个。

统计：
- `st.pac` 2,732 条目 / 49 组：`ST01A` 138 件、`ST02A` 150、`ST03B` 276、`ST04A` 126…；`ST12A..ST20A` 只有 1 件（配角单图）。
- `face.pac` 1,244（`FA01A_A010` 同构分层，头像是裁切版）。
- `sd.pac` 43（`SD001A01`…）、`mask.pac` 41（全 `GE `）。
- `ev.pac` 714 事件 CG；`bk.pac` 348 背景；`system.pac` 617 UI 图；`tips.pac` 256 用语图。
- 影片：`movie/LOGO.mpg`（1.28 MB）、`movie/opening.mpg`（160.2 MB）、`em.pac` 内 53 个 `.MPG`、`etc.pac` 内 2 个 `.MPG`（MPEG-1 PS，`00 00 01 BA`）。
- 分辨率：`SYSTEM.INI` → CG `1280×720`、背景 `1320×743`、特效影片 `240×152`（`EM_LSIZE_SCALE=535%`）、`MAX_TEXTURE=4096`、注音 `RUBY_SIZE=10`。

### 2.5 `TEXT.DAT`（台词/UI 文本池）

```
_T E X T _ L I S T _ _ | u32 70112 | u32 0 | [cp932 bytes][0x00][u32 id] …
```

实测：2,148,954 B，**70,111 条**，id 1..70111 **连续无缺**，末 3 字节为填充；平均 25.7 B，最长 155 B。
标记面：`<br>` 13,910 条；注音 `<r…>`（含 `<r漢字>` 与 `<rカナ>` 两种）；`<s30>`/`<s34>` 字号；`%d` 254 条（数值插值）；`</r>`、`</d>`、`<s…>` 闭合标签。

含义：这是**显示用文本池**（含 UI、系统键、字体名、用语），不是纯台词；所以"70,111 行 = 剧情行数"是错的，需要按 id 引用情况筛。

### 2.6 `SCRIPT.SRC`（Sv20）与 `POINT.DAT`

`sub_477790`（loader，`0x477790`）实测逻辑：

```c
PalFileCreate("Script.src") → ReadFile(size)
if (*(u32*)buf != 808613459) fail;          // 0x30325653 = "Sv20"
pc_off = 8;  code = *(u32*)(buf + 8);       // 本作 0x334
*(this+87975)=code;  *(this+87976)=12;  *(this+87977)=12+4;
```

同一函数随后读 `File.dat`/`Text.dat`/`Mem.dat`/`Point.dat`，**只有首字节为 `$`(36) 才解密**（`sub_482890`：每 dword 首字节 `ROL1` by 4+i，再 `^= 0x084DF873`、`^= 0xFF987DEE`）。本作五张表都以 `_` 开头，**未加密**。

脚本内**无任何日文**（UTF-8/cp932 双向扫描 0 命中）；只有 `Sv20` 与 2 个 ASCII 串。台词只能以 id 形式引用。

**已定位的运行时结构（这是本次最有用的新证据）**：

| 事实 | 证据 |
|---|---|
| 命令注册表：68 条，id `0x20000`..`0x20043`，逐条 `sub_4046F0(registry, id, handler)` | `sub_472480`（0x472480，1,159 B）完整反汇编，68 对 `push offset sub_X` / `push 200YYh` |
| 注册表是哈希表，重复注册会打印 `error command table add %08X` | `sub_4046F0`（0x4046F0，248 B），FNV-1a 变体 |
| **文本命令 = `0x20013` → `sub_46DC50`** | 该 handler 打印 `text_cat  %s`，文本缓冲在 `this+4620`，并从**操作数栈**弹 4 个值（`sub_46C060`/`sub_46BC10`/`sub_46BBB0`） |
| 脚本点命令打印 `script_point %08x(%08x)`，取 `this+351900`(PC) 与 `this+352064` | `sub_46DC50` 首行；`sub_479xxx` 同族 |
| VM 状态字段：脚本基址 `this+351892`、PC `this+351900`、操作数栈 `this+258424`、SP `this+286352`、线程 id `this+286356` | `sub_45C070`、`sub_46DC50`、`sub_477790` |
| `POINT.DAT`：11,104 个非零 u32（含 1 个 0），**8,786 唯一**，全部 4 字节对齐，范围 `0x29c..0x6a1d70` | 实测；`script point push/pop stack` 串证实"脚本点"语义 |
| 指令流是 **4 字节对齐、`u16 op` + `u16 参数个数` + n×`u32` 参数** 的候选编码；`01 00 02 00` 在全文出现 67,149 次 | 字节统计；**但未完全对齐**（见 §3.3 的失败点） |

`0x0C..0x334` 的 808 B 头表仍未解（101 条 × 8 B，值形如 `0x00010020`/`0x90000000`，像是"常量池/重定位表"）。

### 2.7 `.MIX`（14 个，语音组）

定长 32 B 槽位，只存**语音 id**（`vo01_0601` 形式），无文本 id：

| 文件 | 字节 | 槽 | 含义 |
|---|---|---|---|
| `VO99_046_01.MIX` | 96 | 3 | 三人同场 |
| `VO99_COM11A.MIX` | 64 | 2 | vo98 + vo97（男女混） |
| `VO99_S06_01.MIX` | 96 | 3 | vo29/vo27/vo28（群体） |
| …其余 11 个 | 32–96 | 1–3 | `GRAND09A`/`KATAN37`/`SUISEN15`/`S030_01` 等 |

结论修正：`.MIX` **不是**"文本行 → 语音"的映射，而是**多角色同时发声的语音组定义**（14 组，覆盖群体场景）。逐行语音映射必须来自脚本（voice id 也是命令参数）。

### 2.8 语音 / BGM / SE

- `voice.pac`：22,135 条，全部 `OggS` v0（真 Ogg/Vorbis），**24.55 h**，均 3.99 s，最长 23.4 s；命名 `VO<ch>_<4位>`，另有 `_#`/`A`/`B`/`_DUP`/`SE##_A###B_GR#` 等 20 余个异形名（多角色/战斗混音）。
- `bgm.pac`：34 条全 Ogg；`BGM.CSV` 给**循环点**（`intro, loop_start, loop_end` 采样数，如 `bgm007: 0,562275,5325075`）；`MUSIC.CSV` 给曲名与序号。
- `se.pac`：789 条全 Ogg。
- `system.pac`：74 条 Ogg（系统音）+ 3 个 32×32 未压缩 TGA。
- 影片：2 个独立 `.MPG` + `em.pac` 53 + `etc.pac` 2。

### 2.9 CSV / DAT 世界与档案数据

| 文件 | 大小 | 内容（结构事实） |
|---|---|---|
| `STAND.CSV` | 1,099 | `x,y,高度补正,stNN,voNN` 共 45 行（L/Battle/LL/LL-Battle 四段） |
| `LIST_STAND.TXT` | 3,771 | `st01a_a..st01a_i` 的 9 表情 + 鼻子坐标（漫符定位） |
| `SOUND.CSV` | 724 | 语音通道注册：`vo01..vo21` + `-1/-2/-3` 特殊通道 + 音量 + 解锁位 |
| `MUSIC.CSV` | 1,429 | 33 首 BGM 的序号/曲名 |
| `BGM.CSV` | 652 | 34 条循环点 |
| `TIPS.CSV` | 6,109 | 用语集：`术语,读音,tips0000S,tips0000B`（约 150 条；**世界/地点词条的主要来源**） |
| `CGMODE.CSV` | 11,930 | CG 鉴赏页：每页一组 `"ev101d01",4,…,-1`（CG id + 演出模式 0..40） |
| `CGBASE.CSV` | 144 | 8 个 CG 缩略图名 |
| `TITLE_FORM.CSV` | 5,060 | 标题/系统按钮的 `x,y,w,h,offset` |
| `VO_EXPOS.CSV` | 430 | 语音鉴赏 12 格坐标 |
| `FAVTAG.CSV` / `FAV_GROUP.CSV` / `REP.CSV` | 85 / 66 / 376 | 收藏标签、分组、回想页 layout |
| `SYSTEM.INI` | 18,004 | 引擎参数（分辨率、音量、字体、`PRODUCT_NAME`/`COMPANY_NAME`、`MAX_TEXTURE`） |
| `FILE.DAT` | 909,648 | 28,426 条 32 B 记录，`#` 前缀的十六进制 id（文件清单/哈希表） |
| `TEXT.DAT` | 2,148,954 | 70,111 条文本 |
| `GRAPHIC.DAT` | 14,728 | 16 B 头 + 2,040 B 表 + 从 0x808 起的 32 B 名字（`ANI_DRAWN05`、`BK_BLACK`、`#FF000000`…），id→资源名 |
| `MEM.DAT` | 14,024 | 几乎全零（0x731 非零字节），无串 → **不含角色名** |
| `POINT.DAT` | 44,436 | 11,104 个脚本点 |
| `ARCHIVE.DAT` | 287 | 归档挂载表 |

### 2.10 旧汉化补丁（`totsulover_dl/DimensionToTsuLovers_cn/`）

| 文件 | 字节 | 事实 |
|---|---|---|
| `License/LICENSE.TXT` | 2,503 行 | 自有许可 + 第三方（abseil/fmt/pcre2/SDL3/zstd/spdlog…）声明 |
| `License/DimensionToTsuLovers_cn_sign.bin` | 3,584 | 补丁签名 |
| `Plugin/DimensionToTsuLovers_cn.dll` | 1,822,720 | 外挂窗口 + hook（`HookMethod=1` IAT / `2` inline） |
| `Plugin/LoaderDll.dll` | 6,144 | 加载器 |
| `Plugin/{avcodec-62,avformat-62,avutil-60,swresample-6,swscale-9,SDL3,AVPlayer}.dll` | — | 自带 ffmpeg 7 / SDL3 播放器 |
| `Plugin/LocaleEmulator.dll` | — | 转区 |
| `Resource/DimensionToTsuLovers_cn_base.pswj` | 8,426,208 | 译文基座（**未解码**） |
| `Resource/…_script.pswj` | 1,209,000 | 脚本译文 |
| `Resource/…_tips.pswj` | 11,571,656 | 用语集译文 |
| `Resource/*.pswj.sign` ×3 | 各 4,627 | 签名 |
| `DimensionToTsuLovers_cn.ini` | 1,732 | 字体（微软雅黑 22）、颜色、热键、BackLog、`SubWindowBackend=1`(D3D) |

`.pswj` 头部（**仅结构识别**）：UTF-16LE 明文串 `Package format made by Saint Serenata of World System …`，其后为不透明载荷 + 独立 `.sign`。**没有解码、没有抽取任何译文。**

LICENSE 的可引用约束（短句，事实性）：

- 「Use the Software for any non-commercial purpose.」→ 仅非商用；
- 「Modify, adapt, or create derivative works based upon the Software.」列为禁止项 → 不得修改/衍生；
- 「Reverse engineer, decompile, disassemble, or otherwise attempt to discover the source code of the Software.」→ **不得逆向**；
- 允许「Copy and redistribute … free of charge and … in its original, unmodified form, with this Agreement included.」
- 版权人：`Saint Serenata of World System of julixian`（2025–2026）。

> **本节只适用于旧补丁。** 同一部作品还有第二个汉化组（Can/need）的 `totsulover_CHS_v1.1`，格式、许可、可迁移性完全不同：明文 `{TEXT.DAT id → 中文}`、CC BY-NC-SA 4.0、作者允许做移植版。新补丁的完整分析见 **§12**；本节的许可结论**不要**推广到新补丁。

---

## 3. 提取管线

> 下面的脚本**尚未入库**，是提案；本次等价操作都在 `/tmp` 用一次性脚本跑过。产物一律进 `tools/` 已 ignore 的目录，不进仓库。

### 3.1 PAC 解析器（修正版）

旧 `totsulover_dl/pack/data/` 是坏的：`ANI_ANGEL_STAND.ANI` 落盘 **8,452 B**，而索引里 `size=47, offset=8452` —— 旧脚本把 `offset` 当 `length` 写。**这份提取物整体不可用**（已复现：前 5 个尺寸 8452/8499/8525/8551/8585 恰好等于 offset 序列）。

正确解析：

```python
import struct, os
HDR, ESZ = 0x804, 0x28
def entries(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'PAC ', path
    n = struct.unpack_from('<I', d, 8)[0]
    out = []
    for i in range(n):
        o = HDR + i*ESZ
        name = d[o:o+0x20].split(b'\0')[0].decode('cp932', 'replace')
        size, off = struct.unpack_from('<II', d, o+0x20)
        out.append((name, size, off))
    assert out[-1][1] + out[-1][2] == len(d) - 8, "索引与文件尾不吻合"
    return d, out
```

必做校验三条：`d[:4]=='PAC '`、`count` 与索引区长度自洽、`Σsize + 首 offset == filesize-8`。17 个归档全部通过。

### 3.2 TEXT / SRC / MIX / DAT

```python
# TEXT.DAT
b = open('TEXT.DAT','rb').read()
assert b[:13] == b'_TEXT_LIST__'
assert struct.unpack_from('<I', b, 12)[0] == 70112
p, rows = 20, []
while p + 5 <= len(b):
    e = b.find(b'\0', p)
    if e < 0: break
    rows.append((struct.unpack_from('<I', b, e+1)[0], b[p:e].decode('cp932')))
    p = e + 5                       # 只留 3 B 尾部填充
# 70,111 条；id 连续；逐条 assert len(rows)==70111 and ids==range(1,70112)
```

- `SCRIPT.SRC`：只读头部，`assert u32@0==0x30327653`，`code = u32@8`。
- `.MIX`：`b[i*32:(i+1)*32].split(b'\0')[0]` → 语音 id 列表。
- `POINT.DAT`：`hdr=_POINT_LIST_****`，`offs = u32[] @16`，丢弃 0，去重 → 8,786 个锚点。

### 3.3 场景/说话人（**核心难点，给出可行路线**）

已确认：文本命令是 `0x20013`（`sub_46DC50`），它从栈上取 4 个操作数；说明**参数由前序指令压栈**（栈式/后缀式求值）。所以只要能解出"压栈指令 + 参数宽度"，就能得到每条文本命令的 (文本 id, 说话人 id, 标志, 时长)。

未解：指令流的**精确帧格式**。已验证的约束：

1. 指令起点 4 字节对齐（`POINT.DAT` 全部对齐，且 `0x334 % 4 == 0`）；
2. `u16 op` 的值域很小（锚点处 `op ∈ {0,1,2,3,4,0x17,0x18,0x1f,0x21,…}`，长尾很多）；
3. `u16 nargs` 读法在 `0x3b0` 处失效（`00 00 00 10` → nargs=0x1000），说明**部分 op 有隐式/变长参数**；
4. 参数常以 `0x40xxxxxx / 0x61xxxxxx / 0x90xxxxxx` 形式出现（高字节像类型标签），`0x611d/0x611e` 这种连续值很像文本或字符串 id。

**下一步（建议按顺序，每一步都能单独验收）**：

- **S-a（0.5 d）**：把 `sub_472480` 的 68 条命令按 handler 反编译归类（文本/立绘/BGM/SE/等待/跳转/选择），产出 `cmd_id → 语义` 表；`0x20002` 是最常见命令（37k 次），优先。
- **S-b（1–2 d）**：在 `sub_46DC50` 上设静态回溯——它是 `0x20013` 的 handler，调用它的唯一上游是 VM 主循环；用 `XrefsTo` 定位主循环（`0x474xxx`/`0x479xxx` 一带），读它的 `switch` 跳转表 → 得到**帧格式的权威定义**（而不是靠字节猜测）。
- **S-c（1–2 d）**：按 S-b 的帧格式写解码器，用 `POINT.DAT` 的 8,786 个锚点做**边界断言**（每个锚点必须是指令起点），失败即回退。
- **S-d（0.5 d）**：把 `0x20013` 的 4 个操作数逐个开关（文本 id / 说话人 / 声音 id / 延时），用「文本 id 落在 1..70111」和「说话人 id 落在 vo01..vo29」两个约束反推哪个是哪个。

风险：若 VM 用**计算跳转 + 自修改**，S-b 可能失败；那时退路是 §2.6 的 `u16 op` + `u16 nargs` 配 `op` 白名单的**约束求解**（我已写过一版 CSP，需要更细的白名单），或直接用 `POINT.DAT` 把脚本切成 8,786 段、每段内做**启发式**（见 §5.4）。

### 3.4 图像 `.PGD`：两种方案

#### 方案 A（推荐先做）：插件调引擎自己导出 PNG

`Pal.dll` 导出、游戏也导入的现成 API：

| 导出 | 地址 | 作用 |
|---|---|---|
| `PalSpriteLoad` | `0x100b9d60` | 从 VFS 读一个 `.pgd` 成 sprite |
| `PalSpriteLoadMemory` | `0x100b9c30` | 从内存解码（GE/PNG/JPEG 分支） |
| `PalSpriteLoadTextureToFile` | `0x100b6d60` | 外部 PNG/JPEG 贴图 |
| **`PalSpriteSaveTextureToPngFile`** | `0x100b6e60` | **把当前渲染目标存 PNG** |
| `PalSpriteSaveTextureToPng24File` | `0x100b6ea0` | 24-bit 版 |
| `PalSpriteGetInfo` | `0x100b8170` | 取 w/h/rect |

做法：写 32-bit DLL（游戏自己有 `Plugin/` 加载机制，汉化补丁就是插件），`PalSpriteLoad(vfs, "ST01A_A010.PGD")` → 画到离屏 surface → `PalSpriteSaveTextureToPngFile`。零编解码逆向，但**需要 Windows 跑一次游戏**（本机没有；且任务要求不动游戏执行）。

工作量：插件骨架 + 批量循环 1–2 d（Windows），产出 2,732 + 1,244 + 714 + 348 + 617 + 403 + 43 + 41 ≈ **6,142 张 PNG**。

#### 方案 B：重写解码器（无 Windows 依赖）

已把解码链读通：

```
PalSpriteLoad (0x100b9d60)
  ├─ magic u16 == 0x4547 ("GE") 或 u32 ∈ {0x32444750 "PGD2", 0x33444750 "PGD3"}
  ├─ PGD2/PGD3 → sub_100B9A50 (0x100b9a50)   ← 增量/分层记录
  └─ 其它      → PalSpriteLoadMemory (0x100b9c30)
                    └─ sub_100C7D50 → sub_100C72E0 (0x100c72e0)  ← 格式分派
                          ├─ type@28 == 3 → sub_100C5820 (0x100c5820)  ← LZSS 解压
                          ├─ type 1/2     → 24/32bpp 版本
                          └─ default      → 逐行 4*w 字节裸拷贝
```

**LZSS 解码器**（`sub_100C5820`，196 B）已完全读懂，语义是"8 位标志组 + 4 字节步进拷贝"：

```
flag byte; 每次右移 1 位，8 次后取新 flag
bit0 == 0 → 字面量块：b = next(); len = (b & 0xFC) >> 2; extra = b & 3;
            copy 4*len bytes; then copy `extra` bytes      (即 4*len+extra 字节)
bit0 == 1 → 匹配：v = u16
            if (v & 8)  { dist = v >> 4; len = (v & 7) + 4 }          // 2 字节形式
            else        { v3 = (v << 8) | next(); dist = v3 >> 12;
                          len = ((v3 & 0xFFC) >> 2) + 1; extra = v3 & 3 } // 3 字节形式
            从 dst - dist 处 4 字节步进拷贝 4*len，再补 extra 字节
```

**GE 头**（`GE ` 文件实测，如 `ST01A_A010.PGD` 1,089,924 B）：

```
0x00 u16 "GE"(0x4547) + 0x00/0x20      0x02 u16 payload_off(=32)
0x04..0x0B 0
0x0C u32 w   0x10 u32 h   0x14 u32 w(重复)  0x18 u32 h(重复)
0x1C u32 type(0=raw,1,2,3=LZSS)
0x20 u32 解压后总字节(= 19,662,856)   0x24 u32 压缩载荷字节(= 1,089,884)
payload_off+8 = 0x28 起 = LZSS 流
解压后 = 8 B 子头(u16 7, u16 32, u16 w, u16 h) + h 字节"行表" + w*h*4 RGBA
```

**PGD3 头**（`ST01A_A020.PGD` 2,460 B 实测）：

```
0x00 "PGD3"   0x04 u16 x   0x06 u16 y   0x08 u16 w   0x0A u16 h
0x0C u16 bpp(24/32)   0x0E u16 namelen(=32)
0x0E..0x2D char name[32]   ← 基图名，如 "st01a_a010.pgd"
0x2E..0x2F 2 B 对齐填充
0x30 u32 原始字节(= h + w*h*4，示例 51,429)
0x34 u32 压缩字节(= 2,404)
0x38 起 = LZSS 流
解压后 = h 字节行表 + w*h*4 像素；**像素为 0 表示"该点不变"**
```

**已实测验证**（这是本次最硬的一条）：按上面的写法自己实现 LZSS + 头解析，`ST01A_A010` 解出 **19,662,856 B**（与头部声明逐字节相等、载荷恰好读完），`MASK00` 解出 **2,765,528 B**；`st.pac` 随机抽 12 张 `PGD3`，12/12 的像素区长度都**精确等于 w*h*4**，零像素占比 55.6%–97.3%（即"只改脸"）。**解码器不再需要逆向，只需要写 PNG。**

`sub_100B9A50` 的合成语义（结合实测）：

1. 解 PGD3 的载荷 → `w*h*4` 的差分像素；
2. 取**基图**（名字在头里，同 VFS 解析）在 `(x,y)` 处的 `w×h` 裁片；
3. 逐像素 **XOR**（24bpp 用 `& 0xFFFFFF`，32bpp 直接 XOR），行间按 `4*(w_dst-w_src)` 跳；
4. 差分像素为 0 的位置 XOR 后保持基图原样 → 这就是"换表情"。

所以 `.PGD` 载荷里没有 PNG/zlib 魔数是必然的：**LZSS + 按矩形打的 XOR 差分**。

工作量与风险：**核心解码已经跑通**（本次在 `/tmp` 里有可用的 LZSS + 头解析 + 补丁合成原型）。剩下的是工程化：PNG 编码（可用 `zlib` 裸写，不依赖 Pillow）、24bpp 路径、行表语义、以及"哪些 `PGD3` 补丁属于哪个表情"的编目。估计 **1–2 d**，不再是 3–4 d。风险只剩：① 24bpp 图的通道顺序；② 少数 `GE ` 里 type ≠ 3 的（raw/1/2）；③ 补丁与 `LIST_STAND.TXT` 的 `a..i` 对应关系需要目视确认。**方案 A 仍然值得做一次**，只为给 20 张"标准答案"做回归对照，不作为主路径。

### 3.5 音频 / 视频

- `.OGG`：真 Ogg/Vorbis，`ffmpeg -c:a libmp3lame` 或直接 `AVAudioFile` 播；建议统一转 **48 kHz / 单声道 / 24–32 kbps Opus** 供端上播放（22,135 条 → 约 250 MB）。
- BGM 34 条要保留循环点（`BGM.CSV` 的采样数除以采样率即秒）。
- `.MPG`：MPEG-1 PS，`ffmpeg -f mpeg -i x.mpg -c copy x.mp4` 或转 H.264/AAC 给 AVPlayer；`EM_LSIZE_*` 说明它是 240×152 小窗按 535% 放大。
- `.TGA`：32×32 type 2 未压缩，直接读。

### 3.6 验证清单（每条都要能自动跑）

| 检查 | 判据 |
|---|---|
| PAC 索引 | 17/17 `last_offset+size == filesize-8`；name 全 8.3 大写 |
| TEXT | 70,111 条、id 连续、无残留字节、cp932 可解 |
| MIX | 槽位 32 B 对齐、每个 id 都能在 `voice.pac` 找到同名 Ogg |
| Ogg | 22,135 条 `OggS`；Σgranule/rate ≈ 24.55 h |
| PGD | 抽样 50 张解出 PNG，`w×h` 与头部一致、alpha 非全 255；与方案 A 基准图做 SSIM > 0.99 |
| 立绘对齐 | 每个 `stNNx_x` 的 9 表情合成后尺寸一致、鼻子坐标落在图内 |
| 包 | `StaticStandManifest` 全 `files` size+crc32 校验；`content` 包 `episode_passages>0` |

---

## 4. 旧汉化补丁：结构与对齐（只做结构，不取译文）

> 本节针对**旧补丁** `DimensionToTsuLovers_cn`（`.pswj`）。新补丁 CHS v1.1 的许可**不同**，见 §4.1 与 §12。

**结构事实**（不含内容）：

- 三份 `.pswj` + 三份 `.sign`（各 4,627 B）；`.pswj` 头是 UTF-16LE 的 `Package format made by Saint Serenata of World System …`，说明是**作者自有打包格式**，不是游戏原生容器。
- 补丁通过 `Plugin/DimensionToTsuLovers_cn.dll`（1.78 MB）注入，`HookMethod` 可选 IAT / inline；INI 里可调字体、描边、BackLog、D3D/GDI 后端；自带 ffmpeg 7 + SDL3 播放器（说明它替换了影片播放路径）。
- `DimensionToTsuLovers_cn.exe`（1,159,168 B）比 `totsulover_crack.exe` 多一个 `.detour` 段 —— 与"注入式外挂窗口"一致。

**许可约束对项目的影响**（这决定"能不能用它"）：

| 想做的事 | 许可是否允许 | 结论 |
|---|---|---|
| 把译文并进内容包的 `zh` 列 | ❌ 衍生 + 未授权 | 不可 |
| 解 `.pswj` 拿译文/对照表 | ❌ 明确禁止逆向 | 不可 |
| 用它做**行对齐的旁证**（如行数、段数、文件层级） | ⚠️ 边界：读文件大小/头可以，解内容不行 | 只记录规模，不解内容 |
| 参考它的显示层（字体/描边/BackLog 参数） | ✅ 那是 INI 里的配置事实 | 可参考**参数**，不搬资源 |

**建议的合法路径**（按成本排序）：

1. **官方/正规中文化**：查 CRYSTALiA / AMUSE CRAFT 是否已有官方中文或授权代理版本；有就买、用官方文本（这是唯一能合法再分发的路）。
2. **自制新译文**：以 `TEXT.DAT` 的日文为源，自己（或 LLM 辅助 + 人工校）翻；译文版权归自己，可随内容包分发（仍受原作素材版权约束，见 §7）。
3. **运行时机器翻译**：App 内按需翻译（不落盘、不随包分发），把"翻译"变成用户侧行为而不是内容再分发。
4. **不要**做的事：把 `.pswj` 解包、把它的译文写进 `episode_lines.zh`、把补丁文件放进 `content/`。

### 4.1 补充：CHS v1.1 的许可不同（2026-11-12 追加）

上面的「不可」只对旧补丁成立。新补丁 `totsulover_CHS_v1.1`（Can/need）把译文放在**公开 GitHub 仓库**里，采用 **CC BY-NC-SA 4.0**，Mod 声明里还明确允许「基于本Mod制作移植版本」（须署名、不得换钱）。因此同一张表要重写成：

| 想做的事 | CHS v1.1 是否允许 | 结论 |
|---|---|---|
| 把译文并进内容包的 `zh` 列（本机自用） | ✅ CC BY-NC-SA（非商用、署名、同协议） | **可以**，且不需要逆向（明文 JSON） |
| 解 `totsulover.dll` 拿译文 | ✅ 但没必要 | 走公开 JSON 路线 |
| 把译文提交进本仓库 | ⚠️ 许可允许，但违反本仓库「不放译文」的硬约束 | **不做** |
| 随内容包分发译文（非商用 + 署名 + CC BY-NC-SA） | ⚠️ 译文层可以；**游戏素材层不行**（原作版权） | 只发补丁/脚本，不发成品包 |
| 卖 / 上架 / 内购 | ❌ 违反 NC 且违反 Mod 声明第 1 条 | **禁止** |
| 用 `FONT.TTF`（霞鹜文楷） | ✅ SIL OFL | 可用，保留 OFL 声明 |
| 用 472 张 `.PGD`（UI/用语集/带字 CG）+ 9 张带字背景 | ⚠️ 原作美术改图，比纯文本更敏感 | **不用** |

结论：CHS v1.1 把「能不能用中文文本」从「不能」变成「**非商用可以，须署名 Can/need，衍生同样 CC BY-NC-SA**」；仍不足以支撑「公开分发含素材的成品包」。细节、署名文案与提取管线见 §12.6–§12.7。

---

## 5. 映射到 Eidolon

### 5.1 现状接缝（已实现，可直接用）

| 接缝 | 位置 | 现状 |
|---|---|---|
| `ContentManifest` | `EidolonCore/Sources/EidolonCore/ContentManifest.swift:9` | `format_version=5`；已有 `kind`、`franchise`、**`engineFamily`**、**`contentSetID`**、`characters.characterKeys`、`files[size,crc32]` |
| 内容库 schema | `ContentSchema.swift:8-37` | `episodes` / `episode_cast` / `episode_lines(ja,zh,speaker,seq)` / `episode_passages(embedding)` |
| 统一包头 | `Presentation.swift:243-249` | `ContentKind{content,stand,bar,model3d,universe}` |
| 安装分流 | `ContentBundleInstaller.swift:34-38` | 已按 `expectedKind` 校验 kind |
| 剧情空包拒绝 | `ContentBundleInstaller.swift:351` | `episode_passages > 0` 才收 |
| **静态立绘包** | `StaticStandManifest.swift` | `format_version=1`、`kind=.stand`、`mode=full\|delta`、`renderer="static"`、`characters[].expressions[emotion:path]`、`files` |
| 静态立绘安装 | `StaticStandBundleInstaller.swift:75-130` | `mode` 只收 `full`、`renderer` 只收 `"static"`、逐文件 size+crc32、表情文件必须存在 |
| 内容↔立绘绑定 | `ContentRegistry+Eidolon.swift:214-240` | `installStaticStand(bundleAt:franchise:)`，两边都声明 `contentSetID` 且不等则**报错** |
| 表情枚举 | `StandRender.swift:96` | `StandEmotion{calm,happy,shy,surprised,sad,angry,thinking}`（7 种） |
| TTS | `EidolonIOS/Core/Call/FishSynthesis.swift:19` | `api.fish.audio/v1/tts`，`model` 头 + `reference_id` |

**修正上一份调研的两处过期结论**：① `contentSetID`/`engineFamily`/`characterKeys` **已经落地**，不再是"待做"；② `ContentBundleInstaller` **已按 kind 分流**，但 `content` 仍需 `episode_passages>0`。

### 5.2 content / stand / world 三分

| 包 | kind | 内容 | 体积（估算） |
|---|---|---|---|
| 剧情 | `content` | `eidolon.db`（episodes/lines/passages）+ `characters.json` + `world.json` + `places.json` | 文本 ~30 MB + embedding ~700 MB（70k × 1536 × 4B，见 §5.5） |
| 立绘 | `stand` | 20 角色 × 7 表情 PNG（约 140 张，含 alpha） | 20–60 MB |
| 世界 | 并入 `content` 的 `world.json`/`places.json` | 用语集 ~150 词条、地点、阵营 | < 1 MB |

`franchise = "totsulover"`（**按作品，不按引擎**），`engineFamily = "t-script"`；`CharacterKey = totsulover:<local>`，local 用罗马字：`sakura`/`katan`/`sophia`/`suisen`/`kaon`…

`contentSetID` 建议 `totsulover:main`（content 与 stand 都写同一个），这样 `installStaticStand` 会自动绑定；将来出"FD/追加盘"时换成 `totsulover:fd1`。

### 5.3 立绘设计（20 角色 × 表情，静态包）

**源**：`st.pac` 的 `ST<NN><Pose>_<part>.PGD`。`LIST_STAND.TXT` 给 `a..i` **9 个表情**，Eidolon 要 **7 个**。建议映射：

| 游戏 | Eidolon | 说明 |
|---|---|---|
| a（默认） | `calm` | 基准 |
| b / c | `happy` | 笑/微笑 |
| d | `shy` | 脸红 |
| e | `surprised` | 惊 |
| f | `sad` | 哀 |
| g / h | `angry` | 怒/不満 |
| i | `thinking` | 困/考 |

（`a..i` 的确切语义要人工看 9 张图确认，**不要**按字母顺序硬套。）

**管线**：

1. 每个角色取**主姿态**（`A`）的 `_A010` 底图（`GE `，2400×2048 之类的大画布，绝大多数像素 alpha=0，需按 alpha 包围盒裁切）；
2. 把该姿态下的 `PGD3` 补丁按 `(x,y)` 打回底图（差分像素为 0 处保持原样）；
3. **但"表情 `a` 由哪几个补丁组成"目前还不知道**（见 §8 Q10）——`LIST_STAND.TXT` 只给 `st01a_a..i` 这 9 个**合成 id** 与鼻子坐标，没给补丁清单；
4. 拿到合成表后：合成 9 张 → 裁 alpha 包围盒 → 统一高度（建议 1600 px）→ 存 `stand/expressions/<char>/<emotion>.png`；
5. `manifest.json` 写 7 条 `expressions`；`files` 逐张列 `size` + `crc32`（installer 会校验）；
6. 20 角色 × 7 = 140 张，预计 20–60 MB。

**合成表的三条恢复路线**（按成本）：
- **R-a**：68 条命令里应该有一条"立绘合成/差分挂载"（参数是基图 + 补丁列表或一个合成 id）——与文本命令同批解，最干净；
- **R-b**：`face.pac` 的 1,244 张头像本身就是"某表情的头像"，可用来给 9 个表情**目视命名**（解决 `a..i` 语义），也提供"合成结果应该长什么样"的参照；
- **R-c**：暴力枚举——对每个 `st01a_x`，取该姿态全部补丁的一个子集，按 `(x,y)` 叠上去，用"与 `face.pac` 同名头像的相似度"打分。慢但不需要 VM。

**若仍解不出**：台式退路是方案 A（让引擎自己合成后存 PNG），代价是需要一次 Windows 运行——本报告不建议把它当主路径，但可以作为 20 张基准图来源。

### 5.4 文本 → episode / line / passage

`episode_lines` 需要 `(episode_id, seq, speaker, ja, zh)`；`episodes` 需要 `id/category/source/title`。现状是 70,111 条扁平 id，必须切。

**切分策略（四档，按到手信息量递增）**：

| 档 | 边界 | 说话人 | 质量 | 依赖 |
|---|---|---|---|---|
| H1 启发式 | `POINT.DAT` 的 8,786 锚点 + 文本 id 的"跳跃"（id 不连续即新段）+ `<br>` 分页 | `narrator`（全部） | 能用但粗，适合先跑通 embedding | 无 |
| **H1.5 单元名锚点（新，推荐）** | `TEXT.DAT` 里 255 个脚本单元名（`001_共通ルート：０１` 这类串，各出现**恰好 1 次**）就是精确边界 | **名字 id 紧邻台词** → 真实 speaker | 够用，且不依赖 VM | §12.4.3 |
| H2 半解 | 解出 `0x20013` 的 4 个操作数（文本 id/说话人/voice id/延时） | 真实 speaker + **voice id** | 可用 | §3.3 S-b/S-d |
| H3 全解 | 68 命令全部语义化，按"场景切换/章节标题/选择支"切 | 真实 speaker + 情绪 | 最好 | §3.3 全流程 |

**建议（CHS v1.1 之后更新）**：直接做 **H1.5**——单元边界和 `speaker` 都能从 `TEXT.DAT` 自身静态拿到，不必先跑 H1 再升级。只有「台词 → voice id」还需要 H2/H3；那条可以晚做，且不影响 content 包先落地。

**中文列（`zh`）的来源**：用 CHS v1.1 的 `STRINGS.JSON`，按 **`STRINGS[id-1]`** 取值（**差 1**，见 §12.4.2）。这个偏移必须写成断言，否则整体错行且不会报错。

**passage/embedding 成本**：`episode_passages` 每段必须有非空 embedding（`ContentBundleInstaller.swift:327-330` 会拒）。70k 行 × 1536 维 float32 = **~430 MB**；若按 3 行一段，段数 ~23k，向量 ~140 MB。建议 `dimensions=1024`（硅基流动 bge-m3）→ ~95 MB。

**speaker 兜底**：H1.5 已能给到说话人（名字 id）；仍拿不到时（旁白、或名字不在词表里），`episode_cast` 再用 `STAND.CSV` 的 `st→vo` 反推（每条 voice id 前两位就是角色），把"谁在场"写成 cast，而不是把 `speaker` 写成猜的名字。

**`zh` 的排版缺口**：CHS v1.1 的译文**完全不保留 `<br>`**（日文 13,910 条有，中文 0 条），`<r…>` 注音也从 432 条降到 19 条。所以 `episode_lines.zh` 只存纯文本，换行交给端上按容器宽度折行；不要试图从日文抄 `<br>` 位置（中文比日文短 25%，抄了会断在奇怪的地方）。

### 5.5 语音 vs Fish Audio 训练

| 用途 | 用什么 | 理由 |
|---|---|---|
| **端上播放原声**（推荐先做） | `voice.pac` → Opus 48 kHz 单声道，按 `voice id` 存 | 24.55 h 真原声，零成本，情感/语气是原配 |
| **新台词 TTS** | Fish Audio `reference_id`（现有 `FishSynthesis`） | 与现有通话链路一致，一条 `voiceID` 就够 |
| **Fish 自训 PVC** | 特典 WAV（5.1 min，4 角色）+ `voice.pac` 精选（每角色 ≥10 min） | PVC 门槛 10 min；特典只有 76 s/人，**不够** |
| **本地自训（个人）** | `voice.pac` 每角色 2.9–4.2 h | 时长足够，但**转写未知**（见下） |

`voice.pac` 做训练集的**致命缺口**：文本 ↔ voice id 的映射还没解（§3.3）。三个绕法：

1. 用 Fish ASR（`transcribe-1-pro`，$0.36/音频小时）自动转写 24.55 h ≈ **$8.8**，一次性；转写错误用"游戏文本池"做约束校验（把 ASR 结果与 `TEXT.DAT` 做模糊匹配，命中率能当质量指标）。CHS v1.1 **没有**解决这个问题（它的 `STRINGS` 键是文本 id，不含 voice id），所以这条路仍然有效。
2. 等 §3.3 解出 voice id 参数，直接用官方日文台词当 transcript（**零 ASR 成本、零错误**）。
3. 只用特典 80 条（自带清晰语音、无 BGM）做 reference clone，放弃 PVC。

### 5.6 `world.json` / facts / places 缺口

| 字段 | 来源 | 缺口 |
|---|---|---|
| `facts`（角色设定） | 无静态表；`TIPS.CSV` 是用语不是人设 | 需要手写/LLM 从公开设定整理，**不能**从游戏文本批量抽 |
| `places` | `TIPS.CSV` 里约 150 条用语中的地点/组织类词条（本报告不摘录，见 §4 的合规原则）+ `bk.pac` 背景名 | 需要人工分类（`placeLikes` 还要按角色打标） |
| `photoTag` / `photoAppearance` | 无 | 手写（Danbooru 拼写要人工核） |
| `birthday` / `age` | 无静态表 | 手写或留空（`age` 影响成人模式，**必须**有依据才能填） |
| `voiceID` | Fish 模型 id | 建完模型后回填 |

---

## 6. Fish Audio（一手文档）

| 主题 | 事实 | 来源 |
|---|---|---|
| 即时克隆 | **≥10 秒**音频即可；建议 2–3 段 15–20 s 的连续段落；一人、无 BGM、无回声 | [Voice Cloning Best Practices](https://docs.fish.audio/developer-guide/best-practices/voice-cloning) |
| PVC（专业克隆） | **付费计划**；**≥10 分钟**（12–15 段 × 45–60 s，单段 < 1 min，上限 180 min）；MP3/WAV/FLAC；需**声纹验证**（本人录制或 Proxy 上传授权证明）；训练 10–30 min；发布要选可见性 + 1/2/3 年通知期 | [Professional Voice Clone](https://docs.fish.audio/overview/platform/create-voice/professional-voice-clone) |
| API 建模型 | `POST /model`，`train_mode=fast`（即时可用）或 `full`；`voices` ≤ 20 个文件；`texts` 可省略（省略则跑 ASR）；`visibility` 默认 `private`（public 会被降级） | [Create Model](https://docs.fish.audio/api-reference/endpoint/model/create-model) |
| TTS 计价 | `s2.1-pro` **$15 / 百万 UTF-8 字节**（≈18 万英文词 ≈12 h 语音）；`drama-3` $50（2026-11-30 前促销 $10）；`s1` 2026-12-31 退役 | [Pricing & Rate Limits](https://docs.fish.audio/developer-guide/models-pricing/pricing-and-rate-limits) |
| ASR 计价 | `transcribe-1-pro` / `transcribe-1`：**$0.36 / 音频小时**（按秒向上取整，含静音） | 同上 |
| 并发限流 | 按累计付费额分档：< $100 → **5 并发**；≥ $100 → 15；≥ $1,000 → 50；超限 429（**无 Retry-After**，要指数退避） | 同上 |
| 授权 | 只能克隆"自己的声音 / 有书面许可的人"；**明确禁止**未经许可的网络声音与名人声音 | 同上 Best Practices「Important: Getting Permission」 |
| 条款 | 用户提交内容需向 Fish 授予"royalty-free, perpetual, sublicensable, irrevocable, worldwide"许可（ToS §2 摘要） | [fish.audio/terms](https://fish.audio/terms/) |

**对本项目的含义**：

1. 现有链路（`reference_id` + `model` 头）就是"参考音频克隆"，**不需要训练**也能用；训练只在"想要更像/更稳"时才需要。
2. 特典 80 条（**5.1 min / 4 角色 ≈ 76 s 每人**）**只够做 reference**，达不到 PVC 的 10 min；要 PVC 必须从 `voice.pac` 补时长（每角色 2.9–4.2 h，远超门槛）。
3. **本地自用 vs 再分发必须分开**：
   - 本地/私人：可以用游戏原声做参考克隆（仍属灰区：日本法下声优有パブリシティ権，商业使用不行）；
   - 任何**分享/发布/上架**：不行。要么用 **Voice Design**（生成原创音色，不克隆真人），要么用自己/已获授权的声音。
4. 成本量级：一部 70k 行的全语音替代（假设 12 h 新语音）在 `s2.1-pro` 上约 **$0（12 h ≈ 1 M 字节）**——即**单次全量重录约 $15**；真正贵的是 embedding 与人工，不是 TTS。

**具体数据集方案（推荐顺序）**：

- **D0（1 h）**：特典 80 WAV → 按角色分 4 组，`sox`/`ffmpeg` 统一 48 kHz 单声道、去首尾静音、−16 LUFS；作为 **reference** 上传（或建 `train_mode=fast` 模型）。
- **D1（0.5 d）**：`voice.pac` 按通道抽 **15 段 × 50 s**（每角色 12.5 min），只挑 `SZ` 中等、无 BGM 的（可用"过零率 + 谱平坦度"粗筛），凑够 PVC 门槛。
- **D2（1 d + $9）**：全量 24.55 h 用 `transcribe-1-pro` 转写，再用 `TEXT.DAT` 做模糊校验，产出 `(ogg, text)` 对齐表；这是后续**本地自训**（GPT-SoVITS 之类）的输入。
- **D3（对齐后）**：把 §3.3 解出的 voice id 与官方台词直接配对，替换 D2 的 ASR 文本（零错误）。

---

## 7. 分阶段迁移计划

工时按"一个人、熟悉本仓库"估算；每阶段都有可单独验收的产出。

| 阶段 | 内容 | 产出 | 工时 | 验收 | 风险 |
|---|---|---|---|---|---|
| **P0 提取基座** | PAC/DAT/TEXT/MIX/Ogg 解析入库（`tools/`，产物 ignore） | `extract_pac.py`/`extract_text.py`/`extract_voice.py` + 自检 | 1 d | 17/17 归档校验、70,111 行、22,135 Ogg、24.55 h | 无（已实测） |
| **P1 图像解码** | 用已验证的 LZSS + GE/PGD3 头写解码器；169 张底图 + 2,563 张补丁合成；PNG 裸编码；24bpp 补齐 | `pgd_decode.py` + 约 6,100 张 PNG | 1–2 d（原估 4–6 d） | 12/12 抽样像素长度精确、`ST01A_A010` 解出 19,662,856 B；随机 50 张目视无破图 | 24bpp 通道顺序；type≠3 的少数 GE |
| **P2 静态立绘包** | 20 角色 × 7 表情合成 → `StaticStandManifest` 包 | `totsulover-stand.zip` | 2–3 d | 真机装上、`staticStandExpressions` 返回 7 个 URL、切换表情可见 | **表情合成表未知（Q10）**；`a..i` 语义需目视 |
| **P3 文本切分（H1.5）** | 用 255 个单元名切 episode；`speaker` 取紧邻名字 id；`zh` 取 `STRINGS[id-1]` | `eidolon.db`（episodes/lines/passages） | **0.5–1 d**（原 H1 方案 2 d） | 255 个单元全对、`「」` 首尾一致率 100%、检索抽检 20 条 | 名字词表漏筛（旁白误标）；`<br>` 需端上折行 |
| **P4 VM 解码（H2）** | 68 命令语义表 + 帧格式 + **voice id**（speaker 已由 P3 解决） | `lines.voice_id` | **1–2 d**（原 3–5 d） | voice id 能对上 `voice.pac` 的 Ogg；抽样 1,000 条 | 仍可能卡在计算跳转，但**不再卡关键路径**（只影响语音挂载） |
| **P5 语音包** | 22,135 Ogg → Opus + voice id 索引；按行挂语音 | `voice/` + `lines.voice_id` | 2 d | 任意一行能播对应 Ogg；端上 250 MB 内 | voice id 映射依赖 P4 |
| **P6 世界数据** | `TIPS.CSV` → `places`；手写 `facts/birthday/photoTag` | `world.json`/`places.json` | 1–2 d | `validatePlaces`/`validateWorld` 通过 | 人设需人工，不能批量抽 |
| **P7 Fish 音色** | D0/D1 数据集 → 每角色一个 reference；回填 `voiceID` | `characters.json` 的 `voiceID` | 1 d + $10 | 通话能出声、名字读音正确 | 法务（仅本地） |
| **P8 端到端** | 内容包 + 立绘包 + 语音 + 音色一起装 | 可玩切片 | 1 d | 真机：进剧情 → 检索 → 立绘换表情 → 出声 | 包体过大 |

**关键路径（CHS v1.1 之后）**：P0 → P3（文本+中文可检索）与 P0 → P1 → P2（立绘可见）并行；P4 降级为 P5 的前置，不再是"可能推翻计划"的一步。

**总工时**：约 **10–14 人日**（原 14–20；P3 从 2 d 降到 0.5–1 d，P4 从 3–5 d 降到 1–2 d 且移出关键路径）。

> 变更依据：§12.4（对齐与边界可由 `TEXT.DAT` + `STRINGS.JSON` 静态恢复）。

---

## 8. 开放问题

| # | 问题 | 影响 | 怎么解 |
|---|---|---|---|
| Q1 | Sv20 的帧格式（op 后参数宽度规则）？ | ~~决定 P4 成败~~ → 只影响 voice id | §3.3 S-b；**说话人不靠它也能拿到**（§12.4.3 名字 id） |
| Q2 | `0x20013` 的 4 个操作数各是什么？ | 现在只缺 voice id | §3.3 S-d 的约束反推 |
| Q3 | `0x0C..0x334` 的 808 B 表是什么？ | 可能是常量池/重定位表，能省一半逆向 | 与同引擎其他作品对比 |
| Q4 | PGD3 的"两层 XOR"里谁是基图、顺序如何？ | P1 的 3 d vs 6 d | 用方案 A 的基准 PNG 反推 |
| Q5 | `st05..st20` 与角色名的逐槽绑定？ | 立绘包 `id` 命名 | 看 20 张首图（半天）或 Q2 解出名字板 |
| Q6 | `a..i` 9 表情的真实语义？ | 7 情绪映射 | 人工看 9 张图 |
| Q7 | `voice.pac` 里多少条含 BGM/SE 混音？ | 训练集质量 | 谱平坦度 + 人工抽检 |
| Q8 | `franchise` 用 `totsulover` 是否与 #135 一致？ | id 空间 | 已有 `engineFamily`，按作品命名应无争议，需确认 |
| Q9 | `GE ` 里 type ≠ 3 的少数图（raw/1/2）怎么解？ | 影响少量 UI/遮罩 | 按 `sub_100C72E0` 的 default 分支（逐行 4*w 裸拷贝）先试 |
| Q10 | **表情合成表**（`st01a_a` ↔ 补丁清单）在哪？ | 决定立绘包能否自动化 | §5.3 R-a/R-b/R-c |
| **Q11** | `<dNNNN>` 术语标签要不要跟补丁的 `TIPS.CSV` 顺序？ | 影响 128 条台词的术语弹窗 | §12.4.4：建议保留原版 `TIPS.CSV`，用 `tips####` id 做桥把中文标签映回原行号 |
| **Q12** | `zh` 没有 `<br>`，端上怎么折行？ | 13,910 行原本靠 `<br>` 断行 | 客户端按容器宽度折行；或按标点（。！？…，）优先断；**不要**抄日文的 `<br>` 位置 |
| **Q13** | 译文与语音时长不匹配（中文比日文短 25%）怎么排？ | 自动播放节奏 | 按 Ogg 时长做停留，而不是按字符数 |
| **Q14** | CHS v1.1 的译文要不要作为长期基线（可更新到 v1.2）？ | 维护方式 | 记录 `canneed-oss` 的 commit + `totsulover.dll` SHA-256，重跑 §12.6.1 的断言即知是否漂移 |

**本轮建议**：采用 Can/need CHS v1.1 作为**本机迁移基线**（非商用、署名、同协议；译文不公开）；`<dNNNN>` 走 Q11 的「原版 TIPS + `tips####` 桥接」；旧 `.pswj` 章节保留为历史对照，不进入管线。

---

## 9. 证据表

| ID | 论断 | 来源（可复查） |
|---|---|---|
| E1 | 引擎 = T-Script System -DL / CRYSTALiA / 1.17.0.0 | `totsulover_crack.exe` 的 `.rsrc` VS_VERSION_INFO（UTF-16 扫描） |
| E2 | 17 个 `.pac` 全部满足 `last_offset+size == filesize-8` | `/tmp/eidolon-re-full/tools/pac.py sum *.pac` 输出（本文 §2.2 表） |
| E3 | `data.pac` = 160 条（139 ANI/14 MIX/6 DAT/1 SRC） | 同上 `list data.pac` |
| E4 | `TEXT.DAT` = `_TEXT_LIST__`+70112+0，70,111 条，id 1..70111 连续 | 实测解析（`/tmp` 脚本，§3.2） |
| E5 | `SCRIPT.SRC` 6,954,384 B，`Sv20`，代码段 0x334 | 头部 hexdump + `sub_477790` 伪代码 |
| E6 | 脚本内无日文（UTF-8/cp932 均 0 命中） | 正则扫描 6,954,384 B |
| E7 | 68 条命令 `0x20000..0x20043` 的注册表 | `sub_472480` 完整反汇编（`/tmp/eidolon-re-full/ida/game8.txt`） |
| E8 | 注册表是哈希表，报错串 `error command table add %08X` | `sub_4046F0`（0x4046F0）反编译 |
| E9 | 文本命令 = 0x20013 → `sub_46DC50`，打印 `text_cat  %s`，取 4 个栈参数 | `sub_46DC50` 反编译（`game5.txt`） |
| E10 | VM 状态字段：PC `this+351900`、栈 `this+258424`、SP `this+286352` | `sub_46DC50` / `sub_45C070` |
| E11 | `POINT.DAT` 11,104 个非零偏移、8,786 唯一、4 字节对齐 | 实测（§3.2） |
| E12 | `voice.pac` 22,135 条 Ogg，24.55 h，均 3.99 s，最长 23.4 s | Ogg granule 实测（§2.3） |
| E13 | 立绘命名 `ST<NN><Pose>_<part>`，`_A010` 为底图 | `st.pac` 2,732 条名字统计 |
| E14 | `LIST_STAND.TXT` 每姿态 9 表情 + 鼻子坐标 | `csv.pac` 提取 + cp932 解码 |
| E15 | PGD 分派：`GE`(0x4547)/`PGD2`(0x32444750)/`PGD3`(0x33444750) | `PalSpriteLoad` 0x100b9d60 反编译 |
| E16 | PGD3 头：x@4,y@6,w@8,h@10,bpp@12,namelen@14,name@14..45,size@52,payload@56 | `ST01A_A020.PGD` hexdump + `sub_100B9A50` |
| E17 | LZSS：8 位标志组、4 字节步进、2/3 字节两种匹配形式 | `sub_100C5820`（0x100c5820）完整反编译；dump 见 `pal5.txt` |
| E18 | 导出 `PalSpriteSaveTextureToPngFile` @0x100b6e60 / `…Png24File` @0x100b6ea0 | `Pal.dll` 命名导出表 |
| E19 | CN 补丁 LICENSE：非商用 / 不得修改衍生 / 不得逆向 | `DimensionToTsuLovers_cn/License/LICENSE.TXT` §2–3 |
| E20 | `.pswj` 头 = UTF-16LE "Package format made by Saint Serenata of World System …" | `Resource/*.pswj` 前 96 字节 |
| E21 | 特典 80 WAV / 48 kHz / 单声道 / 24-bit / 合计 303.2 s | `wave` 模块实测 |
| E22 | Eidolon 已有 `StaticStandManifest` + `installStaticStand` 绑定 `contentSetID` | `StaticStandManifest.swift`、`ContentRegistry+Eidolon.swift:214-240` |
| E23 | `content` 包仍强制 `episode_passages>0` | `ContentBundleInstaller.swift:351` |
| E24 | Fish：PVC ≥10 min / 单段 <1 min / 12–15 段；即时克隆 ≥10 s | docs.fish.audio（见 §6 链接） |
| E25 | Fish：`s2.1-pro` $15/M UTF-8 字节；ASR $0.36/h；并发 5/15/50 | docs.fish.audio Pricing & Rate Limits |
| E26 | 旧 `totsulover_dl/pack/data/` 提取错误（size 写成 offset） | `stat` 得 8,452 B vs 索引 size=47/offset=8452 |
| E27 | LZSS 解码器语义正确（8 位标志组、4 字节步进、2/3 字节两种匹配） | 自写解码器对 `ST01A_A010` 解出 **19,662,856 B**（= 头 @0x20 声明值，载荷恰好读完）；`MASK00` 解出 **2,765,528 B**（= @0x20 声明值）；两者均满足 `8 + h + w*h*4` |
| E28 | `PGD3` = 按 (x,y,w,h) 的 XOR 差分补丁 | `st.pac` 随机 12 张 PGD3：12/12 像素区长度 `== w*h*4`；零像素 55.6%–97.3%；`raw_size@0x30 == h + w*h*4`（示例 51,429 = 93 + 138*93*4） |
| E29 | `st.pac` 结构 = 169 张 `GE ` 底图 + 2,563 张 `PGD3` 补丁 | 对 2,732 条目按前 4 字节分类 |
| **E30–E51** | **CHS v1.1 补丁**的全部证据（RPCK 布局、`id+1` 对齐、255 个单元锚点、名字 id、标签迁移、许可、无密钥） | **见 §12.9**（编号在本文内连续） |

---

## 10. 安全 / 法务红旗

| # | 事项 | 处置 |
|---|---|---|
| R1 | **旧**汉化补丁 LICENSE 禁止逆向/衍生 | 不解 `.pswj`、不并译文、不把补丁文件放进内容包（§4 已给合法路径） |
| R2 | 游戏素材版权（CRYSTALiA / AMUSE CRAFT） | 素材/文本/语音**一律不进公开仓库**；只进 `tools/` 已 ignore 的本机目录或内容包 |
| R3 | 声优声音的人格权（パブリシティ権） | 克隆只限本机私人使用；任何分享/上架改用 Voice Design 或授权声音 |
| R4 | Fish ToS：提交内容授予 Fish 永久可转授权 | 上传游戏音频前先确认这一点（这也是"本地 vs 云"要分开的原因） |
| R5 | 本仓库是公开仓库 | 报告内不写剧情原文、不写译文、不写设备 UDID/主机名/内网地址 |
| R6 | 体积 | 全量内容包（文本+embedding+立绘+语音）会到 GB 级；**必须分片**（content / stand / voice 三个包），不要做单一 zip |
| **R7** | CHS v1.1 的译文是 **CC BY-NC-SA 4.0**：非商用 + 署名 + 相同方式共享 | 本机自用没问题；一旦把含译文的包发给别人，包本身要带 CC BY-NC-SA + 「Can/need 8th Project」署名，且**不能含游戏素材**。不准卖、不准上架 |
| **R8** | CHS v1.1 的二进制**无 Authenticode 签名**（证书目录为 0），闭源，启动器还会改写游戏 exe（LAA） | 我们的管线**只读** `totsulover.dll` 抽数据，不运行它；用 §12.1 的 SHA-256 锁定版本 |
| **R9** | 472 张 `.PGD`（含 6 张带字 CG、256 张用语集图）+ 9 张带字背景 JPEG 是「原作美术 + 译文」的改图，版权最脏 | **不进任何包**；Eidolon 用自己的 UI |
| **R10** | 译文/`STRINGS.JSON` 若被提交进本仓库，等于把仓库变成译文分发点 | 产物只进 `/tmp` 或 `tools/` 已 ignore 目录；`git status` 里不许出现 `STRINGS.JSON` / `*.json`（来自 canneed） |

---

## 11. 与上一份调研（2026-11-11）的差异

| 上一份结论 | 本次核实 |
|---|---|
| `.MIX` 是"台词→语音"映射 | ❌ 实为**多角色语音组**（14 组，32 B 槽） |
| `#135` 的 kind 分流"待做" | ❌ 已实现（`ContentBundleInstaller.swift:34`），但 `content` 仍要求非空 passages |
| `contentSetID`/`characterKeys` 未落地 | ❌ 已落地；另有 `StaticStandManifest` + `installStaticStand` |
| `.PGD` 是"私有 LZ/Huffman，1–3 人日" | ✅ 已实测：**LZSS + 按矩形 XOR 差分**；`ST01A_A010` 19,662,856 B 逐字节对得上，12/12 抽样通过；`st.pac` = 169 张 GE 底图 + 2,563 张 PGD3 补丁 |
| 场景边界"需要 VM，风险最高" | ❌ **已被 CHS v1.1 的数据结构旁证推翻**：`TEXT.DAT` 里 255 个单元名各自唯一 → 边界可静态切；说话人是紧邻台词的独立 id（§12.4.3）。VM 只为 voice id 还需要 |
| 中文译文"只能自制或等官方" | ❌ 多了一条合法路：Can/need CHS v1.1，明文 `{id: zh}` + CC BY-NC-SA + 允许移植（§4.1、§12.7） |
| 「汉化补丁不得逆向、不可用」 | ⚠️ 只对**旧**补丁成立；新补丁不用逆向，译文在公开仓库（§12.5） |
| P3 2 d / P4 3–5 d / 总 14–20 人日 | ❌ 更新为 P3 0.5–1 d、P4 1–2 d（移出关键路径）、总 **10–14 人日**（§7） |
| 素材规模 3.31 GB / 4.1 GB | ✅ 与实测一致（另有 417 MB 特典 + 160 MB opening） |

---

## 12. 新汉化组 CHS v1.1 补丁分析（2026-11-12 追加）

> 本节替代 §2.10 / §4 中关于汉化补丁的判断。§2.10 分析的是旧补丁 `DimensionToTsuLovers_cn`（`.pswj` 容器 + 自有许可）；本节分析的是**另一个组**的 `totsulover_CHS_v1.1`，两者的数据结构、许可、可迁移性完全不同，**不要混用结论**。
>
> 合规：本节只做结构识别与统计，**未把任何译文/素材/密钥写进仓库**。所有解析都在 `/tmp/eidolon-re-chs/`，只保留 `id`、计数、标签语法、偏移这类结构样本。补丁与游戏本体全程只读。

**结论先行**：中文文本**只用 CHS v1.1**。它把旧补丁的三个死结一次解开——① 译文是明文 `{TEXT.DAT id → 中文}`，不用逆向 `.pswj`；② 键与 `TEXT.DAT` 的差 1 关系可用 2.4 万条引号做 100% 断言；③ 255 个脚本单元名就是精确的 scene 边界，说话人由紧邻的名字 id 给出。许可也从「禁止衍生」变成 **CC BY-NC-SA 4.0 + 明确允许做移植版**。

### 12.1 清单与结构

补丁根目录 `Galgame support/totsulover_CHS_v1.1/`，合计 **275.7 MB / 292 个文件**（字节相加；`du` 按块报 263 MiB），分三块：

| 位置 | 内容 | 事实 |
|---|---|---|
| `Mod本体/` | 5 个文件，266.6 MB | 真正要覆盖进游戏根目录的东西（§12.2） |
| `canneed-oss/` | 255 个 `.json` + 一个 `.git` | 译文**源仓库**（CC BY-NC-SA 4.0），不是运行所需（§12.5） |
| `如果你们实在是找不到PKG版的游戏本体的话/` | `totsulover.exe` 1,152,512 B | PKG 版主程序，SHA-256 `d33b6774…`；其哈希**被硬编码在启动器里**（§12.3） |

`Mod本体/` 逐文件（实测，`shasum -a 256`）：

| 文件 | 字节 | SHA-256（前 16） | 性质 |
|---|---|---|---|
| `totsulover.dll` | 79,514,112 | `085c535a59778b19` | 注入用 DLL；**译文和替换素材全在它的 RCDATA 里** |
| `totsulover_chs.exe` | 273,920 | `ba1f7afc3a3adfa2` | 启动器（校验主程序 → 打 LAA → 注入） |
| `FONT.TTF` | 25,227,744 | `1b74667333612eb0` | **LXGW WenKai Medium / 霞鹜文楷**（OFL），46,788 字形 |
| `movie/opening_chs.mpg` | 161,540,096 | `7ea3e15fe12ca5af` | MPEG-1 system，带中文字幕的 OP |
| `汉化说明&常见问题检查单.txt` | 6,563 | `19e520a29088e966` | UTF-8 / CRLF / 126 行；安装说明 + 声明 + Staff |

**安装说明（原文要点，`汉化说明&常见问题检查单.txt`）**：

| 行 | 要求 |
|---|---|
| :4 | 「本Mod仅在PKG版可用」，且要先装官方更新补丁；DL 版玩家要用补丁附带的 PKG 主程序覆盖 DL 主程序 |
| :5 | 游戏内「设置-字体样式」被屏蔽；要换字体只能替换 `FONT.TTF` |
| :6 | 使用前**清空 `save` 文件夹**，否则「无法开启原文显示功能」 |
| :7 | 全选 Mod 文件粘到游戏根目录，双击 `totsulover_chs.exe` 启动 |
| :10–13 | 首发可选「显示原文」；关闭=删 `save/OriginalTextFlag`；开启=手动建同名空文件或删档重来；自述「实验性功能」，切界面/回标题时原文可能不消失 |
| :18 | 「无法在已打其它非官方Mod的版本上使用」→ 与本作旧补丁**互斥** |
| :43–50 | 声明：不得换钱；转载/引用须标注来源；**允许**在标注来源前提下直播录播、**基于本Mod做移植版本** |

> 第 50 行「在标注来源的前提下基于本Mod制作移植版本」是本项目最相关的条款：作者**预置**了移植许可（仍需署名、仍不得商用）。这与旧补丁「不得修改/衍生/逆向」是相反的态度。

### 12.2 格式：不是 PAC 替换，是「DLL 内嵌 RPCK 覆盖层 + 运行时按文件名顶替」

**结论**：CHS v1.1 **不改** `.pac`、**不改** `TEXT.DAT`、**不改** `SCRIPT.SRC`，也不用 `.pswj`。它是「外挂 DLL + 自有容器 + 运行时文件顶替」，磁盘上只有主程序被改了 1 个 bit（LAA，见 §12.3）。

#### 12.2.1 `totsulover.dll` 的 RCDATA = `RPCK` 容器（实测 + 反编译）

DLL 的 `.rsrc` 里只有一个自定义资源 `type=10 (RCDATA) / name=1001 / lang=0`，**79,150,278 B**。其头部：

```
0x00  "RPCK"                  magic 0x4B435052
0x04  u32 version = 1
0x08  u32 count   = 486
0x0C  count × 12 B  { u32 name_off; u32 type; u32 data_off; }
      name_off 区（0x16D4 起，紧接索引之后，NUL 分隔的 8.3 名字）
      data_off 区（0x33F6 起，至 79,150,278）
```

校验：`12 + 12*486 = 5844 = 0x16D4` 恰为第一个名字偏移；末条 `data_off` = 79,148,643，末尾 1,635 B 即最后一条 `TIPS.CSV`。`type` 只有两种：**3 = zstd 帧**（前置 u32 长度，随后 `28 B5 2F FD`；多数等于解压长度，但 `STRINGS.JSON` 的前缀是 3,100,634、实际解到 3,102,170 —— **别拿它当分配上界，以 zstd 输出为准**），**1 = 裸数据**（9 张 JPEG 里有 7 张）。

反编译侧对上了：`0x10008380` 处的函数 `cmp (%esi), 0x4B435052` → `mov 0x8(%esi), %esi`（count）→ `lea (%esi,%esi,2)` 再 `<<2`（= count×12）→ 与缓冲区尾部比较，正是上表布局。

| 统计 | 值 |
|---|---|
| 条目 | 486 |
| zstd 帧（type 3） | 479 |
| 裸文件（type 1） | 7（均为 JPEG） |
| 压缩后 | 75.5 MB |
| 解压后 | 316.5 MB（zstd 部分）+ 9.0 MB（裸 JPEG） |
| 扩展名 | `.PGD` 472、`.JPG` 9、`.CSV` 2、`.TGA` 1、`.INI` 1、`.JSON` 1 |

#### 12.2.2 覆盖的是哪些原文件（实测：486 条里 483 条与原始归档同名）

把 17 个 `.pac` 的条目名建索引（30,039 个名字），逐一比对：

| 来源归档 | 被顶替的条目 | 说明 |
|---|---|---|
| `tips.pac` | 256 | **全部**用语集图（128 条 × S/B 两图）；另有 27 张 `TIPS_*` 底图/图标对位 `system.pac` + 2 张新增 |
| `system.pac` | 196 | UI 按钮/标题/存档/读档/收藏/回想/声音/BGM 界面（含 `FONT_EX.TGA`） |
| `etc.pac` | 11 | 事件特效图（`ETCEV_049A01..05` 等 6 张带字演出图 + 5 张 `KIM*`） |
| `bk.pac` | 10 | `BK103A/B/C/E`、`BK911A` 及其 L 尺寸 `BKL*`（带文字的招牌/背景） |
| `ev.pac` | 6 | `EV101A01..E01`：带字 CG |
| `csv.pac` | 3 | `SYSTEM.INI`、`MUSIC.CSV`、`TIPS.CSV` |
| `patch.pac` | 1 | — |
| **新增** | 3 | `TIPS0128S.PGD`、`TIPS0128B.PGD`、`STRINGS.JSON` |

**没有**任何 `.OGG`、`.MPG`、`.ANI`、`.MIX`、`.DAT`、`.SRC` 条目 → 语音（`voice.pac` 22,135 条）、BGM、SE、脚本、`TEXT.DAT`/`POINT.DAT`/`FILE.DAT` 全部**未被触碰**。唯一的影像替换是散装文件 `movie/opening_chs.mpg`：DLL 里同时存在 `opening.mpg` 与 `opening_chs.mpg` 两个字符串，即**运行时改名读取**，原 `opening.mpg` 不动。

#### 12.2.3 两个可执行文件的分工（实测 + 反编译）

`totsulover_chs.exe`（启动器，`ProductName=softpalPatchLauncher`）：

- 导入 `bcrypt`（`BCryptOpenAlgorithmProvider/CreateHash/HashData/FinishHash`）→ 对主程序做 SHA-256；
- **`Mod本体`附带的 PKG 主程序的 SHA-256 以明文 32 字节嵌在启动器里**（实测 `sha256(pkg_exe) in launcher == True`；DL 的 `totsulover.exe`、`totsulover_crack.exe` 的哈希都**不在**其中）→ 白名单只有这一份主程序；
- 导入 `CreateProcessW` / `VirtualAllocEx` / `WriteProcessMemory` / `ReadProcessMemory` / `VirtualProtectEx`，外加 `.detourc` / `.detourd` / `.fptable` 三个节（Microsoft Detours 的特征节）→ 改主程序内存并注入 DLL；
- 只读字符（UTF-16）：「检测到不受支持或已被第三方修改的 totsulover.exe。」「请恢复官方 PKG 盒装原版主程序，且不要使用任何破解补丁。」「为避免损坏游戏文件，补丁未启动。」「主程序未被修改。请检查游戏目录的写入权限，或移走同名的无效备份后重试。」「主程序未启动。请使用同目录的 .before-laa.bak 还原后再处理。」
- 字符串里还有 `totsulover.exe.before-laa.bak` 与 `softpalPatchLauncher`。

`totsulover.dll`（`ProductName=softpalPatch`）：

| 事实 | 证据 |
|---|---|
| 只导入 `USER32` / `GDI32` / `SHLWAPI` / `KERNEL32`，**没有任何网络 API**（无 ws2_32/wininet/urlmon/winhttp） | 导入表全量 |
| `FindResourceA` / `LoadResource` / `LockResource` / `SizeofResource` | 读自己的 RCDATA 1001（RPCK） |
| `AddFontResourceExW` / `RemoveFontResourceExW` + UTF-16 串 `FONT.TTF` | 安装霞鹜文楷（外挂文件，非内嵌） |
| Detours：只对 `Pal.dll` 的 `PalFontDrawText` 装钩子 | `0x1000c265` 处 `DetourFindFunction("PalFontDrawText")` → `DetourAttach(&0x10055e30, 0x1000b4b0)` |
| 对 `PalBoxBlurFilter` 先 `GetProcAddress`，再把它前 12 字节与 `0x459C8` 的 `55 8B EC 83 E4 F8 83 EC 1C 8B 4D 0C` 逐字节比对，通过才置标志 `0x10055e44` | 反编译 `0x1000c2bc`–`0x1000c31d`：**版本探测**，不是挂钩子 |
| 但对 `PalFontDrawText` 的钩子体只是一个空值检查后转发（`0x1000b4b0`–`0x1000b4d1`：`test ecx` / `test edx` / `jmp [0x10055e30]`） | 反编译；**文本替换不在这个钩子里** |
| 另有若干「特征常量 + 预期值」用于在目标模块里认版本：`.rdata 0x459A0` = `0F 84 98 00 00 00`、`0x459B8` = `0F 84 DC 00 00 00`、`0x459C0` = `90 90 90 90 90 90` + `55 8B EC`、`0x45988/0x4598C` = 两段 4 字节值 | 靠**特征码**而不是版本号；具体每个补丁点打在哪未逐个追（推断：把文本获取路径改到 DLL 自己的表） |
| 自带 `cJSON`（静态链接，且把 79 个 `_cJSON_*` 全导出） | 导出表；用于解析 `STRINGS.JSON` |
| 建窗 + `UpdateLayeredWindow` + `TextOutW` + `CreateDIBSection` | 「显示原文」的**分层外挂窗口**（配合 `SoftpalOriginalTextOverlay`、`OriginalTextFlag`） |
| 明文串：`STRINGS.JSON`、`\OriginalTextFlag`、`save`、`\system.dat`、`\FileDescription`、`version.dll`、`opening.mpg`、`opening_chs.mpg`、`Error initialize pack` | `.rdata` |
| 简体中文环境强制：`本程序只能在简体中文环境下运行。` / `使用 Locale Emulator 等工具以简体中文环境启动本软件。` / `是否使用全屏模式进行游戏？` / `是否在游戏中显示原文？` / `注：后续如果想关闭原文显示，就把save目录中的OriginalTextFlag文件删掉后重启游戏生效` | `.rdata`（UTF-16） |

一句话概括机制：**启动器校验主程序哈希 → 给 exe 打 LAA → 带 Detours 注入 DLL → DLL 从自己的 RCDATA 解出 RPCK 覆盖层，按文件名顶替 483 个原资源 + 供 `STRINGS.JSON` 查表 → 用 GDI + 霞鹜文楷画中文，并用分层窗口叠日文原文。** 不落地任何新的 `.pac`，不改 `TEXT.DAT`。

### 12.3 主程序被改的那 1 个 bit

三个 exe 的 `Characteristics` 实测：`Mod本体/totsulover_chs.exe` = `0x0102`、PKG 主程序 `totsulover.exe` = `0x0102`、DL `totsulover.exe` = `0x010F`、`totsulover_crack.exe` = `0x0102` —— **全都没有 `IMAGE_FILE_LARGE_ADDRESS_AWARE`(0x20)**。

结合 Staff 感言（`:85–87`：「什么叫4096*4096的立绘纹理加载太多给游戏整OOM了？我：（给二进制上了个LAA flag使其可以访问4GB的内存地址）」）与启动器字符串（`.before-laa.bak` + 三条失败提示），可以确定：**启动器在启动前把主程序的 LAA 位置 1（并备份原文件），退出后不还原**。这是本补丁唯一会写游戏本体的行为。

对本项目的含义：这条与我们无关（我们不跑它），但它解释了为什么补丁必须绑 PKG 主程序 + 必须可写目录；也说明 4,096×4,096 立绘纹理是本作的原生 OOM 点，端上做立绘时**不要**照搬这个量级。

### 12.4 中文文本怎么存、怎么对齐（本节最有价值的部分）

#### 12.4.1 `STRINGS.JSON` = `{TEXT.DAT id → 中文}`

RPCK 里的 `STRINGS.JSON`：外层 `[u32 原始长度=3,100,634][zstd]`（压缩后 887,264 B），解压 3,102,170 B，UTF-8：

```json
{ "76": "…", "77": "…", … }
```

实测：**68,539 个键** —— 68,538 个落在 `1..70111`，外加 1 个玩笑哨兵键 `1145141919`（值是一个 8 字符的无意义串，可丢弃）。`id` 空间与 `TEXT.DAT` 的 70,111 条**完全同域**，不是行号、不是文件序号。

#### 12.4.2 对齐关系是 **`STRINGS[k] ↔ TEXT.DAT id k+1`**（差 1，必须显式 +1）

这是最容易踩的坑：直接按 `id` join 会**全体错位一行**，而且错得"看起来很合理"。

判别实验（`TEXT.DAT` 里 24,734 条以 `「` 开头的台词）：

| 假设 | 译文也以 `「` 开头的比例 |
|---|---|
| `zh[k] ↔ ja[k-1]` | **24,734 / 24,734 = 100.0%** |
| `zh[k] ↔ ja[k]` | 0 / 24,734 = **0.0%** |
| `zh[k] ↔ ja[k+1]` | 18,946 / 24,734 = 76.6% |

结尾 `」` 同结论（24,737/24,737 = 100%）。所以：**`STRINGS` 的键 = `TEXT.DAT` id − 1**，等价地 `TEXT.DAT` 第 `n` 条的译文在 `STRINGS[n-1]`。打包工具全程用 0 基下标，`<dNNNN>` 术语标签的编号也是 0 基行号（但**不是**简单的 ±1，见 §12.4.4）。

> 这条要写进解析器的断言：`assert zh[k].startswith('「') == ja[k+1].startswith('「')` 在 2 万条规模上必须是 100%，否则说明偏移取错。

#### 12.4.3 覆盖率：脚本区几乎 100%

`TEXT.DAT` 的结构比旧报告写的更有用：**每个脚本单元的第一条 id，其内容就是单元名**（如 `001_共通ルート：０１`），而且这个名字在 70,111 条里**唯一**。255 个单元名 ↔ 255 个 `canneed-oss` 的 JSON 文件名，**一一对应、零缺失**。于是不用解 VM 就能拿到「单元 → id 区间」：

| 指标 | 值 |
|---|---|
| 脚本区 id 区间 | `1348 .. 69874`（68,527 条） |
| 其中已翻译 | 68,252（**99.60%**） |
| 未翻译 | 275，其中 **255 条正是单元名标记**（引擎大概不显示），另有 20 条零散 |
| 脚本区外未翻译 | 1,284 条（`1..1347`：字体名、`%d` 格式串、调试串）+ 14 条（尾部） |
| 说话人名 id | 28,402（脚本区，已译 28,399） |
| 台词 id | 40,125（脚本区），已翻译 39,853（**99.32%**） |
| 中文字符数（脚本区） | 695,679（项目源 JSON 是 646,752，差值是补上的名字与 UI） |
| 译文里残留假名 | **0 条**（全量扫描 `U+3040..U+30FF`） |

**说话人不需要解 VM**：`TEXT.DAT` 把「名字」本身也存成独立 id，紧挨在台词前（`[单元名][台词][名字][台词][名字]…`；旁白没有名字 id）。用「短、无引号、高频」筛出 64 个名字词表 → 全库 28,801 个名字 id（脚本区 28,402）；与 `canneed-oss` 的 `name` 字段逐单元比对，**169/255 个单元完全相等**，其余差 ±1..7（是我这份词表的漏筛，不是数据错）。总量上：脚本区名字 id 28,402 vs 项目里带 `name` 的条目 28,665。名字频次也逐一对上（`槐` 9,670 ↔ 项目 9,670；`ソフィア` 3,045 ↔ 3,045；`華淡` 2,836 ↔ 2,834）。

这直接推翻旧报告 §3.3 的悲观判断：**「哪句话属于哪一幕、谁在说」在 CHS v1.1 的数据里已经是现成的**，只剩「哪句话配哪条语音」还需要 VM（voice id 不在 `TEXT.DAT` 里）。

#### 12.4.4 标签/排版：五处差异，必须显式处理

| 标记 | 日文（`TEXT.DAT`） | 中文（`STRINGS`） | 处置 |
|---|---|---|---|
| `<br>` 换行 | 13,910 条（共 13,916 个） | **0 条** | 译文完全不带换行；必须由客户端折行（**不要**照抄日文的 `<br>` 位置，见 §12.4.5） |
| `<r…>` 注音 | 432 条 | 19 条 | 绝大多数被丢掉；中文本来也不需要假名注音，建议整体丢弃并在渲染层禁用 ruby |
| `<sNN>` 字号 | 39 条 | 39 条 | 完整保留，可直接沿用 |
| `<dNNNN>` 术语 | 128 条（`<d0000>`..`<d0127>`） | 129 条（`<d0000>`..`<d0128>`） | **编号被整体重排**，见下 |
| `%d` 插值 | 254 条 | 0 条 | 253 条落在脚本区外（系统/格式串），唯一落在脚本区的 1 条也没翻译 → 台词层不需要 `%d` 处理 |

`<dNNNN>` 的语义实测确定了：**`NNNN` 是 `TIPS.CSV` 的 0 基行号**（不是 `tips0005` 这种 tips id）。原版 `TIPS.CSV` 128 行；补丁把它**重新排序并扩到 129 行**，所以同一个词条的 tips id 没变（仍是 `tips0005S/B`），但行号从 5 挪到 19 —— 台词里的 `<d0005>` 因此被改写成 `<d0019>`。**这是重排，不是平移**，逐条映射只能靠 tips id 反查。所以：

> **迁移时不能把日文的 `<dNNNN>` 直接搬到中文上**。两条路：① 采用补丁的 `TIPS.CSV`（GB18030、129 行、读音列被填成同一个占位字），保持中文标签不动；② 保留原版 `TIPS.CSV`，用 `tips0005` 这个 id 做桥把中文标签编号映射回原行号。②更干净，代价是要多写 10 行映射。

另外 `TIPS.CSV`、`SYSTEM.INI` 都被转成了 **GB18030**（原版 `TEXT.DAT`/CSV 是 cp932）。`SYSTEM.INI` 与原版逐行 diff，实际只改了 6 处：

```
DEF_FONT_TYPE   4 → 1          （并在 UI 里屏蔽「字体样式」选项）
DEF_MASTER_VOLUME 90 → 100
DEF_BGM_VOLUME    35 → 50
DEF_AUTO_VOLUME   60 → 100
SAMPLE_TEXT     "…" → 一句中文（设置界面的字体预览样例）
若干注释里的「・」因 GB18030 转码变成「?」（仅注释，无功能影响）
```

`MUSIC.CSV` 33 行里只有 1 行不同，而且是个**转码事故**：第 0 行的曲名从正常的日文标题变成半角片假名乱码（`ディメンション凸ラバース!!` → `ｴﾎﾔｪﾍｹﾆﾆﾁｵﾕｽｼｧ!!`，cp932 往返 GB18030 时被拆成半角）。→ **不要继承它的 `MUSIC.CSV`**；这个文件跟汉化无关，只是被打包器顺手带进去了。

#### 12.4.5 排版与体量风险（用数据说话）

| 指标 | 日文 | 中文 |
|---|---|---|
| 每行字符数 均值 / 中位 / P95 / 最长 | 21.5 / 18 / 44 / 92 | **16.2 / 15 / 32 / 68** |
| 中文/日文字符比 | — | **0.75** |

中文比日文短 25%，**文本框宽度不是风险**；真正的风险是 ① 没有 `<br>`（13,910 行原本靠它控制两行显示），② 中文没有假名，行内节奏变了，逐行对齐语音时会出现「中文念完了语音还在响」——需要按语音时长做停留策略，而不是按字符数。

### 12.5 `canneed-oss`：译文源仓库（可审计，这是与旧补丁最大的差别）

- 来源：`canneed-oss/项目仓库.md` → `https://github.com/colorfulkurumi/canneed-oss/tree/master/Project008Totsulover`；本地是完整 git 克隆，`HEAD = 0eb9e28`（2026-09-25），11 个提交（首个 2026-06-02）。
- 内容：`Project008Totsulover/{0共通,1樱,2华淡,3索菲亚,4水仙,5真结局}/` 共 **255 个 `.json` / 39,808 条 / 646,752 中文字 / 153 个不同 `name`**。
- 每条是 `{"name": 说话人, "message": 台词}`，**没有 id 字段**——顺序即脚本顺序；`name` 只在 28,665 条里出现（旁白省略）。
- 文件名的数字前缀（`001_共通ルート：０１`）就是 `TEXT.DAT` 里的单元名，所以**文件名本身就是对齐锚点**。
- 仓库根 `README.md`：「Due to potentially copyright issues, we will only post translated texts here」+「All texts in this repository is licensed under the [CC BY-NC-SA 4.0] license.」；根 `LICENSE` 是 CC BY-NC-SA 4.0 全文（工作区里没 checkout 出来，从 git 对象读到）。
- 工作区里**只有 JSON**（255 个）+ `项目仓库.md`（+ `.DS_Store`）；git 里另有 `LICENSE` / `README.md`。没有 exe/dll/pac/图片 → 补丁二进制是另一个产物，不在开源范围内。

注：`STRINGS.JSON` 与源 JSON 有 2.4% 的条目对不上（38,838/39,808 逐字相同），对应 v1.1 的「优化翻译质量」——**以 DLL 里的 `STRINGS.JSON` 为准**，源仓库只用于交叉校验与补缺失。

### 12.6 迁移步骤（可直接排期）

#### 12.6.1 提取管线

```sh
# 0) 只读复制到 /tmp，不动原目录
cp "…/totsulover_CHS_v1.1/Mod本体/totsulover.dll" /tmp/eidolon-re-chs/
# 1) 抽 RCDATA 1001（type=10 / name=1001）：PE 资源目录 → data entry → RVA→文件偏移
#    偏移 = 0x55EA0，长度 = 79,150,278（本版本固定；用脚本按资源目录解析，别硬编码）
# 2) 解 RPCK：'RPCK' + u32 ver + u32 count + count*12 索引 + 名字表 + 数据
# 3) 每条：[u32 raw_size][zstd] → zstd -d；type==1 时是裸文件
# 4) STRINGS.JSON → json.load → {int(k): v}
# 5) 断言：zh[k] 与 ja[k+1] 的「」首尾一致率 == 100%
```

必做校验（每条都能自动跑）：

| 检查 | 判据 |
|---|---|
| RPCK 索引 | `12 + 12*count == 首个 name_off`；`count == 486` |
| zstd 帧 | 479 条 `28 B5 2F FD`；解压长度 == 前缀 u32（`STRINGS.JSON` 例外：前缀比实际短 1,536 B） |
| 覆盖层对位 | 486 条中 483 条能在 17 个 `.pac` 里找到同名条目 |
| id 偏移 | `「` 首/`」` 尾一致率 **100%**（错 1 位就会掉到 0%） |
| 单元锚点 | 255 个单元名在 `TEXT.DAT` 中各出现**恰好 1 次** |
| 覆盖率 | 脚本区已翻译 ≥ 99%；残留假名 == 0 |
| 标签 | `<sNN>` 39/39；`<dNNNN>` 需重映射后才可用 |

#### 12.6.2 合成 `(ja, zh, speaker)` 三列

1. 按 §12.4.2 把 `STRINGS` 平移到 `TEXT.DAT` 的 id 空间；
2. 用 255 个单元名切 `episode`，`episode.title` 直接用单元名（日文原样；中文标题可另取）；
3. 名字 id → `speaker`：`episode_cast` 用 64 个名字词表建，`seq` 用单元内顺序；
4. 台词 id → `episode_lines.ja`（cp932 解码）+ `.zh`（+1 后的 `STRINGS`）；
5. `speaker` 落不到名字 id 的，标 `narrator`（旁白），**不要**猜。

#### 12.6.3 内容包 vs 立绘包 vs 本地

| 产物 | 进哪里 | 理由 |
|---|---|---|
| `eidolon.db`（`episodes`/`episode_cast`/`episode_lines{ja,zh,speaker,seq}`/`episode_passages`） | **content 包** | 纯文本 + 向量，和现有 installer 契约一致 |
| `characters.json` / `world.json` / `places.json` | **content 包** | 与 ja 源同源；中文名/术语来自 `STRINGS` 与 `TIPS.CSV` |
| 立绘 PNG（`st.pac` → 合成 → 7 表情） | **stand 包** | 与 CHS v1.1 **无关**（它没动 `st.pac`） |
| 语音 Opus（`voice.pac`） | **本地/voice 包** | 补丁也没动语音；中文不含配音 |
| 472 张 `.PGD` + 9 张带字背景 JPEG + `opening_chs.mpg` + `FONT.TTF` | **不进任何包** | 那是「给原游戏换皮」，Eidolon 有自己的 UI；带字 CG 是原作美术的改图，版权最脏 |
| `totsulover.dll` / `totsulover_chs.exe` / `STRINGS.JSON` 原文件 / 255 个源 JSON | **只在 `/tmp`，不进仓库** | 译文与二进制都不入库（CC BY-NC-SA 也不改「公开仓库不放译文」的规矩） |

#### 12.6.4 与旧补丁（`DimensionToTsuLovers_cn`）的差异

| 维度 | 旧补丁 `DimensionToTsuLovers_cn` | 新补丁 `CHS v1.1` |
|---|---|---|
| 体积 / 文件数 | 31 MB / 18 个 | **275.7 MB / 292 个** |
| 译文容器 | `.pswj`（UTF-16LE 头 + 不透明载荷）+ 3 个 `.sign` | `RPCK` → zstd → **明文 JSON `{id: zh}`** |
| 译文可否审计 | ❌ 加密/签名，逆向被许可禁止 | ✅ 明文，且源仓库公开（CC BY-NC-SA） |
| 对齐 | 未知（未解码） | ✅ 键 = 文本 id−1，2 万条规模 100% 可验 |
| 文本注入 | 外挂 DLL + 自带 ffmpeg/SDL3 播放器 | DLL inline patch + GDI 绘制 + 分层原文窗 |
| 字体 | 微软雅黑 22（INI 配置） | **霞鹜文楷 TTF**（OFL，可再分发） |
| 影像 | 替换播放路径（自带解码器） | 换文件名读 `opening_chs.mpg`（MPEG-1 原样） |
| 主程序 | 需 `totsulover_crack.exe`（脱壳） | 需**原版 PKG 主程序**（SHA-256 白名单），并打 LAA |
| 许可 | 非商用 / **不得修改衍生** / **不得逆向** | CC BY-NC-SA 4.0（译文）；Mod 本身：不得换钱、须署名，**允许做移植版** |
| 对本项目 | 只能当「存在中文」的证据，不能用 | **可用**（见 §12.7） |

### 12.7 法务与安全

#### 12.7.1 许可原文（短引，事实性）

`canneed-oss/LICENSE`（CC BY-NC-SA 4.0 全文）与 `canneed-oss/README.md`：

> 「All texts in this repository is licensed under the CC BY-NC-SA 4.0 license.」
> 「Due to potentially copyright issues, we will only post translated texts here, and provide no support in integrating them into specific games.」

`汉化说明&常见问题检查单.txt:43-50`：

> 「1.直接拿Mod或Mod的任何部分换取金钱收益」「2.以任何形式引用转载的同时不标注Mod来源（包括作品名、组名、任意原始发布链接）」
> 「除了上述1和2的其他行为，包括但不限于：1.在标注来源的前提下直播、录播本Mod内容 2.在标注来源的前提下基于本Mod制作移植版本」

#### 12.7.2 能不能用、能用到什么程度

| 想做的事 | 许可结论 | 判断 |
|---|---|---|
| 本机把 zh 并进内容包自用 | ✅ CC BY-NC-SA 允许复制/改编，非商用 | **可以**（仍受原作版权约束，只能本地） |
| 在公开仓库提交译文/`STRINGS.JSON` | ⚠️ 许可允许（须署名 + 相同方式共享），但违反本仓库「不放译文」的硬约束，且会让仓库变成译文分发点 | **不做** |
| 把内容包发给别人（非商用、署名、同协议） | ⚠️ 译文这一层可以；**游戏素材（文本原文/立绘/语音）这一层不行** | 只发「补丁+脚本」，不发成品包 |
| 卖 / 上架 / 内购 | ❌ 违反 NC，也违反 Mod 声明第 1 条 | **禁止** |
| 解 `totsulover.dll` 拿译文 | ✅ 译文本身在公开仓库，**不需要逆向**；但逆向二进制仍属灰区 | 走 JSON 路线，不逆向 DLL 逻辑 |
| 用 `FONT.TTF` | ✅ SIL OFL（霞鹜文楷） | 可用，保留 OFL 声明 |
| 用 472 张 `.PGD`（UI/用语集/带字 CG）+ 9 张带字背景 | ⚠️ 那是「原作美术 + 译文」的改图，比纯文本更敏感 | **不用** |

结论：**CHS v1.1 把「能不能用中文文本」从「不能」变成了「非商用可以，须署名 Can/need，衍生同样 CC BY-NC-SA」**。这足以支撑「本地自用 + 未来可分享补丁脚本」的方案，但仍不足以支撑「公开分发含素材的成品包」。

署名建议（写进 `NOTICE`/包内 `credits`，不进 git 的译文文件）：

```
Chinese translation: Can/need 8th Project — CC BY-NC-SA 4.0
https://canneed.eu.org  /  https://github.com/colorfulkurumi/canneed-oss
```

#### 12.7.3 安全

| 项 | 事实 | 处置 |
|---|---|---|
| 签名 | `totsulover.dll`、`totsulover_chs.exe` **均无 Authenticode**（证书目录 rva/size = 0） | 只能靠 SHA-256 自证；用 §12.1 的哈希锁定版本 |
| 网络 | DLL 只导入 USER32/GDI32/SHLWAPI/KERNEL32，**无任何网络 API**；启动器只导入 bcrypt | 静态看无回传；但仍是闭源二进制，**不要在装有敏感环境的机器上跑** |
| 写盘 | 启动器会改主程序 LAA 位（备份 `.before-laa.bak`）；DLL 读写 `save/OriginalTextFlag`、`save/system.dat` | 我们的管线**只读 DLL**，不运行它，不触发这些写 |
| 密钥 | 全量扫描补丁目录（`sk-`/`AKIA`/`ghp_`/`api_key`/`Bearer`）**0 命中** | 补丁里不含任何凭据 |
| 供应链 | `canneed-oss/.git` 4.4 MB，来源可核对到 GitHub | 只取 JSON，不执行仓库内任何脚本（仓库里也没有脚本） |
| 旧下载目录遗留 | 早期版本曾在 `totsulover_dl/frida_handler.py` 看到明文第三方 API key；它不属于 CHS v1.1，本报告不复制值 | 与补丁无关，但建议所有者轮换该 key 并移出共享目录 |

### 12.8 对既有结论的修正

| 旧结论（§2.10 / §4 / §5.4 / §7 / §8） | CHS v1.1 之后 |
|---|---|
| 「汉化补丁 = `.pswj` 加密容器，不得逆向，不得作为译文来源」 | 对**旧补丁**成立；对 **CHS v1.1 不成立**——它是明文 `{id: zh}`，源仓库 CC BY-NC-SA |
| 「对齐/说话人是最大风险，要 3–5 d 解 VM」 | 对齐已解决（键 = id−1，100% 可验）；说话人可由 `TEXT.DAT` 的名字 id 直接得到。**VM 只剩「台词→voice id」一个用途** |
| 「70,111 条 = 剧情行数」 | 仍是错的：脚本区 68,527 条里 28,402 是名字 id、40,125 是台词、255 是单元名 |
| 「场景边界要靠 `POINT.DAT` 的 8,786 锚点猜」 | 255 个单元名是**精确边界**，`POINT.DAT` 降级为校验用 |
| 「译文要自己翻或等官方中文」 | 多了一个合法选项：Can/need 的 CC BY-NC-SA 译文（非商用、署名、同协议） |
| 工期 P3（H1 切分）2 d | 降到 **0.5 d**（单元名直接切） |
| 工期 P4（VM 解码）3–5 d，卡关键路径 | 降级为「只为 voice id」的 **1–2 d 可选任务**，不再卡关键路径 |

### 12.9 本节证据表

| ID | 论断 | 来源（可复查） |
|---|---|---|
| E30 | 补丁 = `Mod本体`(5 文件) + `canneed-oss`(255 JSON) + PKG 主程序；275.7 MB / 292 文件 | `find`/`du`；§12.1 表 |
| E31 | `totsulover.dll` 79,514,112 B，SHA-256 `085c535a…`；`.rsrc` 内 RCDATA 1001 = 79,150,278 B | PE 头 + 资源目录解析 |
| E32 | RCDATA 是 `RPCK`：magic + u32 ver=1 + u32 count=486 + 486×12 索引 + 名字表 + 数据 | 头部 hexdump；`12+12*486 == 0x16D4` |
| E33 | 同一布局由反编译独立确认（`0x10008380` 起：`cmp $0x4B435052` → `count*12` 边界检查） | `objdump -d totsulover.dll`（`/tmp/eidolon-re-chs/dll.dis`） |
| E34 | 486 条 = 472 `.PGD` + 9 `.JPG` + 2 `.CSV` + 1 `.TGA` + 1 `.INI` + 1 `.JSON`；479 条 zstd、7 条裸 JPEG；解压 316.5 MB | 逐条解析 |
| E35 | 483/486 条与 17 个 `.pac` 现有条目同名（tips 256 / system 196 / etc 11 / bk 10 / ev 6 / csv 3 / patch 1），3 条新增 | 30,039 条名字索引比对 |
| E36 | 覆盖层**不含**任何 OGG/MPG/DAT/SRC/MIX/ANI → 语音、BGM、SE、脚本、`TEXT.DAT` 未被替换 | 扩展名统计 |
| E37 | `STRINGS.JSON` = `[u32 3,100,634][zstd]` → 3,102,170 B UTF-8；68,539 键（68,538 在 1..70111 + 1 哨兵） | zstd 解压 + `json.load` |
| E38 | 对齐 = `STRINGS[k] ↔ TEXT.DAT id k+1`：`「` 首 24,734/24,734=100%，错位 0 时 0% | `TEXT.DAT` 解析 + 三条假设对照 |
| E39 | 255 个单元名在 `TEXT.DAT` 各出现恰好 1 次，且与 255 个 JSON 文件名一一对应 | 名字集合比对 |
| E40 | 脚本区 68,527 条，已译 68,252（99.60%）；未译 275 中 255 是单元名；残留假名 0 | id 区间统计 + 假名扫描 |
| E41 | 名字 id = 独立 `TEXT.DAT` 条目、紧邻台词；脚本区 28,402 个；频次与项目 `name` 逐一对上（如 9,670↔9,670） | 词表筛选 + 逐单元比对（169/255 精确相等） |
| E42 | `<br>` 13,910→0；`<r…>` 432→19；`<sNN>` 39→39；`%d` 254→0 | 标签计数 |
| E43 | `<dNNNN>` = `TIPS.CSV` 0 基行号；补丁重排 TIPS（128→129 行），同词条 5→19 行，故 `<d0005>`→`<d0019>` | `TIPS.CSV` 原版 vs 补丁版（GB18030）逐行对照 |
| E44 | `SYSTEM.INI` 仅 6 处实质改动（`DEF_FONT_TYPE 4→1`、三处音量、`SAMPLE_TEXT`、注释 `・`→`?`） | 逐行 diff |
| E45 | `FONT.TTF` = LXGW WenKai Medium / 霞鹜文楷，46,788 字形，`name` 表 platform 3 / lang 2052 | TrueType `name`/`maxp`/`cmap` |
| E46 | 启动器内嵌 PKG 主程序 SHA-256；DL `totsulover.exe` 与 `totsulover_crack.exe` 的哈希**不在**其中 | `sha256(pkg) in launcher == True` |
| E47 | 三个 exe 都无 LAA 位；启动器字符串含 `.before-laa.bak` 与三条失败提示；Staff 感言自述打 LAA 解决 OOM | `Characteristics` = 0x102/0x10F；UTF-16 串 |
| E48 | DLL 只对 `PalFontDrawText` 装 Detours 钩子，且钩子体只是空值检查后转发；`PalBoxBlurFilter` 只做 12 字节 prologue 比对（版本探测） | `0x1000c265` 安装序列 + `0x1000b4b0` / `0x1000c2bc` 反编译 |
| E49 | DLL 只用 GDI 画字（`TextOutW`/`CreateDIBSection`/`UpdateLayeredWindow`）+ `AddFontResourceExW` 装 `FONT.TTF`；无网络导入 | 导入表全量 |
| E50 | `canneed-oss` = CC BY-NC-SA 4.0；`HEAD 0eb9e28`（2026-09-25）；仅 JSON，无二进制 | `git show HEAD:LICENSE`、`README.md`、`git ls-files` |
| E51 | 补丁目录密钥扫描 0 命中 | 正则扫描（`sk-`/`AKIA`/`ghp_`/`api_key`/`Bearer`） |

---

## 13. 当前迁移范围与已生成产物（2026-11-12）

范围收窄为 **4 位女主**：夜乃桜、海漫華淡、ソフィア・ランカスター、崩月水仙。

其他角色只保留在 `episode_lines.speaker` 中作为剧情上下文，不生成角色卡、立绘或语音。用户本人映射为 `__producer__`（男主），不做角色卡、立绘或语音；当前共 **9,670** 条台词。

本轮已生成（均在 `build/`，不提交仓库）：

| 产物 | 内容 | 校验 |
|---|---|---|
| `build/eidolon-totsulover-full.eidolonpkg` | 255 个单元、39,803 行、13,351 段、4 角色、`contentSetID=totsulover.full.v1` | 模拟器安装成功，4 角色列表可见 |
| `build/eidolon-totsulover-sakura-full-stand.eidolonpkg` | 夜乃桜 14 张 PNG、6 个语义表情、绑定同一 `contentSetID` | 安装成功，预览返回 6 个表情路径 |
| `build/sakura-voice/` | VO01 的 159 段干净 WAV，12.04 分钟；Fish Audio PVC 门槛 10 分钟 | 仅本机试音/训练用 |

生成器：

- `tools/import_totsulover_story.py`：PAC → TEXT.DAT → CHS RPCK/STRINGS.JSON → 单元切幕 → 说话人/男主 → embedding API → content 包
- `tools/build_sakura_pack.py`：Sakura content + static stand 两个包
- `tools/prepare_fish_audio_dataset.py`：按 PAC 前缀提取/转 WAV/裁剪到目标分钟数

仍需注意：

- `VO01` 与夜乃桜的对应关系目前按通道顺序推定，正式训练前要用 `.MIX`/脚本 voice id 或人工试听确认。
- 其它 3 位女主的头像/人设仍是占位；剧情文本已包含她们。
- `<dNNNN>` 仍建议用原版 TIPS + `tips####` 桥接。
- 全量立绘（20 角色）不在此范围；当前只做 Sakura 的 static stand 链路。
