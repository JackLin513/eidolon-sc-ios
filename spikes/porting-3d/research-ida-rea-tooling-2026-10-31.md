# IDA Pro 9.5 与 rea 6.8.0：分析超大 IL2CPP Unity iOS 二进制的工具现状

- 日期：2026-10-31
- 对象：`jp.co.bandainamcoent.BNEI0310` 的 `UnityFramework`（arm64 薄 Mach-O，158 MB / 165,765,984 字节，`LC_DYLD_CHAINED_FIXUPS`），配套 `global-metadata.dat`（Metadata v31，34,175,268 字节）；已有一个完整分析过的 IDA 数据库 `/private/tmp/mltd-ida/UnityFramework.i64`（702,090 个函数）。
- 工具：本机 IDA Professional `9.5.261026.365f1f33`（`/Applications/IDA Professional 9.5.app`）、官方 IDA MCP 插件 `20261028.0.3`（`~/.idapro/plugins/ida-mcp`，Claude Code 插件缓存 `~/.claude/plugins/cache/HexRaysSA/ida-mcp/20261028.0.3`）、`rea` 6.8.0（`/opt/homebrew/bin/rea`）。
- 本文只谈工具，不引用任何游戏资源；反编译/第三方代码片段均 ≤ 3 行。
- 约定：标「实测」的是本机跑出来的结果；标「未找到」的是查了但确认没有的。

---

## 0. 结论

能用的东西分两层。**一层是"名字"**：`rea 6.8.0` 的 `inspect-il2cpp-metadata` 不碰二进制的 8.7 秒内就能把 34 MB 的 `global-metadata.dat` 读成完整清单——本文实测拿到 `Imas.BoneLib.SwayBone` 的 37 个方法名、83 个字段名、参数名（如 `Init(rot)`、`SetManager(mgr0, cat)`、`SwayMove(delta_time)`）和 4 个嵌套类型；但它**给不出地址、字段类型和返回类型**，因为该二进制用 `LC_DYLD_CHAINED_FIXUPS`，rea 明确拒绝（`unsupported-pointer-encoding`），加上 `--binary` 也无效。**另一层是"地址与代码"**：官方 IDA MCP 在已经分析好的 702,090 函数库上打开/复用后，`execute_python` 里反编译一个 IL2CPP 方法只要 0.116 s（141 行），按名查函数 2.4 ms，全库扫一遍函数名约 5 s；IDA 9.5 新加的 `set_decompiler_timeout()`、`decompile_many(..., VDRUN_RECURSIVE)`、递归 Create C file 正好是为这种无头、大库、批量的场景准备的。所以现实路线是：**用 Il2CppDumper（或等价脚本）把托管名/类型灌进现有 .i64，再用 IDA MCP 做按名定位、反编译和批量导出**；rea 在这里的正确角色是"元数据目录 + 交叉核对"，不是"反编译后端"。另外，rea 的 `ida` provider 并不是官方 IDA MCP——它读 `REA_IDA_MCP_CONFIG` 指向的第三方 `ida-pro-mcp`，本机实测 `Connection refused`；而 rea 自己的二进制侧命令在这颗 158 MB 文件上会超时或拒绝，别把它当 IDA 的替代品。

---

## 1. IDA 9.5 里对我们真正有用的部分

### 1.1 招牌功能大多与本任务无关

9.5 的三个新反编译器是 Android Dalvik → Java、Infineon TriCore、Qualcomm Hexagon（来源：本机 `release-notes.html` 第 1–20 行 Highlights 表；`https://docs.hex-rays.com/release-notes/9_5`）。另有一批 AVX/SSE、PS3/Xbox 360/Wii U/PSP、MIPS R6、ARC、Armv9 的平台工作——对 arm64 IL2CPP 没有直接收益。

**IL2CPP / Unity：没有官方支持。** 对本机 2.5 MB 的 `release-notes.html` 做全文检索，`IL2CPP`/`il2cpp`/`Unity`/`unity` 命中数为 0；Hex-Rays 文档站也没有 IL2CPP loader 页面（来源：本机 release notes 全文 grep；`https://docs.hex-rays.com/release-notes/9_5`）。社区路线仍是 Il2CppDumper 生成脚本再喂给 IDA（见 §3）。

### 1.2 超大二进制相关的性能条目

本机 release notes「Performance & Resource Consumption」里与我们有关系的几条（原文摘句，来源：本机 `release-notes.html` 第 845–846 行）：

- 「auto-analysis of huge functions with flattened control flow (a dispatcher on a state register) drops from 1751 s to 253 s」——IL2CPP 生成的巨型 `switch` 状态机正属于这一类。
- 「decompiling a function with one 5506-instruction basic block drops from 2929 s to 148 s」。
- 「batch decompilation no longer slows down quadratically (8% faster on 26k functions, 11.8% on 74k)」。
- 「creating names in a reopened database no longer slows down as the database fills」——给 702,090 函数的库批量套 Il2CppDumper 名字时直接相关。
- 「database: enabling an address range no longer rewrites the whole database」（第 844/864 行）。

这些是"重分析/重命名变快"，不是"分析变短"：已经分析好的 .i64 仍然是最大资产。

### 1.3 递归反编译、批量反编译、无头超时（9.5 新增，实测可用）

本机 release notes 第 191–195 行：「Create C file… (Ctrl+F5) now offers "Current function and its callees recursively"」「Callees are decompiled first, from the leaves up, so every function is decompiled after the functions it calls」，并且「in batch mode with `-Ohexrays:-recursive`」。

API 侧（第 928–930 行）：「decompiler: `set_decompiler_timeout(msecs)` bounds a whole `decompile()` call (internal retries included) and fails with the new `MERR_TIMEOUT`; intended for headless and idalib runs, where there is no Cancel button」「`decompile_many()` with a null output file decompiles to the cache only, and `VDRUN_RECURSIVE` is exported; from IDAPython: `ida_hexrays.decompile_many(None, [ea], ida_hexrays.VDRUN_RECURSIVE)`」。

实测（在 158 MB 的 MLTD 库上，经 IDA MCP `execute_python`）：

```python
ida_hexrays.set_decompiler_timeout(60000)
ida_hexrays.decompile_many(None, [0x37EC030], ida_hexrays.VDRUN_RECURSIVE)
# -> True, 30.53 s（一个 IL2CPP 方法 + 其全部被调者，只进缓存不写文件）
```

`hasattr(ida_hexrays, "set_decompiler_timeout")` 与 `hasattr(..., "VDRUN_RECURSIVE")` 均为 `True`（实测）。这两条正是"Il2CPP 方法动辄上万指令、无头没有 Cancel 按钮"的解药：**给每次 `decompile()` 一个上限，再对根方法做递归缓存反编译**，比逐个手工 Ctrl+F5 稳。

### 1.4 数据库格式：`.i64/.idb` 与 `.id0/.id1/.nam/.til`

先解释这些文件是什么（来源：Hex-Rays 官方博客 Igor's Tip #174，`https://hex-rays.com/blog/igors-tip-of-the-week-174-ida-database-idbdetails`）：

- `.id0`：「the actual database (implemented using B-tree)」，存名字、注释、函数边界等分析产物。
- `.id1`：「the virtual array, containing a copy of all data loaded from the input file plus internal flags needed by IDA」，一般是输入文件的 4–5 倍。
- `.id2`：仅部分情况出现，「stores the data for sparse memory areas」。
- `.nam`：「a special cache for names used in the database」。
- `.til`：「the type library containing Local Types for the database」。
- 关闭时的三种选择：「Don't pack database」（最快、无完整性校验）、「Pack database (Store)」（合并成 `.idb`/`.i64` 并加校验和）、「Pack database (Deflate)」（zlib 压缩）。`.i64` 是 64 位地址空间的打包格式。

**9.5 的打包变化（来源：本机 release notes 第 851 行）**：「databases can be packed as several independent zstd frames (`PACK_ZSTD_FRAME_SIZE` in `ida.cfg`, in MB, default 32), so tools such as IDA Teams can decode them in parallel: checking out a 9 GB database went from 2.3 s to 0.3 s」。

怎么打开：`.i64` 直接当文件打开即可；只有未打包的散文件时，IDA 依靠同名的 `.id0/.id1/...` 承载同一个库（这一点是 IDA 的既有行为，本文未在 9.5 上单独验证）。9.5 另外修好一处：`idalib: an old .idb opened with idalib is converted to .i64 automatically, and the session continues on the converted database`（第 938 行）——用 IDA MCP 的 idalib 后端打开旧 `.idb` 不再需要手工转。

本任务的现实：库已经是 `/private/tmp/mltd-ida/UnityFramework.i64`，**永远优先打开 `.i64` 而不是 158 MB 的原始 Mach-O**；后者会重新跑 702,090 个函数的分析。

---

## 2. 官方 IDA MCP（Hex-Rays 第一方）

### 2.1 是什么、装了什么

官方仓库 README（`https://github.com/HexRaysSA/ida-mcp`，本机同版本文件 `~/.claude/plugins/cache/HexRaysSA/ida-mcp/20261028.0.3/README.md`）要求：「IDA 9.4 or higher with idalib and Python 3.11+」；并建议「We recommend disabling other IDA MCP servers to reduce agent confusion」。

本机状态：`~/.idapro/plugins/ida-mcp/ida-plugin.json` 版本 `20261028.0.3`，`idaVersions: ">=9.4"`，描述 `Expose IDA GUI databases through IDA Nexus for the official IDA MCP server.`（实测读取）。`rea doctor` 的 `ida-registration` 检查为 healthy，但明确写着「no IDA process was launched」（实测）。

### 2.2 只有六个工具，走"代码模式"

官方架构文档（`docs/ARCHITECTURE.md`）：「The process-wide ZeroMCP server exposes six tools」：

- `open_database(path, set_current=True)`
- `execute_python(code, instance_id=None, timeout=360)`
- `reference(query)`
- `list_databases()`
- `save_database(instance_id=None)`
- `close_database(instance_id=None)`

也就是说，模型不是调几十个窄工具，而是**写 IDAPython（ida-domain API）**。`reference(query)` 返回的是本机 IDA Domain API 文档，实测回包首行为 `IDA Domain API reference 0.5.1`。

`open_database` 的说明明确了复用语义（本机 `ida_mcp/mcp.py`）：「Runs IDA auto-analysis … in a headless worker, or attaches to the file already open in the IDA GUI」「A GUI instance is used when available.」；`gui` 默认 `False`，描述为「Only when the user explicitly asks for the GUI」。

### 2.3 与第三方 MCP 的区别

- 官方：6 个组合式工具 + 写 Python；Hex-Rays 博文（`https://hex-rays.com/blog/hex-rays-ida-mcp-server`）称其「roughly 20% lower token use than comparable servers」，理由是中间结果不必全塞进上下文。
- 第三方 `ida-pro-mcp`（`https://github.com/mrexodia/ida-pro-mcp`，本机 miniforge 里就有一份 `ida_pro_mcp`）：工具面完全不同，是 `list_funcs`、`decompile`、`set_comments`、`py_eval`、`idb_open/idb_list/idb_save`、`server_health` 等一长串；仓库 README 现在反过来推荐官方 IDA MCP，并说 GUI 插件路线「will eventually be deprecated」。
- 关键点：**两套服务不能混用**。本机 rea 的 `ida` provider 指向第三方（见 §4.4），而 Claude Code 里接的是官方，两者互不认识。

### 2.4 在本机大库上的实测延迟与行为

以下全部是在 `/private/tmp/mltd-ida/UnityFramework.i64`（702,090 函数）上经官方 MCP 跑的（实测）：

| 操作 | 结果 |
| --- | --- |
| `open_database("<...>.i64")` | 直接 attach 到已有 idat worker（返回同一 `instance_id`，`backend: "idat"`，`recovery: "repaired"`），没有重分析 |
| `list_databases()` | 同时列出测试用小库与 `UnityFramework.i64`（`backend: "idat"`，`status: "attached"`） |
| `db.functions.get_by_name("sub_37EC030")` | 2.4 ms |
| `db.functions.get_callers(f)` | 10 ms（6 个调用者） |
| `db.functions.get_pseudocode(f)`（IL2CPP 方法，141 行） | **0.116 s** |
| 遍历全部 702,090 个函数取名字 | 3.1–5.7 s（跑了几次，含字符串过滤） |
| `ida_auto.is_auto_enabled()/auto_is_ok()` | `True/True`（已分析完的库不会再排分析） |

结论：**打开 `.i64` 后，单函数交互的代价是毫秒到十分之一秒级**，可以放心让 agent 在库里按名检索、逐个反编译；慢的只有"打开/保存/递归批量"。

### 2.5 大库上的坑（都要按官方源码/文档对齐）

- **两个超时**：`OPEN_TIMEOUT_SECONDS = 300`、`EXECUTE_TIMEOUT_SECONDS = 360`（本机 `ida_mcp/mcp.py` 第 95–96 行）。`execute_python` 的 `timeout` 参数文档写着「This does not include the separate initial autoanalysis wait.」——大库首次打开时，等待分析的时间**不算在**这 360 s 里，客户端自己的工具超时反而可能先到。
- **超时是"请求中断"，不是强杀**：ida-nexus README（`https://github.com/HexRaysSA/ida-nexus`）说「Execution timeouts request interruption rather than forcibly terminating native calls」，所以一个阻塞的原生调用可能超时后仍在跑完。
- **租约（lease）**：`close_database` 的描述是「Release this session's lease … without disrupting other clients. If this is the final lease on a managed idalib worker … this call waits for the IDB to shut down.」；nexus 侧「closing it releases only that lease」，GUI 打开的库永不被关。多 agent/多会话可以同时挂同一个库。
- **worker 形态**：装了 GUI 插件时，无头 worker 是 `idat` 进程（用 IDA 自己的 Python）；没装时用客户端进程里的 idalib；`IDA_NEXUS_IDALIB_ONLY=1` 强制 idalib。本机 `backend: "idat"`，说明走的是前者。
- **避免重分析的三条**：(1) 传 `.i64` 路径而不是 Mach-O；(2) 同一路径重复 `open_database` 会复用 GUI/现有 worker，不会另起一个；(3) 不要在 `execute_python` 里调 `ida_auto.auto_wait()` 之类，前面已经 `ensure_autoanalysis` 过。
- **IDB 位置陷阱**：`save_database` 把 `.i64` 写在二进制旁边。实测对 `/Applications/.../idapyswitch` 调 `save_database`，返回 `/Applications/IDA Professional 9.5.app/Contents/MacOS/idapyswitch.i64`（写进 app bundle），该测试库已删除。大库请先把二进制/库放到可写的固定目录（本项目就是 `/private/tmp/mltd-ida/`）。

---

## 3. IL2CPP 实战：从 `Imas.BoneLib.SwayBone` 定位到方法与字段

### 3.1 现状：数据库里没有任何托管名（实测）

对现有 `.i64` 做全库名字统计（实测）：

```
func_qty 702090
named 87473   sub_ 614617
samples ['_UnityARKit_EnsureRootViewIsSetup', '+[UnityARKit loadPlugin]', 'j__objc_msgSend$hash', ...]
at 0x37EC030: sub_37EC030
```

即：**ObjC/Unity 的 C/ObjC 符号在，IL2CPP 的 `Imas.*` 名字一个都没有**（全库函数名搜 `"SwayBone"` 命中 0）。这符合 IL2CPP 的机制：托管名字不在原生二进制里，只在 `global-metadata.dat` 里；二进制里能导出的是 `_il2cpp_init`、`_il2cpp_method_get_name` 这类 API（实测库中 519 个含 `il2cpp` 的函数，`_il2cpp_method_get_name` 在 `0x84ba48`）。所以**必须先"灌名字"**。

### 3.2 推荐路线：Il2CppDumper → IDA 脚本

Il2CppDumper README（`https://github.com/Perfare/Il2CppDumper`）列出的产物：

- `dump.cs`——所有类型/方法/字段声明，方法上带 RVA 注释；
- `il2cpp.h`——「structure information header file」；
- `script.json`——「For ida.py, ghidra.py and Il2CppBinaryNinja」；
- `ida.py`——「For IDA」；
- `ida_with_struct.py`——「For IDA, read il2cpp.h file and apply structure information in IDA」；
- `stringliteral.json`——「Contains all stringLiteral information」。

本项目此前的实操（本地 `notes.md`，2026-10-29）：「Il2CppDumper 6.7.46 生成 `dump.cs` / `il2cpp.h`」，并记录了 `CharacterImasMotionData.CreateFromImoAsset @ 0x37EC030` 这类地址；`research-mltd-calcbone.md` 写明「dump.cs 与 IDA 地址 1:1」。在现有库上复核：`sub_37EC030` 正好位于 `0x37EC030`，反编译成功、141 行——**Mach-O 的 dump.cs RVA 就是 IDA 线性地址**，不需要加基址。

做法（不改原始二进制，只改库）：

1. 用 Il2CppDumper 对该 `UnityFramework` + `global-metadata.dat` 生成 `dump.cs`/`il2cpp.h`/`script.json`；
2. 在 IDA 里对已分析的 `.i64` 跑 `ida_with_struct.py`（先灌 `il2cpp.h` 的结构体），再跑 `ida.py`（按 `script.json` 改名/加注释）；
3. `save_database`，之后就可以 `get_by_name("Imas.BoneLib.SwayBone$$LateUpdate")` 一类的名字直接定位。

批量套名的耗时风险由 9.5 的两条改进兜底：「creating names in a reopened database no longer slows down as the database fills」「batch decompilation no longer slows down quadratically」（§1.2）。

### 3.3 不装 dumper 时的"定位原理"

Il2CppDumper 源码给出了方法定义 → 原生指针的规则（`Il2CppDumper/Il2Cpp/Il2Cpp.cs`，`GetMethodPointer`）：

- 元数据 ≥ 24.2：用 `methodDef.token`，`token & 0x00FFFFFF - 1` 作为下标，去对应 image 的 code-gen module 的 `methodPointers` 里取；
- 更早版本：用 `methodDef.methodIndex` 直接索引全局 `methodPointers`。

配套结构（`Il2CppDumper/Il2Cpp/MetadataClass.cs`）里，`Il2CppMethodDefinition` 的关键字段是 `nameIndex`、`declaringType`、`returnType`、`parameterStart`、`methodIndex`、`token`、`parameterCount`；`Il2CppTypeDefinition` 用 `methodStart`/`method_count`、`fieldStart`/`field_count`、`nestedTypesStart`/`nested_type_count` 把方法与字段挂到类型上；`Il2CppParameterDefinition` 与 `Il2CppFieldDefinition` 各只有 `nameIndex` + `typeIndex`（类型索引指向**原生二进制**里的类型表，这解释了为什么"名字"在元数据里而"类型"要二进制）。

这也解释了为什么单纯在 IDA 里搜字符串 `"Imas.BoneLib.SwayBone"` 找不到东西——类型名字节只存在于 `global-metadata.dat`，不在 `UnityFramework` 里：`LC_ALL=C grep -ac "SwayBone" <UnityFramework>` 与 `grep -ac "Imas.BoneLib"` 都返回 0，而同一串在元数据里分别命中 39 次和 86 次（实测）。

### 3.4 rea 6.8.0 能补上"清单"这一半（实测）

`rea inspect-il2cpp-metadata <global-metadata.dat>`（帮助：支持 version 24/27/29/31/39；`--binary` 可链接方法地址；`--architecture` 仅用于 universal 二进制；`--ghidra-seeds` 需要 `--binary`）。

实测命令：

```bash
rea inspect-il2cpp-metadata .../BNEI0310.app/Data/Managed/Metadata/global-metadata.dat \
  --detail summary --evidence_output /tmp/rea-il2cpp-evidence/mltd-meta --format toon
```

8.7 秒得到（summary；完整 Evidence 41 MB）：

```
metadata_version: 31
validated_section_row_counts: images 99, types 45483, methods 270248,
  fields 203587, parameters 200240, string_literals 43088, properties 44738, events 375
```

从 Evidence 里取 `Imas.BoneLib.SwayBone`（type row 15301）：

- 37 个方法（按元数据顺序）：`Record`、`get_ResolveDepthFactor`、`set_ResolveDepthFactor`、`.ctor`、`Awake`、`Start`、`SetManager`、`Init`（两个重载）、`RefreshCollidersEnable`、`SetTemporaryStiffnessForce`、`InitSub`、`CalcSideLinkDistance`、`SetAntiFoldAngle`、`SetSkirtParam`、`AdjustSkirt`、`AdjustColliderOffset`、`GetParentSwayManager`、`ResetRot`、`ResetRotForADV`、`SetSideLink2`、`GetSideLinkPath`、`SetSideLinkPath`、`FinishRotate`、`ResetTipPos`、`InitWingLimit`、`SetWingLimitL`、`SetWingLimitR`、`SwayMove`、`SwayHit`、`CalcRotate`、`InitKeepOut`、`AdjustPreTipPos`、`CalcSideLineDistance`、`CalcAntiFoldForce`、`OnDrawGizmos`、`.cctor`。
- 83 个字段名，包括 `stiffnessForce`、`dragForce`、`gravity`、`followForce`、`limitAngle`、`min/maxYAngle`、`min/maxZAngle`、`sideLinkPath`、`colliders`、`refParam`、`initialLocalRotation`、`swayLength`、`curTipPos`、`prevTipPos`、`<ResolveDepthFactor>k__BackingField` 等。
- 4 个嵌套类型：`swaycategory`、`hittypes`、`reftypes`、`RecordParameter`。
- 参数名：`Init(rot)`、`Init(jbh0)`、`SetManager(mgr0, cat)`、`SetTemporaryStiffnessForce(force)`、`SetWingLimitL(param)`、`SwayMove(delta_time)`。
- 同名类还有一个 `Imas.BoneLib.SwayVer02.SwayBone`（1 个方法），所以**命名空间必须一起看**。
- 顺带一个纠偏：这个版本的 `Imas.BoneLib.SwayBone` **没有 `LateUpdate`**（37 个方法里没有）；名字上对应每帧推进的是 `SwayMove(delta_time)`，旋转计算是 `CalcRotate`。要找"每帧调用者"应按这两个方法的 xref 去找（在 IDA 侧就是 `db.functions.get_callers`，实测 10 ms）。

拿不到的部分，Evidence 自己写明了 limitations（原文）：

- 「Field, parameter and return types are not recovered without binary_path」；
- 「Native code addresses and IL2CPP binary registration are not recovered without binary_path」；
- 「Only unencrypted global-metadata.dat versions 24, 27, 29, 31 and 39 are decoded」。

而加上 `--binary` 在本机直接失败（实测）：

```
code: unsupported_target
reason: "unsupported-pointer-encoding: Mach-O chained fixups are not decoded"
```

`otool -l` 确认该文件带 `LC_DYLD_CHAINED_FIXUPS`，所以这不是参数问题。**rea 6.8.0 无法给这个目标做地址链接**；字段/参数类型、方法 RVA 还得靠 Il2CppDumper 或 IDA 侧。

### 3.5 字段值/偏移怎么读

两段互补：

- **字段名与类型**：元数据给名字，类型索引要二进制 → Il2CppDumper 的 `dump.cs` + `il2cpp.h` 一次解决（`ida_with_struct.py` 还能把 `Il2CppClass`/`MethodInfo` 结构体直接落进 IDA）。
- **字段偏移/常量**：IL2CPP 的实例字段布局基本按声明顺序 + 对齐；要精确值就看 `.ctor`/`Init` 里对 `this + offset` 的写入，以及静态构造里的浮点常量。在现有库上这是毫秒级操作：`get_pseudocode` 0.116 s/方法（§2.4）。

一个必要的现实提醒（来自本地 `ios/MotionSway.swift` 与 `sway.py` 的注释）：游戏自己的 `SwayBone` 参数不在出包资源里，所以这一轮 RE 的目标就是**把常量从构造函数/`Init` 里读出来**，而不是从 asset 里解。

---

## 4. rea 6.8.0：哪些命令在这件事上有用

### 4.1 真正有用的命令（本机 `rea --help`）

| 命令 | 对本任务的价值 | 备注 |
| --- | --- | --- |
| `rea inspect-il2cpp-metadata` | **核心**：全局元数据清单（类型/方法/字段/参数/字符串字面量） | 不需要 IDA；见 §3.4 |
| `rea search <path> --kind procedures --mode regex` | 在 rea 的分析结果里按名字找函数 | 需要分析 provider（见 §4.4） |
| `rea decompile <path> --procedure <name>` | 反编译单个函数 | 同上 |
| `rea function <path> <addr>` | 一个函数的"档案"（引用/调用者等） | 同上 |
| `rea xrefs` / `instructions` / `read-bytes` | 交叉引用、原始指令、按地址读字节 | 同上 |
| `rea inspect-macho` / `inspect-binary-layout` | 快速看 Mach-O 结构 | 本机对 158 MB 文件超时，见 §4.3 |
| `rea analyze` / `inspect` | 应用/程序总览 | 同上 |

注意：CLI 里没有 `open-binary`/`list-procedures`/`binary-overview` 这些名字——那是 MCP 工具名（`mcp__rea__open_binary` 等）；CLI 对应 `analyze`/`inspect`/`search`/`decompile`。`analyze` 帮助里写着 path 可以是「App, program, or analysis database path」，但实测 `.i64` 被拒（§4.3）。

### 4.2 输出控制（按 CLAUDE.md 的规矩）

所有命令都支持：`--token-limit <n>`、`--token-offset`、`--format toon|json|yaml|md|jsonl`、`--filter-output <key paths>`、`--full-output`、`--token-count`、`--schema`、`--llms`。对大输出：

- 元数据这种天然很大的，用 `--detail summary --evidence_output <dir>`，把完整 Evidence 落盘（本次 41 MB），再本地用 `python3 -I` 解析；
- 只关心某几个字段时 `--filter-output`（如 `normalized_result.types`）；
- 只想估体积时 `--token-count`。

### 4.3 rea 在这个 158 MB Mach-O 上的实测失败点

1. **`inspect-macho` 超时**：默认 60 s 报 `provider_timeout`；提高到 `--native-command-timeout-ms 180000` 仍然 SIGKILL（实测两次）。这颗二进制的 `MH_..._NLIST_OUTOFSYNC_WITH_DYLDINFO` 与 700k 符号量让底层原生命令跑不完（`nm -gu` 在本机同样 190 s 未完成，被我们手动杀掉）。
2. **`inspect-il2cpp-metadata --binary` 拒绝**：`Mach-O chained fixups are not decoded`（§3.4）。
3. **不认 `.i64`**：`rea analyze /private/tmp/mltd-ida/UnityFramework.i64 --provider ida` → `target_unavailable / unsupported binary format / file_format_rejected`（实测）。

所以 **rea 不能读 IDA 数据库，也不会替你复用已有分析**；它只有"自己重新分析二进制"这条路线，而这条路线在这份文件上目前走不通。

### 4.4 一个容易误判的配置真相（实测）

`rea providers` 显示分析 provider 候选：`ghidra`（unavailable，未设 `GHIDRA_INSTALL_DIR`）、`hopper`（available）、`ida`（available，"IDA MCP adapter"）、`kuna`（unavailable）。看起来"ida 可用"，但：

- 环境变量 `REA_IDA_MCP_CONFIG=/Users/jacklin/.config/rea/ida-mcp.json`；
- 该文件内容：`{"command": "/opt/homebrew/Caskroom/miniforge/base/bin/ida-pro-mcp", "args": []}`；
- 对任意目标 `rea analyze <thin Mach-O> --provider ida` 报 `unreadable_output`，诊断是 `Error executing tool get_metadata: [Errno 61] Connection refused`。

结论：**rea 的 `ida` provider 是第三方 `ida-pro-mcp` 的适配器，不是官方 Hex-Rays IDA MCP**，而且本机这个第三方服务没起。要用 rea 做二进制侧分析，得先把它指向一个真在跑、且暴露它期望工具名（`get_metadata` 等）的服务；否则只能用 `hopper`（`/Users/jacklin/Applications/Hopper Disassembler.app`，`rea doctor` healthy），但 Hopper 对这种 700k 函数的库没有现成分析。

---

## 5. 过去一年内"新出现"的能力（只写能证实的）

- **官方 IDA MCP**：9.5 的 release notes 明列为新 Add-on——「IDA MCP Add-on: A first-party, open-source MCP server that connects your AI agents to IDA, fully locally and across multiple databases at once.」（本机 `release-notes.html` 第 196–197 行）。一年前没有第一方的东西，只有第三方 `ida-pro-mcp` 一类。
- **9.5 的递归反编译 / 批量缓存反编译 / `set_decompiler_timeout` / `MERR_TIMEOUT`**：release notes 第 191–195、928–930 行，属 9.5 新增。
- **9.5 的 zstd 分帧打包**（`PACK_ZSTD_FRAME_SIZE`，默认 32 MB）：第 851 行，属 9.5 新增；这是 .i64 内部容器的变化，不影响打开方式。
- **rea 的 IL2CPP 读取器**：6.8.0 里 provider id `il2cpp-metadata`、name「REA IL2CPP global-metadata reader」、version 1，支持 v24/27/29/31/39。**具体是哪一版加的未找到**（没有公开 changelog；`rea --llms` 未见版本变更记录）。
- **IL2CPP loader / Unity 支持**：IDA 侧**未找到**官方支持（release notes 全文 0 命中，文档站无对应页面）。

---

## 6. 推荐工作流（针对本目标）

1. **不要动原始二进制**；固定用 `/private/tmp/mltd-ida/UnityFramework.i64`（或复制到你自己的可写目录，别放在 app bundle 里）。
2. 用 Il2CppDumper 生成 `dump.cs`/`il2cpp.h`/`script.json`（v31 已验证可行：本地 notes 记录 6.7.46，Metadata v31）。
3. IDA 里对现有 `.i64` 依次跑 `ida_with_struct.py`、`ida.py`，然后 `save_database`。之后库里就有 `Imas.BoneLib.SwayBone$$*` 这类名字。
4. 用官方 IDA MCP 做交互：
   - `open_database("<...>.i64")`（attach，不重分析）；
   - `execute_python` 里用 `db.functions.get_by_name(...)`、`db.functions.get_callers(...)`、`db.functions.get_pseudocode(...)`；
   - 需要成批时：`ida_hexrays.set_decompiler_timeout(60000)` + `ida_hexrays.decompile_many(None, [ea...], ida_hexrays.VDRUN_RECURSIVE)`；
   - 读完常量后 `save_database` 保留注释/改名。
5. 用 rea 的 `inspect-il2cpp-metadata`（不带 `--binary`）当"目录"：核对类名、方法清单、字段名、参数名，和 IDA 里的结果对齐；不要指望它给地址。
6. 需要运行时验证时，`_il2cpp_method_get_name`（本机库 `0x84ba48`）与 `_il2cpp_init`（`0x84af24`）是现成的挂点（Frida 侧此前已这样 dump 过 rest 数据，见本地 `notes.md`）。

---

## 7. 未找到 / 未验证

- IDA 9.5 release notes 中**没有** IL2CPP/Unity 相关条目（已全文检索，0 命中）。
- 没有找到 Hex-Rays 官方的 IL2CPP loader 或 Unity 插件；社区路线仍是 Il2CppDumper 脚本。
- **未验证**：在 158 MB 原始 Mach-O 上从头跑 IDA 分析的耗时（本次刻意只打开已有 `.i64`）；以及 `open_database` 对全新大二进制是否会撞上 300 s 的 `open_timeout`（源码常量存在，但没有实测）。
- **未找到** rea 的版本变更记录，无法确认 `inspect-il2cpp-metadata` 引入的具体版本。
- **未验证** rea 的 `hopper` provider 在这个库上的表现（没收跑 Hopper 的导入，158 MB 且 700k 函数，代价太高）。
- rea + 官方 IDA MCP 没有任何现成桥接：rea 的 `ida` provider 只认第三方 `ida-pro-mcp` 协议（`get_metadata` 等工具名）。

---

## 附：本文用到的证据

**命令（节选）**

```bash
/opt/homebrew/bin/rea --version                                   # 6.8.0
/opt/homebrew/bin/rea inspect-il2cpp-metadata --help              # 版本 24/27/29/31/39；--binary/--ghidra-seeds
/opt/homebrew/bin/rea providers --format json                     # ghidra/hopper/ida/kuna 四候选
/opt/homebrew/bin/rea inspect-il2cpp-metadata <global-metadata.dat> --detail summary --evidence_output ...
/opt/homebrew/bin/rea inspect-macho <UnityFramework> --native-command-timeout-ms 180000   # 仍 provider_timeout
/opt/homebrew/bin/rea analyze <UnityFramework.i64> --provider ida # unsupported binary format
otool -l <UnityFramework> | grep LC_DYLD_CHAINED_FIXUPS           # 命中
```

**IDA MCP（`execute_python`，实例 `c05467508ca7`，库 `/private/tmp/mltd-ida/UnityFramework.i64`）**

```python
ida_funcs.get_func_qty()                                  # 702090
db.functions.get_by_name("sub_37EC030")                   # 2.4 ms
db.functions.get_pseudocode(f)                            # 0.116 s, 141 行
ida_hexrays.set_decompiler_timeout(60000)
ida_hexrays.decompile_many(None, [0x37EC030], ida_hexrays.VDRUN_RECURSIVE)   # True, 30.53 s
```

**本地文件**

- `/Applications/IDA Professional 9.5.app/Contents/MacOS/release-notes.html`（9.5 全文，2.5 MB）
- `~/.claude/plugins/cache/HexRaysSA/ida-mcp/20261028.0.3/{README.md,docs/ARCHITECTURE.md,ida_mcp/mcp.py}`
- `~/.idapro/plugins/ida-mcp/ida-plugin.json`
- `/Users/jacklin/.config/rea/ida-mcp.json`
- 本项目此前记录：`spikes/porting-3d/notes.md`、`research-mltd-calcbone.md`、`research-apply-color-overrides.md`、`ios/MotionSway.swift`、`sway.py`

**在线**

- `https://docs.hex-rays.com/release-notes/9_5`
- `https://hex-rays.com/blog/ida-9.5-three-new-decompilers`
- `https://hex-rays.com/blog/hex-rays-ida-mcp-server`
- `https://hex-rays.com/blog/igors-tip-of-the-week-174-ida-database-idbdetails`
- `https://github.com/HexRaysSA/ida-mcp`、`https://github.com/HexRaysSA/ida-nexus`
- `https://github.com/mrexodia/ida-pro-mcp`
- `https://github.com/Perfare/Il2CppDumper`、`https://raw.githubusercontent.com/Perfare/Il2CppDumper/master/Il2CppDumper/Il2Cpp/{Il2Cpp.cs,MetadataClass.cs}`
