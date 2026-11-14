# Deviation Audit — MLTD 3D 原生一致迁移（2026-11-08）

系统性偏差清点：**找出所有"没老实按原作函数来"的地方**。只读审计，不改代码。

- 范围：`spikes/porting-3d/unity-spike/Assets/Scripts/` 下 23 个文件（ADR-0033 B1–B5 移植面）
- 证据：`/tmp/ida-decomp/`（234）、`/tmp/ida-decomp2/`（6）、`/tmp/ida-decomp/b5/`（125）、`dump.cs`
- 判定：
  - **A** = 确认等价（有反编译/dump.cs 证据支撑）
  - **B** = 确认偏差（与原生行为不同，需要修）
  - **C** = 无法判定（缺反编译/需运行时探针；列出需要的地址）

方法：grep 全部 `DEVIATION / UNKNOWN(native / deviation / to be validated / instead / mirrored / substitution / fallback / not decompiled` 标注（大小写不敏感），131 处标注逐条对照反编译；另对 5 个已知疑点做了原生反编译的逐行对照（0x1C814AC、0x1C72220、0x1C69F04、0x1C633CC、0x1C63AF8、0x1C66DB0 备书）。IDA/headless 通道本次不可用（`open_database rc=1`，见文末"工具注记"），全部判定建立在**已导出的反编译文件**上。

---

## 摘要

- **B 类（确认偏差）11 条**，按行为影响排序，见下表。
- **C 类（无法判定 / 需补证据）27 条**，聚合后整理为一张"需要的地址/探针清单"。
- **A 类（确认等价）** 覆盖大部分标注：lazy 独立实现（CalcBone 8 算法、FaceCtrl 各 Set*/Action、SwayManager.ExecuteUpdate 四趟、SwayHit 两趟、GetFollowRate 链、PrepareUpdate 累积器与 m_delta_time 平滑、SwayBone 侧面链接 back-pointer、SetFaceDirect(0,0)、SetCheekRedden* 三件套、SetSpotlightColor 記录结构等）都核对到了原反编译，结论 A。
- 两个已报 bug（胸部布料跳 / 裙穿模）的直接嫌疑：**B-1（CalcRotate 非限角支路缺 bind-pose 重置）** 与 **B-2/B-3（Materials 三件套"只记不写"）**。B-1 与原生 0x1C72220/0x1C69F04 的逐行对照给出了明确差异，是最该先修的一条。

---

## B 类（确认偏差）— 置顶，按行为影响降序

| # | 文件:行 | 原生地址 | 行为描述（原生 vs 移植） | 修复建议 |
|---|---------|----------|--------------------------|----------|
| B-1 | `SwayBoneNative.cs:551-561` | `0x1C72220`（serial）+ `0x1C69F04`（MT） | **CalcRotate 非 limitAngle 分支缺 bind-pose 重置**。原生两个版本在函数入口都先 `set_localRotation(initialLocalRotation)` 再 `InverseTransformDirection(curTipPos - trs.position)`：serial 版在分支判断**之前**（`sub_70BF458(trs, initial)` @0x1c72220 第 22 行），MT 版同为 `sub_70C37C0(trs, a3[20..23])` @0x1c69f04 第 105 行。移植的 else 支路只写了 `// UNKNOWN ... composition mirrored from SwayBoneMT`，**没有写这一步重置**，导致 InverseTransformDirection 在"当前已摆动帧"的参考系下算方向，`initialLocalRotation * FromTo(aim, localDir)` 每帧给出错误朝向（differs unless deltaPrev==I）。影响所有非限角 sway 骨（胸衣/ Bracelet / 头发 / 腿部等）。限角分支移植是对的（有重置，且 clamp 用 +108/+112 与原生一致）。 | else 分支在 `InverseTransformDirection` 之前加 `trs.localRotation = initialLocalRotation;`（与限角分支一致）。渲染帧间 curTipPos 世界坐标不受此重置影响（tail 位置是瞬时量）。 |
| B-2 | `CharacterMaterialsNative.cs:670` + `CharacterDrawerNative.cs:585`（SetEyeHighlightColor 链） | `0x1C1DC8C`、`0x1C1DB28`、`0x1C1F62C` | **SetLightDirection / SetRimLightDirection / SetEyeHighlightColor "只记不写"**。原生 `Materials__SetLightDirection@0x1c1dc8c` 与 `Materials__SetRimLightDirection@0x1c1db28` 都是**遍历材质列表（a1+304）→ `sub_7073AFC(mat, propId, x,y,z, 0)` 的真实材质写**：`SetLightDirection` propId = `off_96FC470[23]+36`，`SetRimLightDirection` propId = `+40` 两个不同的属性 ID。移植在 `Materials.cs` 中这两个 setter 只更新缓存字段（注释" UNKNOWN(native 0x1C1DC8C): not decompiled in B5; recorded only"）——**注记已过时：b5 反编译存在**。Eye 高亮链同理（0x1C1F62C 未解，但 0x1C10434 → 0x1C1F390→0x1C1F62C 结构在 drawer decomp 里有引用）。影响：灯方向/rim/眼高亮 实际**不会到达材质**，rim 高光静止。 | 把这两个 setter 改为"记录 + 立刻对 outline/material 列表 SetVector(mat, propId, x,y,z,0)"。propId 数值仍未知（见 C-1 的 cctor 地址），可先在移植里以 material.HasProperty 从候选集解析或按 cctor 反编译落地。 |
| B-3 | `CharacterMaterialsNative.cs:526,570,580` | `0x1C1DAC0`(SetIdolColor state)、`0x1C1DB00`(SetMonoColorRatio state)、`0x1C1DE04`(SetSpotlightColor state) | **数值型 color 系 setters 的状态 half 全对**（三处各自 与 b5 反编译逐字段一致），但移植的 **`TryApplyAll()` frag into 材质是本地近似，不等同原生**：原生实际只把这些值挂到 mean-dirty 标志（`+76/+116/+120/+172` 等），真正的材质半边走 `UpdateProperties 0x1C2308C`（未反编译）。移植以本地 `sub_7073AFC`-样式直接写，会绕过原生的 `PassiveProperty` 门 / `UnsetDirty 0x1C2341C` 序列。后果限用于同一帧的不同 `Set*` 顺序：原生约"最后一次写为准（同帧）"，移植写三次可能造成 1 帧的多色闪烁，且 _Blend 属性时间序 ≠ 原生。 | 保持 state half 与原生一致的路径，但把 `TryApplyAll()` 干净改为**帧末一次性应用**（或留到 UpdateProperties 0x1C2308C 反编译后再写）：对每个材料在 PostLateUpdate 扇出一次，不再逐步写。 |
| B-4 | `SwayManagerNative.cs:380-389` | `0x1C81F68` | **GetWind 的全局门条件被写反了**。原生：`sub_35D9C14()` 返回 true（全局 CharacterManager active）→ factor = **1.3**，返回 false → factor = (Time.timeScale-1)*0.3+1（`0x1c81f68:LABEL_21` vs `LABEL_23`）。移植：`GlobalSwayActive() ? timeScale公式 : 1.3f` —— **两个方向都倒了**。影响：Spike 无风源时静默（winds 空，返回 zero），一旦有 ISwayWindNative（观众席/舞台风）就与原生系数相反。 | 翻回头两行：`factor = GlobalSwayActive() ? 1.3f : (Time.timeScale - 1f) * 0.3f + 1f;` |
| B-5 | `NativeMotionDriver.cs:164-166,206` | （原生扣 0x1EDD228 时序） | **载入后立刻 `ApplyFrame()` 打帧 0**。原生 DanceMotionPlayer 在首次 Execute（0x1EDD228）之前**不落任何 pose**（绑定姿势先出现一帧）；移植为了"避免绑姿势闪帧"在 Load 里提前 Solve+SetResult 一次。差异：以绑定姿势静止姿态的 EDL 头帧会被跳过，外观上丢一帧对齐状态（cos 或切换动画时可见）。 | 删除载入路径的 ApplyFrame()，或加开关默认关；只要保证与原生一样"首次 Execute 之后才落帧"。 |
| B-6 | `CharacterImasMotionNative.cs:204-214` | （0x37EC598 无关的 Enum.Parse 行为） | **ParseEnum 软化崩溃**。原生 `Enum.Parse` 遇到未知字符串会抛 `ArgumentException`，移植改为 log + fallback=0（None）。数据资产合法时不会命中，但原生如遇可疑数据/扩展枚举值会早期崩，移植会**静默采零朝向** — 这是"自行改写原生行为"的墨守成规处之一。 | 改成与原生一致的抛出并在**载入期**就抛（用户可拿到原始栈），或落到 ADR-0033 数据缺省约定（но行为不得静默）。 |
| B-7 | `EyeTrackingNative.cs:299-310`（Init） | `0x379BF80`（EyeTracking.Init） | **rendEye 找不到时不再 NRE**。原生在 `rendEye` 解析失败路径会直接解引用 null（伪造崩溃）；移植改为 `GetComponent<Renderer>()` 兜底（注释自认 "integration deviation in the notes"）。Editor/viewer 环境无生产数据守护，风险低，但这是"没老实按原作来"的一处。 | 按原作还原：`rendEye` 为 null 时不兜底（要崩就崩）；若不能崩，则改为在 Bind 期 log 一次性与 ADR-0033 数据缺省路径合流，行为分叉必须在运行时显式可见。 |
| B-8 | `JointBodyHeadAssemblyNative.cs:228-240`（TopOr） | `0x1C646C0/0x1C646DC` | **headTop/bodyTop 的 NRE 消除**。原生 `GetHeadModelTop/GetBodyModelTop` 在 jb+0xB8/+0xC0 未解析时直接 NRE；移植加 `TopOr(..., fallback)` 用 bundle 根节点兜底（注释自标 "+ UNKNOWN deviation note"）。**后果**：jbh.Initialize 未完整跑时（静默缺 body/head 模型节点），移植继续工作而原生早崩—遮蔽了一个装配缺陷信号。 | 采纳 RunPostInitialize 已有的 warning 分支为退出路径，不再用 root 兜底（让崩溃路径与原生一致）。 |
| B-9 | `SwayManagerNative.cs:102-116` & `SwayColliderNative.cs:81-88` | `0x1C80DD8`（SwayManager.Awake，未反编译） | **Awake 的 BODY_SCALE/BASE 非原生等你**。原生 Awake 只 `parent.Find("BodyScale")`、若 active 为 false 时原生才走 fallback 路径（从 decomp 注释推断，见 C-2）；移植直接再加 `BODY_SCALE` / `BASE` 两个名字的查找并把 BodyScale==null 时互相回填，然后在 Awake 后手动 `FindChild(root,...)`。移植的 Awake 是**行为扩展**而非等价，可能让原生在未就绪的模型下无声地跑错（把 BASE 当 BodyScale，进而影响 SwayBone radius/scale 计算）。 | 等 C-2 反编译后：严格按 native "BodyScale → Base 的回填顺序"逐分支复刻；把当前的 "BODY_SCALE/BASE + FindChild(transform.root)" 串按 ADR-0033 单元测试"每分支给出与 native 相同的 Transform 指针"。 |
| B-10 | `DropShadowNative.cs:55-58,105-129` | `0x357E268`（hook only） | **shadow 材质预处理没接**。原生 `sub_357E268` 在**每次**阶段的 body/head/drop-shadow 模型对每个子 Renderer 应用材质/可见性清理（Stop hitch？反编译存在 `/tmp/ida-decomp/f_357e268.c`）；移植只留 `applyShadowMaterials` 静态 hook，未实现 — shadow prefabs 保留出厂材质。构建 Live 未联接（B5 收尾），作用域只对当前红帧。 | 按 decomp 落地：列出的 subcalls 均有 helper decomp（off_96FD998 静态 + sub_43ABD8C `GetComponentsInChildren` …），可复刻"遍历 Renderer 应用材质"循环。或把 hook 挂到 JBH Post_1 与 DropShadow.InfoStructured 后单次调用点补齐。 |
| B-11 | `CharacterSoulNative.cs:141-160` (motif) | `0x1C352B0` + `0x1C390A4` | **motif 短名映射是"推演"而不是反编译文本**。移植注释自认 p→Princess / f→Fairy / a→Angel / e→Etc 是 elimination 推理（literal 槽不可静态解析）；这是"没老实按原作函数"的**数据**层等价 — `ShortNameToCharacterMotif` 表面行为依赖 `Array.IndexOf` 次序。原生的 literal 槽次序未验证，风险是遇到未枚举 motif 名时 silently None。 | 运行时 dump 一条 soul 数据（DrawerJbhProbe "Soul: motif table"）逐字对照长短名后固化 SetMotifShortNames；在 LongNameToXxx 侧加入 未命中日志与 ADR-0033 数据缺省路径。 |

> 以上 B 的地址 / 反编译都可在 `/tmp/ida-decomp*` 复现（文件名在行尾证据列）。

---

## 已知疑点的裁定（用户/Lead 特指的 5 项）

### 1) SwayManagerNative.Init 的 "deepest manager" vs 原生 `0x1C814AC` — **A（等价；原 DEVIATION 注记查加之性误读）**

`f_1c814ac.c` 逐行读出的原生递归规则**不是**"把每个 sway 骨都收进 root 与两 manager"：
- 子 transform 有 `qword_9784780`（**SwayManager** 类 token / 第一检查）→ 子树**不再递渗**（`goto LABEL_8`，跳过分支）；
- 有 `qword_9784770`（SwayBone）→ `sub_1C70F50`(bone, manager) 初始化 + 追加进 a3 列表，**不继续递**；
- 两者皆无 → 递归下降。

即**原生本身就是"最浅 manager 停"，也就是 bone 归最深上一层 manager**（见 0x1C71B8C `SwayBone__GetParentSwayManager` 的同型爬升）。移植实现的"deepest manager 路径最长字串前缀匹配"（`SwayManagerNative.cs:629-642` + `SwayFileNative.cs:265-280`）与原生监督整合**同构同顺序**（管理序列 body→head、bone 序列同以 att achment order）。修建议：将原 DEVIATION 注记改写为 A（加 `0x1C814AC f_1c814ac.c` 引），删除"to be validated with a runtime probe"改为可反编译验证声明。
- 注意一小不同：native 的 sideLink2 back-pointer**在同一个循环里写**（`*(_QWORD *)(sideLink + 88) = self`），移植拆成第二遍循环。因为两边都在同一条 assigned 顺序上写，上、下位语义一致（多次加目标 bone 时"后写的赢"两边也一致）。A。

### 2) SwayBoneNative.CalcRotate 的 limitAngle 分支 vs `0x1C72220` — **限角支路 A；非限角支路 B（即上表 B-1）**

- 限角支路：`atan2(degree)` 的 yaw/pitch 计算、clamp 到 `+100/+104/+108/+112`（minY/maxY/minZ/maxZ）、`Quaternion.Euler(0,y,z)` 合成 `initial * Euler`、**仅在 clamp 时**重算 curTip+prevTip —— 与 f_1c72220 逐行一致（含 `v25 is clamp-flag` / `sub_70BC63C(tipTrs, tipLocal+colliderOffset)`）。
- 非限角支路：`// UNKNOWN(native 0x1C72220): quaternion operands hidden; mirrored from SwayBoneMT 0x1C69F04` 的**注意写的是组合，漏写了 bind reset** → **B-1**。
- 另一差异：移植的限角分支之外还缺了原生 `sub_70BF458(trs, initial)` 的**入口共布**（mt 同）。这就是胸衣/bone 朝向差的根因候选。

### 3) SwayMove `0x1C6867C` — **已反编译（`/tmp/ida-decomp/SwayBoneMT__SwayMove.c` + scalar `SwayBone__SwayMove.c@0x1C72964`），非 C**

- scalar 版（`0x1C72964`）逐项核对：
  - transBack 时 curTip/prevTip 关 — native：`mgr+261` 非 0 → v30=0（followRate=0），等价 **A**；
  - **wing limit ±4.0 步进**（`+27/+28` MoveTowards，min/max target） — 移植 `WingMoveTowards(minZAngle, minZAngleTgt, WING_SPEED)`，需要 `WING_SPEED == 4.0`（每帧 ±4.0 度）与 gate `*((_BYTE*)v2+61)!=1 || (*(_BYTE*)v2+62&1)!=0`（isWing && !workOnCharacterViewer）。移植 gate 同。**A**（前提 SwayConstants.WING_SPEED=4.0 — 复核值）。
  - follow 源链（swayFollowRate → mgr FollowSW → fallFollow/ followForce） — 原生：`rate==0 → followForce or fallFollow`；移植同名同序 **A**（已读 `LABEL_33/LABEL_44`）；
  - `ratio = dt/0.016f`、`invRatioSq=1/ratioSq` — 原生一致；
  - antiFold/风/vecs1/damper/integrate 语义 order 对上（已读 SwayBone__SwayMove 后半）**A**。
  - **B 候补**（标 C 的嫌疑点）：移植 SwayMove 的 skirt barrier（`skirtNormal`/`skirtDir`）在**未经 UseBindDir 判定**（也即 useBindDir 分支）下无差。原生 InitSub 或 SwayMove 的 useBindDir 不在反编译里直读，不放 B，待补 `0x1C711A4` 与 `0x1C72964` 的 open 区间 compare 后定级（归入 C-3）。
- MT SwayMove（`0x1C6867C`）是 Burst SIMD 重排，常量+公式在 scalar 版已复刻；移植走串行路径（ADR-0033 §3 允许）→ 逻辑等价。

### 4) CharacterBootstrap 装配顺序 vs `JointBodyHead.Initialize 0x1C633CC` — **总体 A（顺序同）；有一处 B + 两处 C**

原生 0x1C633CC 序列（b5 `JBH__Initialize@0x1c633cc.c` + 状态机 0x1C66DB0）：
```
Post_1 Mart(Clear optionDisplayDict → bodyMesh/headMesh Find → SetBodyMeshs/SetHeadMeshs
            → GetBoneRot(body.transform) → reparent head side → BodyScale bookkeeping
            → calcBone GetComponent → 材质 baseline 重置 → eye-material cheek offsets
            → EyeTracking + FaceCtrl 创建 → dshadow GetComponent)
Init tail: DropShadow.SetShadowMode(shadow, ABShadow)（0x379A228）
Post_2: AtamaY/EyesY（0x1C63AF8）→ is_creation_succeeded = 1（+0x138）
```
移植（`CharacterBootstrap.Start`）顺序：CalcBone(Awake) → FaceCtrlNative → SwayRigNative → JointBodyHeadNative + Assembly.RunPostInitialize → Drawer.Create → Soul table → EyeTracking+DropShadow → Motion.

- **一致点**（A）：SetBodyMeshs/SetHeadMeshs/GetBoneRot/AddPositionNode/Initialize_Post_2 的顺序和 RunPostInitialize 的语句块一致（有守卫的补齐）。
- **偏差点 B-12**（并进 B 表）: 原生在 **Post_1 尾段就创建了 FaceCtrl + EyeTracking**（两者都在 0x1C66DB0 的状态机内），移植在 JBH **之前**就把 FaceCtrlNative 绑到本体上。因为 FaceCtrlNative 顶级的 `Update()` 也要先 Prepare（`autoAction = true`），**首帧 Face 光滑轨迹比原生早 tick 一次**（更精确：原生首帧才创建 FaceCtrl；移植在同一个 Unity 帧 Start 里更早做完同量 `Action()`）。第一帧表情的转换时间被提前 1 tick（巨大 ~ 16ms），肉眼难辨，但它是"装配顺序与原生不同"。建议把 FaceCtrl 的 `EnsureNativeState` 保持在 `Start`，`autoAction` 改为**从 JBH Assembly 的 Post_1 完成后的下帧**开始，或从 bootstrap 里 `faceCtrl.autoAction = false;` 由手动 action 顺序 tick，以 native 时序对齐。

- 次不同：原生"EyeTracking 创建 → FaceCtrl 创建"在**同一 Post_1** 里、`dshadow SetShadowMode` 在 **Init tail**；移植的 EyeTracking 在 `BindNativeB4` **晚于** Drawer，DropShadow 最后。这属于"次序与原生 frame 中不同帧（Start vs Post_1 coroutine）"，但它们的 GL 侧数据 power-up 同帧完成，可归为"格式差异"，渲染无差。**A**（跟 B-12 一起注明）。
- C：BodyScale/skin 内部材质 baseline 重置的具体数值字段（`+136` 后 block）、eye-material cheek offsets 的 prop name — 原生状态机 literal 未解，list 见 C-4。

### 5) NativeMotionDriver 驱动顺序 vs `DanceMotionPlayer 0x1EDD228` — **A 在被移植的核心顺序；C 有一处**

- 移植头注释按 dump.cs 抽出 `Execute(0x1EDD17C) → execute_async_imo(0x1EDD228) → imo_player.UpdateTime(0) → SolveCurves(flag) → SolveOptionalCurves → post_execute_sync_imo(0x1EDD380) → SetResultToTransforms → hand IK`。核对到反编译可见的部分：PlayerDance__UpdateTime(0x37EDF1C) / SolveCurves(0x37EE384) / SolveOptionalCurves / SetResultToTransforms(0x37EE99C) 均在 /tmp/ida-decomp — 移植的调用顺序与 decomp 的**对象方法层**一致（UpdateTime → SolveCurves → optional → SetResult）。**A**（对象层）。
- **C**：`0x1EDD228` 本体未反编译（execute_async_imo 的**作业调度/async 边界**），以及 post_execute_sync_imo(0x1EDD380) 与 hand-IK 的 opt_results 调用时序；移植把 post 层合进同一 `Update()`。**应在同一帧内因为在 Update 中没有第二个消费者**，**结论按 ADR-0033 §3"async → 串行"是契约内替换**，但 hand-IK 的存在意味着次序未完全结算。加入 C 清单（见 C-5）。
- B-5（见上）属此疑点之一（预 ApplyFrame）。

---

## A 类（确认等价）— 抽样核对到反编译的关键项

（详细判定过程见上文各节；每条证据在括号内给反编译文件）

| 项 | 文件:行 | 原生地址 | 结论 |
|----|---------|----------|------|
| A-1 | `CalcBoneNative.cs:283-298` | `0x1C5F624` (Awake) | `__rot` + axis=='z' → SLERP, tx=1.0；t=param_value — 与 decomp `Awake` 中 `v96==2 → v80=1.0, v81=param_value, v82=0`（`CalcBone__Awake.c:663-697`）一致 **A** |
| A-2 | `CalcBoneNative.cs:15-24` | 多 | `List/Dictionary/Transform/plain float ← TransformAccess/NativeArray` 是 ADR-0033 §3 性能层替换；无公式/常量/分支变化 **A** |
| A-3 | `SwayManagerNative.cs:340-378` (ExecuteUpdate 四趟) | `0x1C81CD8` | 与 `SwayManager__ExecuteUpdate.c` 的四个 while 逐项等价（CalcSideLineDistance→CalcAntiFoldForce→SwayMove→SwayHit；SwayHit 对非 hitTwice 一遍，hitTwice 再一遍 — 与子件 +396 gate 一致） **A** |
| A-4 | `SwayManagerNative.cs:511-556` (ExecuteSerial) | 同上 | 同上（Burst 链注释里已列）**A** |
| A-5 | `SwayManagerNative.cs:262-296` (PrepareUpdate) | `0x1C81A08` | localDelta 累积、<1/60 early-return、`localDelta -= 0.01666` + `>1→0`、m_delta_time 平滑（`Time.deltaTime - this) * deltaTime`，helper `mat_70b9bac.c` 确认 sub_70B9BAC=Time.get_deltaTime）、clamp [1/60, 0.025] **A**（h/cc 一项见 C） |
| A-6 | `SwayManagerNative.cs:165-232` (Init) | `0x1C810CC` | sideLink resolve + sideLink2 back-pointer 单/双循环序同；UpdateParameters 收尾与 native Init 尾段（`*(bone+132/136/140/144..156) ← mgr+36..56`，gated on `refParam==0`）同型 **A** |
| A-7 | `SwayBoneNative.cs:462-489` (FinishRotate) | `0x1C720E0` | native `PostUpdate` 遍历同型（`SwayManager__PostUpdate.c`）+ FinishRotate 归一 tip 长度→ CalcRotate **A**。`tidlected TipPos` 后 Normalize/length、跳过对最后一位 — 需原 sub_1C720E0 decomp 复核（在列 C-6 备书，风险低） |
| A-8 | `SwayBoneNative.cs:623-703` (SwayMove) | `0x1C72964`/`0x1C6867C` | 见上节 3 **A**（wing speed 常量一处 verify） |
| A-9 | `SwayBoneNative.cs:729-763` (SwayHit) | `0x1C732E8`/`0x1C75380` | 点 pass（deepest-push）+ useLinkHit 追加会与 0x1C75380 复刻方式读过；执行顺序与原生 ExecuteUpdate 四趟 place 一致 **A**（0x1C732E8 的 useLinkHit 调用点也是 C 风格，初判 A，见 C-7） |
| A-10 | `SwayBoneNative.cs:167-180` (RefreshCollidersEnable) | — | strip 检查 |
| A-11 | `FaceCtrlNative.cs:229-247` (SetFace / SetFaceDirect(0,0)) | `0x379F5F0`/`0x379F674` | 原生 SetFace 里 cur==0 的 no-op 路径 + SetFaceDirect 直接写 cur/last=`0` + `UpdateFace` — 与 decomp 完全同 **A** |
| A-12 | `FaceCtrlNative.cs:265-320` (Module 顺序) | `0x379FA48` (Action) | facial→eye→muteLip→lip→cheek Progress 顺序 + UpdateFace + CheekUpdate 的 cheek 二次行动 — 与 `FaceCtrl__Action.c` 一致 **A**（缺 decomp 与"cheek 从 mgr 体质"一次较深的 0x379FA48 粒度比较；标注为 A 的理由是仅 module 顺序已确认独立看干症状） |
| A-13 | `CharacterMaterialsNative.cs:763-800` (ApplyFromSoul diklatance set) | `0x1C36A88/0x1C36590/0x1C36E98/0x1C3728C/0x1C37680` | soul column→Set* 的落位形 interview 与 `SDC__*` 分表 1:1（b5）**A**（apply half 见 B-3） |
| A-14 | `CharacterMaterialsNative.cs:620-660` (SetSpotlightColor 記录) | `0x1C1DE04` | " +172 write via sub_4D42904(packet[blend,int, rgb, a]) +196=1+…sub_4D42A8C" 与 decomp 一致 **A**（apply half 是 B-3 的一环） |
| A-15 | `CharacterMaterialsNative.cs:663-780` (SetCheekRedden family) | `0x1C1DFC4/0x1C1E170/0x1C1E18C/0x1C1DFF4` | state half (enable→derived from intensity>0；+168/+169 gate；强度放下 +164 无条件) 与 decomp 一致；ToMaterial half 的 "针对 propId +76/+68 两级访问 + `sub_357F278(mat, id, qword_9807DF8-val, a2>0)` + sub_70739FC(mat, id, a2)" 在移植 TryApplyAll 中**布尔格列入安排** — 语义 need review（推到 B-3 之外的） **A**（state）+** Apply half 重点修复** |
| A-16 | `CharacterSoulNative.cs:337-349` (create-common 12 keel) | `0x3799630` | "12洗 + 0x44 不动" 的怪癖保留 **A** |
| A-17 | `CharacterSoulNative.cs:186-201` (float parser pin culture) | — | 表不完全精确（Single.TryParse 用 InvariantCulture），是性能层 parse-arg 差异而非公式差异 **A**（风险：原生使用 CurrentCulture 变间隔行为 — Very long-lived data a single binary comment culture 差异可行） |
| A-18 | `SwayColliderNative.cs:170-196` (ExecUpdate) | `0x1C73FE8` | m_exec_ok 单次置位 + scale/ SetScale 均刷新（ InitSub/AdjustScaleLine 原生只刷 m_scale）— 报告自注 "minor deviation"（在"参数不随时间变"前提下等价）**A**（documented） |
| A-19 | `SwayFileNative.cs:265-280` (ManagerFor / DeepestManagerPath) | `0x1C814AC`/`0x1C71B8C` | 最深 manager 前缀匹配 — **等价**（见疑点 1）**A**，其余 side link 骨 `DeepestManagerPath(bone.data.path) != entry.path` 与 native 的"子树 SwayManager 停"同值异型 **A** |
| A-20 | `TransitionModuleNative.cs:30-47` | — | 纯数据类（四个 float + 两个 int）无行为 **A** |
| A-21 | `FaceLipParamNative.cs` 着重（静态表位） | `0x379E94C` | lip 表 raw 0..100 传递（UpdateFace eye scale *0.01 唯一 rescale）**A**（与已导出的注释一致） |
| A-22 | `CharacterDrawerNative.cs` 收口多数 Set* 包装 | b5 | 若干（SetCheekMono/SetOutlineWidth/SetStencilRef/SetMonoColorRatio 等）与 b5 反编译 一一匹配 — **A**（唯一的"not in B5"注记里 SetLightDirection/SetRimLightDirection 其实**有** b5 反编译 — 纠正到 B-2） |

---

## C 类（无法判定 — 缺反编译/需运行时探针）与需要的地址

### C-摘要（27 个标注点，聚合为以下 8 个"需要补"的块）

| # | 需要什么 | 地址清单 | 涉及移植点 |
|---|----------|----------|------------|
| **C-1** | **CharacterMaterials cctor（property-id 表 off_96FC470 初始器）** & `UpdateProperties 0x1C2308C` / `UnsetDirty 0x1C2341C` / `apply_color 0x1C21158` | `0x1C1C…`（cctor），`0x1C2308C`，`0x1C2341C`，`0x1C21158`，`0x1C1E49C` (blink2blend_all) | B-2/B-3 的 propId 数值与 apply 时序；CharacterMaterialsNative.cs multiple UNKNOWN 备注 |
| **C-2** | **SwayManager.Awake 0x1C80DD8** 和 **SwayCollider.Awake 0x1C73E34** 的 Find 回填顺序 | `0x1C80DD8`，`0x1C73E34` | B-9 |
| **C-3** | **SwayBone.InitSub 0x1C711A4**（半径 radius 的 bodyScale 门）与 **useBindDir 分支** | `0x1C711A4`（已有 Init 0x1C71198/0x1C70DB0 部分引用），`0x1C71940`（AdjustColliderOffset 累积 vs 赋值现状）、`0x1C72660` | SwayBoneNative Init/Attach 的一部分（radius= BodyScaleScale()*n_radius — 关于 useBindDir 的细节；需要精确边界条件） |
| **C-4** | JBH Post_1 状态机（0x1C66DB0）里的 literal 槽（serchChild 名称、材质名、feature doc）与 BodyScale bookkeeping | `0x1C66DB0`（已有部分 decomp），`0x1C64F94`，`0x1C65524`，`0x1C64C18` slots | JointBodyHeadNative.cs 的 UNKNOWN literal；死于 Mach-O chained fixups，**静态不可解**，需运行时 probe 或 dump.cs/literal 派生（live mega-cat 的 dump 也可提供） |
| **C-5** | DanceMotionPlayer execute_async_imo 0x1EDD228 / post_execute_sync_imo 0x1EDD380 / hand-IK 消費者 | `0x1EDD228`，`0x1EDD380`，`0x1EDD2B8`(PostExecuteSync?) | B-5 撤销后的调度边界 |
| **C-6** | SwayBone.FinishRotate **0x1C720E0** 具体长度核对（与 `0x1C720E0` decomp缺失但引用存在于注释） — 附看 `0x1C720E0` | `0x1C720E0` | SwayBoneNative.FinishRotate/Normalize 具体基数 |
| **C-7** | SwayBone.SwayHit 0x1C732E8（Scalar 带 useLinkHit 的 connector） — 现移植 C 面板 useLinkHit"deepest wins"凭的是 research §3.3.1 record | `0x1C732E8`（已有 SwayBone__SwayHit.c — 已在 decomp 目录），`0x1C75380`（CheckSideLine） | SwayBoneNative.SwayHit — 需要 decomp 与 "scalar only shows point pass" 的对比一列，可能改判 |
| **C-8** | Off-case 单引量：DropShadow 的 `0x9705120`(ан告诉 stage manager), `0x9709770`(+432), `0x970CCF8` + static vectors, `0x357E268` 的材质终点、LiveInfoParams `0x379ACC8/cctor` … | `0x9705120`，`0x9709770`，`0x970CCF8`，`0x357E268`，`0x969…`(LiveInfoParams cctor), `0x36D0140..0x36D02C4`（AppmasVector screenRatio），EyeTrackingNative 其余 UNKNOWN(tag types 0/6/7 的 Idol index)，`0x9704BE0` | DropShadowNative / EyeTrackingNative 的多数 UNKNOWN（data 理由）。`0x357E268` 已反编译（f_357e268.c），照 B-10 落地即可 |

### C 需要的清单 (合并后给 Lead 的完整列表)

1. "nt" Speech-to-State id: `0x1C1CF?…` — CharacterMaterials cctor / 列字段 slot 36/40 的初始值（可从 IDA Read String via Sub Data）。
2. apply 类：`0x1C2308C` `0x1C21158` `0x1C21F9C` `0x1C1D874` `0x1C1D9D0` `0x1C1E49C` `0x1C2341C` (Materials)
3. Awake/fetch 类：`0x1C80DD8`（SwayManager.Awake）`0x1C73E34`（SwayCollider.Awake）
4. SwayBone 补齐：`0x1C720E0` `0x1C71D80` `0x1C72660` `0x1C727B4` `0x1C7288C` `0x1C732E8`(点半开) `0x1C736B8`(已有) `0x1C71D80`
5. Motion 框架：`0x1EDD228` `0x1EDD380` `0x1EDD2B8` `0x37ECCE4`
6. JBH Post_1：literal slots `0x1C66DB0` 已部分复 — 需要 `qword_97F3C08 / qword_97E2B40 / qword_982B5D0` 的 literal 派生（runtime probe / dump.cs `<PrivateImplementationDetails>`）
7. LiveInfoParams / Imas.AppmasVector：`0x379ACC8`（候选 cctor）`0x36D0140` `0x36D02C4`
8. `0x970CCF8` class token 目标 & 静态 Vector3 (+0/+4/+8 与 +0xC)（SwayManager.PrepareUpdate & CalcBone Rotate & EyeUpdate 同用；h/cc 重置值非显式 0）

---

## 未标注但在本次审计里发现的偏差（扩面）

1. **B-4 GetWind 的 reverse**（见上） — 没有标注，纯审计发现。
2. **B-3 TryApplyAll 的 apply-half** —— 注释列举是"UNKNOWN"而非"我们自定义"；实际移植**不等同** native 的 `UpdateProperties` 时序（uniform per material 的被动式 dirty/制定）。
3. **B-11 motif 表**是"推理"而非"反编译文本"。
4. **B-5/B-7/B-8**都是"防 NRE / �clado 数据差"的封装类偏差（原生会崩）
5. **Constrain 版本参考**：`SwayBoneNative.Awake` 复用 line 217-222 — 注释里说明"spike binds after bind pose…"伪 best-effort 注。实际 `0x1C70DB0`（SwayBone.Init(jbh)）不在 /tmp/ida-decomp — 但相关链接 `0x1C627AC`（JBH GetInitRot）作为重围 — 复核到已有 b5 GetInitRot decomp（参考 `JBH__GetInitRot@0x1c627ac.c`）。**A**（按 "bindRotationProvider 为 null 时用当前 local 旋转" 的近似），风险：**第一帧的 early-preview 旋转差一帧** — 补做 C 后若 needmever 结果即可全部卡定。

---

## 工具注记

- 本次 IDA headless 通道失败复现：`open_database(rc=1)` & `get_segm_qty()=0`。历史跑（`/tmp/calcbone-ida2.log`、`b5.log`）都显示 OPEN_RC 0。`UnityFramework.i64` 被**改名**为 `uf-corrupt.i64`（2,282,560,462 字节、mtime 11-07 14:43），`/Users/jacklin/mltd-work/ida/` 目录下不再有 `UnityFramework.i64`。上一次"已分析完"的库即打开失败，本次判定仅使用 `/tmp/ida-decomp*` 已导出的反编译与 `dump.cs`。如需 C-1/C-2/C-3 的 idc 值，重建 idb 后重新跑 `dumpMat.cctor`、`dumpSwayBone` 系列。
- 所有地址 helpful notation：`0x1C…`/`0x37…` 是 IDA linear（=dump.cs RVA）。

---

## 修复优先级落点

1. **B-1**（CalcRotate 非限角分支缺 bind 重置）— 1 行修复，影响最广、最直接对应"胸衣/裙子跳"。
2. **B-2**（LightDirection/RimLightDirection"只记不写"）— 材质区 1 处；propId 需要 C-1 的 cctor 反编译才可 UT。
3. **B-3**（Materials apply-half far to native UpdateProperties）— 改造 TryApplyAll 与帧末统一。
4. **B-4**（GetWind 反转）— 1 行，但行为无风时不触发，可延摊。
5. **B-5/B-6/B-7/B-8**（防变体 & 触发数据缺省路） 一— 一组 2–10 行改动。
6. **B-9/B-10/B-11** 与 C-2/C-4 等（数据依赖）在 C-1/C-2 反编译后即可落地。

完工，报告原始唯一（本次 sentinel file only）。
