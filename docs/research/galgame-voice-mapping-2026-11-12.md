# 行 → 语音映射调研：`ディメンション凸ラバース!!`（Sv20 VM 静态解）

- 日期：2026-11-12
- 范围：`Galgame support/ディメンション凸ラバース!!/totsulover_dl/`（只读）、`/tmp/eidolon-re-full/`（既有 RE 产物 + 本次新增脚本/输出）、`/tmp/eidolon-re-vm-expr/`（另一位 agent 的 IDA 库，本次复用）。
- 目的：回答「**每一句台词配哪条 `voice.pac` 语音**」，并顺带补上 **立绘/表情命令（Sv20 VM 侧）** 的已证事实。**不使用 ASR、不调用付费 API、不运行游戏、不绕过保护。**
- 性质：调研结论，不是 spec / ADR / 已实现设计。**本报告只写一份，未改动游戏素材与译文；未把任何素材/语音/译文写进仓库。**
- 关联报告：`docs/research/galgame-full-migration-2026-11-12.md`（§2.5/§3.3/§5.5 的结论已被本报告修正）、`docs/research/galgame-stand-runtime-2026-11-12.md`（§5.2「编号补丁 020..231」、§9.2 manifest v2）。

---

## 0. 摘要（结论先行）

1. **映射已经解出来了，是确定性的静态映射，不需要 ASR。** 每句台词在 `SCRIPT.SRC`（Sv20）里是一条 **4 个操作数的命令**，操作数里直接带着 **语音 id**：它是 `FILE.DAT` 的 32 字节名字表下标，解析出 `VO01_0000` 这样的名字，加 `.OGG` 就是 `voice.pac` 的条目。
2. **覆盖率**：39,829 条剧情文本命令中 **22,127 条有语音（55.55%）**，其中 22,113 条直接映射到 Ogg、14 条映射到 `.MIX` 多人语音组；17,702 条无语音（叙述/主角内心/无配音配角）。
3. **四女主（桜/華淡/ソフィア/水仙）台词 100% 有语音**，合计 12,810 条；第 5 主角「槐」9,667 条里只有 3,146 条有语音（32.5%，其余为无配音的主角台词）。所以「4 女主」的语音是完整可拿的。
4. **引用完整性 100%**：22,104 个被引用的 Ogg 全部存在于 `voice.pac`，抽样/全量头部校验 0 失败；被引用语音总时长 **25.25 h**（22,104 条，均 4.11 s，最长 23.36 s，最短 0.13 s）。14 个 `.MIX` 引用成员的 Ogg 也全部存在。
5. **命令/VM 编码已完全解出**：指令是 4 字节字；`0x0001xxxx` 走内建 opcode 表；通用调用前缀 `0x00010017` 后跟「selector<<16 | index」字，再跟一个附加 dword；selector 2 是文本命令族（68 条命令），文本命令是 `0x00020002`（handler `sub_46FB90`），`0x0002000F` 是 `text_w` 变体（handler `sub_46EA60`）。
6. **顺带修正既有报告的一处结构错误**：`TEXT.DAT` 的记录布局是 `[u32 id][cp932 string][NUL]`，id **从 0 开始（0..70,111，共 70,112 条）**；旧报告按 `[string\0][u32 id]` 解析，导致「id 1..70,111」整体错位 1。这正好解释旧报告 §12.4 里「CHS 译文键 = 文本 id − 1」的差 1。
7. **ASR 明确否决**：既有路线里「用 Fish ASR 转写 24.55 h 再模糊匹配文本」是**错误且昂贵**的绕路（约 $8.8 + 转写错误 + 无法对齐），本报告证明官方数据里就有逐行语音 id。**以后不得再用 ASR 作为行→语音来源。**
8. **立绘/表情命令（VM 侧）**：立绘/表情命令是 module 3 的 `face_init/face_set/face_cls`（`0x30013/0x30014/0x30017`）；角色/衣装/姿态/表情编号编码在 **FILE.DAT 资源名** `ST<CC><Pose>_<Expr><NNN>` 里（`020..231` 是资源名后缀编号，不是命令操作数）。**脚本里没有「逐行用哪个表情」的数据**：`face_*` 全脚本各只出现 1 次、`sp_*` 贴图参数里没有 `ST*`/`FA*`（与并行报告 [`galgame-vm-stand-commands-2026-11-12.md`](galgame-vm-stand-commands-2026-11-12.md) 一致；我的独立核对见 §7）。→ 表情语义只能人工标定，不要排期「脚本导出表情标签」。

---

## 1. 方法与证据等级

| 等级 | 用法 |
|---|---|
| **实测** | 在 `/tmp` 对 `SCRIPT.SRC`（6,954,384 B）/`TEXT.DAT`（2,148,954 B）/`FILE.DAT`（909,648 B）/`voice.pac` 索引（22,135 条）跑解析；39,829 条文本命令 100% 解析成功；Ogg 头/granule 校验 |
| **反编译** | IDA Hex-Rays（复用 `/tmp/eidolon-re-vm-expr/workpe.exe` 的 IDB）+ 自写反汇编核对：VM 主循环、opcode 表、二级 dispatch 表、文本/语音/sprite handler |
| **文件事实** | 头部、条目名、`.MIX` 槽位、`STAND.CSV`/`LIST_STAND.TXT`/`st.pac` 索引 |
| **推断（明示）** | 角色↔通道对应（用名字记录与语音通道共现统计，非官方表）；「槐=主角」的定位 |
| **不采用** | ASR、运行游戏、插件/注入、绕过保护、把素材写进仓库 |

原型脚本与中间产物都在 `/tmp/eidolon-re-full/ida2/`（`mapping_raw.json`、`text_records.json`、`voice_index.json`、`final_stats.json`、`ops_full.txt`、`stand.txt`），不进仓库。

---

## 2. 权威映射机制（Sv20 VM）

### 2.1 脚本与 VM 基本事实（实测 + 反编译）

- `SCRIPT.SRC`：magic `Sv20`，`code = u32@8 = 0x334`；**指令是 4 字节字**，代码区从 `0x334` 开始。
- VM 状态（`this` = 脚本对象；单位字节）：脚本基址 `this+351892`（0x55E94）、大小 `this+351896`、PC `this+351900`（0x55E9C）、代码起点 `this+351908`（0x55EA4）、操作数栈 `this+258424`（0x3F178，64 槽）、SP `this+286352`（0x45E90）。
- 主循环（`sub_47C240` / `sub_47BC00`）：读 `w = *(u32*)(base+PC)`，PC += 4；**若 `HIWORD(w) == 1`** 则 `call dword_4EB0A0[LOWORD(w)]`，再按 handler 读取 N 个**类型化内联操作数**（N 由 opcode 决定）。完整帧格式与 734,961 条指令/8,786 个 `POINT.DAT` 锚点的全量验证见并行报告 [`galgame-vm-stand-commands-2026-11-12.md`](galgame-vm-stand-commands-2026-11-12.md)；本报告只用到其中 3 个 opcode（push/pop/gosub + call_ext）。
- `dword_4EB0A0`（VA 0x4EB0A0）是内建 opcode 表（0..209），例如：
  - `0x0001001F`（idx 31）= **push 操作数**：读下 1 个 dword，经 `sub_458740` 解码后压栈；
  - `0x0001001E`（idx 30）= pop 到变量；
  - `0x0001000B`（idx 11）= gosub；`0x00010017`（idx 23）= **通用命令调用前缀**（见 2.2）。
- 操作数解码 `sub_458740`（VA 0x458740，已反汇编）：读 1 个 dword，按 `value & 0xF0000000` 分派：
  - `0x0`（普通小整数/字符串偏移/索引）= **常量**（把原值放入临时槽返回指针）→ 这就是我们用的「常量 push」；
  - `0x1/0x2/0x3/0x4` = 变量槽（低 16 位是下标）；`0x5/0x6/0x7` = 结构体字段；`0x8` = 栈相对；`0x9` = 特殊槽。
- 所以脚本里 `0x0001001F` + `<小整数>` = 把该整数压栈；我们解出的 4 个操作数就是这样压的。

### 2.2 命令编码（这是旧报告缺的一层）

通用调用 `0x00010017` 之后固定跟 **两个 dword**：

```
word1 = (selector << 16) | index     # selector 选二级表，index 选表内 handler
word2 = 附加操作数（文本命令里恒为 0；写入 VM+286356）
```

二级表指针数组 `dword_4D25B8`（VA 0x4D25B8）：`selector → table`，`handler = table[index]`。实测 selector 与表：

| selector | 表地址 | 语义（已证） | 脚本出现次数 |
|---|---|---|---|
| 2 | 0x4EB3E8 | **文本命令族**（68 条，内部 id 0x20000..0x20043） | 40,467 |
| 3 | 0x4EAE30 | sprite/立绘/face 命令族（`sp_*`/`face_*`） | 9,689 |
| 5 | 0x4EB240 | SE（音效） | 5,227 |
| 7 | 0x4EB580 | wait / wait_click | 6,937 |
| 15 | 0x4EA8D4 | 调试/窗口等（表是 selector 17 的前移窗口） | 545 |
| 17 | 0x4EA910 | action（动作脚本）系统 | 5,466 |
| 22 | 0x4EAE08 | run / run_no_wait / run_stack（脚本调用） | 5,698 |
| 13 | 0x4EB500 | voice/bgv 控制 | 155 |
| 14 | 0x4EB030 | gosub/ret/数学/随机 等内建 | 59 |
| 18 | 0x4EAB70 | 文件/字符串工具（open_file 等） | 1,786 |
| 其余 | — | 8/16/9/10/12/… 见 `/tmp/eidolon-re-full/ida2/stand.txt` | — |

**文本命令族**（selector 2）实测：`0x00020002`（`sub_46FB90`，37,275 条）与 `0x0002000F`（`sub_46EA60`，`text_w`，2,554 条）是两种显示变体；`0x00020012`（`text_n`）和 `0x00020013`（`text_cat`）各只出现 1 次（拼接/补写，不是独立行）。旧报告把 `0x20013` 当「文本命令」是误判：它只出现 1 次，真正逐行文本命令是 `0x20002`/`0x2000F`。

### 2.3 文本命令的 4 个操作数（逐行解出）

`sub_46FB90` / `sub_46EA60` 都从操作数栈弹 **4 个值**（pop 顺序 = 栈顶到底）：

| 位置 | 来源（push 顺序） | 含义 | 取值域 |
|---|---|---|---|
| pop1 | 第 4 个 push（栈顶） | **voice id** | `FILE.DAT` 下标（6,297..28,423，指向 `VO*`），或 `0x0FFFFFFF` = 无语音 |
| pop2 | 第 3 个 push | **说话人名字 id** | `TEXT.DAT` 记录偏移，或 `0x0FFFFFFF` = 无名（旁白） |
| pop3 | 第 2 个 push | **台词文本 id** | `TEXT.DAT` 记录偏移 |
| pop4 | 第 1 个 push | 等待/标志（本作实测恒为 0） | 0 |

因此脚本里一行台词的字节形态恒为（实测 39,829/39,829 全部匹配，无例外）：

```
1F 00 01 00 | 00 00 00 00        ; push wait = 0
1F 00 01 00 | <text_off>         ; push TEXT.DAT 记录偏移
1F 00 01 00 | <name_off>         ; push 名字记录偏移（0x0FFFFFFF=无名）
1F 00 01 00 | <voice_idx>        ; push FILE.DAT 下标（0x0FFFFFFF=无语音）
17 00 01 00 | 02 00 02 00 | 00 00 00 00   ; 命令 (selector=2,index=2) + 附加 0
```

（`text_w` 变体只把最后一个 dword 换成 `0F 00 02 00`，参数完全相同。）

### 2.4 两个 id 空间

**（a）文本/名字：`TEXT.DAT` 的字节偏移**
- `TEXT.DAT` 布局（实测，修正旧报告）：16 字节头 = 12 字节 magic `_TEXT_LIST__` + `u32 count = 70,112`；随后 `count` 条记录：
  `[u32 id（0 起，0..70,111）][cp932 string][0x00]`
- 脚本操作数 = **该记录 `u32 id` 字段的文件字节偏移**（记录起点）；字符串在 **+4**。
  实测：39,829 个 text 操作数、28,662 个非空 name 操作数 **100% 落在记录的 id 字段偏移上**；解析出的 id 在脚本顺序上 **0 个逆序**（严格单调），且每行的 name id 恰好是 text id 的下一条（`2621/2622/2623/2624...`）——这是「文本记录 + 名字记录成对、按剧本顺序分配」的直接证据。
- `0x0FFFFFFF` = 无名字（旁白/无说话人）。

**（b）语音：`FILE.DAT` 的 32 字节名字表下标**
- `FILE.DAT` 布局：16 字节头（magic `_FILE_LIST__` + `u32 count = 28,426`）；随后 `count` 条 `char name[32]`。
- 下标 6,297..28,423 是语音条目：`VO01_0000`、`VO02_0431`、`VO97_0017`、`VO99_COM11A` 等。
- 解析：`FILE.DAT[voice_idx]` → 名字；`name + ".OGG"` → `voice.pac` 条目（22,135 条，`VO*` 全为大写）。
- `0x0FFFFFFF` = 无语音。
- 14 个 `VO99_*` 名字不在 `voice.pac`，而是 `.MIX` 多人语音组（文件名 `VO99_*.MIX`），见 §3.3。

**为什么「偏移」不是「id」**：把同一个操作数当 id 去查 `TEXT.DAT[28414]` 得到的是别处的台词，当 name 用会得到台词而非人名；当偏移查得到 `桜` 等人名并与语音通道 `VO01` 完全一致（§3.2），且 39,829 条全量自洽。故采用偏移解释。

---

## 3. 验证样本（可复跑）

### 3.1 逐行样本（脚本偏移 → 命令 → 操作数 → 解析结果 → 语音文件头/时长）

`script_off` 是 `SCRIPT.SRC` 文件偏移；`text_off/name_off` 是 `TEXT.DAT` 偏移（id 字段）；`voice_idx` 是 `FILE.DAT` 下标；时长由 Ogg 最后一页 granule ÷ 采样率算得。

| 角色 | script_off | 命令 | text_off→id | name_off→id | voice_idx → FILE.DAT 名 | voice.pac 偏移/大小 | 采样率/时长 |
|---|---|---|---|---|---|---|---|
| 桜 | 0x161E1C | 0x20002 | 28414→1362 | 28456→1363 | 6297 → `VO01_0000` | 887452 / 35408 | 44100 / 2.743 s |
| 華淡 | 0x18CCE0 | 0x2000F | 79609→2915 | 79682→2916 | 10543 → `VO02_0043` | 181941551 / 71954 | 44100 / 6.440 s |
| ソフィア | 0x182890 | 0x2000F | 61837→2370 | 61902→2371 | 13470 → `VO03_0055` | 331729288 / 52511 | 44100 / 4.568 s |
| 水仙 | 0x16FAFC | 0x20002 | 40892→1723 | 40969→1724 | 16524 → `VO04_0002` | 469847892 / 81209 | 44100 / 7.145 s |
| 槐 | 0x167840 | 0x20002 | 32607→1478 | 32660→1479 | 19290 → `VO05_0000` | 621154831 / 59182 | 44100 / 5.314 s |
| ミオ | 0x195288 | 0x2000F | 90661→3268 | 90708→3269 | 22477 → `VO06_0000` | 745009846 / 54298 | 44100 / 4.782 s |
| クラスメートたち | 0x193B38 | 0x20002 | 89218→3216 | 89247→3217 | 28394 → `VO99_COM11A`（.MIX 组） | — | 2 人混声（vo98+vo97） |
| 旁白（无语音） | 0x180E58 | 0x20002 | 60295→2322 | 60364→2323 | 0x0FFFFFFF | — | — |

- 上述 7 条有语音的样本，`voice.pac` 条目都存在、首 4 字节 `OggS`、Vorbis id 头采样率 44,100、单声道，时长与句长量级一致。
- 全量校验：22,104 个被引用 Ogg **全部存在**、**0 个坏头**、0 个解析失败。

### 3.2 通道 ↔ 说话人（用数据自证，不是 cast 表）

对「有语音且有人名」的行做共现统计（行数）：

| 通道 | 名字 | 行数 | 通道 | 名字 | 行数 |
|---|---|---|---|---|---|
| VO01 | 桜 | 4,177 | VO06 | ミオ | 952 |
| VO02 | 華淡 | 2,834 | VO10 | 清楓 | 892 |
| VO03 | ソフィア | 3,045 | VO16 | システム－大獄 | 467 |
| VO04 | 水仙 | 2,754 | VO98 | 其他女性（多人） | 392 |
| VO05 | 槐 | 3,146 | VO97 | 其他男性（多人） | 305 |
| VO09 | 桧木 | 1,055 | VO99 | 群体/怪物（38） | 38 |

这同时把旧报告 §2.3 的「待解：st05..st20 与名字的逐槽绑定」在**语音通道维度**上补上了：`VO01..VO05` 与 `桜/華淡/ソフィア/水仙/槐` 的对应是数据里直接出现的，不是 cast 表硬猜。

### 3.3 多人语音（`.MIX`）与边界情况

- 14 条台词的 voice id 指向 `VO99_*.MIX`（不在 `voice.pac`）。`.MIX` = 32 字节槽位数组，每个槽是 `voNN_NNNN` 语音 id：
  - `VO99_046_01` → `vo01_0601, vo03_0644, vo02_0540`（3 人同时）
  - `VO99_COM11A` → `vo98_0096, vo97_0017`（男女混）
  - `VO99_S06_01` → `vo29_0015, vo27_0019, vo28_0017`（3 人）
  - 其余 11 个同理（1–3 人）。
- 实测 14 个 `.MIX` 的全部成员（共 21 个 Ogg）都存在于 `voice.pac`。所以「一行多语音」= 这 14 条，处理方式是播放 `.MIX` 列出的所有 Ogg（或预混），**不是**一行为多条普通语音。
- 无语音的 17,702 条里：11,167 条无名字（旁白/系统），6,535 条有名字（槐 6,521 条 + 14 条怪物/系统名）。
- 22,127 条有语音的行里，**没有**「有语音但无名字」的行（有语音必有人名记录）；名字记录 157 种不同字符串。
- 9 个 Ogg 被 2 行共用（同一句语音复用），其余一行一文件。

---

## 4. 覆盖率量化

| 指标 | 数量 | 备注 |
|---|---|---|
| 剧情文本命令总数 | **39,829** | `0x20002` 37,275 + `0x2000F` 2,554；另有 2 条 `text_n`/`text_cat` 不计 |
| 有语音 | **22,127（55.55%）** | 22,113 直接 Ogg + 14 `.MIX` 组 |
| 无语音 | 17,702（44.45%） | 旁白 11,167 + 有名字无配音 6,535 |
| 被引用 Ogg | 22,104（22,118 个名字含 14 MIX） | 100% 存在；总时长 **25.25 h**，均 4.11 s |
| 四女主（桜/華淡/ソフィア/水仙） | 12,810 行，**100% 有语音** | 4,177 / 2,834 / 3,045 / 2,754 |
| 槐 | 9,667 行，3,146 有语音（32.5%） | 其余 6,521 为无配音主角台词 |
| 其他具名配角 | 6,185 行，6,171 有语音 | 其余 14 条是怪物/系统名（吸魂蟲、黒列車、化物…），无配音 |

> 结论：**「4 女主」的语音是 100% 可拿的**；全量语音覆盖约 55.6%，未覆盖的主要是旁白与主角无配音台词。若只要「有语音的行」，22,127 条即全部可交付。

---

## 5. 生产级提取算法（可直接实现）

### 5.1 输入 / 输出

输入（全部只读）：
- `totsulover_dl/data.pac` → `SCRIPT.SRC`、`TEXT.DAT`、`FILE.DAT`（也可用根目录 `SCRIPT.SRC`，与 pac 内同一份，SHA-1 一致）
- `totsulover_dl/voice.pac`（只读索引 + 需要时读 Ogg 头/尾）
- `totsulover_dl/csv.pac` → `STAND.CSV`、`LIST_STAND.TXT`（立绘元数据用）
- `POINT.DAT`（可选：场景/幕边界锚点）

输出（**不进仓库**，进本机内容包构建目录）：
```jsonc
{
  "format": "totsulover.voicemap.v1",
  "source": { "script_sha1": "...", "text_sha1": "...", "file_sha1": "...", "voice_pac_sha256": "..." },
  "lines": [
    {
      "script_offset": 1449500,          // SCRIPT.SRC 字节偏移
      "command": "text",                  // text | text_w
      "wait": 0,
      "text":  { "offset": 28414, "id": 1362 },   // TEXT.DAT 记录偏移 + 0 起 id
      "name":  { "offset": 28456, "id": 1363, "text": "桜" },
      "voice": {
        "file_id": 6297,                  // FILE.DAT 下标
        "name": "VO01_0000",              // FILE.DAT 名字
        "kind": "ogg",                    // ogg | mix | none
        "entry": "VO01_0000.OGG",         // voice.pac 条目（kind=ogg）
        "offset": 887452, "size": 35408,  // voice.pac 内偏移/大小
        "duration": 2.743,                // 可选，Ogg 校验时算
        "mix_members": null               // kind=mix 时为 ["VO98_0096", ...]
      }
    }
  ]
}
```

### 5.2 算法（伪代码）

```
1. 解析 TEXT.DAT:
     hdr = magic "_TEXT_LIST__"; count = u32@12; p = 16
     while p < len: id = u32@p; e = index of 0x00 after p+4
                    records[p] = (id, cp932(p+4..e)); p = e+1
     offset_to_record = { p: (id, string) }        # 操作数是记录起点

2. 解析 FILE.DAT:
     count = u32@12; names[i] = NUL-terminated char[32] @ 16+i*32
     voice_names = {i: names[i] for i if names[i].startswith("VO")}

3. 解析 voice.pac 索引（只读头部 0x804 + count*0x28）:
     entry[name] = (offset, size)

4. 解析 .MIX（14 个）:
     mix[name] = [slot strings, 32B 步长]；校验每个成员 + ".OGG" 在 entry 中

5. 扫 SCRIPT.SRC（从 0x334 起，按 4 字节字扫描）:
     if word == 0x00010017 and next in {0x00020002, 0x0002000F}:
         assert 前 8 个 dword 恰为 4 组 (0x0001001F, value)
         wait, text_off, name_off, voice_idx = 4 个 value（push 顺序）
         rec = offset_to_record[text_off]；name = offset_to_record.get(name_off)
         voice = 解析 voice_idx（0x0FFFFFFF→none；在 mix→mix；否则 names[idx]）
         emit line(script_offset=prefix_off, ...)

6. 校验（全部是硬断言，失败即拒绝出包）:
     a) 文本命令数 == 39,829（37,275 + 2,554）
     b) 4 组 push 模式匹配率 == 100%
     c) text_off/name_off 命中率 == 100%（name 可为 0x0FFFFFFF）
     d) text id 在脚本顺序上严格单调（0 逆序）
     e) 每个 voice 名字 + ".OGG" 存在于 voice.pac（或属于 .MIX 且成员齐全）
     f) 每个引用 Ogg：size>0、前 4 字节 "OggS"、末页 granule/采样率 = 时长（0.1–30 s 合理区间）
     g) 计数断言：有语音 22,127；无语音 17,702；四女主 12,810 全有语音
7. 输出 JSON/SQLite；由内容包构建器读取，不把语音/文本写进仓库。
```

### 5.3 非语音行 / 多语音 / 边界处理

| 情况 | 判定 | 处理 |
|---|---|---|
| 旁白/无说话人 | `name == 0x0FFFFFFF` 且 `voice == 0x0FFFFFFF` | `voice.kind=none`；不参与语音 |
| 有名字无配音（主角台词等） | `name` 有效、`voice == 0x0FFFFFFF` | `voice.kind=none`；播放时按「无语音」走文本自动推进 |
| 普通逐行语音 | `voice` 在 `FILE.DAT` 且 `+".OGG"` 在 `voice.pac` | `kind=ogg` |
| 多人语音 | `voice` 是 `VO99_*` 且 `name+".OGG"` 不在 `voice.pac` | `kind=mix`，`mix_members` 列出成员；播放端可并行播或预混 |
| 同一语音复用 | 9 个文件被 2 行引用 | 正常，输出两条 line 指同一 entry |
| 文本 id/名字 id 偏移重复 | 实测 0 次 | — |
| 无 Ogg 的 voice id | 实测仅 14 个 `VO99_*`，全部由 `.MIX` 解释 | 不视为死引用 |

### 5.4 工作量

- 解析器 + 校验脚本：**约 0.5 天**（~250 行 Python；依赖仅标准库）。
- 接入现有 `tools/import_totsulover_story.py`（`episode_lines` 加 voice 字段 + 生成器读取）：**约 0.5–1 天**。
- 全量跑一遍 < 1 分钟（voice.pac 只读索引；可选时长校验 ~2 s / 22k 条）。
- 结论：**1–1.5 工程师日**可交付「TEXT id → speaker → voice file」全量映射；不含把语音接进 app 播放（那是另一条线）。

### 5.5 下一个代码接缝

1. `tools/import_totsulover_story.py`：目前 `episode_lines` 没有 voice 字段——在这里加 `voice: {entry, offset, size, duration?}`；`episode_lines` 的 `text` 来源应改为「脚本偏移 → TEXT.DAT 记录」而不是「TEXT.DAT id 顺序」。
2. 新增 `tools/extract_totsulover_voice_map.py`（只读游戏目录，输出到内容包构建目录）：本报告 §5.2 的算法 + 硬断言。
3. 内容包 schema：`kind=content` 的 line 增加 `voiceEntry`（`voice.pac` 内条目名 + 偏移/大小），语音资源由构建器从 `voice.pac` 抽取，**不进仓库**。

---

## 6. ASR：明确否决（这是已经付过代价的错路）

- 旧报告 §5.5 的路线 1「Fish ASR `transcribe-1-pro` 转写 24.55 h（约 $8.8），再用 TEXT.DAT 模糊匹配」是**错误且昂贵的**：
  1. 官方数据里**逐行**就有 voice id，且 22,127 行 100% 可解析，不需要任何识别；
  2. ASR 会引入转写错误，而「模糊匹配」又需要人工/阈值兜底，误差不可控；
  3. 24.55 h 里本来就包含大量旁白/BGM 干扰段，转写质量进一步下降。
- **结论：ASR 不是行→语音的来源，本作也不需要 ASR。后续任何「语音→文本」需求都必须先检查 `SCRIPT.SRC` 的 voice 操作数；不得再为这个映射调用 ASR / 付费 API。**

---

## 7. 立绘/表情命令（Sv20 VM 侧）——与并行报告对齐

> 背景：立绘运行时报告已解出 `st.pac` 的 `GE `/`PGD3` 解码与「表情 = 底图 + 一张编号补丁 PGD3」；并行的 [`galgame-vm-stand-commands-2026-11-12.md`](galgame-vm-stand-commands-2026-11-12.md) 已完整解出帧格式与立绘/表情命令。本节只做**交叉核对**并给 manifest v2 建议，不重复其推导。

### 7.1 已证（两报告一致）

- **帧格式**：`u32 opcode`（`HIWORD==1`，`low16` 查 `dword_4EB0A0`）+ N 个 32 位**类型化内联操作数**（N 由 opcode 决定；如 `0x0001001F` = push 有 1 个立即数，`0x00010017` = call_ext 有 2 个：`cmd_id` + ret_slot）。从 `SCRIPT.SRC:0x0C` 顺序解码 **734,961 条指令恰好到 EOF**，**8,786/8,786** 个 `POINT.DAT` 锚点都是指令起点（见并行报告 §0/§3）。本报告 §2 的「4 组 push + 1 条 call_ext」正是这个帧格式在文本命令上的实例。
- **立绘/表情命令**是 module 3 的 `face_*`（命令字 `0x0003xxxx`，handler 已在 `/tmp/eidolon-re-full/ida2/stand.txt` 反编译）：
  - `0x30013` = `face_init(instance, slot, anchor_x, anchor_y, y_offset)`（handler `sub_44A6E0`）
  - `0x30014` = `face_set(file_id, instance, dx, dy)`（handler `sub_44A270`）
  - `0x30017` = `face_cls(instance)`（handler `sub_44A1D0`）
- **角色/衣装/姿态/表情编号编码在 `FILE.DAT` 资源名里**：`ST<CC><Pose>_<Expr><NNN>`（如 `ST01A_A020`）。命令只收一个 `file_id`，没有独立的 character/pose/slot 字段；`020..231` 是**资源名后缀编号**（立绘报告的「编号补丁 020..231」），不是命令操作数。
- **`SCRIPT.SRC` 里没有「第几行用哪个表情」的数据**：全脚本 `face_init/face_set/face_cls` **各只出现 1 次**（`0xACC40` / `0xC85C` / `0xC738`，都在低地址工具函数里，实参全是变量）；`sp_*` 的贴图参数里没有 `ST*`/`FA*`。→ **表情编号语义只能人工标定**（立绘报告 §6.2），不要排期「脚本导出表情标签」。

### 7.2 我的独立交叉核对（支持上述负结论）

全脚本扫到 **601 处** `FILE.DAT` 的 `ST*` 文件 id 常量（push）。逐处核对上下文：

- **372 处在第一个 1 MB**（调试/工具脚本区）：典型形态是 `push ST_id → sp_text(0x30016)`（module 3 index 22，把 ST 文件名当文字画出来）+ `btn_set(0x80003)`（module 8 index 3）——正好对应 exe 里的 `STAND EDIT OK/CANCEL` 串，是**立绘编辑器的调试 UI**，不是剧情立绘；
- **其余 229 处**散布在剧情区，形态多为「`push ST_id` 后接赋值/比较/其他命令的参数窗口」，**没有一处作为 `face_init/face_set/face_cls` 的 `file_id` 实参**（这 3 条命令全脚本各 1 次，实参全是变量）；
- 唯一的「`sp_*` 直接收 ST 名」例外是 **2 处 `sp_set_ex`**：`0x11736C` / `0x1173A0`，文件名是 `STAND_BASE` / `STAND_NUM2139`（编辑器辅助图），不是角色立绘。

→ 与并行报告结论一致：剧情脚本**不含**逐行立绘/表情数据；manifest 只能来自 `st.pac` + `LIST_STAND.TXT` + `STAND.CSV` + 人工标定。

### 7.3 命令族参考（module 3：sprite/face，命令字 `0x0003xxxx`）

| 命令字 | handler | 语义（调试串） | 弹栈数 | 参数顺序（pop 顺序） |
|---|---|---|---|---|
| `0x00030002` | `sub_44CB40` | `sp_set %s, %d, %d` | 4 | filename_id、slot（0..0x80）、x、y（通用 sprite，UI/特效/背景用） |
| `0x00030003` | `sub_44C6A0` | `sp_set_ex %s, %d, %d, %d, %d` | 5 | filename_id、slot、x、y、附加（缩放/优先级） |
| `0x00030020` | `sub_448AD0` | `sp_create %d, %s, %d, %d, %d, %d` | 6 | slot、filename_id、x、y、priority、… |
| `0x00030039` | `sub_447130` | `sp_set_anime %d, %s, %d` | 3 | slot、ANI filename_id、循环标志 |
| `0x00030021` | `sub_4487D0` | `sp_anime_clear %d` | 1 | slot |
| `0x0003002E/2F` | `sub_447D30` / `sub_447C70` | `sp_show %d` / `sp_hide %d` | 1 | slot |
| `0x00030004/06/07/09/0E/0F/11/12/18/19` | — | 位置/透明度/缩放/旋转/优先级 | 2–5 | 见 `stand.txt` |
| `0x00030013/14/17` | `sub_44A6E0`/`sub_44A270`/`sub_44A1D0` | **`face_init` / `face_set` / `face_cls`**（立绘/表情系统） | 5 / 4 / 1 | 见 §7.1 |

- `filename_id` 高位带 `0x10000000` 时是**直接字符串 id**（不是 FILE.DAT 下标）；立绘/表情用普通 FILE.DAT 下标。
- `slot` 是 sprite/face 槽位（0..128），**不是**角色/表情编号。

### 7.4 建议：`StaticStandManifest` v2 元数据（在立绘报告 §9.2 基础上补 VM 侧字段）

在 `poses[].expressions[]` 条目上增加以下**可选**字段（向后兼容 v1）：

```jsonc
{
  "id": "020",
  "resource": "ST01A_A020",          // FILE.DAT / st.pac 资源名
  "characterCode": "01",             // ST<CC>
  "poseCode": "A",                   // ST..<Pose>
  "expressionLetter": "A",           // <Expr>
  "expressionNumber": 20,            // NNN，010..231（数值化便于排序/筛选）
  "variant": 0,                      // 个位 0/1/2
  "archive": "st.pac",               // 或 "patch.pac"（覆盖版本）
  "anchor": { "x": 1209, "y": 572 }, // LIST_STAND 鼻尖（按 st<CC><pose>_<a..i>）
  "basePosition": { "x": 1072, "y": 901, "heightCorrection": 1 }, // STAND.CSV
  "emotion": "calm",                 // 人工标定，可缺省
  "vm": { "command": "0x30014", "filenameSource": "runtime", "slotSource": "runtime" }
}
```

- **不要**把「逐场景使用情况」写进 manifest：脚本里没有该数据（§7.1），属于剧情/事件层，人工标定或另找来源。
- 角色↔槽位建议以数据自证为准：语音通道 `VO01..VO05` ↔ `桜/華淡/ソフィア/水仙/槐`（本报告 §3.2），比 cast 表硬猜可靠。

### 7.5 剩余未知（立绘侧）

1. 表情编号语义 → 人工标定（立绘报告 §6.2 已给提议表）。
2. **残留可能（低置信，不影响当前结论）**：`face_*` 各只有 1 个调用点，且实参来自变量；如果某个包装函数通过变量/全局槽接收「ST 文件 id」再调用 `face_set`，那么逐场景立绘数据理论上可能藏在变量赋值里，需要 VM 数据流仿真才能排除。并行报告的完整帧解码 + 本报告的常量扫描都没有发现这样的直接数据，故当前按「脚本里没有」处理；若要 100% 定论，下一步是对 `face_*` 所在工具函数做数据流/调用者分析。
3. `020..231` 是否在别处作为数字操作数出现：本报告在常量里没有找到作为 ST 文件名的该范围值；它们已证明是资源名后缀。若其他 agent 看到，需要地址/上下文再核对。

## 8. 对既有报告的修正建议（不改旧报告正文，供合并时采用）

| 位置 | 旧结论 | 本报告修正 |
|---|---|---|
| full-migration §2.5 | `TEXT.DAT` 70,111 条，id 1..70,111 | **70,112 条，id 0..70,111**；记录 = `[u32 id][cp932 string][NUL]`；旧解析把 id 标成了下一条（整体 +1） |
| full-migration §3.3 | 「文本命令 = 0x20013」「帧格式未解」「voice id 不在 TEXT.DAT 里」 | 逐行文本命令 = **0x00020002 / 0x0002000F**；帧格式已解（§2.2/2.3）；**voice id 在脚本里**，是 FILE.DAT 下标，`0x20013` 只是出现 1 次的 `text_cat` |
| full-migration §5.5 | 「文本↔voice id 映射还没解」+ ASR 路线 | **已解**；ASR 路线作废（§6） |
| full-migration §7 | 「语音映射是风险/待办」 | 降级为 **1–1.5 天工程**，算法/断言见 §5 |
| full-migration §2.3「待解」 | st05..st20 与名字无静态表 | 语音通道维度已解（§3.2）；立绘槽位维度仍需图像对号 |
| stand-runtime §5.2 / §9.2 / §13.6 | 表情编号 020..231、manifest v2、「脚本 VM 是唯一真值来源」 | 与并行报告 [`galgame-vm-stand-commands-2026-11-12.md`](galgame-vm-stand-commands-2026-11-12.md) 一致：立绘/表情命令 = `face_init/face_set/face_cls`；**脚本里没有逐行表情数据**（负结论，我的独立核对见 §7）；manifest 增可选字段（§7.4） |
| full-migration §12.4 | 「CHS 译文键 = 文本 id − 1」 | 这是旧解析整体 +1 造成的；按 0 起 id，译文键应 = 真实 id（建议合并时用 CHS `STRINGS.JSON` 抽样复核一次） |

---

## 9. 剩余未知与下一步（确定性）

1. **`TEXT.DAT` 访问器的 +4 约定**：脚本操作数 = 记录 `u32 id` 字段偏移，字符串在 +4；渲染器 `sub_47D310`（VA 0x47D310）按「Text.dat + 偏移」拷贝字符串。实测 100% 自洽（偏移解析、id 单调、name/voice 配对），但「访问器内部为何是 +4」未逐指令追平（`Text.dat` 指针由主 loader `sub_477790` 原样保存）。**不影响生产算法**（用偏移→记录表即可）；若要 100% 复刻运行时语义，下一步是单步追 `sub_47D310` 的实参/指针。
2. **立绘/表情逐场景状态**：已证**脚本里没有**（§7.1，与并行报告一致），不需要再做 VM 仿真/受控 trace 去恢复「逐行表情」；表情语义按立绘报告 §6.2 人工标定即可。唯一可选的后续是追 `face_*` 工具函数（`0xACC40`/`0xC85C`/`0xC738`）的调用者，但那不影响内容包交付。
3. **`.MIX` 播放语义**：成员 Ogg 同时播还是预混，需要看 voice 子系统（`sub_473560` 一带）的混音参数；对内容包只要「一行多语音」的成员列表即可，播放策略留给端上。
4. **CHS 译文键**：用真实 0 起 id 复核一次（§8 最后一行）。

---

## 10. 证据表

| 事实 | 证据 |
|---|---|
| 指令字/主循环/opcode 表 | `sub_47C240`、`sub_47BC00`（VA 0x47C240/0x47BC00）；`dword_4EB0A0`@0x4EB0A0；opcode 31=`sub_458980`（push）、30=`sub_4589D0`（pop 变量）、23=`sub_458D80`（通用调用） |
| 二级 dispatch | `dword_4D25B8`@0x4D25B8；selector 2 表 @0x4EB3E8；selector 3 表 @0x4EAE30 |
| 文本命令 handler | `0x00020002`→`sub_46FB90`（"text"）；`0x0002000F`→`sub_46EA60`（"text_w"）；`0x00020013`→`sub_46DC50`（"text_cat"，仅 1 次） |
| 4 参数弹栈 | `sub_46FB90` 反编译（`/tmp/eidolon-re-full/ida2/ops_full.txt` idx=212）与反汇编核对（0x46FC30–0x46FF00） |
| 操作数解码 | `sub_458740`@0x458740（llvm-objdump 反汇编，tag 0 = 常量） |
| TEXT.DAT 布局 | `_TEXT_LIST__` + count=70,112@12；`[u32 id][cp932 string]\0`；偏移→id 全量解析 0 失败 |
| FILE.DAT 布局 | `_FILE_LIST__` + count=28,426@12；`char name[32]`；语音名 6,297..28,423 |
| 文本/名字访问器 | `sub_47D310`（VA 0x47D310，Text.dat+偏移）；`sub_47D3D0`（VA 0x47D3D0，File.dat 下标×32） |
| 语音文件 | `voice.pac`：PAC，22,135 条 `VO*.OGG`；引用 22,104 条全存在，0 坏头；总时长 25.25 h |
| 通道↔名字 | 全量共现统计（§3.2） |
| `.MIX` | 14 个文件、32B 槽、成员全在 `voice.pac`（§3.3） |
| 立绘/表情命令 | module 3 表 + `stand.txt`：`face_init`=`sub_44A6E0`(0x30013)、`face_set`=`sub_44A270`(0x30014)、`face_cls`=`sub_44A1D0`(0x30017)；通用 sprite `sp_set/sp_set_ex/sp_create/sp_set_anime` 反编译 |
| 立绘资源 | `FILE.DAT` 2,147 个 `ST*`；2,137 个 `ST<CC><Pose>_<Expr><NNN>` 全部在 `st.pac`（`.PGD`），`patch.pac` 覆盖 221 |
| 负结论证据 | 全脚本 `face_init/face_set/face_cls` 各 1 次（0xACC40/0xC85C/0xC738，实参为变量）；601 处 `ST*` 常量消费者为 `sp_text`/`btn_set`（调试立绘编辑器）或变量赋值，无一处进 `face_*`/`sp_set*` 贴图参数；仅 0x11736C/0x1173A0 两处 `sp_set_ex` 收 `STAND_BASE`/`STAND_NUM2139`（辅助图） |
