# MLTD 表情与眼睛：脚本命令、运行时语义与「待机眯眯眼」根因

日期：2026-11-15
范围：剧情（ADV）里驱动眼睛/表情的剧本命令、原游戏运行时如何处理它们，以及我们在
`EidolonIOS` + Unity 立绘里复刻时踩到的 bug。

配套文档：[mltd-motion-reverse-engineering-2026-11-15.md](mltd-motion-reverse-engineering-2026-11-15.md)
（姿势状态机）、[mltd-story-extraction-2026-11-15.md](mltd-story-extraction-2026-11-15.md)
（剧情/语音/口型抽取）。

## 1. 症状

剧情播到「动作结束、进入待机」的间隙时，角色经常半闭着眼（眯眼），下一个表情命令来了才恢复。
动作本身已经按原游戏状态机播放，所以问题只在眼睛/表情这一层。

## 2. 剧本里眼睛是脚本驱动的（此前完全没接）

扫描 `~/mltd-work/out/story-extract/scripts.json`（933 个剧本、全部 `CutRecord` 行）：

| 命令 | 条数 | `arg5` | 含义 |
| --- | --- | --- | --- |
| `actor_eye_blink` | 43,316 | `close` / `open` / `blink` | 闭眼 / 睁眼 / 恢复自动眨眼 |
| `actor_eye_direction` | 12,941 | `arg5`=水平、`arg6`=垂直（-100…100） | 视线方向 |

两者都是 `arg1`=cut 标签、`arg2`=起始帧、`arg3`=结束帧（多为 start+1）、`arg4`=角色 id。
我们此前只抽了 `actor_pose` / `actor_facial` / `actor_yes_no` / `actor_cheek`，眼睛两条命令
**一条都没实现**，于是眼睛只由我们自造的随机眨眼 + 表情行决定。

统计（`scenes.json`，933 故事 / 7,501 行）：`open` 20,852、`close` 20,419、`blink` 1,775、
`actor_eye_direction` 12,451。close→open 的间隔中位数 **30 帧**（60 fps → 0.5 s），
`job_story_001har_9000` 的闭眼占比 **20.9%**（1,715 / 8,189 帧）——这是作者写出来的表演，
不是 bug。

## 3. 原游戏怎么消费这两条命令

二进制：PlayCover 的
`/Users/jacklin/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0310.app/Frameworks/UnityFramework.framework/UnityFramework`
（165,765,984 B，arm64 dylib，`__TEXT vmaddr 0 == fileoff 0`，所以 il2cpp RVA == 文件偏移）。
元数据用 Il2CppDumper v6.7.46（`CodeRegistration 8f13e60` / `MetadataRegistration 9199070`）解出
`/tmp/ild/dump.cs`，反汇编用 `xcrun llvm-objdump` 与自建 capstone 注解器。

### 3.1 `actor_eye_blink` → `CharacterActorBase.SetEyeMode`

`Imas.EyeBlinkActor.onEnter`（**0x376DD18**）：
`GetCurrentCharacter(mGameObjectName)`（0x3704DC0）→ `Character.actor` →
按 `eyemode` 字符串与三个字面量比较，每支尾部 `b 0x382290C`（尾调用 `SetEyeMode`），
第二参数固定 `w2 = 1`（`isInterpolate = true`）：

| 脚本 `arg5` | 字面量地址 | `SetEyeMode` 参数 |
| --- | --- | --- |
| `blink` | `0x98C2F58` | `(0, 1)` |
| `open` | `0x98D7828` | `(1, 1)` |
| `close` | `0x98C44E0` | `(2, 1)` |

（`0x376DDB4`–`0x376DED8` 的指令：`mov w1,#0/#1/#2; mov w2,#1; b 0x382290C`。）

`CharacterActorBase.SetEyeMode(mode, isInterpolate)` 反编译（`/tmp/face-decomp/CharacterActorBase__SetEyeMode.c`）：
先写 `eye_mode("+0x48") = mode`，再按模式设置角色的眼睛标志位，最后

* `Close` → `FaceCtrl.SetEyeClose(true)`（插值闭眼）
* `Open` → `FaceCtrl.SetEyeClose(false)`（插值睁眼）
* `Blink` → 先复位眨眼计时（vtable +808），**再** `SetEyeClose(false)`，即「睁眼 + 恢复自动眨眼」
* `ByRate` → vtable +600（`SetEyeCloseRate(0.0)`），供 `SetEyeCloseRate` 用
* `isInterpolate == false` 时走 `SetEyeCloseDirect(bool)`（无过渡）

`CharacterEyeMode`（TypeDefIndex 9821）：`None=-1, Blink=0, Open=1, Close=2, ByRate=3, Num=4`。
`CharacterActorBase`（9941）字段 `eye_mode(+0x48)`、`currnet_eye_close_rate(+0x50)`；
`SetEyeMode` **0x382290C**、`SetEyeCloseRate(float, bool)`、`SetEyeDirectionByRate(float,float)`。

### 3.2 `actor_eye_direction` → `CharacterActorBase.SetEyeDirectionByRate`

`Imas.EyeDirectionActor`（9170）字段 `hVal(+0x38)` / `vVal(+0x3C)` / `hvec(+0x40)` /
`vvec(+0x44)` / `endhrate(+0x48)` / `endvrate(+0x4C)`；`onEnter` **0x3769024**：

* `GetCurrentCharacter(...)` → `Character.actor`（0x430A544）→ 眼睛速率字段 `+0x13C/+0x140`；
* 脚本值 `hVal/vVal` **除以 100** 得到 `-1…1` 的率（`fdiv v2, v3=100.0`）；
* `endhrate/endvrate` = 目标率（`stp d0, d2, [x19,#0x40]`），`hvec/vvec` = 每帧步长 =
  `(target - current) / 帧数`（帧数 = `arg3-arg2`），由 `update()`（0x3769130）逐帧逼近。

`CharacterActorBase.SetEyeDirectionByRate`（**0x3822AF0**）把率写进 `+0x13C/+0x140`，再按
`(rate+1)*0.5` 夹到 0…1，在两组角度之间插值后写进眼睛朝向字段（`+0x144`），并把
`eye_direction_mode = 3`（ByRate）。角度上下限来自 `EyeTrackParam`
（`EyeDirLimUp=10, EyeDirLimDown=-10, EyeDirLimLeft=30, EyeDirLimRight=-30`，
`EyeDirScale=0.004`，`EyeTrackingNative.EyeTrackParam`）。

原游戏的视线是**逐帧插值**的：`EyeDirectionActor.onEnter`
（`/tmp/face-decomp/EyeDirectionActor__onEnter.c`）算
`target = (h/100, v/100)`、`step = (target - current) / (arg3 - arg2)`，`update()` 每帧加一个 step。
实测 12,941 条命令里 **12,653 条 `arg3-arg2 == 1`**（60 fps → 16.7 ms），所以端上直接跳到目标率
与原生逐帧效果等价；跨度 ≥5 帧的 160 条会是瞬时跳到终点，差异只在 33–500 ms 的过渡里。

### 3.3 `FaceCtrl` 的过渡常量（对照用）

`Imas.FaceCtrl`（TypeDefIndex 9907）：

| 常量 | 值 | 说明 |
| --- | --- | --- |
| `eyeBlinkTime` | 0.1 | 眨眼过渡 |
| `faceTransitionTime` | 0.13333334 | 表情过渡 |
| `cheekTransTime` | 0.1 | 腮红过渡 |
| `lipTransitionTime` | 0.2 | 口型过渡 |

`FaceCtrl.UpdateFace`（0x387A86C）里 `eyeOpenBuff` / `eyeCloseBuff`（字段 `+0x78` / `+0x80`）是
**表情权重缓冲**（由当前与上一个 `MeshBlendParam` 插值得到），眨眼只往 Renderer 的 blend shape 写值，
**不移动这两个缓冲**。

反编译核对（`/tmp/face-decomp/FaceCtrl__UpdateFace.c`，眼部分支 LABEL_155–LABEL_169）：
`from = eyeTrs.last 对应的缓冲`、`to = eyeTrs.cur 对应的缓冲`，`r = clamp01(eyeTrs.ratio)`，
`sub_710B454(from[i] + (to[i] - from[i]) * r)` 只把**插值结果**交给写权重的函数，缓冲本身只读。
`FaceCtrl.Action`（0x387B968）里过渡模块是 `remaining -= dt; ratio = 1 - remaining/duration`，
`remaining <= 0` 时 `from = cur`、`ratio = 0`；`FaceCtrl.Init2` 把眼模块初始化成
`last = cur = 1`（`0x100000001`，即睁眼）。

## 4. 根因：我们的 `FaceCtrlNative.UpdateFace` 把缓冲当草稿纸

`spikes/porting-3d/unity-spike/Assets/Scripts/FaceCtrlNative.cs` 第 2 步（眨眼淡入）原来写：

```csharp
float[] from = eyeTrs.last == Open ? eyeOpenBuff : eyeCloseBuff;
float[] to   = GetEyeBuff(eyeTrs.cur == Open ? Open : Close);
for (i…) {
    from[i] = from[i] + (to[i] - from[i]) * ratio;   // ← 就地把缓冲改成插值结果
    render.SetBlendShapeWeight(mouthShapes + i, from[i]);
}
```

`from` 就是持久缓冲本身。一次眨眼（Open→Close）结束后 `eyeOpenBuff` 被写成「闭眼值」；
下一次睁眼（Close→Open）时 `to` 已经等于闭眼值，于是无论怎么插值都写回闭眼值——
**眼睛从此停在闭眼/半闭状态，直到下一条 `actor_facial` 重建缓冲**。这正是「动作结束进入待机就眯眼」：
待机段没有新表情命令，缓冲不会重建。

数值复现（19 个眼睛通道，open=1.0 / close=0.0，交替眨眼 8 次，每次 6 帧）：

```
buggy   eyeOpenBuff[0], eyeCloseBuff[0] 每次眨眼后: (0.0,0.0) (0.0,0.0) … (0.0,0.0)
fixed   eyeOpenBuff[0], eyeCloseBuff[0] 每次眨眼后: (1.0,0.0) (1.0,0.0) … (1.0,0.0)
```

修法：插值结果写进临时变量再写权重，绝不回写 `eyeOpenBuff/eyeCloseBuff`。

## 5. 我们把眼睛/视线命令接进剧情播放

数据链路：

1. `~/mltd-work/build_story_scenes.py`：新增两类事件
   `actor_eye_blink → line.eyes[{frame,end,mode}]`、
   `actor_eye_direction → line.gazes[{frame,end,h,v}]`（`h`/`v` 原样保留 -100…100）；
2. `tools/build_story_demo.py`：写进 `story.json` 每行 `eyes[{ms,mode}]` / `gazes[{ms,h,v}]`
   （`ms = frame*1000/60`）；
3. `EidolonIOS/Features/Stand/StoryTheaterView.swift`：`Story.Line` 增加 `eyes` / `gazes`，
   `dispatchDueEvents` 按 `ms` 派发 `renderer.setEyeMode(_:)` / `renderer.setGaze(h:v:)`；
4. `EidolonIOS/Runtime/Unity/UnityCharacterRenderer.swift`：发 `SetEyeMode` / `SetGaze`；
5. `EidolonStandHost.cs`：`SetEyeMode(string)` → `EidolonStandFace.SetEyeMode`；
   `SetGaze("h,v")` → `EidolonStandFace.SetGaze`；
6. `EidolonStandFace.cs`：实现 `CharacterEyeMode` 的三态——
   `close` 调 `face.SetEyeClose(true)` 并停掉自动眨眼、`open` 反之、`blink` 先
`face.SetEyeClose(false)` 再恢复自动眨眼（对齐原生 `Blink` 分支）；
   `SetGaze` 把率换算成 -1…1 交给 `EyeTracking.SetForcedGaze`；
7. `EyeTrackingNative.cs`：新增 `forcedGaze`，在原生 `EyeUpdate` 算完并夹取 `eye_rx/eye_ry`
   之后用 `EyeDirLimRight/Left`、`EyeDirLimDown/Up` 插值覆盖，绕开「眼睛追相机」。

自动眨眼（`BlinkClosed=0.125s`、3.2–6.0s 间隔，来自 `CharacterFace_RC`）保留为默认
`CharacterEyeMode.Blink` 的行为；脚本 `close/open` 期间暂停，脚本 `blink` 恢复。

## 6. 验证

模拟器 iPhone Air（`F2F62CF3-3C68-4466-98ED-7CC804AB8551`），
`SIMCTL_CHILD_EIDOLON_STORY=job_story_001har_9000 SIMCTL_CHILD_EIDOLON_ACTIVE_FRANCHISE=mltd`：

* stdout 中 150 s 内 `[stand] eye mode=...` **114** 次、`[stand] gaze ...` **44** 次，
  与 `story.json` 的 `eyes/gazes` 条数一致；
* 逐帧截图里，动作结束后的待机段眼睛保持睁开；闭眼只出现在剧本 `close` 的窗口内
  （`story-eyes-contact.png` 第 1–2 行可以看到「闭眼笑 / 睁眼」交替，第 3–4 行待机时都是睁眼）；
* 证据：`~/mltd-work/out/3d-stand/story-eyes-001har-9000.mp4`（540 宽压缩版）、
  `~/mltd-work/out/3d-stand/story-eyes-contact.png`（4 s 间隔、36 帧头部特写联系图）；
  补上 `blink` 分支「先睁眼」后的复跑：`story-eyes-blink-001har-9000.mp4`、
  `story-eyes-blink-contact.png`（3 s 间隔、40 帧眼部特写，待机段全部睁开，
  半闭只出现在 0.1 s 过渡或 `微笑み`/`困り笑い` 这类本身就垂眼的行里）。

## 7. 052tmg 没有动作的原因（顺带结案）

`~/mltd-work/asset-manifest/manifest.msgpack`（171,033 条）按角色统计：`052tmg` 只有
**1** 条资产 `cb_pr001_052tmg.unity3d`（卡面 body），没有 `ch_*`（头/脸）、没有
`chr_anim_com_*`、没有 `com_*` 姿势剪辑；`motion-daily-merged/index.json`、`chara_commu_pose_set.json`、
PlayCover 缓存索引里也都查不到它（`051tmg {ch:141, cb:44, chr_anim:6}` 是对照组）。

结论：**这是只有卡面资源的角色，原游戏里没有它的立绘动作可提**。`tools/build_mltd_3d_packages.py`
现在会丢弃没有任何 `ch_*.unity3d` 的角色，并打印
`dropped card-only characters: 052tmg`；重建后 `build/eidolon-model3d-mltd.eidolonpkg`
从 57 → **56** 个角色（613 个文件，manifest 的 `files` 全部存在）。

## 8. 仍然 UNKNOWN

* `SetEyeDirectionByRate` 里角度插值用的两组端点值，从上下文看是 `EyeTrackParam` 的
  `±30°`（水平）/`+10°/-10°`（垂直），但没有直接读到取这两个字段的指令；当前实现按该假设重建。
* `_swt`（动画控制器的 `_switch` 状态）在 933 个剧本里没有被触发过，触发条件未解。
* `priv_etc01..08` 私有姿势的资源和触发条件仍未对上（剧情里没出现）。
* `CharacterEyeMode.Blink` 的自动眨眼时序由 `CharacterFace_RC` 驱动（我们自造的 0.125 s 闭眼 /
  3.2–6.0 s 间隔只对齐了节奏，未逐字节还原）；`_swt`/`priv_etc` 同上。
* `SetEyeDirectionByRate` 里角度端点（`EyeTrackParam` 的 `±30°` / `+10°/-10°`）来自
  `EyeTrackingNative.EyeTrackParam` 常量，未直接从该函数取字段确认。
