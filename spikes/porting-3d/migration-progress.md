# 3D 原生一致迁移进度（ADR-0033）

- 起始：2026-11-07
- 依据：[ADR-0033](../../docs/adr/0033-native-faithful-3d-migration.md)、[审计报告](audit-migration-2026-11-07.md)
- 目标：按原生类边界重写角色表现系统；只允许性能层等价替换，禁止行为自创。

## 数据与工具（已完成）

| 项 | 位置/命令 | 状态 |
| --- | --- | --- |
| 资产快照（版本锁定） | `~/mltd-work/assets/1078590/`（manifest 171,033 条、snapshot.json、sha256） | ✅ |
| 抓取工具 | `spikes/porting-3d/fetch_snapshot.py --version latest|<n> --names ...` | ✅ |
| 原始 imo 导出 | `spikes/porting-3d/export_imo.py`（`eidolon.imo/1`，一个 bundle 多资产 + optional） | ✅ |
| 原始动作样例 | `~/mltd-work/motion/`：`dan_loveig_01_dan.imo`（180 曲线）、`dan_amater_01_apg.opt.imo`（optional 2 条 HandToHand FCurve） | ✅ |
| 版本事实 | 当前 asset version **1078590** / indexName `4961f12f…data`；matsurihi API 可查最新 | ✅ |
| IDA 库 | `~/mltd-work/ida/UnityFramework.i64`（702,223 函数） | ✅ |
| gitignore | Unity `Assets/` 恢复入库 | ✅ |

## 批次状态

### B1 动作 + CalcBone

**CalcBone：完成并接入**（commit `91cf115f`）
- 新文件：`Assets/Scripts/CalcBoneNative.cs`（8 算法 + TITE + 节流，1097 行）、`Assets/Editor/CalcBoneProbe.cs`
- 关键结论：ROT 的 `initRefVec = referInitRot * Vector3.right`（axis 不参与）；`__rot` 首参为 z 时原生登记为 **SLERP(t=v, tx=1)**（HIJI/HIZAKOZO 半弯的真正机制）；TITE 第二参考骨字面量 `MOMO_L/MOMO_R`；TITE_FRONT_TRANS 计算值进 `localPosition.x`
- 运行态验收：`CalcBoneNative.Count = 30`；HIJI/HIZAKOZO 显示 `type=SLERP t=0.5 tx=1 axis=2`（与原生一致）；截图 `~/mltd-work/out/native-calcbone.png`；console 0 error

**动作播放：完成并接入**（commit 本批）
- 新文件：`CharacterImasMotionNative.cs`（imo 数据模型/8 种 key_type/`CreateFromImoAsset`/optional/多动作/循环/step_keys）、`NativeMotionDriver.cs`、`Assets/Editor/NativeMotionProbe.cs`
- 语义按原生：`SolveCurve` 0x37E80B8、`GetKey*` 0x37EC388/454/4A4/598、`UpdateTime` 0x37EDF1C、`SolveCurves` 0x37EE384、`SetResultToTransforms` 0x37EE99C、`CreateFromImoAsset` 0x37EC030、optional 0x37FE7B4；位置写入条件为「CurveSet 存在任一 Position 曲线」（审计旧说法已更正）
- 集成：`CharacterBootstrap.useNativeMotion=true` 时跳过旧 EULR、挂 `NativeMotionDriver`（默认 `$MLTD_WORK/motion/dan_loveig_01_dan.imo.imo.json`）
- 运行态验收：`IsLoaded=true`、57 个 CurveSet、`length=130.000s`、`PlaybackTime` 推进；Seek(0)/Seek(10) 姿态正常（`~/mltd-work/out/seek-0.png`、`seek-10.png`）；console 0 error
- 修正记录：`NativeMotionDriver.Time` 属性遮蔽 `UnityEngine.Time` 导致编译错误 → 已改名 `PlaybackTime`；`clip==null` 时 `Apply(0)` 的空引用已 guard
- 旧 EULR 路径保留为 `useNativeMotion=false` 的对照，B1 收尾时删除
- **数值对拍（新增）**：`CharacterImasMotionPlayer.SolveCurve` vs 已与原生核对过的 `motion.py::sample`（同一原始 imo）：
  - `MODEL_00/BODY_SCALE/BASE AngleX FullFrame`：t=0/10/65 → `-0.231814/6.594243/0.922939` vs `-0.231814/6.594186/0.922933`
  - `BASE AngleY FullFrame`：`-87.570790/-54.616330/-1169.992000` vs `-87.570786/-54.616329/-1169.992310`
  - `SAKOTSU_L AngleZ Discreate`：`-90.000000/-89.999980/-90.000460` vs `-90.000000/-89.999980/-90.000455`
  - `KOSHI AngleY Const`：完全一致
  - 结论：最大差 ~6e-5°（float/时间网格量级），通过
- 补充 C# 实测参考（motion-native 提供，可作后续回归）：BASE AngleX t=0/1/30 = -0.23181434/0.227893963/-2.56663084；SAKOTSU_R 链 AngleZ t=1.9/1.95 = -12.2118816/-24.5489388；optional HandToHand_RH t=0.2/0.5 = 0.285772562/0.961734176；POSITION PositionX t=0/1/30 = -0.00902702101/-0.0102410857/-0.105215162
- 已知未知：key_type 6 的段内分数原生未减 v0（按原生实现，语料不可观测）；idle 需要 common-skeleton 缓存（留钩子）；Create 用骨架 bind 初始化 results（移植零初始化，舞蹈数据不可观测）

### B2 Sway V01

**完成并接入**（commit `27d3d056`、`d5e002c4`）
- 新文件（全部按原生类边界）：`SwayNativeTypes.cs`、`SwayFileNative.cs`、`SwayManagerNative.cs`、`SwayBoneNative.cs`、`SwayColliderNative.cs`
- 已实现：`SwayBoneMT` 四个参数结构；`_sway` 严格解析（含 bridgetgt/clipPlane/planeRot/新格式字段）；body+head 合并 rig（`ImportCommon` 顺序）；`<joint>#n` 按关节查表；四趟顺序 + hitTwice；固定 1/60、dt≤0.025；SwayMove 全项（followRate/followSW/damper/transBack/antiFold/侧线/重力向量）；CalcRotate 钳位回写 cur/prevTip + HitMute；Plane/Bridge/胶囊/skirt barrier/side-line/culling；wing 限位过渡
- 运行态验收：`managers=3 bones=33 colliders=20`；ss003 裙骨 22 条引用全部解析到 `MOMO_L/MOMO_R#0`（不再绑 KOSHI 球）；头发 `KATA_L/R#0`、`KUBI#1/#2` 跨 bundle 全部 resolved；console 0 error；截图 `~/mltd-work/out/native-sway*.png`
- **数值验收（新增）**：裙骨尾点 vs 大腿胶囊最小间隙，接入初测最差 **-63.2 mm**（穿模）→ 定位到 `CapsuleHit` 传给 `hit_capsule_sphere` 的半径漏加 collider radius（原生 0x1C74500 第 146 行是 `collider.radius + bone.radius`；culling 与 skirt barrier 仍用 bone radius）→ 修正后最差 **-5.5 mm**（≈0，属角度窗/帧内残差量级）。`~/mltd-work/out/native-sway-fixed.png`
- 已知未知（21 处 `UNKNOWN(native 0x…)`，见 sway-native 汇报）：嵌套 manager 归属（当前“最深 manager 唯一更新”，需运行态/游戏对照确认）、wing 静态表、JointBodyHead 运行时数组（B5 接线）、`CheckSideLine` 调用点、BodyScale 兜底等

### B3 FaceCtrl —— 完成并接入
- 新文件：`TransitionModuleNative.cs`、`FaceCtrlNative.cs`、`FaceCtrlProbe.cs`
- 覆盖：Init/Init2、BlendParamLoad（native + 资产两种 schema）、SetFace(n,muteLip)/Direct、ConvLip/SetLip/SetLipDirect/SetSinging、SetEyeClose/Direct/GetEyeBuff、SetCheek/CheekUpdate/GetCheekValue/SetCheekValue（`_IsReddish`/`_ReddishIntensity` + `_ISREDDISH_ON` + CharacterDrawer 双回调）、UpdateFace 五段（BS0..13 嘴、BS14..31 眼）、Action 五模块
- **已知未知已解**：用运行时 `il2cpp_codegen_initialize_method` 反编译确认 metadata token 解码规则，解出 `facialMenu[28]`（通常…左ウィンク）与 `lipChar[60]`（52 非空/8 个 null）、ctor 路径 `/obj_head_GP/face`、shader 属性/keyword
- **28 个表情名（`facialMenu`，已解出，顺序即索引）**：通常/明るい/興味/安堵/照れる/微笑み/泣き笑い/困り笑い/真剣/不敵な笑い/企み/考える/きょとん/驚き/超驚き/呆れ/不機嫌/怒り/不安/哀しみ/泣き/痛い/拗ねる/嫌そう/つまらない/がっかり/右ウィンク/左ウィンク
- 运行态验收：`expressions=28 chars=61 cid=001har`、`facialMenu[0]=通常`、`facialMenu[27]=左ウィンク`、`lipChar[0]=ア`；SetFaceDirect(3,0)+SetCheekDirect(2) 生效（材质 `_IsReddish=1`、`_ReddishIntensity=0.2`）；console 0 error；截图 `~/mltd-work/out/native-b3.png`、`native-b3-face.png`
- 集成修补：spike 的 `facial_chara.json` 是 `cid/expressions` schema，原 BlendParamLoad 先按 native schema 解析会把 cid 吞成 null（JsonUtility 不拒绝未知字段）→ 已改为按 JSON 内容选择 schema
- 唯一 data-gap：`lipParam[11,14]` 是 global-metadata 的编译器数组初始化 blob（不在资产快照）；代码写全、默认全 0 跑通，`LoadLipParam` 可注入；默认状态不依赖它

### B4 EyeTracking + DropShadow —— 完成并接入
- 新文件：`EyeTrackingNative.cs`（EyeTrackParam/eyedirtype/EyeTracking 12 方法，含 Init/SetTarget/SetMaterials/SetTeary/EyeUpdate）、`DropShadowNative.cs`（DropShadow 13 方法：Shadow enum/SetShadowMode/InitShadowMode/InitPinSpotLight/SetVisible…）
- 接入（CharacterBootstrap.BindNativeB4）：眼睛 SMR 同名物体上挂 EyeTracking → `RefreshScreenRatio()` → `Init(new EyeTrackingIdolInfo())` → `SetMaterials(两个 eye 材质)` → `FaceCtrlNative.SetEyeTarget(EyeScaleSink 适配器)`；新增 `EyeTrackingDriver` 每帧 `EyeUpdate()`（原生由 JBH/Drawer 驱动），viewer 场景下 eyeTarget 跟随主相机；DropShadow 从快照 `chara_shadow.unity3d` 加载后 `SetShadowMode(CIRCLE, bundle)`
- 新增文件：`EyeTrackingDriver.cs`（每帧驱动，LateUpdate 顺序 50）、`Assets/Editor/EyeShadowProbe.cs`（Tools/Eidolon/B4 探针）、`Assets/Scripts/EyeFlickerProbe.cs`（视线角/eye base/相机逐帧采样器，用于跳动诊断）
- **视线跳动修复（2026-11-07 晚）**：用户报告“动的时候眼睛闪现式跳动”。逐帧采样发现 `rx` 460/600 帧卡在 ±30°、`ry` 全部卡在 +10°，并出现 3 次 **±60° 瞬间翻转**（`atan2` 过零）。根因：viewer 没有 `LiveInfoParams`/`DanceCameraManager` 舞台数据却用原生 `Front` 模式，且 `EyeTrackingIdolInfo` 传空（`info.eye=null` 使目标高度掉到 0.05，视线向下穿极限）。修复：把真实 `body/atama/mune2/eye` 节点传入 `EyeTrackingIdolInfo`；viewer 改用原生同样存在的 `FaceRelative` 模式（目标永远在眼睛局部前方，不会过零）。复测 600 帧：`rx=ry=0.0` 恒定、`jumps>1° = 0`，截图 `~/mltd-work/out/eye-fixed2.png`
- **黑眼/高光丢失修复（2026-11-07 晚）**：修复视线后用户报告眼睛全黑、无高光。定位为 `EyeTracking.screenRatioV` 在 Start 时按当时很小的 Game 视图算出 **(0.54, 0.48)**，`EyeUpdate` 每帧把眼睛主贴图 UV 缩到 0.54，虹膜/高光被采样出界 → 黑色。viewer 固定原生 1280×720 参考比例 **(1,1)**（原生在参考分辨率下的取值；spike 直接采样虹膜图集，不迁移 screen-space eye pass），并去掉按窗口尺寸刷新的做法；材质 ST 复测 `(1,1)/(0,0)`，高光恢复（`~/mltd-work/out/eye-fixed4.png`）
- **Editor 注意事项**：重启/重编译后需 `Application.runInBackground=true`（否则 Game 视图失焦时 `frameCount` 停在 1，看起来像暂停）；Game 视图窗口尺寸异常（被调成 2412×72）会连带把 `Screen` 比例弄坏，必要时关掉 Game 视图重开
- 运行态验收：`Initialized=true`、`UseEyeMaterials=true`、`shadowMode=CIRCLE`；截图 `~/mltd-work/out/native-b4.png`（脚下出现接地影）；console 0 error
- 编译修补（Lead）：`Mathf.Truncate` → `(float)System.Math.Truncate`
- data-gap：眼睛材质无 `_VfxTex`（泪目/vfx 滚动为空操作）；shadow 包只有 Mesh/Material/Texture、无 DropShadow 脚本（组件按反编译重建）；`_Irogae`/材质静态表 `sub_357E268` 未迁；舞台 `LiveInfoParams`/`DanceCameraManager` 输入缺失（`upCamPosDef/upCamTgtPosDef/frontDepthSign/camTgtPosProvider` 等 seam 已留，viewer 用主相机作为 eyeTarget）；`shadowScaleVectorOverride` 未定（默认按原生表达式，不编造）
- 探针：`EyeShadowProbe`（Describe/Bind/Cycle shadow mode）

### B5 CharacterDrawer / JointBodyHead / CharacterSoul —— 部分接入
- 新文件：`CharacterSoulNative.cs`（`CharacterSoul.Value<T>`/SoulDataCharacter/CharacterSoulTable，从快照 `chara_soul.unity3d` 读 61 角色）、`CharacterDrawerNative.cs`（角色相关子集：可见/描边/颜色/mono/rim/spotlight/cheek/eye highlight/z-shift/LOD/skin quality/子网格）、`JointBodyHeadNative.cs`（装配骨、SwaySwitch/SwayManagerAllON/skirt_GP_SwayManagerCtrl/SetWingLimit/MeasureSway/BindSwayRig/PushSwayRuntimeState）、`DrawerJbhProbe.cs`
- 运行态接入：CharacterBootstrap 依次挂 JBH（BindSwayRig）→ CharacterDrawer.Create → `FaceCtrlNative.SetCharacterDrawer`；CharacterSoul 的 `cheekReddenIntensity` 已用于 `face.cheekBaseIntensity`（001har=1.5）
- 运行态验收：6 个组件同时存在、console 0 error、截图 `~/mltd-work/out/native-b5.png`
- 编译修补（Lead）：Unity 6 的 `SkinnedMeshRenderer.skinQuality` 已改名 `.quality`（2 处）
- **仍未接**：JBH.Initialize 的完整装配/模型切换/眼镜/配件显示/翅膀限位、CharacterSoul 的 cheekReddenColor/bodyScale/breast sway 到材质与 Sway 的映射、CharacterDrawer 的 Live 绘制管线（明示 out-of-scope）

### 游戏内参考素材（已采集）

`~/mltd-work/ref/game/` + `manifest.json`（15 张 + 3 个未取得项）：
- 事务所/偶像选择/衣装选择/偶像详情页面截图
- 春日未来 白/浅蓝舞台礼服（疑似 ss003、未确认）站立正/侧/背、裙摆侧面、头发背面、头部特写（裁剪放大）
- 默认私服三视图
- **未取得**：舞蹈帧（需ライブ选曲消耗体力/下载，属不可逆账号状态，未操作）、腿弯曲姿势（主页 idle 无 pose 切换）、游戏内真变焦（PlayCover 单点触摸无法 pinch，特写是裁剪）
- 全程未抽卡/未付费/未改设置/未引继；游戏现留在ホーム（未来/私服）
- **自采对照图（同相机角度、原生管线）**：`~/mltd-work/out/native-ref-{front,side,back,face,skirt}.png`（驱动暂停在 Seek(0)、相机 OrbitCamera 参数固定）

## 验收与证据

| 项 | 位置 |
| --- | --- |
| 每批截图 | `~/mltd-work/out/native-*.png` |
| 游戏内参考截图（进行中） | `~/mltd-work/ref/game/`（已到事务所 3D 画面，正在试衣装/偶像详情） |
| IDA 反编译 | `~/mltd-work/ida-decomp/` |
| 原生/数据审计 | `audit-migration-2026-11-07.md`、`~/mltd-work/audit/` |

## 清理与最终运行态（2026-11-07 晚）

- 删除：`HelperBones.cs`、`SwayPhysics.cs`、`SwayRig.cs`、`SwayData.cs`、`SwaySolver.cs`、`EidolonMotionClip.cs`（+ .meta）、`Editor/SwayProbe.cs`（`SwayShot` 移到 `Editor/SwayShot.cs`）
- `CharacterBootstrap` 重写为纯原生管线；`PlayMotion` 的 scene.json 字段改为 motion/soul/shadow（旧 `clipPath` 忽略）
- 最终运行态：10 个原生组件同时在线（CalcBone/FaceCtrl/SwayRig/JBH/CharacterDrawer/EyeTracking/DropShadow/NativeMotionDriver 等），原生动作 `t` 推进、`loaded=true`，console **0 error**；截图 `~/mltd-work/out/native-*.png`
- 仍需补（非阻塞、已记 data-gap/known-unknown）：B5 的 JBH 完整 Initialize/模型切换/眼镜/配件显示/翅膀限位、CharacterSoul 颜色/bodyScale/breast sway 映射、CharacterDrawer 的 apply_color 与 Live 绘制管线；B4 的舞台相机/LiveInfo 输入与 `shadowScaleVectorOverride`

## Phase 0 验收 + sway 平移语义修复（2026-11-08 凌晨）

**用户点名的 Phase 0（Unity 内确认表情 + 换装重测）完成，全部通过：**

| 项 | 结果 |
|---|---|
| 28 表情全表 | 28/28 截图各不相同（`~/mltd-work/out/expr-sweep/`）；数值抽查 4 表情通道对位正确（微笑/驚き/怒り/右ウィンク） |
| 眨眼 | `SetEyeClose` 0.1s 过渡 → BS24/25=100，闭眼帧正确；"反转"假象查明为 player loop 冻结 + 探针死引用，非代码问题 |
| 换装 | ss001（红裙 SSR）：47 sway 骨/48 碰撞体全解析/30 辅助骨/28 表情/动作 loaded |
| 换动作 | s01yay（dan_s01yay_02_dan.imo）：57 curve sets/128.3s/POSITION 走位轨正常 |
| **胸部跳动修复（B-1）** | 根因=`CalcRotate` 非 limitAngle 分支缺 `localRotation=initial` 头部重置（原生 0x1C72220 两个分支都无条件重置）→ OPAI 每帧真实翻转 ~147°（\|dot\|=0.28）；修复后 **\|dot\|=0.99973/0.99997、翻转帧 0**；`sub_70C13F4` 语义由 wrapper 内嵌字符串钉死为 `InverseTransformDirection`（推翻 Lead 的 set_position/平移假设——那次实验把裙骨炸成尖刺，已回滚） |
| **裙穿模修复（同批 sway 修正）** | SwayMove 重力门控只看 lineHitF/skirtNormal 改当前旋转/CalcSideLineDistance 顺序/CalcAntiFoldForce 从 sideLink2 起/SwayHit 删除自创 line 测试（原生 0x1C75380 无静态调用点）；LF0 间隙 **-37mm→+70mm**，最差 RC0 -0.7mm（接触级） |
| 动画"闪现卡住" | `Time.maximumDeltaTime=0.33`→0.1（编辑器卡顿恢复后动作不再一跳 0.33s）；探测用 eval 本身会卡编辑器 0.3-1s（停止在用户观看时跑探针） |
| 游戏参考对照 | 用户提供的 ss001 游戏截图（站立/深蹲）与修复后渲染一致 |

新增工具：`FrontFollow`（朝向跟随相机，舞蹈转身不吞镜头）、`SwayJitterProbe`（四元数连续性采样）、POSITION 节点正式入 bootstrap。
偏差清点：`deviation-audit-2026-11-08.md`（B类11条：B-1 已修、B-2 灯/rim/眼高亮写材质、B-4 GetWind 门反向、B-5 载入立即落帧等；C类8块待反编译——IDA 库后台重建中）。


## 原生真值对比管线（2026-11-08，游戏内实时抓取）

**让游戏可被注入**：PlayCover 安装的 launcher 是 adhoc 签名且无 `get-task-allow`（frida/lldb 均被 taskgated 拒）。给 launcher 补 `get-task-allow` + `disable-library-validation` 后重启，Frida 注入可用。原签名备份在 `~/mltd-work/backup-app-sign/`。副作用：PlayCover 若在启动时重签会丢掉该权利，重新签名即可。

**重要发现（影响保真判断）**：游戏跑的是 **MT/Job 并行 sway**（`SwayBoneMT.SwayMove 0x1C6867C`）。托管 `SwayBone` 对象里只有**静态配置**（radius/limitAngle/初始旋转/碰撞体引用；31 万样本验证 tip/base 全程不变），实时状态在非托管 `WorkingParams` 与骨骼 `Transform` 上。所以抓真值必须读 Transform，不能读托管字段。

**管线**：
- 游戏侧：hook `SwayManager.LateUpdate 0x1C817F0` → 遍历 manager 骨骼数组（+0x50）→ 对每根骨调 `Transform.get_rotation/get_position`（il2cpp）→ 10Hz 记录；舞蹈时间取 `PlayerDance.UpdateTime 0x37EDF1C` 的 current_time(+0x44)。
- 移植侧：`Assets/Scripts/SwayBoneLog.cs` 记录同格式（世界旋转 + tip + base）。
- 对比工具：`spikes/porting-3d/tools/compare_game_vs_port.py`（先做平移不变的相对骨位匹配定身份，再逐骨比较世界旋转角度）。

**首次量化结果（キラメキラリ MV，春香/2 号位，全场 128s，20 根裙骨）**：
| 指标 | 数值 |
|---|---|
| 身份匹配（相对骨位中位偏差） | **0.9 mm**（时间偏移 +0.00s）|
| 裙骨世界旋转偏差 中位 | **1.73°** |
| p90 / p99 / max | 7.32° / 26.48° / 52.93° |
| 偏差尖峰窗口 | t≈79.8–84.3s、89.6s、94.8s、22.9–24.4s（全场 15–18° 均值） |

解读：**绝大多数时间我们的 sway 与原生高度一致**（中位 1.7°）；尖峰窗口偏差在整组 20 根骨上同时抬高 → 更像整体/根级或时序因素，而非单骨物理错误。下一步：在这些窗口内逐骨 dump（tip/prevTip/命中标志）与原生 MT 路径分支对照，确认是根骨/朝向差还是碰撞响应差。


### 23 秒穿模定位（2026-11-08 上午，原生真值）

游戏侧刚体/配置对齐结论：
- **bind 基准完全一致**：20 根裙骨的 `initialLocalRotation` 与游戏逐骨比对 中位 **0.00°**（max 1.19°）→ 取 bind 的姿态没问题
- **同一时刻的 solver 输出差异**（由游戏真实 `localRotation` 反解 `init⁻¹·local = Euler(0,yaw,pitch)`，与移植版同式）：

| 时刻 | 游戏 F0 yaw/pitch | 移植 pre-clamp yaw/pitch | 说明 |
|---|---|---|---|
| 22.0s | yaw -1.00 / pitch **-4.6°** | ~0 / +3° | 开始分化 |
| 22.5s | -1.00 / **+0.99°** | ~0 / +3° | 游戏恰好停在 maxZ 边界内侧 |
| **23.0s** | **+1.00 / -44.4°** | ~0 / **+3.0°** | 游戏裙板抬起 44°避让腿 |
| 24.0s | +1.00 / -47.6° | ~0 / +3° | 持续避让 |

- **穿模机理（已用数据闭环）**：正面裙板（skirt_F0/LA0/RA0…）的 `maxZAngle` 只有 **+1°**。移植版静止下垂角约 **+3°**，**每帧越过上限 → 钳制（clamped=1）每帧命中 → 原生钳制路径会把 `curTipPos` 重设为刚性偏移（`TransformPoint(tipLocal+colliderOffset)`）→ tip 被钉死 → follow/碰撞累积的位移每帧清零 → 裙板永久保持刚性下垂，腿一抬就穿过去**。游戏侧 pitch 走负方向（-4→-44°，限幅下界 -75°），不触发钳制，所以能自由抬起。
- **次级差异**：移植版静止下垂角 +3° vs 游戏 +1°（超出仅 2°）就足以落进钳制陷阱；需在 `SwayMove` 力链（gravity / stiffness / follow / damper / BodyScale 缩放）上找出这 ~2° 的来源。

下一步（明确）：逐项 dump 移植版 SwayMove 的力分量，与 `SwayBoneMT.SwayMove 0x1C6867C` 反编译逐项对照，定位重力/刚度/follow 的标度差；同时复核钳制重设 tip 的边界条件（原生只在“严格越界”时置标志，恰在边界不钳）。

### 23s 穿模：三线索排查进度（goal-f16105ed）

| 线索 | 结论 |
|---|---|
| gravity 标度 | **排除**。ss001 逐板 gravity 均为 `0,-0.0001,0`，移植运行时实测 `diag_grav = -0.0001` 完全一致（未被 BodyScale/默认值改动）|
| Live 侧 swayDamper / swayFollowRate | **待抓**。移植端为原生字段初值（damper 全 1.0、followRate 全 0、followSW 全 false）→ 走 followForce 回落；游戏内由 `IdolPositionMgr` 填充，MV 播放时是否非默认未知 → **需游戏侧抓取确认** |
| followForce 施加量级 | 待比对（实测 0.002–0.025 m/帧；需与原生同刻对照）|


### 23s 穿模：实现路径排查（goal-f16105ed，回合 11-14）

**关键实测（MV 播放中，Frida 计数）**：
| 函数 | 命中 |
|---|---|
| `Imas.BoneLib.SwayManager.PrepareUpdate 0x1C81A08`（Ver01） | **8857 ✓ 在跑** |
| `Ver01.ExecuteUpdate 0x1C81CD8` / `PostUpdate 0x1C81E40` | **0** |
| `SwayBone.CalcRotate 0x1C72220` / `SwayMove 0x1C72964` / `SwayHit 0x1C732E8` | **0** |
| `SwayVer02.Execute 0x1C8EE48` / `ExecuteChains` / `CalcFollowMatrix` / `CalcRestoration` / `CalcAngleLimitPenetrative` | **0** |
| `SwayCtrlMT.InitializeParallelSway 0x1C6FC28` | **0** |

**离线调用图（ARM64 BL 扫描，无 IDA）**：
- `SwayCtrlAllMT.ExecuteParallelSwayIdols 0x1C6CBD4` ← 由 `0x1C6DC14` 调用
- `SwayBoneMT.CalcRotate 0x1C69F04` ← 由 `0x1C70A68` 调用（Job 内）
- `SwayBoneMT.SwayMove 0x1C6867C` ← 由 `0x1C705A4` 调用（Job 内）
- `Ver01.LateUpdate 0x1C817F0` 的 BL 目标含 `0x1C81A08/0x1C81CD8/0x1C81E40`（串行三连），但运行期只命中第一个 → 说明后续调用是**虚调用/接口分派**，未走串行分支

**★ 已确认（MV 播放实测）**：`SwayCtrlAllMT.ExecuteParallelSwayIdols 0x1C6CBD4` 命中 **600 次/10s**，同时 `V01_PrepareUpdate` 命中 10200 次，而 **Ver01 串行求解与 Ver02 全部为 0**。

→ **游戏运行时走的是 MT 并行（Job）路径，不是我们移植的串行路径。** 我们实现了同一套数学，但执行结构不同：MT 把每骨固定参数/工作参数放进 NativeArray，由 Job 批量求解并写回 TransformAccess；其中 `WorkingParams` 的 limit 目标插值（±4°/帧）、`forceUpdate` 分帧更新等机制只存在于 MT 节奏里。这正是"参数都对、结果却差 -44° vs +4°"的原因。

**原结论（保留）**：游戏裙骨旋转确为物理驱动（关掉我们的 sway 后裙骨局部旋转恒为 -7.66°，而游戏同刻 -44°），但**运行期只有 Ver01 的 PrepareUpdate 在跑**，真正的求解入口尚未观测到 —— 候选为 MT 并行驱动 `ExecuteParallelSwayIdols`（其 Job 会调 MT_SwayMove/MT_CalcRotate）。若是，则**当前 Ver01 串行移植不是游戏的运行路径**，需按 MT 语义校正。

**判定工具**：`spikes/porting-3d/tools/probe_sway_path.js`（16 个入口一次问清）。


### #129 实现前置实验（2026-11-08 午）

在开始 MT 重写前先验证了 spec 的实现决策 1「钳制不再重设 tip」，结果**无效**，已回滚：

| 实验 | F0 @23s pitch | clamped |
|---|---|---|
| 基线 | +4.30° | 9/9 |
| 去掉钳制时的 tip 重设 | +4.09° | 9/9 |
| 限位插值推广到全部骨 | +4.23° | 9/9 |
| damper 1.0→0.85 | +4.43° | 9/9 |
| follow 倍率 1→3 | +4.25° | 9/9 |

**新事实**：imo 动画共 180 条 curve set，**没有任何 skirt 曲线** → 裙子完全由物理驱动（不是动画驱动）。
**新工具**：`SwayCtrlMT..ctor 0x1C6DE90` 可在角色加载时捕获控制器实例，从而读取 `swayBoneWorkingParamsArray@88`（游戏真实逐骨 tip）、`swayDamperArray@264`、`swayFollowRateArray@296`；抓取脚本 `/tmp/ctrl_ground.js`（需 MV 播放期间运行）。

**结论**：MT 重写前应先取到游戏的真实 tip 轨迹（WorkingParams），否则无法判断差异发生在积分、碰撞还是限位阶段。


### 游戏真值抓取打通（2026-11-08 午，#129 实现期）

**已打通**：`SwayCtrlMT.ResetParallelState 0x1C6CFD0` 每帧被调用（2884 次/14s），用它捕获控制器实例即可读取 MT 的运行时数组：

- `swayBoneWorkingParamsArray@88`（NativeArray：buffer@+0、length@+8；元素 88 字节，**tip 在元素内 +52**，已验证数值合理）
- `swayDamperArray@264`、`swayFollowSWArray@280`、`swayFollowRateArray@296`

**已确认**：`damper[0] = 1.0`、`followRate[0] = 0` → **Live 表就是默认值**，"Live 表非默认导致差异"的假设正式排除（第三条线索结案）。

**已录得**：`~/mltd-work/out/game-tips.csv`（45 骨 × 130s，10Hz，含舞蹈时间）、`~/mltd-work/out/unity-full.csv`（我们 20 根裙骨，全曲）。

**遇到的问题**：捕获到的控制器属于**其他偶像**（45 骨，与我们的 47 骨/20 裙骨模型不匹配；去平移后最小残差仍有 ~837mm）。需要对每个 `SwayCtrlMT` 实例读 `parallelSwbs` 里 `SwayBoneMT.sb → SwayBone.trs` 的 Transform 名字，挑出春香 ss001 那个控制器。

**下一步（下一轮）**：多实例枚举 + 骨名识别 → 取春香控制器 tip 轨迹 → 与我方同刻 tip 对比，判定差异发生在积分/碰撞/限位哪一阶段，再动手写 MT 等价实现。


### ★ 全曲偏差形态分析（决定修复方向，2026-11-08 午）

用春香控制器（mgr 0x14b889300）的全曲局部旋转 vs 我们的全曲记录，逐时刻算 pitch 差：

| 骨 | 全曲中位 | 每 10s 平均 |Δpitch| |
|---|---|---|---|
| b1 (skirt_F0) | **-0.17°** | 0s:2.8 / 10s:6.2 / **20s:14.2** / 30s:1.6 / 40s:1.9 / 50s:5.5 / 其余 ≤3.5 |
| b11 (skirt_RA0) | **-0.25°** | 0s:3.3 / 10s:5.9 / **20s:15.5** / 30s:1.7 / 40s:2.4 / 50s:5.2 / 其余 ≤2.7 |

**结论**：我们的求解器与游戏**在绝大部分时间几乎完全一致**（中位 0.2°），偏差是**局部事件性的**，集中在 **20–30 秒**这一段的少数帧（峰值 48–50°）。

**这推翻了 #129 的结构性重写前提**：如果串行/MT 的执行结构真有系统差异，偏差应该遍布全曲而不是只在一段。真正的问题是这一段落里某个**具体事件**处理不同。

进一步看偏差帧的本地状态（我们的诊断）：
- 偏差 >10° 的帧全部 `clamped=1`、`sphereHit=1`、且 `|tip-base|` 恰好等于刚性长度 **0.269**（= tip 每帧被重设回刚性偏移）
- 说明主导差异的是**碰撞推离方向**：我们的 tip 在大腿胶囊**下方**被推向更下（pitch +4 → 越 maxZ=+1 → 钳制），游戏在同刻被推到 -44°（在 [-75,+1] 内，不触发钳制）

**下一步**：读游戏 MT 的 `swayColliderParamsArray@168`（碰撞体世界参数数组），与我们 `m_w_center/m_w_dir` 同刻对比——验证是不是我们的碰撞体世界几何算错（导致 tip 落在胶囊错误一侧）。


### 自动化抓取 + 春香控制器锁定（2026-11-08 下午）

**测试游戏播放已自动化**（不再需要人工播 MV）：
- 点击「本番」屏幕坐标 `(1235,1033)` → 单位确认页「MV再生」`(1172,937)`
- 工具：`/tmp/click`（CGEvent 单击，Swift 编译版）、窗口坐标 = 窗口原点(75,283) + 截图px/2

**多控制器抓取**（`/tmp/cap_multi.js`）：hook `SwayCtrlMT.ResetParallelState 0x1C6CFD0` 收集**所有**控制器实例，每 200ms 记录每个控制器的 45 根骨 tip（WorkingParams +52），整首歌 0→128.3s，111,932 行。

**结果**：MV 里共 4 个控制器。用速度互相关匹配我们的裙骨，**ctrl[1] 的 corr=0.82 为春香**，且索引映射干净：
> 我们的 b0..b19 ↔ 游戏 ctrl[1] 的 idx 2..21（`idx = b + 2`），去平移残差 21–30mm

**tip 偏差时间序列**（20 根裙骨平均，mm）：
| 时段 | 0-10 | 10-20 | 20-30 | 30-40 | 40-50 | 50-60 | 60-70 | 70-80 | 80-90 | 90-100 | 100+ |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 平均 Δtip | 45.5 | 72.0 | 54.5 | 27.9 | 44.6 | 46.7 | 29.4 | 29.0 | **79.1** | 29.5 | 29-33 |

- 基线 ~25–30mm（映射噪声），**spike 到 100–300mm**（最大 314mm @ t=10.7s）
- 不存在"只有 20–30 秒异常"的简单结论：tip 偏差是**广泛存在**的，而 **pitch（旋转）偏差**只在 20–30 秒显著 → 说明多数时候 tip 差异不改变骨骼转向（长度差异），但某些时段会改变方向

**下一步**：抓 `swayColliderParamsArray@168`（碰撞体世界参数），与我们的 `m_w_center/m_w_dir` 对比，确认碰撞体几何是否一致；并对照"碰撞被越过"的具体时段（用户观察：23s 及后续若干片段）。


### ★★ 分歧点精确定位：t=22.60s / 22.80s 两次碰撞推离（2026-11-08）

用游戏 `WorkingParams`（force/tip/base）与我们的逐帧对比（b1 ↔ ctrl[1] idx3，base 轨迹残差 17mm）：

**t=21.0–22.55s：完全一致**
- 力向量差 <1%（如 t=22.5 游戏 (+0.00409,-0.01029,+0.00412) vs 我们 (-0.00026,-0.01029,+0.00413)）
- tip 方向 dirY 差 <0.06

**t=22.60s 与 22.80s：游戏发生两次方向跳变，我们完全没动**
- t=22.55→22.60：游戏 dirY -0.929 → **-0.702**（跳变 +0.23）；我们 -0.938 → -0.936
- t=22.75→22.80：游戏 -0.702 → **-0.321**（再跳 +0.38）；我们 -0.919 → -0.914
- 之后到 t=25s 游戏稳定在 -0.32~-0.55（裙板抬起），我们始终 -0.9（垂着）

**长度一致**：`|tip−base|` 双方都是 **0.2694**（21 根骨中位：游戏 0.2710 / 我们 0.2711）→ 不是长度问题，是**方向没被推动**。

**碰撞体世界几何一致**：游戏 ctrl[1] 在 t=23 的碰撞体
`idx0 center=(-1.506,0.56,-0.073) r=0.07 scale=1.0` / `idx1 center=(-1.731,0.434,-0.004) r=0.07 scale=1.0`
vs 我们记录的 `col0=(-1.730,0.429,-0.004) r=0.070` / `col1=(-1.510,0.558,-0.072) r=0.070` → **差 1–5mm，几何正确**。

**新发现**：游戏运行时每个碰撞体的 `useSkirtBarrier`（`ColliderParams@0x64`）= **1**，而 `_sway` 文件里**完全没有该字段**（我们的解析器默认 false）。
实验：把默认值改为 true → F0 pitch 4.30→4.27°、clamped 仍 9/9 → **单独打开挡板无效**（可能还依赖 `skirtNormal/skirtDir` 的具体值或触发条件），已回滚。

**结论**：分歧精确发生在 22.60/22.80 两次"硬推离"上，我们的推离量级远小于游戏（我们 ~2cm，游戏等效 13°/22° 的方向跳变）。下一步：给我们的 `SwayColliderNative` 挡板/推离分支加计数器与推离量级日志，确认挡板是否真的触发、以及 `newpos` 深度为何远小于游戏。


### ★★★ 23 秒穿模已修复：裙摆挡板（SkirtBarrier）默认开启（2026-11-08）

**根因**：ss001 的 `_sway` 文件里**根本没有 `useSkirtBarrier` 字段**，我们的解析器按 `false` 处理；而原生运行时该值为 **1**（通过读游戏 `SwayCtrlMT.swayColliderParamsArray` 元素 `+0x64` 逐碰撞体验证）。

挡板的作用：在胶囊碰撞之前，把面板沿"裙面法线"推出平面（`d = dot(normal, tip-center) - radius - radius*skirtGuardOffset`），这正是"腿抬起来时裙板让开"的机制。关掉它就等于让大腿直接顶穿面板。

**修复**：`useSkirtBarrier` 默认 `true`（字段缺失时与原生一致）。

**验证（与游戏春香控制器逐时刻对比）**：
| 指标 | 修复前 | 修复后 |
|---|---|---|
| b1 全曲 \|Δpitch\| 中位 | 1.40° | **1.08°** |
| b1 p90 | 6.96° | **4.29°** |
| b1 max | **48.5°** | **18.8°** |
| b11 全曲中位 / max | 1.30° / **50.6°** | **1.21°** / **14.9°** |
| **t=23.0s b1 pitch** | **+4.3°（穿模）** | **-47.5°（游戏 -44.4°）** |
| t=23.0s b11 pitch | +4.3° | **-44.4°（游戏 -44.5°）** |

截图 `~/mltd-work/out/fix23.png`：23 秒处裙板完整覆盖大腿，间隙计显示 -0.6cm（接触级，非穿透）。

**仍存在**：全曲还有 284 个采样点偏差 >10°（占 2.2%），集中在 t=10–20s（64）、20–30s（52）、**80–90s（94）**；与用户观察的"23 秒和后面有些片段"吻合，说明还有第二个机制待查。


### 挡板修复后的全曲穿模验收（2026-11-08 下午）

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 最差裙骨间隙 | **-10.6cm** | **-5.3cm** |
| clear < -8cm 帧 | 189 帧（0.25%） | **0 帧** |
| clear < -5cm 帧 | 1139 帧（1.49%） | **2 帧（0.05%）** |
| clear < -3cm 帧 | 4.64% | 5.12% |
| 剩余 -5cm 时刻 | — | t=22.56s、53.91s（各 1 帧，接触级瞬态） |

**结论**：肉眼级穿模（>-8cm 等级的深穿透）已归零；最差从 -10.6cm 收敛到 -5.3cm，只剩 2 帧接触级瞬态。

**剩余 pitch 偏差**：80–90s 的链端骨（B0/LG0/LH0/LI0/RG0/RH0/RI0）仍有 20–27° 的 pitch 差（纯 pitch，yaw 差 ~0），但这些偏差**不再导致穿透**（该时段无 <-5cm 帧）。属于次级保真度问题，可后续处理。


### 剩余偏差的归属：动画层（root/skeleton），不是 sway（2026-11-08）

对 80–90 秒剩余 pitch 偏差（链端骨 20–27°）做分解：

| 检查项 | 结果 |
|---|---|
| 力向量（游戏 vs 我们，t=88s） | 差 1–1.5%（如 b18 游戏 -0.01669 / 我们 -0.01692）|
| `|tip−base|` 长度 | 双方逐骨完全相等（0.2532–0.2745）|
| **`base` 位置（骨骼基点）** | **差 85–103mm**（b1 在 23s 时仅 17mm）|
| 裙骨质心差（=整体舞台偏移） | 全曲恒为 **~222mm 常数**（编队位置差，非漂移）|

**结论**：80–90 秒的 pitch 偏差来自**动画层（蒙皮骨架位置）差异**，不是 sway 物理——因为力与长度都对，只有 base 位置不同，进而改变了重力/惯性相对方向。

全曲 base 相对偏差分布（已扣除常数舞台偏移）：多数时段 20–40mm，尖峰 200mm+ 集中在 10–20s、40–60s、**80–90s**，与 pitch 尖峰时段一致。

→ 这是 **Motion（imo 播放）层面的保真度问题**，与 #129 的 sway 议题不同源，应另开议题跟踪。


### #130 第一轮：偏差是"整体刚性旋转"，根节点已排除（2026-11-08）

**观测**：88s 处对 20 根裙骨做刚体拟合（Kabsch，用 b0/b10/b19 构基）：
- 相对游戏为**整体旋转 10.3° + 平移 (106,39,103)mm**
- **拟合残差中位 0.1mm、最大 0.2mm** → 整套裙骨确实是"被整体转了一下"，不是单骨各异

随时间变化：23s 0.1°、40s 44.7°、80s 26.0°、88s 10.3°、95s 18.1° → 是**动画驱动的**，不是固定编队偏移。

**已排除**：
- **根节点 `MODEL_00`**：直接读游戏侧 `MODEL_00` 的 Transform 四元数 → **恒为单位四元数（无旋转）**，与我们一致
- **`BASE` 应用**：我们运行时 `BASE.localRotation` = (-4.091, -22.665, 3.208)，imo 数据同刻为 (-4.109, -22.043, 3.026) → 差 <0.6°，应用正确
- **力/长度/命中**：力差 1.5%、`|tip−base|` 完全一致、sphereHit 标志与游戏逐帧一致

**因此**：差异在 `BASE` 与裙骨之间（`BODY_SCALE`/`KOSHI` 或骨骼层级映射），或来自我拟合时的构基误差。下一步：给游戏侧根链抓取**加上舞蹈时间戳**，直接比对同刻 `BASE` 四元数，避免偏移猜测。


### #130 第二轮：定位到 `BASE` 层（2026-11-08）

给游戏侧根链抓取加上**舞蹈时间戳**后，逐层与 imo 的 `BASE` 角度四元数同刻比对：

| 层（从 manager 向上） | 与 imo BASE 中位差 | 推断 |
|---|---|---|
| 0 | 89.7° | skirt_GP |
| 1 | 93.6° | KOSHI（AngleZ=90° 常数，符合）|
| **2** | **12.29°** | **BASE** ← 目标 |
| 3/4/5 | 86.2–86.7° | MODEL_00 / holder / root（无旋转）|

**关键**：游戏侧 `BASE` 的世界四元数与 imo 原始角度差 **12.29°**；而我们移植版的 `BASE` 与 imo 差 <0.6°。

→ 说明差异**就在 BASE 这一层**。下一步必须区分两种可能：
1. 游戏对 BASE 做了额外处理（如 Live 层再乘一个旋转）
2. 我们抓的是 `get_rotation`（世界旋转），层2 可能不是 BASE；需要用 **`get_localRotation`** 复核

**下一轮**：抓 `BASE` 的 **localRotation**（不是 world），与 imo 同刻比对，直接判定游戏是否"改写"了 BASE。


### #130 第三轮：BASE 精确抓取成功，但对比口径需修正（2026-11-08）

**抓取方式升级**：不再靠"链路层序猜测"，直接从 `SwayManager` 字段取 Transform：
- `BaseTr @0x70`、`BodyScale @0x68`
- 实测：`BASE` 的 world == local（父链无旋转）、`BodyScale` 世界旋转 = 单位四元数 → **父链正常**

**当前口径的问题**：把游戏 `BASE.localRotation`（Unity 四元数）与"imo 的 AngleX/Y/Z 用 ZXY 顺序重建的四元数"相比，得到中位 11.76°、p90 53.98°、max 170°。但 imo 的角度是**多圈累加值**（如 AngleY = -450°、-1535°），Euler→四元数重建对顺序/取模敏感，**这个对比口径不可靠**。

**下一轮改用同构口径**（消除换算不确定性）：
1. 记录**我们运行时 `BASE` 的四元数序列**（带 PlaybackTime，全曲）
2. 与游戏的 `BASE` 四元数序列（已抓到 `game-base.csv`，433 样本）**直接比较四元数夹角**
3. 若差异呈"随时间增大"→ 说明是**播放时间轴漂移**（我们 `time += deltaTime` 累积 vs 游戏时钟）；若随机跳变 → 是角度应用/插值问题

数据：`~/mltd-work/out/game-base.csv`（baseName/baseWorld/baseLocal/pos，带舞蹈时间）


### #130 第四轮：同构口径对比结果——我们正确，游戏在 imo 之外多转一层（2026-11-08）

改用**同构四元数直接对比**（都取 Unity localRotation，无 Euler 重建误差）：

| 对比 | 中位 | p90 | 最大 |
|---|---|---|---|
| **我们 `BASE` vs imo 原始角度**（同刻） | **0.28°** | 1.04° | 5.42° |
| **游戏 `BASE` vs imo 原始角度**（同刻） | **11.76°** | 53.98° | 170.25° |
| 我们 `BASE` vs 游戏 `BASE`（同刻） | 11.64° | — | 170.25° |

**结论**：
- 我们的动画应用是**忠实**的（0.28°）
- **游戏在 imo 之外对 BASE 又施加了一层旋转**（约 8–12° 常态，高角速度时因采样错位放大到 50°+）

已排除的解释：
- 不是时间偏移（±0.4s 扫描，0 最优）
- 不是 Euler 轴序问题（6 种轴序测试，(1,0,2)/(1,2,0) 最好，仅 11.7°）
- 高/低角速度分组：低角速度组仍有 **8.61°** 中位差 → 存在真实差异，不只是采样抖动

**下一步**：找出游戏对 BASE 的额外旋转来源。候选：
1. MV/舞台侧的"朝向修正"（每个偶像朝舞台中心微调）
2. `SwayManager.BaseTr` 指向的节点与我们的 BASE 不是同一个（位置吻合但可能层级不同）
3. Live 侧的 `IdolPositionMgr` 追加旋转


### #130 第五轮：写入者定位到动画播放器；排除速率/编队偏移（2026-11-08）

**hook `Transform.set_localRotation 0x70BF458`，过滤 BASE 指针在 MV 中的写入者**：

```
0x37EEAA4 → 0x1EDD3A4 → 0x1EDD2DC → 0x1F36D9C → 0x1DFCAF8 → 0x8D9178
```

`0x1EDD2DC/0x1EDD3A4` 位于 **DanceMotionPlayer** 区域（`0x1EDD228 = DMP.Execute`）→ **BASE 由动画播放器写入，没有额外系统改写**。

**已排除的解释**：
| 假设 | 结果 |
|---|---|
| key 速率不是 60fps | 24/30/60/120 全测，**60 最好**（11.76°），排除 |
| 编队固定偏移（常数 yaw） | 相对旋转均值仅 4.5°，但**各时刻偏离均值中位 11.87°、p90 54.7°** → 不是常数 |
| 随移动方向转向 | Δyaw 与 POSITION 轨迹移动方向无明显相关 |

**当前结论**：游戏 `BASE` 的世界旋转 = 由动画播放器写入，但与 imo 原始角度存在 **时间上剧烈变化的差异**（-12°~+40°）。我们的播放与 imo 一致（0.28°）。

**下一步**：反编译写入链 `0x1EDD2DC` 附近的 SetResultToTransforms，确认它是否对 BASE 做了额外处理（例如 root motion 提取/朝向重定向/混合）。


### #130 第六轮：⚠️ 前一轮结论被推翻——比较的节点可能不对（2026-11-08）

对上轮"游戏 BASE 比 imo 多转 11.76°"做交叉校验：比较**双方 BASE 的世界位置**：

| t | 我们 BASE 世界坐标 | 游戏 BaseTr 世界坐标 | 距离 |
|---|---|---|---|
| 0 | (1.24, 0.82, 0.04) | (-0.11, 0.75, 0.40) | **1402mm** |
| 20 | (-1.96, 0.79, 0.05) | (-0.23, 0.66, 0.48) | **1789mm** |
| 50 | (-0.37, 0.78, -0.83) | (0.96, 0.67, 1.14) | **2379mm** |

**位置差 1.2–2.4 米** → 我们比较的**大概率不是同一个节点**（或不是同一个角色的同一编队位）。

这意味着上轮"游戏 BASE 在 imo 之外多转 11.76°"的结论**不可靠**——可能只是把两个不同节点的旋转拿来比了。

**因此必须先解决"节点/角色配对"问题**：
1. 确认游戏 `SwayManager.BaseTr@0x70` 到底指向哪个节点（用它的**父节点名/层级路径**，不是猜）
2. 确认我们实测的 `BASE` 与游戏 `BaseTr` 属于同一角色（编队位一致）——裙骨质心差 222mm 与这里 1.4m 不一致，说明两次比较用的对象不同

**教训（对应 goal 要求）**：先验证"比较对象是同一个东西"，再下结论。这一步没做就做后续分析，正是 #129 早期走弯路的模式。


### #130 第七轮：节点配对修正 + 身份仍未验证（2026-11-08）

**修正**：之前用"另一路抓取的裙骨"做参照导致 1.35m 偏差。改为**从同一个 SwayManager 同时取 BaseTr 与 swayBones**：
- 我们 BASE 相对裙骨质心偏移（中位）：(-0.003, -0.100, -0.015)
- 游戏 BaseTr 相对裙骨质心偏移（中位）：(0.002, -0.107, -0.001)
- **两者差 21.1mm** → **确认是同一层级位置的节点**（姿势差异量级）

**但** BASE 四元数差仍为 **中位 11.27°、p90 59.20°、max 171.26°**（n=432）。

**当前最大不确定**：抓到的这个 20 骨管理器**是不是春香**。尝试读 `SwayManager.fileName@0xE0` 失败（437 个样本全为空 → 该字段运行时为空或字符串读取失败）。il2cpp 的 `get_name` 此前也返回空，说明**字符串读取通道有系统性问题**，需要先修好它才能确认身份。

**下一步**：
1. 修 il2cpp 字符串读取（打印返回指针的原始字节，确认 Il2CppString 布局/调用是否成功）
2. 用修好的通道读管理器/骨骼名 → 确认是 ss001(春香)
3. 只有身份确认后，BASE 四元数差异才可解读


### 工具修复：IDA 库损坏与重建（2026-11-08 下午）

**症状**：`idapro.open_database(..., False)` 返回 `rc=4`，IDA CLI 日志给出真实原因：

```
Database is empty -> OK
Database initialization failed with error 4
Open database failed with result: 4
```

→ 不是 Python 环境问题（那个早已解决），而是**这个 2.0GB 的 `.i64` 文件本身不可读**。最可能是此前为了清理锁，`kill -9` 掉仍持有该库的 IDA 进程，导致保存不完整。

**处理**：旧库改名 `uf-empty-broken.i64` 保留，后台重新从 `UnityFramework` Mach-O 建库（`open_database(..., True)` + `auto_wait` + `close_database`，约 30 分钟），日志 `/tmp/ida-rebuild3.log`。

**教训**：对 IDA 库所在进程**不要用 kill -9**；应先 `close_database()` 或等待其自然退出。


### #130 第八轮：身份判定的可行路径（2026-11-08）

**问题**：MV 里有 17 个 SwayManager（5 个角色），必须确定哪个是春香 ss001，否则 BASE 对比无意义。

**尝试过的判据**：
| 判据 | 结果 |
|---|---|
| `SwayManager.fileName@0xE0` | 437 样本全空 → 字段运行时为空 |
| il2cpp `get_name`（Object/Transform） | 返回空 → 字符串通道有问题 |
| 祖先链指针分组 | 各管理器挂点不同，分组碎裂 |
| `BaseTr` 世界坐标聚类 | **全部在角色本地坐标 (0, 0.85, 0)，无法区分** |

**可行路径**：同时录制**全部 17 个管理器**的 `BaseTr` 旋转序列，与我们（已确认与 imo 一致，0.28°）逐一比对，**匹配最好的即春香**。这一箭双雕：既定身份，又拿到正确的 BASE 对照。

**工具**：`/tmp/cap_allbase.js` + `/tmp/cap_allbase.py`（每 400ms 采样全部管理器的 bones 数与 BASE 四元数）。
**注意**：游戏窗口会被误点成小窗（124×129），导致点击落空——跑自动化前需先 `osascript ... set frontmost` 恢复主窗口（1330×859）。


### #130 第九轮：身份确认成功，结论反转——动画层差异可能是"拿错角色"的假象（2026-11-08）

**身份确认**：同时录全部 17 个管理器的 `BaseTr` 旋转，与我们的 BASE 序列比对：

| 管理器 | 骨数 | 与我们 BASE 中位差 |
|---|---|---|
| 0x14c1ff600 | **17** | **1.03°** |
| 0x14c1ff800 | **8** | **1.03°** |
| 0x14c1ff900 | **20** | **1.03°** |
| 0x14c1ffa00 | **2** | **1.03°** |
| 其它 13 个 | 15/14/19/5/4/… | 10.29° 或更差 |

**骨数签名 {17, 8, 20, 2} 完全匹配我们的模型**（HAIR 17 / 丝带 8 / 裙 20 / 根 2）→ 这 4 个管理器就是春香，且其 BASE 与我们差 **仅 1.03°**。

**结论反转**：
- 之前"游戏 BASE 比 imo 多转 11.76°" → 那是**别的偶像**的管理器（第一个 20 骨管理器 0x14d7a2000）
- 因此 **"动画层有 11° 差异"的结论不成立**；`#130` 的前提（base 差 85–103mm）也来自同一个错误角色对照，可能同样不成立
- 之前"裙摆抬得比游戏多 282 个样本"的统计也基于 ctrl[1]，**需要重做**

**下一步**：用**已确认的春香管理器**重新采集裙骨数据（世界位置 + 局部旋转），重做 pitch/位置对比，判断"飘起"是否真实存在。
**工具坑**：本轮自动化点击失败（MV 未启动），已确认窗口坐标正确，需在点击前截图确认状态。


### ★★ #130 结论：前提不成立——动画层实际是忠实的（2026-11-08）

用**确认身份的春香管理器**（`0x14c1ff900`，BASE 与我们差 0.90°）重新测量全曲：

| 指标 | 之前（错角色） | 现在（春香，正确） |
|---|---|---|
| 骨架基点位置差 中位 | 85–103mm | **6.3mm**（p90 28.4mm）|
| 骨架局部旋转差 中位 | 11.76° | **1.77°**（p90 5.89°）|
| 裙骨 pitch 差 中位 | 14–15°（20–30s 段）| **1.56°**（p90 7.29°）|
| 每 10s 分桶 pitch 均值 | 最高 +15° | **+0.07 ~ +2.50°** |

**逐骨局部旋转差中位 0.84–2.50°**，无系统性错位；偏差 >10° 的样本 6.2%，且极端值集中在单一骨的个别帧（骨骼接近 180° 退化时的数值噪声）。

**结论**：`#130` 的前提（骨架 base 差 85–103mm、裙摆普遍飘起）**是错误角色对比造成的假象**。动画层（imo 播放）实际上是忠实的，**没有需要修的动画层缺陷**。

**方法论教训**：跨进程比对必须先验证"对象身份"（本 issue 用骨数签名 {17,8,20,2} + BASE 序列匹配确认为春香）。此前多轮结论（11.76°、85–103mm、282 个过度抬升样本）全部作废。

## Spec 收口（#126）

原生一致重写的收口 spec 已发布：JackLin513/eidolon-sc-ios#126（「B5 深水区：lipParam/材质写色/JBH 装配」）——三个原子件、验收口径与运行经验清单都在里面；本轮已完成其中的 `FaceLipParamNative`（见上文 lipParam 恢复记录），其余两个（CharacterMaterialsNative/JointBodyHeadAssemblyNative）按 spec 里的反编译证据落地。

## 下一步

1. 收 `motion-native` 交付 → 集成 `NativeMotionDriver` → 数值对拍（C# vs motion.py/原生公式）→ 截图 → commit（B1 完成）
2. 收 B3/B4 交付 → 按序集成与验收
3. B2/B1 收尾：删除旧近似组件（SwayPhysics/SwayRig/SwayData/SwaySolver、HelperBones、EidolonMotionClip 旧 EULR 路径），探针迁移
4. 游戏内参考补齐（站立/舞蹈/脸/裙摆/头发），做视觉对照
5. 每批更新本文件与 handoff

## lipParam 恢复记录（2026-11-07 晚，B3 data-gap 闭环）

`FaceCtrl.lipParam`（`float[11,14]`，字段 0x10）曾是三个 data-gap 之一。IDA 9.5 idalib 当前启动失败（license 版本不匹配，error 4），改走 metadata 直读路线：

- **证据链**：dump.cs 行 1030049 `internal static readonly <PrivateImplementationDetails>.__StaticArrayInitTypeSize=616 888BFFFA9D5BC23ABA6BFC6DB5ACA0414B021342528D0EDE6D939D5BEB8C7357 /*Metadata offset 0x115FE40*/` → `global-metadata.dat` 偏移 `0x115FE40` 起 616 字节。
- **读取结果**：11×14 float32，全部有限、范围 0..100，首两行首位/次位是 100/77、第三..五/十位对角 100、第六行首位 50、第七行第二位 38.5 等——与「11 种 lip kind × 14 口型混合槽（百分数）」语义吻合。无 NaN、无异常值。
- **消费端**：`UpdateFace 0x379E94C` 的 lip 段按 `lipParam[kind]` *0.01 写 BS0..13；muteLip 段用 `lipParam[muteLipKind-1]` 或 mouthCloseBuff。
- **接线**：`FaceLipParamNative.Table` 已在 `CharacterBootstrap.Start` 接入 `faceCtrl.LoadLipParam(...)`（原始 0..100 值）。**subagent 反编译复核修正**：`UpdateFace 0x379E94C` 的 lip→SetBlendShapeWeight 路径**没有 ×0.01**（原样写 BS0..13，与 mouthCloseBuff 同域 0..100 lerp）；唯一 `*0.01f` 在 EyeTracking scale 段。`GetRawWeight` 供原生一致数值，`GetWeight`（×0.01 归一）另作便利访问器。
- **B5 Assembly 复核发现**：`GetHeadModelTop/GetBodyModelTop` 原读 jbh+0xB8/+0xC0（headMesh/bodyMesh → get_gameObject），不是 body/head 根；`JointBodyHeadAssemblyNative.RunPostInitialize` 已按此实现（未命中才回退根并注明）。
- **MoveNext 尾段顺序（bootstrap 参考）**：eye 分支（info+184==1）→ EyeTracking.Init@0x379BF80 → FaceCtrl ctor@0x379DC1C → `if(info+68==1) face+76=info+72` → FaceCtrl.Init@0x379E5B8 → dshadow(+0xF8)=GetComponent<DropShadow>(body)。BodyScale 的 localScale 倍数来源是 CharacterManager 字典项（value@+36 × off_970CCF8 系数），**不是** CharacterSoul —— `ApplySoulBodyScale` 保持 no-op 记录。
- **残留 UNKNOWN（notes）**：lipParam 的 kind→口型语义映射（表值 bit 级正确）；JBH 字符串/材质 literals、DanceIdolInfo 旗标、swayBreast→SwayBone 槽位、face+76 字段、腮偏移 shader 属性名等 10 条。
- **落盘**：`$MLTD_WORK/out/face_lip_param.json` + `/tmp/lip-param-notes.md`。

### 日常动作（chr_anim_com）根因：humanoid muscle clip + 通用 Avatar（2026-11-08）

**事实**：
- `chr_anim_com_001har.unity3d` 的 7 段 clip 全部 `AnimationUtility.GetCurveBindings() == 0`、
  `isHumanMotion == False`、`legacy == False`；但 `m_MuscleClip` 是 **ClipMuscleConstant**
  （含 `m_DeltaPose: HumanPose`、`m_ValueArrayDelta`、`m_ValueArrayReferencePose`）
  → 数据是 **humanoid 肌肉空间**，不是普通 transform 曲线。
- 角色 prefab 的 `Animator.avatar` 是 **通用（isHuman=False）** 的 `cb_ss001_001harAvatar`。
- 因此 Unity 的 Animator/Playable 播这些 clip 时「什么都绑不上」：Playable 探针在 UDE_L/TE_L
  等 16 根骨上 `maxΔ = 0.0°`。

**结论**：要让日常动作动起来，必须给它一个**能映射 MLTD 骨骼名的 humanoid Avatar**
（`AvatarBuilder.BuildHumanAvatar` + humanDescription.boneName 映射），或自己解码 muscle clip。

**可用骨骼名样本**（300 个 GameObject 中）：
`KOSHI`、`MUNE1`、`mune1_chn`、`KUBI`、`ATAMA_jnt`、`KATA_L/R`、`UDE_L_jnt`、`TE_L/_jnt`、
`MOMO_L`、`SUNE_*`、`ASHI_L_jnt`、`HARA`、`koshi_chn` 等；
注意还有大量重名后缀（`MODEL_00 1`、`BASE1`）和约束骨（`*__twist`、`*__slerp_*`）。

### 日常动作（chr_anim_com）第 6-7 轮：Unity 播不了，只能自己解码或运行时抓取

**决定性实验**：用程序生成的标准 humanoid 骨架（Hips/Spine/Chest/Neck/Head/LeftUpperArm…，
Avatar 构建成功且 valid），播 7 段 `chr_anim_com_001har` clip → **LeftUpperArm/LeftLowerArm/
Chest/Head 的 maxΔ 全部 0.0°**。因此：

- 不是 MLTD 骨架映射问题（标准骨架同样不动）
- 不是 AvatarBuilder 的问题（标准骨架 avatar 有效）
- **Unity 的 Animator/Playable 读不到这些 clip 的曲线**

**clip 内部结构**（UnityPy）：
```
com_001har_18y_noo: sampleRate=60
    m_IndexArray=200 条   m_ValueArrayDelta=180 条   m_ValueArrayReferencePose=0
    m_Clip = Clip（自定义二进制 blob，非标准曲线表）
    GetCurveBindings() = 0
```
→ 曲线被存在 Unity 自定义压缩块里，游戏自己的播放器解析；`AnimationUtility` 看不到。

**两条可行路线**：
1. **运行时抓取**（务实）：在游戏里触发日常对话动作，Frida 按帧记录骨骼旋转，导出成我们自己的 motion 数据
2. **自己解码 Clip blob**：需要逆向 Unity 压缩曲线格式，成本高

### 日常动作：Unity 版本不兼容（2018.4 资源 vs Unity 6000.3）——2026-11-08

`strings` 显示资源包头是 **Unity 2018.4.11f1**（游戏客户端基于 2018.4/2020.3 引擎），
而我们的 spike 工程是 **Unity 6000.3**。

- 网格/贴图/材质：Unity 6 能正常加载（已验证 25 个角色同屏正常渲染）
- **AnimationClip**：2018 格式的压缩曲线在 Unity 6 里**读不出曲线**（`GetCurveBindings=0`、
  标准骨架上也 0°）→ 这是版本不兼容，不是数据缺失

因此"用 Unity 内置动画系统播游戏 clip"这条路**走不通**（除非把工程降到 2018/2020）。

**剩下两条**：
1. **运行时抓取**（需要在游戏里进一次对话场景，Frida 记录骨骼旋转）——最省事
2. 自己实现 2018 版压缩曲线的解码器（参考 AssetStudio 的实现，工作量大）

### 日常动作：运行时抓取工具已就绪（2026-11-08）

`tools/capture_bone_tree.js`：从 `SwayManager.BaseTr@0x70` 向上找到角色根，
再用 `Transform.get_childCount` / `GetChild(i)` **深度优先遍历整棵骨骼树**，
每 100ms 记录所有节点的 `get_localRotation`（带舞蹈/对话时间戳）。

- 不需要 GameObject 名字（il2cpp `get_name` 不可靠）：抓下来的顺序就是 DFS 顺序，
  离线用 bundle 里同一棵树的 DFS 顺序做索引映射即可
- 限制：深度 6 层、最多 400 节点（够覆盖角色骨架）
- 用法：先在游戏里进入会播日常动作的对话场景，然后跑抓取，持续 20–30 秒即可

### ★ 日常动作已跑通（2026-11-08）：走 adv_imo，不走 chr_anim

**关键纠正**：之前找的 `chr_anim_com_*` 是 Unity AnimationClip（2018 格式，Unity 6 读不出曲线），
但那**不是对话动作的载体**。真正的对话/日常动作是 **`adv_imo_*.unity3d`**，
里面是 `kind=imo.chara` 的 `CharacterImasMotionAsset`——和舞蹈 imo **完全同一套格式**。

实测（`adv_imo_ssn_intro_ver001_001har.unity3d`）：
- 180 条曲线、`time_length=23.33s`
- `UDE_L AngleZ` 范围 **130.9°**，`TE_L AngleX/Y/Z` 范围 **76.6° / 500.1° / 527.4°**
  → 手臂确实有动画

端到端验证（Unity 里用 `NativeMotionDriver` 播）：
| 采样 | UDE_L | TE_L |
|---|---|---|
| t1 | (0, 0, 98.8) | (81.2, 225.7, 172.0) |
| t3 | (0, 0, 98.9) | (73.9, 206.8, 150.1) |
| t5 | (0, 0, 93.2) | (75.3, 204.1, 161.2) |

→ **TE_L 变化 ≥25°，UDE_L 变化 ≥5.7°**，截图 `build/mltd-preview/daily-motion.png` 里
手臂自然弯曲、不再是 T-pose。

**用法**：
```bash
# 1. 从 NAS 资产库取对话动作（任意 adv_imo_* ）
curl -H "Authorization: Bearer <token>" \
  "http://192.168.0.6:2830/v1/assets/adv_imo_ssn_intro_ver001_001har.unity3d" -o adv.unity3d
# 2. 解成 motion JSON
spikes/porting-3d/export_imo.py --bundle adv.unity3d --out ~/mltd-work/motion-adv
# 3. 把 scene.json 的 imoFile 指向它，重建场景即可
```

**注意**：`export_imo.py` 对空/损坏 bundle 会静默输出 0 assets——先确认文件头是 `UnityFS`。

### chr_anim 是否遗留？—— 不是，它很可能是春香当前在用的日常动作（2026-11-08）

**找到了游戏自己的资源清单**：
`~/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents/e821415207bf0601ed040cb438d526c478a22873`
（21.6 MB，msgpack，结构和 CDN manifest 一样：asset → [sha, cdn 名, size]）

清单里同时出现：
- `chr_anim_com_*` **589 处**
- `adv_imo_*` **108 处**
- 例：`chr_anim_com_umset_lb07_102mis.reduc.unity3d`、`adv_imo_com_046rio_18y_end.unity3d`

**命名规律对比**（CDN 清单 1078590）：
| 前缀 | 数量 | 说明 |
|---|---|---|
| `adv_imo_com_*` | 276 | 只有部分角色（如 046rio 律子）有 `yes/noo/lop/str/end` |
| `adv_imo_ssn_*`/`tva_*` | 少量 | 剧情/TV 专用（春香只有 5 个：intro/kawaii/tenth）|
| **`chr_anim_com_001har`** | 1 | **春香的 7 段语义动作（noo/yes/act/str/swt/lop/end）只存在这里** |

**结论**：春香没有 `adv_imo_com_001har_*`，她的 7 段日常语义动作**只以 Unity AnimationClip 形式
存在于 `chr_anim_com_001har.unity3d`**。所以"chr_anim 是旧版遗留"的猜测**不成立**——它更可能
就是当前在用的那一套，只是 Unity 6 播不动 2018 格式的压缩曲线。

**三条可选路线**：
1. 用一个 Unity 2018/2020 工程专门做动画烘焙（把 clip 采样成我们自己的曲线格式）
2. 运行时从游戏抓（进对话场景，Frida 记录骨骼）
3. 自己解码 2018 压缩曲线

### 运行时资源加载监听工具（2026-11-08）

`tools/hook_bundle_loads.js`：hook `UnityEngine.AssetBundle.LoadFromFile(string)`，
记录运行期实际加载了哪些 bundle。用途：判定 `chr_anim_com_*` 是否仍在用。

用法：
```bash
python3 tools/hook_bundle_loads.py <秒数> <输出.json> <游戏pid>
```

**注意**：游戏进程会退出/重启（今天 pid 25520 → 新 pid 99707），重启用
`open "/Users/jacklin/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0310.app"`。
重签的 `get-task-allow` 仍在，Frida 可正常 attach。

**当前状态**：在标题界面挂 45 秒，加载事件为 0（符合预期——标题页不拉资源）。
需要进入会播放日常动作的界面才有数据。

### chr_anim 仍在用的直接证据（2026-11-08）

在游戏缓存里找到 **commu（对话）数据 bundle**：
`Data/Documents/Cache00/61/616b80...`（235KB，UnityFS）

里面同时出现：
- `chr_anim_com_...`（被截断的资产名）
- 路径片段 `s/imas/resources/exclude/m/commu/col/a/...86a_act.y`
- `_act`（日常动作名）

→ **chr_anim_com_* 由 commu（对话）系统引用，不是历史遗留**。春香的 7 段语义动作
（noo/yes/act/str/swt/lop/end）确实只存在于 `chr_anim_com_001har.unity3d`。

### 用 Unity 2020 导出曲线的尝试（被 License 挡住）

- 已安装：`/Applications/Unity/Hub/Editor/2020.3.32f1`
- 建了临时工程 `/tmp/unity2020-anim-proj` + `tools/unity2020/BundleCurveExport.cs`
  （用 `AnimationUtility.GetCurveBindings/GetEditorCurve` 把 2018 clip 曲线导成 JSON）
- **batchmode 运行失败**：日志 `Pro License: NO` / `Failed to activate/update license`
  → 需要先在 Unity Hub 里登录并激活 2020.3，再重跑

### ★ 证据确凿：chr_anim 是游戏正在用的（2026-11-08）

在游戏的下载缓存里直接找到了 **chr_anim bundle**：

```
文件: Data/Documents/Cache00/61/616b801322c352a5...
内部 AssetBundle 名: chr_anim_com_col_a_86.reduc.unity3d
包含 AnimationClip:    com_col_86a_act
```

→ 游戏**实际下载并缓存了 chr_anim 资源**，说明它在当前版本仍在用（不是旧版遗留）。
（对照：`chr_anim_com_001har` 里的 clip 命名是 `com_001har_18y_act`，同一套规则。）

**结论汇总**：
| 问题 | 结论 |
|---|---|
| chr_anim 是否遗留 | **不是**，游戏缓存里有实例，仍在用 |
| 春香的 7 段日常动作在哪 | 只在 `chr_anim_com_001har.unity3d`（Unity AnimationClip） |
| Unity 6 能否播 | **不能**（2018 序列化格式，`GetCurveBindings=0`，标准骨架也 0°）|
| 可行路径 | ① Unity 2020 导出曲线（当前被 License 挡住）② 运行时抓骨骼 |

### ★ 关键纠正：Unity 2020.3 也读不到曲线（不是版本问题）

用 **Unity 2020.3.32f1**（与游戏 2018.4 更接近的版本）打开同一个 bundle：

```
com_001har_18y_act: len=1.83 legacy=False isHumanMotion=False curves=0 objectCurves=0 frameRate=60
（7 段全部 curves=0 / objectCurves=0）
```

→ **不是 Unity 版本不兼容**：2020.3 的 `AnimationUtility` 同样读不到这些 clip 的曲线。
说明这些 AnimationClip 的曲线数据存在 **Unity 公共 API 不暴露的私有块**（`m_Clip.data`）里，
游戏是用自己的播放器直接解析的（和 imo 一样）。

**产出工具**（`tools/unity2020/`）：
- `BundleCurveExport.cs` / `MltdCurveExportAuto.cs`：在 Unity 2020 里加载 bundle、尝试导出曲线
- 临时工程 `/tmp/unity2020-anim-proj`；batchmode 因 License 不可用，GUI + `-executeMethod` 可行

**最终结论（本 goal 的问题 1）**：
| 问题 | 答案 |
|---|---|
| chr_anim 是否遗留 | **不是**（游戏缓存里有实体，且在 commu 系统中被引用）|
| Unity（6 或 2020）能否播/读 | **都不能**，曲线在私有块里 |
| 剩下可行路线 | ① 运行时抓骨骼 ② 自己解码 m_Clip 私有数据 |

### Unity 2020 关键实验（2026-11-08）：游戏自己的 prefab + Avatar 也播不动

在 Unity 2020.3.32f1 里，用**游戏原包 prefab**（`cb_ss001_001har`，Animator + `cb_ss001_001harAvatar`，
avatar valid=True / isHuman=False）逐帧 `SampleAnimation` 播 7 段 clip：

```
[com_001har_18y_act] sample: UDE_L=0.0° TE_L=0.0° MUNE1=0.0° KOSHI=0.0° ATAMA_jnt=0.0° KUBI=0.0°
（7 段全部 0.0°）
```

又尝试在该 prefab 上**现场构建 humanoid Avatar**（19 槽位映射，重名去重后）：
```
avatar= valid=False human=False        ← 构建失败（Unity 2020 与 6 都一样）
```

**结论**：无论用哪个版本的 Unity、游戏自己的 prefab/Avatar，还是自己造的 humanoid Avatar，
这些 clip 都驱动不了骨骼。它们在 Unity 眼里"没有可用于绑定/播放的数据"
（`curves=0`、`isHumanMotion=False`），而游戏能播，说明游戏内部另有一套读取路径
（muscle/私有块 + 自己的播放器）。**在 Unity 里直接播这条路已经排尽。**

**实验脚本**（可复现）：`/tmp/unity2020-anim-proj/Assets/Editor/`
- `MltdClipInfoAuto.cs`（clip 元信息）
- `MltdPlaybackAuto.cs`（游戏 prefab + SampleAnimation）
- `MltdHumanoidAvatarAuto.cs`（现场构建 humanoid Avatar 再播）

### 对照实验：标准 clip vs 游戏 clip 的字段差异（2026-11-08）

在 Unity 2020 里生成一个标准 `AnimationClip` 资产（`SetCurve` + `CreateAsset`），
对比序列化字段：

| 字段 | 标准 clip（.anim YAML） | 游戏 clip（AssetBundle） |
|---|---|---|
| `m_MuscleClip` | 无（普通曲线 clip）| **有**（`ClipMuscleConstant` + `HumanPose`）|
| `m_MuscleClipSize` | 无 | **有** |
| `m_AnimationClipSettings` | **有** | **无** |
| `m_EditorCurves` / `m_EulerEditorCurves` | 有（编辑器字段）| 无（打 player 包时被剥离，正常）|
| `m_ClipBindingConstant` | 有 | 有 |
| `m_SampleRate` | 有 | 有（60）|

**解读**：`m_EditorCurves` 这类编辑器字段在打包时本就会被剥离，所以"缺 settings"不能直接当结论——
需要看 humanoid clip 打包后是否也保留 `m_AnimationClipSettings`（未验证）。

**目前站得住的结论**（多轮实测）：
- 游戏 clip 是 **Unity 标准结构的人形肌肉动画**（不是自研编码器）
- 但 Unity 6 / Unity 2020、游戏自身 prefab+Avatar、现场构建 humanoid Avatar 都播不动（0°）
- 游戏能播说明它内部另有读取路径（自定义播放器，和 imo 同族）

**下一步**：运行时抓骨骼（唯一稳妥路线）。

### IDA：日常动作播放链路的第一层（2026-11-08）

从 `dump.cs` 取到 RVA 后反编译 `CommuPlayer`：

| 方法 | RVA | 反编译要点 |
|---|---|---|
| `Play(string,double)` | 0x33B9530 | 存字段 → `sub_84DA14` → 取单例 `qword_975B170` → `sub_24321FC(singleton, 0, time)`（转发给管理器）|
| `Play(string)` | 0x33B94B4 | 同上（时间=0）|
| `Load` | 0x33B8EE8 | 小函数，成立 `finishedLoadEventListener` |
| `DownloadUseResource` | 0x33BA994 | 协程，只有几行（真正下载在别处）|
| `CheckPlayElementInRange` | 0x33BADF8 | 按时间查当前 element |

对 0x33B9530 / 0x24321FC 做 220 个函数的调用图 crawl：**没有找到名字里带
Anim/Clip/Playable/Muscle/Pose 的函数**，说明真正播动画的代码在这条链的更深处或走消息分发。

**关键思路（下一轮）**：与其在游戏 UI 里找触发点，不如在 IDA 里定位
"按名字加载/播放 clip" 的那个方法，然后在 Frida 里**直接调用它**——
传入 `com_001har_18y_xxx` 之类的名字，就能把 7 段动作逐个放出来，不需要人工找入口。

### 目标：Frida 直接调 CommuCharacterManager 播日常动作（2026-11-08）

从 `dump.cs` 拿到的关键 API（RVA + 签名）：

| 方法 | RVA | 签名 |
|---|---|---|
| `Commu2Singleton<T>.get_Instance` | 静态属性 | 取单例 |
| `CommuCharacterManager.RegisterAnimation` | 0x1D1F324 | `float RegisterAnimation(string objectName, string assetBundleName, string resourcePath, bool forceLoadResource, ...)` |
| **`CommuCharacterManager.SetAnimation`** | **0x1D1FA58** | `bool SetAnimation(string objectName, string assetName, double time, bool needsLoop, double loopStartTime, Commu2AnimationClipParamSet ...)` |
| `SetAnimation`（混合两个 clip）| 0x1D1FE90 | `void SetAnimation(string objectName, string assetName1, double time1, string assetName2, double time2, float ...)` |
| `GetJointPosition` | 0x1D1DEAC | 取某角色某动画某关节的世界位置（可用来验证播放在跑）|
| `GetJointRotation` | 0x1D1E2B4 | 同上取旋转 |

管理器内部字段（可直接读内存）：
`characterMap@0x88`（Dictionary<string,CharacterInfo>）、`animationAbMap@0x98`、
`characters@0xC0`（List<Commu2Character>）、`commuEngine@0xA8`。

**下一步（等 IDA 重建完）**：
1. 反编译 `SetAnimation` / `RegisterAnimation`，确认 `assetName` 到底传什么（`chr_anim_com_001har`？还是内部 id）
2. Frida 里 `get_Instance` → 枚举 `characters` 拿角色名 → `RegisterAnimation` + `SetAnimation`
3. 抓骨骼 → 导出 motion → Unity 验证

### ★ 关键突破：commu 动画控制器里的 298 个 clip 全是 dummy（2026-11-08）

在 CDN 清单里按名字找到 `chr_anim_ctrl_com.unity3d`（45KB），下载后解析：

```
AnimationClip: 298   AnimatorController: 1   TextAsset: 1
```

298 个 clip 的名字全是 `dmy_com_aNN_action`（例如 `dmy_com_a86_action`）——**dummy 占位动画**。
里面**没有**任何 `com_001har_18y_*` 真实动作。

对照关系：
| 资产 | 内容 |
|---|---|
| `chr_anim_ctrl_com.unity3d` | 1 个 controller + **298 段 dummy clip**（`dmy_com_aNN_action`）|
| `chr_anim_com_001har.unity3d` | 春香的 **7 段真实动作**（`com_001har_18y_act/yes/noo/...`）|

**推论**：游戏在运行时用 **AnimatorOverrideController** 把 dummy clip 替换成真实动作
（这也解释了为什么 `CommuCharacterManager` 里会有 `RegisterAnimation` / `SetAnimation(assetName…)`）。

**这改变了我们之前的判断**：之前直接 `SampleAnimation` 播 clip 全是 0°，是因为**没有绑定到
Animator + controller 上下文**。如果按游戏的做法（controller + override）来播，很可能就能动。

**下一轮验证**（纯离线，不需要 Frida）：
1. 在 Unity 6 里载入 `chr_anim_ctrl_com` 的 controller
2. 建 `AnimatorOverrideController`，把某个 dummy state 覆盖成 `com_001har_18y_act`
3. 挂到角色 prefab 的 Animator 上播放，测 `UDE_L/TE_L` 旋转变化

### 决定性实验：controller + AnimatorOverrideController 仍然 0°（2026-11-08）

按游戏自身机制做的完整实验（Unity 6，游戏原包资产）：

```
controller = AnimCtrl_Commu  (clips=298)
realClip   = com_001har_18y_act  (len=1.83s)
avatar     = cb_ss001_001harAvatar  isHuman=False
overrides  = 298（全部指向真实动作）
result: UDE_L=0.0°  TE_L=0.0°  MUNE1=0.0°  KOSHI=0.0°
```

**结论**：即使完全复刻游戏的 controller + override 机制，骨骼依然不动。

**唯一未满足的条件**：Avatar 是 **generic（isHuman=False）**。Unity 的 muscle 动画必须挂
humanoid Avatar 才能绑定；而游戏包里的 Avatar 就是 generic。

**新推断**：`chr_anim_com_*` 里的 7 段 clip 与 `chr_anim_ctrl_com` 里的 298 段 dummy
一样，**很可能也是占位/被剥掉曲线数据的**（这解释了为什么任何 Unity 版本、
任何播放方式都读不到曲线）。真实动作数据可能通过别的渠道下发。

**与已可用的路线对比**：
| 资产 | 是否有真实曲线 | 能否在 Unity 播 |
|---|---|---|
| `adv_imo_*`（剧情动作）| ✅ 180 条曲线 | ✅ 已验证（手臂 maxΔ≥25°）|
| `chr_anim_com_*`（7 段日常）| ❌ 读不到曲线 | ❌ |

### 最后一轮定位：clip 有真实数据，缺的是 humanoid Avatar（2026-11-08）

对比 dummy 与真实 clip 的内部数据（UnityPy）：

| clip | index | delta | bindings | muscleClipSize |
|---|---|---|---|---|
| `dmy_com_a10_action`（dummy）| 200 | **0** | **0** | — |
| `com_001har_18y_act`（真实）| 200 | **180** | **60** | **224,312 字节** |

→ 真实 clip **确实带着 224KB 肌肉动画数据**（compressed=False, legacy=False, 60fps）。

**所以问题不是"数据被剥掉"，而是：Unity 要播肌肉动画，必须有匹配的 humanoid Avatar。**
而游戏包里的 Avatar 是 **generic（isHuman=False）**；我们用 `AvatarBuilder.BuildHumanAvatar`
现场构建（19 槽位映射 + 重名去重）在 Unity 6 和 Unity 2020 下都返回 **invalid**，
`BuildHumanAvatar` 不给原因（无错误日志）。

**三种尝试全部失败**（均实测）：
1. Unity 6 / 2020 直接 `SampleAnimation` → 0°
2. 游戏自己的 controller + `AnimatorOverrideController` 注入真实 clip → 0°
3. 现场构建 humanoid Avatar → 构建失败

**结论（goal 阻塞条件）**：要播这 7 段动作，必须先拿到一个能匹配 MLTD 骨架的 humanoid Avatar；
`AvatarBuilder` 对该骨架一律判 invalid 且无诊断信息。剩下两条路都需要较大投入：
① 逆向 `m_MuscleClip` 的 StreamedClip/DenseClip 编码自行解码（无公开文档，数天）
② 改用运行时抓骨骼（Frida 在该游戏上反复超时，未能稳定工作）

### ★★ 决定性反转：`chr_anim_*` 是 Generic 变换轨道，不需要 humanoid Avatar（2026-11-09）

上一节的结论（"必须有匹配 MLTD 骨架的 humanoid Avatar，否则播不了"，以及"数据可能被剥掉"）
**是错的**。真正的根因只有一个：**clip 的绑定路径里有一层运行时才插入的 `BODY_SCALE` 节点，
而 prefab 里没有它**，所以 Unity 的 Generic 绑定按路径 hash 找不到 transform，静默失败 → 全 0°。
解码器其实**早就在这个仓库里**（`photo_pose.py`，为 `chr_anim_pho_*` 拍照姿势写的），
日常动作和它是同一种资产，直接复用即可。

#### 证据链（全部可复现）

1. **这不是 muscle 动画。** `m_ClipBindingConstant.genericBindings` 有 60 条 binding，
   `typeID=4`（Transform），`attribute` 只有 1（position，3 条曲线）和 4（euler，3 条曲线）：
   180 条 streamed curve = 60 × 3，是普通的 Transform 动画轨道。
2. **绑定路径是 CRC32。** `path_hash("MODEL_00") = 782113489`、
   `path_hash("POSITION") = 2149546169`（即 binding 里那两个 "未知 hash"）。
   与 `tests/test_photo_pose.py` 钉住的值一致；`photo_pose.BONE_PATHS` 就是完整路径表
   （含 `MODEL_00/BODY_SCALE/...`、`POSITION`、`POSITION/SCALE_POINT`）。
3. **只差 BODY_SCALE。** 用 body prefab 的 Avatar TOS 路径，在 `MODEL_00/` 之后插入一段
   `BODY_SCALE` 再算 CRC：57 个 hash 命中 55 个，剩下 2 个正是 `POSITION` /
   `POSITION/SCALE_POINT`。也就是说 clip 是照着**游戏运行时层级**（`MODEL_00/BODY_SCALE/BASE/...`）
   烘的；`cb_*` prefab 里只有 `MODEL_00/BASE/...`。游戏自己 spawn 时插入 `BODY_SCALE`
   （native `DropShadow` 代码里 `tra.Find("MODEL_00/BODY_SCALE")` 就在找它）。
4. **Unity 6 实测**（原 prefab vs 插入 identity `BODY_SCALE`，`SampleAnimation`
   采样 `com_001har_18y_act`）：

   | 骨骼 | 原层级 maxΔ | 插入 BODY_SCALE 后 maxΔ |
   |---|---|---|
   | UDE_L | 0.00° | **116.73°** |
   | TE_L | 0.00° | 51.93° |
   | ATAMA | 0.00° | 10.99° |
   | HIZA_L | 0.00° | 8.52° |
   | KUBI | 0.00° | 6.82° |
   | MUNE1 | 0.00° | 4.91° |
   | KOSHI | 0.00° | 0.00°（该 clip 里 KOSHI 恒为 90°） |

   之前所有 0° 实验（`SampleAnimation`、游戏 controller + `AnimatorOverrideController`、
   自建 Avatar）都是同一个原因：**路径 hash 对不上，绑定静默跳过**；和 Avatar、和数据剥除无关。
5. **离线解码 = Unity 采样，逐点吻合。** `photo_pose.py` 解出的 30fps
   `eidolon.motion/1` 与 Unity 采样值（`com_001har_18y_act` 的 UDE_L AngleZ）：

   | t | 0.0 | 0.2 | 0.4 | 0.6 | 0.8 | 峰值 |
   |---|---|---|---|---|---|---|
   | 离线解码 | 9.39° | 26.56° | 75.03° | 117.78° | 125.67° | 126.11° |
   | Unity 采样 | 9.4° | 26.6° | 75.0° | 117.8° | 125.7° | 126.12°（=9.39+116.73）|

#### 工具与产物

```bash
V=~/mltd-work/venv/bin/python
# 单段：bundle -> 60fps 解码 -> 30fps eidolon.motion/1
$V spikes/porting-3d/photo_pose.py --bundle ~/mltd-work/chranim-com/chr_anim_com_001har.unity3d \
    --output ~/mltd-work/motion-daily
# 列表
$V spikes/porting-3d/photo_pose.py --bundle <bundle> --list
```

- `photo_pose.py` 直接可解 `chr_anim_com_*`（日常 7 动作）、`chr_anim_pho_*`（拍照姿势）、
  `chr_anim_the_*`（剧场）等所有 `chr_anim_*` Generic clip——不需要 Unity、不需要 humanoid Avatar。
- 已把 53 个角色的 `chr_anim_com_<idol>.unity3d` + `.reduc.unity3d`（共 111 个 pack）抓到
  `~/mltd-work/chranim-com/`，批量导出到 `~/mltd-work/motion-daily/`：
  **963 段 `eidolon.motion/1`、58 个角色、0 解码失败**（`index.json` 带来源 bundle）。
  注意：**日常动作大多在 `.reduc` bundle 里**，非 reduc 的 `chr_anim_com_<idol>.unity3d`
  往往只有 1 段 `act`；两套要合并去重。clip 名带年龄档（`18y`/`18a`/`18b`/`18c`/`18d`），
  同一角色可能有多档同一动作：
  - `end/str` 58/58 个角色都有；`noo/yes/lop` 57/58（只差 049mom）；`act` 55/58
    （049mom、204xxx、205xxx 没有），分布在 18c/18d/18y 等档；
  - `swt` 只有 13 个角色有（001har/002chi/005yay/009rit/011ami/012mam/052kao/101kot/102mis 等）；
  - 13 个角色在某一年龄档里凑齐完整 7 动作（多数是 18y）。
  → 这是该版本 CDN 的真实数据分布，不是解码失败（每个 pack 里的每个 clip 都解出来了）。
- Unity 6 里插 `BODY_SCALE` 后采样/渲染的 7 段截图：`~/mltd-work/out/daily-motions/`
  （`com_001har_18y_{act,noo,yes,str,swt,lop,end}.png`，768×1152；UDE_L 在动作中段 33.8°–131.3°）。
- 如果要在 Unity 里直接 `SampleAnimation` 这些 clip：**只需要在 `MODEL_00` 和 `BASE` 之间
  插一个 identity 的 `BODY_SCALE` GameObject**（游戏运行时就是这么做的）。若继续用
  `NativeMotionDriver` 播 imo，现有的 `stripBodyScaleNode` 适配保持原样即可。

#### 参考

- AssetRipper 的 `AnimationClipConverter` / `StreamedFrame` / `StreamedCurveKey`（反过来读：
  streamed 帧 = `float time` + `int32 keyCount` + key(`int32 曲线号` + 3 个 Bezier 系数 + `float value`)）：
  <https://github.com/AssetRipper/AssetRipper/blob/master/Source/AssetRipper.Processing/AnimationClips/AnimationClipConverter.cs>
- AssetStudio 的 `AnimationClip.cs`（`attribute` 1=位移 3 曲线 / 2=四元数 4 / 3=缩放 3 / 4=欧拉 3）：
  <https://github.com/Perfare/AssetStudio/blob/master/AssetStudio/Classes/AnimationClip.cs>

#### 对迁移的含义

- 日常动作不需要运行时抓骨骼、不需要 Frida hook、不需要 humanoid Avatar；
  `chr_anim_*` 全家族（日常/拍照/剧场/坐姿）都可用纯离线 Python 解码，成本≈0。
- 之前花在 `AvatarBuilder` / `SampleAnimation` / `AnimatorOverrideController` 上的尝试是弯路；
  根因是**层级少一层节点** + **没复用已有的 `photo_pose.py`**。

### 日常动作全角色打通：`chara_commu_pose_set` 映射 + Unity Animation 窗口展示（2026-11-09）

目标：把「春香那 7 个日常动作」推广到全部角色，并能在 Unity 的 Animation 窗口里逐个查看。

#### 数据结论：日常动作有两层，当前版本靠两层拼出 7 个

1. **per-idol 层**（`chr_anim_com_<idol>.unity3d`）：`com_<idol>_<age>_<action>`。
   春香是完整的 7 段（`18y` 的 act/noo/yes/str/swt/lop/end），但多数角色这一版只带一部分
   （常见是 act + end/lop/noo/str/yes，`swt` 只有 13 个角色有）。
2. **commu pose-set 层**（`chr_anim_com_<cat>_<variant>_<pose>.unity3d`）：`com_<cat>_<pose><variant>_<action>`。
   游戏 master data **`chara_commu_pose_set`**（TextAsset，`JSON/chara_commu_pose_set`）给了每个角色
   每个 pose 编号用哪个变体：
   - `Category`（Cute/Cool/Passion）→ 包前缀取前三字母：`cut` / `col` / `pas`；
   - 表的列名是 pose 编号（`p02`…`p114`），值是变体字母 `a/b/c/d`；
   - 反应组（`p03` 等）带 `noo/yes/str/lop/end`，待机组（`a10` 等）带 `act/swt`。
   证据：扫游戏自身缓存（`~/mltd-work/cache_anims.jsonl`）得到的包/动作，和按这张表推出的
   45–50 个 `chr_anim_com_*` 包逐个吻合——说明这就是游戏实际加载的日常/commu 动作包。

因此合并规则：**per-idol 真实 clip 优先，缺的用 pose-set 补齐**。结果：
`62` 个角色 × 7 动作 = `434` 段，`native` 291 段 + `commu` 143 段，0 缺失。

```bash
# 输入：~/mltd-work/{motion-daily,motion-scene,chara_commu_pose_set.json,cache_anims.jsonl,asset-manifest}
$V spikes/porting-3d/export_daily_motions.py
# 输出：~/mltd-work/motion-daily-merged/
#   <idol>_<action>.motion.json（eidolon.motion/1，带 index.json 记录来源：native/commu + 包名 + clip 名）
#   flat/<idol>_<action>.txt（30fps TSV，逐帧四元数，给 Unity 的编辑器脚本直接读）
#   flat/catalog.tsv（idol/action/body/head/category）
```

#### Unity Animation 窗口展示

游戏 bundle 里的 clip 是构建版，**编辑器曲线（path 字符串）被剥掉**，Animation 窗口不能直接显示。
做法是在编辑器里把动作采样/解码成项目内 `.anim` 资产：

- `Assets/Editor/MltdDailyMotionWindow.cs`：最初那版——载入 `cb_ss001_001har` + `ch_ss001_001har`，
  插 `BODY_SCALE`，`SampleAnimation` 采样 60fps 后 `AnimationUtility.SetEditorCurve` 烘 7 个 `.anim`，
  建 7 个 `.controller`，打开 Animation 窗口（菜单 `MLTD/Daily Motion/{act,noo,…}` 可切换）。
- `Assets/Editor/MltdDailyMotionBrowser.cs`（推荐）：读 `motion-daily-merged/flat/` 的 TSV，
  按「角色 + 动作」烘 `.anim`（四元数逐帧写入 `m_localRotation.x/y/z/w`，位置有变化时写 `m_LocalPosition`），
  搭角色 + `Animator`，选中并用 `AnimationMode.SampleAnimationClip` 定到 35% 处，然后打开 Animation 窗口。
  菜单：`MLTD/Daily Motion Browser`；也可用请求文件驱动：

  ```bash
  printf '003mik:act' > ~/mltd-work/daily-show.request   # 编译后自动执行
  ```

  角色身体/头：`~/mltd-work/characters/`（117 个 `cb_pr001_*` / `ch_pr001_*`，从 NAS 按需下载；
  `024ann_v2/027say_v2/050jul_v2/203xxx/204xxx/205xxx` 没有 `pr001` 资产，会回落到 `ss001` 或不可用）。

生成物都在 `Assets/__MLTD/`（已加进 `.gitignore`：是游戏数据的派生物，不入库）。

截图证据（Animation 窗口 + Game 视图中姿态）：`~/mltd-work/out/anim-window/`
（`haruka_{act,noo,yes,str,swt,lop,end}_animwindow.png` / `_pose.png`，以及
`miki2-act.png`、`momoko_yes_pose.png`、`yukiho_noo_pose.png`）。

#### 修掉两个「没法人眼审核」的问题（2026-11-09 晚）

初版浏览器有两个毛病，都已修：

1. **头身分离**：初版把 `ch_*` 头模型直接挂在 `MODEL_00` 下。日常动作只动身体骨骼
   （KUBI/ATAMA 会转/低头），头却钉在 MODEL_00 上 → 一播动作就分离。
   改成和 `CharacterBootstrap.BuildCharacter()` 一致：头挂到身体
   `MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/KUBI/ATAMA`（`SetParent(atama, true)`），
   同时按 `CharacterBootstrap.FixOutlineDepth()` 给材质补 `_ZShift1000Min/Max`。
2. **Game 窗口里糊**：不是渲染/材质问题——是**Game 视图本身是 docked 小面板，渲染分辨率低**。
   同一相机用 `capture game_view --source camera --width 1024 --height 1536` 渲染出来是清晰的。
   浏览器窗口现在自己用 **1024×1536 的 RenderTexture** 渲染预览（带 MSAA），窗口里看到的就是
   原生分辨率，和 Game 视图大小无关；并且加了播放/暂停/速度/时间轴，可以直接逐帧看。

用法：菜单 `MLTD/Daily Motion Browser`；顶部选角色 + 动作 → 「加载 / 刷新」；
「▶ 播放」连续播放；拖时间轴逐帧；「Action 窗口」打开 Animation 曲线窗口。
CLI 也可驱动：

```csharp
MltdDailyMotionBrowser.PreviewAt("001har","act",0.35f);  // 角色, 动作, 归一化时间
```

证据截图（`~/mltd-work/out/anim-window/browser_*.png`）：001har 的 act/swt/noo/end、
003mik 的 lop/swt、049mom 的 yes、007ior 的 noo——头都跟着身体，清晰度是 1024×1536。

### 澄清：7 个「日常动作」不是 7 段独立动画，而是一套姿势状态机的 7 个状态（2026-11-09）

实测 `chr_anim_com_001har_18y_*` 七段之间的边界姿态（每根骨四元数夹角，取平均/最大）：

| clip | 帧数 | 自身首帧 vs 末帧 | 结论 |
|---|---|---|---|
| `act` | 56 | **0.05°** | A 姿势的循环 |
| `swt` | 56 | 36.8° | A→B 的切换过渡 |
| `str` | 26 | 36.2° | A→B 的快速进入 |
| `lop` | 46 | 0.04° | B 姿势的循环 |
| `yes` | 31 | 0.05° | B 循环的变体 |
| `noo` | 31 | 0.04° | B 循环的变体 |
| `end` | 31 | 36.6° | B→A 的退出 |

`str/swt` 的**末帧 = `lop/yes/noo/end` 的首帧**；`end` 的**末帧 = `act/swt` 的首帧**，
全部边界误差 ≤0.4°。所以七个动作 = 一个姿势包（pose package）的完整状态集：

```
act(A 待机循环) --str/swt--> lop(B 表演循环, yes/noo 变体) --end--> act
```

游戏代码里也能对上（`dump.cs`）：`CharacterActorCommu.PoseInfo` 有
`has_loop` / `has_yes_no` / `is_action` / `switch_from` / `switch_to` / `bundle_pose` / `bundle_vari`；
`PoseSet` 有 `category` + `variations`。即：**每个 PoseInfo 由 pose clip 集 + variation(act) clip 集
组合成 7 段状态**，对话时按状态机切换/混合，而不是把 7 段当独立动作播。

#### 剧情对话用的动作远不止这 7 段

- **同一批姿势包在 ADV（剧情）里还有 imo 版本**：`adv_imo_com_<cat>_<pose><var>_<action>.unity3d`
  （276 个整角色/包，加上其他 pose 变体共 1125 个 `adv_imo_*` 资产）。抽了
  `adv_imo_com_cut_03a_lop.imo` 和 `chr_anim` 的 `com_cut_03a_lop` 做逐骨对比：
  UDE_L 的 AngleZ 起始 76.998° vs 77.00°，全通道 2760 个采样点 **平均差 0.0029°、最大 0.0142°**
  —— 两边就是同一段动作，只是 imo / AnimationClip 两种容器。
- **真正的剧情专用长动作**：`adv_imo_mjo_sty<NNN>_cut<NNN>_<idol>`（409 个）、
  `adv_imo_ops_*`（129）、`adv_imo_ssn_*`（114），例如
  `adv_imo_mjo_sty002_cut012_022ser` = 15.83s、180 曲线的一条完整演出动作（一条 cut 一条）。
- 其他动作家族（CDN 非 reduc 计数）：`chr_anim_com_*` 242 个包、`chr_anim_the_*` 87（剧场）、
  `chr_anim_lgn_*` 11（登录）、`chr_anim_2d_pose_*`、`chr_anim_pho_*`（拍照姿势，多为 reduc）、
  `adv_imo_igp_*` 187（抽卡/其他演出）等。
- 映射表：`chara_motion`（CharacterId → CommuCategory cut/col/pas + TheaterWalkCategory）、
  `chara_commu_pose_set`（每角色每个 pose id 用哪个变体、以及 SetNameSit）、
  `chara_motion_info`（Theater/Login 的动作名表）。

结论：**日常/对话表现 = 姿势包状态机 + 场景选包 + 剧情专用长动作**。当前 `motion-daily-merged`
里的 7 段只是每个角色**一个**姿势包的状态（所以看起来像同一个动作的不同状态），不是对话全部动作。
要和游戏剧情对齐，下一步得：
① 把 PoseInfo/pose 脚本的选包数据找齐（pose id + variant → 状态机参数）；
② 用 `adv_imo_*`（imo 格式，现有播放器直接可用）覆盖 ADV 剧情；
③ 状态机播放器：act ↔ str/swt ↔ lop/yes/noo ↔ end 的交叉淡入淡出 + 对话事件驱动。

（本次只在编辑器里做了状态片段展示；状态机与剧情数据尚未实现。）

### 2026-11-09 深夜：3D 立绘运行时（StandScene）编辑器验证 + #126 B5 收口

**目标**：把 spike 的原生管线做成 App 可用的「3D 立绘」运行时（ADR-0034 的 Unity 侧），
并先完成 #126 的三个 B5 原子件验收。

**Unity 侧新增/修复**（`Assets/Scripts/`）：
- `EidolonStandHost`：`LoadCharacter/SetEmotion/SetSpeaking/SetNod/SetFraming/SetPaused` 消息面；
  复用 `CharacterBootstrap` 装配，插 `BODY_SCALE`、outline `_ZShift1000`、按 `StandFraming`
  （knees/waist/full，照 `EidolonCore` 的公式）取景；loaded/failure 事件经
  `EidolonStandBridge`（iOS 端是 `EidolonStandNative.mm` 的 NSNotification 通道）回 Swift。
- `EidolonStandMotion`：读内容包里的 60fps flat TSV（`fps/frames/R/P` 行），act 循环 +
  yes/noo 手势交叉淡入；路径解析兼容 `MODEL_00/...` 与根下 `POSITION/SCALE_POINT`。
- `EidolonStandFace`：情绪→`FaceCtrl` 表情/脸红、说话口型（`SetLip` 0..4 循环）、
  眨眼（CharacterFace_RC 常量 0.125s / 3.2–6.0s）。**修**：Bind 时先 `SetFaceDirect(0,0)+
  SetEyeCloseDirect(false)+SetCheekDirect(0)`——原生 `SetFace(0)` 是 no-op，否则第一帧闭眼。
- `CharacterBootstrap`：`buildMotion/buildCameraOrbit` 开关、`FaceCtrl/SwayRig` 访问器、
  `FixOutlineDepth()` 接线；**修**：`jbh.Initialize(bodyObject, headObject, …)` 从未被调用，
  导致 JBH body/head 为 null（`RunPostInitialize` 报 unresolved）；bundle 缓存（body/head/soul/
  shadow 同一路径只 `AssetBundle.LoadFromFile` 一次，否则第二次加载同一 bundle 报错）。
- `JointBodyHeadNative`：节点名比较改为大小写/下划线不敏感（精确优先、前缀兜底），
  实际 bundle 节点 `MODEL_00/BODY_SCALE/ATAMA/KUBI/MUNE2/eyes` 现在全部解析。

**验证（Unity Editor 运行态，001har/pr001，内容 `build/Unity3DContent`）**：
- 加载：`[stand] resolved 56/57 motion bones`、`idleFrames=111`、loaded 事件；console **0 error**。
- 动作保真抽检：`ProbeIdle("t,bone")` 读数与 flat TSV 帧号反算逐位一致
  （UDE_L 98.750、HIZA_L 346.870、MUNE1 274.030、ASHI_L 0.890）。
- 表情/口型/脸红：`SetEmotion("5,0")+SetSpeaking("1")` 笑眼+张嘴；`SetEmotion("4,2")` 睁眼+脸红；
  多表情 sweep 15 个索引各不同。
- `#126` 证据：`~/mltd-work/out/b5-126/`（README、face-probe、drawer-jbh-probe、
  stand-default/happy/shy、b5-exercise 截图）；lipParam 11×14、材质 exercise 全字段变化、
  JBH Atama/Kubi/Mune2/Eye/Base/BodyScale/Model00/Position 全部解析，摆动开关往返正确。

**App 侧**（详见 `docs/3d-stand-integration-plan.md`）：UnityFramework（arm64 device）已嵌入
EidolonIOS，`UnityStandRenderer` + 设置开关「3D 立绘（实验）」已接；真机安装成功，
但首次启动被 iOS 拦为「不受信任的开发者」，等用户在设置里信任开发证书后再验。
