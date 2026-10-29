# 不点 Xcode 拿到 MLTD 某一帧的 Metal uniform/buffer 内容

日期：2026-10-29
机器：macOS 27.2（26B123）/ Xcode 27.1（27A9275）/ SDK MacOSX27.0.sdk
目标进程：PlayCover 中的 `jp.co.bandainamcoent.BNEI0310`（ミリシタ 9.0.350，Unity 6000.2.6f2）

回答的目标只有一个：在**不需要人在 Xcode/Metal Debugger 里点**的前提下，读出某一帧某个 draw call 的
fragment/vertex 常量（`_RimCtrl`、`_GuradeParams`，以及顺手能验证的 `_ColorBlendRate` 等）。

---

## 0. 结论摘要

**能。而且不需要自己注入、不需要解析 `.gputrace`、不需要 Xcode GUI。**

macOS 27 自带两个命令行工具，组成完整的「录制 → 离线读 buffer」链路，本机已实测跑通：

| 工具 | 版本 | 作用 |
|---|---|---|
| `/usr/bin/gpucapture` | `2027.1.3` | 对**已在运行**的进程抓 GPU trace，产出 `.gputrace`（headless 录制） |
| `/usr/bin/gpudebug` | `v1.0` | 离线打开 `.gputrace`，REPL/`-c`/`--json` 导航，`fetch` 导出 buffer/texture/内联 `setBytes` 字节 |

实测（本机，一个自写的小 Metal 程序，不碰游戏）：

- `gpucapture list` → `boundaries` → `start --count N --output x.gputrace` 全程无 GUI；
- `gpudebug --oneshot -t x.gputrace -c "go commands/cb0/re0/draw0/fragment" -c "fetch buf[0] --out b.bin"`
  取回的 `setFragmentBytes` 内联字节与程序写入的 `1.25, -2.5, 3.75, 42.0` **逐字节一致**；
- 三帧各自写不同值的 `MTLBuffer`，取回 cb0/cb1/cb2 的 draw 分别是 `204 → 205 → 206`，
  说明 **fetch 取到的是「该 draw 提交时刻」的快照，不是帧末状态**——这正是 per-draw 常量需要的性质。

唯一还需要人工的是：**用 launchd 环境变量让游戏在启动时打开「可捕获」开关**，然后在游戏里
走到想抓的 Live 舞台。之后全部是命令行。

推荐链路（细节见 §2.1）：

```bash
launchctl setenv MTL_CAPTURE_ENABLED 1          # 普通用户，不要 sudo；一次性
# （在 PlayCover 里启动游戏，进入目标舞台）
gpucapture list                                  # 应能看到 ProductName
gpucapture boundaries --pid <PID>                # 找 Layer/Queue 边界
gpucapture start --pid <PID> --boundary <ID> --count 1 --output /tmp/mltl.gputrace
gpudebug -t /tmp/mltl.gputrace -c "list"         # 之后的导航/取值全部命令行
launchctl unsetenv MTL_CAPTURE_ENABLED           # 收尾
```

关键前提已在本机核实：游戏进程的环境变量就是 launchd 给的默认集合（只有 `HOME`/`PATH`/`XPC_*` 等
13 项），PlayTools 不是靠环境变量注入的，而是靠改写过的 `LC_LOAD_DYLIB`
（`otool -L` 看到 `/Users/jacklin/Library/Frameworks/PlayTools.framework/PlayTools`）。
所以 `launchctl setenv` 这条路不会被 PlayCover 覆盖掉——这一点比「启动 PlayCover 时带环境变量」可靠得多。

> 结论一句话：**唯一不确定的是 AppGuard 会不会因为 `GPUToolsCapture.framework` 被加载而干预**，
> 这不是技术可行性问题，一次尝试即知（`gpucapture list` 里有没有游戏）。

---

## 1. 先把「已经排除的」对齐

- `xctrace` Metal System Trace：schema 里没有 buffer 内容，已排除（结论不变；它抓的是 driver 层计数器）。
- PlayTools 只 hook UIKit：不变。
- 主程序里 `METAL_CAPTURE_*` 字符串无代码引用：不变（那次搜的是游戏自己的二进制，跟系统侧的
  `MTL_CAPTURE_ENABLED` 是两件事，后者由 **Metal.framework** 读，不在游戏里）。

---

## 2. 逐条方法

### 2.1 方法 A（推荐）：`gpucapture` + `gpudebug`

#### 事实依据（本机一手）

`man gpucapture`（`/usr/share/man/man1/gpucapture.1`）原文：

> `gpucapture` is a command line tool for creating GPU Trace files for any App, process or service
> that can connect to GPU Tools agent/daemon `gputoolsserviced`. A GPU Trace file contains Metal API
> calls … as well as the necessary data to reconstruct any GPU workloads for further analysis via
> Metal Debugger.

> In order to establish a connection the user is responsible to launch their target process with
> **`MTL_CAPTURE_ENABLED=1`** environment variable within. This environment variable is responsible
> for loading `GPUToolsCapture.framework` into the process and will attempt to connect to
> `gputoolsserviced` if a MTLDevice is ever created within the process.

边界类型（man 原文）：

| 类型 | 起点 | 终点 |
|---|---|---|
| `Device` | 下一个 `MTLCommandBuffer` 创建 | 该 buffer scheduled |
| `Queue` | 指定 `MTLCommandQueue` 上的下一个 buffer | 同上 |
| `Layer` | 指定 `CAMetalLayer` 的下一次 present（**= 一帧**） | 该 layer 下一次 present |
| `Scope` | `[MTLCaptureScope beginScope]` | `endScope` |

`--count N` 对 Layer 就是「抓 N 帧」；`--output` 必须是目录或以 `.gputrace` 结尾；不给就落在 CWD。

`man gpudebug`（`/usr/share/man/man1/gpudebug.1`）原文要点：

> `gpudebug` is an interactive CLI debugger for Metal GPU traces. It opens a `.gputrace` file and
> provides a REPL for navigating the captured API call hierarchy, inspecting resources and pipeline
> state, **fetching textures and buffers to disk**, browsing shader source code …

> `fetch` … Textures are saved as `.png`, buffers as `.bin` … **Inline bytes from `setBytes:` calls are
> also fetchable as `.bin`.**

树结构正好对上我们需要的东西：

```
commands/cb0/re0/draw0/{pipeline, vertex{buf[i],tex[i]}, fragment{buf[i],tex[i]}, color0}
```

Apple 官方文档也明确 `gpudebug` 就是给程序化/agent 用的：
"the `gpudebug` command-line tool provides a text-based, self-discoverable interface that you can use
programmatically, making it well-suited for AI agents."（见 §来源）

#### 本机实测（完整链路，2026-10-29）

自写测试程序（源码在 `/tmp/gputest2/main.swift`，二进制 `/tmp/gputest2/gputest2`）：
每帧写 `MTLBuffer` = `[frame, -frame, 3.75, 42.0]`，用 `setFragmentBytes` 再塞 `[0.5,0.25,100,200]`。

```bash
MTL_CAPTURE_ENABLED=1 /tmp/gputest2/gputest2 60 &
gpucapture list
#     PID  Device     Name  GPU(ms)
#   86778       0  gputest     0.36
gpucapture boundaries --pid 86778
#   ID    Type           Label  GPU(ms)  Count
#    1  Device    Apple M1 Pro     0.41    203
#    6   Queue  gputest_queue     0.41    203
gpucapture start --pid 86778 --boundary 1 --count 3 --output /tmp/gputest2/t.gputrace
#  … 2 / 2 MTLCommandBuffer
#  capture finished / capture took 0.4 seconds
```

读取：

```bash
gpudebug --oneshot -q -t /tmp/gputest2/t.gputrace \
  -c "go commands/cb0/re0/draw0/fragment" -c "list" \
  -c "fetch buf[1] --out /tmp/gputest2/cb0_buf1.bin"
# Name     Label                       Summary            Actions
# buf[0]                               16 bytes (inline)    fetch
# buf[1]   "gputest2_perframe_buffer"  @buf0 16 bytes       info, fetch
# Fetched /private/tmp/gputest2/cb0_buf1.bin (16 bytes)
```

结果：

```
cb0 buf1:  2.040000e+02  -2.040000e+02  3.750000e+00  4.200000e+01
cb1 buf1:  2.050000e+02  -2.050000e+02  3.750000e+00  4.200000e+01
cb2 buf1:  2.060000e+02  -2.060000e+02  3.750000e+00  4.200000e+01
```

内联 `setBytes` 也逐字节正确：`xxd` 得到 `0000 a03f 0000 20c0 0000 7040 0000 2842` =
`1.25, -2.5, 3.75, 42.0`（另一个测试 `/tmp/gputest`）。

#### 迁移到游戏上要做的三件事

1. **让环境变量进到游戏进程**。
   本机实测游戏进程（PID 75365）的环境是 launchd 默认集合：

   ```
   OSLogRateLimit=64 USER=jacklin COMMAND_MODE=unix2003 __CFBundleIdentifier=…
   PATH=/usr/bin:/bin:/usr/sbin:/sbin LOGNAME=jacklin SSH_AUTH_SOCK=…
   HOME=… SHELL=/bin/zsh TMPDIR=… __CF_USER_TEXT_ENCODING=… XPC_SERVICE_NAME=… XPC_FLAGS=1
   ```

   没有 `DYLD_*`、没有 `MTL_HUD_ENABLED`——所以 PlayCover 不是通过 `NSWorkspace.OpenConfiguration.environment`
   传环境（它挂在 `metalHUD` 上的开关是在 PlayTools 里自己处理的），而是靠
   `NSWorkspace.openApplicationAtURL:configuration:`（PlayCover 二进制里有这个 selector）+ 改过的
   `LC_LOAD_DYLIB` 做注入。结论：**`launchctl setenv` 是唯一直接命中这条 launchd 链的入口**。

   ```bash
   launchctl setenv MTL_CAPTURE_ENABLED 1     # man launchctl: "set … on all future processes launched by launchd in the caller's context"
   # 完全退出 PlayCover 里的游戏，再从 PlayCover 启动
   ps eww -p $(pgrep -f 'BNEI0310.app/ProductName') | tr ' ' '\n' | grep MTL_CAPTURE_ENABLED
   vmmap $(pgrep -f 'BNEI0310.app/ProductName') | grep -i GPUToolsCapture   # 应能看到 framework 已载入
   ```

2. **进到目标舞台**（人工点几下，唯一的人工）。
3. **抓一帧**：优先用 `Layer` 边界（`--count 1`），这样 trace 只有一帧，体积可控；
   如果 `boundaries` 不列 Layer，就退到 `Queue`/`Device` + `--count 1`。

#### 风险 / 限制

- **AppGuard**：`Info.plist` 里有 `AppGuardConnect` / `AppGuardUseId`，bundle 里有 `appguard`、`SC_Info`。
  `GPUToolsCapture.framework` 是 Apple 系统框架（`/System/Library/PrivateFrameworks`），加载它不算改文件，
  但反作弊是否检测「非预期 image 载入/额外 mach port」未知。**这是唯一需要实测的风险点**，且不做任何绕过。
- **沙盒**：游戏带 `com.apple.security.app-sandbox`。我们的测试程序没有沙盒，所以「沙盒内进程能否被
  `gpucapture` 抓到」属未验证（见 UNVERIFIED）。trace 由宿主侧的 `gputoolsserviced` 落盘，理论上不受
  应用沙盒限制。
- **开销**：Apple 文档说开启捕获有 "tiny, but measurable" 的 CPU 开销；`gpucapture` 自身抓帧时会短暂
  拖慢目标（本例 0.4–0.5 s）。
- **体积**：一帧真机 Live 场景的 trace 可能几十到几百 MB（贴图 dump 是主体）。`--count 1` 是最小化手段。
- **replay 设备**：`fetch` 需要 background replayer 起来（`status` 里 `Replayer: loading...` 也能 fetch，
  会有几秒等待）。因为游戏渲染走的就是宿主 Metal（`vmmap` 里是
  `/System/Library/Extensions/AGXMetalG13X.bundle` + `/System/Library/Frameworks/Metal.framework`），
  replay 设备天然兼容。

---

### 2.2 `.gputrace` 是什么，能不能离线解析

**是目录（bundle），不是单文件。** 本机刚生成的一份（`/tmp/gputest2/t.gputrace`，单帧 3 个 draw，~100 KB）：

```
capture                             3764 B   magic "MTSP"
delta-device-resources-0x1032a1d50    56 B
device-resources-0x1032a1d50       11840 B
index                              13591 B   magic "xdic"
metadata                            1143 B   binary plist ("bplist00")
MTLTexture-7-0-mipmap0-slice0      32768 B   raw pixels（每 slice 一个文件）
startup-0-platform / startup-1-platform
store0                              8253 B   zlib（0x78 0x5e）
unsorted-capture                    3236 B
unused-device-resources-0x1032a1d50 6500 B
```

- `capture` / `device-resources-*` / `unsorted-capture` 都是 `MTSP` magic 的私有流；
- `metadata` 是 bplist（设备/OS/版本信息）；
- 纹理按 slice 平铺成裸文件。

**离线解析有三条路：**

1. **`gpudebug`（官方，推荐）**——它就是「离线解析器 + 可脚本化前端」。已实测，不需要 Xcode 进程。
2. **Metal Debugger（Xcode GUI）**——Apple 文档 "Replaying a GPU trace file" 指的就是这条路，缺点是要人点。
3. **第三方逆向解析器**——公开存在，但都不是 Apple 支持面：
   - `github.com/tmc/gputrace`（Go）：自称 "parses and analyzes Apple Metal GPU trace files (`.gputrace` bundles)"，
     解析 `store0`、`device-resources-*`、`.gpuprofiler_raw/streamData` 等；它的 `trace-format.md`
     是逆向笔记，不保证跨 Xcode 版本稳定。
   - `github.com/ibrews/gputrace`（Python，单文件）：明确写 "Apple documents none of this format"，
     格式是 "Reverse-engineered from a single visionOS 26 / Xcode 26.6 capture"，并且提醒
     "treat selector IDs as a starting point to re-derive per Xcode version"。
   - 结论：**只有在 `gpudebug` 不够用时才考虑**。对本次目标（读常量缓冲区）完全不需要。

**`MTLCaptureDestination` 的两种取值（SDK 头文件一手）**
`…/MacOSX27.0.sdk/System/Library/Frameworks/Metal.framework/Headers/MTLCaptureManager.h`：

```c
typedef NS_ENUM(NSInteger, MTLCaptureDestination) {
    /// Capture to Developer Tools (Xcode) and stop the execution after capturing.
    MTLCaptureDestinationDeveloperTools = 1,
    /// Capture to a GPU Trace document and continue execution after capturing.
    MTLCaptureDestinationGPUTraceDocument,
};
```
- `.developerTools`：把 trace 交给正在跑的 Xcode，**并暂停进程**——这是 GUI 那条路。
- `.gpuTraceDocument`：写 `outputURL`（必须是 `.gputrace`），**进程继续跑**——离线路径。
- 两者是同一份数据的两种去向，`supportsDestination:` 可先探测。

---

### 2.3 环境变量语义（逐个）

| 变量 | 语义 | 依据 |
|---|---|---|
| `MTL_CAPTURE_ENABLED=1` | 在 **macOS 14+** 上开启 Metal capture；等价于 `Info.plist` 的 `MetalCaptureEnabled=YES`。必须在启动前设置 | Apple 文档 *Capturing a Metal workload programmatically*；`man gpucapture` 说明它负责把 `GPUToolsCapture.framework` 载入进程 |
| `MTLCAPTURE_WAIT_FOR_SIGNAL=1` | 在 `MTLDevice` 创建处**挂起进程**，直到 `gpucapture start` 发出信号。适合抓启动帧 | `man gpucapture`（`--until-exit` 条目）；字符串存在于 `GPUToolsCapture` |
| `METAL_DEVICE_WRAPPER_TYPE` | 存在且被 `GPUToolsCapture` 读取，Apple **没有公开文档**，语义未验证（历史用法是把 Metal 调用包一层 wrapper 记录） | `strings` `/System/Library/PrivateFrameworks/GPUToolsCapture.framework/Versions/A/GPUToolsCapture` |
| `MTL_DEBUG_LAYER=1` 等 | **API 校验层**，不是捕获。列出 `MTL_DEBUG_LAYER_ERROR_MODE` / `_WARNING_MODE` / `_VALIDATE_LOAD_ACTIONS` … | `man MetalValidation`；Apple 文档 *Validating your app's Metal API usage* |
| `METAL_CAPTURE_ENABLED` | 同一处字符串群里确实存在（旧拼写/别名），但**文档只写 `MTL_` 形式**；本次实测用的是 `MTL_`。同一个字符串块里还有 plist 键 `MetalCaptureEnabled`、`MetalForceCaptureEnabled` | dyld 共享缓存 `.05`（`Metal.framework`）偏移 64512530 附近的字符串：`GPU Frame Capture could not be enabled` / `Unknown Wrapper Type : %d` / `METAL_CAPTURE_ENABLED` / `MTL_CAPTURE_ENABLED` / `MetalCaptureEnabled` / `MetalForceCaptureEnabled` |
| `MTL_SHADER_VALIDATION=1` | shader 校验，同样不是捕获 | `man MetalValidation` |

补充事实：
- `Metal.framework` 里两种拼写并存，且带 `MetalForceCaptureEnabled` 这个更「强制」的 plist 键——但没有文档，
  不确定它是否绕过 `supportsDestination` 的探测，**未验证**。
- `Unknown Wrapper Type : %d` 这条消息就在 `METAL_CAPTURE_ENABLED` 旁边，说明 `METAL_DEVICE_WRAPPER_TYPE`
  是个「wrapper 类型」选择器（数值），不是开关。
- `GPUToolsCapture` 里还有一大票**未公开**的 `MTLCAPTURE_*` 开关（`MTLCAPTURE_DISABLE_HEAPS`、
  `MTLCAPTURE_ENABLE_EVENT_BUFFER`、`MTLCAPTURE_DESTINATION_DEVELOPER_TOOLS_ENABLE` …），可以读，但不要依赖。

**能不能「注入到别人的进程」？** 严格说不能：`MTLCaptureManager` 是**进程内** API（`+sharedCaptureManager`），
必须在目标进程里调用。`gpucapture` 替代了这件苦活——它通过 daemon 让目标进程启动时载入的
`GPUToolsCapture.framework` 自己调 `MTLCaptureManager`。所以「注入」这一环是 Apple 做的，不是我们做的。

---

### 2.4 `DYLD_INSERT_LIBRARIES` + 自写 `MTLCaptureManager` dylib（只评估，不执行）

**可行性：技术上成立，但没有必要，风险比方法 A 高一个量级。**

支持它的本机事实：

- 游戏二进制是 **ad-hoc 签名**：`codesign -dv` → `flags=0x2(adhoc)`，**没有 hardened runtime 位**
  （`0x10000` 未置位），没有 `com.apple.security.cs.disable-library-validation` 之类的约束需求；
- 它**已经**在加载第三方 dylib：`otool -L` 里有
  `/Users/jacklin/Library/Frameworks/PlayTools.framework/PlayTools`，且 `vmmap` 显示已映射——
  说明 PlayCover 是改写 load command 注入的，dyld 侧对额外 image 没有阻拦；
- `man dyld` 对 `DYLD_INSERT_LIBRARIES`：*"a colon separated list of additional dynamic libraries to load
  before the ones specified in the program"*。SIP 只对 platform binary / 带受限 entitlement 的进程剥离
  `DYLD_*`，这个 ad-hoc 的第三方 app 不属于那类。

风险：

1. **AppGuard**（`appguard` / `appguard.fw` / `SC_Info`）：这是最可能的干预点，行为未知，且**不能绕过**；
2. **沙盒**：`com.apple.security.app-sandbox` 为 true，dylib 的 `constructor` 里做任何落盘/端口操作都可能被拒；
3. **PlayCover 自己的注入链**：再叠一层 `DYLD_INSERT_LIBRARIES` 可能与 PlayTools 的初始化顺序打架
   （Unity/PlayTools 早期就创建 `MTLDevice`，要保证你的 dylib 在其之前 hook 到 `MTLCaptureManager`）；
4. **反作弊/封号**风险由用户承担。

**结论：不要做。** 方法 A 用的是 Apple 自己的 `GPUToolsCapture.framework`，同样是一次 image 载入，
但它由 Metal 框架主动加载，属于「受支持的行为」，比自写 dylib 更不像 tamper。

---

### 2.5 Metal 有没有官方 headless / CI 入口

有，且就是我们用的这两个：

- `gpucapture`（录制，macOS 27 起随系统提供，`/usr/bin/gpucapture`）；
- `gpudebug`（离线查看/导出，`/usr/bin/gpudebug`，`man gpudebug`）。

没有第三个：`xcrun` 里那一串 `metal-*`（`metal`、`metal-ar`、`metal-lipo`、`metal-objdump`、`metal-nm`、
`metal-dsymutil`、`metal-source`、`metal-libtool`）全是**离线编译器/工具链**，跟 capture 无关；
`xcrun --find gpu-capture` / `metal-capture` 都不存在。注意本机 Xcode 27.1 的 Metal Toolchain 还没装
（`xcrun metal` 报 `missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain`），
这只影响编译 `.metal` 源文件，不影响 capture。

`gpudebug` 的脚本化用法（Apple 文档原例）：

```bash
gpudebug -t trace.gputrace -c "list"                      # 建 session
gpudebug -s 412 -c "go commands/cb0/re0/draw0" -c "info pipeline"
gpudebug -s 412 -c "fetch color0"
gpudebug --terminate 412
gpudebug --oneshot -t trace.gputrace -c "…" -c "…"        # 一次性的写法
```

`--json` 对 `list`/`info`/`status` 等结构化输出生效，适合喂脚本。

---

### 2.6 兜底：从画面反解（评估，不建议）

前提：我们已有一份能复刻原版公式的 Metal 实现，可以当正向模型做参数拟合。合理性评估：

| 参数 | 可辨识性 | 理由 |
|---|---|---|
| `_RimCtrl.y == rimOffset[type]`（1 维） | **中**（±10% 量级、符号可信） | rim 项已知是 `f(1-N·V)` 的阈值/软化形态，`x,y,z,w` 里只有 y 未知；但需要准确的相机、光照、色调映射/曝光/后处理，否则整体亮度偏移会被误吸收进 y |
| `_GuradeParams`（4 维，`aY,bY,aZ,bZ`） | **低** | 它是 world Y/Z → 渐变坐标的仿射变换，直接影响角色上的渐变带位置；和我们已知的其他项（`_Whiteness`、`_ColorBlendRate` 的三角波、双光照）强耦合，且只在特定舞台生效，单帧几乎欠定 |
| 其余（`_ColorBlendRate` 等） | 已由静态反编译确定，不需要反解 | — |

要让它有意义，需要同时满足：**严格对齐视角**（同一相机矩阵，误差 < 0.1%）、**同一光照环境**
（环境光/方向光强度与方向）、**同一后处理链**（bloom/tonemap/曝光/色彩空间）、**无 UI/无压缩伪影的高分截图**，
并且正向模型在别的帧上已验证到 1e-3 量级。即使全满足，`_GuradeParams` 也只能给出「看起来对」的解，
不是原值。

**上限判断：可以把 rimOffset 拟合到一个能用的近似值；`_GuradeParams` 拟合出来的数不能当「原版参数」写进
文档，只能标成「视觉近似」。** 有了 §2.1，这条完全没必要走。

---

## 3. 如果拿到了值：怎么从 buffer 里把两个值读出来

抓到 `.gputrace` 后，目标是「角色材质的那个 draw 的 fragment 常量缓冲」。步骤：

1. **定位 draw**：
   ```bash
   gpudebug -t /tmp/mltl.gputrace -c "go commands" -c "list --all"
   gpudebug -s <session> -c "find <材质/shader/group 名>"   # 大小写不敏感的子串
   ```
   Unity 会留 debug group（`grpN`），`xctrace` 里已经能看到，`gpudebug` 的树里同样是 `grpN` 节点。
   注意：`find` 按 man 是「labels, names, summaries」全量搜索，但本次实验里**资源 label**
   （`gputest2_perframe_buffer`）没被 `find` 命中，encoder/command buffer 的 label 命中正常——
   所以优先拿 group/encoder/pipeline 名去搜，别指望材质名一定搜得到。
2. **看绑定**：
   ```bash
   gpudebug -s <session> -c "go commands/cb0/re0/draw0/fragment" -c "list"
   # buf[0] … buf[N]  →  fetch 各下标
   ```
   Unity 的全局属性和材质属性都在 constant buffer 里（`setFragmentBuffer`），偶尔用 `setFragmentBytes`
   （此时显示 `(inline)`，同样可 fetch）。
3. **导出 + 扫值**：
   ```bash
   gpudebug -s <session> -c "fetch buf[0] --out /tmp/frag0.bin"
   ```

两个值有很强的「指纹」，扫字节就能定位，不需要先知道完整的 cbuffer 布局：

- **`_RimCtrl = (type!=0, rimOffset[type], 0.5, 0.9)`**
  小端 float 的尾巴是 `0.5f = 00 00 00 3F`、`0.9f = 66 66 66 3F`，即 16 字节里最后 8 字节固定为
  `00 00 00 3F 66 66 66 3F`。扫这个 8 字节 pattern，前面 4 字节就是 `rimOffset[type]`。
  只有 `RimLightEventCtrl` 生效的舞台才会出现（其余舞台整条是 0），这本身也是一个判据。
- **`_GuradeParams = (aY,bY,aZ,bZ)`**，默认复位值是 `(0,1,0,1)`；有 `CharGuradeCtrl` 的舞台满足
  `aY = 1/(top-bottom)`、`bY = -(bottom+floorY)/(top-bottom)`，Z 同理。可以在 dump 里找满足
  `aY>0 且 bY<0 且 aZ>0 且 bZ<0` 且 `bY/aY`、`bZ/aZ` 量纲一致的 4 连 float。
- 顺手可交叉验证 `_ColorBlendRate`（三角波，0..1）、`_Whiteness`、`_FadeColV`——如果这些和我们静态反编译的
  值对得上，说明定位到的 buffer 就是那套全局属性，`_RimCtrl`/`_GuradeParams` 的读数可以直接采信。

注意：SRP batcher 下同一个大 cbuffer 会被很多 draw 共用，**同一帧内不同 draw 的同一 offset 值可能相同**；
确认「这确实是角色材质」靠 pipeline/entry point（`info pipeline`）和 debug group 名，而不是 offset。

---

## 4. 复现实验（本次用的最小验证）

```bash
# /tmp/gputest2/main.swift：每帧写 MTLBuffer=[frame,-frame,3.75,42.0]，
# 另用 setFragmentBytes 塞 [0.5,0.25,100,200]，画一个三角形
xcrun swiftc -O /tmp/gputest2/main.swift -o /tmp/gputest2/gputest2 -framework Metal -framework Foundation
MTL_CAPTURE_ENABLED=1 /tmp/gputest2/gputest2 60 &
gpucapture list
gpucapture boundaries --pid <pid>
gpucapture start --pid <pid> --boundary 1 --count 3 --output /tmp/gputest2/t.gputrace
gpudebug --oneshot -q -t /tmp/gputest2/t.gputrace \
  -c "go commands/cb0/re0/draw0/fragment" -c "list" \
  -c "fetch buf[1] --out /tmp/gputest2/cb0_buf1.bin"
od -An -f /tmp/gputest2/cb0_buf1.bin
```

（不需要 Metal Toolchain：shader 用 `device.makeLibrary(source:)` 运行时编译。）

---

## 5. UNVERIFIED

1. **AppGuard 是否会因为 `GPUToolsCapture.framework` 载入而干预**（杀进程/上报/不干预）——未实测，
   需要真的用 `launchctl setenv` 重启一次游戏才知道。这是整条链路唯一可能的硬阻塞。
2. **沙盒进程（`com.apple.security.app-sandbox=true`）能否被 `gpucapture` 捕获**——我们的测试程序无沙盒。
3. **游戏里 `boundaries` 是否会列出 `Layer` 边界**、有几个 `CAMetalLayer`（Unity 通常一个，但 PlayCover 的
   窗口/缩放层可能多一个）。
4. **`launchctl setenv` 是否 100% 命中 PlayCover 的启动方式**。已确认游戏进程环境等于 launchd 默认集合
   （强证据），但 PlayCover 用的是 `NSWorkspace.openApplicationAtURL:configuration:`，
   若它显式设置了 `configuration.environment` 就可能覆盖——本机没观察到这种覆盖的痕迹。
   验证方法：启动后 `ps eww -p <pid> | tr ' ' '\n' | grep MTL_CAPTURE_ENABLED`。
5. **一帧真实 Live 场景的 trace 体积**（估几十~几百 MB，未测）。
6. **`gpudebug` 对 iOS-app-under-PlayCover 的 trace 的 replay 兼容性**——驱动是宿主
   `AGXMetalG13X`，预期一致，但未实测。
7. **`METAL_DEVICE_WRAPPER_TYPE` 的确切语义**——只确证字符串存在于 `GPUToolsCapture`，Apple 无公开文档。
8. **Unity 侧这两个值到底走 `setFragmentBuffer` 还是 `setVertexBuffer`**（大概率 fragment，因为 `_RimCtrl`
   在 FS 里用；`_GuradeParams` 的 VS 用法见 `research-mltd-shading-math.md`，可能在 vertex 绑定里）——
   抓一次两侧都 fetch 即可确认。
9. **`.gputrace` 私有流（`MTSP`/`xdic`/`store0`）的格式稳定性**——Apple 无公开文档，跨 Xcode 版本会变；
   依赖 `gpudebug` 而不是自己解析。

---

## 来源

一手（本机）：
- `man gpucapture`、`man gpudebug`、`man MetalValidation`、`man launchctl`、`man dyld`
- `…/MacOSX27.0.sdk/System/Library/Frameworks/Metal.framework/Headers/MTLCaptureManager.h`
- `/usr/bin/gpucapture --version` = `2027.1.3`，`/usr/bin/gpudebug --help` = `GPU Debugger (v1.0)`
- 实测：`gpucapture list/boundaries/start`、`gpudebug --oneshot/-c/fetch/--json`、`.gputrace` 目录清单
- 游戏侧：`ps eww`、`vmmap`、`otool -L`、`codesign -dv/--entitlements`、`plutil -p`（Info.plist / App Settings）
- `strings` `/System/Library/PrivateFrameworks/GPUToolsCapture.framework/Versions/A/GPUToolsCapture`；
  `grep -a` dyld shared cache（`.05`/`.21`/`.23`）命中 `MTL_CAPTURE_ENABLED` 与 `METAL_CAPTURE_ENABLED`

Apple 文档：
- [Capturing a Metal workload programmatically](https://developer.apple.com/documentation/xcode/capturing-a-metal-workload-programmatically)
  （`MTL_CAPTURE_ENABLED=1`，macOS 14+；`MetalCaptureEnabled` plist；`.gpuTraceDocument` + `outputURL` 必须是 `.gputrace`）
- [Investigating GPU issues with AI agents](https://developer.apple.com/documentation/xcode/investigating-gpu-issues-with-ai-agents)
  （`gpudebug` 的 `-t/-s/-c/--oneshot` 脚本化用法）
- [Validating your app's Metal API usage](https://developer.apple.com/documentation/xcode/validating-your-apps-metal-api-usage)
  （`MTL_DEBUG_LAYER` 等校验变量，与捕获无关）
- [Replaying a GPU trace file](https://developer.apple.com/documentation/xcode/replaying-a-gpu-trace-file)
- [apple/game-porting-toolkit · using-gpudebug](https://github.com/apple/game-porting-toolkit/blob/main/game-porting-skills/skills/using-gpudebug/SKILL.md)
  （`gpudebug` 随 macOS 27 起提供）

第三方（仅作 `.gputrace` 格式背景，非必需）：
- [tmc/gputrace](https://github.com/tmc/gputrace) — Go 写的 `.gputrace` 解析器，含逆向格式笔记
- [ibrews/gputrace](https://github.com/ibrews/gputrace) — Python 单文件解析器；"Apple documents none of this format"
