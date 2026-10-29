# MLTD 3D 角色 shader 运行时 uniform 的取值调研

- 日期：2026-10-29
- 对象：`/Users/jacklin/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0310.app`（MLTD 9.0.350，iOS 26.0 SDK 构建，Unity IL2CPP，`global-metadata.dat` version 31）
- 主机：Apple Silicon，macOS 26.1（Darwin 27.2.0），Xcode 27.1，Metal toolchain 32023.921
- 约束：只读。没有修改游戏文件、没有碰 `SC_Info` / `appguard*`、没有绕过完整性校验、没有跑 Frida attach 到游戏、没有 git 提交。中间产物都在 `/tmp`。

---

## 0. 结论摘要

按“真的能拿到数值”排序：

| 排名 | 方法 | 能否拿到 | 状态 |
|---|---|---|---|
| 1 | **IL2CPP 静态反编译**（`global-metadata.dat` + `UnityFramework` + Il2CppDumper + 自写 xref 扫描） | **能，且已经拿到绝大多数值** | 已验证，本文 §2、§9 |
| 2 | **Xcode GPU Frame Capture**（`Debug > Debug Executable` 选 `ProductName`，GPU Frame Capture = Metal） | 能；唯一实用的“补齐 per-scene 值”的动态手段 | 官方文档 + 第三方 PlayCover 同类实证，本文 §3；需要人操作 |
| 3 | **`xctrace` / Instruments Metal System Trace** | 只能拿帧/绘制/资源名字，**拿不到 uniform** | 已实测 attach 成功，本文 §4 |
| 4 | Frida / 动态插桩 | 技术上可 attach 等价 ad-hoc 进程；游戏有 AppGuard，未执行 | 风险与命令，本文 §5 |
| 5 | PlayCover 自身能力 | 没有 Metal hook / 捕获功能 | 已核实，本文 §6 |
| 6 | `rea` CLI 联动 | metadata 可盘点；**没法把 Mach-O 与方法链起来** | 已实测，本文 §7 |
| 7 | 离线反解 | 只能验证/拟合，不能独立求绝对常数 | 可信度上限，本文 §8 |

**一句话结论**：`_ColorBlendRate` 不是一个常数，运行时是 **0..1 的三角波**（ss003：`rate = 1 - |2*fract(0.5*t) - 1|`，周期 2 秒，再乘 `_Whitish=1`）；波峰时 `glowTarget = _WhityCol = (0.6912, 0.4828, 0.6165)`，这就解释了实拍里霓虹描边的粉白色。材质里的 `_ColorBlendRate: 0` 只是初始值，`CharacterMaterials.apply_color` 每帧用算出来的 `blend_rate` 覆盖它。

---

## 1. 先落事实：二进制与元数据

### 1.1 可读性

```text
$ otool -l "$APP/Frameworks/UnityFramework.framework/UnityFramework" | grep -A6 LC_ENCRYPTION_INFO
  cmd LC_ENCRYPTION_INFO_64
  cryptoff 16384
  cryptsize 148652032
  cryptid 0
```

- `UnityFramework`（165,765,984 字节，arm64）与 `ProductName`（72,064 字节）的 `cryptid` 都是 **0**：当前文件可直接读，没有 FairPlay 加密层。（这通常是 PlayCover 安装时解密/重签后的结果；不是本调研做的绕过。）
- `Data/Managed/Metadata/global-metadata.dat` 34,175,268 字节，magic `0xFAB11BAF`，**version 31**。
- `appguard`、`appguard.fw`、`appguard106000`、`SC_Info/` 都在 bundle 里。本次分析全程没有读取/修改它们，也没有任何禁用反调试的动作。
- `ProductName` 的 `LC_LOAD_DYLIB` 里有：
  `/Users/jacklin/Library/Frameworks/PlayTools.framework/PlayTools`
  所以**直接启动 `ProductName` 仍然会加载 PlayTools**，这对 §3 的 Xcode 直接启动很关键。
- 签名：`ProductName` / `UnityFramework` 都是 adhoc，entitlements 只有 sandbox/设备权限，**没有 `com.apple.security.get-task-allow`**。
- `csrutil status` = enabled；`DevToolsSecurity -status` = disabled（做 Xcode 调试验证前需要人开 Developer Mode）。

### 1.2 `UnityFramework` 目录里已有的 IDA 文件

`Frameworks/UnityFramework.framework/` 下已有 `UnityFramework.id0`（793 MB）、`.id1`（649 MB）、`.id2`、`.nam`、`.til`（2026-10-28 22:40），但没有 `.i64`/`.idb` 打包库。它们不是本次产生的，本次也没有使用或修改。

---

## 2. 方法一：IL2CPP 静态反编译（已成功，主路径）

### 2.1 工具链

`global-metadata.dat` 未加密，`UnityFramework` 未加密，直接上 Il2CppDumper：

```sh
mkdir -p /tmp/il2cpp-dumper && cd /tmp/il2cpp-dumper
curl -sL -o dumper.zip \
  https://github.com/Perfare/Il2CppDumper/releases/download/v6.7.46/Il2CppDumper-net7-v6.7.46.zip
unzip -q dumper.zip

mkdir -p /tmp/il2cpp-out
dotnet Il2CppDumper.dll \
  "$APP/Frameworks/UnityFramework.framework/UnityFramework" \
  "$APP/Data/Managed/Metadata/global-metadata.dat" \
  /tmp/il2cpp-out
```

实际输出（`/tmp/il2cpp-out/`）：

```text
Initializing metadata...
Metadata Version: 31
Il2Cpp Version: 31
CodeRegistration : 8e6bd80
MetadataRegistration : 90ecef0
Dumping... Done!
Generate struct... Done!
Generate dummy dll... Done!

dump.cs            70,690,325 B
script.json       189,253,785 B
stringliteral.json  3,517,602 B
DummyDll/          100 个程序集
```

`dump.cs` 有 45,483 个类型、270,248 个方法（`rea inspect-il2cpp-metadata` 给出的行数：images 99 / types 45483 / methods 270248 / fields 203587 / properties 44738 / events 375 / parameters 200240 / string_literals 43088）。

### 2.2 为什么不用 `rea` 直接联动

`rea inspect-il2cpp-metadata` 单独读 metadata 是好的：

```sh
rea inspect-il2cpp-metadata "$APP/Data/Managed/Metadata/global-metadata.dat" --format toon --token-limit 1500
```

它给出 `metadata_version: 31` 和 31 个 section 的 offset/size，足够做交叉验证。但加上 `--binary UnityFramework` 就失败：

```text
error: unsupported_target / unsupported-pointer-encoding
message: ... unsupported-pointer-encoding: Mach-O chained fixups are not decoded
```

`rea inspect-macho UnityFramework` 在 60 s 的 `native_command_timeout_ms` 上超时（SIGKILL）；`rea decompile <binary> 0x1C1E3B0 --provider hopper` 在 Hopper 启动分析阶段 120 s 超时（`hopper.startup_timeout_ms`）。所以**实际的方法-地址链接是由 Il2CppDumper 完成的**，rea 的价值在 metadata 盘点与 evidence 记录。

### 2.3 找写入点的方法（可复现）

IL2CPP 的字符串字面量不在 `UnityFramework` 里，而在 `global-metadata.dat`；二进制里只有“元数据 usage 槽”。Il2CppDumper 的 `stringliteral.json` 给出 字面量 → usage 槽地址：

```text
_ColorBlendRate    0x98079B8
_WhityCol          0x9808918
_RimCtrl           0x9808338
_GuradeParams      0x9807D98
_WhiteMode         0x9808900
_Whitish           0x9808910
_Freq              0x9807D20
_Luminance         0x9807F00
_FadeColV          0x9807C00
_TheaterColV       0x9808698
_Whiteness         0x9808908
_IsLive            0x9807E58
_FlashParams       0x9807CD8
_VfxTex            0x9808898
```

在 `__TEXT,__text`（VMA 0x4000、file offset 0x4000、size 0x07d09e38）里线性扫 ARM64 `ADRP`+`ADD/LDR` 对（约 32 M 条指令，numpy 约 10 s），把所有解析到上述槽的指令地址找出来，再用 `script.json` 的 `ScriptMethod.Address` 做“最近小于等于”映射到方法。扫出 68 处引用，关键归属：

| 槽 | 引用点 | 所在方法 |
|---|---|---|
| `_ColorBlendRate` / `_WhiteMode` / `_Whitish` / `_Freq` / `_Whiteness` / `_Luminance` / `_MonoColor` | 0x1C20000…0x1C207E4 | `Imas.ModelLib.CharacterMaterials$$initStatic`（只是 `Shader.PropertyToID` 缓存） |
| `_WhityCol` | 0x3808C14 / 0x3808C60 | `Imas.CharacterPinkyRingModel$$SetWhityColor` |
| `_ColorBlendRate` | 0x3808D48 / 0x3808D94 | `Imas.CharacterPinkyRingModel$$SetColorBlendRate` |
| `_GuradeParams` | 0x1ED7F1C…0x1ED83AC | `Imas.Live.CharGuradeCtrl$$setGlobalVector / OnDisable / resetGlobalVector / OnDestroy` |
| `_RimCtrl` | 0x3788D2C / 0x3793148 / 0x3517E70 / 0x3517F4C | `CharacterManager.draw_manager_create` / `RimTypeCtrl..ctor` / `GlobalPropsOnLoad.resetGlobalProps` |
| `_FadeColV` / `_TheaterColV` / `_Whiteness` / `_IsLive` / `_RimCtrl` / `_GuradeParams` | 0x3517E28…0x3517F54 | `Imas.GlobalPropsOnLoad$$resetGlobalProps`（启动时全局复位） |
| `_IsLive` | 0x1E004B0 / 0x1E0230C / 0x1DFCB4C | `MainLoop.<Start>d__72.MoveNext` / `MainLoop.OnDestroy` |
| `_FlashParams` | 0x354727C / 0x35472FC | `Imas.SwordTrail$$Awake`（特效，不是角色本体） |
| `_VfxTex` | 0x1C1B210 / 0x1C1B23C / 0x379BFEC | `CharacterDrawerEye.set_textures_to_material` / `EyeTracking.Init`（贴图槽） |
| `_Luminance` | 0x17FE35C / 0x17FE888 | `UnityStandardAssets.ImageEffects.VignetteAndChromaticAberration$$OnRenderImage`（另一个 `_Luminance`，与角色无关） |

再用 `BL`/`B` 立即数扫描找调用者，得到关键调用链：

```text
CharacterDrawer.LateUpdate (0x1C1889C)
  -> CharacterMaterials.UpdateProperties (0x1C2308C)
       -> apply_color (0x1C21158)       // 把 blend_rate / luminance 写进 Material
       -> ApplyOutline (0x1C21F9C)

VisualManager3d.setup_character_drawer.<...>MoveNext (0x1F44320 附近)
  -> CharacterDrawer.SetGlowBlinkEnable(true)   // 0x1F44340, w1=1
  -> CharacterDrawer.SetGlowBlinkRate(1.0)      // 0x1F44364
  -> CharacterDrawer.SetGlowLuminance(1.0)      // 0x1F44380

VisualManager3d.on_post_update_sub_glow (0x1F368C4)
  -> is_meltyf_blink_costume (0x1F39CB8)
  -> CharacterDrawer.SetGlowBlinkEnable(false) / SetGlowBlinkRate(1.0) / SetGlowLuminance(s9)
```

---

## 3. 方法二：Xcode GPU Frame Capture（推荐用来补 per-scene 值）

### 3.1 官方事实

Apple “Capturing a Metal workload in Xcode”（https://developer.apple.com/documentation/xcode/capturing-a-metal-workload-in-xcode）：
- 抓帧是在**调试会话**里点 Debug bar 的 Metal Capture 按钮；scheme 的 Options > GPU Frame Capture 选 Metal。
- 文档给的两条入口都是 “debug your app” / “Debug > Debug Executable”，不是对任意系统进程 attach。
- `MTLCaptureManager` 是**进程内** API（“records commands within the … instance that you create and commit”），不能从外部进程替游戏开始捕获。

Apple “Capturing a Metal workload programmatically”（https://developer.apple.com/documentation/xcode/capturing-a-metal-workload-programmatically）：
- 捕获需要显式开启：`Info.plist` 的 `MetalCaptureEnabled = YES`，或 macOS 14+ 的 `MTL_CAPTURE_ENABLED=1`；
- `MTLCaptureDescriptor.destination = .gpuTraceDocument`、`outputURL` 以 `.gputrace` 结尾；
- 只记录 start 之后、stop 之前提交的 command buffer。

### 3.2 本机与 PlayCover 的可行性

- 本机 Xcode 27.1，GPU Frame Capture 可用；`DevToolsSecurity -status` 当前是 disabled，Xcode 首次调试会要求开 Developer Mode（`sudo DevToolsSecurity -enable`，需要管理员）。
- 目标进程没有 `get-task-allow`，所以 **Xcode “Attach to Process” 大概率不行**；但 **`Debug > Debug Executable` 是启动子进程**，不依赖目标 entitlement。
- 第三方已经对“PlayCover 跑 iOS 游戏 + Xcode 抓 Metal 帧”走通过同一条路（PJSK，2024，https://mos9527.com/posts/pjsk/shading-reverse-part-1/）：用空工程 → `Debug > Debug Executable` → **选 App 自己的二进制 `ProductName`**（不要选 PlayCover 生成的 App 图标，否则 Xcode 当 iOS app 处理、没有 debug destination）→ `Options > GPU Frame Capture = Metal` → 运行 → 点 Capture。作者在 trace 里直接看到 shader 源码、可编辑的 named uniform（如 `_CoCParams`、`_SatAlpha`）和 texture 名字（`_ColorCocTex`、`_SatTex`）。
- 对本游戏额外有利的一点：`ProductName` 的 `LC_LOAD_DYLIB` 已写死 `PlayTools.framework`，直接启动仍会加载 PlayCover 的 shim，不需要 PlayCover 再注入。

### 3.3 人能照做的步骤

1. 打开 Xcode，新建一个空 macOS App 工程（只作宿主，不用编译）。
2. `Debug > Debug Executable…`，在文件选择框按 `⌘⇧G`，输入：
   `/Users/jacklin/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0310.app/ProductName`
3. Scheme → `Edit Scheme` → `Run` → `Options` → `GPU Frame Capture` 选 **Metal**；`Diagnostics` 里可先不开 validation（会拖慢）。
   - 如失败，先 `sudo DevToolsSecurity -enable` 再试。
4. `Product > Run`。进入游戏的 3D/Live 画面，让角色出现在镜头里。
5. Debug bar 点 **Metal Capture**（金属图标）→ scope 选 `Device` 或 `Frame`，count 选 1 → `Capture`。
6. 在 Metal debugger 里：
   - 左侧选对应 draw call（Unity 的 debug group 会让你看到 `body` / `face` / `hair` / `eyes` / `ss003_acc01`）；
   - 右侧 `Bound Resources` 看 fragment/vertex 的 constant buffer（Unity 把 `FGlobals`/`VGlobals` 打包成 inline bytes 或 buffer）；
   - Shader 视图里可以直接看 named uniform 并改值（第三方实证）。
   - 需要的话 `File > Save` 存 `.gputrace`，或截图。
7. 重点读：`_ColorBlendRate`、`_WhityCol`、`_WhiteMode`、`_Whitish`、`_Freq`、`_Luminance`、`_RimCtrl`、`_GuradeParams`、`_FadeColV`、`_IsLive`。

### 3.4 风险与限制

- 必须在 Xcode 下**重新启动**游戏；不能抓当前 PlayCover 里已经在跑的实例（无 get-task-allow + `MTLCaptureManager` 进程内）。
- 游戏是联网的，且带 AppGuard；调试器会话是否被检测未知。**建议用小号/离线场景，别在重要账号或正在进行的 Live 里做**。
- `.gputrace` 可能很大（几百 MB 到数 GB），抓单帧、只抓一个 device/frame。
- 直接启动 `ProductName` 是否完全等价于 PlayCover 启动（HOME/TMPDIR、容器路径、AKInterface 等）没有逐个验证；第三方同类经验是可行的，但本游戏未实测。

---

## 4. 方法三：`xctrace` / Instruments Metal System Trace（已实测）

`xctrace` 可以**不注入、不 attach 调试器**地记录 Metal 时间线。本次对正在运行的 PID 75365 试了 5 秒：

```sh
xcrun xctrace record --template "Metal System Trace" \
  --attach 75365 --time-limit 5s --output /tmp/mst.trace
```

输出：

```text
Starting recording with the Metal System Trace template. Attaching to: ProductName (75365).
Reached specified time limit, ending recording...
Output file saved as: mst.trace
```

`--toc` 里本 game 的 `metal-object-label` 表已经能看到 Unity 的 debug group：

```text
[R] CommandBuffer.BeforeForwardOpaque
[R] Graphics.Blit
[R] Drawing
Camera.Render
eyes
ss003_acc01
hair
ss003_acc02
face
body
```

用途：
- 确认画面上真的是 `ss003` 这套衣装 + 哪些部件在画；
- 给 GPU 抓帧做时间/帧的对齐（先 xctrace 看帧节奏，再 Xcode 抓同一段）。

**拿不到的东西**：trace 的 schema 只有 `metal-application-*`、`metal-command-buffer-*`、`metal-gpu-*`、`metal-resource-allocations`、`metal-object-label` 等时间线/资源表；没有 encoder 参数、没有 constant buffer 内容、没有 shader uniform。所以它只能做定位，不能替代 §3。

---

## 5. 方法四：Frida / 动态插桩

### 5.1 本机事实

- `frida` 17.24.3 已安装；`frida-ps` 能看到 `75365 jp.co.bandainamcoent.BNEI0310`。Frida 官方 macOS 文档说明 attach 依赖 `task_for_pid` / taskgate 授权（https://frida.re/docs/examples/macos/、https://frida.re/docs/troubleshooting/）。
- 做了一次**不涉及游戏**的对照实验：编译一个 ad-hoc、无 entitlement 的 `/tmp/frida-test/t`（`sleep(120)`），`frida -p <pid> -e "console.log(...)"` **成功 attach**。说明“没有 get-task-allow 的 ad-hoc 进程”本身不一定挡 Frida。
- 但目标进程额外有：`com.apple.security.app-sandbox`、`appguard*`、`SC_Info`、联网。AppGuard 是反篡改层，Frida 的注入/线程/模块特征很容易被检测。**本次没有对游戏执行 attach**，这是按“只写事实和风险、不执行”的约束做的取舍。

### 5.2 如果用户自己决定要试

技术上要 hook 的是 Metal 的常量写入，命令形态：

```js
// 先确认实现类
const cls = ObjC.classes.MTLRenderCommandEncoder; // 协议，实际实现类需枚举
// 常见实现类名类似 _MTLRenderCommandEncoder / AGXRenderCommandEncoder
Interceptor.attach(impl['- setFragmentBytes:length:atIndex:'].implementation, {
  onEnter(args) {
    const len = args[2].toInt32();
    const idx = args[3].toInt32();
    const buf = args[1];
    console.log('idx', idx, 'len', len, hexdump(buf, { length: len }));
  }
});
```

要点：
- Unity 的 Metal 后端通常把 `FGlobals`/`VGlobals` 通过 `setFragmentBytes`/`setVertexBytes`（小结构）或 `setFragmentBuffer`（大结构）绑定；两种都要 hook。
- 拿到的是**整块字节**，还要知道 `FGlobals` 的字段布局才能把 offset 映射到 `_ColorBlendRate` 等名字。布局可以从 §3 的 `.gputrace` 里读，或从 Unity 运行时编译出的 Metal 反射里读；单靠 hlslcc 的源码不够（Metal 编译器的打包/对齐可能与声明顺序不同）。
- 映射示例：`idx` 是 buffer index，通常 `VGlobals` 在 vertex 的某个固定 index、`FGlobals` 在 fragment 的另一个；先 hook `setFragmentBytes` 打 `idx/len`，用长度和内容与材质已知值（`_WhityCol` = 0.691/0.483/0.616 很好认）对齐。

风险：
- AppGuard 可能直接让游戏崩溃或标记会话；
- 不要为了 attach 去禁用反调试、改签名、改 `SC_Info` —— 这些都不在本次范围；
- 如果只是要拿数值，§3 的 Xcode 抓帧风险更低、信息更全。

---

## 6. 方法五：PlayCover 本身

- `Frameworks/PlayTools.framework` 存在；`nm`/`strings` 里是 UIKit/触控/键盘/鼠标/GCMotion 相关 hook：
  `hook_Unity_KeyboardDelegate_Initialize`、`hook_GCMouse_current`、`hook_bounds`、`hook_frame`、`swizzleInstanceMethod:withMethod:`、`SwizzleVolume`、`SwizzleBattery` 等。
- **没有** `MTL*` / `Metal` / `setFragmentBytes` / `MTLCaptureManager` 相关符号或字符串。
- `PlayTools.framework` 的 `Frameworks/PlugIns/Resources` 只有 `AKInterface.bundle` 和本地化，没有捕获/日志库。
- PlayCover 主程序里有 `METAL_CAPTURE_ENABLED`、`METAL_CAPTURE_OUTPUT_FILE`、`METAL_CAPTURE_TYPE`、`METAL_FRAME_CAPTURE_ENABLED`、`MTLCaptureEnabled` 字符串（file offset 0x2467c0 一带，前后还有 `METAL_SHADER_VALIDATION_OPTIONS`、`METAL_FORCE_LAZY_COMPILATION`、`METAL_ERROR_MODE`）。这些是 Apple Metal 的环境变量名；在 PlayCover 的 `__text` 里用 ADRP+ADD/LDR 扫描 **没有找到任何引用**，也没有对应 UI 文案。**不能据此认为 PlayCover 有抓帧功能。**
- 唯一和本任务相关的：PlayCover 在安装时给 `ProductName` 写了 `LC_LOAD_DYLIB PlayTools`，所以 §3 直接用 Xcode 启动二进制仍能保持 PlayCover 的 shim。

---

## 7. 方法六：`rea` CLI 能帮到什么

实际跑过的命令与结果：

| 命令 | 结果 |
|---|---|
| `rea capabilities` | native-macos / rea-artifact-graph / rea-dotnet-static / il2cpp-metadata 等 provider；没有可用的 IDA/Ghidra 会话 |
| `rea inspect-il2cpp-metadata <metadata>` | **成功**：version 31，31 个 section，类型/方法/字段/字面量行数 |
| `rea inspect-il2cpp-metadata <metadata> --binary UnityFramework` | **失败**：`unsupported-pointer-encoding: Mach-O chained fixups are not decoded` |
| `rea inspect-macho UnityFramework` | **超时**（60 s，SIGKILL） |
| `rea decompile UnityFramework 0x1C1E3B0 --provider hopper` | **超时**（Hopper 启动/分析 120 s；`hopper.startup_timeout_ms` 可调） |
| `rea doctor` | IDA MCP 注册有效但无 IDA 进程；Hopper 指向 `/Users/jacklin/Applications/Hopper Disassembler.app`（demo），不是 6.1.0 |

结论：
- rea 的 metadata reader 是可靠的一手证据源（section offset、行数、version），适合做校验；
- rea 的“二进制 + metadata 联动”在本 Mach-O 上被 chained fixups 挡住；
- rea 的 Hopper provider 会用 demo 版、对 165 MB 二进制启动超时；**不要再用 demo 跑全量分析**；
- 如果要用 rea 的 IDA provider，需要人先打开 IDA 9.4 → `Edit > Plugins > MCP` 启动插件；否则 `check_connection` 会报 “Failed to connect to IDA Pro”。

---

## 8. 方法七：离线反解（兜底）

如果所有动态手段都不可行，能不能从“游戏输出像素 + 已知 shader 公式”反推未知 uniform？

**能解的部分**：只有自由变量很少、且输出是线性组合时。例如在某个像素上：
`out = lerp(2*base*_GlowColor, _WhityCol, _ColorBlendRate) * _FadeColV * ...`
如果 `base`、`_GlowColor`、`_WhityCol` 都已知，只有一个标量 `_ColorBlendRate`，可以从一个像素解出来。

**必须满足的前提**（缺一不可）：
1. 视角、投影、模型变换、骨骼姿势完全对齐（否则 `base`、rim、法线全错）；
2. 光照参数一致：`_Light`、`_RimLight`、`_AmbientColor`、顶点色 `COLOR0`、`_VColMin`、`_Blending` 等（见 `research-mltd-shading-math.md` §2.0）；
3. 贴图/材质参数一致（`_Color`、`_MainTex`、`_SubTex`、`_Luminance`、`_Whiteness`、`_FadeColV`）；
4. 后处理不参与或可精确复刻：Live 画面有 bloom、DOF、color grading、LUT、bloom stencil、vignette；角色 shader 的输出不是最终像素；
5. 采样精确：视频有压缩、抗锯齿、tone mapping；最好拿未压缩截图/抓帧；
6. 已知 shader 变体（`_TESTMODE_NONE` 等）与实际一致。

**可信度上限**：
- 只能得到“在该像素/该帧上使公式成立的值”，无法区分“`_ColorBlendRate=1`”和“`_WhityCol` 被整体缩放”这类等价变换；
- 多帧可以拟合周期（比如确认 2 秒三角波），但绝对相位依赖计时起点；
- 最多用来**验证**静态分析得到的公式，不能替代静态/动态取数。

本次不需要用它：§2/§9 已经把除 per-scene 值以外的常数全部定死。

---

## 9. 已经拿到的具体数值

材质值来自本仓库已导出的 `mirai-ss003-materials.json`（`build/dd-glow/Build/Products/Debug-iphonesimulator/Eidolon3DSpike.app/mirai-ss003-materials.json`，材质 `cb_ss003_014mir_01glw_m`，shader `Custom/Chr_Glow`）：

```json
"_ColorBlendRate": 0.0,
"_Freq": 0.5,
"_Luminance": 1.0,
"_WhiteMode": 2.0,
"_Whitish": 1.0,
"_WhityCol": [0.6911764740943909, 0.48280709981918335, 0.6164510250091553, 1.0],
"_GlowColor": [1.0, 1.0, 1.0, 1.0]
```

> 注意：任务描述把 `_WhityCol` 也列为“材质不提供”。实际导出里 ss003 的 `Chr_Glow` 材质**有** `_WhityCol`（就是上面这组值），C# 只在**配饰**材质上覆盖它（`CharacterPinkyRingModel.SetWhityColor`）。如果你目标材质的 JSON 里没有 `_WhityCol`，那说明它是另一套衣装/变体，需要单独确认。

### 9.1 `_ColorBlendRate`（最要紧的一条）

先纠正一个前提：**它不是 `MaterialPropertyBlock`，也不是全局 shader 属性，而是每帧对每个 glow 材质做 `Material.SetFloat`**（0x70739FC）。`_GuradeParams` / `_FadeColV` / `_IsLive` 这类才是 `Shader.SetGlobal*`；`_WhityCol` / `_WhiteMode` / `_Whitish` / `_Freq` / `_Luminance` 是材质属性。

**它每帧被 C# 覆盖。**

- `CharacterMaterials.GlowProperty..ctor`（0x1C1E6C4）从材质里读三个值：
  - `Material.GetInt(id_WhiteMode)` → `white_mode`（0x1C1E790，`id_WhiteMode` = 静态偏移 0x8C）
  - `Material.GetFloat(id_Whitish)` → `whitish`（0x1C1E7B8，id 0x90）
  - `Material.GetFloat(id_Freq)` → `freq`（0x1C1E7D8，id 0x94）
  - `blend_rate` 不读材质，初始 0。
- `CharacterMaterials.UpdateProperties(float delta_time)`（0x1C2308C）：
  - 若 `is_glow_blink_enable == true`（setup 时由 `VisualManager3d.setup_character_drawer` 置 true，0x1F44340）：
    ```text
    frac = fract(timer * freq)
    saw  = 1 - frac
    tri  = 1 - |2*frac - 1|
    blend_rate = whitish * (white_mode == 1 ? saw
                          : (white_mode == 0 || white_mode == 3 ? 0 : tri))
    ```
    指令位置：0x1C23248–0x1C232B0；`timer` 是 `CharacterMaterials` 的静态字段（偏移 0xC0），每帧用 `Time.deltaTime` 累加一次（用 `Time.frameCount` 去重，0x70B9E54）。
  - 否则走 `apply_color`，把已有的 `blend_rate` 写回材质。
- `CharacterMaterials.apply_color`（0x1C21158）对每个 glow 材质执行：
  - `Material.SetFloat(id_Luminance, glow_luminance * glowLuminanceAll)`（0x1C21F04）
  - `Material.SetFloat(id_ColorBlendRate, glow_property.blend_rate)`（0x1C21F28）
- 另一个入口 `blink2blend_all(float blink_rate)`（0x1C1E49C）：
  `blend_rate = whitish * (1 - clamp(blink_rate, 0, 1))`
  - `SetGlowBlinkEnable(false)` 会调 `blink2blend_all(0)` → `blend_rate = whitish = 1`
  - `SetGlowBlinkRate(1.0)` → `blend_rate = 0`
  - `VisualManager3d.on_post_update_sub_glow` 只对 `is_meltyf_blink_costume` 为真的特殊衣装走这条“关掉脉动、按时间表闪”的路径；普通衣装走上面的 per-frame 波形。

**ss003 的最终值**：`_WhiteMode=2`、`_Whitish=1`、`_Freq=0.5`，
所以 `_ColorBlendRate = 1 - |2*fract(0.5*t) - 1|`，**周期 2 秒、0→1→0 的三角波**（t=1 s 时到 1，t=2 s 回到 0）。`timer` 的相位原点是进程启动后的累计时间。

复现建议（写进渲染器）：

```swift
timer += deltaTime                    // 每帧一次
let frac = (timer * 0.5).truncatingRemainder(dividingBy: 1)
let rate = 1.0 - abs(2 * frac - 1)    // ss003，_Whitish = 1
// glowTarget = mix(2 * base * _GlowColor, _WhityCol, rate)
```

如果只想对一张参考截图做静态复刻，取 `rate = 1.0` 就能得到实拍里看到的粉白描边。

注意：上面这条 pulse 走的是 **Live** 路径（`VisualManager3d.setup_character_drawer` 把 `is_glow_blink_enable` 置 true）。commu/剧情场景没有这一步时，`blend_rate` 可能停在 0 或被 `ADVCostumeLight` 单独设置；两者的视觉差别就是“描边是粉白 `_WhityCol` 还是 2×本色”。

### 9.2 其余 uniform

| uniform | 材质/默认 | 运行时值 | 依据 |
|---|---|---|---|
| `_WhityCol` | `(0.6911765, 0.4828071, 0.6164510, 1)` | 基本不变；只有配饰材质被 `CharacterPinkyRingModel.SetWhityColor` 用 `Material.SetColor` 覆盖（0x3808CCC） | material JSON；`dump.cs:346862` |
| `_WhiteMode` | 2 | 不变（C# 只读） | `GlowProperty..ctor` 0x1C1E790；material JSON |
| `_Whitish` | 1.0 | 不变（只读） | 0x1C1E7B8 |
| `_Freq` | 0.5 | 不变（只读） | 0x1C1E7D8 |
| `_Luminance` | 1.0 | `SetGlowLuminance(input)` 先把 `input` 乘一个全局亮度再存成 `glow_luminance`；`apply_color` 再乘一次 `VisualManager3d.glowLuminanceAll`（ctor 里是 1.0）。Live 开场 1.0–1.5 s 线性 0→1。 | `SetGlowLuminance` 0x1C1E310；`VisualManager3d..ctor` 0x1F39EA4（`str w8,#0x128`, w8=0x3F800000）；`on_post_update_sub_glow` 0x1F36950–0x1F36990 |
| `_RimCtrl` | **(0,0,0,0)**（启动复位） | 只有 Live 的 `RimLightEventCtrl.Excute` 事件会调 `CharacterManager.SetRimLightEnv(type,…)`，设为 `(type!=0 ? 1 : 0, rimOffset[type], 0.5, 0.9)`；没有该事件的舞台保持 0。`rimOffset[]` 未取到。 | `GlobalPropsOnLoad.resetGlobalProps` 0x3517FD0（读 `Vector4.zeroVector`，`dump.cs:1740019` 偏移 0x0）；`SetRimLightEnv` 0x3791E10 / 0x3791F8C；调用者 `RimLightEventCtrl.Excute` 0x1F215B8/0x1F21620 |
| `_GuradeParams` | **(0,1,0,1)**（启动复位） | Live 由场景里的 `CharGuradeCtrl` 计算：`(aY,bY,aZ,bZ)`，其中 `aY=1/(top-bottom)`、`bY=-(bottom+floorY)/(top-bottom)`，Z 同理用 `edgeZ/near/far` | `resetGlobalProps` 0x3517FE4–0x3518010；`CharGuradeCtrl.setGlobalVector` 0x1ED7ED0；字段见 `dump.cs:539449` |
| `_FadeColV` | **(1,1,1,1)** | 换装/淡出时由 `GlobalColorCtrl` 改 | `resetGlobalProps` 0x3517EC4（`Vector4.oneVector`，偏移 0x10） |
| `_TheaterColV` / `_FadeTheaterColV` | (1,1,1,1) | 同上 | 0x3517EFC / 0x3517F6C |
| `_Whiteness` | 0 | 灰度化时 0..1 | `resetGlobalProps` 0x3517F78（`Shader.SetGlobalFloat(_Whiteness, 0)`） |
| `_MonoColor` | 材质 | `CharacterMaterials.SetMonoColor` / `SetMonoColorRatio` | `dump.cs:491021` 的 `id_MonoColor` 0x54 |
| `_IsLive` | 0 | Live 进入时 1（`Shader.SetGlobalInt("_IsLive",1)`，0x1E02318），`MainLoop.OnDestroy` 回 0 | `resetGlobalProps` 0x3517F98；`MainLoop` |
| `_FogMode` | 0 | 由 `GlobalColorCtrl.updateFogMode` 管理 | `resetGlobalProps` 0x3517F88（`SetGlobalInt("_FogMode",0)`） |
| `_ExtraBihaku` | 材质 1.0 | C# **完全不引用**（metadata 里没有这个字面量） | `research-mltd-shading-math.md:654`；本次对 `global-metadata.dat` 的 grep 为 0 |
| `_FlashParams` | 特效材质 | `SwordTrail.Awake` 0x3547218 设置 | 与角色本体无关 |
| `_VfxTex` | 眼睛材质贴图槽 | `CharacterDrawerEye.set_textures_to_material` 0x1C1B1D4；`EyeTracking.Init` | 贴图，不是标量 uniform |
| `_AntiGrayscale` | — | C# **完全不引用**（metadata 里没有） | grep 0 |

补充：`GlobalPropsOnLoad.resetGlobalProps` 是通过 `[RuntimeInitializeOnLoadMethod] initOnRun()`（0x3518014，tail-call 到 0x3517DF8）在启动时跑的；所以即使没有任何场景控制器，`_GuradeParams` 也不是 0，而是 (0,1,0,1)。代入 shader：

```metal
g.x = max(G.x*worldPos.y + G.y, 0);  // = max(0+1,0) = 1
g.y = max(G.z*worldPos.z + G.w, 0);  // = 1
COLOR0.z = min(g.x+g.y, 1);          // = 1
```

**默认不会把角色乘黑**。之前笔记里“默认 0 会乘黑”的担心只在不跑 `GlobalPropsOnLoad` 的自制渲染器里成立；照抄 (0,1,0,1) 即可。

---

## 10. Hopper 6.1.0 的评估与操作步骤

- 安装路径：`/Applications/Hopper Disassembler ver6.1.0.app`
- 可执行文件：`Contents/MacOS/hopper`（169,728 B 的 launcher）和 `Contents/MacOS/Hopper Disassembler`（GUI，13 MB，universal x86_64/arm64），另有 `HopperMCPServer`。
- CLI 是真的有：

```text
Usage: Hopper [-e file] | [-d hop_file] [-l loader_id [options]] ... [-Y python_script.py]
  -e | --executable file     Creates a new Hopper document, and loads the given executable file.
  -a | --analysis            Start the background analysis.
  -A | --no-analysis         Don't start the background analysis.
  -Y | --python script.py    Execute a Python script, once the initial analysis is ended.
```

但它仍然会打开 GUI document；对 165 MB 的 `UnityFramework` 做全量分析不适合无人值守。**不要再运行 `/Users/jacklin/Applications/Hopper Disassembler.app`（demo）**：30 分钟限制，跑不完也导不出。

### 10.1 人怎么点（6.1.0）

1. 打开 `Hopper Disassembler ver6.1.0.app`。
2. `File > Read Executable to Disassemble…`（或直接把文件拖进窗口），选：
   `/Users/jacklin/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0310.app/Frameworks/UnityFramework.framework/UnityFramework`
   选 arm64，用默认 loader，等分析完成（大二进制请给足时间，别在 demo 上跑）。
3. `Navigate > Go to Address…`（快捷键 `G`），输入已知 RVA（十进制/十六进制都行）：
   - `0x1C1E49C` `CharacterMaterials.blink2blend_all`
   - `0x1C2308C` `CharacterMaterials.UpdateProperties`
   - `0x1C21158` `CharacterMaterials.apply_color`
   - `0x1C1E6C4` `GlowProperty..ctor`
   - `0x1C23354` `GlowProperty.CalcGlowBlendRate`
   - `0x1C21F28` `Material.SetFloat(id_ColorBlendRate, …)` 的调用点
   - `0x3517DF8` `GlobalPropsOnLoad.resetGlobalProps`
   - `0x3791E10` `CharacterManager.SetRimLightEnv`
   - `0x1ED7ED0` `CharGuradeCtrl.setGlobalVector`
4. 右侧切到 **Decompile**（伪代码）面板。看什么：
   - 立即数：`0x3F800000` = 1.0，`0x3E19999A` = 0.15，`0x3F000000` = 0.5，`0x3F666666` = 0.9；
   - 对 `Material.SetFloat`（thunk 到 `0x70739FC`）、`Shader.SetGlobalVector`（`0x706EE60`）、`Shader.SetGlobalFloat`（`0x706ECC0`）、`Shader.SetGlobalInt`（`0x706EC54`）的调用；
   - 从静态字段读出来的值：`[class+0xb8]` 是 static fields 区，`CharacterMaterials` 的 `id_*` 是 0x84/0x88/0x8C/0x90/0x94，`timer` 是 0xC0。
5. **字符串搜索的陷阱**：在 `UnityFramework` 里搜 `_ColorBlendRate`、`_RimCtrl`、`_GuradeParams`、`_ExtraBihaku`、`MaterialPropertyBlock`、`SetFloat` **基本搜不到有用的东西**——IL2CPP 的字符串字面量在 `global-metadata.dat`，二进制里只有 BSS 里的 usage 槽；托管方法名也不在 Mach-O 符号表里。不要按“字符串 → 交叉引用”的常规思路在 Hopper 里兜圈子；直接用上面给的 RVA。
6. 导出/截图：
   - 需要留证：`File > Save`（.hop），或 `⌘⇧4` 截取 Decompile 面板；
   - 想批量导出：用 `-Y` 脚本在分析结束后调 Hopper 的 Python API（`Document.getCurrentDocument()`、取 segment、取 procedure、`decompile()`）；不同 6.x 版本的 API 名可能略有差异，第一次用先在 Hopper 的 Python 控制台里试一行，别直接跑批量。

### 10.2 Hopper vs Il2CppDumper vs rea

| 维度 | Hopper 6.1.0 | Il2CppDumper v6.7.46 | rea 6.8.0 |
|---|---|---|---|
| 类型/方法清单 | 只看到 native 函数，没有托管名 | **完整**：45,483 类型、270,248 方法、RVA、DummyDll | metadata 可盘点；binary 链接受 chained fixups 限制 |
| 字符串→方法 | 对 IL2CPP **无效**（字面量在 metadata） | **有效**：`stringliteral.json` 给 usage 槽，自写 ADRP 扫描即可 | 不适用（--binary 失败） |
| 伪代码 | **有**，对已知 RVA 很好用 | 只有签名，没有函数体 | 依赖 Hopper/IDA provider；Hopper provider 超时 |
| 大二进制 | 165 MB 可以开，但慢；GUI | 命令行，几分钟出全部产物 | `inspect-macho` 60 s 超时 |
| 无人值守 | 不方便 | **可以** | 部分可以 |

结论：**用 Il2CppDumper 做导航和图谱，用 Hopper 只看具体函数的伪代码**；两者组合比任何单一路径都快。

---

## 11. 建议的下一步（命令级）

### 11.1 只想确认 ss003 的描边颜色/脉动

不需要再跑动态：

```text
_WhityCol = (0.6911765, 0.4828071, 0.6164510)
_WhiteMode = 2, _Whitish = 1.0, _Freq = 0.5
_ColorBlendRate(t) = 1 - |2*fract(0.5*t) - 1|
```

### 11.2 想拿 per-scene 的 `_RimCtrl` / `_GuradeParams`（以及验证 9.1 的波形）

用 §3 的 Xcode 流程。人要在旁边做的只有：

```text
1. sudo DevToolsSecurity -enable        # 如果 Xcode 提示 Developer Mode
2. Xcode > Debug > Debug Executable…    # 选 ProductName
3. Scheme > Run > Options > GPU Frame Capture = Metal
4. Product > Run，进入 3D/Live 画面，Metal Capture → Device/Frame，Capture
```

抓到的 `.gputrace` 里读 `_RimCtrl`、`_GuradeParams`、`_ColorBlendRate`、`_WhityCol`，就能把 §9 里仅剩的两个 UNVERIFIED 值补齐。

### 11.3 如果不想开 Xcode

可以先跑 5 秒 `xctrace` 确认场景和帧节奏：

```sh
xcrun xctrace record --template "Metal System Trace" \
  --attach <pid> --time-limit 5s --output /tmp/mst.trace
xcrun xctrace export --input /tmp/mst.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-object-label"]' \
  | grep -oE '<metal-object-label[^>]*fmt="[^"]*"' | head -50
```

它给不了 uniform，但能确认 `body/face/hair/eyes/ss003_acc01` 这些 debug group 正在画，帮你在 Xcode 抓帧时挑帧。

---

## 12. UNVERIFIED

1. **`CharacterManager.rimOffset[]` 的 5 个 float 值**。只知道 `rimOffset` 是 `CharacterManager` 的 `static float[]`（`dump.cs:339761`，长度 5，由 `.cctor` 0x379500C 用 `RuntimeHelpers.InitializeArray` 从 field RVA 初始化），`SetRimLightEnv(type,…)` 取 `rimOffset[type]` 作为 `_RimCtrl.y`，阈值/软化固定 0.5/0.9。数组数据在 Mach-O 的 field-RVA blob 里；本机没有解析出 FieldInfo 表（token 0x0400A1EF 在文件里 0 次命中，表可能在 `__bss`/运行时填充）。先验猜测是 `-0.25`（VS 里同一条逻辑写死 offset = -0.25），但**没有验证**。影响很小：`_RimCtrl.x == 0` 的默认路径不读它。
2. **各 Live 舞台的 `CharGuradeCtrl` 序列化值**（`floorY/top/bottom/edgeZ/near/far`）。它们来自舞台 prefab/scene，不在代码常量里；默认复位是 (0,1,0,1)（中性），所以静态复刻可以先用中性值。
3. **`_FlashParams` 的类型/数值**。只确认 `SwordTrail.Awake` 引用了它；与角色本体无关。
4. **`_VfxTex` 具体是哪张贴图**。只确认是眼睛材质上的贴图槽，由 `set_textures_to_material` / `EyeTracking.Init` 设置。
5. **`_MonoColor` 在 `_Whiteness > 0` 时的实际值**。正常 Live 下 `_Whiteness = 0`，不影响。
6. **不同衣装的 `_WhiteMode/_Whitish/_Freq/_WhityCol`**。只验证了 ss003；pr001 没有 `Chr_Glow` 材质。其他衣装需要各自的 material JSON 或抓帧。
7. **AppGuard 对 Xcode 调试器 / Frida 的反应**。没有执行任何 attach 到游戏的动作；无法给出“会不会崩/会不会封”的结论，只能说存在风险。
8. **`CharacterMaterials.timer` 的相位原点**。静态上它是零初始化的静态字段，每帧加 `Time.deltaTime`；如果游戏在别处重置过它，`t=0` 的相位会变。用抓帧可以一帧定相位。
9. **`_ColorBlendRate` 在普通 Live 里是否一定走 pulse 分支**。代码上 `is_glow_blink_enable` 由 `VisualManager3d.setup_character_drawer` 置 true；如果某些场景/模式另行关闭，值会变成 0 或 1。抓帧可确认。
10. **`Frameworks/UnityFramework.framework/` 里的 `.id0/.id1` 来源**。不是本次产生，未使用。

---

## 附录 A：本次用到的命令/产物

```sh
APP="/Users/jacklin/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0310.app"

# 1) 可读性
otool -l "$APP/Frameworks/UnityFramework.framework/UnityFramework" | grep -A6 LC_ENCRYPTION_INFO_64
codesign -d --entitlements - "$APP/ProductName"

# 2) IL2CPP
dotnet /tmp/il2cpp-dumper/Il2CppDumper.dll \
  "$APP/Frameworks/UnityFramework.framework/UnityFramework" \
  "$APP/Data/Managed/Metadata/global-metadata.dat" /tmp/il2cpp-out

# 3) 字符串槽
python3 - <<'PY'
import json
for e in json.load(open('/tmp/il2cpp-out/stringliteral.json')):
    if e['value'] in ('_ColorBlendRate','_WhityCol','_RimCtrl','_GuradeParams'):
        print(e['value'], e['address'])
PY

# 4) ADRP/BL 交叉引用（脚本在 /tmp/xref_scan.py、/tmp/bl_scan.py、/tmp/callers.py）
/opt/homebrew/bin/python3.11 /tmp/xref_scan.py
/opt/homebrew/bin/python3.11 /tmp/callers.py 0x1C1E488=SetGlowBlinkEnable ...

# 5) 反汇编
xcrun llvm-objdump -d --arch=arm64 --start-address=0x1C1E49C --stop-address=0x1C1E568 "$BIN"

# 6) rea
rea inspect-il2cpp-metadata "$APP/Data/Managed/Metadata/global-metadata.dat" --format toon --token-limit 1500
rea inspect-il2cpp-metadata "$APP/Data/Managed/Metadata/global-metadata.dat" --binary "$BIN" ...
rea decompile "$BIN" 0x1C1E3B0 --provider hopper ...

# 7) xctrace
xcrun xctrace record --template "Metal System Trace" --attach <pid> --time-limit 5s --output /tmp/mst.trace
xcrun xctrace export --input /tmp/mst.trace --xpath '.../table[@schema="metal-object-label"]'

# 8) 材质值
python3 - <<'PY'
import json
d=json.load(open('/Users/jacklin/Developer/IdeaProjects/eidolon-sc-ios-3dspike/build/dd-glow/Build/Products/Debug-iphonesimulator/Eidolon3DSpike.app/mirai-ss003-materials.json'))
print(d['materials']['cb_ss003_014mir_01glw_m'])
PY
```

产物：

```text
/tmp/il2cpp-out/dump.cs            70 MB
/tmp/il2cpp-out/script.json       189 MB
/tmp/il2cpp-out/stringliteral.json 3.5 MB
/tmp/il2cpp-out/DummyDll/          100 DLL
/tmp/xref_scan.py /tmp/bl_scan.py /tmp/callers.py
/tmp/mst.trace                     5 秒 Metal System Trace
/tmp/apply_color.txt               apply_color 反汇编
```

## 附录 B：shader 侧对应关系（引用已有笔记）

- `Chr_Glow` 的 `_ColorBlendRate`/`_WhityCol` 公式：`research-mltd-shading-math.md:263`。
- `_GuradeParams` 的 VS 用法：`research-mltd-shading-math.md:157` 附近。
- `_RimCtrl` 的 FS 重算分支：`research-mltd-shading-math.md:228–244`。
- `_FadeColV`/`_Whiteness`/`_MonoColor`：`research-mltd-shading-math.md:271–272`、`487–488`。
- ss003 材质清单：`research-mltd-shading-math.md:621`、`647`。
- `_ExtraBihaku` 的材质值：`research-mltd-shading-math.md:654`（1.0）。
