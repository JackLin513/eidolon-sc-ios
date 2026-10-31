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

### 测试

```sh
$V -m unittest discover -s spikes/porting-3d/tests
```

38 个纯函数单测（解码、手性、材质参数、曲线、资源定位），不联网。

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
