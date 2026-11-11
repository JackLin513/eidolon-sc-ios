# 两个外部企划的内容包可行性：`ディメンション凸ラバース!!`(T-Script) 与 Gakumas-Player

- 日期：2026-11-11
- 范围：`/Users/jacklin/Developer/IdeaProjects/Galgame support/`（只读）、`/Users/jacklin/Developer/IdeaProjects/Gakumas-Player/`（只读）；本仓库 `EidolonCore`/`EidolonIOS` 的现状接缝。
- 目的：为 **#135（S3 多内容包 / `FranchiseID` / `CharacterKey` / 多根 `ContentRegistry`）** 提供"这两个项目各自能变成什么样的内容包"的事实基础。
- 性质：**调研结论，不是 spec、不是 ADR、不是已实现设计**。任何一条要落地都要再走 grill → spec → implement（见 [`docs/research/README.md`](README.md)）。

所有分析在 `/tmp/eidolon-re/` 下进行，未改动两个外部项目；未把任何素材、文本或密钥写入本仓库。IDA 用的是 **脱壳镜像的副本**（`/tmp/eidolon-re/ida/game.exe`）与 `Pal.dll` 副本，外部目录里的 `.i64` 未被打开或改写。

---

## 0. 摘要

**两个项目提供的"内容"根本不是一个物种，所以 #135 不能用同一种内容包接它们。**

| | Galgame（`ディメンション凸ラバース!!`） | Gakumas-Player |
|---|---|---|
| 本质 | 已完结的 2D ADV 游戏（CRYSTALiA，T-Script System 引擎） | 浏览器里的 **3D 演出运行时**（three.js/WebGL）+ 远程素材库 |
| 文本 | **70,111 条**剧情/UI 台词，`TEXT.DAT` **明文 cp932**，无需解密 | **没有剧情语料**；剧情是用户/AI 写的 Beat XML |
| 图像 | `.PGD`（`PGD3` 私有编解码），**无公开工具**，最大工作量 | 1,658 张 PNG + 176 个 GLB + 37 个 PMX，全部直接可读 |
| 音频 | 22,135 条真 OggS（`voice.pac` 1.04 GB）+ BGM/SE | 无游戏音频；TTS 走 Fish Audio |
| 3D | 无 | 1,636 个 VMD + 176 GLB + 场景 `scene.json`(+lightmap) |
| 体积 | 4.1 GB（3.31 GB `.pac` + 154 MB 影片 + 417 MB 豪华版特典） | 清单 **4,561 项 / 7.6 GB**，R2 按需下载 |
| 对 Eidolon | `kind=content`（文本库）+ `kind=stand`（2D 立绘） | `kind=model3d`（新渲染运行时），**不是** `content` |

三条最重要的结论：

1. **galgame 的文本是白送的，图像是要还债的。** 文本表 `TEXT.DAT` 明文、结构简单（`[cp932 串][NUL][u32 id]`，id 连续 1..70111），一条 `python3` 脚本就能导出 70,111 行。但立绘/背景/CG 全是引擎私有 `.PGD`，30 个样本里 PNG/JPEG/zlib 命中率 **0/30**；要拿到图，必须逆向 `Pal.dll` 的解码器，或者写一个 32 位插件让游戏自己调 `PalSpriteSaveTextureToPngFile` 导出。
2. **Gakumas-Player 提供的是"怎么演"，不是"演什么"。** 它没有 `commu`/scenario 语料；Beat 脚本是用户或 AI 生成的表现层 DSL。它映射到 Eidolon 的是 `ContentKind.model3d` + 一个 Web 渲染运行时，接缝可以复用现成的 `SpinePresentationRuntime`（WKWebView + 自定义 scheme 从内容包目录供资源）。
3. **先做哪个：两者都不该先做"完整内容包"。** 最便宜的切片是 galgame 的 **角色包**（`Galgame support/sakura/` 里已经有 card.md 人格、14 张表情立绘、6 个音色 ref 的现成原型），而不是剧情库；Gakumas 最便宜的是**一个偶像的一个场景**（`idols/fktn` + `scenes/gakumas` 一个 `scene.json`）。

---

## 1. 方法与证据等级

| 等级 | 含义 | 本报告里的例子 |
|---|---|---|
| **实测** | 我在 `/tmp` 里跑过解析/反编译，结论可复现 | PAC 索引布局、`TEXT.DAT` 记录数、`PGD3` 头、OGG/MPG 魔数 |
| **反编译** | IDA Hex-Rays 伪代码 + 交叉引用，地址可复查 | `sub_477790` 加载器、`sub_482890` 解密 |
| **文件事实** | 直接读文件头/版本资源/许可证文本 | CRYSTALiA + "T-Script System -DL"、CN 补丁 LICENSE |
| **推断** | 由事实推出、**未被运行时验证** | `.PGD` 载荷是私有 LZ 类编码、脚本 `0x334` 是代码段起点 |

本文所有 `0x…` 地址均为 **imagebase + RVA**：游戏 exe imagebase `0x400000`，`Pal.dll` imagebase `0x10000000`。

**IDA 调用方式**（可复现，headless，无 GUI）：

```sh
cp "…/totsulover_dl/totsulover_crack.exe" /tmp/eidolon-re/ida/game.exe
"/Applications/IDA Professional 9.5.app/Contents/MacOS/idat" \
  -A -c -S/tmp/eidolon-re/ida1.py /tmp/eidolon-re/ida/game.exe
# 脚本开头必须 ida_auto.auto_wait()，否则 -S 会在自动分析前执行，只得到 2 个函数
```

> 注意：IDA 9.5 已没有 `idat64`/`ida64`，只有 `idat`/`ida`；且 `ida_idaapi.get_inf_structure`、`ida_bytes.find_binary` 都已移除。第一版脚本因此失败过两次，最终版本见 `/tmp/eidolon-re/ida1.py`、`/tmp/eidolon-re/ida2_pal.py`。

---

## 2. 项目 A：`ディメンション凸ラバース!!`

### 2.1 身份与引擎

PE 版本资源（`.rsrc` 里的 VS_VERSION_INFO，UTF-16 扫描）给出：

| 字段 | 值 |
|---|---|
| CompanyName | `CRYSTALiA` |
| ProductName | `ディメンション凸ラバース!!` |
| FileVersion / ProductVersion | `1.17.0.0` / `1.26.323.1226` |
| Comments | **`T-Script System -DL`** |

所以引擎是 **CRYSTALiA 的 T-Script System**，2D 层是同目录 `dll/Pal.dll`（`Pal*` C API 引擎库）。游戏 exe 的导入表里有独立模块 `PAL`，并导入 262 个 `Pal*` 符号（`PalSpriteLoad`、`PalSoundLoad`、`PalFontLoad`、`PalFileCreate`、`PalAnimation`、`PalMovie*`…），`Pal.dll` 自身导出 370 项。

分层很清楚：

```
totsulover.exe           ADX/脚本层：Sv20 脚本 VM、文本表、存档、菜单
  └─ PAL.dll             T-Script 的 2D 引擎：Sprite/Font/Sound/Input/Window/File(VFS)/Animation
  └─ FX.dll             特效
  └─ ogg/vorbis/vorbisfile.dll   音频解码
  └─ RESOURCE.dll
```

### 2.2 可执行文件与保护

| 文件 | 大小 | `.text` vsize | `.data` vsize / raw | 判断 |
|---|---|---|---|---|
| `totsulover.exe` | 1,410,560 | `0x57a2` | `0x3ce48` / **`0x1000`** | **加壳壳**：代码在运行时被解到 `.data` |
| `totsulover_crack.exe` | 1,152,512 | `0xc82bf` | `0x210d74` / `0x1e00` | **已脱壳镜像**（真实代码） |
| `111.exe` | 1,152,512 | `0xc82bf` | 同上 | 与 crack 同尺寸，Frida 脚本里当靶子用 |
| `DimensionToTsuLovers_cn.exe` | 1,159,168 | `0xc82bf` + `.detour` | 同上 | crack + 汉化插件注入段 |

- 反调试很弱：只有一处 `IsDebuggerPresent` 导入，加 `OutputDebugStringA/W`、`PalDebug*`、`SetUnhandledExceptionFilter`。
- `totsulover_crack.exe.i64`（19.6 MB，外部目录里已有）对应的是脱壳镜像；**我用副本另建数据库**，没有动它。
- 结论：**IDA 分析 crack 镜像 = 分析真实代码**，不需要脱壳、不需要绕过反调试。

### 2.3 归档格式 `.pac`（已完全解出）

`data.pac` 头 96 字节实测：

```
00000000: 50 41 43 20 00 00 00 00 a0 00 00 00 00 00 00 00  "PAC "  flags  count=160  ?
00000010: 00 ... (零填充到 0x803)
00000804: "ANI_ANGEL_STAND.ANI\0…"  size=0x2f(47)  offset=0x2104
```

布局（**实测校验通过**：索引结束偏移 == 第一条 offset；`Σsize + last_offset == filesize - 8`）：

| 偏移 | 类型 | 含义 |
|---|---|---|
| `0x00` | char[4] | `"PAC "`（含尾空格） |
| `0x04` | u32 | 0（未用/flags） |
| `0x08` | u32 | **条目数** |
| `0x0C` | u32 | 0 |
| `0x10..0x803` | — | 零填充 |
| `0x804 + i*0x28` | struct | `char name[0x20]`（NUL 填充，大写 8.3 名）+ `u32 size` + `u32 offset` |
| `0x804 + n*0x28` | — | 数据区起点（== 第一条 offset） |
| 文件尾 | 8 bytes | 尾标记/校验（未解，暂不依赖） |

各归档实测：

| 归档 | 大小 | 条目 | 内容 |
|---|---|---|---|
| `data.pac` | 10.1 MB | 160 | 139 `.ANI` + 14 `.MIX` + 6 `.DAT` + 1 `.SRC`（脚本、文本表、表索引） |
| `csv.pac` | 53 KB | 17 | 15 `.CSV` + `.TXT` + `.INI`（BGM/CG/FAV/LIST_EV… 表） |
| `face.pac` | 26.4 MB | 1,244 | 头像 `.PGD` |
| `tips.pac` | 10.8 MB | 256 | 用语集 `.PGD` |
| `sd.pac` / `mask.pac` | 12.7 / 16.3 MB | 43 / 41 | SD 立绘 / 遮罩 `.PGD` |
| `st.pac` | 369 MB | 2,732 | 立绘 `.PGD` |
| `ev.pac` | 331 MB | 714 | 事件 CG `.PGD` |
| `bk.pac` | 254 MB | 未列 | 背景 |
| `etc.pac` | 394 MB | 425 | 403 `.PGD` + 20 `.JPG` + 2 `.MPG` |
| `em.pac` | 176 MB | 107 | 54 `.PGD` + 53 `.MPG` |
| `battle.pac` | 278 MB | 305 | 战斗演出 `.PGD`/`.MPG` |
| `system.pac` | 194 MB | 695 | 617 `.PGD` + 74 `.OGG` + 3 `.TGA` + 1 `.DAT` |
| `bgm.pac` | 64.8 MB | 34 | 全 `.OGG` |
| `se.pac` | 43.5 MB | 789 | 全 `.OGG` |
| `voice.pac` | **1.04 GB** | **22,135** | 全 `.OGG` |
| `patch.pac` | 84.4 MB | 510 | 补丁覆盖资源（389 `.PGD` + 116 `.OGG` + 4 `.JPG`） |

`data.pac` 内的路由表 `ARCHIVE.DAT`（287 B）是**按模式列出要挂载哪些归档**：

```
csv|tips|bgv|movie|bgm|mask|em|evx|ev|sd|etc|bk|se|system|face|voice|st|battle|patch|debug|test,
csv|tips|bgv|movie|bgm|mask|em|evx|ev|sd|etc|bk|se|system|face|voice|st|battle|patch|trial,
…countdown
```

→ `PalFileCreate("Script.src")` 这类虚拟路径就是靠这张表解析到具体 `.pac` 的（VFS 在 `Pal.dll` 里，游戏 exe 只调 API）。

### 2.4 加密：只有一处，`sub_482890`

`sub_477790`（`0x477790`，加载器，7.5 KB 伪代码）在读完 `File.dat` / `Text.dat` / `Mem.dat` / `Point.dat` 之后都做同一个判断：

```c
if ( *buf == 36 )                    // '$'
    sub_482890(buf + 16, size - 16); // 跳过 16 字节头再解密
```

`sub_482890`（`0x482890`）的真身：

```c
if (len & 3) len -= len & 3;         // 只处理 4 字节对齐长度
v3 = 4;
do {
    *p = __ROL1__(*p, v3++);         // 每 dword 第 0 字节循环左移 (4+i)
    *(u32*)p ^= 0x084DF873;
    *(u32*)p ^= 0xFF987DEE;          // 等价于 ^= 0xF7D5859D
    p += 4; len -= 4;
} while (len);
```

要点：

- 这是**整段流式加密**（按 dword 递进），不是逐条目 key；密钥是常量，`Pal.dll` 里没有额外校验。
- **只对以 `$` 开头的表生效**。我们手上的 `TEXT.DAT` 以 `_` 开头（`_TEXT_LIST__`），所以**根本没加密**——这也解释了为什么它里面是明文。
- 同一份代码路径说明：如果发行版里某张表被加密，只需在提取后对 `[16:]` 施加逆变换（`^= 0xF7D5859D`，再把第 0 字节 `ROR` 回去），不需要游戏。

### 2.5 脚本格式 `SCRIPT.SRC`（Sv20）

`sub_477790` 对脚本的处理说明了一切：

```c
v2 = PalFileCreate("Script.src", …);
ReadFile(v2, v4, size, …);
if ( *(_DWORD*)v4 != 808613459 ) goto load_error;   // 0x30325653 = "Sv20"
*(this+87975) += 8;                                  // 跳过 magic(4) + 0x69d8a1a1(4)
v8 = *(u32*)(buf + *(this+87975));                   // +8 处的 u32 = 代码段偏移
*(this+87976) = 12;
*(this+87977) = v8;
*(this+87975) = v8;                                  // PC/入口 = 代码段偏移
```

实测 `SCRIPT.SRC`（6,954,384 B，与 `data.pac` 内那份**同一文件**）：magic `Sv20`、`u32@4 = 0x69d8a1a1`、`u32@8 = 0x334`。

**关键实测**：对整份 6.95 MB 脚本做 UTF-8 日文（3 字节序列 ≥4 连）与 cp932 日文（≥4 连）扫描，命中 **0 / 0**。

→ 脚本是**纯字节码，不含任何台词**；台词只以 id 形式出现在 `TEXT.DAT`。这是本次调研最重要的结构事实：**文本抽取不需要理解 VM，但"哪句话属于哪一幕"需要理解 VM**。

`0x0C..0x334` 这 808 字节是某种定长描述表（8 字节一条，约 101 条），`0x334` 起是代码；具体语义未解（见开放问题 Q3）。

### 2.6 数据表 `.DAT`（明文）

| 表 | 大小 | 头 | 用途 |
|---|---|---|---|
| `FILE.DAT` | 909,648 | `_FILE_LIST__` + 小头（`0a 6f 00 00`，未解），之后是 32 字符名 + `#` 的定长记录 | 文件清单/哈希表 |
| `TEXT.DAT` | 2,148,954 | `_TEXT_LIST__` + `u32 70112` + `u32 0` | **台词/UI 文本池** |
| `GRAPHIC.DAT` | 14,728 | `_GRAPH_LIST_****` | 图像 id → 资源名 |
| `MEM.DAT` | 14,024 | `_MEM_LIST___****` | 内存/角色表 |
| `POINT.DAT` | 44,436 | `_POINT_LIST_****` + 偏移数组 | 脚本/分支点索引 |

`TEXT.DAT` 的记录布局（实测逐条走完，无残留）：

```
[cp932 字符串][0x00][u32 id]   id 从 1 连续到 70111，共 70,111 条
```

抽样（只列结构性短串，不摘剧情）：

```
id 1     "MS ゴシック"      id 2  "MS 明朝"       id 3  "MS Pゴシック"   ← 字体名
id 301   "HISTORY_BACK_Y"   id 302 "history"      id 303 "WAIT_ICON_TIME" ← 系统键
```

前几百条是字体名/系统常量，之后混入 UI 与剧情。**含 `<br>` 换行标记**（实测样本里有 `<br>`），说明文本表直接存"显示用文本"，不是纯台词。

### 2.7 图像 `.PGD`（**硬阻塞**）

两种头，实测：

```
PGD3  小图/头像：
50 47 44 33 | ed 00 | 0f 01 | 6f 00 | 4b 00 | 20 00 | "fa01a_a010.pgd" + 零填充(32B)
"PGD3"        w=237   h=271   0x6f     0x4b    namelen=32   原资源名
→ 头长 0x2E，之后是载荷

"GE " 大图（如 500×410 的 face）：
47 45 20 00 | 8 字节 0 | f4 01 00 00 | 9a 01 00 00 | f4 01 00 00 | 9a 01 00 00 | 03 00 00 00 | c2 84 0c 00 | c2 5e 02 00
"GE "        填充       500          410           500           410           3(未解)       820418(未解)   155074(未解)
```

（`820418` 与 `500×410×4=820000` 只差 418，`155074` 与文件大小 155370 也只差 296，但两者都对不上精确的"未压缩/压缩字节数"，所以标为未解，不要按 `w*h*4` 硬算。）

- 30 个随机样本：`PGD3` 28、`GE ` 2、**PNG 0、JPEG 0、zlib 0**。
- 载荷里没有任何标准容器魔数，也没有 zlib 头；`Pal.dll` 虽然内置 zlib 1.1.4 + IJG libjpeg + PNG IHDR 代码，但那是给**外部** PNG/JPEG 贴图用的（`PalSpriteLoadTextureToFile` / `PalSpriteSaveTextureToPngFile`），`.PGD` 走的是另一条私有解码路径。
- `Pal.dll` 里确实有 `"PGD3"` 字符串（`0x100b8652`、`0x100b9e32`），说明 PGD 处理是引擎显式分支，不是一个通用图片加载器。

**两条可行路线**（按成本排序）：

1. **让引擎自己导出**（推荐先试）：游戏 exe 导入表里有
   `PalSpriteLoad`（`0x483c5e`）、`PalSpriteLoadTextureToFile`（`0x4832ee`）、
   **`PalSpriteSaveTextureToPngFile`（`0x48334e`）**、`PalSpriteSaveTextureToPng24File`（`0x48336e`）。
   写一个 32 位 DLL 插件（游戏本身有 `Plugin/` 加载机制，汉化补丁就是插件），在其中 `PalSpriteLoad` + `PalSpriteSaveTextureToPngFile` 批量转 PNG。零编解码逆向，但需要 Windows 环境跑一次游戏。
2. **逆向解码器**：从 `Pal.dll` 的 PGD3 分支还原 LZ/Huffman 变体。样本里 `01 02 02 01 01 01 01 01` 这类字节很像码长表，但未证实；预计 1–3 人日，且要处理 16 位/32 位两种像素格式与 alpha。

### 2.8 音频/视频（**直接可用**）

| 类型 | 实测头 | 结论 |
|---|---|---|
| `.OGG` | `4f 67 67 53 00 02` = `OggS` v0 | 真 Ogg，可直接 ffmpeg/AVFoundation；`voice.pac` 22,135 条 |
| `.MPG` | `00 00 01 ba` = MPEG-1 program stream | 可直接播/转码 |
| `.TGA` | `00 00 02 00 …` type 2, 32×32 | 未压缩 TGA，可直接读 |

`.MIX`（14 个，32–96 B）是**台词→语音 id 的映射组**：

```
"vo01_0601" (32B) | "vo03_0644" (32B) | "vo02_0540" (32B)
```

→ 这是把 `TEXT.DAT` 的某一行对到 `voice.pac` 里若干 OGG 的现成线索（多角色混音时一条记录里有多个 id）。

`.ANI`（139 个，26–47 B）是定长动画指令流，例如 `ANI_ANGEL_STAND.ANI`（47 B）：

```
fd 03 e0 ff ff ff e8 03 00 00 fe e8 03 00 00 03 20 00 00 00 e8 03 00 00 fe e8 03 00 00 0a 00 …
```

（`0x03fd`、`0x03e8`=1000 这类常量像时长/曲线参数，语义未解；对立绘进 Eidolon 不关键，因为我们只需要"表情差分图"，不需要还原引擎的补间。）

### 2.9 已有的提取物：**有坑，别复用**

外部目录里有两份"看起来像提取结果"的东西：

| 路径 | 实际 | 判断 |
|---|---|---|
| `totsulover_dl/pack/data/`（160 个文件） | `ANI_ANGEL_STAND.ANI` 是 **8452 B**，而索引里 size=**47**、offset=**0x2104=8452** | **旧脚本把 `offset` 当 `length` 写了**，整份提取是错的 |
| `totsulover_dl/SCRIPT.SRC` | 6,954,384 B，magic `Sv20`，与 `data.pac` 内一致 | ✅ 正确 |
| `totsulover_dl/translation.db` / `translations.db` / `translation_cache.json` | 机翻缓存（16 KB 级） | 与本调研无关；**不要**当作译文本体 |

证据：`pack/data` 里文件尺寸序列 8452, 8499, 8525, 8551, 8585… 恰好等于索引里的 offset 序列 0x2104, 0x2133, 0x2155…，而真实 size 序列是 47, 26, 26, 34, 34…

### 2.10 提取管线（可执行步骤）

> 下面提到的 `tools/pac_extract.py` 等脚本**尚未入库**，是提案；本次调研的等价操作都在 `/tmp` 里用一次性脚本跑过，结论以第 2.3–2.8 的实测为准。

**步骤 0：列归档**（只读，不改外部项目）

```python
# tools/pac_list.py
import struct, sys
d = open(sys.argv[1], 'rb'); n = struct.unpack('<I', d.read(0x10)[8:12])[0]
d.seek(0x804); idx = d.read(n * 0x28)
for i in range(n):
    e = idx[i*0x28:(i+1)*0x28]
    name = e[:0x20].split(b'\0')[0].decode('cp932')
    size, off = struct.unpack_from('<II', e, 0x20)
    print(f"{name}\t{size}\t{off:#x}")
```

**步骤 1：抽 `data.pac` 的四张表 + 脚本**

```sh
python3 tools/pac_extract.py "<game>/data.pac" --only TEXT.DAT,FILE.DAT,GRAPHIC.DAT,POINT.DAT,ARCHIVE.DAT,SCRIPT.SRC \
  --out /tmp/eidolon-re/out
```

**步骤 2：`TEXT.DAT` → 行表 JSONL**（不要进仓库，产出放 `tools/` 已 ignore 的目录）

```python
b = open('/tmp/eidolon-re/out/TEXT.DAT','rb').read()
assert b[:12] == b'_TEXT_LIST__'
assert struct.unpack_from('<I', b, 12)[0] == 70112
p, rows = 20, []
while p < len(b):
    e = b.find(b'\x00', p)
    line = b[p:e].decode('cp932')
    tid = struct.unpack_from('<I', b, e+1)[0]
    rows.append((tid, line)); p = e + 5
# 70,111 行；line 里可能含 <br>、%d 等格式串
```

**步骤 3：语音**——`pac_extract.py voice.pac --out /tmp/…/voice`（22,135 个 `.ogg`，1.04 GB），再用 `.MIX` 32 B 记录把行对到 voice id。

**步骤 4：立绘**——先走 2.7 的路线 1（插件导出 PNG），不要先写解码器。

**步骤 5：打包成 Eidolon 内容包**——见第 5 节；注意现有 installer 只认 `content` 一种校验路径。

---

## 3. 项目 B：Gakumas-Player

### 3.1 架构

- 纯静态前端 + `node server.mjs`（Node ≥20，**无 npm 运行时依赖**，`npm start` 起 4173），无构建步骤（`package.json` 只有 `start`）。
- 入口 `gakumas-player.html`，编辑器 `beat-editor.html`，`vendor/three/` 是 Three.js。
- 素材来源写死在 `library.json`：`source: "r2"`、`localBase: "library/file"`、R2 公共桶（`*.r2.dev`）。**仓库不含完整素材**，大型资源按需从 R2 拉。
- 一致性由 `resource-manifest.json` 管：每项 `{size, hash(sha256), type, local, deps?}`；README 明确"清单记录的大小和 SHA-256 必须与实际下载的文件一致"。

### 3.2 素材规模（实测统计 `resource-manifest.json`）

| 指标 | 值 |
|---|---|
| 条目数 | **4,561** |
| 总字节 | **7.62 GB** |
| 扩展名 | png 1,658 / vmd **1,636** / json 1,047 / glb 176 / pmx 37 / obj 7 |
| 主要前缀 | `motions/story-all-20261010` 950、`motions/cmmn-body` 238、`motions/cmmn-face` 236、各偶像 `motions/<id>-dedicated-body` |
| 场景依赖 | 143 条带 `deps`（如 `scenes/env_3d_adv_all001-00-noon/scene.json` → `scene.glb` + 6 张 lightmap + 2 张 reflection） |
| 仓库内本地素材 | `assets/` 20 MB、`ui/` 8.3 MB、`npc-portraits/` 10 MB、`worldbook/` 952 KB |

`library.json`（55 KB）：

- `idols`：15 个，含 `{id, name, outfit, pack, model(.glb), textureDir, visemes, secondaryMotionProfile, costumes}`。例：`fktn` 藤田琴音、`amao` 有村麻央、`ttmr` 月村手毬 … `nasr` 亚纱里老师、`krnh` 贺阳燐羽。
- `packs`：`{root, r2Prefix}` 映射；`root` 是作者本机路径（`G:/SillyTavern/...`）→ 说明素材是**从 MMD/SillyTavern 流水线导出的**，不是官方发布包。
- `scenes`：`{id, name, pack, path(scene.json), defaultLayout, sourceScene, beatPolicy}`，如 `home-classroom-noon`、`adv-classroom-00-00-evening`。
- 还有 `gakumas-motion-map.json`（695 KB，988 条动作：581 配对 / 96 仅身体 / 311 仅表情）与 `gakumas-secondary-motion.json`（419 KB，二次动作）。

### 3.3 剧情格式：Beat XML（**不是游戏剧情**）

README 的示例：

```xml
<beat speaker="kotone" cue="talk" face="neutral">收到，制作人。</beat>
```

`beat-protocol.js` 里的字段面：`speaker`、`cue`（含 `BEAT_CUE_IDS`、`BEAT_BODY_CUE_SPECS`）、`face`（`BEAT_FACE_IDS`）、`overlay`、`effect`、`shot`/`camera`（中景/近景/特写/反应/全景/保持）、`wait`（text/voice/none）、`position`（left/center/right）、`transition`（clock/时钟）。还有中英别名表（`疑问→ask`、`害羞→shy`…）。

**实测：仓库没有 `commu`/scenario 语料。** 对 `*.json`/`*.md` 搜 `commu|scenario|story`，命中的只有 `library.json`、`resource-manifest.json`、`gakumas-motion-map.json`、`scene-activity-manifest.json` 这类**演出清单**，以及 `worldbook/初星学园.json`（SillyTavern 世界书，`entries` 带 `key/content/constant/selective`）。

→ 所以 Gakumas 侧可用的"内容"是：**角色/模型/动作/场景/UI/世界书**，加上"如何把 Beat 脚本演出来"的运行时；**没有可导入的剧情库**。

### 3.4 3D / 立绘 / 动作

- `live-portrait-model.js`：`detectLivePortraitFormat(idol)` = `.glb` → `'glb'`，否则 `'pmx'`；`configureGlbAnimationTarget` 从 `SkinnedMesh` 里挑骨骼最多的骨架 + morph target 字典。
- 表情/口型：`visemes`（A/I/U/O/E/M → `mouth_032` 等 morph 名）；`facial-effects/` 是 obj+png 的贴花（泪、星眼、腮红）。
- 动作：VMD 1,636 个 + `gakumas-motion-map.json` 的语义分桶（情绪/动作家族）。
- 场景：`scene.json`（最大 575 KB）+ `scene.glb` + RGBM lightmap/reflection。
- 渲染：Three.js + 自写 shader（`gakumas-shader.js`）、GPU/纹理预算（`gpu-resource-estimator.js`、`portrait-texture-budget.js`）。

### 3.5 依赖与许可

- 依赖：Node 20+（仅静态服务）、Three.js（`vendor/three/LICENSE`）。**没有** package 依赖、没有构建步骤。
- **项目级许可证：没有。** README「许可与素材」原文：*"本仓库目前尚未提供项目级开源许可证，请在使用、修改或再分发前向项目维护者确认授权"*，并声明游戏角色/模型/贴图/音频"可能有各自的权利归属；仓库或远程地址可访问不代表这些素材已获得再分发许可"。
- 素材命名（`eff_ps_adv_tex_tears_02`、`mdl_prp_smartphone-fktn-00`、`env_3d_adv_*`）是游戏内部命名规范 → 来源是**游戏解包/转换**，不是官方素材包。
- R2 公共桶可匿名读 ≠ 授权；`library.json` 里还带着 `accountId`/`bucket` 字段（公共仓库里已有）。

### 3.6 管线（如果要做成 Eidolon 包）

> `tools/fetch_gakumas_pack.mjs` 同样是提案，仓库里没有；现在能跑的只有 `npm start` 与 `prepare-assets.mjs`（后者只拷贝，不转换）。

```sh
# 1) 只拉需要的子集（不要 7.6 GB 全量）
node tools/fetch_gakumas_pack.mjs --manifest resource-manifest.json \
  --prefix idols/fktn --prefix motions/fktn-body --prefix motions/cmmn-face \
  --scene scenes/gakumas/env_3d_home_classroom-00-00-noon --out /tmp/gakumas-pack
#   逐项校验 size + sha256；R2 base 从 library.json 读

# 2) 本地跑一次播放器，确认子集自洽（缺 deps 会 404）
cd Gakumas-Player && npm start   # http://127.0.0.1:4173
```

`prepare-assets.mjs` 只是把仓库拷进 `dist/`（部署用），**不做素材转换**；转换在仓库外（作者本机的 MMD/SillyTavern 流水线，见 `packs[].root`）。

---

## 4. 格式清单（两个项目对照）

| 维度 | Galgame（T-Script） | Gakumas-Player |
|---|---|---|
| 容器 | `.pac`（自研索引，明文，无压缩） | zip/HTTP 目录 + `resource-manifest.json` |
| 文本 | `TEXT.DAT`：`[cp932][NUL][u32 id]` × 70,111 | Beat XML（自撰/AI），无游戏语料 |
| 脚本 | `SCRIPT.SRC`：`Sv20` 字节码（无文本，只有 id） | JS 运行时解释 Beat XML |
| 图像 | `.PGD`（`PGD3`/`GE `，私有编解码） | PNG / WebP / JPG（标准） |
| 3D | 无 | GLB（176）、PMX（37）、VMD（1,636） |
| 场景 | 背景 `.PGD` + `.ANI` 指令流 | `scene.json` + `scene.glb` + lightmap |
| 音频 | OGG（22,135 语音）+ `SE`/`BGM` OGG | 无游戏音频；TTS 运行时生成 |
| 视频 | MPEG-1 PS（`.MPG`） | 无 |
| 动画 | `.ANI` 定长指令（26–47 B） | VMD + 二次动作 JSON |
| 元数据 | `FILE/GRAPHIC/MEM/POINT.DAT` + `*.CSV` | `library.json` / `motion-map` / `scene-activity-manifest` |
| 加密 | `$` 前缀 + `sub_482890`（本作未触发） | 无 |
| 反调试 | 仅 `IsDebuggerPresent`；原始 exe 加壳 | 不适用 |
| 许可 | 商业游戏，素材版权 CRYSTALiA；汉化补丁**禁止逆向/衍生** | 无项目许可；素材版权 Bandai Namco 系 |

---

## 5. 映射到 Eidolon 现状与 #135

### 5.1 现有接缝（已实现，可直接用）

| 接缝 | 位置 | 现状 |
|---|---|---|
| `ContentManifest` | `EidolonCore/Sources/EidolonCore/ContentManifest.swift:9` `supportedFormatVersion = 5` | 已有 `kind: String?`（`:28`）与 **`franchise: String?`**（`:31`，nil 读作 `shiny`） |
| 内容库 schema | `ContentSchema.swift:8-37` | `episodes` / `episode_cast` / `episode_lines(ja,zh)` / `episode_passages(embedding)`，`user_version = 1` |
| 安装校验 | `ContentBundleInstaller.swift:14` | zip → `manifest.json` → `content/eidolon.db` → `characters/*.json` → `holidays/world/gifts/jobs/places/photo_tags` → 原子换入 `current/` |
| 包内布局 | 同上 `:201`（characters.json）、`:246`（gifts）、`:280`（places）、`:294`（photo_tags）、`:345`（`stand/idols/**/data.json`） | 单包、单根、单 franchise |
| 统一包头 | `Presentation.swift:243-280` | `ContentKind{content,stand,bar,model3d,universe}` + `PackageHeader{kind, franchise, runtime, capabilities, legal}` + `resolvedFranchise`（nil→`shiny`） |
| 运行时选择 | `Presentation.swift:41`（`RuntimePreference{auto,2d,3d}`）、`EidolonIOS/Runtime/Runtime.swift:88`（`RuntimeRegistry`）、`:152`（`SpinePresentationRuntime`） | 2D 走 WKWebView |
| 2D 渲染器 | `EidolonIOS/Features/Stand/StandWebRenderer.swift:10` `SpineCharacterRenderer` | **WKWebView + 自定义 URL scheme，从 contentRoot 供资源**，消息式接口 |

`SpineCharacterRenderer` 这条尤其关键：它已经是"用 WebView 跑 WebGL、从内容包目录读素材、只传消息"的形状，**Gakumas 的 three.js 运行时几乎可以照抄这个骨架**（换页面、换消息协议）。

### 5.2 每个项目需要什么

#### A. Galgame → `kind=content` + `kind=stand`

**能直接对上：**

- `episode_lines(ja, zh)` ← `TEXT.DAT`（ja = cp932 解码；zh 留空或自己做机翻，**不要**用汉化补丁的文本）。
- `characters/characters.json` + `stand/` ← `sakura/character.json` 的 `portrait.expressions` 六种情绪（中性/不满/害羞/请求/困惑/惊讶）正好落在 `StandEmotion` 的语义里。
- `characters/world.json` ← 手写世界设定（`sakura/card.md` 里已有"原作信息"段，可直接改写）。

**缺的（要新 schema/runtime）：**

1. **场景边界**。`episodes` 需要 `id/category/title`，`episode_lines` 需要 `seq`。现在只有 70,111 条**扁平** id，我们**不知道**哪条属于哪一幕。要么解 `Sv20` 的文本 opcode（脚本 VM 里"push 文本 id + 说话人"的调用点），要么用 `POINT.DAT`/`.MIX` 做近似。这是 galgame 内容包的**第一技术风险**。
2. **行↔语音映射**。`.MIX` 给了 voice id 组，但 `.MIX` 文件名（`VO99_046_01`）与文本 id 的对应关系未解；需要脚本 VM 或存档结构。
3. **installer 只认"有剧情"的包**：`ContentBundleInstaller.swift:323` `guard (counts["episode_passages"] ?? 0) > 0 else "剧情库是空的"`，且 installer **完全不读 `kind`**（全文只有 manifest 的 `kind` 字段，没有分支）。所以"只有角色没有剧情"的包现在装不进去 → #135 需要**按 kind 分流校验**（这也是 M3 本来就要做的事）。
4. **向量**：`episode_passages.embedding` 必须每段都有（`ContentBundleInstaller.swift:327-330` 拒绝空向量），走一次 SiliconFlow embedding 是必须的成本。

#### B. Gakumas → `kind=model3d`（+ 可选 `content` 只放元数据）

**能直接对上：**

- `ContentKind.model3d`（`Presentation.swift:247`）与 `PackageHeader.runtime/capabilities/legal` 就是为这条路留的。
- `capabilities`（`expressions/framings/lipSync/gaze/gesture/fullBleed/engine`）能表达 three.js 运行时的真实能力。
- `characters/characters.json` ← `library.json` 的 15 个 `idols`（id/name/costumes/visemes）。

**缺的：**

1. **一个 WebGL 渲染运行时**。Eidolon 现有 2D 是 Spine（`spine-webgl`），3D 是 Unity UaaL。Gakumas 的 GLB+VMD 需要 three.js —— 最省事的是**新写一个 `PresentationRuntime`**，内部复用 `StandWebRenderer` 的 WKWebView + scheme 结构，页面换成 Gakumas 的 three.js bundle。**不需要 Unity**。
2. **包内目录约定**。`model3d` 还没有目录规范（现在只有 `stand/idols/**/data.json`）。要定：`model3d/<id>/model.glb`、`motions/*.vmd`、`scenes/<scene>/scene.json`、`textures/`。
3. **体积策略**。7.6 GB 不可能整包；必须"按角色/按场景切片 + 按需下载"，这与现有"原子安装 zip"模型冲突 → 需要**可增量/可分片**的包（或先只做静态子集，把 deps 一次拉全）。
4. **VMD→GLB 动作**：three.js 需要 MMDLoader 或预转；`gakumas-*.js` 里已有大量转换/二次动作代码，可作为**参考实现**（不是直接依赖，因为它是浏览器 JS + 作者的素材路径）。

### 5.3 复合身份（#135 的核心）

跨企划文档已经给了方向（`docs/research/cross-franchise-model-2026-11-09.md:102-106,137-148`）：`Content/<franchise>/current` + `ContentRegistry` + `FranchiseID` / `CharacterKey{franchise, localID}`；五张把 `character_id` 写进主键的表要重建。

两个项目的具体取值建议：

| | FranchiseID | CharacterKey 例 | 理由 |
|---|---|---|---|
| Galgame | **按作品**：`totsulover`（不要用 `galgame`） | `totsulover:yano-sakura` | 文档把 `galgame` 定义成"引擎族"。同一引擎（T-Script）下有多个作品，若都用 `galgame`，local id（`A020` 这种）会跨作品撞车。引擎族应另设字段（如 `engineFamily`），不要占用 franchise 命名空间 |
| Gakumas | `gakumas` | `gakumas:fktn` | 与文档一致；`library.json` 的 id（`fktn/amao/…`）已经是稳定 local id |

**对 #135 的三条硬要求（由本次调研直接推出）：**

1. **多根 registry 必须按 kind 分流校验**：现有 `ContentBundleInstaller` 只有一条路径且强制 `episode_passages > 0`；`model3d`/纯角色包会被拒。
2. **包内相对路径不能加全局前缀**（文档 `:106` 已写）：Gakumas 的 `library.json` 里 `packs[].root` 是**绝对路径**，直接搬进来会破坏可移植性 —— 必须重写成包内相对路径。
3. **同名/同 id 冲突**：Galgame 的头像 id（`A020`/`FA01A_A010`）与 Gakumas 的偶像 id（`fktn`）风格不同，但两者都会进 `characters.ids`；`ContentManifest.characters.ids` 是**裸字符串数组**，不含 franchise → 装两个包时 manifest 层的 id 必须已经带前缀，或在 #135 里改成 `CharacterKey` 序列。**这是最容易漏的一处。**

### 5.4 目标包形状（"重打包"的实际动作）

两个项目都**不需要**保留原容器；我们只把它们的内容搬到 Eidolon 的 zip 布局（`ContentBundleInstaller.swift:14` 的产物）：

```
<totsulover-content.zip>
  manifest.json                 format_version=5, kind="content", franchise="totsulover"
  content/eidolon.db            episodes / episode_cast / episode_lines / episode_passages
  content/holidays.json
  characters/characters.json    CharacterConfig[]（id 暂时带前缀，等 #135 换成 CharacterKey）
  characters/world.json         从 sakura/card.md 的「原作信息」改写
  characters/places.json        可选（酒吧/日程用）
  stand/idols/<id>/data.json    2D 表情差分（S0 用 sakura/portraits/*.png）
```

```
<gakumas-model3d.zip>
  manifest.json                 kind="model3d", franchise="gakumas", runtime=webgl
  model3d/fktn/model.glb + textures/
  model3d/fktn/motions/*.vmd    （或预转后的 glb 动画）
  scenes/<scene>/scene.json + scene.glb + textures/
  characters/characters.json    id=fktn，visemes 原样保留
```

两条不变式（与 #135 直接相关）：

- **包内路径全部相对**：Gakumas 的 `library.json` 用绝对路径（`G:/SillyTavern/...`），打包时必须重写；内容包不写全局前缀（跨企划文档 `:106`）。
- **`manifest.files` 必须列全 + CRC32**：`ContentBundleInstaller.swift:134-155` 会逐项校验 size 与 crc32，少一个文件就装不进去（这是"体积切片"必须显式列 deps 的原因）。

---

### 5.5 决策表

| 类别 | 项目/能力 | 结论与近期动作 |
|---|---|---|
| **近期可做** | Galgame 文本 | `TEXT.DAT` 70,111 行明文可导出；先做行表 + 启发式 episode，不要等 VM |
| **近期可做** | Galgame 语音 | `voice.pac` 22,135 条 Ogg 可直接转/播；先保留原文件，映射放 S2 |
| **近期可做** | Galgame 角色原型 | `sakura/` 的 card + 14 表情 + SoVITS 音色可先做 S0 角色包 |
| **近期可做** | Gakumas 单偶像/单场景 | 切片下载 + three.js runtime 骨架；不承诺剧情 |
| **需要新运行时** | Gakumas 演出 | 新 `PresentationRuntime`（WKWebView + scheme + three.js），不是 Unity |
| **需要新 schema** | 多包/复合身份 | `ContentRegistry`、`CharacterKey`、installer 按 `kind` 分流；#135 的 P0 |
| **需要逆向后才能做** | Galgame 立绘/CG | `.PGD` 私有编解码；优先写插件调 `PalSpriteSaveTextureToPngFile`，逆向解码器作为后备 |
| **需要再调研** | Galgame 场景边界/说话人 | `Sv20` opcode、`POINT.DAT`、`.MIX` 映射；这是文本包成败关键 |
| **法务禁止/不可用** | CN 补丁 `.pswj` | LICENSE 禁止逆向/衍生；不得作为来源 |
| **法务禁止/不可用** | 两项目素材整包分发 | 版权不允许，仓库只存工具/报告，不存素材/文本 |

## 6. 最小可行切片（建议顺序）

| 切片 | 内容 | 工作量 | 依赖 | 产出 |
|---|---|---|---|---|
| **S0** | **Galgame 角色包（零解码）**：用 `Galgame support/sakura/` 现成的 `card.md` + 14 张表情 PNG + 6 个 tone ref，做 1 个角色 + 1 个 `stand` 目录 + 最小 content 库（10–20 条手写 episode 或 1 条占位） | 1–2 天 | 只需 #135 的"按 kind 校验"或一个占位 episode | 真机上一个能换表情、能聊的 galgame 角色 |
| **S1** | **Galgame 文本语料**：`TEXT.DAT` → 70,111 行 → 按 id 分段成 episodes（先用启发式：连续 id + `<br>` 分页 + 说话人未知则 `narrator`），跑 embedding | 3–5 天 | S0；embedding API；episode 切分启发式 | 可检索的剧情库（`kind=content`） |
| **S2** | **Galgame 语音**：`voice.pac` 22,135 OGG + `.MIX` 对齐 | 2–3 天 | S1（需要行↔voice 映射）；本地播放/缓存策略 | 台词配音（替代/补充 Fish Audio） |
| **S3** | **Galgame 立绘/CG**：插件导出 PNG（2.7 路线 1） | 3–7 天 | Windows 环境 + 插件工程 | 真实立绘与背景 |
| **S4** | **Gakumas 单偶像单场景**：`idols/fktn` + `scenes/gakumas` 一个 `scene.json` + 10 个动作，切片下载（~200–400 MB） | 5–10 天 | 新 WebGL runtime（抄 `StandWebRenderer` 骨架）+ `model3d` 目录规范 | 3D 立绘在 Eidolon 里说话/换表情 |
| **S5** | **Gakumas 多偶像/多场景 + 动作语义映射** | 2–3 周 | S4；`gakumas-motion-map` 的语义→`PresentationFrame` 映射 | 可演的 3D 场景 |

**建议先做 S0 + S4 的"骨架验证"，再决定 S1/S2/S3 的投入**：S0 能在不碰引擎的情况下验证 #135 的 kind 分流；S4 能验证 WebGL runtime 接缝。两者都不需要解 `.PGD`。

---

## 7. 风险排序

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | **`.PGD` 无解码器** | galgame 立绘/背景/CG 全部不可用（等于只剩文字） | 先走插件导出路线；把 S3 排在 S1 之后，别让它阻塞文本包 |
| R2 | **Sv20 场景边界未知** | 无法把 70k 行切成有意义的 episode，只能做扁平语料 | 先做启发式 + 人工抽检；把 VM 解码列为独立 spike |
| R3 | **Gakumas 体积 7.6 GB** | 与"原子安装 zip"模型冲突；真机存储吃不消 | 按偶像/场景切片；manifest 增量；先只支持"预置子集" |
| R4 | **installer 单路径（`kind` 未分流）** | 角色包/3D 包装不进去 | #135 里先改 `ContentBundleInstaller` 按 `kind` 校验 |
| R5 | **`characters.ids` 无 franchise** | 两个包同时装会 id 冲突 | #135 里把 manifest 的 ids 升级为 `CharacterKey` 或强制带前缀 |
| R6 | **Gakumas 无渲染运行时** | 只能存素材不能显示 | 复用 `StandWebRenderer` 的 WKWebView + scheme；不引入 Unity |
| R7 | **版权/许可**（见第 8 节） | 不能分发、不能进仓库 | 只做本机自用；内容包走 `tools/` 生成、`.gitignore` |

---

## 8. 法律 / 体积 / 脱敏

- **两个项目都是商业游戏的衍生素材**：galgame 归 CRYSTALiA，Gakumas 归其权利方。本仓库是**公开仓库**，因此：
  - 素材、文本、语音、模型**一律不进仓库**；只进 `tools/` 生成的本机目录（已 ignore）或内容包。
  - 报告里不摘剧情原文（本文只引用字体名/系统键这类结构性短串）。
- **汉化补丁不能作为来源**：`totsulover_dl/DimensionToTsuLovers_cn/License/LICENSE.TXT` 明文规定「非商用 / 不得修改 / **不得反向工程、反编译、反汇编**」，且 `.pswj` 是补丁作者自有格式（UTF-16 头 `"Package format made by S…"`）。→ **不要**从 `.pswj` 抽文本，也不要把它的译文并进内容包。
- **Gakumas-Player 没有项目许可证**，README 明确"仓库或远程地址可访问不代表已获得再分发许可"。→ 只能当**参考实现/本机工具**，不能 vendor 进 Eidolon，也不能把它的素材打进包。
- **体积**：galgame 3.31 GB 归档 + 154 MB 影片 + 417 MB 特典；Gakumas 清单 7.62 GB；`sakura/voice/models` 两个 SoVITS 模型 328 MB。任何"整包分发"都不现实，必须切片 + 本机生成。
- **脱敏**：`totsulover_dl/frida_handler.py` 里有**明文 API key**（第三方服务的），`Hook.js` 有本地 hook 地址。本文未复制、未使用；建议提醒所有者**轮换该 key**，并把这类脚本移出共享目录。`library.json` 里的 R2 `accountId`/`bucket` 是公共仓库已有内容，不重复展开。

---

## 9. 开放问题

| # | 问题 | 为什么重要 | 怎么解 |
|---|---|---|---|
| Q1 | `Sv20` 的文本/说话人 opcode 是什么？ | 决定 galgame 能否切成 episode（S1 的前置） | 在 `sub_46AB70`（3,539 B，最大非 CRT 函数，疑似 VM 主循环）附近找 `TEXT.DAT` 索引的读取点；或用 `POINT.DAT` 反推 |
| Q2 | `TEXT.DAT` 的 id 是否就是脚本里的立即数？ | 若是，可用静态扫描脚本里的 u32 序列重建"引用顺序" | 在 `SCRIPT.SRC` 里搜 id 区间（如 0x0001xxxx）的出现模式 |
| Q3 | `SCRIPT.SRC` `0x0C..0x334` 的 808 B 表是什么？ | 可能是 opcode 表/重定位表，能省掉一半 VM 逆向 | 对比 `Sv20` 其他作品的脚本头（同引擎） |
| Q4 | `.PGD` 载荷到底是什么编码？ | 决定 S3 是"3 天"还是"3 周" | 优先试插件导出；否则从 `Pal.dll` 的 `"PGD3"`（`0x100b8652`）交叉引用入手 |
| Q5 | `.MIX` 文件名与文本 id 的映射规则？ | 语音对齐（S2） | 结合 `FILE.DAT` 表 + 存档结构 |
| Q6 | Gakumas 的 `scene.json` 是否自带 Beat 演出编排（可直接复用）？ | 决定 S4 是"抄场景"还是"抄场景+编舞" | 读一个 `scene.json`（575 KB）的 schema |
| Q7 | 原版 `Pal.dll`（`dll/游戏原来的pal.dll/`）与现用 `Pal.dll` 的差异？ | 现用 DLL 被改过（目录名就叫"原来的"），可能影响 PGD 解码行为 | 二进制 diff 两个 DLL；确认改动是否只涉及校验 |
| Q8 | #135 的 `FranchiseID` 是否允许"一作品一 franchise"？ | 直接影响 galgame 多作品的 id 空间 | 需要 grill（跨企划文档目前把 `galgame` 当引擎族） |

---

## 10. 证据表（claim → source）

| ID | 论断 | 来源（可复查） |
|---|---|---|
| E1 | 原始 `totsulover.exe` 是加壳壳（`.text` 0x57a2、`.data` vsize 0x3ce48 / raw 0x1000）；crack 是脱壳镜像（`.text` 0xc82bf） | 自写 PE 头解析脚本对两个 exe 的输出（`/tmp`，命令见 2.2） |
| E2 | 引擎 = T-Script System，厂商 CRYSTALiA，版本 1.17.0.0 | `totsulover_crack.exe` 的 `.rsrc` VS_VERSION_INFO（UTF-16 扫描：`CompanyName CRYSTALiA`、`Comments T-Script System -DL`） |
| E3 | 游戏 exe 导入模块 `PAL`，共 262 个 `Pal*` 符号；`Pal.dll` 导出 370 项 | IDA `out1.txt:227`（module: PAL）+ `strings`/导出目录解析 |
| E4 | 加载器 `sub_477790` 依次读 `Script.src`/`File.dat`/`Text.dat`/`Mem.dat`/`Point.dat`，失败时打 "script/textlist/filelist/pointlist/tablelist load error" | IDA Hex-Rays `sub_477790 @ 0x477790` |
| E5 | 脚本 magic `"Sv20"`（0x30325653=808613459），`u32@8` 是代码段偏移（本作 0x334） | `sub_477790` 伪代码 + `SCRIPT.SRC` 实测头 |
| E6 | `TEXT.DAT` 等表仅当首字节为 `$`(36) 时解密，跳过 16 字节头 | `sub_477790` 伪代码 `if (*v10 == 36) sub_482890(v10+16, size-16)` |
| E7 | 解密算法：每 dword 第 0 字节 `ROL1` by (4+i)，再 `^= 0x084DF873`、`^= 0xFF987DEE` | IDA Hex-Rays `sub_482890 @ 0x482890` |
| E8 | `.pac`：`"PAC "` + u32 count@8 + 索引@0x804 + 0x28 B/条（40 B：name[0x20], size, offset），数据区紧随索引 | 对 15 个 `.pac` 实测：索引结束 == 首条 offset；`Σsize+offset == filesize-8` |
| E9 | 各 `.pac` 条目数/类型（voice 22,135 条 OGG；st 2,732；face 1,244 …） | 同上脚本输出（第 4 节表） |
| E10 | `TEXT.DAT` = `_TEXT_LIST__` + 70112 + 0，记录 `[cp932][NUL][u32 id]`，id 1..70111 连续 | 逐条解析实测（70,111 条，无残留、id 单调唯一） |
| E11 | 脚本内**没有**日文文本（UTF-8 与 cp932 两种扫描均 0 命中） | 对 6,954,384 B `SCRIPT.SRC` 的正则扫描（2.5） |
| E12 | `.PGD` 头两种：`PGD3`+w/h+4×u16+32B 原名；`GE `+两对尺寸+两个未解字段 | `face.pac` 实测 hexdump（2.7） |
| E13 | `.PGD` 载荷无 PNG/JPEG/zlib（30 样本 0 命中），是私有编码 | 随机 30 条目扫描（PNG 0 / JPEG 0 / zlib 0 / PGD3 28 / GE 2） |
| E14 | `Pal.dll` 含 zlib 1.1.4、IJG libjpeg、PNG IHDR 代码；但 PGD3 是显式分支 | `pal_out.txt` 字符串表 + `"PGD3"` @ `0x100b8652`/`0x100b9e32` |
| E15 | 引擎导出 `PalSpriteSaveTextureToPngFile`；游戏 exe 导入于 `0x48334e` | IDA named hits（`out1.txt`）+ `Pal.dll` 导出 |
| E16 | OGG/MPG/TGA 是明文标准容器 | `bgm.pac`/`em.pac`/`system.pac` 头实测（`OggS`、`000001BA`、TGA type2） |
| E17 | `.MIX` = 32 B/条 voice id 记录；`.ANI` = 26–47 B 定长指令流 | `data.pac` 样本 hexdump（2.8） |
| E18 | `ARCHIVE.DAT` 按模式列出挂载的归档名 | `data.pac` 内 `ARCHIVE.DAT` 全文（287 B） |
| E19 | 总体积 4.1 GB（pac 3.31 GB + movie 154 MB + 特典 417 MB） | `ls -l *.pac` 汇总 + `du -sh` |
| E20 | `pack/data/` 的旧提取是错的（把 offset 当 length） | 磁盘上 `ANI_ANGEL_STAND.ANI`=8452 B vs 索引 size=47；尺寸序列 == offset 序列 |
| E21 | 汉化补丁禁止逆向/衍生且自带签名包格式 | `.../DimensionToTsuLovers_cn/License/LICENSE.TXT`（§3 b/c）+ `*.pswj` 的 UTF-16 头 |
| E22 | `frida_handler.py` 含明文 API key（本文不复制） | `totsulover_dl/frida_handler.py`（仅记录存在，不引内容） |
| E23 | `sakura/` 已是角色包原型：card.md 9.6 KB、14 张 1.4 MB PNG、SoVITS 328 MB、6 个 tone ref | `sakura/character.json`、`portraits/*.txt` 对照表、`voice/refs/ref.txt` |
| E24 | Gakumas 无 npm 依赖、Node 20、`npm start` 起 4173；无项目许可证 | `README.md`「运行要求」「许可与素材」、`package.json` |
| E25 | 4,561 项 / 7.62 GB；png 1658、vmd 1636、json 1047、glb 176、pmx 37 | 统计 `resource-manifest.json` 的 `assets` |
| E26 | 15 个偶像 + packs + scenes + visemes 在 `library.json` | `library.json` 的 `idols`/`packs`/`scenes` |
| E27 | Beat XML 字段面（speaker/cue/face/shot/wait/position/…） | `beat-protocol.js` + `README.md` 示例 |
| E28 | 仓库没有剧情语料（搜 commu/scenario/story 只命中演出清单与世界书） | 全仓 grep + 目录清单 |
| E29 | 988 条动作（581 配对/96 仅身/311 仅脸） | `gakumas-motion-map.json` 的 `counts` |
| E30 | 世界书是 SillyTavern 格式（`entries[].key/content/constant/selective`） | `worldbook/初星学园.json` |
| E31 | `ContentManifest` 已有 `franchise`（nil→shiny），格式版本 5 | `ContentManifest.swift:9,28,31`；`Presentation.swift:280` |
| E32 | 内容库 schema v1：4 张表 + 向量列 | `ContentSchema.swift:8-37` |
| E33 | installer 单路径且强制 `episode_passages > 0`（`kind` 未参与校验） | `ContentBundleInstaller.swift:14,323-324`；全文无 `kind` 分支 |
| E34 | `ContentKind{content,stand,bar,model3d,universe}` + `PackageHeader{franchise,runtime,capabilities,legal}` | `Presentation.swift:243-280` |
| E35 | 2D 立绘已是 WKWebView + 自定义 scheme、从 contentRoot 供资源 | `StandWebRenderer.swift:10-49`；`Runtime.swift:88,152` |
| E36 | #135 的 registry/复合身份方案 | `docs/research/cross-franchise-model-2026-11-09.md:102-106,137-148,155,160-166` |
| E37 | S3 = #135，M3 验收"两个企划包可同时安装" | `docs/roadmap.md:11,29` |

---

## 11. 附：本次分析产物（均在 `/tmp`，不提交）

```
/tmp/eidolon-re/ida/game.exe            # totsulover_crack.exe 副本
/tmp/eidolon-re/ida/out1.txt            # 6,009 函数、导入、字符串、xref、反编译
/tmp/eidolon-re/ida2/pal.dll            # Pal.dll 副本
/tmp/eidolon-re/ida/pal_out.txt         # Pal.dll：3,925 函数、370 导出、字符串
/tmp/eidolon-re/text.dat                # TEXT.DAT 提取（仅本地，勿提交）
/tmp/eidolon-re/pgd_sample.bin          # 一个 PGD 头样本（仅本地）
/tmp/eidolon-re/ida1.py, ida2_pal.py    # 可复现的 IDA 脚本
```
