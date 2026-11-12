# 立绘显示引擎与表情用法（`ディメンション凸ラバース!!`，2026-11-12）

> 回答四个问题：**谁在画全身立绘**、**表情/姿态按什么选**、**脚本里到底有没有逐行用法数据**、**能不能自动抽出权威标签**。
> 这是 [`galgame-vm-stand-commands-2026-11-12.md`](galgame-vm-stand-commands-2026-11-12.md) §6 负结论的**后续与修正**：
> 立绘不由 `face_*` 驱动；脚本里**有**逐行立绘状态数据，只是它藏在 **VM 原语赋值指令**里，而不是 `call_ext` 的立即数参数。
>
> 方法：只读静态分析（IDA 9.5 headless + 自写 Sv20 解码器）；不运行游戏、不注入 DLL、不联网、无 ASR/付费 API。
> 一次性脚本在 `/tmp/eidolon-re-engine/`（不入库）。

---

## 0. 摘要（结论先行）

| 问题 | 结论 | 置信度 |
|---|---|---|
| 驱动全身立绘的子系统 | **T-Script System 的 ADV 图层（graphic layer）+ 脚本侧共享显示子程序**；`sp_set_transition`(0x30032) 按 FILE.DAT 名字建 sprite，`Pal.dll` 解码 `.PGD` | **H（反编译 + 数据全量）** |
| 立绘资源 id 从哪来 | 脚本指令 `local[1] = <FILE.DAT id>`（VM opcode 1 = 赋值，立即数 = `ST<CC><Outfit>_<Pose><Slot>` 的记录号），随后 `push local[1]` + `gosub` 共享显示子程序 | **H** |
| 有没有「逐行用哪个表情」数据 | **有.** `SCRIPT.SRC` 里 **11,614 条**立绘状态赋值，覆盖 **2,137/2,137** 张 ST 立绘（100%）；其中 **6,996 条（60%）** 紧邻（前 16 条指令内）一条 `text` 台词命令 | **H** |
| 表情语义（槽位 → calm/happy/…） | **没有**任何字符串/注释给出语义；脚本只给「哪一行用了哪个槽位」。语义仍需人工标定，但现在可以**按实际使用频率**标，而不是盲标 115 张 | **H（负）** |
| `face_init/face_set/face_cls` 是什么 | **不是立绘**：`face.pac`（500×410 的「脸部/头像」层，`FA01A_A010…`）是独立于全身立绘的一套图层；脚本里每个命令只有 1 个调用点（在同一个共享「脸部显示」子程序内），具体用于对话窗 / 战斗 UI / 回想未定，但**不驱动 ST 立绘** | **M（否定 H）** |
| 旧报告 §6「0x4CF5C0 是 ST 静态表」 | **误读. `0x4CF5C0` 是 Windows LCID → locale 名（`0x409 en-US`、`0x411 ja-JP`…）表**，与立绘无关 | **H** |
| `WORK*.EXE` | 安装目录**不存在** `WORK*.EXE`；`totsulover.exe` 是保护壳/launcher（`.text` 仅 0x57A2、尾部 1.2 MB 载荷、导入 `ReadProcessMemory`/`WriteProcessMemory`/命名管道），真实引擎是脱壳后的 1,152,512 B PE | **H** |
| 权威标签可抽性 | **用法可抽（11,614 条，含行号/脚本偏移）**；**语义标签不可自动抽**，但用法频率能把人工标定减到「每角色前 10–14 个 base 槽位覆盖 80%」 | **H / M** |

**一句话**：这不是「脚本没有表情数据」，而是「**旧解码器只看 `call_ext` 操作数，漏了普通 VM 赋值指令里的数据**」。立绘用法数据量足够做 manifest v2 的 `usage` 元数据与标签校验，情绪名仍要人看。

---

## 1. 方法与证据等级

| 等级 | 本文用法 |
|---|---|
| **实测/反编译** | `game.exe`（脱壳镜像，1,152,512 B，ImageBase `0x400000`）的函数反编译、`SCRIPT.SRC` 全量指令解码、`FILE.DAT`/`TEXT.DAT` 全量解析 |
| **数据全量** | 734,961 条 VM 指令、79,378 条 `call_ext`、37,275 条台词命令、28,426 条 FILE.DAT 记录、11,614 条 ST 赋值 |
| **推断（明示）** | 「赋值紧邻的前一条台词 = 该立绘状态生效的行」这一时序解释（§3.3 给出两种可能，需要一条实机/录像验证） |
| **不采用** | 运行游戏、注入插件、读取存档格式未解部分当结论 |

**分析目标**：`/tmp/eidolon-re-full/ida/game.exe`（= `totsulover_crack.exe` 的副本，SHA-256 `a2d148…`），与目录里未被改写的 `111.exe` 逻辑相同（两者只差 3 字节的 DRM patch）。导出文件在 `/tmp/eidolon-re-full/out/data/`。

一次性脚本（可复跑）：

| 脚本 | 作用 |
|---|---|
| `/tmp/eidolon-re-engine/vm1.py`～`vm6.py` | Sv20 指令解码、`call_ext` 直方图、ST 赋值扫描、上下文与统计 |
| `/tmp/eidolon-re-engine/s1.py`～`s14.py` | IDA headless：字符串/xref、opcode/命令表定位、`sp_set_transition`/`face_*`/`history_*` handler 反编译 |
| `/tmp/eidolon-re-engine/stand_usage.json` | 11,614 条赋值的原始记录（脚本偏移、ST 名、局部槽位、gosub、邻接台词） |

---

## 2. 引擎与立绘子系统全貌

### 2.1 二进制与保护（对旧报告的补充）

| 文件 | 大小 | 判断 |
|---|---|---|
| `totsulover.exe` | 1,410,560 | **壳/launcher**：4 个 section，`.text` vsize `0x57A2`（约 22 KB），`.data` raw 仅 `0x1000`，文件尾 ~1.2 MB 是载荷。导入 `ReadProcessMemory` / `WriteProcessMemory` / `VirtualProtectEx` / `CreateNamedPipeA` / `ShellExecuteA` / `LoadLibraryA`，典型的解壳-注入式启动器 |
| `totsulover_crack.exe` / `111.exe` | 1,152,512 | **真实引擎镜像**（5 个 section，`.text` vsize `0xC82BF`）；两者只差 3 字节（DRM patch），逻辑相同 |
| `dll/Pal.dll` | 1,281,536 | T-Script 的 2D 引擎：Sprite / File(VFS) / Font / Sound / Movie / 窗口 |
| `dll/FX.dll` / `RESOURCE.dll` / ogg/vorbis | — | 特效 / 资源 / 音频编解码 |

**结论**：`WORK*.EXE` 不存在；不要为了找「战斗模块」去搜独立 exe。战斗演出同样在 `game.exe` 里，由同一套 graphic 图层系统驱动（§3.5）。

PE 版本资源：CompanyName `CRYSTALiA`，Comments `T-Script System -DL`（与旧报告一致）。

### 2.2 命令体系（复核）

- VM 帧格式、`call_ext`（opcode 23）、24 张模块表在 [`galgame-vm-stand-commands-2026-11-12.md`](galgame-vm-stand-commands-2026-11-12.md) 已证明，本文沿用。
- 本文新增的关键一条：**VM 原语**（opcode 1..33，不经 `call_ext`）里也有数据。`opcode 1` 的 handler `sub_459210` 反编译就是 `*(ref1) = *ref2`（赋值）；`opcode 31` = push。
- 因此 **立绘 id 不需要出现在命令参数里**：它是普通赋值语句的立即数。

### 2.3 立绘显示链路（本文核心）

```
SCRIPT.SRC（脚本字节码）
  opcode 1  : local[1] = <FILE.DAT id>        ← 11,614 条，id 的 FILE.DAT 名 = ST<CC><Outfit>_<Pose><Slot>
  opcode 31 : push local[1]
  opcode 11 : gosub <共享显示子程序>            ← 98% 紧跟在赋值后；top: label 0x3ED(8,466) / 0x3D1(2,259) / 0x3E7(196)
        │
        ├─ label 0x3ED  → PC 0xABF8 → gosub label 0x3E7 → PC 0xA99C
        │     0xAA94: local[0] = frame[1]              ← frame[1] = 调用方压栈的立绘 id
        │     0xA9C0: gosub 0x38D（内部调 module 18 系统命令）
        │     0xAA18: gosub 0x396（矩形/缩放）
        │     0xAAA8: call_ext 0x30032  sp_set_transition(name, layer, mode, time)
        │     0xAB0C: call_ext 0x3000C  set_filter
        │     0xAB60/0xABCC: call_ext 0x30025  sp_set_color
        │     0xABD8: call_ext 0x12001D（module 18 系统命令）
        │     回到 0x3ED: call_ext 0x160001 = run_no_wait（动画）
        │
        └─ label 0x3D1  → PC 0xA51C → gosub 0x3CF → PC 0xA2EC
              0xA2EC: sp_set_rect(0x30019) + sp_set_scale(0x30011) + 背景/演出命令
              （定位/无过渡的换图路径，14–22% 的用法）
```

关键 handler 反编译（伪代码，Hex-Rays 精简）：

```c
// cmd 0x30032 = sp_set_transition ；handler sub_44C180
name_id = pop(); layer = pop(); mode = pop(); time = pop();
if (name_id == 0x0FFFFFFF) return 1;          // -1 = 清空
resolved = sub_47D3D0(Str1, name_id, 1);       // FILE.DAT[id] -> 名字（如 "ST01A_A030"）
PalDebugPrintf(10, 0, "sp_set_transition  %s, %d, %d, %d", Str1, layer, mode, time);
/* 释放旧 sprite，建 transition handle，sub_4454D0/… 之后 sub_479900(name, …) 加载 .PGD */
```

```c
// load_pgd sub_479900（立绘/背景/头像共用）
  -> PalSpriteCreate / PalSpriteLoad（PAL.dll）
  -> PAL.dll 内 PGD 分派 sub_100C72E0：GE / PGD3 / raw 分支
（`GE`/`PGD3` 解码细节见 galgame-stand-runtime-2026-11-12.md §3）
```

**旁证**：FILE.DAT 末尾还有 `STAND_BASE`/`STAND_BTN_HIDE/NEXT/PREV`/`STAND_NUM2139`（id 6179–6183）与 `STAND.CSV`——它们是游戏内 **STAND EDIT 开发工具**的 UI 资源（`game.exe` 字符串 `STAND EDIT OK/CANCEL`，handler `sub_436EB0` 弹对话框），不是运行时立绘；`LIST_STAND.TXT` 的鼻子坐标也是给该工具的「漫符定位」用的。

**结论**：立绘是「ADV 图层（graphic layer）」，每层一个 `.PGD`（`st.pac` 里的 `STxx` 条目）；换表情 = 换该层的 FILE.DAT id（同一角色同一姿态的 `010` 底图与 `020..231` 差分槽位都是独立整图，引擎不合成差分，合成是我们离线提取时做的）。

### 2.4 `0x4CF5C0` 更正（旧报告线索 1 作废）

旧报告说 `0x4CF5C0` 起是一张 `(FILE.DAT id, name*)` 静态表、条目是 `ST01A_D161` 等。实测该地址落在 **Windows LCID 映射表**中间：

```
0x4CF5C0: 0x00000C01 -> "ar-EG"     0x00000C04 -> "zh-HK"
0x4CF5D0: 0x00000C07 -> "de-AT"     0x00000C09 -> "en-AU"
0x4CF5E0: 0x00000C0A -> "es-ES"     0x00000C0C -> "fr-CA"
…（表尾 0x4CF7D8 = 0x00007C1A -> "sr"）
```

它来自静态链入的 CRT/`setlocale` 支持，不是游戏资源表；也没有任何 `.text` 引用。**立绘资源表在运行时由 FILE.DAT 提供，exe 里没有预置 ST 列表。**

### 2.5 `face_*` 的真实定位（不是立绘）

- `face.pac`：94 张 `GE` + 1,150 张 `PGD3`，画布 500×410，名字 `FA01A_A010…`（即 500×410 的**脸部/头像层**，不是 2400×2048 的全身立绘）。
- `face_init/face_set/face_cls` = module 3 的 `0x30013/0x30014/0x30017`，handler `sub_44A6E0/sub_44A270/sub_44A1D0`，语义与旧报告一致（instance / slot / 锚点 / 名字）。
- 三个调用点在脚本里都只有 1 处，位于同一个共享子程序（入口 `PC 0xC5B8`，被 20 处 `gosub` 调用；`PC 0xC600–0xC940` 内是 `face_cls/face_set/face_init` + `sp_set_transition`/`sp_cls_transition` 的组合）。它处理的是 **500×410 的「脸」层**，不是 2400×2048 的全身立绘；用于对话窗、战斗 UI 还是回想尚未定（见 U6）。
- 汉化补丁/事件都不改变这个结论：**`face_*` 与「全身立绘用哪个表情」无关。**

---

## 3. 表情/姿态是怎么选的（数据与统计）

### 3.1 指令形态（可直接复现）

以 `ST01A_A030`（id 4034 = `0xFC2`）为例，`SCRIPT.SRC:0x172B1C`：

```
0x172b10  idx=23  call_ext 0x20002   ← text（台词 1832「…………」）
0x172b1c  01 00 01 00 | 01 00 00 40 | c2 0f 00 00
          opcode 0x00010001 (赋值)  ref1=local[1]  ref2=0x00000FC2
0x172b28  push local[1]
0x172b30  gosub 0x3ED
0x172b38  …（下一条：local[0]=0xC 等位置/参数设置）
0x172b9c  idx=23  call_ext 0x2000F   ← text（下一行 1834「では、何故？」）
```

靶站点（`game.exe` 侧）：

| 角色 | 地址/证据 |
|---|---|
| 赋值语义 | `opcode 1` handler `sub_459210`：`*v1 = v2`（`sub_458740` 解析带 tag 的类型化引用） |
| 立绘 id 解析 | `sub_47D3D0(name, id, 1)`：`FILE.DAT[id]` 的 32 B 名字（记录 = 32 B，名字在前 32 B NUL 填充） |
| 立绘加载 | `sub_479900` → `PalSpriteCreate`/`PalSpriteLoad`（PAL.dll）→ `.PGD` 分派 `PAL.dll:sub_100C72E0` |
| 显示命令 | `sp_set_transition` = cmd `0x30032`，handler `sub_44C180`，debug 串 `"sp_set_transition  %s, %d, %d, %d"` |

### 3.2 全量扫描结果

| 指标 | 值 |
|---|---|
| VM 指令总数 | 734,961 |
| `call_ext` 总数 | 79,378（module 3 = 9,689） |
| 台词命令（`0x20002`） | **37,275**（另有 `0x2000F` 2,554 等变体） |
| 立绘 FILE.DAT 记录 | **2,137** 张，命名严格为 `ST<dd><Outfit>_<Pose><Slot>`（如 `ST01A_A030`）；`ST` 开头共 2,153 条，其余 16 条是 `ST01..ST20` 基名、`STAND.CSV`、`STAND_BASE`/`STAND_BTN_*`/`STAND_NUM2139`（**STAND EDIT 工具**资源，非立绘） |
| **赋值总数** | **11,614**（写入 `local[1]` 11,550 / `local[0]` 44 / `local[2]` 20） |
| 覆盖的不同 ST 立绘 id | **2,137 / 2,137 = 100%** |
| 紧随 `gosub` 的比例 | 11,581（98.1%）；33 条无 gosub（异常/变体） |
| 前 16 条指令内有台词命令 | **6,996（60.2%）** |
| S 尺寸组（ST01..20） | 8,854 条 |
| LL 尺寸组（ST31..35） | 2,746 条 |
| 战斗 LL 组（ST41..45） | 14 条 |
| 其它 graphic id（同一机制） | `ETC_BATTLE_*` 2,459 条、`BA_FREESIA` 973 条等（§3.5） |

**显示子程序分布**（`gosub` label → 次数）：

| label | 次数 | 语义（推断） |
|---|---|---|
| `0x3ED`（PC `0xABF8`） | 8,466 | 带 `sp_set_transition` 的换立绘（主流） |
| `0x3D1`（PC `0xA51C`） | 2,259 | 走 `sp_set_rect` 的定位/无过渡换图 |
| `0x3E7`（PC `0xA99C`） | 196 | 直接调 `sp_set_transition`（不跑 `run_no_wait`） |
| `0xEA6` / `0x3D3` / `0xD0D` / `0xE9E` / `0x3F5` | 162 / 117 / 115 / 100 / 47 | 特殊演出/初次登场/战斗等变体 |

**每角色的使用量（S 组）与姿态分布**：

| 角色（S） | 次数 | 主要姿态（A..I） |
|---|---|---|
| 03 ソフィア | 1,770 | A 697 / D 424 / B 253 / E 152 / F 149 / C 95 |
| 01 夜乃桜 | 1,595 | **A 1053** / B 206 / D 108 / G 61 / E 55 / F 52 / I 31 / H 15 / C 14 |
| 04 崩月水仙 | 1,189 | B 400 / E 294 / A 245 / D 218 / C 18 / F 14 |
| 02 海漫華淡 | 1,075 | B 518 / E 273 / C 99 / F 69 / D 62 / A 54 |
| 05 崩月槐 | 667 | A 251 / B 237 / E 78 / F 57 / C 33 / D 11 |

> 姿态不是「每角色 9 个全用」：樱基本只用 A（站姿），Katan/Suisen 更多用 B/E（坐/侧），说明姿态是**按场景的身体状态**选的，而不是表情轴的一部分 —— 这解释了 `LIST_STAND.TXT` 里 `a..i` 是姿态、坐标随姿态变的原因（旧报告 §5.1 已解）。

**角色↔槽位绑定得到数据验证**：把「赋值紧邻的前一条台词的说话人名」与 ST 角色号交叉，命中 1,295 次（`桜→01` 371、`ソフィア→03` 399、`水仙→04` 202、`華淡→02` 162、`槐→05` 100、`N.a.v.i.→08` 57）。说话人名来自 `TEXT.DAT` 名字记录（如 `「…………」` 的名字 id = `？？？`）。所以 `ST01=桜、ST02=華淡、ST03=ソフィア、ST04=水仙、ST05=槐、ST08=N.a.v.i.` 这条绑定从「推断」升级为「数据验证」。

### 3.3 时序语义：赋值在哪一行生效？

实测形态（`0x172A34..0x172B9C`）：

```
wait / 演出
text 1831「もしかしてアイドルの子とかなのかな？…」      ← 旁白
local[1] = ST01A_A160 ; push ; gosub 0x3ED              ← 立绘状态 A
text 1832「…………」 名字「？？？」                       ← 台词
local[1] = ST01A_A030 ; push ; gosub 0x3ED              ← 立绘状态 B
text 1834「では、何故？」 名字「？？？」
```

- 指令是**状态设置**：设置后一直生效，直到下一次 `local[1]=ST…`。
- 赋值总是夹在两条 `text` 之间，**不会**与某条台词有显式句柄关联（VM 里没有「这条命令属于第几行」的字段）——与旧报告一致。
- 两种解释：**(a)** 赋值生效于**下一条**台词的显示（推荐；状态在下一行出现前就绪）；**(b)** 生效于上一条台词剩余显示时间。二者都是「行粒度」，差别只有 ±1 行。
- **验证方法（便宜）**：取一段已知剧情（例如公开 PV/实况或用户录像），把 §5 抽出的 20–30 行序列与 `TEXT.DAT` 台词文本按行对齐；或用 `.MIX`/voice id 定位台词后再对照。**不需要跑游戏**。

**置信度**：数据本身（脚本偏移、ST id、邻接台词）是 H；「紧邻哪一行」是 M，需要在生成器里做成可配置（`bind: next|prev`）。

### 3.4 一个「表情」到底是什么

- `ST<CC><Outfit>_<Pose><Slot>`，`Slot` 3 位：
  - `010` = 该（角色, 衣装, 姿态）的底图 `GE`；
  - `020..231` = 该底图的整脸 XOR 差分（`PGD3`），一张对应一个「表情状态」；
  - 编号 `xx0/xx1`（如 `060/061`）是两个不同状态，不是图层叠加。
- 全量使用里，同一角色在剧情中会用到 **29–44 个不同槽位**、**21–23 个不同 base（前两位）**；`010`（无表情底图）只占 ~8%（樱 132/1595），**说明 AVG 里绝大多数行都有明确表情状态**。

**每角色实际使用 top base 槽位**（前 10，可据此排人工标定优先级）：

| 角色 | top base 槽位（次数） |
|---|---|
| 01 桜 | 04(220) 03(196) 16(174) 02(174) 01(132) 07(85) 05(80) 13(79) 06(75) 08(67) |
| 02 華淡 | 03(152) 04(102) 05(96) 07(79) 09(65) 01(59) 20(50) 22(48) 02(43) 10(42) |
| 03 ソフィア | 03(210) 02(166) 04(154) 05(144) 06(113) 16(93) 10(86) 13(78) 09(75) 23(71) |
| 04 水仙 | 03(150) 05(107) 04(93) 10(84) 08(83) 06(77) 15(66) 02(60) 01(58) 14(57) |

**覆盖率**：每角色只标前 **10–14 个 base** 就能覆盖 **80%** 的剧情用量（樱 10、華淡 14、ソフィア 14、水仙 13 个），标 14–18 个覆盖 90%。这比旧报告「主姿态 25–40 个编号全标」省一半以上。

### 3.5 同一机制驱动的其它图层（战斗/演出）

`ETC_BATTLE_*`、`BA_FREESIA` 等 graphic id 也用 `opcode 1` 赋值（`ETC_BATTLE_*` 2,459 条、`BA_FREESIA` 973 条），走同一套图形槽约定（`ETC_BATTLE` 在 `local[1]` 1,043 / `local[0]` 752 / `local[2]` 425…；`BA_FREESIA` 主要 `local[0]`），随后进入不同的 action/演出子程序（module `0x110000`/`0x160000`）。例：`SCRIPT.SRC:0x1A8`（脚本最前段）

```
opcode 1: local[2] = 800  →  FILE.DAT[800] = ETC_BATTLE_MATTHEW_B11
```

这说明**战斗演出与 ADV 立绘共用同一个 graphic 图层/资源机制**，只是资源在 `battle.pac`、图层参数不同。旧报告的「战斗/ADV 两套模块」应修正为「一套图层机制 + 不同归档/参数」。

### 3.6 运行时痕迹：存档与历史文件里也有立绘 id

- `save/save000.dat` 里出现 `st31`（13 次，位于 `0x13000` 起、步长 `0x7FF` 的字符串槽），`save998.dat` 里出现 `st45a`；
- `save/*.dat`、`hist*.dat` 的 `0x1B9E8` 起有 **560 B/条** 的记录数组，每条以 **FILE.DAT id + scale(1.0/1.0) + 尺寸** 开头（如 `4865 ST04C_A031`、`5357 ST31A_A030`）；
- 这些是**运行时序列化的 ADV 图层状态**（回滚/回想用；`sub_45C5F0` 恢复 ADV 状态、`sub_446280` = `AdvGraphicLoad` 按 128 B 头重建图层）。
- **未完全解**：560 B 记录数组的起始/终止、以及它是否按「每行一条」排列（见 U5）。但方向明确：**游戏自己会把立绘状态写进存档/历史，因此存在一条「运行时真值」旁路，未来可用于验证脚本用法。**

---

## 4. 已验证的具体 usage（3 条 ADV + 1 条战斗）

> 全部为「脚本偏移 → ST 资源名 → 上下文台词」的直接证据；`gosub` 都是 §2.3 的显示子程序。

| # | 脚本偏移 | 立绘 id / 资源名 | 角色/衣装/姿态/槽位 | 前一条台词（id） | 说话人 | gosub |
|---|---|---|---|---|---|---|
| U1 | `SCRIPT.SRC:0x1732C4` | 4109 = `ST01A_E050` | 01 / A / E / 050 | `1869`「連絡先は教えられないけれど」 | 桜 | `0x3ED` |
| U2 | `SCRIPT.SRC:0x176984` | 4796 = `ST04B_B140` | 04 / B / B / 140 | `2050`「兄さんの引きこもり！」 | 水仙 | `0x3ED` |
| U3 | `SCRIPT.SRC:0x167224` | 5758 = `ST33A_E020` | 33 / A / E / 020（LL·ソフィア） | `1475`「改めて――俺達の事を睨みつける。」（旁白）→ 下一行 `1476`「さて、それじゃあ――追跡開始と行くのだわ！」（名字 `1477`「？？？」） | —（旁白） | `0x3ED` |
| U4 | `SCRIPT.SRC:0x1A8` | 800 = `ETC_BATTLE_MATTHEW_B11` | 战斗演出层（`local[2]`） | 脚本最前段（战斗初始化） | — | 后续 action 命令 |

补充一条更直白的「表情随台词变化」序列（`SCRIPT.SRC:0x172AD4/0x172B1C`）：

```
text 1831（旁白） → ST01A_A160（樱·E 姿态·160 槽）
text 1832「…………」→ ST01A_A030（同一角色换表情）
text 1834「では、何故？」
```

**如何复核**：`TEXT.DAT` 记录 `id → [cp932][0][u32 id]`，偏移 = `text` 命令第 2 个 push + 4（如 `0x7B5D+4 = 0x7B61` → id 1451）。`FILE.DAT` 记录 32 B/条，`id 4032 = ST01A_A010`。

---

## 5. 权威数据结论与抽取器

### 5.1 结论

| 问题 | 结论 |
|---|---|
| 有没有权威「用法」数据？ | **有**：11,614 条（脚本偏移、ST 资源、姿态/槽位、邻接台词 id/说话人、显示子程序），可 100% 复现，覆盖 100% 的 ST 立绘 |
| 有没有权威「语义」标签？ | **没有**：脚本/CSV/配置/事件数据里都没有 `calm/happy/...` 或日文情绪名；只有槽位 id |
| 人工标定是否仍是最终来源？ | **是**，但**标定对象从「115 张全标」变成「每角色 top 10–14 base」**（80% 覆盖），并用 usage 频次与上下文校验 |

### 5.2 抽取器形态（建议实现为 `tools/totsulover_stand_usage.py`，只进工具不进包）

```python
# 输入：SCRIPT.SRC / POINT.DAT / TEXT.DAT / FILE.DAT（只读游戏目录，输出 build/）
# 复用 galgame-vm-stand-commands 的 nops/opcode 表；无需 game.exe
def extract(script, point, text, file):
    ins = decode_sv20(script)                       # 734,961 条
    st_ids = {i: name for i, name in enumerate(file) if is_stand_name(name)}  # ST.._...
    out = []
    for i, (pc, op, args) in enumerate(ins):
        if op == 1 and args[1] in st_ids:           # local[1] = ST id
            out.append(dict(
                script_pc=pc,
                st_id=args[1],
                st_name=st_ids[args[1]],
                char=..., outfit=..., pose=..., slot=...,      # 从名字切
                layer_local=args[0] & 0xFFFF,
                display_gosub=next_gosub(i),                   # 0x3ED/0x3D1/0x3E7/...
                prev_text=nearest_text_before(i, max_instr=16), # (text_id, name_id, voice)
                next_text=nearest_text_after(i),                # 需要 control-flow 感知，见 §3.3
                scene_label=nearest_point_anchor(pc),           # POINT.DAT 最近锚点
            ))
    return out    # 11,614 条
```

**覆盖与质量**：
- 11,614 条，覆盖全部 2,137 张 ST 立绘，98.1% 有明确显示子程序；
- 60.2% 有「紧邻前一条台词」，其余是场景建立时的初始状态（`0x8BC50` 一带的 `gosub 0x3D1` 序列就是「一次摆好整屏角色」）；
- 输出可稳定 diff（脚本不变即字节级一致）。

**附加产出（建议同时做）**：
1. `usage_histogram.json`：每角色 × base 槽位计数 + 覆盖率（§3.2）→ 决定人工标定顺序；
2. `context_sample.jsonl`：每个 ST 槽位抽 3–5 条前后台词 → 人工标定时不用自己找例子；
3. `character_binding.json`：用「说话人名 ↔ ST 角色号」统计（1,295 条命中）验证 `st01=桜…`，可写进 manifest 的 `characterKey` 证据。

### 5.3 对 v2 manifest 的建议（在旧报告 §9.2 上补字段）

```jsonc
{
  "source": {
    "archive": "st.pac",
    "labelSource": "script-usage+manual",     // 有脚本用法 + 人工情绪名
    "scriptDerived": true,                     // 用法来自脚本；语义不是
    "usageScript": "SCRIPT.SRC",
    "usageSites": 11614
  },
  "characters": [{
    "id": "sakura",
    "poses": [{ "id": "a", "expressions": [
      { "id": "030", "path": "images/sakura/a030.png",
        "emotion": "happy",                    // 人工
        "usage": { "count": 196, "rank": 2, "coveragePct": 80.0,
                   "displayRoutine": "0x3ED" } // 脚本统计，可选
      }
    ]}]
  }]
}
```

要点：
- **`id` 继续用游戏槽位**（`pose + 3 位槽`），`emotion` 只作可选标签；
- `usage` 是新增的**可复算元数据**（由 extractor 生成），供预览页排序/显示「游戏里最常用的表情」；
- 不要把 `labelSource` 写成 `manual`，也不要写「script-derived 语义」——**用法是脚本的，语义是人的**，这两个事实分开写；
- `source.scriptDerived: true` 不再等同于旧报告的「false」，旧报告（`galgame-vm-stand-commands` §9 第 2 条）的 `scriptDerived=false` 建议作废（见 §6）。

---

## 6. 对旧报告的修正

1. **`galgame-vm-stand-commands-2026-11-12.md` §6「脚本里没有表情数据」→ 错误。** 正确说法：`face_*` 与立绘无关且各只 1 个调用点；**立绘状态在普通赋值指令里，11,614 条**。旧结论的根因是只扫 `call_ext` 的操作数，没扫 `opcode 1` 的立即数。
2. **§6 线索 1「`0x4CF5C0` 是 ST 静态表」→ 误读。** 它是 LCID→locale 名表。
3. **`WORK*.EXE` 不存在。** `totsulover.exe` 是壳/launcher；真实引擎是 1,152,512 B 的脱壳镜像。
4. **`face_*` 的定位**：独立的「脸部/头像」层（`face.pac` 500×410，`FA*`），由入口 `PC 0xC5B8` 的共享子程序调用（20 处）；不是全身立绘，也不是逐行表情的来源（具体用途见 U6）。
5. **`galgame-stand-runtime-2026-11-12.md` §6.3/D4**：不再需要「人工标定 115 张全量」，改为「脚本 usage 提取 + 每角色 top 10–14 base 标定」；`source.scriptDerived` 取 `true`（用法）而不是 `false`。
6. **「战斗/ADV 是两套模块」→ 一套 graphic 图层机制**，资源归档与图层参数不同（§3.5）。

---

## 7. 未知与后续

| # | 未知 | 影响 | 建议下一步 | 量 |
|---|---|---|---|---|
| U1 | 赋值到底绑定「下一行」还是「上一行」 | 影响 usage 元数据 ±1 行 | 取 20–30 行用台词/voice id 与实况/录像对齐；或解 `text` handler 的显示时序（`sub_46FB90`） | 0.5 d |
| U2 | `local[0]`（44 条）/`local[2]`（20 条）的语义 | 影响多角色同屏与战斗用法 | 结合 display gosub 的 frame 参数约定（`0x8000000x`）反推 | 0.5 d |
| U3 | S 组（ST01..20）vs LL 组（ST31..35）的选择规则 | 影响 manifest 优先用哪套 | 统计「同角色两种 id 是否在同一场景并存」，对照 `STAND.CSV` 的 L/S 位置与 `MAX_TEXTURE` | 0.5 d |
| U4 | 战斗子系统完整链路（`ETC_BATTLE_*` → action/演出） | 战斗演出若要迁移 | 解码 module 17/22 的 `action_run` 参数与 action 数据来源 | 1 d |
| U5 | save/hist 里 560 B ADV 图层记录数组的结构 | 可作为运行时真值旁路 | 对 `hist*.dat` 按 560 B 对齐解析 + 与 `sub_446280`/`sub_45C5F0` 对照 | 1 d |
| U6 | `history_set_face_call/sound` 与 text 的绑定 | backlog 头像/语音复现 | 解 text handler 的 history append | 0.5 d |

> **优先级**：U1（便宜且直接决定 usage 元数据语义）> U3（决定包体/质量取舍）> 其余可延后。立绘落地本身**不被这些阻塞**：extractor 先用「前一条台词」作保守绑定，manifest 里标 `bind: prev`，真机前抽验即可。

---

## 8. 证据表

| ID | 事实 | 证据 |
|---|---|---|
| E1 | `totsulover.exe` = 壳（`.text` 0x57A2、1.2 MB 载荷、导入 ReadProcessMemory/WriteProcessMemory） | PE section 表 + 导入表 dump |
| E2 | 真实引擎 = 1,152,512 B 脱壳镜像；`111.exe`/`totsulover_crack.exe` 仅差 3 字节 | `cmp -l` + SHA-256 |
| E3 | `opcode 1` = 赋值 `*ref1 = *ref2` | `sub_459210` @0x459210 反编译 |
| E4 | `0x4CF5C0` 是 LCID→locale 名表 | 0x4CF400–0x4CF7D8 逐条 u32/UTF-16 解析 |
| E5 | `sp_set_transition` = cmd `0x30032`，handler `sub_44C180`，debug 串 `"sp_set_transition  %s, %d, %d, %d"` | `stand.txt`/`s11.txt` 表 dump + 反编译 |
| E6 | FILE.DAT = 28,426 × 32 B；`id 4032 = ST01A_A010`、`4033 = ST01A_A020` | `FILE.DAT` 全量解析 |
| E7 | 显示子程序 label 0x3ED → PC 0xABF8 → label 0x3E7 → PC 0xA99C → `sp_set_transition`(0x30032) | 脚本反汇编（`vm3.py`/`s7.txt`） |
| E8 | `ST*` 赋值 11,614 条；local[1] 11,550 / local[0] 44 / local[2] 20 | `vm6.py` 全量扫描 |
| E9 | 覆盖 2,137/2,137 张 ST 立绘（100%） | 同上 |
| E10 | 98.1% 赋值后 16 条指令内有 gosub；top 0x3ED=8,466、0x3D1=2,259 | 同上 |
| E11 | 60.2% 赋值前 16 条指令内有一条 `text`(0x20002/0x2000F) | 同上 |
| E12 | S 组 8,854 / LL 组 2,746 / ST41..45 14 | 同上 |
| E13 | 每角色 top base 槽位与 80% 覆盖率（10/14/14/13 个） | 同上 |
| E14 | 1,295 条「ST 角色号 == 前一条台词说话人名」命中（桜/華淡/ソフィア/水仙/槐/N.a.v.i.） | `vm6.py` + `TEXT.DAT` 名字记录 |
| E15 | 例子 U1/U2/U3 的脚本偏移、ST 名、台词 id — 见 §4 | 脚本反汇编 + `TEXT.DAT` 解码 |
| E16 | 例子 U4：`ETC_BATTLE_MATTHEW_B11` id 800 写入 local[2] @0x1A8 | 脚本反汇编 |
| E17 | `face_set/face_init/face_cls` 各 1 个调用点，同在入口 `PC 0xC5B8` 的共享「脸」子程序（20 处 gosub）；与 ST 立绘无关 | `s9/s11` 反编译 + 脚本反汇编 |
| E18 | `face.pac` = 94 GE + 1,150 PGD3，500×410（名字 `FA…`） | 旧报告 `inv.py`/`galgame-stand-runtime` §2.2 |
| E19 | save/hist 含 560 B/条、以 FILE.DAT id 开头的 ADV 图层记录（`ST04C_A031`/`ST31A_A030`…）；save 里另有 `st31`/`st45a` 字符串 | `hist00000001.dat`/`save000.dat`/`save998.dat` 扫描 |
| E20 | 脚本 734,961 条指令从 0x0C 解码到 EOF，指令边界与 POINT 锚点一致（8,786/8,786） | 旧 `decode.py` + `vm1.py` |

---

## 9. 工作量与决策建议

| 工作 | 量 | 说明 |
|---|---|---|
| usage extractor（§5.2） | **0.5–1 d** | 复用现有 Sv20 解码器；主要成本是「next line」控制流与异常过滤 |
| 人工标定（按 §3.2 优先级） | **0.5–1 d** | 每角色 top 10–14 base（80%）；context_sample 自动给例子 |
| manifest v2 增加 `usage` 字段 | 0.5 d | 生成器输出；Core 只校验不解释 |
| 其余（生成器/打包/Core/iOS） | 见 `galgame-stand-runtime-2026-11-12.md` §10 | 不受本文影响 |
| **合计新增** | **1.5–2.5 d** | 比旧报告「人类标定 1–1.5 d + 等 VM 真值（已否决）」更省，且产物可复算 |

**决策清单（更新旧报告 D4）**：

- **D4′ 表情标签**：用脚本 usage 排序 + 人工标前 10–14 base（推荐）／仍然全标 115 张（不推荐，多花 1–2 d 且 80% 的图用不上）。
- **D9 新**:是否把 `usage` 写进 manifest（推荐，体积可忽略；预览页可按「游戏里最常用」排序）。
- **D10 新**：「行绑定」默认 `next` 还是 `prev`（默认 `next`，生成器可配置，真机前抽验）。

---

## 10. 与既有报告的关系

| 报告 | 关系 |
|---|---|
| [`galgame-stand-runtime-2026-11-12.md`](galgame-stand-runtime-2026-11-12.md) | PGD/GE 解码、差分合成、包体/接入方案仍有效；§6.3/D4 的「情绪只能人工标定」被本文升级为「脚本用法可抽、语义人工但可减量」 |
| [`galgame-vm-stand-commands-2026-11-12.md`](galgame-vm-stand-commands-2026-11-12.md) | 帧格式/操作数/命令表仍有效；**§6 负结论被本文修正**（错在只扫 `call_ext` 操作数） |
| [`galgame-voice-mapping-2026-11-12.md`](galgame-voice-mapping-2026-11-12.md) | `text` 命令 4 操作数/voice 映射与本文的行定位互补；本文的 `text id` 解码沿用其结论（第 2 push + 4 = TEXT.DAT 偏移） |
| [`content-packs-galgame-gakumas-2026-11-11.md`](content-packs-galgame-gakumas-2026-11-11.md) | 引擎身份（T-Script System -DL）与 PAC/VFS 结论继续成立 |
