# MLTD 3D 预览 spike（原生资产路线）

状态：spike，不进入产品；分支 `spike/mltd-3d-static`，基于 `main`。游戏素材与转换产物一律不进仓库。

路线见 `docs/adr/0022-3d-native-assets-runtime-skinning.md`：模型、骨骼、绑定、蒙皮权重、贴图、表情形变全部来自游戏自己的 UnityFS bundle；USDZ 只承载**静态蒙皮模型**，动画在端上运行时驱动。PMX / VMD / MLTDTools / MMD Tools 那条路线已作废，不要按它走。

## 目标

1. 从游戏 bundle 导出角色和衣装，转成 RealityKit 能渲染的静态蒙皮 USDZ；
2. 在独立 target `Eidolon3DSpike` 里做固定构图的预览（换角色、换衣装）；
3. 后续（#27–#29）在端上解码原生动作曲线并驱动骨骼、表情。

**不包含**：主线 App 接入、内容包、语音、舞台、相机、完整 Live、素材分发。

## 管线

```text
UnityFS bundle
  → glTF（export_character.py / export_corpus.py，UnityPy）
  → .usdc（Blender，仅格式转换）
  → .usdz（pack_usd.py：面法线平均回顶点 + 打包）
```

Blender 唯一的角色是 GLB → USDZ 格式转换：不做绑定、不做重定向、不改骨架、不调姿态。

### 单角色

```sh
V=build/mltd-spike/venv/bin/python

# 取包（manifest 已下好）
$V spikes/porting-3d/mltd_assets.py --manifest build/mltd-spike/out/mltd/ios-manifest.json \
   --version 1078000 --platform ios --out build/mltd-spike/assets <包名...>

# glTF + 材质表 + 参数图集 + bounds sidecar
$V spikes/porting-3d/export_character.py \
   --body  build/mltd-spike/assets/cb_pr001_014mir.unity3d \
   --head  build/mltd-spike/assets/ch_pr001_014mir.unity3d \
   --out   build/mltd-spike/out/native --name 014mir-ss003
```

`export_character.py` 会同时写 `<name>-materials.json`、`<name>-params.png`、`<name>-bounds.json`。bounds sidecar 是蒙皮后骨架真正画出来的包围盒——RealityKit 的 `visualBounds` 报的是绑定姿势盒，不能拿来取景。

### 全语料

```sh
$V spikes/porting-3d/export_corpus.py \
   --index build/mltd-index.jsonl \
   --out build/mltd-corpus \
   --blender build/mltd-spike/Blender42.app/Contents/MacOS/Blender
```

按内容配对而不是文件名：带 `cb_pr001_<idol>_01_m` 的是身体，带 `ch_pr001_<idol>_face_m` 且无身体材质的是头；材质最少的头胜出。已导出的 USDZ 会跳过，可断点续跑。

当前语料：58 组（001–052 角色、101kot/102mis、4 个通用 `xxx`）、109 个模型、49 套演出服。

### 动作曲线

```sh
$V spikes/porting-3d/compress_motion.py \
   --input  build/mltd-spike/out/il2cpp/loveig-curves.json \
   --output build/mltd-spike/out/curves/loveig.motion.json \
   --verify
```

把 `CharacterImasMotionAsset` 的曲线压成端上格式 `eidolon.motion/1`：30 fps 统一网格、折叠常量、通道增量编码、1/100° 与 1/4000 单位量化。`--verify` 会用原始曲线重新采样对照，报告真实误差。语义（欧拉顺序、各 key_type 的采样与插值）已用 IDA 反编译确认，见 `notes.md` 的 2026-10-31 一节。端上解码器是 `ios/MotionDance.swift`，纯值类型，不依赖 RealityKit。

### 原地动作（照相模式）

```sh
$V spikes/porting-3d/photo_pose.py --bundle <chr_anim_pho_*.reduc.unity3d> --list
$V spikes/porting-3d/photo_pose.py --bundle <...> --output build/mltd-spike/out/poses/
```

相片/剧场的原地动作不是 Humanoid 肌肉曲线，也不是 `.imo`，而是普通 Generic `AnimationClip`：binding 用**路径 CRC32**（`Animator.StringToHash` 就是 CRC32）指向骨骼，键在 `m_MuscleClip.m_Clip` 的 streamed / dense / constant 三个容器里。UnityPy 原样给出容器，脚本自己解（帧 = `float time` + `int32 keyCount` + key × (`int32 曲线号` + 4 个 Bezier 系数)），再拼成和舞蹈同一个 `eidolon.motion/1`，端上不用改播放器。

已验证 `pho_standd_ver01..03` 的 base / check / gretng 九段、以及剧场待机 `the_stdcac_*` 在模拟器里正常播放。注意同尺寸的 `chr_anim_pho_birth_*`、`straw_*` 包是道具模型（SkinnedMesh + Avatar），不是动作——按尺寸找包会踩到，按内容找才对。

缓存里已经有一整套动作，不用下载：`scan_animations.py` 按内容扫一遍（缓存文件名是哈希，只能打开看），2026-11-01 的结果是 1,110 个含 clip 的 bundle、4,085 条 clip，其中姿势类 2,662 条（`the_*` 527、`com_*` 2,102、`lgn_*` 24、`pho_*` 9）：

```sh
$V spikes/porting-3d/scan_animations.py --root <Documents> --out build/mltd-animations.jsonl
$V spikes/porting-3d/export_pose_library.py --index build/mltd-animations.jsonl \
   --out build/poses --catalog build/poses.json
```

`sync_cache.py` 把「索引 → 扫动作 → 导姿势 → 导衣装」串成一件事，`--loop 900` 可以挂在后台：游戏自己下载进缓存的新包会被自动接手（CDN 现在拒绝匿名下载，只有游戏本身能取）。

### 资源下载的现状

`td-assets.bn765.com/<版本>/production/2018/<平台>/<哈希>.unity3d` 现在一律 403：桶 `assetbundles-theaterdays` 已经不允许匿名读，所有版本、iOS/Android 都一样。唯一的合法取用路径是游戏自己（它带着会话去要），所以新资源只能通过在游戏里触发（写真棚、剧场、衣装一览、游戏内下载）进缓存，再由上面的脚本接手。

### 测试

```sh
$V -m unittest discover -s spikes/porting-3d/tests
```

80 个纯函数单测（解码、手性、材质参数、曲线语义、压缩格式、资源定位、摆动尾点），不联网。

Swift 单测（`Eidolon3DSpikeTests`，74 个，从 scheme `Eidolon3DSpike` 跑）：

```sh
xcodebuild test -project EidolonIOS.xcodeproj -scheme Eidolon3DSpike \
  -destination 'platform=iOS Simulator,id=<sim>'
```

### 体检

```sh
$V spikes/porting-3d/audit_materials.py <gltf 或语料目录>
$V spikes/porting-3d/audit_outline.py --with <描边开> --without <描边关>
$V spikes/porting-3d/check_corpus.py <语料目录>
```

## 预览 App

独立 target `Eidolon3DSpike`，不依赖 `EidolonCore` / `EidolonIOS`。

```sh
xcodegen generate
xcodebuild -project EidolonIOS.xcodeproj -scheme Eidolon3DSpike \
  -destination 'platform=iOS Simulator,id=<sim>' build
```

模型从 Documents 递归发现，底部按钮换角色/衣装；也支持文件选择。USDZ（含材质表、参数图集、bounds sidecar）放进 App 容器即可，不提交仓库。

调试开关（`SIMCTL_CHILD_` 前缀给模拟器）：

- `EIDOLON_3D_START=<id>`：启动时选中某个模型；
- `EIDOLON_3D_OUTFIT`、`EIDOLON_3D_YAW`：衣装与起始朝向；
- `EIDOLON_3D_MODEL=<url>`：直接加载指定 USDZ；
- `EIDOLON_3D_NO_OUTLINE=1`：关描边壳，用于 A/B；
- `EIDOLON_3D_PAUSE_AT=<秒>`：停在该时刻的姿势，方便截图对比；
- `EIDOLON_3D_NO_SWAY_COLLIDERS=1`：裙摆/头发不做碰撞，用于 A/B；
- `EIDOLON_3D_LOG_MATERIALS=1`：写 `frame.log`（取景诊断）；
- `EIDOLON_3D_DEBUG_ALPHA` / `_ALBEDO` / `_MASTER` / `_ISOLATE_ROW=n`：材质探针。

## 已确认的坑

- 四元数手性共轭是 `(-x, -y, z, w)`，不是 `(x, y, -z, w)`；写错静止姿势就爆。
- glTF 的 `scenes[0].nodes` 必须是真正的根节点索引。
- Blender 会为骨骼造 42 顶点 Icosphere，取景按「有 Armature 修改器的网格」过滤。
- Unity 的 `m_BindPose` 等于 rest 世界矩阵的逆。
- 身体顶点色全零，不能当颜色来源。
- 每个网格的权重/索引槽位数按实际给的补齐到 4：常规角色 4 个影响骨，双骨骼道具 2 个，刚性配件 0 权重 + 1 个 32 位索引。
- 手性转换 `(x, y, z) → (x, y, −z)`，同时反法线 Z 与三角形绕序；禁止根节点负缩放。

## 不做

- 不绕过 DRM、不解密 `.pak`、不提取 ACB/HCA。
- 不把游戏原始资源或转换产物提交、上传、分发。
- 不改 `EidolonIOS` / `EidolonCore` / `StandRenderer`。
