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
