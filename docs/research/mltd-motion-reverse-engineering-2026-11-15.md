# MLTD 姿势/动作播放：原游戏实现逆向记录（2026-11-15）

目的：剧情剧场此前用「猜测」的方式播放姿势剪辑（把 `_act` 当一次性、冻结在峰值帧、0.45s 交叉淡入），
观感是「每个动作开头抽搐一段时间然后突然闪现到动作后半阶段」。这份记录把原游戏
**真实的姿势状态机**从二进制与缓存资产里挖出来，播放逻辑按它重写，不再自创启发式。

## 1. 结论速览

原游戏的立绘姿势不是「一个 clip 换一个 clip 地 cross-fade」，而是**状态机 + 成组的姿势剪辑**：

| 状态（占位 clip 名 `dmy_com_<pose>_<suffix>`） | 对应我们导出的 clip | 语义 |
| --- | --- | --- |
| `dmy_com_<pose>_start` | `<clip>_str` | 进入姿势（一次性） |
| `dmy_com_<pose>_loop` | `<clip>_lop` | 姿势循环（唯一真循环） |
| `dmy_com_<pose>_end` | `<clip>_end` | 离开姿势（一次性，播完回 idle） |
| `dmy_com_<pose>_yes` / `_no` | `<clip>_yes` / `<clip>_noo` | 姿势内点头/摇头（一次性） |
| `dmy_com_<pose>_action` | `<clip>_act` | 动作型姿势（一次性，播完回 idle） |
| `dmy_com_<pose>_switch` | `<clip>_swt` | 姿势间切换变体 |
| `dmy_com_p01` | `cut_01z_lop`（角色 `18y_lop` 亦可） | 基础站立待机 |
| `dmy_com_p01_yes` / `_no` | 待机点头/摇头 | — |

状态机里的 transition **全部 `exitTime = 1.0`、`duration = 0`**：

- `_start → _loop`（进入动画播完自动接循环）
- `_yes / _no / _switch → _loop`（一次性动作播完回循环）
- `_end → idle`、`_action → idle`

因此「动作之间不 blend」是设计本身：平滑靠 `_start` / `_end` 剪辑自身从/到中立项的编排，
零时长过渡在剪辑边界上不会跳。代码里唯一给 `PlayAnimation` 非零淡入的地方是**回到 idle**（0.1s）。

## 2. 证据来源

### 2.1 二进制与元数据

游戏包（PlayCover 内部）：

- 可执行主体（il2cpp）：`~/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0310.app/Frameworks/UnityFramework.framework/UnityFramework`（165,765,984 B，arm64 dylib）
- 元数据：同 app 的 `Data/Managed/Metadata/global-metadata.dat`（34,175,268 B）

解析（二进制 2026-11-15 更新过，旧 dump 的 CodeRegistration 已失效，需重跑）：

```bash
cd /tmp
dotnet /tmp/ild/Il2CppDumper.dll \
  "<app>/Frameworks/UnityFramework.framework/UnityFramework" \
  "<app>/Data/Managed/Metadata/global-metadata.dat" /tmp/ildout2
# Metadata Version: 31 / Il2Cpp Version: 31
# CodeRegistration : 8f13e60 / MetadataRegistration : 9199070
# 产物（落当前目录）：dump.cs 71,289,054 B / il2cpp.h / script.json / stringliteral.json
```

Mach-O 的 `__TEXT` 是 `vmaddr 0x0 / fileoff 0x0`，所以 **il2cpp RVA == 文件偏移**，
`xcrun llvm-objdump --disassemble --arch=arm64 --start-address=<RVA> --stop-address=<RVA+n> <UnityFramework>`
（或 capstone）可以直接反汇编任意方法。

### 2.2 姿势机类（`dump.cs`）

`Imas.CharacterActorCommu : CharacterActorBase`（TypeDefIndex 9765）保存姿势状态：

- 常量：`s_idle_pose_name = "p01"`、`s_private_pose_name = "p18"`、`s_private_state_name = "priv00"`、
  `s_idle_pose_name_volley = "p81"`、`s_idle_pose_name_salmon = "p101"`、`s_costume_pose_name = "a19"`。
- 状态字段：`step`(+0x188)、`current_pose`(+0x1A8)、`is_pose_changing`(+0x1B0)、`next_poses`(+0x1B8)、`pose_infos`(+0x200)。
- 关键方法（RVA）：
  - `SetPose(string poseName, bool loopDirect = false)` **0x3823BFC**
  - `get_loop_state_name(PoseInfo)` **0x382E754**：非私有姿势返回 `p.id`，`p01` 返回 `"p01.loop"`；私有姿势 `private_pose_type == 1` 返回 `"priv00"`。
  - `check_force_loop(PoseInfo)` 0x382E67C：要求 `has_loop`、`status == 1`、`_anim_reach_end_anim_clip.name == current_clip_name` 才 `LoopCurrentAnimation()`。
  - `force_reset_to_idle_pose()` 0x38244B8：`PlayAnimation("p01", 0f, 0f)` 后清队列、`ResetSway`。
  - `set_clip_to_over_ctrl(pose_name, postfix, over_name, bundle)` 0x3830D5C：运行时把占位 `dmy_com_*` clip 覆盖成真实 `com_*` clip。
  - 嵌套类型 `PoseInfo`：`id / number / group / has_loop(+0x40) / has_yes_no / is_action(+0x42) / is_private(+0x58) / private_pose_type(+0x5C) …`；
    `STEP { None=-1, Pose=0, YesNo=1, ComeIn=2, GoOut=3, Private=4, Waiting=5 }`。
- `Imas.CharacterActorBase`（9741）：
  - `PlayAnimation(string state_name, float blend_duration, float start_time = 0)` **0x3820DD0**
  - `LoopCurrentAnimation()` 0x3821200、`IsCurrentAnimationEnded()` 0x38212B0、`SetAnimationState(state)` 0x3820CC4、
    `override_animation(org_name, clip)` 0x3821CC4
  - 字段：`current_state_name`(+0xC8)、`current_clip_name`(+0xD0)、`_anim_reach_end_anim_clip`(+0xB0)、`anim_state_clip_infos`(+0xE0)。

### 2.3 剧情入口：`ADVPoseLogic.Execute()` @0x3758F28

```
CurrentCut() → cut.GetCurrentCharacter(mGameObjectName) → chr.actor
Debug.Log(Format("CUT:{0} SetPose {1} {2}", ...))
if (this.poseType == 1) SetPose(this.poseId, loopDirect: true)   // w2 = 1
else                   SetPose(this.poseId, loopDirect: false)  // w2 = 0
```

剧本 `actor_pose` 的 **arg6** 就是这个 poseType：全量 16,197 条 `actor_pose` 里 `0` 有 15,404 条、`1` 有 793 条。
`loopDirect = true` 时跳过 `_start`，直接进 `_loop`。

### 2.4 调用点与淡入常量（capstone 全量扫描）

用 capstone 扫 `__text`（`skipdata=True`，约 148 秒）得到 `PlayAnimation` 40 处调用点；姿势机相关：

- `0x382c510` / `0x382c834` / `0x382cc48` / `0x382ccd0` / `0x382d044`：`PlayAnimation(state, 0f, 0f)` —— 姿势状态瞬时切换。
- `0x382c77c` / `0x382c834`：`mov w8,#0xcccd; movk w8,#0x3dcc,lsl#16` → **0.1f**，
  即回到 idle / 进出场（`in_left`、`hako_in.` 之类）时用 **0.1s** 淡入。
- `0x382bf6c`：`PlayAnimation(req.state, req.fade_duration, req.start_time)`（`PlayAnimationRequest` 字段 +0x1F0/+0x1F4）。
- `0x382cc80`：`animator.PlayInFixedTime(state, 0, 0)`（Skip/直切）。

`SetAnimationState` 被用来“把状态名对齐到当前动画”（先 `GetCurrentAnimatorStateInfo(0).IsName(...)` 再 `SetAnimationState`），
`LoopCurrentAnimation` 用于让已播完的状态重新循环（`check_force_loop` 的落点）。

### 2.5 动画控制器资产：`AnimCtrl_Commu`

从 PlayCover 缓存里用 UnityPy 扫 861 个 chara/commu 候选 bundle，找到 44 个 `AnimatorController`，
其中姿势机用的是 **`AnimCtrl_Commu`（298 个 AnimationClip）**：

```
~/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents/Cache00/55/55affd6f2643e6b2bba8ddec59407b81ce693f8a757e786455b6463d067ef140b9c5
```

它的 clip 全是占位：`dmy_com_p01`、`dmy_com_p01_no/yes`、`dmy_com_p05_start/_loop/_end/_yes/_no`、
`dmy_com_p02_start/_loop/_end/_action`、`dmy_com_priv00_*`、`dmy_com_priv_etc01..08_*`、`dmy_com_a10_action`、
`dmy_com_in_left`、`dmy_com_run_in_front`、`dmy_com_hako_out_left` 等，共 298 个。

烘焙后的控制器（Unity 6 `ControllerConstant`）结构：

- `m_StateMachineArray[0].data.m_StateConstantArray`：305 个 state，`m_DefaultState = 0`。
- 每个 `StateConstant`：`m_Loop`（实际上全 false，循环由代码 `LoopCurrentAnimation`/`PlayInFixedTime` 维持）、
  `m_Speed`、`m_BlendTreeConstantArray[i].m_NodeArray[j].m_ClipID`（→ `AnimatorController.m_AnimationClips[idx].m_Name` 取回占位名）、
  `m_TransitionConstantArray`。
- `m_Values`（名字表）被剥离，所以状态名只能通过 `m_ClipID → clip 名` 反查。
- 全部 transition：`m_ExitTime = 1.0`、`m_TransitionDuration = 0.0`，无 condition。
  实测转换只有六类：`_start → _loop`、`_yes → _loop`、`_no → _loop`、`_switch → _loop`、`_end → dmy_com_p01`、`_action → dmy_com_p01`。

复现脚本（`~/mltd-work/venv`，UnityPy 1.25.4）：

```python
import UnityPy
p = ".../Cache00/55/55affd6f2643e6b2bba8ddec59407b81ce693f8a757e786455b6463d067ef140b9c5"
env = UnityPy.load(p)
for o in env.objects:
    if o.type.name != "AnimatorController": continue
    d = o.read(); cc = d.m_Controller
    clips = [c.read().m_Name for c in d.m_AnimationClips]
    sm = cc.m_StateMachineArray[0].data
    for sp in sm.m_StateConstantArray:
        s = sp.data
        names = {clips[np_.data.m_ClipID] for bt in s.m_BlendTreeConstantArray for np_ in bt.data.m_NodeArray}
        # names: {"dmy_com_p05_start"}; transitions: s.m_TransitionConstantArray
```

### 2.6 姿势主数据里没有 p01 / p18

`chara.commu.pose`（`~/mltd-work/chara_commu_pose_set.json`，date `2026/05/20`）的 `means` 只有
`SetName, Category, p02 … a114` 共 63 项，124 组（Sit 62 / Cool 22 / Cute 20 / Passion 20），**不含 p01、p18**。

- `p01` 是全局基础站立待机（常量 `s_idle_pose_name`）。
- `p18*` 是**私有姿势族**（`s_private_pose_name = "p18"`，状态 `priv00` / `priv_etc01..08`），
  每个角色只有 `com_<idol>_18y_*`（`18y` = 18 岁版站位），只有测试角色才有 `18a…18o` 变体。
  所以剧情里的 `p18_p / p18_s / p18_a` 应解析到该角色自己的 `18y` 剪辑族。

## 3. 我们现在的播放实现（`EidolonStandMotion.cs`）

按上述状态机对齐后的行为：

- `PlayPose(path, loopDirect)`：
  - 解析同目录下的整套剪辑：`<clip>_lop`（循环）、`_str`（进入）、`_end`（离开）、`_act`（动作型）、`_yes`/`_noo`。
  - 切到新姿势时，**先播当前姿势的 `_end`**；播完再进入新姿势的 `_str`（`loopDirect` 为真则跳过）；`_str` 播完接 `_lop`。
  - 动作型姿势（只有 `_act`，如 `cut_16a`）播一次 `_act` 后回 idle —— 对应 `_action → idle`。
  - 相同姿势重复请求直接忽略（避免同一事件重复从头播）。
- **switch 过渡姿势**（`a10_p11` / `a12_p13` / `a14_p15` / `a16_p17`，`create_pose_infos` 里硬编码的四条 `CreateSwitch`）：
  它们不是站姿而是一次「从 `aNN` 摆到 `pMM`」的过渡。剪辑名按 `switch_from.Substring(1)` 取源姿势
  （`a16` → `com_cut_16a_swt`），播完落到目标姿势的 `_lop`。工具层把它写成
  `"enter": "swt:<source clip>"`，播放器 `ResolveIntro` 按同目录 `<source>_swt.tsv` 加载。
- **`p18` 私有族**：`p18_p` → 角色自带 `18y` 的 `_lop`；`p18_s` → `18y` 的 `_swt` 进入；
  `p18_a` → `18y` 的 `_act` 一次性后再落 `_lop`；`p18_e01..08`（`priv_etc`）依赖
  `chr_anim_com_umset_<set>_<chr>`，只有 `101kot`/`102mis` 有，普通偶像回退到 `18y_lop` 并记日志。
- `PlayGesture(yes/no)`：优先当前姿势的 `_yes`/`_noo`，播完回该姿势 `_lop`（对应 `_yes/_no → _loop`）；没有就退回角色自己的点头。
- `ResetPose()`：有 `_end` 就先播 `_end` 再回 idle；否则直接回 idle。
- 所有状态切换 **不做 cross-fade**（时长 0）；只有回到 idle 用 **0.1s** 平滑（游戏里同样的 0.1f 常量）。
- 已删除：`one-shot` 平台期检测、`ClipTime` 冻结/平台循环、0.45s/0.35s 交叉淡入 —— 这些正是「抽搐 + 闪现」的来源。

## 4. 数据/工具落点

- 姿势剪辑库：`~/mltd-work/out/poses/`（1,539 个 `com_*.motion.json`，含 `act 214 / end 276 / lop 281 / noo 214 / str 276 / swt 64 / yes 214`）
- 剧情包：`tools/build_story_demo.py` → `build/Unity3DContent/stories/`（现在同时导出 `_lop`/`_str`/`_end`/`_yes`/`_noo`）
- 剧情场景（带 `direct` 标记）：`~/mltd-work/out/story-extract/scenes.json`（`build_story_scenes.py` 已把 `actor_pose.arg6` 写成 `direct`）
- 反汇编辅助：`/tmp/cs_annot.py`（capstone，解析 adrp+add 字面量与 `bl` 目标名）、`/tmp/ild_names.json`（258,679 条 RVA→方法名）

## 5. `_switch` / `priv_etc` 结案（2026-11-15）

原先记在这两处的 UNKNOWN 已解：

- **`_switch` 不是「条件触发」，而是四种复合姿势名的专用过渡动画。**
  `CharacterActorCommu.create_pose_infos` @0x382EAC0 里硬编码调用
  `CreateSwitch(from, to)`（@0x384CA14；调用点 0x382FBAC / 0x382FBE8 / 0x382FC1C / 0x382FC50）：
  `a10→p11`、`a12→p13`、`a14→p15`、`a16→p17`，另有 `CreatePrivateSwitch("p18_s")` @0x382FC84。
  `PoseInfo.is_switch()` @0x384CE7C 判 `switch_from(+0x48)/switch_to(+0x50)` 非空；
  `override_pose_clip` @0x3829770 的 switch 分支（0x382A1C0 起）取 `switch_from.Substring(1)`
  （去掉 `a`/`p`，`a16` → `"16"`）调 `set_clip_to_over_ctrl` @0x3830D5C，把控制器里的
  `dmy_com_<pose>_switch` 占位覆盖成真实的 `com_<variant>_16a_swt`。
  所以 933 个剧本里 `_swt` 用得很频繁——只是我们此前把 `a16_p17` 截成 `a16` 当普通姿势播了。
  数据核对：`a16_p17` 257 次、`a10_p11` 241 次，另有 `a12_p13` / `a14_p15`。
- **`priv_etc01..08` 属于特殊角色的 UniqueMotionSet。** `create_pose_infos` 的私有分支（0x382FD40 起）
  先调 `GetPrivatePoseInfo` @0x389687C（masterdata）取 flags（bit0 action / bit8 pose / bit0x10 switch）
  与 etc 数组，再 `CreatePrivateEtc` 循环用 `"priv_etc" + ToString(i + 1)` 生成 `priv_etc01..08`。
  真实剪辑来自 `chr_anim_com_umset_<set>_<chr>.unity3d` / `chara_commu_umset_<set>_<chr>`
  （`CreateBundleName` @0x384D40C、`CreateJsonName` @0x384D874）。资产清单里 `umset` 只有 13 个，
  全部属于 `101kot` / `102mis`（set `lb01..lb07`、`mk01`、`test00`）；PlayCover 缓存里只有
  `dmy_com_priv_etc01..08_*` 占位动画。普通偶像没有 umset，剧情也不会引用 `p18_e*`。

## 6. 仍未确认的点（UNKNOWN）

- `_start → _loop` 在代码里到底由 controller 的 `exitTime` 自动触发，还是由 `step_pose_execute` 里的
  `IsCurrentAnimationEnded` + `PlayAnimation` 驱动：两种路径都只能看到常量 0 的切换，画面效果一致，实现上按「剪辑播完即换」处理。
- `_switch` 播放结束后是否一定由 `check_pose_changing_loop` 切到目标 `_lop`（推断如此，画面已按此实现；
  IDA 的 `step_pose_execute` 反编译产出后复核）。
