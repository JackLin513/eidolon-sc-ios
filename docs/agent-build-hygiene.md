# Agent 构建与资源使用规范（磁盘 / CPU / GPU）

日期：2026-11-15
适用：本仓库所有 agent / 子 agent / 自动化脚本

## 0. 背景

2026-11-15 磁盘只剩 4.1G，清理后回收约 104G。根因不是源码，而是反复生成的多份 Xcode DerivedData、模拟器 App 构建、Unity iOS 导出和重复的 3D 资源副本：

- 主仓库 `build/`：多个 `Sim*` / `Device*` / `DerivedData*`，每个 1–2G
- `.agents/worktrees/.../build`：同一套构建又一份 25G
- `spikes/porting-3d/unity-spike/build/ios-export*`：Unity 导出 7.8G
- `eidolon-sc-ios-3dspike/build/dd*`：spike 构建 8G+

清理后项目从约 68G 降到约 20G，磁盘可用从 4.1G 回到 108G。

## 1. 磁盘规则

### 1.1 一个分支只用一个 DerivedData

不要为每次 UI 验证新建 `build/SimBar2`、`build/SimBar3`、`build/SimDialog` 这类目录。统一：

```bash
xcodebuild \
  -project EidolonIOS.xcodeproj \
  -scheme EidolonIOS \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'id=<SIMULATOR_UDID>' \
  -derivedDataPath build/DerivedData \
  ONLY_ACTIVE_ARCH=YES \
  DEBUG_INFORMATION_FORMAT=dwarf \
  ENABLE_DEBUG_DYLIB=NO \
  build
```

需要“干净构建”时只用一份：

```bash
rm -rf build/DerivedData
```

不要为每个 worktree 建独立 DerivedData；worktree 里构建前先确认已有 `build/` 大小。

### 1.2 设备构建只在必要时做

设备构建 + 签名产物通常 1G+/次。只在需要真机验收 / 安装时生成，验证完就删：

```bash
rm -rf build/Device*
```

不要让 `build/DeviceBackup`、`build/DeviceDialogs`、`build/DeviceUniform` 等长期堆积。

### 1.3 Unity 导出只保留一份

`spikes/porting-3d/unity-spike/build/ios-export` / `ios-export-sim` 是最大单点，动辄 4–8G：

- 只在一个位置生成；
- 模拟器验证优先用 `ios-export-sim`，不要同时保留 device/sim 两份；
- 验证完删：

```bash
rm -rf spikes/porting-3d/unity-spike/build/ios-export*
```

- 不要从主仓库复制 Unity 资产到每个 worktree；需要时用同一路径或 symlink，改完再同步。

### 1.4 模拟器

```bash
xcrun simctl list devices
xcrun simctl delete unavailable
```

只保留当前在用的 Duo；不要为每次测试新建模拟器。`~/Library/Developer/CoreSimulator/Devices` 里旧设备可以单独删。

### 1.5 每次任务结束前自检

```bash
df -h /System/Volumes/Data
du -sh build .agents/worktrees/*/build spikes 2>/dev/null
```

磁盘可用低于 20G 就先清，不要等构建失败。

### 1.6 可安全删除 / 不要删

可删（生成物）：

- `build/Sim*`、`build/Device*`、`build/DerivedData*`
- `build/stand`、`build/dd-*`、`build/UnitySimSwap`、`*.noindex`
- `.agents/worktrees/*/build`
- `spikes/porting-3d/unity-spike/build/ios-export*`
- `eidolon-sc-ios-3dspike/build/dd-*`、`build/mltd-spike`

不要删：

- `build/eidolon-*.eidolonpkg`（交付包）
- `build/Unity3DContent`（App 内 3D 资源）
- `eidolon-sc-ios-3dspike/build/mltd-corpus`（MLTD 原始语料，4G+，除非确认可重新拉取）

## 2. CPU / GPU 规则

### 2.1 不要并发跑重任务

同一时间只跑一个：

- `xcodebuild`
- `swift test`
- Unity batchmode 导出
- ComfyUI 生图

`swift test` 默认并行；调试时先用 `--filter` 跑单测，最后再全量。不要一边 Xcode build 一边跑 Unity/ComfyUI。

### 2.2 Xcode / Swift

- 增量构建优先；不要每次 `clean`。
- `xcodegen generate` 只在 `project.yml` 变化后跑，不要每次构建都生成。
- Debug 构建加 `ONLY_ACTIVE_ARCH=YES`、`DEBUG_INFORMATION_FORMAT=dwarf`、`ENABLE_DEBUG_DYLIB=NO`。
- 需要并行时限制 `-jobs 4`，不要占满所有核心。
- UI 验证优先模拟器；真机只做最终安装/验收。

### 2.3 Unity

- 用 batchmode 且关闭图形：

```bash
Unity -batchmode -nographics -quit -projectPath spikes/porting-3d/unity-spike ...
```

- 不要长期开着 Unity Editor。
- 一次只导出一个平台（sim 或 device），不要并行导出。

### 2.4 ComfyUI / 生图

- 只在需要验证生图时启动；验证完停掉。
- 不要和 Xcode/Unity 构建同时跑。
- 用单张、固定 704×1024 / 23–28 步；不要批量排队。
- 复用同一模型/服务，避免反复加载大模型。
- 显存不足时用服务端 `--lowvram`，不要在本地同时跑第二个生图任务。

### 2.5 进程清理

任务结束/被取消后检查：

```bash
ps aux | grep -E 'xcodebuild|swift-build|Unity|ComfyUI' | grep -v grep
```

确认没有残留构建/Unity/生图进程。

## 3. 提交前检查

- `git status --short` 只应包含预期源码/文档/包，不应有 `build/` 大目录；
- `du -sh build` 不应异常增长；
- 不要把 DerivedData、Unity 导出、模拟器 App 加进 git；
- 交付包放 `build/*.eidolonpkg`，不要复制多份到 worktree。

## 4. 一键清理（确认无正在运行的构建后用）

```bash
ROOT=/Users/jacklin/Developer/IdeaProjects/eidolon-sc-ios
rm -rf "$ROOT"/build/Sim* "$ROOT"/build/Device* "$ROOT"/build/DerivedData* \
       "$ROOT"/build/stand "$ROOT"/build/dd-* "$ROOT"/build/UnitySimSwap \
       "$ROOT"/build/*.noindex
rm -rf "$ROOT"/.agents/worktrees/*/build
rm -rf "$ROOT"/spikes/porting-3d/unity-spike/build/ios-export*
rm -rf /Users/jacklin/Developer/IdeaProjects/eidolon-sc-ios-3dspike/build/dd-* \
       /Users/jacklin/Developer/IdeaProjects/eidolon-sc-ios-3dspike/build/mltd-spike \
       /Users/jacklin/Developer/IdeaProjects/eidolon-sc-ios-3dspike/spikes/porting-3d/unity-spike/build
df -h /System/Volumes/Data
```
