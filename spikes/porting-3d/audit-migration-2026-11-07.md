# 3D 迁移完整性审计（REA + IDA 复核）

- 日期：2026-11-07
- 范围：`spikes/porting-3d/unity-spike` 对游戏原生角色表现系统的迁移完整度——动作、辅助骨（CalcBone）、Sway（头发/蝴蝶结/裙摆/胸骨）、表情（FaceCtrl）、以及相关的角色装配/材质/视线/接地影子系统。
- 结论适用于 **Unity spike**；`EidolonIOS/`、`EidolonCore/` 未改动，不在本次范围。

---

## 0. 结论（先读这段）

**没有完整迁移。** 现在的 Unity spike 是「静态角色 + 一支舞能看」的最小骨架：主链路（bundle → 动作 → 辅助骨 → sway → 表情 → 截图）通，但相对游戏缺的是**子系统级**能力和**若干算法语义**，不是零散字段。

按层的结论：

| 层 | 状态 | 说明 |
| --- | --- | --- |
| 数据获取 | ✅ 完整 | `_sway` 文本、`FaceScrObj` 表情表、`dan_loveig_01` 曲线都完整取出；ss003 的 16/17 根 sway 骨、33 条骨路径 + 20 条碰撞体路径全部能解析，0 悬空 |
| 动作播放 | ⚠️ 部分 | 曲线解码在离线管线里是完整的（8 种 key_type）；但端上播放是 **30 fps 最近帧、无插值**，游戏是 1/60 网格 + 线性/Hermite 插值；无 optional 曲线、无多动作/过渡 |
| 辅助骨 CalcBone | ⚠️ 部分 | 只实现 4/8 种算法（SLERP/TWIST/ROT/CONST），`TITE_*` 4 种（长裙前后片）整个缺失 → 语料 4/109 模型长裙片停在 bind |
| Sway V01 | ⚠️ 部分 | 数据字段 38 个，解析 35 个，**真正参与解算只有 17 个（≈45%）**；最严重的是**碰撞体引用语义搞错**（见 P0-1），ss003 裙摆现在只撞骨盆球、不撞大腿胶囊 |
| 表情 FaceCtrl | ⚠️ 部分 | 28 个表情表 + 眨眼 + 口型字符串可用；但**脸红（cheek）整条链路 0%**，缺 `TransitionModule`、`muteLip`、`SetLipDirect/ConvLip`、`SetEyeClose`、`facialMenu/lipChar`、材质联动 |
| 角色装配/其他 | ❌ 缺失 | `EyeTracking`（视线/泪光/眼高光）、`DropShadow`（接地影/脚灯）、`CharacterDrawer`（描边/换色/脸红材质/z-shift）、`JointBodyHead` 的 sway 开关与 `swayFollowRate` 全部没迁 |
| Shader 全局量 | ✅ 无缺口 | 角色 shader 需要的 7 个全局量都设了；`_FadeTheaterColV` 不在角色 shader 消费表里，不设不算缺口 |

**当前测试模型（ss003 演出服）上已经生效的错误**（不是"换衣服才会暴露"）：

1. **Sway 碰撞体映射错误**：`_sway` 的 `<joint>#k` 中 `k` 是「该关节的第 k 个碰撞体」，移植把它当成了整个文件碰撞体数组的下标。ss003 的 14 根裙骨共 22 条引用 **22/22 全部绑到 KOSHI 骨盆球**，`MOMO_L/R` 大腿胶囊从未参与碰撞（数据侧证据 §5.2）。
2. **头部 sway 碰撞体绑错/丢弃**：头发骨引用 `KATA_L#0`、`KUBI#1/#2`，这些碰撞体定义在 **body** 的 `_sway` 里；移植按单文件建表 → 7/8 绑到头球、1 条静默丢弃。
3. **Plane / Bridge 碰撞体未实现**：`Violation()` 只区分 Capsule，其余一律当 Sphere；ss003 body 就有 4 个 Plane + 2 个 Bridge（头发的 `KUBI#1/#2` 正是 Bridge），`bridgetgt` 连解析都没有。
4. **`CalcRotate` 钳位不写回尾点**：游戏钳位后会把尾点放回允许角度，移植只在渲染时用钳后方向，下一帧仍从窗口外的 `tips[]` 继续积分/碰撞。
5. **`isSkirt` 语义被挪用**：游戏用它开裙摆屏障/侧线，移植用它决定是否叠加 70% 大腿基线 → ss003 有 5 根 `isSkirt=False` 的裙片拿不到基线（推断项，需按顶点权重确认）。

严重度清单见 §3；原生侧逐函数确认见 §4。

---

## 1. 校验方法与证据链

| 工具/资料 | 用途 | 说明 |
| --- | --- | --- |
| REA 6.8.0 (`rea` MCP) | 元数据权威清单 | `inspect_il2cpp_metadata` 读 `global-metadata.dat`：v31，45,483 类型 / 270,248 方法 / 203,587 字段；确认 `FaceCtrl`=type 9605（30 方法）、`CalcBone`=15265（22 方法）、`Imas.BoneLib.SwayBone`=15301（37 方法）、`SwayBone`(Ver02)=15330。受 `LC_DYLD_CHAINED_FIXUPS` 限制，REA 不给原生地址（`unsupported-pointer-encoding`），地址由 dump.cs/IDA 提供 |
| IDA Pro 9.5（idalib 无头） | 反编译原生函数 | 打开已分析库（`/tmp/mltd-ida/UnityFramework.i64`，7 万+ 函数规模），按 dump.cs RVA 直接定位；本审计复核的函数与结论见 §4 |
| `dump.cs`（Il2CppDumper 6.7.46） | 声明/地址索引 | `build/mltd-spike/out/il2cpp/dump.cs`；RVA 与 IDA 线性地址 1:1（实测 `sub_37EC030` = `CharacterImasMotionData.CreateFromImoAsset`） |
| `_sway` 语料 | 数据语义 | 从游戏缓存/工程 bundle 用 UnityPy 导出：ss003 + pr001 原文，以及 1,554 个 `_sway` 文件的全语料普查（字段/取值/特性统计） |
| gltf 语料 | 模型差异 | `build/mltd-corpus/*.gltf` 260 个，用于统计 TITE 骨、裙子结构等 |
| Unity 2026.3.27f2 运行态 | 行为复现 | 载入 ss003 场景后以 `eval` 读运行时状态（骨数、rig、材质），截图见 `~/mltd-work/out/` |

> 本目录下 `/tmp/audit-port-coverage.md`（声明→移植矩阵，45 KB）与 `/tmp/audit-sway-data.md`（数据字段→消费矩阵，620 行）是两份原始审计底稿，本文是其汇总 + 原生复核。

---

## 2. 逐系统迁移矩阵（摘要）

图例：✅ 语义等价；⚠️ 有实现但语义/参数不全；❌ 未实现；➖ 明确超出静态角色范围。

### 2.1 动作 / 曲线

| 能力 | 游戏 | 移植 | 判定 |
| --- | --- | --- | --- |
| imo 曲线解析（7 属性 / 8 key_type，含 Hermite） | `CharacterImasMotionAsset` + `CharacterImasMotionPlayer.SolveCurve` | 离线 `motion.py` / `compress_motion.py` 完整实现 | ✅（离线） |
| 时间网格 | `s_delta_time = 1/60`，`SolveCurves` 截断到 1/60 后插值 | `compress_motion.py` 重采样到 30 fps；`motion_to_eulr.py` 逐帧烘焙 | ⚠️ 分辨率减半 |
| 端上播放 | 每帧在 1/60 曲线上求值 | `CharacterBootstrap.Update`：`floor(time*30) % frames` 最近帧，无插值 | ⚠️ 台阶感 |
| 欧拉应用 | `SetResultToTransforms`（Euler 角写 localRotation） | `Apply()` 直接 `Quaternion.Euler` | ✅（顺序需注意） |
| optional 曲线（`CharaOptionalImoData`） | `SolveOptionalCurves` | 无 | ❌ 手对手等附加曲线缺失 |
| 多动作/过渡/初始姿势/step_keys/bookmark | 完整 | 只有单 clip 硬循环 | ⚠️/➖（step_keys 只影响 8 首指定曲，`loveig` 不在内） |
| `AnimatedBone.has_position/has_angle` | 决定是否写旋转/位移 | 无（全部 track 都写旋转） | ⚠️ 当前 clip 未见此类骨 |

### 2.2 辅助骨 `Imas.BoneLib.CalcBone`

| 能力 | 游戏 | 移植（`HelperBones.cs`） | 判定 |
| --- | --- | --- | --- |
| 名字文法解析（slerp/twist/rot/const、参数 `i/x/y/z + 百分数`） | `Awake`/`getParams`/`getTargetName` | 等价实现 | ✅ |
| SLERP / TWIST / ROT / CONST | 4 种基础算法 | 4 种都有 | ✅（ROT 轴语义有分歧，见 §4.1） |
| `TITE_FRONT_ROT` / `TITE_FRONT_TRANS` / `TITE_BACK_ROT_YZ` / `TITE_BACK_ROT_X` | 由 MOMO_L/R 驱动长裙前后片（含 localPosition 位移） | 无，关键字也不识别 | ❌ 4/109 模型（048rei-ss004、038chz-ss007、205xxx-gs001、010azu-ss013）长裙片停在 bind |
| `forceUpdate` / `RequestUpdate` / `IsAssistBone` | 节流与外部查询 | 无（每帧无条件执行） | ⚠️ 视觉等价，接口缺失 |
| `Constrain`（世界空间 −X 指向参考骨） | ✔ | 等价实现，静止姿态误差 0.000°（此前已验） | ✅ |

> 本模型 ss003：49 个带 `__` 的 Transform 里真正被登记的是 28~29 根（`null`/`gnull` 跳过），无 TITE 骨；所以 TITE 缺口在 ss003 上不可见，属"换模型才中"。

### 2.3 Sway V01（头发 / 蝴蝶结 / 裙摆 / 胸骨 / 翅膀）

| 能力 | 游戏 | 移植（`SwayData/Rig/Physics`） | 判定 |
| --- | --- | --- | --- |
| 文本解析（Top/Manager/Collider/Bone 段 + 每骨字段） | `SwayFileIO` / `SwayParamsScrObj` | 解析 35/38 个值字段 | ⚠️ |
| 每帧顺序 | `SwayManager.ExecuteUpdate`：SideLine → AntiFold → Move → Hit(×1~2) → PostUpdate(CalcRotate) | 单趟逐骨 Move/Hit/Rotate，侧线力内联 | ⚠️ 顺序敏感、非等价 |
| `SwayMove`：跟随 + 弹簧 + 阻尼 + 重力 + 侧线 + antiFold + damper/followRate/followSW/transBack | 完整 | 只有跟随/弹簧/阻尼/重力(y)/单向侧线弹簧；重力只取 `|y|` 沿世界 up | ⚠️ |
| `SwayHit`：Sphere/Capsule/Bridge/Plane、最深推出、`hitTwice` | 完整 | Sphere/Capsule 点测试；Plane/Bridge 被当 Sphere；无 hitTwice | ⚠️/❌ |
| `CalcRotate`：局部系 yaw/pitch 限位 + **尾点回写** + HitMuteForce | 完整 | 世界 up/径向近似的窗口；**不回写尾点**；无 HitMute | ⚠️ |
| 碰撞体引用 `<joint>#k` | `SwayColliderSet{c,path,n}`，按关节+序号查 | 只取 `#k` 当扁平下标 | ❌ **P0 错误** |
| body/head 两份 `_sway` 合并 | `SwayFileIO.Import` 合并到同一个 JointBodyHead | 两个独立 `SwayPhysics`，跨 bundle 引用查不到 | ❌ **P0** |
| `SwayManager` 组参数（gravity/stiffness/drag/follow/lineMoveLimit/sideline*/skirtL1L2/winds） | 参与解算 | 解析但 6 个字段一个都没用（`refParam: Manager` 时行为不同） | ⚠️ |
| 其余数据开关：`hitTwice`(1041/1554 文件 True)、`refParam Manager`(344)、`useBindDir`(121)、`HitMuteForce`(44)、`useLinkHit`(9)、`antiFold`(172)、`sideAntiSpring*` | 有 | 未消费 | ⚠️ 换服装暴露 |
| `SwayWind*` | 舞台风场 | 未迁 | ➖ 风源在舞台场景，角色包不带 |

### 2.4 表情 `Imas.FaceCtrl`

| 能力 | 游戏 | 移植（`FaceCtrl.cs`） | 判定 |
| --- | --- | --- | --- |
| 表情表加载（`FaceScrObj.charaParams`，61 角色×28 表情×32 通道） | `BlendParamLoad` | `LoadJson`（离线导出 → JSON） | ✅ |
| `SetFace(n, muteLip)` / `SetFaceDirect` | 2 个 API | 只有 `SetFace(n)`，`muteLip` 忽略 | ⚠️ |
| 表情过渡 0.1333 s | `TransitionModule` | 手写 `MoveTowards` | ✅（线性近似） |
| 眨眼（0.1 s，open/close 双缓冲） | 5 组 32 宽缓冲 | 两组 + 整表 lerp | ✅ |
| 口型 `SetLip(int)` / `SetLipDirect` / `ConvLip` / `lipChar` / 0.2 s 过渡 | 完整 | 只有字符串 API，立即生效 | ⚠️ |
| **脸红 `SetCheek` / `CheekUpdate` / `GetCheekValue` / `SetCheekValue`（`_IsReddish`/`_ReddishIntensity`）** | 三档 + 0.1 s 过渡 + `CharacterDrawer`/`CharacterSoul` 联动 | **完全无**；材质默认 `_IsReddish=0` → 永远不脸红 | ❌ |
| `SetEyeClose` / `GetCurrentEyeClose` / `SetSinging` / `facialMenu` | 有 | 无（只有 `BlinkNow()` 一次性眨眼） | ❌ |
| `SetFaceMaterial` / `SetCharacterDrawer` | 有 | 无 | ❌ |

### 2.5 其他表现子系统

| 子系统 | 游戏 | 移植 | 判定 |
| --- | --- | --- | --- |
| `EyeTracking`（视线、10 种模式、上下左右限位、泪光、眼高光 `_SubTex`/`_VfxTex`） | 有 | 0% | ❌ 近景可见 |
| `DropShadow`（接地影、脚灯、聚光） | 有 | 0% | ❌ 角色悬空感 |
| `CharacterDrawer`（描边宽度/颜色、idol 色、mono、rim、z-shift face/other、脸红、眼高光、LOD、CommandBuffer） | 有 | 只有 `FixOutlineDepth` 硬编码 `_ZShift1000Min/Max=0.2/2.0` | ⚠️/❌ Live 管线部分 ➖ |
| `JointBodyHead`（装配、`swayOn`、`SwaySwitch`、`swayFollowRate`、`swayTransBack`、翅膀限位、模型切换、配件显示） | 有 | 只做 body+head 装配、挂三组件 | ⚠️ |
| Shader 全局量 | 7 个角色全局 | 全部设置 | ✅ |

---

## 3. 缺口清单（按影响排序，附证据）

### P0 —— 当前 ss003 上就生效

**P0-1 Sway 碰撞体引用语义错误**
- 数据：`_sway` 里 `0: MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_L#0`；18 个碰撞体依次是 KOSHI 球、MOMO_L/R 胶囊、MUNE1/2、KUBI、KATA/UDE/TE。
- 移植：`SwayData.cs:244-249` 只取 `#` 后的整数；`SwayRig.cs:115-121` 用该整数索引扁平 `rig.colliders`。→ 14 根裙骨 22 条引用全部落到 `colliders[0]`（KOSHI 球），大腿胶囊从未参与。
- 语料统计：per-joint 解读违例 4/7,231；扁平下标解读违例 5,619/7,231（192 个文件）。
- 影响：裙摆贴腿/穿腿；现有 `SwayMeshProbe` 遍历全部 capsule 自测、不校验骨→碰撞体映射，所以此前"0 穿透"结论不能证明碰撞正确。

**P0-2 头部 sway 跨 bundle 碰撞体未合并**
- ss003 头部 17 根发骨里，`hair_ushiroA1` 引 `KATA_L#0`、`hair_yokoL1` 引 `KATA_L#0`+`KUBI#1`、`hair_yokoR1` 引 `KATA_R#0`+`KUBI#2`；这些碰撞体定义在 body 的 `_sway` 里。移植按单文件建表 → 7 条绑成 ATAMA 头球、1 条（`KUBI#2`）静默丢弃。表现：侧发/后发穿肩、绕颈。

**P0-3 Plane / Bridge 碰撞体未实现**
- `Violation()` 只特判 `Capsule`，其余当 `Sphere`（`SwayPhysics.cs:239-245`）；`bridgetgt` 未解析。ss003 body 有 4 个 Plane、2 个 Bridge；头发的 `KUBI#1/#2` 就是 Bridge（颈→肩）。全语料 205 个文件带 Plane、205 个带 Bridge。

### P1 —— 与游戏行为不同，特定姿势/服装可见

- **P1-4 `CalcRotate` 不回写尾点**：`SwayPhysics.cs:151-166` 先存未钳位 tip，`:255-291` 的 Clamp 只影响渲染方向 → 下一帧从窗外积分、碰撞点也按窗外算；大摆幅会"钳不住"/抖。游戏在钳位时把尾点放到允许角度（`research-mltd-sway-physics.md` §3.2）。
- **P1-5 `isSkirt` 语义挪用**：游戏用 `isSkirt` 开裙摆屏障/`sideLineForce2`/`skirtL1L2`；移植用它决定是否叠加 70% 大腿基线（`SwayPhysics.cs:119, 173-184`）。ss003 的 5 根 `isSkirt=False` 裙片（B0/LE0/LF0/RE0/RF0）没有基线。**推断项**：需按顶点权重确认这 5 片是否也蒙到大腿。
- **P1-6 CalcBone TITE 缺失**：见 §2.2；4/109 模型长裙前后片停 bind。
- **P1-7 脸红链路 0%**：见 §2.4；材质默认 `_IsReddish=0`，无 `SetCheek` → 剧情/表情常用表现不可用。
- **P1-8 EyeTracking / DropShadow 全缺**：视线、泪光、眼高光、接地影、脚灯全部没有。
- **P1-9 动作 30 fps 最近帧**：无插值；optional 曲线缺失；无过渡/多动作。

### P2 —— 换角色/换装/换曲才中

- `hitTwice`（1,041/1,554 文件 True，主要是头发）、`refParam: Manager`（344）、`useBindDir`（121）、`HitMuteForce/Rate`（44）、`useLinkHit`（9）、`antiFoldForceK/antiFoldAngle`（172）、`sideAntiSpring*` 未消费。
- `SwayManager` 6 个组参数全部未用；`CapsuleSphere1/2`、`colliderOffset`、`bridgetgt` 未解析。
- `swayFollowRate`/`swayDamper`/`swayFollowSW`/`swayTransBack`（来自 `JointBodyHead` 运行时，不是 `_sway` 文本）未迁移。
- `JointBodyHead` 的 `SwaySwitch`/`SwayManagerAllON`/`skirt_GP_SwayManagerCtrl`/翅膀限位/模型切换/配件显示。
- `CharacterDrawer` 除脸红外的材质联动（描边宽度/颜色、idol 色、z-shift、眼高光）。
- `HelperBones` 的 `Resolve` 写错：`candidate.IsChildOf(context.root)` 对所有骨恒真 → body/head 同名骨（KUBI 等）可能取错（`HelperBones.cs:201-209`）。
- 尾点取「第一个子骨」vs 游戏 `SwayBone.tipTrs`（无子骨时移植退化成 `radius*2`，游戏不这么做）。

### 明确不算迁移缺口（out-of-scope）

`SwayWind*`（舞台风场，角色包不带）、`SwayVer02`（系统开关控制的第二代求解器，pr001/ss003 走 V01）、`SwayCtrlAllMT/MT` 并行 Job（纯性能）、`BookMark`/`step_keys`/`MovePosition`/`lift`/`SwayManagerAllON`/`CharacterDrawer` 绘制管线/镜像/LOD/`Record`/`SetTemporaryStiffnessForce`（Live/剧情运行时编排）、`BlendParamLoadStep`（加载进度）。

---

## 4. 原生侧复核（IDA，2026-11-07）

> 用 IDA Pro 9.5（idalib 无头）在已分析库（702,223 函数，`/tmp/mltd-ida/UnityFramework.i64`）上按 dump.cs 地址直接反编译了 80+ 个函数，输出在 `/tmp/ida-decomp/*.c`。以下每条都是这次实际读代码得到的结论，用来把「声明层面缺失」升级成「语义层面确认」。

### 4.1 辅助骨 `CalcBone`

- `Awake`（`0x1C5F624`）：`CALC_BONE_INFO.initRefVec = initRefRot * Vector3.right`——反编译里直接取 `Vector3.right` 静态字段（`off_970CCF8+23` 的 60/64/68 字节），**参数里的 axis 字母没有参与 initRefVec 的计算**。
- `ExplictUpdate`（`0x1C60748`）：按 `type` 分派 **8 种**：0=`SlerpEx`、1=`Twist`、2=`ROT`、3=`Constrain`、4=`TITE_FRONT_ROT`（用 `referTransform2`）、5=`TITE_FRONT_TRANS`（算完还 `set_localPosition`）、6=`TITE_BACK_ROT_YZ`、7=`TITE_BACK_ROT_X`；每种最后 `set_localRotation`。→ 移植只覆盖 0–3，4–7 连关键字都没有。
- `ROT`（`0x1C60F74`）：`FromToRotation(initRefVec, curRefRot * Vector3.right)`，其中 `initRefVec` 就是上面的 `initRefRot * Vector3.right`；**axis 字母只被解析进 `CALC_BONE_INFO.axis`，ROT/SlerpEx/Twist 都不用**。→ 移植用 `AxisVector(axis)` 计算 `initRefVector`（`HelperBones.cs:73, 245, 292-300`）与原生不一致；`notes.md:661-685` 记录的「按首字母选轴才让 HIJI 正确」是经验修补，需要用 A/B 再确认是否在掩盖别的误差。
- `Constrain`（`0x1C612A4`）：世界空间 −X 指向参考骨，与移植一致（此前静止姿态 0.000° 已验）。
- `LateUpdate`（`0x1C60694`）带 `forceUpdate/ForceUpdateFrames` 节流；移植每帧无条件算（视觉等价、接口缺失）。

### 4.2 Sway（V01）

- `SwayManager.ExecuteUpdate`（`0x1C81CD8`）**四趟**：① 逐骨 `CalcSideLineDistance`（`0x1C736B8`）② 逐骨 `CalcAntiFoldForce`（`0x1C738A8`）③ 逐骨 `SwayMove`（`0x1C72964`，结果写回 `bone+64` 的 force）④ 逐骨 `SwayHit`（`0x1C732E8`），且 `bone+396`（hitTwice）为真时**同一帧再跑一次**。→ 移植是单趟逐骨，侧线力用当帧已更新的邻居，顺序与游戏不同。
- `SwayManager.PrepareUpdate`（`0x1C81A08`）：时间累积器按 **固定 1/60** 步长推进，`dt` 下限 1/60、上限 **0.025**；每帧把 `colliderInx` 重置为 −1、重算 `m_offset_rot`。→ 移植 `MaxStep=0.05`、最多补 4 步，步长语义不同。
- `SwayBoneMT.SwayMove`（`0x1C6867C`）确认：
  - 跟随率取 `swayFollowRateArray[category]`；为 0 时再查 `swayFollowSWArray[category]`，仍为 0 才用骨上的 `followForce`/`SkirtFallFollow`；**跟随量为 `tipTrs.position − lastBasePos` 乘该率**；
  - 速度项 `(curTip − prevTip) * (1 − dragForce) / (dt/0.016)²`；
  - 重力按 **Vector3 全向量**加（不是只取 `|y|`），且上一帧有碰撞时不加；
  - 结果再乘 `swayDamperArray[category]`（`a19`）；
  - 侧线有 `sideLineForce` 与 `sideLineForce2`/anti 两组（`a14/a17/a25/a26`），外加 `swayTransBack`（`a29`）；
  - `isWing` 有 ±4°/帧的 `minZAngle/maxZAngle → *Tgt` 限位过渡。
  → 移植只有 `followForce + stiffness + (1−drag) + 重力(|y|) + 单侧线弹簧`，缺 damper/followRate/followSW/transBack/antiFold/侧线 anti/翅膀过渡/全向量重力。
- `SwayBoneMT.SwayHit`（`0x1C68C3C`）：按 `colliderIndexParams` 逐碰撞体调 `SwayColliderMT.Check`，保留推出距离最大的一个并写回 `WorkingParams`；→ 移植只做单次最深的球/胶囊点测试。
- `SwayColliderMT.Check`（`0x1C73424`）按 `type` 分派 **0=Sphere、1=Capsule、2=Plane（`CheckPlane`）、3=Bridge（`hit_capsule_sphere` + `bridgetgt`）**；→ 移植把所有非 Capsule 当 Sphere，且不解析 `bridgetgt`。
- **`#n` 语义（P0-1 原生证据）**：`SwayFileIO.AttachSwayBone`（`0x1C7726C`）对每个 `SwayColliderSet{path,n}` 先 `FindObjectByPath(top, path)`，再 `GetComponents<SwayCollider>()`，取 `array[n]` 赋给 `set.c`。即 **n 是"该关节下第 n 个 SwayCollider"**，不是文件扁平下标。→ 移植把 `#n` 当 `rig.colliders` 下标，ss003 裙骨 22/22 绑到 KOSHI 球。
- **body/head 合并（P0-2 原生证据）**：`SwayFileIO.ImportCommon`（`0x1C764FC`）依次 `AttachSwayManager(body)`、`AttachSwayManager(head)`、`AttachSwayCollider(body, skirtGuardOffset)`、`AttachSwayCollider(head)`、`AttachSwayBone(body)`、`AttachSwayBone(head)`，全部挂到同一个 top 对象 → 游戏是**一份合并 rig**；移植拆成两个 `SwayPhysics`，头部引用 body 碰撞体必然查不到。
- `SwayBone.CalcRotate`（`0x1C72220`）：`atan2` 求局部 yaw/pitch → 与 `minY/maxY`、`minZ/maxZ` 比较并记「是否钳过」→ `Internal_FromEulerRad(0, yaw, pitch)`（Unity `Quaternion.Euler`）叠到父旋转；**钳位时用 `TransformPoint` 重算 `curTipPos`，并把它同时写进 `prevTipPos`**；之后 `HitMuteForce && (lineHitF||sphereHitF)` 时 `prevTip = curTip*HitMuteRate + hitTip*(1−HitMuteRate)`。→ 移植不回写尾点、无 HitMute、窗口几何是按世界 up/径向的近似（不是原生的局部 yaw/pitch 公式）。
- `CalcSideLineDistance`（`0x1C6A450`）：用 `sideSpringTorelance` 判"拉伸/压缩"，压缩超过容差才输出 anti 力（`sideAntiSpringForce`）；→ 移植只做单向拉弹簧、忽略容差与 anti。

### 4.3 表情 `FaceCtrl`

- `SetFace(n, muteLip)`（`0x379F5F0`）：同时设 `facialTrs.Set(n)` 与 `muteLipTrs.Set(muteLip)` 再 `UpdateFace`。→ 移植 `SetFace(int)` 没有 muteLip 这一维。
- `ConvLip`（`0x379F3A4`）：把调用方的口型码转成 0..10 的 lip 索引（50→5、54→−1（静音）、55..59→6..10、其余 `%5`）；`SetLip(int)`（`0x379F46C`）用它再 `lipTrs.Set`，然后 `UpdateFace`。→ 移植改成字符串 API + 直接写 blend shape，语义不同。
- `SetCheekValue`（`0x379F840`）：`Material.SetFloat(shaderPropID_ReddishIntensity, v)` + `SetMaterialToggle(mat, shaderPropID_IsReddish, keyword, v != 0)`，再调 `CharacterDrawer.SetCheekReddenEnable(v!=0)` / `SetCheekReddenIntensity(v)`。→ 移植完全无脸红链路（材质 `_IsReddish` 默认 0，永远不红）。
- `Action`（`0x379FA48`）：先推进 **5 个 TransitionModule**（facial/eye/muteLip/lip/cheek，`ratio = 1 − timer/transTime`，到点把 last=cur），`UpdateFace` 之后按 cheek 档位：OFF=0、Weak=`cheekBaseIntensity*0.5`、Strong=`cheekBaseIntensity`，用 cheek 过渡比例插值后 `SetCheekValue`。→ 移植只有 2 个手写过渡（表情/眨眼），无 TransitionModule、无 cheek、无 muteLip。
- `FaceCtrl.cctor`（`0x379FD10`）建了两个静态表：`lipChar` **60 项**、`facialMenu` **28 项**（对应 28 个表情的菜单名）。→ 移植两个表都没有；28 个表情的语义命名（交接文档的待办 #1）本来可以靠 `facialMenu` 解决，但字符串指针在 `LC_DYLD_CHAINED_FIXUPS` 里，静态库读不出内容（REA 也不解码），需要运行时或 memdump 才能落地，本次标为未知。

### 4.4 动作

- `CharacterImasMotionPlayer.SolveCurve`（`0x37E80B8`）：按 `key_type` 分派（case 0 二分 + 4 元插值、case 1 多分支 step/linear、case 2 常量），在 **1/60 网格**上求值。
- `CharacterImasMotionPlayerDance.UpdateTime`（`0x37EDF1C`）：维护 `current_time/next_time`，循环时用 `floor` 回绕；`SolveCurves` 把时间截到 1/60 网格后逐曲线求值。
- `CharacterImasMotionPlayerDance.SetResultToTransforms`（`0x37EE99C`）：每条结果 `Quaternion.Euler(angle)` 写 `localRotation`；位置轨道只有在值非零时写 `localPosition`（`has_position` 语义）。→ 移植直接 `Quaternion.Euler` 写旋转、位置无条件写；**播放侧无插值、30 fps 最近帧**（`CharacterBootstrap.Update`），与 1/60 求值不一致。
- `SolveOptionalCurves`（`0x37EEB2C`）确实存在 optional 曲线通道（`CharaOptionalImoData`）。→ 移植未迁。

### 4.5 REA 交叉核对

- `inspect_il2cpp_metadata`（metadata v31）：45,483 类型 / 270,248 方法 / 203,587 字段；`FaceCtrl`=type 9605（30 方法）、`CalcBone`=15265（22 方法）、`Imas.BoneLib.SwayBone`=15301（37 方法）、`SwayVer02.SwayBone`=15330——与 dump.cs 完全一致，说明 dump.cs 没有漏类。
- 受 `unsupported-pointer-encoding: Mach-O chained fixups are not decoded` 限制，REA 不能把 metadata 方法映射到原生地址；所以「元数据清单」用 REA，「地址 + 反编译」用 IDA + dump.cs。两者在这一步互补，没有冲突。

### 4.6 仍未证实 / 留作后续

1. `facialMenu` 28 个名字的实际内容（chained fixup 指针，静态取不到；需要运行时读取或用 memdump）。
2. 4 个 TITE 算法的精确公式细节（本次只确认存在与分派，未逐式移植验证）。
3. `swayFollowRate` / `swayDamper` 数组的来源与默认值（`JointBodyHead` 初始化里设置；本次未反编译到底，移植侧一律没有）。
4. 移植「ROT 按轴字母」的经验修正与原生 `Vector3.right` 不一致——需要在 Unity 里做 A/B（同一姿态下两种 initRefVec 的 HIJI/UDE 角度差），再决定是否回退。

---

## 5. 数据侧证据（可复现）

### 5.1 环境与导出

```sh
PY=/Users/jacklin/mltd-work/venv/bin/python
# ss003 + pr001 的 _sway 原文（只读 bundle）→ /tmp/sway-audit/
# 全语料 1,554 个 _sway 的字段普查 → /tmp/audit-sway/
```

### 5.2 ss003 body `_sway` 关键事实

- 16 根 SwayBone：14 根 `skirt_*`（9 根 `isSkirt=True`、5 根 False）+ 2 根 `OPAI_*`；全部 `refParam: Self`、无 sideLink/hitTwice/useLinkHit。
- 18 个碰撞体（文件顺序）：`KOSHI#0 Sphere r0.13`、`MOMO_L#1 Capsule r0.088 len0.355`、`MOMO_R#2 Capsule`、`MUNE1#3 Capsule`、`MUNE2#4-8`（4 Plane + 1 Capsule）、`KUBI#9-11`（Capsule + 2 Bridge）、`KATA/UDE/TE` 左右。
- 14 根裙骨每条都写 `MOMO_L#0`、`MOMO_R#0` → 移植解析成 `[0,0]` → 两条都指向 `colliders[0]` = 骨盆球。

### 5.3 head `_sway` 关键事实

- 17 根发骨；2 个 ATAMA 球在 head 文件；发骨引用 body 的 `KATA_L#0`、`KUBI#1/#2`。
- 移植单文件建表：7 条错绑 ATAMA、`hair_yokoR1` 的 `KUBI#2` 越界被丢。

### 5.4 表情表

`~/mltd-work/out/facial_chara.json`：61 角色 × 28 表情 × 33 通道；`001har` 的 open/close 只在眼通道（下标 24/25）不同，第 33 通道在网格上无对应 blend shape——移植整表 lerp 的写法合理。

### 5.5 当前 clip

`~/mltd-work/out/dance.bin` = 900 帧 × 30 fps × 56 track（30 s 循环），无 POSITION 轨（舞台摆位丢弃）。帧 0/120/…/860 的裙摆、头发、肘部此前抽查正常。

### 5.6 Unity 运行态探针（本次实测）

用 `unity command eval` 在 ss003 场景里读运行时对象（探针输出 `/tmp/unity-probe.txt`）：

```
helperCount=30                     # CalcBone 实际登记 30 根（ss003，无 tite）
swayGroups=2                       # body / head 两个独立 SwayPhysics（游戏是合并 rig）
rig bones=16 colliders=18          # body 16 骨 / 18 碰撞体（与 _sway 一致）
skirt_F0  refs=2 :: KOSHI#0(r0.13,Sphere) KOSHI#0(r0.13,Sphere)   # 22 条裙骨引用全部落 KOSHI 球
rig bones=17 colliders=2           # head 17 骨，但只建出 2 个碰撞体
hair_ushiroA1 refs=1 :: ATAMA#0(r0.115,Sphere)    # 本应 KATA_L#0（body 文件里的胶囊）
hair_yokoL1   refs=2 :: ATAMA#0 ATAMA#1           # 本应 KATA_L#0 + KUBI#1（Bridge）
hair_yokoR1   refs=1 :: ATAMA#0                   # 本应 KATA_R#0 + KUBI#2；第 2 条越界被丢
faceMat=ch_pr001_001har_face_m hasIsReddish=True val=0 hasReddishIntensity=True val2=1.5
faceCtrl= 001har 28 expressions of 61 characters, 32 shapes
```

两条结论：
1. **P0-1/P0-2 在运行态可复现**：裙摆只撞 `KOSHI` 球（大腿胶囊不在列表里），头发 7 条绑 ATAMA 球、1 条被丢；
2. **脸红未驱动**：材质有 `_IsReddish`/`_ReddishIntensity` 属性，但 `_IsReddish=0`，移植没有任何代码写它 → 永远不脸红（与 §2.4/§4.3 一致）。

---

## 6. 建议的修复顺序

1. **P0-1/P0-2/P0-3 一起修**：`SwayBoneData` 保留 `(jointPath, n)`；`SwayRig` 用 `(path,n)` 索引；body/head 合并成一个 collider 表（或允许跨 rig）；补 Plane/Bridge/`bridgetgt`。修完用「骨→碰撞体映射表」探针验证（现在的 `MeasureRig` 测不出来）。
2. **P1-4**：`Clamp()` 返回钳位后的方向后把 `tips[bone]` 也写回；同时补 `HitMuteForce`。
3. **P1-7**：`FaceCtrl` 取 `face_material`，补 `SetCheek/SetCheekValue`（`_IsReddish`/`_ReddishIntensity`，0.1 s 过渡）。
4. **P1-9**：C# 端按 60 Hz 在 30 fps 烘焙帧间做线性插值（或直接改离线管线到 30 fps 但播放时插值），消除台阶感。
5. **P1-6**：补 `tite` 关键字 + 4 个 TITE 算法（需要 `referPath2/initMyPosition`，语法可参考 dump.cs 和 `SwayData` 的骨名样本）。
6. 之后才是 EyeTracking/DropShadow/CharacterDrawer 联动与 JointBodyHead 开关。

---

## 7. 复现与证据文件

| 内容 | 路径 |
| --- | --- |
| 本报告 | `spikes/porting-3d/audit-migration-2026-11-07.md` |
| 声明→移植矩阵（45 KB） | `~/mltd-work/audit/audit-port-coverage.md` |
| 数据字段→消费矩阵（620 行） | `~/mltd-work/audit/audit-sway-data.md` |
| `_sway` 原文/语料 | `~/mltd-work/audit/sway-audit/` |
| IDA 反编译输出（80 个函数） | `~/mltd-work/ida-decomp/*.c` |
| **IDA 已分析数据库**（可复用，省 30 分钟重分析） | `~/mltd-work/ida/UnityFramework.i64` |
| Unity 运行态探针输出 | `~/mltd-work/out/unity-probe.txt` |
| 运行态截图 | `~/mltd-work/out/*.png` |
| 交接文档 | `docs/3d-branch-handoff-2026-11-07.md` |

### 7.1 复用 IDA 库的姿势

```sh
# 无头反编译单个函数（idalib 在 ~/mltd-ida/venv）
~/mltd-ida/venv/bin/python - <<'PY'
import idapro, ida_hexrays, ida_funcs
rc = idapro.open_database("/Users/jacklin/mltd-work/ida/UnityFramework.i64", False)
print("rc", rc, "funcs", ida_funcs.get_func_qty())   # 预期 702223
ida_hexrays.init_hexrays_plugin()
print(ida_hexrays.decompile(0x1C6867C))              # SwayBoneMT.SwayMove
idapro.close_database()
PY
```

- 打开已分析库约 1–2 分钟；单函数反编译 0.1–0.5 秒。
- 地址取自 `build/mltd-spike/out/il2cpp/dump.cs` 的 RVA（与 IDA 线性地址 1:1）。
- 不要再用原始 Mach-O 打开（会重新分析 70 万函数，约 30 分钟）。

---

## 8. 迁移状态更新（2026-11-07，执行 ADR-0033 后）

本审计列出的缺口正在按 B1–B5 重写。当前状态（详见 `migration-progress.md` 与 git log）：

| 审计缺口 | 状态 | 实现与证据 |
| --- | --- | --- |
| P0-1 `#k` 碰撞体语义 | ✅ 已修 | `SwayFileNative` 保留 `(path,n)`，`SwayRigNative` 按 joint 的 GetComponents 序解析；运行态 22/22 裙骨引用解析到 `MOMO_L/MOMO_R#0` |
| P0-2 body/head 合并 | ✅ 已修 | `SwayRigNative.Build` 按 `ImportCommon` 顺序合并；头发 `KATA_L/R#0`、`KUBI#1/#2` 全部 resolved |
| P0-3 Plane/Bridge | ✅ 已写 | `SwayColliderMT.Check` 四类分派 + `bridgetgt`/`clipPlane`/`planeRot`；并用数值探针修掉胶囊半径漏加（-63mm→-5.5mm） |
| CalcRotate 回写 / HitMute | ✅ | 钳位后重算 curTip 并写 prevTip + HitMuteRate 混合 |
| 30fps 最近帧 → 原始 imo | ✅ | `CharacterImasMotionNative` + `NativeMotionDriver`：8 种 key_type、optional、多动作、1/60/连续求值；与 `motion.py` 对拍 max 6e-5° |
| CalcBone 4/8 + ROT 轴 | ✅ | `CalcBoneNative` 8 算法 + TITE；ROT 用 `Vector3.right`，z 轴 `__rot` 走原生 SLERP 分支；运行态 30 根辅助骨 |
| 表情/脸红/muteLip/lip 表 | ✅ | `FaceCtrlNative` 全 API；`facialMenu[28]` 与 `lipChar[60]` 已从 metadata 解出；材质 `_IsReddish=1` 实测 |
| EyeTracking / DropShadow | ✅ 已接入 | EyeTrackingNative（Init/SetTarget/EyeUpdate/SetTeary/SetMaterials）+ EyeTrackingDriver 每帧驱动；DropShadowNative（CIRCLE 等 4 模式）+ chara_shadow 包接线；运行态脚下接地影出现 |
| CharacterDrawer / JointBodyHead / CharacterSoul | ⚠️ 部分 | CharacterSoulNative（61 角色，cheek intensity 已用于 FaceCtrl）、CharacterDrawerNative 角色子集、JointBodyHeadNative 开关/运行时 sway 数组；JBH 完整 Initialize/模型切换/眼镜/配件显示、Drawer apply_color/Live 管线仍是缺口（详见 migration-progress） |
| `lipParam[11,14]` | ✅ 已恢复 | global-metadata @0x115FE40 直读 616B（dump.cs `<PID>=616` 行为佐证），11×14/0..100；UpdateFace lip 段不做 ×0.01（subagent 复核，唯一 ×0.01 在 eye scale）；`FaceLipParamNative` 接线 FaceCtrlNative，kind→口型语义映射仍 UNKNOWN |
| 旧近似组件（HelperBones/SwayPhysics/SwayRig/SwayData/SwaySolver/EidolonMotionClip/EULR） | ✅ 已清理 | 全部删除，CharacterBootstrap 收斂为纯原生管线（commit 26019f96） |
| 游戏内视觉对照 | 部分 | `~/mltd-work/ref/game/` 15 张参考图；缺舞蹈帧（未进 LIVE）与真变焦（PlayCover 无法 pinch） |

## 9. 运行经验沉淀（2026-11-07）

与游戏对照和调试中反复用到、值得写下来的方法（详见 migration-progress 与 spec #126）：

1. **探针先于结论**：像素级"不对"先用逐帧数值采样定位（EyeFlickerProbe 一帧一测 rx/ry/eye base/camera/material ST/UV），再决定修输入还是公式。两次眼睛问题（jitter、黑眼）都是输入/配给问题，公式一项没改。
2. **IL2CPP 数据恢复三层链**：
   - `dump.cs` 字段/方法 → RVA（=IDA 地址）读行为；
   - metadata usage（token→字面量）→ 字符串/材质名/路径（facialMenu/lipChar/shader 属性名/Chara/Shadow/*）；
   - `RuntimeHelpers.InitializeArray` blob → `global-metadata.dat` 直读（lipParam 616B @0x115FE40），IDA 失效也不阻塞。
3. **材质属性必须 bundle 实测**，不要信 shader 源里的默认值：`_Stencil`、`_MonoColor`（全局）、`_IsReddish/_ReddishIntensity/_ReddishColor`（仅 Chr_Face）、`_IrisColor/_SubTex`（Bi_CharEye）都被实测过。
4. **Unity 自动化稳态**：`unity open/recompile/status`、`editor.set_auto_tick` + `editor.playmode set_run_in_background`（否则 Game 视图失焦时 frameCount 停 1）、`command capture game_view`（自动开窗）、`SwayShot.Request`；Game 视图窗口可能被自动化搞坏尺寸，必要时关掉重开。
5. **游戏内参考图**：PlayCover 自动化稳定可做（正面/侧面/背面/特写），但应注意 ① PlayCover 中 Stage Manager 会缩窗口，每次操作前 activate+校验像素尺寸；② 游戏内优先级：別选曲/付费/设置/引继一律不动；③ 参考婚纱 ss003 `not_confirmed`（衣装列表没有命名项，疑为 LIVE 演出服）。
6. **行为实验前先看浏览坐标**：诊断眼睛时把 eye base 旋转与相机一起记进去（`atan2` 过零翻转特征一眼可见：±60° 突变），用数值说话，少猜多证。
7. **subagent 提交先后序**：文件先落盘、send_message 汇报时明确 `已编译/未编译`，lead 统一由 Unity `recompile` 验证并提交（本轮 4 个批次都这样收口，没有出现互相踩脚）。
