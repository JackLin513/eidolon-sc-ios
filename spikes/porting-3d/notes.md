# MLTD 3D spike notes

## 资源

- 游戏/平台：
- 版本：
- 资源路径（仅本机）：`build/mltd-spike/assets/`
- 来源/所有权：

## 工具

- Windows VM：
- .NET Framework 4.7.2：
- MLTDTools：
- Blender / MMD Tools：

## 2026-10-28 iOS 容器只读探测

- 容器：`~/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents`（本机已有 iOS 版缓存）
- 扫描：4885 个文件，4422 个 UnityFS bundle，约 1.36GB；没有导出/复制素材。
- Unity revision 分布：
  - `2018.4.11f1` 1575
  - `2018.4.12f1` 882
  - `2020.3.28f1` 44
  - `2020.3.32f1` 270
  - `2021.3.21f1` 412
  - `2021.3.36f1` 896
  - `6000.2.6f2` 343
- 结论：缓存不是单一版本；2018.4 的 2457 个 bundle 与 MLTDTools v0.3.0 的年代接近，可能可读；2020.3/2021/6000 不应假设旧 AssetStudio 能读。下一步要在 2018.4 bundle 中定位目标角色的 `ch_*`/`cb_*`/`dan_*`，再决定是否启动 Windows VM。
- 探测工具：`unityfs_probe.py`；测试：`tests/test_unityfs_probe.py`（4 tests）。只读 header，不解析资源内容。

## 2026-10-28 模型/贴图实际读取

- 在 iOS 缓存中定位到 `014mir`（春日未来）的 2018.4 bundle：`ch_pr001_014mir` / `cb_pr001_014mir` / `ch_ss003_014mir` / `cb_ss003_014mir`。
- UnityPy 能读：head 有 3 个 Mesh、6 张 Texture、Avatar/SkinnedMeshRenderer；body 有 1 个 Mesh、2 张 Texture、Avatar/SkinnedMeshRenderer。
- 已用 UnityPy 导出 OBJ + PNG 到 `build/mltd-spike/out/`，再用 Blender 4.5 headless 渲染静态 T-pose 到 `build/mltd-spike/out/mirai.png`。
- 结果：身体/衣服/头发/鞋/裙纹理基本正确；脸与眼睛材质仍不完整（脸是闭眼贴图，眼睛层还没接对）。
- 这一步证明“iOS 缓存里的 2018.4 模型可读、可在 Mac 显示”，不证明 MLTDTools 的 PMX/VMD 转换可用。

## 2026-10-28 Headless MLTDTools

- 给 MLTDTools 加了 `--config` 控制台入口（`MainWorker` 改成 `IMainWorkerHost`，ConsoleHost 不依赖 WinForms），补丁见 `mltools-headless.patch`。
- 用 Mac Mono/xbuild + 预编译依赖构建出 `MillionDance.exe --config ...`，在 Windows VM 上运行成功（Windows 侧只需 .NET 4.8 + 预编译 DLL；不必装 Visual Studio）。
- 用 2018.4 的 `ch_pr001_014mir` + `cb_pr001_014mir` + `dan_loveig_01` + `scrobj_loveig` 生成：
  - `mirai.pmx`（约 694KB）
  - `mirai.vmd`（约 24MB，3900 帧）
  - `tex/` 贴图
- PMX 在 Blender + MMD Tools 里能正确导入并渲染 T-pose；VMD 导入后模型爆炸/拉伸，尚未解决。
- 失败点已定位到 VMD 的动画坐标/骨骼映射，不是 PMX/贴图；下一步比较 VMD 与 PMX 的骨骼名/缩放，或用 MillionDanceView 复核 VMD。
- 脸/皮肤偏白不是贴图丢失：PMX 的基础色贴图本身很浅，游戏里还叠了 toon/环境光；Blender 中性光下会显得平、白。眼睛是独立 mesh + 贴图，PMX-only 图里是正常的。
- Blender 4.2.23 LTS + 对应 MMD Tools 4.5.14（bl4.2）仍复现 VMD 爆炸；因此不是 Blender 4.5 单点兼容问题。
- `MillionDanceView` 不能用来复核 PMX/VMD：它加载的是 MLTD 原始 head/body Unity 资源并在 Unity/OpenGL 里播放，不读 PMX/VMD。B 方案不成立，需要 MMD 本体或其他 PMX/VMD 查看器。
- 输出只在 `build/mltd-spike/out/mltd/`，不提交。

## 结果

- [x] head/body 读取（UnityPy）
- [x] 静态模型 + 贴图渲染（Blender，T-pose）
- [x] Headless MLTDTools 生成 PMX/VMD
- [x] PMX 导入 Blender 显示正确
- [ ] VMD 动画导入显示正确
- [ ] PMX 导出
- [ ] 贴图
- [ ] 骨架
- [ ] VMD 动作
- [ ] Blender 导入

## 失败点 / issue 对照

## 截图/录屏（仅本机，不提交）

`build/mltd-spike/out/`


## 2026-10-28 3D 支线（spec #53）

- 新增独立 `Eidolon3DSpike` target：RealityKit + `Model3DPreview`，不碰 Spine/Core。
- PMX → USDZ：[pmx_to_usdz.py](pmx_to_usdz.py)；`usdchecker` 返回 Success。
- RealityKit macOS 能加载 `mirai.usdz`；原始 extents 约 0.106 × 0.127 × 0.023，App 按高度归一化到 1.6m。
- Simulator build 成功；模拟器 UI 测试环境当前 `simctl`/launchd_sim 卡住，未拿到截图。
- Air 安装失败：设备 free developer profile 已装 3 个 App（AltStore / Eidolon / Bangumi），spike 是第 4 个，需先删一个或换付费账号。
- `usdchecker` 输出 `Success!`；RealityKit macOS 加载 extents ≈ 0.106 × 0.127 × 0.023，App 归一化到 1.6m。
- Review 修正：文件选择的 security-scoped URL 先复制到 Documents；灯光只加一次；空 bounds 报错；empty/failure 共用 placeholder。
- Air 已安装并截到静态模型：几何、比例、orbit 相机正常；但当前截图仍是灰色材质，纹理 USDZ 已包含 PNG 且在 USD 里是 UsdPreviewSurface，RealityKit 在 Air 上没有显示贴图。Air 截图：`build/mltd-spike/out/ios-3d-air-2.png`。
- Air 重启并清理安装后重新安装成功：textured USDZ 正常显示，头发/眼睛/衣服/裙子/鞋子贴图都在，比例和朝向可用。截图：`build/mltd-spike/out/ios-3d-reboot.png`。
- orbit 相机由 RealityKit 的 `realityViewCameraControls(.orbit)` 提供；未做手势自动化，只确认代码路径和静态画面。
- 纹理问题实际是安装缓存/旧 build，不是 USDZ 材质；textured USDZ 已嵌入 PNG。
- 增加 `Model3DResourceLocator` 与 iOS XCTest：env → bundle（递归）→ Documents；`xcodebuild test` 因模拟器 boot timeout 未执行，但测试代码已编译。
- 重启 Air 后重新安装，textured USDZ 正常显示；此前空页面是设备安装/快照缓存问题。

## T1（#55）双衣装静态预览

- 新增 `Model3DOutfit`：`pr001` 私服、`ss003` 演出服；两套 USDZ 作为 target resources 打入 App。
- UI 底部可切换两套衣装；固定默认舞台/机位，orbit 保留为调试手势。
- 载入失败保留上一套实体并显示红色错误条；没有上一套时才进入失败页。
- Air 截图：`build/mltd-spike/out/ios-3d-pr001d.png`、`build/mltd-spike/out/ios-3d-ss003.png`。
- `ss003` 第一次从 Windows VM 复制出的 PMX 损坏（同尺寸但 MMD Tools 报 signature invalid）；重新复制后导出成功。以后跨 VM 复制大文件要重拷贝/校验。
- 新增 outfit-specific locator 单测；`build-for-testing` 通过，模拟器测试运行仍受 boot timeout 阻塞。

### T1 review 修正

- 固定舞台改为与主线一致的渐变背景；移除默认 orbit，默认机位固定。
- 换装不再卸载 RealityView：旧实体保留，载入时覆盖 spinner；成功后替换实体，失败保留上一套并显示错误条。
- 加入 `StandDirection` 状态（calm），换装不重置；动作消费在 T2。
- 资源引用从 Xcode 工程移除；`postBuildScripts` 仅在本地资源存在时复制，clean checkout 不会因缺 USDZ 构建失败。
- 移除文件选择器，避免未结构化的加载 Task 与衣装选择竞态。
- 当前 Air 重新安装被设备/连接阻塞，最新固定机位版本尚未重新截图；旧双衣装截图仍有效。

### 资源打包最终方案

- USDZ 重新作为 target Resources，由 Xcode 正常签名。
- `preBuildScripts` 只在文件缺失时创建空占位，保证 clean checkout/无素材时仍能构建；本地有真实 USDZ 时不会被覆盖。
- 最新 build 已生成两个 USDZ；Air 安装连续 `devicectl` timeout，需解锁设备后复验。

### T1 模拟器复验

- iPhone Air 模拟器（`6C599927...`）启动成功，最新 build 已安装并截到两套衣装：`build/mltd-spike/out/sim-pr001b.png`、`build/mltd-spike/out/sim-ss003b.png`。
- 固定渐变舞台、固定机位、底部私服/演出服按钮均可见；`StandDirection` 为 calm 并跨换装保留。
- `xcodebuild test` 在模拟器执行：4 个 locator 测试全部通过。
- 实机安装仍超时，最终 Air 验收留给 T6（#60）。

### T2 动作映射起点

- 新增 `Model3DAction` / `Model3DActionMap`：calm→idle、speaking→talk+mouthOpen、looking→listen、nod→nodYes/nodNo，情绪透传。
- 新增 4 个纯映射单测，模拟器全部通过。
- 渲染器动作播放/按钮状态机尚未接上，T2 不能关闭。

### T4 Phase 0（MMD/ARM）

- Windows ARM 无法正常安装 x64 VC++ 2008；改用 App-local x64 VC90（从 VisualCppRedist AIO 提取 `msvcr90/msvcp90/vcomp90` + 私有 manifest，manifest 版本改成 MMD 依赖的 `9.0.21022.8`），MMD 进程能启动。
- 在 VM 桌面打开 `C:\MMD\app\MikuMikuDance.exe`，加载 `mirai.pmx` + `mirai.vmd`：动作/骨骼运动正常；Mesh 因 Windows ARM/MMD 渲染问题不可见。
- 结论：VMD 动作有效性通过（按用户确认），Phase 3 可以用 VMD 路径；但“MMD 里看到模型内容物”仍受 ARM 渲染限制，不能用于模型视觉验收。
- 下一步不是再装运行库，而是解决 Blender/MMD Tools VMD 导入爆炸，或写 VMD→USDZ 导出。

## 原生动作分析（IDA + Il2CppDumper）

- 将 PlayCover 容器里的 `UnityFramework` 复制到 `/tmp/MLTD-UnityFramework` 后，IDA 可以打开；容器原路径会 `Failed to open database`。
- 完整 IDA 分析完成：702,223 个函数，数据库 `/tmp/MLTD-UnityFramework.i64`。
- Il2CppDumper 6.7.46 生成 `dump.cs` / `il2cpp.h`（本地 `build/mltd-spike/out/il2cpp/`，不提交）。
- 关键原生类型/地址：
  - `CharacterImasMotionAsset.Curve`：`path`、`attribs`、`values`。
  - `CharacterImasMotionData.CurveSet`：`px/py/pz/rx/ry/rz` 六个曲线，按 `path` 分骨骼。
  - `CharacterImasMotionData.CreateFromImoAsset` @ `0x37EC030`。
  - `CharacterImasMotionData.GetKeyCount/GetDeltaTime/GetKeyTime/GetKeyValue` @ `0x37EC388/0x37EC454/0x37EC4A4/0x37EC598`。
  - `CharacterImasMotionPlayer.SolveCurve` @ `0x37E80B8`、`GetLastSeekerPosition` @ `0x37E89DC`。
  - `CharacterImasMotionPlayerDance.SolveCurves` @ `0x37EE384`、`SetResultToTransforms` @ `0x37EE99C`。
- 曲线 `KeyType`：0 固定 60fps、1 时间/值对、2 常量、3 全帧曲线、6 全帧偏移、7 增量帧；`SolveCurve` 负责 Hermite/线性插值。
- 结论：应直接从 `.imo.unity3d` 的 `CharacterImasMotionAsset` 解码，生成 USDZ/骨骼动画；不再依赖 MMD/VMD 或 Blender 的 MMD Tools 导入。

### 原生曲线直接套骨骼的实验

- 从 `dan_loveig_01` 解出 180 条曲线（`CharacterImasMotionAsset`），导出为 `/tmp/loveig-curves.json`（本地副本在 `build/mltd-spike/out/il2cpp/`）。
- 直接按 native path（MUNE1/MUNE2/SAKOTSU_L/...）映射到 MMD 骨骼并应用 Euler 角，模型仍爆炸。
- 结论：原生曲线本身可读，但 native 骨骼局部轴/rest pose 与 MLTDTools PMX/MMD 骨骼不一致；需要按 native skeleton 的 rest transform 做 retarget，不能直接套 MMD 骨骼。下一步应构建 native skeleton 或使用 `CharacterCommonSkeleton` 的 rest 矩阵。

### 真矩阵链尝试

- 按 `skin = rest^-1 * currentWorld`、`local = rest * skin * parentWorld^-1` 实现一帧 retarget，使用 PMX rest 作为 native rest 的代理。
- 结果仍爆炸。说明 PMX rest 不能替代 native rest；必须先取得 `CharacterCommonSkeleton` 的 native rest world matrices，再套矩阵链。
- 未完成 T5；不能继续用 PMX rest 冒充 native rest。

### native skeleton rest（第二轮）

- 从 head/body Unity Transform 层级提取 188 个 native 节点（localPosition/localRotation/parent），保存为本地 `native-skeleton.json`。
- 用 native rest + native curves + PMX binding 矩阵链渲染，仍爆炸。
- 已排除“没有 native rest”这一项；剩余问题在 native 路径/父子关系或 native→PMX binding 的对应。
- T5 仍未完成。

### 运行时 native rest dump（成功）

- Frida attach 到 PlayCover MLTD，找到 `UnityFramework` 的 `il2cpp_*` 导出。
- 通过 `ilm2cpp_class_from_name("Imas","CharacterCommonSkeleton")`、静态字段 `s_static_data` 读取。
- 已 dump 64 根 native 骨骼：`bone_id/local_position/local_angle`。
- 文件：`build/mltd-spike/out/il2cpp/native-rest.json`。
- 这是真正的 `CharacterCommonSkeleton` rest，不是 Avatar/Transform 推断。

## 2026-10-29 原生路线（ADR-0022）

放弃 PMX / VMD / MLTDTools / MMD Tools。模型、骨骼、绑定、蒙皮、贴图、表情形变全部从游戏自己的 UnityFS bundle 读，动画在端上用 `SkeletalPosesComponent` 每帧算。spec 见 #54，执行见 #73–#77。

**取包**：`mltd-assets.py` 用 `mltd-asset-downloader` 下载的 manifest 直接向 CDN 取指定包，不问工具要全量。URL 形如
`https://td-assets.bn765.com/<version>/production/2018/iOS/<manifest 第二字段>`；
当前 version `1078000`，manifest 22.7 MB。只取 9 个包（两套衣装的 `ch_/cb_/ca_/cas_` 加 `dan_loveig_01`），约 5.5 MB。

**实测结构（UnityPy 1.25.4）**

| 包 | 内容 |
|---|---|
| `ch_pr001_014mir` | 5 个 SMR（face / hair / eyes / 两个 acc），各 37 骨；`face` 有 **32 个 shape key**；Avatar TOS 45 |
| `cb_pr001_014mir` | 1 个 SMR，134 骨；body 4422 顶点、11440 索引；Avatar TOS 143 |
| `ch_ss003_014mir` / `cb_ss003_014mir` | 同上，body 4123 顶点、124 骨 |
| `dan_loveig_01.imo` | **只有 MonoBehaviour + MonoScript + AssetBundle**，脚本类是 `Imas.CharacterImasMotionAsset`，字段 `curves` / `kind` / `time_length` / `attribs` |

所以这支舞**不是** `AnimationClip`，是游戏自定义的 `CharacterImasMotionAsset`——但 UnityPy 能直接读，不需要自己写二进制解析。曲线的 180 条按 Transform 路径寻址，与既有 `loveig-curves.json` 一致。

**顶点布局**：`m_DataSize` 就是整块顶点缓冲，三条流首尾相接、每条按 16 字节对齐。
stream0 stride 40（pos12 + normal12 + tangent16）、stream1 stride 12（color4 + uv8）、stream2 stride 32（权重 Float32x4 + 骨索引 **SInt32x4**）。
**每顶点 4 个骨影响**，所以 `m_VariableBoneCountWeights` 那套截断风险在本作不存在。

**骨头集合**：头 37 骨与身体 134 骨共用 `KUBI` / `ATAMA` / `KUBI_RT__twist_x0`，其余 35 根头发骨只在头包里。合并成一套 joint 要做名字对齐。

**已做**：`unity_mesh.py`（顶点流解码、索引解码、手性翻转）与 `mltd_assets.py`（manifest 解析、CDN URL 推导）各有单测，共 20 个通过。

### 2026-10-29 导出器进度（#73）

已能出一张完整的未来（pr001 私服）：头、发、身、裙、鞋、脸，T-pose，正面，比例正确。

**踩到并修掉的坑**

1. **四元数手性共轭写反**。镜像 `diag(1,1,-1)` 把旋转轴送到 `(x, y, -z)`，但同时把**角度取反**，合起来等价于 `(-x, -y, z, w)`。写成 `(x, y, -z, w)` 会让整具骨架在静止姿势就爆炸。已加数值断言钉住。
2. **glTF 场景根写成了节点 0**。节点按名字排序后 0 号是个中间骨，整棵树挂错地方。已改成真正的根节点索引。
3. **IBM 用 Unity 的 `m_BindPose`**。先验证过它与 rest 世界矩阵的逆**逐元素相等**（134/134 个 joint，误差 0），所以两者可以互推；现在直接用层级算，保证与导出的节点自洽。
4. **Blender glTF 导入会造一个 42 顶点的 Icosphere 当骨骼显示形状**，它会把包围盒撑到 2.0 m，渲染取景要按「有 Armature 修改器的网格」过滤。

**还没对的地方（下一步）**

- **身体材质只取了第一个**。`body` 网格有 3 个 submesh、3 个材质，我们只用了 `m_Materials[0]`，而那是一张贴着领结的贴花图，所以衣服渲染成黑的。要按 submesh 切 primitive、逐 submesh 选材质。
- 身体顶点色全是 `(0,0,0,0)`，没用；COLOR_0 只在非全零时才写。头/脸有真实贴图，UV 的 V 翻转（Unity 左下原点 → glTF 左上原点）验证正确。
- 32 个 face shape key 还没导出成 morph target。
- 还没转 USDZ、还没接进 `Eidolon3DSpike`。

### 2026-10-29 USDZ 与模拟器（#73 收尾）

两套衣装都能从原生资产导出成 USDZ：`mirai-pr001.usdz` 2.2 MB、`mirai-ss003.usdz` 2.3 MB，各自 8 张贴图内嵌。Blender 只做 GLB → USDZ 的格式转换。

**Blender 4.2 的坑**：`bpy.ops.wm.usd_export` 没有 `export_format` 参数，格式由扩展名决定；参数是 `export_armatures` / `export_shapekeys` / `export_animation`，不是 `export_skeletons` / `export_animations`。

**glTF 的坑**：每个 primitive 必须有自己的属性 accessor。共享 accessor 时 Blender 的导入器会去重，然后给第二个 primitive 产出越界索引。另外 `buffers[0].uri` 要跟着 `--name` 走，不能写死。

**未完成**：装进 iPhone 18 Pro 模拟器后启动，截图全黑，没有崩溃日志。iPhone Air 模拟器本身坏了（`simctl install` 挂住、`bootstatus` 报 `Data Migration Failed`）。下一步要先查这个黑屏，不要当成模型问题。

### 2026-10-29 曲线压缩（#74）

三种 key_type 实测：

| key_type | 曲线数 | 值个数 | 结论 |
|---|---|---|---|
| `Const` | 74 | 1 | 整段一个值，可折叠成常量表 |
| `FullFrame` | 52 | 7801 | **60 fps 每帧一个**（130.0 s × 60 + 1），已确认 |
| `Discreate` | 52 | 22 / 54 / 4662…4890 不等 | 长度不规整，**采样语义未确认** |

压缩实测（`motion.py`，33 个单测通过）：

- 折叠 74 条 `Const` + `FullFrame` 降到 30 fps + int16 量化
- 0.01° 精度 → **2.45 MB**；0.1° 精度 → **1.99 MB**（原始 13.32 MB）

**未确认的三件事**（原计划用 rea 反编译确认，但这台机器上 rea 6.8.0 **没有 ida provider**——`rea providers` 只列出 ghidra / hopper / native-macos / rea-artifact-graph / rea-dotnet-static / sqlite）：

1. `Discreate` 的采样语义与时间轴（决定还能压多少）
2. 欧拉顺序与符号
3. `MODEL_00/BODY_SCALE` 在角色实际层级里是否存在

要补 IDA：`idalib-mcp` 在 `~/.local/bin/idalib-mcp`，配置在 `~/.dsh/plugins/rea-bundle/ida-mcp.json`，但 rea 6.8.0 不认这份配置。

### 2026-10-29 模拟器里跑通（#73 收尾）

两套衣装都能在模拟器里正立、正面、贴图正确显示。截图：

- `build/mltd-spike/out/native/sim-final.png`（私服）
- `build/mltd-spike/out/native/sim-ss003.png`（演出服）

**这一步修掉的四个 Blender 转换缺陷**

1. **朝向转了 90°**：角色朝 +X 而不是朝相机。在导出前把整具 rig（网格 + 骨架）挂到一个 yaw = -90° 的父空对象下面。蒙皮是相似变换，整 rig 一起转不破坏形变。
2. **法线是 `faceVarying`**：Blender 的 USD 导出器**无条件**写 face-varying 法线，`shade_smooth()` 和清 custom split normals 都改不掉。RealityKit 不做面法线插值，于是头发和所有曲面都是硬边块面。解决：`pack_usd.py` 用 pxr 把面法线平均回顶点、改 `interpolation=vertex`，再用 `UsdUtils.CreateNewUsdzPackage` 重新打包。7485 顶点 → 7485 条法线。
3. **`upAxis` 是 Z**：Blender 默认不转，RealityKit 要 Y。`convert_orientation=True`。
4. **蒙皮网格被挂到骨下面**：父级的 90° 会被重复施加，表现为侧身 + 鞋子和腿断开。导出前把它从父级摘掉、世界矩阵归一。

**流程因此变成**：glTF →（Blender）`X.usdc` →（`pack_usd.py`：修法线 + 打包）`X.usdz`。

**构图**：`Model3DPreview` 把模型推到 z = -1.35。原先居中在原点，RealityKit 默认相机也在原点，等于贴在脸上，脚会被切掉。

**注意**：`Model3DPreview` **没有** orbit 手势，这是 spec 里的决定（固定正面构图），不是 bug。

### 2026-10-29 toon 着色

`ToonShading.metal` 是一段两段式 ramp（>0.55 全亮、>0.15 半亮、否则 0.66 保底），`ToonShading.swift` 把载入模型的每个 `PhysicallyBasedMaterial` 换成 `CustomMaterial`，把它自己的 baseColor 贴图接到 `custom.texture`。

**踩到的 API**

- `CustomMaterial(surfaceShader:lightingModel:)` 本身是 **throwing**（它在编译 shader）。
- `CustomMaterial.SurfaceShader(named:in:)` 的 `in` 是 **`MTLLibrary`**，不是 `Bundle`。用 `MTLCreateSystemDefaultDevice()!.makeDefaultLibrary()`。
- `CustomMaterial.Texture(_:)` 也 throwing。
- **surface shader 里拿到的 UV 没有翻 V**。内置材质内部会翻，自定义 shader 必须自己 `1.0 - uv.y`，否则整张图集错位（表现为衣服变成橙色、袖子变成格子）。

效果：两套衣装都不再有压黑的暗部，头发和脸干净。

### 2026-10-29 换装修复与画质

**换装不生效的真因**：不是按钮。`RealityView` 的 make 闭包只跑一次，重新给 `@State entity` 赋值不会重新挂载；按钮状态变了、模型没换。改成先 `content.add(container)`，换装时清空 `container` 的子节点再挂新的。

**换装卡死**：`Entity.load(contentsOf:)` 在主 actor 上解析 5 MB USDZ。改成 `nonisolated` 静态方法，离主线程跑。

**头部色块/伤疤**：不是打光，是**图集 mipmap 串色**。card 贴图是一张图集，采样 mip 链会把相邻岛的颜色混过来（头发上出现青紫色块，而头发贴图里根本没有这些颜色）。sampler 改成 `mip_filter::none` + `address::clamp_to_edge` 后消失。

**ramp 过硬**：三段式（0.55/0.15）在低模脸上切出硬边，看着像疤。改成 `mix(0.80, 1.0, smoothstep(0.15, 0.55, lambert))`。

**调试开关**：`EIDOLON_3D_SWAP_SECONDS=6` 启动后自动换一次装，用来验证换装路径（模拟器没有点击自动化）。

### 2026-10-29 UV 通道 bug（真正的原因）

**症状**：ss003 演出服胸口一大块红色墨水、身上到处色块；pr001 看着正常。

**根因**：`TEXCOORD0` 的 offset 被写死成 4。两条流的布局其实不同：

| 包 | stream1 通道 | UV offset |
|---|---|---|
| `cb_pr001_014mir` | color(UNorm8x4) @0 + UV @4 | **4** |
| `cb_ss003_014mir` | 只有 UV @0 | **0** |

写死 4 之后，ss003 的所有 UV 都从错误位置读，采样到图集的随机区域——所以是"墨水""色块"，而不是整体错位。

**修法**：`unity_rig` 改成从 `m_VertexData.m_Channels` 按通道号查 offset/stride，不再硬编码。通道号：0 位置、1 法线、4 UV0、12 权重、13 骨索引。

修完两套衣装在模拟器里都正确（`fix-pr001.png` / `fix-ss003.png`）。

**顺带发现**：MLTD 的材质多数有两个贴图——`_MainTex`（反照率）和 `_SubTex`（发光/配色遮罩）。我们只用了 `_MainTex`，暂时够用，但发光部件会缺。

### 2026-10-29 高光（第一版）

原版材质里的高光不是烘在贴图里的，是两套参数：

- **边缘光**：`_RimLightOn` / `_RimBorder` / `_RimOffset`（脸、头发）
- **眼睛高光**：`_SpecTex_Center_X/Y`、`_Zoom`、`_Rotate_Z`、`_Scale_X/Y`、`_Vector_X/Y`、`_Fade`——亮点是算出来的
- 分级参数：`_ShadingBorder` 5.0、`_ShadingOffset` 0.25

第一版实现：`toonSurface` 加 fresnel 边缘光（0.10）+ 收紧的高光（pow 48，阈值 0.72）；另写 `eyeSurface`（pow 120、强度 0.85）想给眼睛单独加强。

**没生效**：眼睛那条路靠 `material.name` 匹配 `"eye"`，但 USD 导入后 `Material.name` 可能是 nil，所以全部走了通用 shader。下一步要用可靠标识（材质名、贴图尺寸，或按 primitive 索引）来分流。

### 2026-10-29 高光第二版：`_SubTex`，以及它到底是什么

第一版把高光当成"程序化算出来的"（`_RimLight*` / `_SpecTex_*`），结果眼睛那条路也没生效。这版先按 `research-mltd-materials.md` 的结论把真正承载高光的那张贴图搬过来，结论是：**MLTD 的高光是 `_SubTex` 这一层加法贴图，不是参数**。

**证据**：把 `_SubTex` 导出后再渲染，眼睛出现明确的白色眼神光（原来是平的）、ss003 的霓虹描边从暗紫变成亮白。同一份 glTF 去掉 `emissiveTexture` 再渲染，这两处都消失。两版对比图在 `build/mltd-spike/out/native/probe-glow-ss003.png`（开）与 `/tmp/noglow-ss003.png`（关）。

**原来的调查结论要修正一处**：`_SpecTex_*` 那套参数确实存在，但眼睛上真正画出亮点的是 `_SubTex`——一张白底（`(255,255,255)`）配 alpha 遮罩、覆盖率约 2% 的贴图。`_SpecTex_*` 是经营这套高光的运动/缩放参数，不是高光本身。

**这条链上的四个坑**

1. **`_SubTex` 的 alpha 是遮罩，emissive 只乘 RGB。** 直接把带 alpha 的原图当 emissive，眼睛会整块发光。导出时先把 alpha 乘进颜色（`premultiplied()`），alpha 再置 255；ss003 的 glow 本来就 alpha=255，乘积是恒等。测试在 `tests/test_export_character.py`。
2. **`params.textures().emissive_color()` 能采样，但 `.lit` 光照模型不会替你把 emissive 加进结果。** 验证方法是先把 `emissiveColor` 的 tint 设白（结果没变化），再在 shader 里自己加（结果出来了）。所以现在 tint 设成 `.black` 只用来**绑定**贴图，加算在 `toonSurface` 里做——否则两条路径同时生效会加两遍。
3. **UV1 读错了地方**：`decode_channel(stream(uv1_channel.stream), ...)` 少写了 `offsets[...]`，把 stream 序号 1 当成字节偏移，读出来是 `-1.7e18` 量级的垃圾。修好后 hair 的 UV1 范围是 u∈[0.099, 0.998]、v∈[0.002, 0.995]。
4. **Blender 的 USD 导出器只写一套 `primvars:st`。** 场景里 `UVMap` / `UVMap.001` 都在，`export_uvmaps=True`，但导出的 USD 里没有 `primvars:st1`。所以头发的 `_SubTex`（唯一需要 UV1 的材质）暂时跳过——用 UV0 采样只会把几笔高光甩到头上，比没有更糟。

**顺带修掉的构图问题**：`visualBounds` 在实体还没挂到场景里时读到的包围盒不可靠（骨架 rest pose 决定），pr001 因此被缩到四分之一个 ss003。现在先 `container.addChild`、睡 120 ms 再 `normalize`。归一化目标从魔数 `1.6` 改成显式常量 `targetHeight = 2.3`——默认 `RealityView` 相机在 z = -1 处的可视高度约 3.1 单位，2.3 正好留出状态栏和按钮的位置。

**仍未做**：`_AmbientColor` / `_DiffuseColor` / `_ShadingOffset` / `_Outline*` 这些材质标量仍没进导出，所以明暗分级还是全局一套，没有描边。

### 2026-10-29 参数迁移：把每个材质的完整参数送到端上

目标是不再靠猜全局常量，而是把游戏每个材质自己的颜色和浮点原样交给 shader。

**导出**：`material_params.py` 读整个 `m_SavedProperties`（每个材质 9–11 个颜色、18–38 个浮点），写成 `<name>-materials.json`。shader 名只在 `Shader.m_ParsedForm.m_Name` 里，`Material.m_Shader.m_Name` 全是空串。五个 shader 都认出来了：`Chr_Glow` / `Chr_Basic` / `Chr_Face` / `Chr_Hair` / `BultIn/Bi_CharEye`。

**传输**：一条 `float4` 装不下 30 个数。试了三条路，只有第三条能用：

1. `LowLevelTexture` + `metal.replace(region:)` —— **写不进去**，CPU 回读全是 0。加了 `.shaderWrite` 也没用。
2. `TextureResource(dimensions:format:contents:)` + `Format.raw(pixelFormat:)` —— `Dimensions2D` **没有公开初始化器**，编译不过。
3. `TextureResource(contentsOf:)` 读一张 PNG —— **可以**。参数烘进 `material_atlas.py` 生成的 32×64 图，**每texel 一个参数，存在 alpha 通道里**：颜色通道会被色彩管理（sRGB PNG 取回来是线性化过的），alpha 原样通过。shader 用 nearest 采样读 `.a`，一个字节就是 `value/255`。

**`.unlit` 用不了**：`CustomMaterial(lightingModel: .unlit)` 下 `custom` / `emissive` 贴图不再绑定，整个人渲染成黑剪影（换成有效参数表之后依然如此）。只能用 `.lit`，于是 PBR 光照会在 shader 结果上再加一层；目前靠三盏方向光把亮度维持住。

**已验证**：调试开关 `EIDOLON_3D_LUT_DEBUG=1` 把参数行直接画成颜色（R=shader 类型/10，G=`_Color.r`，B=|\_Light.x|），躯干打出 (0.38,0.76,0.58)、头发 (0.71,0.81,0.62)，与表里的 0.2/0.502/0.3 和 0.4/0.502/0.3 按同一增益吻合——查表真的接通了。

**顺带确认的事实**：`_Light` / `_RimLight` 在所有材质里都是 `(-0.3,-0.4,1.0)`；`_Color` 全是 0.502；`_DiffuseColor` 全白；`_OutlineColor` 全同；`_ShadingOffset` 0.25、`_ShadingBorder` 5.0、`_RimOffset` 0.25、`_RimBorder` 2.0 也全同。真正逐材质变化的是 `_AmbientColor`（0.863 灰 / 0.841,0.709,0.647 头发 / 0.980,0.827,0.788 皮肤）、眼睛的 `_SpecTex_*`、头发的 `_Sub*`、`Chr_Glow` 的 `_WhityCol`/`_WhiteMode`、脸的 `_Bihaku*`/`_Reddish*`。`_BumpScale`/`_Parallax`/`_Glossiness` 是 Unity Standard 的遗留字段，没有 `_BumpMap` 槽，所以**原版没有法线贴图，凹凸这一项没有可迁移的东西**。`_Cube`（反射）在所有材质的 `m_PathID` 都是 0，`_UseReflect`=0——**原版这两套衣装不反射**。

### 2026-10-29 着色换成原版公式（从游戏自带的 GPU 程序反推）

**来源是一手**：主包 `Data/data.unity3d` 里 200 个 `Shader` 全带 LZ4 压缩的 `compressedBlob`，解压后不是汇编，而是 **hlslcc 生成的完整 Metal 源码**。iOS 上 Unity 就是把它编成 metallib 跑的，所以这五个 shader 的数学不需要反汇编、不需要看重实现。提取方法在 `research-mltd-shading-math.md` §8（该文件**不入库**，因为它逐行引用了反编译出来的游戏代码；结论已全部落到 `ToonShading.metal`）。

**写进 shader 前纠正的四处错判**

1. **`_Light` 在视空间**，且只翻 x、y，z 保持不变：`L = normalize(-Lx,-Ly,+Lz)`。明暗是**线性斜坡** `saturate((N·L - 0.25) * 5)`，不是 smoothstep。
2. **`_Color` / `_IllumiColor` 恒为 0.5，是"中性"**，shader 里到处 `×2` 抵消。以前按贴图直接乘，整体亮度就差了。
3. **`_SubTex` 有三种语义，不是统一加法**：
   - `Chr_Glow`：门控是 `_MainTex.a * _SubTex.g > 0.5`（**绿通道**），命中时把颜色**替换**成 `2*base*_GlowColor`（= 不参与明暗的纯贴图色），所以霓虹线看着像自发光；
   - `Bi_CharEye`：alpha 当遮罩，向 `_IrisColor` 插值——眼神光其实是"白色插值"；
   - `Chr_Hair`：`nz³` 加权的加法高光，需要第二套 UV。
4. **`_RimOffset` / `_RimBorder` 不在编译出来的变体里**。边缘光是顶点路径 `(1-|N·V|)^5 * saturate(2*(N·Lr-0.25))`；另一条重算路径依赖 C# 每帧推入的 `_RimCtrl`，取值未知。

**顺带确认**：`_Cube` 全包 75 个材质里没有一个非空，`_USEREFLECT_ON` 从未开启 → **原版不反射**；`_BumpMap` 槽不存在 → **原版没有法线贴图**；`02alp_m` 不是半透明，是 `_ISCUTOFF_ON` 的 alpha 裁剪；顶点色 R 被夹到 ≥1，**实际不影响颜色**。

**踩到的两个 RealityKit 限制**

- `RealityKit` 的 emissive 贴图**会丢 alpha**（USDZ 里的 PNG alpha 还在，0–255 完好）。所以 `_SubTex` 导出时把 alpha 乘进 RGB，shader 用 `.r` 当遮罩。ss003 的 glow 本来 alpha=255，乘积是恒等，绿通道门控不受影响。
- `.unlit` 下 `custom` / `emissive` 贴图不再绑定（整只角色黑剪影），只能用 `.lit`，于是 PBR 光照会在着色结果上再加一层——这是目前剩下的主要失真来源。

**眼睛高光**：原版用第二套 UV 算一个透镜畸变、随视角旋转的高光位置，但 `eyes` mesh 根本没有 uv1（一手数据里只有 uv0），公式跑起来会把整个虹膜刷白。改用 MLTDTools 记录的做法：按 base UV 采样（两张图尺寸相同，等价）。这也是研究报告 §7 里那条 UNVERIFIED 的处置。

**构图**：`visualBounds` 在骨骼就绪后还会继续变大好几帧，读一次会把模型缩成四分之一或撑爆。改成挂载后连续 6 帧取最大包围盒（异步 100 ms 一次），并允许换装时重算。

### 2026-10-29 色彩空间：已验证是 Gamma

前面按"饱和度偏高 + 蓝通道被吃"推断项目是 Gamma，属于推测。现在读到了游戏自己的设置：

```
UnityPy.load(.../Data/data.unity3d)
  PlayerSettings.m_ActiveColorSpace == 0        # 0 = Gamma, 1 = Linear
```

注意：直接 `obj.read()` 会因这个 2018.4 数据的 typetree 少 4 字节报
`Expected to read 900 bytes, but only read 896`，用 `read(check_read=False)` 才能拿到。

旁证（方向一致）：`Chr_Glow/Basic/Face/Hair/Bi_CharEye` 五个角色 shader 里**没有任何**
色彩空间转换（无 `ColorSpaceDouble`、无 `LinearToGammaSpace`），全包出现 `0.416666`
的只有 UI / Legacy 那几个内置 shader。也就是说角色 shader 不转换，算术直接在当前
色彩空间里做——Gamma 项目里就是在 sRGB 值上做 `_Color*tex - 0.02`。

RealityKit 采样会线性化、输出也期望线性，所以 `ToonShading.metal` 在采样后做
`toGamma`、出结果前做 `toLinear`，把数学放回 sRGB 空间。实测头发饱和度
0.84 → 0.71（游戏 0.45），余下差距归因于 `.lit` 的 PBR 那层。

## 2026-10-30 描边与 unlit 输出

- **纠正**：之前记「`.unlit` 会把自定义纹理绑丢」是错的。`RealityKitSurfaceShader.h:484-494`
  写明 unlit 材质只取 `set_emissive_color()` 的输出；黑剪影是因为着色器只写了
  `set_base_color()`。现在基色写 0、结果写 emissive，同一份着色器两种光照模型都对。
  默认 unlit（`EIDOLON_3D_LIT` 可切回），RealityKit 的 PBR 那层和它带来的多余光照随之消失。
  截图对比：头发从偏橙的高饱和变成红棕，肤色回暖，和游戏接近了很多。
- **描边**：游戏是倒装壳——同一网格再画一遍，沿法线外推、`Cull Front`。RealityKit 没有
  单模型的第二 pass，所以克隆一份做兄弟节点，`faceCulling = .front`，`lightingModel = .unlit`，
  颜色写死近黑。第一次做的时候外推量写死 0.004，结果整块黑：这是**模型本地空间**的单位，
  而这个 USD 原生只有 1.58 高，壳被撑得比人还大，从内部看就是全黑。改成按模型自身高度
  取 0.003。
- **取景**两个老 bug 一并修了：`fit()` 设了 entity 的 transform，`applyInspection` 又设容器的，
  缩放被应用两次；换装时容器残留上一次变换，而 `visualBounds(relativeTo:)` 是世界坐标，
  会一路累积。现在每次加载先把容器归零。另外实测默认相机不是盯着内容原点，居中后她在
  画面偏下，所以按半个模型高度抬了一点。

## 2026-10-30 已知缺口（全角色上线时留的账）

按优先级，都是已知未做，不是未知问题：

1. ~~**`Chr_Alpha` 的混合数学没移植**~~ —— 已补：材质切 `.transparent`，
   shader 用 `set_opacity(_MainTex.a)`。2026-10-30 在 003mik 吊坠上实测通过
   （透明区能透出白衬衫）。**残留**：`_IsCutOff` 材质仍用"近黑即丢弃"替代真正的
   `_MainTex.a < 0.5` 裁切，实测会误丢 795 个暗像素（占游戏保留像素 2.29%）。
2. **描边外扩方向用的是 NORMAL，游戏用 TANGENT 通道里的硬法线**。手臂、裙子这类
   平滑过渡处描边会断。补法：读通道 2 → 八面体编码塞进空闲 UV 集 → `primvars:st2`
   → 着色器解码。
3. **描边缺深度偏移** `out.z -= 0.001 * lerp(_ZShift1000Min, _ZShift1000Max, T.z²)`，
   游戏用它救轮廓 z-fighting。
4. **描边宽度系数 0.0014 是量出来的**，不是从 `0.7 * k * _Outline` 推出来的
   （Unity 的 `_ProjectionParams` / `_ScreenParams` 无法完整复原）。
5. **几何修改器里 `normal()` 的空间未实测**，倾向 model-space；影响 `outlineVertex`
   的外推方向，转模型时可能看得见。
6. **geom shader 未覆盖的变体**：`_USEREFLECT_ON`、`MOSAIC_ON`、`_ISREDDISH_ON`。
   体检脚本会把出现过的报成 warn。
7. **HUD/眼睛高光以外的加法层**：`_FlashColor`、`_GuradeParams`、fog 等实测在默认
   值下恒等，但换舞台/换服装后是否仍恒等未验证。
8. **真机未验证**。所有像素实验都在 iOS 27 模拟器上；`ToneMappingComponent` 是
   iOS 27 的未文档化组件。
9. **部分语料的取景偏上**：052kao、046rio 等模型头被切在屏幕外，001har、007ior、
   014mir 正常。`basePosition.y = -center.y + extent * 0.62` 用的是包围盒中心，
   怀疑这些模型有离群顶点把 `center` 拉偏。未查。

2026-10-30 又修了两个：003mik 吊坠黑底（描边壳，`applyOutline` 的材质名判断失效）
和 052kao 纽扣花边（采样器 `clamp_to_edge` 吃掉平铺 UV）。根因与证据见本地
`research-alpha-and-cutout.md`（逐行引用反编译源码，不进仓库）。

## 2026-10-30 剩下 18 个角色解不出来的原因（已定位到通道表）

对比同一份代码下的两个网格，`m_VertexData.m_Channels` 不一样：

```
001har（能导）  (3,0,0,0) (3,0,12,0) (4,0,24,0) … (4,0,2,0) 权重  (4,11,2,16) 骨骼索引
006mak（导不出）(3,0,0,0) (3,0,12,0) (4,0,24,0) … (0,0,0,0) 权重缺失  (1,10,2,0) 索引
```

即这批网格 **通道 12（权重）是空的，通道 13（骨骼索引）是 dimension=1、format=10
（UInt32）**——一个 32 位里塞 4 个 8 位索引，权重可能被压在同一个 uint32 里，或者
存到了别处。我们现在的解码器假设"权重 4×float32 + 索引 4×SInt32"，所以：
先 KeyError(10)，补上 32 位格式后又变成 stride/offset 越界。

下一步要在 `unity_mesh.decode_channel` 里支持这种打包布局（解 4 个字节出来），
并确认权重到底在哪——如果确实缺失，说明这批模型不是常规蒙皮，需要另找数据源。
