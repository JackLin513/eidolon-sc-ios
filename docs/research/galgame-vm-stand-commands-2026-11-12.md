# Sv20 脚本 VM 与立绘/表情命令解码（2026-11-12）

> 回答：#1 `galgame-full-migration-2026-11-12.md` §3.3 留下的「指令流帧格式未解」；
> #2 `galgame-stand-runtime-2026-11-12.md` §6.3 留下的「唯一真值来源是脚本 VM」是否成立。
>
> **结论先行**：帧格式已完整解开（100% 锚点验证）；立绘/表情命令已定位并反编译出操作数语义；
> 但**本作 `SCRIPT.SRC` 里 `face_init/face_set/face_cls` 各只出现 1 次**，
> 而且 `ST*`/`FA*` 资源 id 从未作为 `sp_*` 命令参数出现 ——
> **脚本里没有「逐行用哪个表情」的数据**，脚本导出标签这条路不成立。

---

## 0. 摘要（结论先行）

| 问题 | 结论 | 置信度 |
|---|---|---|
| 帧格式 | `u32 opcode`（必须 `HIWORD==1`，`low16` = 全局 opcode 索引）+ N 个 32 bit **类型化操作数**；N 由 handler 决定 | **H（已证明）** |
| 跳转表 | `POINT.DAT`：11,105 个 u32，**从尾部倒数索引**，`PC = entry + 12` | **H** |
| 解码验证 | 从 `0x0C` 起顺序解码 734,961 条指令，恰好结束于 EOF；**8,786/8,786** 个 POINT 锚点都是指令起点 | **H** |
| 命令规模 | 不是 68 条：**24 张分发表 / 11 个注册表 / 674 条命令**；68 条只是「文本窗口」那一组 | **H** |
| 外部命令调用 | opcode `0x00010017`（索引 23）= `call_ext`，两个内联字 `[cmd_id][ret_slot]`，`cmd_id = (module<<16)\|index` | **H** |
| 立绘/表情命令 | **不在 68 条里**；在 module 3（`0x3xxxx`）：`face_init 0x30013`、`face_set 0x30014`、`face_cls 0x30017` | **H** |
| 参数 | `face_set(file_id, instance, dx, dy)`；`face_init(instance, slot, anchor_x, anchor_y, y_offset)`；`face_cls(instance)` | **H（反编译）** |
| 角色/衣装/姿态/表情槽位编码 | 全部在 **FILE.DAT 文件名**里（`ST01A_A020` → 角色 01、组 A、槽 020）；命令只收一个 file id，没有独立字段 | **H** |
| 每行 vs 每场景 | 命令是「脚本位置上的状态设置」，与文本行**没有绑定关系** | **H** |
| 脚本能否给表情标签 | **不能给情绪名**：全脚本 `face_*` 各 1 次；`sp_set_ex` 贴图参数全是 UI/特效/背景。**但能给用法**：后续报告实测 `local[1] = ST…` 赋值 **11,614 条**（旧结论漏扫了普通赋值指令，见 [`galgame-stand-engine-2026-11-12.md`](galgame-stand-engine-2026-11-12.md)） | **H（负结论已被限定）** |
| `LIST_STAND.TXT` | 是 **STAND EDIT 工具**的数据（exe 里有 `STAND EDIT OK/CANCEL` 串），给「姿态 a..i × 漫符锚点坐标」，与剧情的「用哪个表情」无关 | **M** |
| `STAND.CSV` | `st↔vo` 通道 + x/y/高度补正；只帮「角色↔槽位/语音通道」，不帮表情语义 | **M** |

**对上游结论的修正**（两处）：

1. `galgame-full-migration-2026-11-12.md` §2.6 / §3.3：「68 条命令 = 全部命令」「`u16 op + u16 参数个数`」——都错。
   68 只是 `0x20000` 文本窗口模块；帧头是 `u32` 且高位是固定 `0x0001` 标签，参数个数不在帧里。
2. `galgame-stand-runtime-2026-11-12.md` §6.3：「唯一可靠的真值来源是脚本 VM」——**不成立**，见 §5/§6。

---

## 1. 方法与证据等级

- 只读分析：`/tmp/eidolon-re-full/ida/game.exe`（1,152,512 B，PE32，ImageBase `0x400000`）与
  `/tmp/eidolon-re-full/out/data/{SCRIPT.SRC,POINT.DAT,TEXT.DAT,FILE.DAT}`。
- IDA 9.5 + Hex-Rays：用 `idalib`（`~/.idapro/venv/bin/python3` + `idapro.open_database`）跑无头脚本，
  dump/decompile 了 opcode 表 326 个 handler、24 张命令表、11 个注册函数。
- 脚本侧用独立 Python 解码器（`/tmp/eidolon-re-vm-expr/`，一次性脚本，不入库），
  与 IDA 结论交叉验证：**指令边界 × POINT 锚点 8,786/8,786**。
- 置信度：H = 反汇编/反编译 + 数据全量验证；M = 单一证据或命名推断；L = 猜测。
- 没有运行游戏、没有 ASR、没有联网。

---

## 2. Sv20 帧格式（本次的核心新证据）

### 2.1 文件布局

```
off 0x00  u32 magic = 0x30327653 "Sv20"
off 0x04  u32 0x69D8A1A1      // 版本/校验（未用）
off 0x08  u32 code_start      // = 0x334，loader 写入 PC 的初值
off 0x0C  ...                 // 代码区（真正的第一条指令在 0x0C，0x334 是「主入口」之一）
```

`sub_477790`（loader）：`base=this+351892`、`PC(this+351900)=*(u32*)buf[8]=0x334`、
`this+351904=12`（POINT 目标值要 +12 才是指令地址）、`POINT.size=this+352072`。

### 2.2 解释器主循环（`sub_47C240`，0x47C240，786 B）

```c
// this = vm+351892 ; this[0]=script base, this[1]=end, this[2]=PC, this[5]=last opcode
while ( (pc = this->pc) != this->end ) {
    u32 op = *(u32 *)(base + pc);      // 读一个 32 bit opcode
    this->pc = pc + 4;                 // PC += 4（操作数由 handler 自己消费）
    this->last_op = op;
    if ( HIWORD(op) == 1 )             // ← 唯一合法 tag
        dword_4EB0A0[LOWORD(op)](vm);  // 直接查表调用
    else
        PalDebugPrintf(0,"unknown opcode %08x",op);
}
```

证据：`sub_47C240` 反编译（本项目 `s7.txt`）；表基址 `0x4EB0A0` 由字节 `0x4eb434 = 0x46DC50`
（text_cat handler）反推：`0x4EB434 - 229*4 = 0x4EB0A0`，与 `dword_4EB0A0` 全局数组一致。

**opcode 表**：`0x4EB0A0` 起 326 个槽（0..325），其中 19 个空洞 → **307 个有效 opcode**。
槽 `i` 的 handler 见 §7 附录（或 IDA 直接查）。

### 2.3 操作数：类型化 32 bit 引用（`sub_458740`，0x458740）

handler 用一个共享函数读内联操作数：`p = sub_458740(vm)` 返回**指针**，`*p` 才是值。
它按操作数高 4 bit（tag）决定指向哪块内存：

| tag | 含义 | 目标地址（`this` = vm 基址，单位 = dword） | 备注 |
|---|---|---|---|
| `0x0` | **立即数** | 值本身（低 28 位/全 32 位） | 最常见；`0x40000000` 不是立即数而是 tag 4 |
| `0x1` | 全局变量组 A | `this + this[(u16)v + 64670] + 64925` | 间接：先取线程局部值再加偏移 |
| `0x2` | 全局变量组 B | `this + this[(u16)v + 64670] + 70045` | 同上 |
| `0x3` | **操作数栈槽** | `this + (u16)v + 64606` | 与 SP(`this+286352`) 同一块栈 |
| `0x4` | **线程局部变量** | `this + (u16)v + 64670` | `0x40000000` = local[0]，最常用操作数 |
| `0x5` | 结构成员 | `this + idx + this[(u16)v+64670] + 65949` | 带二级索引 |
| `0x6` | MEM.DAT 相对数组 | `this[64599] + 4*((HIWORD&0xFFF) + this[(u16)v+64670]) + 16` | 64599 = MEM.DAT 基址 |
| `0x7` | MEM.DAT 二级索引 | 同上多一次解引用 | |
| `0x8` | **帧栈** | `this + this[71070] - (u16)v + 71071` | 函数帧/参数 |
| `0x9` | 返回值槽 | `this + 71069` | 命令返回值写这里 |

> 这解释了旧报告 §3.3 的困惑：`0x40xxxxxx` / `0x90xxxxxx` / `0x61xxxxxx` 不是「类型标签参数」，
> 而是**带 tag 的变量引用**。`0x40000000`=local[0]、`0x90000000`=返回值槽。

### 2.4 跳转：POINT.DAT 是「倒序标签表」

`POINT.DAT`：`_POINT_LIST_****`（16 B）+ `(44436-16)/4 = 11,105` 个 u32，非零 11,104、含 1 个 0，
去重 8,786。全部 4 字节对齐，范围 `0x29C..0x6A1D70`。

- `gosub`（op 11）/`jump`（op 9）/`jcc`（op 10）的目标是**标号号 `L`**（立即数）；
- 解析：`target = *(u32 *)(POINT + POINT.size - 4*L) + 12`；
  即**从 POINT 尾部向前数**，`L=0` 表示「无目标」（代码里显式判 0）；
- `+12` = loader 写入 `this+351904` 的常量，也就是「代码偏移基准」。

### 2.5 验证（这一步让格式从「候选」变成「证明」）

| 验证 | 结果 |
|---|---|
| 从 `0x0C` 顺序解码到 EOF | 734,961 条指令，`pc` 恰好 = 6,954,384 = 文件尾，无剩余 1 字节 |
| 从 `0x334`（loader 入口）解码 | 734,882 条，同样**恰好到 EOF**，只是前面 79 条属于 0x0C 段的函数体 |
| POINT 锚点 `(entry+12)` 是否都是指令起点 | **8,786 / 8,786 = 100%**（另外 79 个锚点落在 0x0C..0x334 区间，同样命中） |
| opcode 高位 | 全部 `0x0001xxxx`，没有例外 |
| 指令长度分布 | 4 B（无参）、8 B（1 参）、12 B（2 参），`idx` 决定 |

> 可复现：`/tmp/eidolon-re-vm-expr/decode.py`（一次性脚本，~60 行）。

---

## 3. 命令体系：68 条 ≠ 全部

### 3.1 两层分派

1. **opcode 表**（`dword_4EB0A0`，326 槽）= VM 内建指令 + 少数常用命令（文本/存档/系统/精灵）。
2. **外部命令表**：`call_ext` = opcode `0x00010017`（索引 23），
   内联 2 个字 `[cmd_id][ret_slot]`，`cmd_id = (module<<16) | index`：

```c
// sub_458D80 —— call_ext
u32 cmd = *(u32*)(base+PC); PC += 4;
u32 slot= *(u32*)(base+PC); PC += 4;
vm->ret_slot = slot;  vm->cmd_id = cmd;
table = dword_4D25B8[HIWORD(cmd)];       // 24 张表
if (table) return table[LOWORD(cmd)](vm);
```

`dword_4D25B8` 是 24 个指针（`0x4D25B8`），指向 24 张模块表；**模块 11/23 等槽位有别名/未用**。

### 3.2 模块清单（handler 名来自各 handler 里的 `PalDebugPrintf` 串）

| module | id 前缀 | 条数 | 语义 | opcode 表内有？ |
|---|---|---|---|---|
| 1 | `0x1000x` | 33 | **VM 原语**：赋值/算术/比较/逻辑/push/pop/jump/gosub/ret/call_ext | 是（槽 1..33） |
| 2 | `0x200xx` | 68 | **文本窗口**：`text_cat/text_show/text_clear/text_voice_play/tips_*/script_point` | 是（槽 210..277） |
| 3 | `0x300xx` | 123 | **精灵 + 立绘/表情**：`sp_*`（set/create/pos/alpha/scale/mask/anime）+ `face_init/face_set/face_cls` | 否（必须走 call_ext） |
| 4 | `0x400xx` | 28 | BGM | 是 |
| 5 | `0x500xx` | 26 | SE（`se_load/se_play/se_stop/se_set_*`）+ select（20..30） | 是 |
| 6 | `0x600xx` | 31 | select/跳过/自动/字体（0..10 select_*，12..31 skip_set/auto_set/font） | 是 |
| 7 | `0x700xx` | 20 | wait/同步（`wait_sync_*`/`wait_click`） | 否 |
| 8 | `0x800xx` | 47 | 按钮（`btn_*`） | 否 |
| 9 | `0x900xx` | 68 | 系统/字体/输入/跳过（`skip_set`/`load_font`/`set_font_*`） | 是（槽 136..203） |
| 10 | `0xa00xx` | 38 | **存档**（`save/load/save_set_*/thumbnail_*/save_point_*`） | 是 |
| 11 | `0xb00xx` | 30 | 影片（`movie_*`/`msp_*`）+ 系统别名（16..31） | 否 |
| 12 | `0xc00xx` | 30 | **文本模块的别名表**（+5 偏移；见 §3.4）+ `system_btn_*` | 否 |
| 13 | `0xd00xx` | 31 | 存档缩略图/标题（`save_get_title`/`thumbnail_set`） | 是（槽 280..310） |
| 14 | `0xe00xx` | 26 | 历史/回想（`history_*`） | 否 |
| 15 | `0xf00xx` | 31 | 调试（`debug_break`/`set_window_text`）+ action 别名 | 否 |
| 16 | `0x1000xx` | 29 | 特效（`shake`/`snow`/`sakura`/`raster`/`flush`）+ 影片别名 | 否 |
| 17 | `0x1100xx` | 48 | **action**（`action_run`/`action_push`/`action_loop_run`…） | 否 |
| 18 | `0x1200xx` | 164 | 系统工具（文件/字符串/玩家名/收藏/tips/存档读写/skip/网络） | 否 |
| 19 | `0x1300xx` | 28 | **module 3 的别名**（`sp_set 0x130008`、`face_set 0x13001A`、`face_cls 0x13001D`） | 否 |
| 20-23 | `0x1400xx..0x1700xx` | 27-29 | `random/abs` 等数学别名、task/thread 别名 | 部分 |

**注册表**：11 个 `sub_4046F0(this, id, handler)` 注册函数，共 674 条
（`sub_41CDA0`/`sub_420C50`/`sub_4272D0`/`sub_4394E0`/`sub_4542D0`/`sub_458580`/`sub_459240`/
`sub_461670`/`sub_466EC0`/`sub_472480`/`sub_475920`）。
它是 FNV-1a 哈希表（`sub_4046F0`：`h=0x811C9DC5; h=(h^b)*0x01000193`），
与 `dword_4D25B8` 的**静态数组**是两套并行机制（静态表给 VM；哈希表给 C++ 侧/工具按 id 调用）。

### 3.3 module 2（文本窗口，68 条）里**没有**立绘命令

`0x20000..0x20043` 的 handler 串只有：
`text_cat / text_show / text_clear / text_voice_play / text_set_btn / text_redraw /
 set_text_mode / text_vn_br / text_window_set_alpha / text_animation_set_mode /
 is_text_visible / is_voice_cut / tips_* / system_btn_* / script_point`。
**没有 face/stand/chara/pose/graphic 字样**。

### 3.4 别名表给模块 2 补上了「真实命令名」（重要）

module `0xc0000` 是**文本命令的别名表**：`cmd 0xc0000 + 5 + i` ↔ `cmd 0x20000 + i`
（例：`0xc0005 = 0x470E80 = text_init`、`0xc0018 = 0x46DC50 = text_cat`）。它带完整调试名：

| module 2 id | 名称 | 说明 |
|---|---|---|
| `0x20000` | `text_init` | 初始化文本窗 |
| `0x20002` | **`text`** | **台词/正文命令**（全脚本 37,275 次，最常见）|
| `0x20004` | `text_show` | 显示 |
| `0x2000F/10/11/12` | `text_w / text_a / text_wa / text_n` | 文本变体（等/追加/换行等） |
| `0x20013` | `text_cat` | 拼接文本（全脚本仅 1 次） |
| `0x20016` | `text_set_base` | |
| `0x2001B` | `text_set_rect` | |

> 修正旧报告 §2.6/§3.3：「`0x20002` = script_point」是误读 —— `script_point` 只是**每个 handler 入口的 trace 打印**，
> `0x20002` 的真实名字是 **`text`**（`PalDebugPrintf(…, "text  %s", …)`，见别名表 `0xc0007`）。
> 它弹 4 个参数；**没有证据表明其中含图形/表情 id**（实测：第 1 个恒 `0`，第 2 个是文本引用，
> 第 3/4 个是 `-1` 或 TEXT 类数值）→ 与立绘命令无关。

---

## 4. 立绘/表情命令（module 3）

### 4.1 命令 id 与 handler

| 命令 | cmd_id | handler | 栈出参个数 | 别名 |
|---|---|---|---|---|
| `face_init` | `0x30013` | `sub_44A6E0`（359 B） | 5 | `0x130019` |
| `face_set` | `0x30014` | `sub_44A270`（1,124 B） | 4 | `0x13001A` |
| `face_cls` | `0x30017` | `sub_44A1D0`（151 B） | 1 | `0x13001D` |

证据：module 3 表 `0x4EAE30[0x13/0x14/0x17]`；`0x4EAE30` 来自 `dword_4D25B8[3]`；
注册函数 `sub_4542D0` 里 `sub_4046F0(196627=0x30013, sub_44A6E0)` 等一一对应。

### 4.2 操作数顺序（伪代码，来自 Hex-Rays）

```c
// face_set 0x30014 —— sub_44A270
name_id = pop();  instance = pop();  dx = pop();  dy = pop();   // 出栈顺序
if (name_id != 0x0FFFFFFF) {                 // 0x0FFFFFFF = "无图"
    name = resolve_file_name(name_id);       // sub_47D3D0 → FILE.DAT 记录名
    slot  = vm->face[instance].slot;         // vm + 16*instance + 258260
    if (slot > 0x80) return 0;               // 128 个对象槽
    base_y = screen_h - vm->face[instance].base_y - vm->face[instance].slot + 4999;
    if (parse_name_meta(name)) base_y += 134 * n;   // sub_47A160
    obj = get_or_create_sprite(1, instance);        // sub_47AD60
    obj->image = load_pgd(name, base_y);            // sub_479900
    obj->pos  = anchor + (dx, dy);                  // 用 face[instance] 的锚点
    obj->scale/rotate/color = 默认值;
    obj->name_id = name_id;
    draw(obj);
}
// PalDebugPrintf("face_set  %s, %d, %d, %d", name, instance, dx, dy)

// face_init 0x30013 —— sub_44A6E0
instance = pop(); slot = pop(); ax = pop(); ay = pop(); yoff = pop();
if (slot+1 > 0x80) return 0;
face[instance].slot = slot;                  // +258260
face[instance].y_base = -134 * yoff;         // +258264
face[instance].anchor_x = ax;                // +258268
face[instance].anchor_y = ay;                // +258272
// PalDebugPrintf("face_init  %d, %d, %d, %d, %d", instance, slot, ax, ay, yoff)

// face_cls 0x30017 —— sub_44A1D0
instance = pop();
slot = vm->face[instance].slot;
release_face_object(vm + 732*slot + 164564); // sub_445360
// PalDebugPrintf("face_cls  %d", instance)
```

要点：

- **`instance`（0..N）是显示槽（左/中/右…），不是角色**；每个 instance 16 B 参数 + 一个
  732 B 的「face object」，object 里 128 个槽（`face[instance].slot`）。
- `name_id` 是 **FILE.DAT 记录下标**（`sub_47D3D0`：`name = *(buf + 32*id + 16)`，读 16 B 名 + 后续 16 B），
  所以 `ST01A_A020` = 记录 4033。
- 一帧只有一个 `name_id`：**角色/衣装/姿态/槽位全部编码在文件名里**，命令没有独立字段。
- `0x0FFFFFFF`（tag 0 立即数 `-1` 的低 28 位形态）= 「无图/清空」。

### 4.3 每行还是每场景？

- 命令是**脚本位置上的状态设置**（设置到下一次 `face_set`/`face_cls` 为止），
  **与 `text_*` 命令没有参数或句柄关联**。VM 里没有任何「这条命令属于第几行文本」的字段。
- 因此「TEXT id → 表情」只能靠**脚本里 `face_set` 与 `text_*` 的先后位置**推断（时间顺序），
  不存在显式映射。

---

## 5. 已验证脚本实例（全量扫描结果）

扫描方法：§2 解码器 + `call_ext` 的 `cmd_id` 过滤。全脚本 79,368 条 `call_ext`。

| 命令 | 全脚本出现次数 |
|---|---|
| `face_init 0x30013` | **1** |
| `face_set 0x30014` | **1** |
| `face_cls 0x30017` | **1** |
| module 3 合计 | 9,689（其余是 `sp_*`/`se_*`/`btn_*`/`select_*`） |

### 5.1 `face_set` 唯一实例：`SCRIPT.SRC:0x0C85C`

```
0x00c830  1f 00 01 00 00 00 00 00     push  #0                 (dy)
0x00c838  1f 00 01 00 00 00 00 00     push  #0                 (dx)
0x00c840  1f 00 01 00 00 00 00 00     push  #0                 (instance)
0x00c848  01 00 01 00 00 00 00 40 01 00 00 80   local[0] = frame[1]   (name_id ← 参数)
0x00c854  1f 00 01 00 00 00 00 40     push  local[0]           (name_id)
0x00c85c  17 00 01 00 14 00 03 00 00 00 00 00   call_ext(0x30014, 0)   ← face_set
```

- 解出的参数：`face_set(name_id=frame[1], instance=0, dx=0, dy=0)`。
- `name_id` 是**函数参数（帧变量）**，不是常量 → 这一处**静态无法解析出具体 ST 文件**。
- 可达性：该块是**条件跳转目标**（`0x0C810` 是 `jcc label 0x44E` → `0xC830`），
  不是死代码；`frame[1]` 在外层赋值（未在本段出现）→ **未解：这一处实际加载哪张图**。

### 5.2 `face_init` 唯一实例：`SCRIPT.SRC:0x0ACC40`

```
0x0acc08  push local[0]    0x0acc28  push local[0]
0x0acc30  push #0x1E      0x0acc38  push #0
0x0acc40  call_ext(0x30013, 0)   ← face_init
```

- `face_init` 弹 5 个出参；此处能看到的常量 push 只有 `#0x1E(30)`、`#0`，
  `local[0]` 由前面的 `idx 8 / idx 1`（异或、赋值）算出，其余 1 个来自更早的表达式 → **无法静态解析**。
- 所在函数起始标号 `0xAC464`（顺序执行进入，非跳转目标）。

### 5.3 `face_cls` 唯一实例：`SCRIPT.SRC:0x0C738`

```
0x0c730  1f 00 01 00 00 00 00 00     push #0
0x0c738  17 00 01 00 17 00 03 00 00 00 00 00   call_ext(0x30017, 0)  ← face_cls
0x0c744  1e 00 01 00 00 00 00 90     pop → 返回槽
```

- **这是唯一一个参数可静态确定的实例**：`face_cls(instance=0)`。
- 前后是 `sp_cls_transition`（0x3000D）等精灵清理命令，像一段「清场」代码。

### 5.4 与已知 stand 资产对照

- `FILE.DAT` 里 `ST01A_A010..A230` = 记录 4032..4058（27 条，含 A061/A081 等变体），
  全部 49 组 `ST*` 共 **2,153** 条；`FA*` 852、`SD*` 38。
- `face_set` 的 `name_id` 就是这些记录下标 —— **链路成立**（命令 → FILE.DAT → `ST01A_A020` → `st.pac`）。
- 但本作脚本里没有常量形式的 `ST*`/`FA*` 下标（见 §6），所以**没有一条可验证的 `TEXT → ST 槽` 实例**。

---

## 6. 为什么「脚本导出标签」不成立（负结论及其证据）

> **2026-11-12 追加修正（必读）**：本节结论**只对 `face_*`/`call_ext` 常量参数成立**，不能推广到「脚本没有逐行立绘数据」。
> 后续实测（[`galgame-stand-engine-2026-11-12.md`](galgame-stand-engine-2026-11-12.md)）发现：立绘由 ADV 图层 +
> `sp_set_transition`(0x30032) 驱动，脚本里有 **11,614 条 `local[1] = ST<CC><Outfit>_<Pose><Slot>`**（VM opcode 1 赋值的立即数）
> 覆盖 2,137/2,137 张 ST 立绘（100%）。本节保留为「`face_*` 不是立绘驱动 + 命令参数无 ST 常量」的证据，
> 但 §6 的最终结论「脚本不含逐行表情」**作废**。

三个独立的证据都指向同一结论：

**证据 A：`face_*` 几乎没被调用。**
全 6.95 MB 脚本、73.5 万条指令里，`face_init/face_set/face_cls` **各 1 次**（§5）。

**证据 B：精灵命令的贴图参数不是立绘资源。**
`sp_set_ex`（`0x30003`，2,702 次调用）的 `%s` 参数（第一个出参，`sub_47D3D0` 解析 FILE.DAT）
在 1,023 个「参数是常量」的调用里解析结果全部是：

```
#FF000000(254) #FFFFFFFF(117) #00000000(110) ETC_EFFECT(37) BA_FREESIA(36)
ETC_BATTLE(22) BK_BLACK(13) MASK20..00(各10) ANI_*(若干) ...
ST*/FA*/SD* = 0 个（唯一 1 个 "FAVORITE_B..." 是 UI 资源名，不是 FA 立绘）
```

`sp_set`(8)/`sp_create`(92)/`sp_text`(37) 同理：`#颜色`、`BGM_BTN_*`、`ETC_*`、`ANI_*`、`BATTLE_*`。
**没有一个 ST 立绘资源被精灵系统加载。**

**证据 C：立绘资源 id 在脚本里没有被当作常量引用。**
把 `[4000,6250]` 区间的立即数全部提取：`ST*` 的 id 段 4031..6183 与 TEXT id（1..70111）完全重叠，
因此「立即数落在 ST 段」不能证明是立绘 id；而按命令参数位置做约束（哪个命令吃 FILE.DAT id）后，
没有任何 ST*/FA* 命中。反过来，`TEXT.DAT` 的 37,275 条台词 id 分布正常。

**那么立绘到底谁画？** 现有证据只支持「**不在 SCRIPT.SRC 里**」：

- 线索 1：exe 里存在一张静态 `(FILE.DAT id, name*)` 表（`0x4CF5C0` 起，8 B/条），
  条目恰是 `ST01A_D161 / ST01A_D191 / ST01A_D220 / ST01A_E010 / ... / ST08A_B010` 这类
  **具体立绘变体**，且每条后面跟一个名字指针。这张表**没有被 `.text` 直接引用**（可能由
  基址+索引间接访问，或在 `Pal.dll`/战斗模块里用）→ 说明「立绘 = 预置资源列表」是引擎侧概念。
- 线索 2：`battle.pac` / `battle` 归档、`BATTLECUTIN_H02`、`STAND_BASE`/`STAND_NUM2139` 这类名字，
  以及 `ARCHIVE.DAT` 三种模式都挂 `st` —— 立绘更可能是**战斗/演出**用的图层，而不是剧情 AVG 立绘。
- 线索 3：剧情侧视觉演出走的是 `sp_*`/`action_*`/`fx_*`（背景、特效、UI 合成），
  与 `st.pac` 的 2,153 张立绘资源不是同一套。

> **未解（需要另一条路，不在本报告范围）**：`ST*` 到底由哪个子系统、哪份数据驱动。
> 可选验证：(a) 反编译 `Pal.dll` 的 `PalSpriteLoad` 调用方；(b) 找 `0x4CF5C0` 表的真正基址/访问者
> （很可能不是 `lea` 而是 `mov eax, [base + idx*8]`，需要按 `0x4CF000` 附近的表结构反推）；
> (c) 直接静态扫 `game.exe` 的 `.data`，看是否有按 `(角色,姿势,槽)` 三元组生成的 id 计算代码。

---

## 7. 生产抽取算法（`TEXT id → character/pose/slot/emotion`）

### 7.1 能抽的（建议做，成本低）

```python
# 伪代码；已在本机全量跑通（一次性脚本，不入库）
POINT = read_points("POINT.DAT")           # 11,105 个 u32
CODE  = read("SCRIPT.SRC")                  # 0x0C 起
def label_pc(L): return POINT[-L] + 12      # L 从 1 开始；L=0 = 无目标
NARGS = {1:2,2:2,...,9:1,10:2,11:1,12:2,...,23:2,30:1,31:1,...}  # 见 §2/§3

pc = 0x0C; stack = []
while pc < len(CODE):
    op = u32(CODE, pc); assert op >> 16 == 1
    idx = op & 0xFFFF; args = read_u32s(pc+4, NARGS.get(idx, 0))
    if idx == 31:   # push
        stack.append(eval_ref(args[0]))      # eval_ref: tag 0 → 常量；tag 4/8 → 变量（未知则 None）
    elif idx == 23: # call_ext
        cmd = args[0]
        n = ARITY[cmd]                       # ★ 需要每命令的出参个数（本报告 §4 已给出 face_*）
        call_args = stack[-n:]; del stack[-n:]
        emit(cmd, call_args, pc)
    ...
```

**ARITY 来源**（本报告已验证）：handler 里 `*(vm+286352) = sp-1` 的**执行路径**出参个数：
`face_set=4 / face_init=5 / face_cls=1 / text_cat=4 / text_show=1 / sp_set_ex=5 / sp_create=6`。
注意：handler 有分支时不能直接数静态 `pop`（`sub_46FB90` 两个分支各 4 次，会被数成 8），
要么人工过一遍 674 条，要么按「分支最大值」再校验（栈平衡）。

**产出**：

- 每条 `text_*`/说话命令的 **TEXT id**（`TEXT.DAT` 1..70111）、voice id、wait 参数；
- 每条 `face_set` 的 **FILE.DAT id**（若为常量）→ `ST01A_A020` → 角色 01 / 组 A / 槽 020；
- 每条命令的**脚本偏移**（可回填 frame/锚点）。

> **`text`（0x20002）的文本参数实测是「TEXT.DAT 字节偏移 − 4」而不是 id**：
> 全脚本 37,275 次调用里，第 2 个内联参数 `v` 都满足
> `TEXT.DAT[v+4 .. ]` 恰好是某条文本的起点（**37,275 / 37,275 = 100%**）。
> 其中 716 次的 `v ≤ 70,111`，与「按 id 读」在数值上重合（两种读法都能解出文本，
> 但按偏移读落在 TEXT.DAT 前段的 UI/调试串；按 id 读是台词/人名）→ **这一点尚未定论**，
> 交给「TEXT/说话人抽取」那条线验证（§10 U4）。对**立绘**没有影响。

### 7.2 抽不到的（**不要排期**）

- **每行表情候选**：脚本里没有数据（§6）。想得到「第 N 行用 `020`」只能：
  1. 人工看视频/实机（本任务禁止）；或
  2. 找一个**真正驱动立绘的子系统**（本报告未定位，§6 未解）。
- **emotion 语义**：即使拿到槽位，`020` 在四个角色语义不同（上一份报告 §5.2 已证明），
  仍需人工标定。

### 7.3 与 LLM 7 情绪运行时的结合方式

脚本这条路断掉后，端上「AI 文本 → 7 情绪」仍然是唯一运行时来源，组合方式建议：

```
LLM 输出 emotion ∈ {calm,happy,shy,surprised,sad,angry,thinking}
      → manifest v2 的 characters[].emotions[emotion] = "<pose>.<slot>"
      → 找不到/低置信 → 回退 defaultPose 的 slot 010（底图）
脚本派生的东西（若将来找到了别的数据源）只作为“离线标签”写进 manifest 的
      expressions[].label / usage，运行时**不读**它做决策。
```

---

## 8. `LIST_STAND.TXT` 与 `STAND.CSV` 到底帮什么

| 文件 | 实测 | 对「用哪个表情」 | 对 v2 manifest |
|---|---|---|---|
| `LIST_STAND.TXT` | 188 行 / 49 组；`"st01a_a",1209,572` 形式；第三段 `a..i`=姿态，坐标=**漫符（表情符号）锚点** | **不帮**。它给的是「每个姿态 9 个漫符的鼻子坐标」，不是剧情用法 | 可选：将来做「头顶漫符/气泡」时用；与 `ST01A_A0xx` 槽位无关 |
| `STAND.CSV` | 45 行 `x,y,高度补正,stNN,voNN`；四段（L/Battle/LL/LL-Battle） | **不帮**。没有槽位/表情列 | **帮**：「角色(st01..)→语音通道(vo01..)」与站位/高度补正；可作为 `characters[].characterKey`/`source` 的旁证（仍是推断，见上一份报告 §6.1） |
| exe 里的 `STAND EDIT OK/CANCEL` | 字符串证据 | 说明 `LIST_STAND.TXT` 是**开发期 STAND EDIT 工具**的数据 | 不需要进包 |

结论：两份文件**只能提供角色↔槽位/姿态/漫符锚点**，不能提供「剧情里什么时候用哪个表情」。

---

## 9. 对 `StaticStandManifest` v2 的建议（保持 v1 兼容）

现状（`EidolonCore/Sources/EidolonCore/StaticStandManifest.swift`）：
`format_version=1`、`characters[].expressions[emotion:path]`（7 情绪）、`files[size,crc32]`。
安装器只收 v1 + `mode=full` + `renderer=static`。

**建议 v2 数据形态**（沿用上一份报告 §9.2，补上本次结论）：

```jsonc
{
  "format_version": 2,
  "kind": "stand", "mode": "full", "renderer": "static",
  "franchise": "totsulover", "contentSetID": "totsulover.main.v1",
  "source": { "archive": "st.pac", "resolution": "S|LL|mixed", "height": 2048,
              "labelSource": "script-usage+manual", // ← 修正：用法有脚本来源，情绪名手工
              "scriptDerived": true },          // ← 修正：脚本有「用法」真值（11,614 条），但没有情绪语义
  "characters": [{
    "id": "sakura", "characterKey": "totsulover:sakura", "defaultPose": "a",
    "poses": [{
      "id": "a", "label": "默认",
      "expressions": [
        { "id": "010", "path": "images/sakura/a010.png" },                    // 底图
        { "id": "020", "path": "images/sakura/a020.png", "emotion": "calm",   // 人工标签，可选
          "label": "平静", "usage": "manual" },
        { "id": "061", "path": "images/sakura/a061.png", "label": "半眯眼" }  // 无 emotion 也允许
      ]
    }],
    "emotions": { "calm":"a.020","happy":"a.030","shy":"a.140",
                  "surprised":"a.150","sad":"a.080","angry":"a.120","thinking":"a.100" }
  }],
  "files": { "images/sakura/a020.png": { "size": 0, "crc32": "…" } }
}
```

**具体建议**：

1. **`id` 必须是游戏槽位**（`pose + 3 位槽`，如 `a.020`/`a.061`），不要用情绪当主键；
   这样与 `ST01A_A020` 一一对应，将来任何数据源（含找到真值后）都能回填。
2. **`emotion` 只作可选标签**，来源标 `manual`；**不要**写「script-derived」，
   **修正（2026-11-12）**：立绘由其后的 [`galgame-stand-engine-2026-11-12.md`](galgame-stand-engine-2026-11-12.md) 证明**有脚本用法**（11,614 条槽位赋值），
   所以 `source.scriptDerived` 应为 `true`，同时用 `labelSource: "script-usage+manual"` 说明「用法是脚本的、情绪名是人工的」。
3. **`label`/`usage` 允许任意字符串**（生成器读 `tools/stand_expression_map.json`，可人工改）；
   安装器只校验 `path` 在 `files` 里，`emotion` 不在 7 情绪内时记 warning 而不是报错。
4. **v1 兼容**：`format_version` 接受 `1...2`；v1 包行为不变（`expressions` 字典 → 7 情绪）。
   v2 时 `staticStandExpressions(characterID:)` 仍返回 7 条 URL（由 `emotions` + `defaultPose` 解析），
   新增 `staticStandCatalog(characterID:)` 返回 `[(pose, slot, emotion?, label?, URL)]` 供目录 UI。
5. **预览 UI**（`StaticStandPreviewView.swift`）：现在硬编码 7 情绪 + 一次一张；
   v2 下改成「按姿态分组的全槽位网格 + 7 情绪快捷键」，没标签的槽位显示 `a061` 之类，
   并显示 `source.labelSource`（告诉用户这是人工标定）。
6. **不要**为了「等脚本真值」而阻塞立绘落地：上一份报告的结论（预合成 PNG + v2 manifest）
   仍然成立，本次只是把「表情语义从哪来」明确为**人工标定**，并给出可替换的字段。

---

## 10. 未知与后续（按优先级）

| # | 未知 | 影响 | 建议下一步 | 量 |
|---|---|---|---|---|
| U1 | `ST*` 立绘由哪个子系统驱动（不在 SCRIPT.SRC） | 决定「脚本真值」是否彻底无解 | 反编译 `Pal.dll` 的 `PalSpriteLoad` 调用方；或按 `0x4CF000` 附近表结构反推 `0x4CF5C0` 表的访问者；或扫 `game.exe` 里 `id = f(char,pose,slot)` 的算术 | 1–2 d |
| U2 | §5.1/§5.2 的 `face_set/face_init` 实例：`name_id` 来自帧变量，静态未解析 | 若这些是唯一路径，则结论「无标签」更硬；若外层传常量，则可能还有极少标签 | 回溯外层函数参数（`gosub`/`jcc` 的入口约定），确认 `frame[1]` 是否由常量填充 | 0.5 d |
| U3 | 674 条命令的「出参个数」表 | 决定 TEXT/voice 抽取的准确率 | 用「分支路径最大 pop 数 + 栈平衡断言」自动生成，再人工抽查 | 1 d |
| U4 | `0x20002`（`text`，37,275 次）**4 个参数的语义**（本次已确认它是台词命令；但第 1 个出参恒为 0、第 2 个常是 TEXT id，第 3/4 个是 -1 或其它 id） | 决定 TEXT id / 说话人 / voice 抽取 | 反编译 `sub_46FB90` 全路径 + `sub_46C060/sub_46BE30/sub_46A6A0` 的参数含义，用 20 条已知台词对照 | 0.5 d |
| U5 | 说话人（角色）从哪来 | 「TEXT → 角色」是立绘/语音/记忆的公共前置 | 同 U4：`sub_46C060/sub_46BE30/sub_46A6A0` 的参数含义 | 0.5 d |

---

## 11. 工作量（本报告之后）

| 工作 | 量 | 说明 |
|---|---|---|
| 本次解码（已完成） | ~3 h | 帧格式 + 操作数 + 命令表 + 3 个 face 实例 |
| 生产级脚本解码器（工具侧，不入包） | 1 d | §7.1；输出 `(script_off, cmd, args, text_id?)` JSONL |
| 命令 arity 表自动化 | 1 d | §10 U3 |
| TEXT/voice/说话人抽取 | 1 d | §10 U4/U5；**与立绘无关**，但对话引擎/语音要用 |
| 「找 ST 真值源」 | 1–2 d | §10 U1；**可能无果**，建议先做 U1 再决定是否投入 |
| manifest v2 + 生成器 + 预览 UI | 见上一份报告 §9.3（app 6–9 d） | 与本次结论无关，照旧 |

---

## 12. 证据表

| # | 事实 | 地址 / 偏移 | 证据 |
|---|---|---|---|
| E1 | loader：`PC=*(u32*)(buf+8)=0x334`、`+351904=12`、POINT 基址/大小 | `sub_477790` @0x477790 | 反编译 + `POINT.DAT` 全量 |
| E2 | 帧 = `u32 opcode`，`HIWORD==1`，`dword_4EB0A0[LOWORD]` 调用 | `sub_47C240` @0x47C240 | 反编译；`0x4EB434=0x46DC50` 反推表基址 |
| E3 | opcode 表 326 槽 / 307 有效 | `0x4EB0A0..0x4EB5B8` | 文件字节 dump（`0xe8aa0` 起，PE 段映射） |
| E4 | 操作数 tag 表（0x0..0x9） | `sub_458740` @0x458740 | 反编译 switch |
| E5 | POINT 倒序索引 + `+12` | `sub_458E50/sub_458C10/sub_458A50` | 反编译 |
| E6 | 解码 734,961 条、EOF 对齐 | `SCRIPT.SRC:0x0C` | `/tmp/eidolon-re-vm-expr/decode.py` |
| E7 | 8,786/8,786 锚点命中 | `POINT.DAT` 全量 | 同上 |
| E8 | `call_ext` = op 23，2 内联字，`dword_4D25B8[HIWORD][low16]` | `sub_458D80` @0x458D80 | 反编译 |
| E9 | 11 个注册函数 / 674 条 / FNV-1a | `sub_4046F0` + 11 个 caller | 反编译 `sub_4046F0`；IDA `XrefsTo` |
| E10 | module 3 = 精灵+立绘（123 条） | `dword_4D25B8[3]=0x4EAE30` | 表 dump + 123 个 handler 的 `PalDebugPrintf` 串 |
| E11 | `face_init=0x30013 / face_set=0x30014 / face_cls=0x30017` | 表 `0x4EAE30+4*idx` | 表 dump；`sub_4542D0` 注册 |
| E12 | `face_set(name_id, instance, dx, dy)` 等语义 | `sub_44A270` @0x44A270 | 反编译（§4.2 伪代码） |
| E13 | FILE.DAT 记录 = 32 B，名字在前 16 B；`ST01A_A010`=4032 | `FILE.DAT` | Python 全量解析（28,426 条） |
| E14 | `sub_47D3D0` 按 `32*id+16` 取文件名 | `sub_47D3D0` @0x47D3D0 | 反编译 |
| E15 | `face_*` 全脚本各 1 次；实例偏移 0xC85C/0xACC40/0xC738 | `SCRIPT.SRC` | 解码器 + 字节 dump |
| E16 | `sp_set_ex` 的贴图参数无 ST*/FA*（1,023 个常量样本） | `SCRIPT.SRC` | 解码器 + FILE.DAT 解析 |
| E17 | 静态 `(id,name*)` 表含具体 ST 变体、无 `.text` 直接引用 | `0x4CF5C0` 起 | 字节 dump + 全 `.text` 扫描 |
| E18 | `LIST_STAND.TXT` = STAND EDIT 工具数据 | `game.exe` 串 `STAND EDIT OK/CANCEL` @0xD5418 | 字符串扫描（**M**，推断） |
| E19 | `STAND.CSV` = `st↔vo` + 位置 | `csv.pac/STAND.CSV` | 上一份报告 §2.9/§6.1 已实测 |
| E20 | module `0xc0000` = 文本命令别名表（`+5` 偏移），给出 `text`=`0x20002` 等真实名 | `dword_4D25B8[12]=0x4EB3D4` | 表 dump + 30 个 handler 的 `PalDebugPrintf` 串（`text  %s` @`sub_46FB90`） |
| E21 | 立绘命令的 `name_id` 是帧变量（`face_set` 实例） | `SCRIPT.SRC:0xC85C` 前序 `idx 1`（local[0]=frame[1]） | 解码器 + 指令 dump |

**一次性脚本位置**（不入库、可复跑）：`/tmp/eidolon-re-vm-expr/`
（`decode.py`、`instances.py`、`analyze*.py`、`workpe.exe` + IDA 无头脚本 `s2..s13.py`）。
