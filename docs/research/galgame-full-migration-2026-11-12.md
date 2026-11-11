# 全量迁移调研：`ディメンション凸ラバース!!`（T-Script / totsulover）

- 日期：2026-11-12
- 范围：`/Users/jacklin/Developer/IdeaProjects/Galgame support/ディメンション凸ラバース!!`（只读）、本仓库 worktree `dsh-659b97a2-fcd2` 的 `EidolonCore`/`EidolonIOS` 现状接缝、Fish Audio 官方文档。
- 目的：把这部作品**全量**（角色 + 立绘 + CG/背景 + 文本 + 语音 + 世界数据）迁进 Eidolon 的 `kind=content` + `kind=stand` 双包形态，并给出可执行的阶段计划。
- 性质：**调研结论，不是 spec、不是 ADR、不是已实现设计**。落地仍要走 grill → spec → implement。
- 合规声明：本次调研**没有运行游戏**、没有绕过任何保护、没有把素材/译文/语音/密钥/UDID 写进本仓库。所有解析产物都在 `/tmp/eidolon-re-full/`。汉化补丁只做了结构识别，未解码其内容。

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
| 汉化补丁 | `.pswj` 自定义签名容器（UTF-16LE 头 `Package format made by …`，三份 + 三份 `.sign`）；LICENSE 明确**非商用 / 不得修改或衍生 / 不得逆向** → 不得作为译文或结构来源 |
| Eidolon 现状 | 已具备 `kind`/`franchise`/`engineFamily`/`contentSetID`/`characterKeys` 与 **`StaticStandManifest`（PNG-per-expression）**、`installStaticStand` 的 `contentSetID` 绑定；installer 已按 `expectedKind` 分流，但 `content` 仍强制 `episode_passages > 0` |
| 最大风险 | 不是解码 `.PGD`，而是 **"哪句话属于哪一幕、谁在说"**：需要把 Sv20 的 68 条命令流解到"文本 + 说话人"两三个 opcode |

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
  DimensionToTsuLovers_cn/      汉化补丁（License/Plugin/Resource，见 2.10）
  movie/{LOGO,opening}.mpg      1.28 MB / 160.2 MB
  save/, save_cn/               空模板（868 + 560 个 0 长度/空记录）
  html_manual/playmanual.html   36 KB 说明书（无角色表）
../豪華版特典/                  417 MB：80 WAV + 176 PNG 壁纸
../AI翻译补丁/                  第三方 AI 翻译补丁（另一作者，未使用）
```

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

### 2.10 汉化补丁（`DimensionToTsuLovers_cn/`）

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

## 4. 汉化补丁：结构与对齐（只做结构，不取译文）

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
| **静态立绘包** | `StaticStandManifest.swift` | `format_version=1`、`kind=.stand`、`mode=full|delta`、`renderer="static"`、`characters[].expressions[emotion:path]`、`files` |
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

**切分策略（三档，按到手信息量递增）**：

| 档 | 边界 | 说话人 | 质量 | 依赖 |
|---|---|---|---|---|
| H1 启发式 | `POINT.DAT` 的 8,786 锚点 + 文本 id 的"跳跃"（id 不连续即新段）+ `<br>` 分页 | `narrator`（全部） | 能用但粗，适合先跑通 embedding | 无 |
| H2 半解 | 解出 `0x20013` 的 4 个操作数（文本 id/说话人/voice id/延时） | 真实 speaker | 可用 | §3.3 S-b/S-d |
| H3 全解 | 68 命令全部语义化，按"场景切换/章节标题/选择支"切 | 真实 speaker + 情绪 | 最好 | §3.3 全流程 |

**建议**：先 H1 出 1 个可检索剧情库（验收 embedding + 检索），再 H2 替换 `speaker` 与 `seq`（**同一 `episode_id` 不变**，只 UPDATE，避免重跑 embedding）。

**passage/embedding 成本**：`episode_passages` 每段必须有非空 embedding（`ContentBundleInstaller.swift:327-330` 会拒）。70k 行 × 1536 维 float32 = **~430 MB**；若按 3 行一段，段数 ~23k，向量 ~140 MB。建议 `dimensions=1024`（硅基流动 bge-m3）→ ~95 MB。

**speaker 兜底**：拿不到 speaker 时，`episode_cast` 可以先用 `STAND.CSV` 的 `st→vo` 反推（每条 voice id 前两位就是角色），把"谁在场"写成 cast，而不是把 `speaker` 写成猜的名字。

### 5.5 语音 vs Fish Audio 训练

| 用途 | 用什么 | 理由 |
|---|---|---|
| **端上播放原声**（推荐先做） | `voice.pac` → Opus 48 kHz 单声道，按 `voice id` 存 | 24.55 h 真原声，零成本，情感/语气是原配 |
| **新台词 TTS** | Fish Audio `reference_id`（现有 `FishSynthesis`） | 与现有通话链路一致，一条 `voiceID` 就够 |
| **Fish 自训 PVC** | 特典 WAV（5.1 min，4 角色）+ `voice.pac` 精选（每角色 ≥10 min） | PVC 门槛 10 min；特典只有 76 s/人，**不够** |
| **本地自训（个人）** | `voice.pac` 每角色 2.9–4.2 h | 时长足够，但**转写未知**（见下） |

`voice.pac` 做训练集的**致命缺口**：文本 ↔ voice id 的映射还没解（§3.3）。三个绕法：

1. 用 Fish ASR（`transcribe-1-pro`，$0.36/音频小时）自动转写 24.55 h ≈ **$8.8**，一次性；转写错误用"游戏文本池"做约束校验（把 ASR 结果与 `TEXT.DAT` 做模糊匹配，命中率能当质量指标）。
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
| **P3 文本切分（H1）** | 8,786 锚点 + id 跳跃切 episode，`speaker=narrator` | `eidolon.db`（episodes/lines/passages） | 2 d | 检索命中率人工抽检 20 条、installer 通过 | 切分过碎/过粗 |
| **P4 VM 解码（H2）** | 68 命令语义表 + 帧格式 + 文本/说话人/voice id | `speaker`/`seq`/voice 映射 | 3–5 d | 1,000 条抽样 speaker 正确率 > 95%、voice id 能对上 Ogg | **最大不确定性**；可能卡在计算跳转 |
| **P5 语音包** | 22,135 Ogg → Opus + voice id 索引；按行挂语音 | `voice/` + `lines.voice_id` | 2 d | 任意一行能播对应 Ogg；端上 250 MB 内 | voice id 映射依赖 P4 |
| **P6 世界数据** | `TIPS.CSV` → `places`；手写 `facts/birthday/photoTag` | `world.json`/`places.json` | 1–2 d | `validatePlaces`/`validateWorld` 通过 | 人设需人工，不能批量抽 |
| **P7 Fish 音色** | D0/D1 数据集 → 每角色一个 reference；回填 `voiceID` | `characters.json` 的 `voiceID` | 1 d + $10 | 通话能出声、名字读音正确 | 法务（仅本地） |
| **P8 端到端** | 内容包 + 立绘包 + 语音 + 音色一起装 | 可玩切片 | 1 d | 真机：进剧情 → 检索 → 立绘换表情 → 出声 | 包体过大 |

**关键路径**：P0 → P1 → P2（立绘可见）与 P0 → P3（文本可检索）并行；P4 是唯一"可能推翻计划"的一步，建议**先做 3 天的 spike**，成功再排 P5。

**总工时**：约 **14–20 人日**（不含 P4 失败后的回退方案；图像解码从 4–6 d 降到 1–2 d）。

---

## 8. 开放问题

| # | 问题 | 影响 | 怎么解 |
|---|---|---|---|
| Q1 | Sv20 的帧格式（op 后参数宽度规则）？ | 决定 P4 成败 | §3.3 S-b：`sub_46DC50` 的调用者（VM 主循环） |
| Q2 | `0x20013` 的 4 个操作数各是什么？ | 文本 id/说话人/voice id | §3.3 S-d 的约束反推 |
| Q3 | `0x0C..0x334` 的 808 B 表是什么？ | 可能是常量池/重定位表，能省一半逆向 | 与同引擎其他作品对比 |
| Q4 | PGD3 的"两层 XOR"里谁是基图、顺序如何？ | P1 的 3 d vs 6 d | 用方案 A 的基准 PNG 反推 |
| Q5 | `st05..st20` 与角色名的逐槽绑定？ | 立绘包 `id` 命名 | 看 20 张首图（半天）或 Q2 解出名字板 |
| Q6 | `a..i` 9 表情的真实语义？ | 7 情绪映射 | 人工看 9 张图 |
| Q7 | `voice.pac` 里多少条含 BGM/SE 混音？ | 训练集质量 | 谱平坦度 + 人工抽检 |
| Q8 | `franchise` 用 `totsulover` 是否与 #135 一致？ | id 空间 | 已有 `engineFamily`，按作品命名应无争议，需确认 |
| Q9 | `GE ` 里 type ≠ 3 的少数图（raw/1/2）怎么解？ | 影响少量 UI/遮罩 | 按 `sub_100C72E0` 的 default 分支（逐行 4*w 裸拷贝）先试 |
| Q10 | **表情合成表**（`st01a_a` ↔ 补丁清单）在哪？ | 决定立绘包能否自动化 | §5.3 R-a/R-b/R-c |

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

---

## 10. 安全 / 法务红旗

| # | 事项 | 处置 |
|---|---|---|
| R1 | `totsulover_dl/frida_handler.py` 含**明文第三方 API key**（5 处 key/token 形态命中） | 本报告未复制任何值；**建议所有者立即轮换该 key**，并把 Frida 脚本移出共享目录 |
| R2 | `Hook.js` / `ReadFile.js` 是注入脚本 | 不进仓库、不作为管线依赖 |
| R3 | 汉化补丁 LICENSE 禁止逆向/衍生 | 不解 `.pswj`、不并译文、不把补丁文件放进内容包（§4 已给合法路径） |
| R4 | 游戏素材版权（CRYSTALiA / AMUSE CRAFT） | 素材/文本/语音**一律不进公开仓库**；只进 `tools/` 已 ignore 的本机目录或内容包 |
| R5 | 声优声音的人格权（パブリシティ権） | 克隆只限本机私人使用；任何分享/上架改用 Voice Design 或授权声音 |
| R6 | Fish ToS：提交内容授予 Fish 永久可转授权 | 上传游戏音频前先确认这一点（这也是"本地 vs 云"要分开的原因） |
| R7 | 本仓库是公开仓库 | 报告内不写剧情原文、不写译文、不写设备 UDID/主机名/内网地址 |
| R8 | 体积 | 全量内容包（文本+embedding+立绘+语音）会到 GB 级；**必须分片**（content / stand / voice 三个包），不要做单一 zip |

---

## 11. 与上一份调研（2026-11-11）的差异

| 上一份结论 | 本次核实 |
|---|---|
| `.MIX` 是"台词→语音"映射 | ❌ 实为**多角色语音组**（14 组，32 B 槽） |
| `#135` 的 kind 分流"待做" | ❌ 已实现（`ContentBundleInstaller.swift:34`），但 `content` 仍要求非空 passages |
| `contentSetID`/`characterKeys` 未落地 | ❌ 已落地；另有 `StaticStandManifest` + `installStaticStand` |
| `.PGD` 是"私有 LZ/Huffman，1–3 人日" | ✅ 已实测：**LZSS + 按矩形 XOR 差分**；`ST01A_A010` 19,662,856 B 逐字节对得上，12/12 抽样通过；`st.pac` = 169 张 GE 底图 + 2,563 张 PGD3 补丁 |
| 场景边界"需要 VM，风险最高" | ✅ 仍成立，但**已定位到命令表与文本 handler**，风险从"未知"降为"3–5 d 的确定性工作" |
| 素材规模 3.31 GB / 4.1 GB | ✅ 与实测一致（另有 417 MB 特典 + 160 MB opening） |
