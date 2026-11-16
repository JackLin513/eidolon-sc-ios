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

- **`_switch` 不是「条件触发」，而是五种复合姿势名的专用过渡动画。**
  `CharacterActorCommu.create_pose_infos` @0x382EAC0 里硬编码调用
  `CreateSwitch(from, to)`（@0x384CA14；调用点 0x382FBAC / 0x382FBE8 / 0x382FC1C / 0x382FC50 / 0x382FC84）：
  `a10→p11`、`a12→p13`、`a14→p15`、`a16→p17`、`a21→p22`（字面量 `0x98C0A18`/`0x98C0A40`/`0x98C0A50`/`0x98C0A60`/`0x98C0A80`），
  另有 `CreatePrivateSwitch("p18_s")`。
  后缀字面量（`script.json`）：`start`@0x98DE5D8 / `loop`@0x98D3A28 / `end`@0x98C7638 / `action`@0x98C0DD0 /
  `yes`@0x98E3300 / `no`@0x98D6B28 / `switch`@0x98DF3D8 / `_swt`@0x98C07E0，与磁盘剪辑后缀
  `_str/_lop/_end/_act/_yes/_noo/_swt` 一一对应。
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

### 5.1 IDA 复核：switch 播完确实落到目标姿势

`CharacterActorCommu.step_pose_execute`（Hex-Rays 反编译，@0x382D2AC）里请求状态被播出的那段
（对应 `LABEL_149`）：

```c
v37 = PoseInfo__is_switch(v12, 0);        // 0x384CE7C
v38 = v37 ? 80 /* switch_to @+0x50 */ : 16 /* id @+0x10 */;
*(a1 + 424) = *(v12 + v38);               // current_pose := switch_to (e.g. "p17")
v39 = (loopDirect != 0) ? 0.0f : 0.1f;    // 进入 loop 的混合时长
if (`id` 以 a89/a90/a94/a95 结尾 || 姿势 number 不匹配) v39 = 0.0f;
*(a1 + 488) = v13;  *(a1 + 496) = v39;    // pending state + fade
*(a1 + 504) = loopDirect;  *(a1 + 432) = (loopDirect == 0);
```

也就是说：switch 播放期间 `current_pose` 已经是**目标姿势**，状态播完后下一次 `step_pose_execute`
按目标姿势求 loop 状态名并以 **0.1 s** 混合过去；`check_pose_changing_loop` @0x382E084 只负责
「等 animator 真正进入该 loop 状态」再 `SetAnimationState` 对齐。

端到端验证：`cut_16a_swt` 末帧与 `cut_17a_lop` 首帧逐骨最大夹角 **0.00°**（全 56 骨），
所以 0.1 s 混合在画面上等价于直接接上；我们实现的「播 `_swt` → 播目标 `_lop`」与原生一致。

另一条独立证据：`CharacterFace_RC` 的 `.ctor`/`Action`/`blink_control` 在 1.3 亿字节 `__text`
里**一次都没被调用**（capstone 全量扫描），说明这张脸走的是基类 `CharacterFace`，
`EyesBlink`/`SetFaceBlink`/`nextblinktime`(+0xA8) 都在基类上 —— 与 §3 的眨眼结论一致。

## 6. `_start → _loop` 是谁驱动的（已解）

拆开两层就能对上：

**状态之间的串接是 controller 自己做的（exitTime，不是代码）。**
把烘焙后的 `AnimCtrl_Commu` 的 `TransitionConstant` 全量解出来（`m_HasExitTime` 等字段），
227 条 transition 无一例外：

| 源 → 目标 | 条数 | `m_HasExitTime` | `m_ExitTime` | `m_TransitionDuration` | 条件数 |
|---|---|---|---|---|---|
| `*_start → *_loop` | 47 | true | 1.0 | 0.0 | 0 |
| `*_yes → *_loop` | 43 | true | 1.0 | 0.0 | 0 |
| `*_no → *_loop` | 43 | true | 1.0 | 0.0 | 0 |
| `*_switch → *_loop` | 14 | true | 1.0 | 0.0 | 0 |
| `*_end → dmy_com_p01` | 38 | true | 1.0 | 0.0 | 0 |
| `*_action → dmy_com_p01` | 19 | true | 1.0 | 0.0 | 0 |
| `*_end → *_loop` | 9 | true | 1.0 | 0.0 | 0 |
| `in_*/out_* → dmy_com_p01` | 6 | true | 1.0 | 0.0 | 0 |

即 `<pose>_start` 播到剪辑末尾（exitTime=1.0）时由 Animator 自动跳到 `<pose>_loop`，
过渡时长 0、无条件、`m_InterruptionSource=0`。代码里没有任何 `IsCurrentAnimationEnded → PlayAnimation(_lop)` 的路径。

**`_loop` 自己的循环反而是代码驱动的。** 305 个 state 的 `m_Loop` 全是 `false`，`_loop` 状态没有出边，
磁盘上真实剪辑（如 `com_cut_05d_lop`）的 `m_MuscleClip.m_LoopTime` 也是 `false`——Animator 播完会停在末帧。
真正让它循环的是 `CharacterActorCommu.step_pose_execute` 的 Waiting 分支
（反编译第 590-600 行附近）：`status == 1` 且 `AnimatorStateInfo(0).IsName(current_state_name)` 为真时调
`CharacterActorBase.LoopCurrentAnimation()`（@0x3821200）。该函数是
`CrossFadeInFixedTime(current_state_name, 0f)` + `PlayInFixedTime(current_state_name, 0)` + 清标志位，
即在剪辑末尾**零时长重播同一状态**（不是交叉淡入）。另外 `check_force_loop` @0x382E67C 是同一个循环
在 `loopDirect == false` 且队列仅剩 1 个请求时的兜底入口。

实践含义：剪辑是首尾对齐的，零时长重播在画面上无缝。实测 14 个剧情 loop 剪辑的首帧/末帧逐骨最大夹角
0.14°–0.33°，所以我们用 `Mathf.Repeat` 连续播放与原生「播完重头再来」等价。
switch 播放结束后由 `step_pose_execute` 把 `current_pose` 置为目标并在下一次 update 播目标 `_lop`
（IDA 已复核，见 §5.1）；`check_pose_changing_loop` 本身只做状态对齐，不负责选剪辑。

### 6.1 混合时长（全部按原生对齐）

`step_pose_execute` 在发出姿势请求时写 `PlayAnimationRequest`：`fade = loopDirect ? 0.0f : 0.1f`
（state 以 `a89/a90/a94/a95` 结尾或姿势编号不匹配时为 0），`execute_entity` @0x382BE18 再用
`PlayAnimation(req.state, req.fade_duration, req.start_time)` 播放。加上上面的 transition 表，
原生只有**一个**非零混合：进入姿势状态（`_start`/`_switch`/`_action`）时 0.1 s（`loopDirect` 时为 0）。
其余全部是零时长直切：`_start/_yes/_no/_switch → _loop`、`_end/_action → dmy_com_p01`、
以及 `_loop` 的末尾重播。

端上 `EidolonStandMotion` 已按此实现（2026-11-15）：
`PoseEntryBlend = 0.1f` 只在 `EnterPose` 时启用（`loopDirect` 传 0），
`_start → _loop`、`_end → idle` 都走 `BeginBlend(0f)` 直切，`_loop` 用 `Mathf.Repeat`。
`yes/no` 早先是「0.2 s 升降的覆盖层叠加」，现已改成原生状态机语义（见 §6.3）。

### 6.3 `yes/no` 是状态而不是覆盖层（2026-11-15 补）

反汇编确认（`dump.cs` + `llvm-objdump`）：

- `CharacterActorCommu.PlayYes` @0x38245AC / `PlayNo` @0x382479C 只做三件事：检查
  `is_pose_changing`（真则返回 false）、检查 `next_poses.count > 0`（真则返回 false）、
  取 `pose_infos[current_pose]` 并读 `PoseInfo.has_yes_no`（+0x41）。满足时写
  `step_yes_no.is_yes`、`step = STEP.YesNo(1)` 并返回 true；**不满足时只打错误日志返回 false，
  不会退回到别的剪辑**。
- `STEP.YesNo` 在 `execute_entity_sub` 里被消费：找当前姿势对应的 `_loop` 状态名，
  `IsInTransition` 为假且 `IsName(loop)` 时 `SetAnimationState(loop)`、`step` 复位为 `Pose`。
- 控制器侧 `dmy_com_<pose>_yes → dmy_com_<pose>_loop`、`_no → _loop` 的 transition 同样是
  `m_HasExitTime=1 / m_ExitTime=1.0 / m_TransitionDuration=0`。
- 另有 `queued_yes_no`(+0x1E2) 队列：`ignore_pose_changing` 且处于 `ComeIn` 时把请求挂起，
  在 `STEP.Pose` 分支里再喂给 `StepYesNo`；`ignore_pose_changing` 为假时直接失败。

即：`_yes/_no` 是**当前状态**，播完零时长回同一姿势的 `_loop`，没有覆盖层也没有 cross-fade。
端上实现（`EidolonStandMotion.PlayGesture`）：

- 当前有故事姿势 → 用该姿势的 `_yes`/`_noo`；处于 idle（`cut_01z_lop` 等）→ 用同 stem 的
  `<stem>_yes`/`<stem>_noo`（如 `cut_01z_yes.tsv`）；
- 找不到对应状态就只记日志返回（不回退角色日常动作），与原生的 false 返回一致；
- 进入/离开/动作型阶段收到请求直接忽略（原生在 `is_pose_changing` 时返回 false）；
- 播放时 `BeginBlend(0f)` + `StartClip(clip, false)` + `phase = Phase.YesNo`，
  在 `Update()` 的 `Phase.YesNo when clock >= Length` 分支里零时长切回 `_lop`（idle 则回 idle 剪辑）。
- 已删除 `gesture`/`gestureTime`/`ApplyGesture` 覆盖层（原来的 0.2 s 升降叠加）。

### 6.4 台词时长按脚本帧，不用自造兜底（2026-11-15 补）

原实现 `lineDurationMs = max(max(voiceMs, scriptMs), 音频时长) + 350` 是自造规则。
原游戏推进由剧本帧决定：`actor_text` 的 `arg2`/`arg3` 是 60 fps 的起止帧，台词窗口就是这两帧之间；
语音比窗口长时会被下一句直接切掉，而不是延长当前句。端上改为：

```swift
// StoryTheaterView.playLine()
lineDurationMs = max(line.scriptMs, 200)
```

（200 ms 只是防空行；不再读音频时长、不再 `+350`。）

### 6.2 姿势切换必须等当前剪辑播完（2026-11-15 补，修「动作衔接闪现」）

上一版端上实现在 `PlayPose` 里**立即**切到下一个姿势。按原生代码这是错的：
所有 transition 都是 `m_HasExitTime=1`、`m_ExitTime=1.0`、`m_TransitionDuration=0`，
而 `CharacterActorCommu.step_pose_execute` 只在 `IsCurrentAnimationEnded` 为真后才把
`next_poses` 的队首变成 `current_pose` 并 `PlayAnimation(...)`——**没有任何路径在剪辑中途打断当前状态**。
`SetPose` 的职责只是把请求压进 `next_poses`（`is_pose_changing` 期间若帧率低于 60 才直接丢弃）。

也就是说：`_start`/`_switch`/`_action`/`_loop` 都要播到剪辑末尾，下一个姿势才接管；
`_loop` 没有出边、靠 `LoopCurrentAnimation()` 末尾零时长重播，所以新请求最多等一个循环周期（`_lop` 46 帧 ≈ 1.53 s）。

端上原来「立即切换」的后果：把正在播放的 `_str/_swt/_act/_lop` 在任意相位截断，
再以 0.1 s 混到下一个姿势 → 画面上就是**动作衔接的闪现/抽搐**（用户 2026-11-15 反馈）。
修正后（`EidolonStandMotion.cs`）：
- `PlayPose` 在当前 `Looping/Entering/Acting` 期间只做 `pendingPose/pendingLoopDirect/pendingIntro` 入队，
  打日志 `queued until <Phase> ends`，不切换；
- `Update()` 在 `Phase.Looping when clock >= current.Length` 时应用队首请求（否则 `clock -= Length` 继续循环），
  `Phase.Entering/Acting` 结束时同样先看队列；
- 跨姿势不再插 `_end`（`_end` 只用于 `ResetPose` 回 idle，对应 controller 的 `_end → dmy_com_p01`）。

验证（模拟器 `job_story_001har_4000`，28 次姿势请求、27 次入队）：
日志每个 `[stand] pose ...` 之后要么紧接 `queued until ... ends`，要么是同姿势 `already showing`；
没有一次「请求即切换」。对比录像里原先 81.5 s 处「双手垂下 → 合十」的单帧跳变，
现在该处为 2–3 帧（≈0.25–0.5 s）连续过渡。证据：
`~/mltd-work/out/3d-stand/story-exit-time-001har-4000.mp4`、`story-exit-time-contact.png`。

## 7. 剧本演出层（ADV actor 命令）实现状态

对 933 个剧本的 `CutRecord` 共 126,755 行做过命令统计。表里「已实现」的语义都以反汇编为依据，
不是猜的；标注 UNKNOWN 的地方写清为什么端上拿不到原值。

| 命令 | 次数 | 现状 | 原生语义 / 端上实现 |
| --- | ---: | --- | --- |
| `actor_text` | 7,501 | 已实现 | `actor_text` 帧窗口驱动字幕与语音（§6.4） |
| `actor_pose` | 16,197 | 已实现 | `SetPose(loopDirect)` → `_str/_swt/_act` 进入 + `_lop` 循环（§3、§6） |
| `actor_facial` | 22,618 | 已实现 | `SetExpression(facialMenu)` 透传 0..27 |
| `actor_eye_blink` | 43,316 | 已实现 | `SetEyeMode(Close/Open/Blink, isInterpolate:1)`（`EyeBlinkActor.onEnter`） |
| `actor_eye_direction` | 12,941 | 已实现 | `SetEyeDirectionByRate(h,v)`；99% 的跨度就是 1 帧 |
| `actor_yes_no` | 6,541 | 已实现 | `_yes/_noo` 作为状态播完回 `_loop`（§6.3） |
| `actor_cheek` | 479 | 已实现 | `SetCheek(level)` |
| `actor_2d_bg` | 449 | 已实现 | `adv_bg2d_*` 贴图导出为 JPEG（本机缓存 88/187 张），Unity 内贴在相机子节点的 Quad 上，随取景自动铺满 |
| `actor_visible_character` | 1,065 | 已实现 | `SetActive` 开关角色（`VisibleCharacterActor.onEnter`） |
| `actor_chara_dorotate` | 407 | 已实现 | `SetPosition/SetAngle` 逐帧插值（`SetRotationActor`/`CharaDoRotateActor`），端上用度数 + 缓动 |
| `actor_set_rotation` | 233 | 已实现 | 同上，瞬时版 |
| `actor_set_position` | 63 | 已实现 | `SetPosition`，端上按米制偏移 |
| `actor_reset_sway` | 802 | 已实现 | `ResetSway` 清 SwayManager 的累积状态与力（`ResetSwayActor.onEnter` → `chr.ResetSway`） |
| `actor_sit_pose` | 95 | 已实现 | 坐姿是姿势主数据的 `sit` 变体：端上把 `actor_sit_pose` 解析成 `com_sit_*` 的 pose 事件（`_str → _lop`） |
| `actor_fade_screen` | 136 | 已实现 | `black_fadein_ex_ui` / `black_fadeout_ex_ui` 等 → 端上全屏遮罩按脚本帧淡入淡出 |
| `actor_lip` | 30 | 已实现 | 原生四种：`Mumble` / `Open` / `Close` / `Fomalhout`（`LipActor.onEnter` + `setFomalHautSuspend` + `SetLipMode`）；端上 `Close` 闭嘴、其余走正式口型循环 |
| `actor_wait` | 76 | 已实现 | 纯时间轴等待，剧本帧已经在推进 |
| `actor_in_out` | 99 | **近似** | 原生用控制器的 `in_left/in_right/in_front`、`run_in_*`、`out_*` 状态；这些状态在本机缓存里只有占位剪辑（`dmy_com_in_left` 等），真实剪辑不随包下发。端上按名字做 ±2.6 m 的侧向进出插值 |
| `actor_camera_set_position_preset` | 925 | **近似** | 原生 `CameraSetTransformPresetActor.onEnter` 查 5 个预设名：`solo` / `duo` / `trio` / `solo_sit` / `live_result`（`script.json` 字面量 0x98DD4C8/0x98C6EE8/0x98E1298/0x98DD4E0/0x98D3198），数值从静态参数表读，不在客户端包里 → 端上只按预设改机位距离（solo ×1.0、duo ×1.35、trio ×1.65、solo_sit ×0.9、live_result ×1.2） |
| `actor_character_set_position_preset` | 896 | **近似** | 原生 `CharacterSetPositionPresetActor.onEnter` 按预设名 + `locationId`(1..3) 给每个角色设置位置/朝向；同样依赖不随包下发的参数表。端上单角色常驻中心，只记日志 |
| `actor_load_character` (+`_v3`) | 686+251 | **单角色近似** | 原生会加载/替换 cut 里的角色；端上只有一个 stand，忽略换人请求（同角色时保持） |
| `actor_change_costume` | 210 | **单角色近似** | 原生换装；端上只记日志（model3d 包每个角色只有 `pr001`/`ss003`，剧情里 setId 与包内 outfit 不是同一套编号） |
| `actor_sound` | 9 | UNKNOWN | 原生从 ADX2 cue sheet 播音（`bgm_commu`/`city_night`）；本机 `ADX2/General/bgm_commu.acb` 里只有 `salmon_comu` 一条流，`city_night`/`tv_show` 未缓存 → 端上只记 cue 名 |
| `actor_doscale_2dbg` / `actor_domove_2dbg` / `actor_domove_p2dbg` / `actor_visible_2dbg` | 103/94/50/37 | UNKNOWN | 2D 背景层的前景/局部演出（`Set2dBGActor` 里对 sprite 尺寸 1022×720 / 720×258 与缩放）；端上只有整张背景，未实现前景 2D 图层 |

### 7.2 验证记录（2026-11-15 模拟器）

- 背景：`job_story_001har_4000`（`bg2d_g0149`）—— 日志 `[stand] background bg2d_g0149.jpg 1024x1024`，
  截图 `~/mltd-work/out/3d-stand/bg-001har-4000-v2.png`（背景铺满、随取景自适应，字幕卡正常）。
  踩坑：① `Unlit/Texture` 被 Player 剥离 → `Shader.Find` 返回 null → `new Material(null)` 抛
  `Value cannot be null`；已在 `iOSExport.EnsureAlwaysIncludedShaders()` 把
  `Unlit/Texture`、`Sprites/Default` 写进 `GraphicsSettings.m_AlwaysIncludedShaders`。
  ② 背景 Quad 必须挂到相机的子节点（`localPosition=(0,0,24)`）并按 FOV 算尺寸，挂在世界坐标
  会在取景变化后盖不满屏幕。③ SwiftUI 侧 `scaledToFill` 背景要用 `GeometryReader` 约束 +
  `clipped()`，否则会撑大 `ZStack` 把字幕挤出屏幕。
- 取景与背景「割裂」修复：第一版把 Unity 视图 `scaleEffect(0.72)` 缩进屏幕上方，同时 SwiftUI 又
  铺了一层同样的背景图 → 同一个背景出现两种缩放，画面上就是操作者看到的「拼接缝」。
  现在背景只由 Unity 的相机子节点 Quad 绘制，取景改成在 Unity 相机上 **拉远 1.42 倍 + 上移 0.16
  屏高**（`SetCameraZoom` / `SetCameraBias`），视图铺满全屏不缩放，缝消失且人物完整落在字幕卡
  上方。截图 `~/mltd-work/out/3d-stand/bg-001har-4000-v5.png`。
- 可见性 / 进出场 / 淡入淡出：`job_story_006mak_5000` —— 日志 `[stand] visible False`、
  `[stand] visible True`、`[stand] inout RUN_IN_RIGHT speed=0.8 duration=2.12s`；
  `job_story_006mak_2000` 第 2 句（`black_fadein_ex_ui` 0→0.5s、`black_fadeout_ex_ui` 2.0→2.25s）
  录像 `~/mltd-work/out/3d-stand/story-fade-006mak-contact.png` 可见「正常画面 → 全黑 → 恢复」，
  与剧本帧一致；同一话里也验证了按故事加载不同角色（006mak 真壁瑞希，绿色外套）。
- 尚未有素材可验证的项：`sits`（这 6 话没有坐姿事件）、`lips`（`actor_lip` 只在 26 处出现）、
  `sounds`（cue 音频不在本机缓存）、多角色（模型包每个角色只有一套 stand）。

### 7.1 这轮新拿到的反汇编事实（2026-11-15 补）

- 相机预设名（`script.json` 解 slot）：`0x98DD4C8='solo'`、`0x98C6EE8='duo'`、`0x98E1298='trio'`、
  `0x98DD4E0='solo_sit'`、`0x98D3198='live_result'`。
- `CameraSetTransformPresetActor.onEnter`（0x37672F4）对预设名做 5 路字符串比较，选出 6 个 float
  （相机位置 xyz + 欧拉 xyz），调 `set_position` / `LookAt` / `UpdateFov`。
- `CharacterSetPositionPresetActor.onEnter`（0x3769278）遍历 cut 角色，按预设名分支 + `locationId`
  （`*(a1+64)` 的 1/2/3）调 `SetPosition`(0x38046B0) / `SetAngle`(0x3804738)。
- `LipActor.onEnter`（0x3768190）：`Mumble`/`Open`/`Close` → `setFomalHautSuspend(1)`，
  `Fomalhout` → `setFomalHautSuspend(0)`，然后 `SetLipMode`（0x381B438）。
- `Set2dBGActor.onEnter`（0x376B31C）：把两张 sprite 尺寸分别设为 1022×720 与 720×258，
  再按静态参数表缩放/位移（属于 2D 演出层）。
- 背景贴图：`export_backgrounds.py` 把 `adv_bg2d_*` 的 Texture2D 解成 JPEG(q82)，88 张 14 MB；
  其余 99 个 id 只在 CDN，未缓存。

已知的其它近似：

- 章节背景为纯黑（没有 2D 背景资源），字幕卡、按钮是端上自绘 UI。
- 台词窗口按剧本帧推进（§6.4），语音比窗口长时会被下一句切掉——这与原生一致，
  但第一次看会觉得「话说一半」。若想改成不切语音，那才是真正的偏离原生。
- `yes/no` 在被 `is_pose_changing` 拦住时只记日志丢弃（原生同样是返回 false，不排队，
  只有 `ignore_pose_changing` + `ComeIn` 时才会用 `queued_yes_no` 挂起）。

## 8. 模型侧（sway / 风场）复查：坐姿裙形不是缺代码（2026-11-15 补）

运行期探针（`EidolonStandHost.ProbeSway`，模拟器 `job_story_027say_6000` 第 9 句）：

```
[sway] bones=44 colliders=23 managers=4
[sway] manager[1] cat=Skirt path=BASE bones=18 skirt=18 normal=0 fallFollow=False
[sway] skirtBones=18 withColliders=18
[sway] skirt0 path=skirt_B0 len=0.230 nradius=0.030 cat=Skirt
```

反编译结论（`/tmp/skirt-decomp/`、`/tmp/sway-decomp/`）：

- `SwayManager.Init` 里的 `skirtL1` / `skirtL2` **恒为空**：`SetSwayColidersRecursive`
  只往第一个列表 append。端上保持空数组 = 忠实。
- `SwayManager.PrepareUpdate` 尾部的 `SkirtFallFollow` 是 **Live 高度开关**：
  `baseY >= LiveParams.fallLimit`，整段由 `LiveParams.SkirtFollow100EnableByYpos` 门控；
  `LiveParams` 是 ScriptableObject，**客户端包里没有该资产**，因此剧情里恒为 false。
- `SwayBone.AdjustSkirt(float)` 是「把裙骨半径抬到 r」的碰撞调参，不是坐姿分支；
  `ActivateSkirtSway` / `SetSkirtSwayEnabled` 是 Live 性能开关（经接口派发，无直接调用点）。

结论：坐姿裙形完全由裙骨物理 + 腿部 collider 决定，**代码侧没有可补的坐姿分支**；
端上 18 根裙骨与 collider 都在跑，参数与原生一致。要判断与游戏的差异，只能拿原游戏
同场景同姿势参考帧对比（`LiveParams` 数值不可得，标 UNKNOWN）。

### 8.1 风场（ISwayWind）现状

- `SwayWind.GetWind` **0x33D8DF8**、`SwayWindDirection.GetWind` **0x33D933C**、
  `SwayWindDirection2.GetWind` **0x33D9828**、`SwayWindDirection3.GetWind` **0x33D9E2C**、
  `SwayWindRefer.GetWind` **0x37663DC**、`SwayManager.GetWind` 0x1CEFFB0、
  `SwayManager.SetWind(ISwayWind,int)` 0x1CF025C。
  （此前误把各 `.ctor` 地址当成 GetWind：0x33D913C/0x33D9434/0x33D9A44/0x33D9E44 是构造函数。）
- 端上已有 `ISwayWindNative`、`SwayManagerNative.winds/SetWind/GetWind`（含原生 1.3 /
  timeScale 系数），**缺 5 个风源组件本身**；剧情 bundle 不带风源，所以剧情播放不受影响，
  只有 Live/舞台需要。实现前需要把 5 个 GetWind 的数学逐字段还原（IDA 反编译受损，改用
  `llvm-objdump` 定点阅读，进行中）。
- 剩余 `UNKNOWN(native 0x…)` 注释共 37 个 RVA，集中在 `CharacterMaterials`（镜面 /
  per-renderer 颜色 / blend）、`EyeTracking`、`JointBodyHead`、`DropShadow`；
  这些只影响 Live 级材质与细微微动，剧情播放不受影响，逐条反编译后补实现或改写注释。

### 8.2 风场组件已实现（代码侧，剧情无风源）

`spikes/porting-3d/unity-spike/Assets/Scripts/SwayWindNative.cs`：

| 组件 | 原生 | 行为 |
|---|---|---|
| `SwayWindDirectionNative` | `SwayWindDirection.GetWind` 0x33D933C（字段 power 0x20 / decay 0x24 / position 0x28 / direction 0x34 / waveFreq 0x40 / waveAmp 0x44 / m_wave_th 0x48 / m_pow 0x4C） | `mag = m_pow * (decay>0 ? 1/(1+decay*|pos-position|) : 1)`，返回 `direction * mag` |
| `SwayWindDirection3Native` | `SwayWindDirection3.GetWind` 0x33D9E2C（power 0x20 / fpsCoeff 0x24 / angleCoeff 0x28 / direction 0x2C / resultPower 0x38，clamp 0–3） | `direction * resultPower`（反编译原文就是两个 float 相乘） |
| `SwayWindPointNative` | `SwayWind.GetWind` 0x33D8DF8 的 `windType.Point` 分支（type 0x28 / power 0x2C / decay 0x30 / position 0x34 / m_pow 0x54） | `local = pos-position`；`|local|<0.001` 返回 0；否则 `normalize(local) * m_pow/(1+|local|*decay)` |
| `SwayWindProxyNative` | 同函数 `Direction/Direction2` 分支 | 找到目标 GameObject 上的 `ISwayWind` 并转发 |
| `SwayWindScan.Attach` | `SwayManager.SetWind` 0x1CF025C 的注册点（舞台代码，未随角色包下发） | 把场景里的风源按 `WIND_MAX=4` 注册进 manager |

未实现并标 UNKNOWN：`SwayWindDirection2`（GetWind 0x33D9828 读取 `WIND_PARAM[]` + `Plane` +
延迟包络，状态由 `Calc` 0x33D95E0 生成，未逐行还原）、`SwayWindRefer`（0x37663DC 按
`idol`+`setid` 解析 Live 风场集合，spike 无 Live 舞台管理器 → 返回 0）。
剧情 bundle 不带风源，这两个在剧情播放里不可达。

### 9. 旧 RVA 全量失效（重要：37 个 `UNKNOWN(native 0x…)` 注释是旧包地址）

游戏在 2026-11-15 09:46 换了安装包，`dump.cs`/`script.json` 是 13:42 从新包生成的；
而 B2–B5 阶段写进 C# 的 `UNKNOWN(native 0x…)` 注释全部是**旧包**的镜像基址 VA。
直接按这些地址反编译只会拿到无关函数（多为 TMP/UI 协程），这也是之前
「反编译结果对不上」的原因。

按区域测量的固定偏移（旧 + Δ = 新）：

| 区域 | Δ | 例（旧 → 新） |
|---|---|---|
| `CharacterDrawer` | `0x5AB00` | `0x1C0F634` → `0x1C6A134` `SetSkinQuality`；`0x1C0FC9C` → `0x1C6A79C` `SetLayerId` |
| `CharacterMaterials` | `0x5AC78` | `0x1C1DB00` → `0x1C78778` `SetMonoColorRatio`；`0x1C1DB28` → `0x1C787A0` `SetRimLightDirection` |
| `JointBodyHead` | `0x5AC78` | `0x1C642A0` → `0x1CBEF18` `SetVisible`；`0x1C66DB0` → `0x1CC1A28` `Initialize_Post_1.MoveNext` |
| `SwayBone` | `0x5AC78` | `0x1C70DB0` → `0x1CCBA28` `Init`；`0x1C732E8` → `0x1CCDF60` `SwayHit` |
| `SoulDataColor3i` | `0x5E6D0` | `0x1C352B0` → `0x1C93980` `TryParse` |
| `SwayManager` | `0x6E048` | `0x1C81A08` → `0x1CEFA50` `PrepareUpdate`；`0x1C81F68` → `0x1CEFFB0` `GetWind` |
| `EyeTracking` | `0xDBF20` | `0x379C2BC` → `0x38781DC` `EyeUpdate`；`0x379BF7C` → `0x3877E9C` `Start` |
| `CharacterImasMotion` | `0xC1448` | `0x37E80B8` → `0x38A9500` `SolveCurve`；`0x37EE384` → `0x38AF7CC` `SolveCurves` |

Δ 随地址单调增大 → 是同一个旧包相对新包的代码增长量。少量注释（`0x1CF025C`、
`0x33D9828`、`0x37663DC`、`0x9705120`、`0x9709770`、`0x970CCF8`）已经是新包地址，
不需要换算。后续按 Δ 换算后的地址逐条反编译，再决定 `implement` / 改注释 / 判定
out-of-scope（Live 舞台、gallery、minigame 等不在剧情播放路径上的）。

### 10. UNKNOWN 标记对「新包」的逐条重编译（2026-11-16）

§9 的 Δ 换算是「旧地址 + 区域偏移」，为了排除偏移误判，这一轮改用 **`dump.cs` 里直接给出的
当前包 RVA** 重新反编译：先从 `/tmp/ild/dump.cs` 解析 259,016 条 `// RVA:` 记录，按方法名
取出 41 个目标（36 个 `UNKNOWN` 标记对应的方法 + 5 个 `Sway*GetWind`），再用 IDA/Hex-Rays
对**当前包地址**反编译（`/tmp/newpkg-decomp/*.c`，文件名带 `<Class>.<Method>__0x<RVA>.c`）。

核对结果：

- 41 个目标全部落在函数入口（`get_func(ea).start_ea == ea`），无 `nofunc`。
- 与上一轮「Δ 换算地址」反编译（`/tmp/unk2-decomp/`）重叠 36 个：**32 个逐字相同**，
  4 个仅类型拼写/变量编号差异（`EyeTracking.EyeUpdate`、`SwayBone.SwayHit`、
  `CharacterImasMotion.SolveCurve`、`CharacterMaterials.SetSpotlightColor`），语义一致。
  → Δ 换算被证实等价于 dump.cs 的当前 RVA，36 条 UNKNOWN 的反编译确实来自新包。
- 37 个标记里另有 4 个是**静态数据槽**（`0x9704BE0`/`0x9705120`/`0x9709770`/`0x970CCF8`，
  il2cpp 字段 RVA，不是函数），不能「编译」；它们指向的当前 TypeInfo 已在端口注释里换成
  新包 token（如 `Imas.Live.MainLoop_TypeInfo 0x97B93B8`、`Imas.Live.CameraCtrl_TypeInfo 0x97AFED8`），
  对应 Live 子系统在本 spike 不存在，属 out-of-scope。

据此，37 个标记的最终处置（对应提交 `73699501`）：

| 处置 | 数量 | 代表 |
|---|---|---|
| 按新包反编译后**已实现** | 27 | `CharacterMaterials.create_sync / initStatic / SetMonoColorRatio / SetRimLightDirection`、`CharacterDrawer.SetSkinQuality`、`JointBodyHead.SetVisible / SetBodyMeshs / ApplyGlassesSwitch`、`SwayBone.Init / SetManager / ResetRotForADV / SwayHit`、`SwayManager.PrepareUpdate`、`SoulDataColor3i.TryParse` |
| 保持行为、仅把注释改引新 RVA（含 out-of-scope 说明） | 5 | `CharacterDrawer.GetZShiftCloth / ReloadDefaultLayers`、`CharacterMaterials.SetSpotlightColor`（Live 聚光）、`SwayBone.FinishRotate`、`SwayManager.GetWind` |
| 精确 UNKNOWN（Hex-Rays 丢操作数，需运行时探针） | 4 | `JointBodyHead.MeasureSway` 的 float 合并、`EyeTracking.EyeUpdate` 的部分数学、`CharacterImasMotion.SolveCurve / SolveCurves` 的取整细节 |
| 静态数据槽（不可编译，已换新 token 并标 Live out-of-scope） | 4 | `0x9704BE0 / 0x9705120 / 0x9709770 / 0x970CCF8` |

风场 5 个 `GetWind` 也按**当前包真实入口**重编译（此前误用 `.ctor` 地址）：

| 类 | 当前 RVA | 反编译确认的行为 | 端口状态 |
|---|---|---|---|
| `SwayWind` | `0x33D8DF8` | `type`(+0x28)==1 → 查 GameObject 上的 `ISwayWind` 代理转发；==2(Point) → `local=pos-position(+0x34..3C)`，`|local|<0.001` 返回零，`mag = m_pow(+0x54) * (decay(+0x30)>0 ? 1/(1+|local|*decay) : 1)`，返回 `normalize(local)*mag`；其他值 → 同样走代理 | `SwayWindPointNative` / `SwayWindProxyNative` 与之一致 |
| `SwayWindDirection` | `0x33D933C` | `mag = m_pow(+0x4C) * (decay(+0x24)>0 ? 1/(1+decay*dist) : 1)`，返回 `direction(+0x34) * mag`（位置 +0x28..0x30） | `SwayWindDirectionNative` 一致 |
| `SwayWindDirection3` | `0x33D9E2C` | `return *(float*)(a1+44) * *(float*)(a1+56)` = `direction(+0x2C) * resultPower(+0x38)` | `SwayWindDirection3Native` 一致 |
| `SwayWindDirection2` | `0x33D9828` | 逐 `WIND_PARAM` 的包络状态（`Init/Update/Calc` 驱动）与 `CalcWindVelocity` 平面投影；此处只有 GetWind 的读取端 | 仍为 stub + 精确 UNKNOWN（Live 舞台专用） |
| `SwayWindRefer` | `0x37663DC` | 从 Live 舞台管理器按 `idol`+`setid` 找角色再转发 | 仍为 stub（无 Live 舞台管理器） |

配套的 `Start/Update/Init/Calc/Awake/UpdateParameters/SetWind`（14 个）也已对当前包反编译，
用于核对 / 补齐 wind 的每帧状态更新（wave 相位、m_pow、Direction2 包络）。

### 10.1 验证时发现的两处控制台噪声（已修）

跑 `job_story_027say_6000` 第 9 句时，Development Console 被两类每帧刷屏的日志占满，
两者都不是本轮引入，但会遮住画面，顺手修掉：

1. `NullReferenceException at CalcBoneNative.ExplictUpdate -> Transform.get_localRotation`（约 20 次/秒）。
   注册表里存在参考骨解析失败的条目，`referTransform` 为空。现在 `ExplictUpdate` 跳过
   `myTransform`/`referTransform`（以及 TITE 类型 4/6/7 的 `referTransform2`）为空的条目并只报一次：
   `[calc] skipping calc-bone entries with missing transforms: my=KUBI_RT__twist_x0 refer=KUBI`。
   根因（已查清）：`CalcBone.Awake` 在 `JointBodyHead` 装配**之前**跑。原生的顺序是先
   `JointBodyHeadAssembly` 把 head 侧骨骼 graft 进 body 的 `KUBI/ATAMA`（旧 body 骨改名
   `KUBI___`、旧 head 侧对象销毁），再让 `CalcBone.Awake` 用 `GetComponentsInChildren<Transform>(true)`
   建名字表，所以它的 `KUBI` 一定能解析；端上先建表时抓到的是即将被销毁的旧对象，
   装配完成后这些引用变成 Unity 的「fake null」，于是 `KUBI_RT__twist_x0` 这类 entry
   的 `referTransform` 为空，颈部/头部 twist 的 calc 被静默跳过。
   修法：`CalcBoneNative.RebindReferences()` 只按名字**重新解析引用**（保留 `initMyRot`/
   `initMyPosition`/`initRefRot` 等 bind-pose 采样，不重跑 `Awake`），在使用到空引用时按 1 秒
   冷却重试一次；修复后日志：`[calc] re-resolved 2 stale calc-bone reference(s) after the
   joint-body-head assembly`（正是 `KUBI_RT__twist_x0` / `KUBI_RT__twist_z0` 这两条）。
   效果：同一话同一句截图对比（左右为修复前后），头部朝向/发束落点不同 —— 颈部 twist
   现在真的被算进去了。
3. **颈部 twist helper 的 A/B 结论（2026-11-16 补）**：`KUBI_RT__twist_x0` 修好绑定后确实
   开始被驱动，但同一话同一句的截图里**脖子右侧靠领口处出现一块缺口**（颈部蒙皮被拉裂），
   而把 `__twist` 条目整体跳过时画面平滑。`KUBI_RT__twist_*` 是没有子节点、只承载蒙皮权重
   的辅助骨，`CalcBone.Twist` 原生实现（`sub_1C60D00`，里面还读 `off_970CCF8+23` 的静态
   Vector3 配置）目前只还原到近似式，对四肢 helper 表现正常、对颈部 helper 会过度旋转。
   处理：先用 `EIDOLON_CALC_SKIP_TWIST` 做过 A/B 取证，落地时只让 `KUBI_RT__twist*`
   保持刚性（`[calc] leaving KUBI_RT__twist* rigid`），其余 twist 条目照旧计算；
   精确的 `Twist` 公式仍列为 UNKNOWN（需要重跑 Il2CppDumper 拿到 `sub_7095F7C` 等
   数学 helper 的方法名后再逐条核对）。证据：`story-sit-027say-6000-v4.png`（有缺口）与
   `story-sit-027say-6000-v3.png`（无缺口）。

2. `Tag hair_side/hair_yoko/wing_L0/OPAI_L0/A/C is not defined` 每帧警告。
   原生用 `GameObject.CompareTag` 读这些服装/部件标记，但 spike 工程的 TagManager 里没有这些 tag，
   Unity 每次调用都会警告且结果恒为 false。改为按节点名匹配（`name == token` 或前缀），
   语义等价（bundle 里同一 token 就在节点名上），警告消失。

验证：同一场景重跑，`NullReferenceException` 0 次、`is not defined` 0 次；
截图 `~/mltd-work/out/3d-stand/story-sit-027say-6000-v3.png`（裙摆贴腿、配色正常、底部只剩字幕与按钮）。
