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

已验证 `pho_standd_ver01..03` 的 base / check / gretng 九段、剧场待机 `the_stdcac_*`、以及四元数曲线混排的 `the_wnd_hap_all` 在模拟器里正常播放。注意同尺寸的 `chr_anim_pho_birth_*`、`straw_*` 包是道具模型（SkinnedMesh + Avatar），不是动作——按尺寸找包会踩到，按内容找才对。

曲线布局按 AssetStudio 的 `ReadCurveData` 对齐：`attribute` 1=位移(3 条)、2=四元数旋转(4 条)、3=缩放(3 条)、4=欧拉旋转(3 条)；容器顺序是 streamed → dense → constant。四元数会转换成欧拉角，缩放丢弃；同一根骨的位置与旋转合并成一条记录。

动作来源有两处：游戏缓存和 `fetch_assets.py` 直连下载的 `chr_anim_*`。`scan_animations.py` 按内容扫一遍（缓存文件名是哈希，只能打开看），`export_pose_library.py` 解码导出，跨两个来源去重后 2026-11-01 共 **2,925 条**（`com_*` 1,595、`the_*` 989、`pho_*` 316、`lgn_*` 25），0 骨骼产物、空占位 clip 592 条已跳过：

```sh
$V spikes/porting-3d/scan_animations.py --root <Documents> --out build/mltd-animations.jsonl
$V spikes/porting-3d/export_pose_library.py --index build/mltd-animations.jsonl \
   --out build/poses --catalog build/poses.json
```

单个角色的全衣装可以直接按资源名导，不经过缓存索引：

```sh
$V spikes/porting-3d/export_idol.py --assets build/mltd-spike/assets \
   --idol 001har --out build/mltd-corpus --blender ...
```

本体取 `cb_<衣装>_<角色>.unity3d`，头优先 `ch_<衣装>_<角色>`（有 face 材质才算），否则回落到 `ch_pr001_<角色>`。

`sync_cache.py` 把「索引 → 扫动作 → 导姿势 → 导衣装」串成一件事，`--loop 900` 可以挂在后台：游戏自己下载进缓存的新包会被自动接手（CDN 现在拒绝匿名下载，只有游戏本身能取）。

### 摆动与根运动

裙摆、头发、飘带按游戏的 `SwayManager` V01 解算：`SwayMove`（跟随 + 弹簧 + 重力）→ `SwayHit`（碰撞）→ `CalcRotate`（角度窗）。2026-11-01 查清并修掉的三件事：

- **碰撞每帧只取最深的那个，推一次。** 游戏 `SwayHit` 对骨列出的碰撞体逐个算穿深，只拿最大的那个把尾点推出去；端上原来把几个推挤量**相加**，再用切向圆最多走 90° 直到「脱离所有碰撞体」。腿一抬，前侧裙片本来就在大腿胶囊里，这条路径就把整圈裙片甩平成一个水平圆盘——就是"伞骨"。现在 `resolvingCollisions` 就是游戏那一步。
- **角度窗按解算器的 up 轴量。** `CalcRotate` 把尾点方向换成相对绑定方向的 yaw（绕身体侧摆）/pitch（在自己径向平面里抬起）。端上原来用 Unity 的 `+Y`-up 公式，而解算世界是 `+Z`-up，下垂的裙片两个角被互换，`1°` 的 yaw 限位形同虚设，横向推挤直接逃出窗口。现在按 `up` 和尾点自己的径向平面分解，直下的骨用绑定 roll（游戏 `m_offset_rot`）兜底。
- **`BASE` 的平移是舞台摆位，不是身体动作。** 全语料 2,919 条里水平通道恒为 0，只有 Y；`com_*` 剧情段最大抬 4.7 个单位（把角色摆进镜头），端上原样加到根骨上就是"飘在空中"。`MotionSampler` 现在把竖直分量限制在 `maxRootLift`（0.5 单位，舞蹈起伏的 90 分位是 0.15）。

`EIDOLON_3D_SWAY_PENETRATION_TOLERANCE=<0..1>` 让尾点允许停在碰撞体里多少（占 `碰撞体半径 + 骨半径` 的比例），默认 0 = 贴在碰撞面上。调大会更"垂坠"，但腿会从裙面穿出来。

`harness/main.swift` 是不依赖 RealityKit 的离线回放器：读容器的 `rest.json`、`poses/*.motion.json`、`*.sway.json`，按 60 Hz 跑同一套 `MotionSampler`/`MotionSway`，打印每片裙骨的峰值角、尾点、yaw/pitch 偏差、脚底最低点和前抬角。诊断与回归用，2 秒出结果：

```sh
swiftc -O -o /tmp/sway_probe spikes/porting-3d/harness/main.swift \
  spikes/porting-3d/ios/MotionPose.swift spikes/porting-3d/ios/MotionDance.swift \
  spikes/porting-3d/ios/MotionJointMap.swift spikes/porting-3d/ios/MotionAssist.swift \
  spikes/porting-3d/ios/MotionSway.swift
/tmp/sway_probe <Documents>/rest.json <Documents>/poses/the_standd_appear_lop_ver01.motion.json \
  <Documents>/001har-pr001/001har-pr001.sway.json 3
```

### Unity 直搬验证（支线）

RealityKit 路线要重写着色与解算，于是另开 `unity-spike/` 验证"直接让 Unity 加载游戏自己的 bundle"。已在 Unity **6000.3.27f2** 实测：

- **能加载、能渲染。** 游戏 bundle（Unity 2020.3.32f1 构建）里的网格、骨骼、材质、贴图，以及五个角色 shader（`Custom/Chr_Basic`、`Chr_Hair`、`Chr_Face`、`Chr_CutOff`、`Custom/BultIn/Bi_CharEye`）全部 `isSupported=True`、无编译错误；材质属性（`_MainTex` 1024×1024、`_OutlineColor`、`_Light (-0.30,-0.40,1.00)`、`_AmbientColor`、`_RimLight`）原样读回；`face` 网格自带 32 个 blend shape。
- **第一次渲染全黑不是 shader 没编译**，而是两个 C# 运行时全局没设：`_GuradeParams` 与 `_FadeColV` 默认为 0，会把整个角色乘成黑。设 `_GuradeParams=(0,1,0,1)`、`_FadeColV=(1,1,1,1)` 后颜色与游戏一致。
- **原生动画播放在任何版本都不行**：`AnimationClip` 能加载（名字、时长正确），但 `GetCurveBindings()` 为 0；换成游戏同版本的 **2020.3.32f1 也一样**（`unity2020-spike/` 实测：`avatar.isHuman=False`，`Animator` 播不动，关节停在 T-pose）。结论是确定的：这些 clip 不走 Unity 的动画系统，是游戏自己的 `CharacterImasMotionPlayer` 直接读 `m_MuscleClip.m_Clip` 的原始曲线。所以动作层必须用自己的播放器——用压好的 `eidolon.motion/1` 按路径写 `localRotation`，姿势在两个版本里都与 RealityKit 端一致。
- **层级只差一节**：clip 路径是 `MODEL_00/BODY_SCALE/BASE/...`，prefab 是 `MODEL_00/BASE/...`，去掉 `BODY_SCALE` 就对上。
- 游戏同版本的 Unity **2020.3.32f1 直接启动会激活失败**（LicensingClient code 10 → legacy → "Failed to activate/update license"），但**带上 Hub 的许可参数**（`-licensingIpc LicenseClient-<user> -hubSessionId <id> -accessToken <token>`，可从 Hub 启动的进程里读到）就能正常跑 `-executeMethod` 并渲染，`unity2020-spike/` 就是这么跑起来的。
- 6.3 未装 iOS 构建模块（没有 `PlaybackEngines/`），上真机前要先 `unity install-modules --module ios`。

探针在 `unity-spike/Assets/Editor/`：`BundleProbe`（加载并渲染各 bundle、打印材质与 shader）、`MotionProbe`（列出 AnimationClip 与绑定数、body+head 组装）、`DriveProbe`（读扁平 `EULR` 曲线包按帧写骨骼并截图）。

### 资源下载

```sh
$V spikes/porting-3d/fetch_assets.py --manifest <manifest .data> \
   --version 1078400 --platform ios --out build/mltd-spike/assets \
   --prefix chr_anim_ --prefix cb_ --prefix ch_ --prefix ca_ --jobs 8
```

清单是 msgpack：`资源名 → [哈希, <哈希>.unity3d, 字节数]`；CDN 地址是 `<版本>/production/2018/<平台>/<文件名>`，需要带游戏的 `X-Unity-Version: 2020.3.32f1` 和 UnityWebRequest UA。下载器按前缀挑、断点续跑（大小不符才重下）、并发可调。

**坑（2026-11-01 踩了两小时）**：同样的 URL 曾一律 403 `AccessDenied`，原因不是桶权限，而是本机 DNS 被 Tailscale MagicDNS 接管、上游解析被污染，请求打到了黑洞 IP；关掉 “Use Tailscale DNS” 后立刻 200。另外部分对象在某个版本里本来就不存在，也会报同一个 403——按报错里的对象名去当前清单里对一下哈希再判断。

清单本身：`curl https://api.matsurihi.me/mltd/v1/version/assets` 给出每个版本的 `indexName`，清单地址是 `<版本>/production/2018/<平台>/<indexName>`。

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
- `EIDOLON_3D_SWAY_PENETRATION_TOLERANCE=<0..1>`：允许的穿深比例（默认 0），用于 A/B 裙摆垂坠；
- `EIDOLON_3D_POSE=<名字或前缀>`：启动时直接挂上某个动作，例如 `the_standd_appear_lop_ver01`；
- `EIDOLON_3D_SHOW_POSES=1`：启动后直接弹出动作选择器（截图/演示用）；
- `EIDOLON_3D_LOG_MATERIALS=1`：写 `frame.log`（取景诊断）；
- `EIDOLON_3D_DEBUG_ALPHA` / `_ALBEDO` / `_MASTER` / `_ISOLATE_ROW=n`：材质探针。

## 已确认的坑

- 摆动解算的世界是 **+Z-up**（USDZ 管线的根转换落在这里），不是 Unity 的 +Y；角度限位按错轴量等于没有限位。
- `BASE` 的旋转是身体，`BASE` 的平移是舞台摆位；两者混着用就是"飘在空中"和"角色明明在跳舞却阳伞化"。
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
