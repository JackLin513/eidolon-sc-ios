# 端上 3D 立绘的动作：现状与遗留（2026-11-01）

这份文档冻结「舞蹈 + sway 物理 + 碰撞」这一轮的结果：做了什么、和游戏差在哪、下次
要改从哪里下手。细节推导在 `research-mltd-sway-physics.md`（本地，含反编译引用，
不入库）；工具链用法在 `README.md`。

## 一、数据管线

```text
iOS 缓存 bundle (UnityFS)
  ├─ extract_sway.py   → <model>.sway.txt     sway 文本资产（骨骼弹簧、限位、碰撞体）
  ├─ compress_motion.py→ loveig.motion.json   舞蹈曲线（30fps 网格 + 量化）
  └─ export_corpus.py  → <model>.gltf → gltf_to_usdz.py → pack_usd.py → <model>.usdz
                          + <model>.sway.json  （sway.py 从 sway 文本生成 sidecar）
```

语料：58 组 / 109 个模型 / 49 套演出服。sidecar 里实际生效 4,758 根摆动骨、
1,266 个碰撞体（sphere 305、capsule 733、bridge 164、plane 64）。

## 二、端上运行时（`ios/`）

| 文件 | 职责 |
| --- | --- |
| `MotionDance.swift` | 解 `eidolon.motion/1`，采样每帧骨骼曲线 |
| `MotionJointMap.swift` | 曲线骨骼名 → 骨架 joint 的映射 |
| `MotionPose.swift` | 关节姿势（位置/旋转/缩放）与父子合成 |
| `MotionAssist.swift` | 舞蹈没 key 的辅助骨（示例） |
| `MotionSway.swift` | 游戏 `SwayBoneMT` 的移植：弹簧、限位、碰撞、侧线 |
| `MotionPlayback.swift` | 把上面几块拼成播放（含调试开关） |

每帧顺序与游戏 `SwayManager.ExecuteUpdate` 一致：`SwayMove`（弹簧 + 跟随 + 重力）
→ `SwayHit`（碰撞，`hitTwice` 再跑一遍）→ `CalcRotate`（角度窗 + `HitMuteForce`）。

## 三、碰撞：和游戏对齐到什么程度

已按反编译逐条对齐（见 `research-mltd-sway-physics.md` §3.3–3.3.3）：

- 碰撞体四类：Sphere、Capsule、Plane（含 planeRotQ 旋转与 planeAxis）、Bridge
  （`bridgetgt` 之间补一段胶囊）。
- 推出量取「推出距离最大」的那个碰撞体写回，和 `SwayHit` 一致。
- `hitTwice`：同一帧再跑一遍碰撞。
- `CheckSideLine`（`useLinkHit`）：两片尾点之间那条线当作半径 `0.9 × min(两片 radius)
  + 胶囊半径` 的胶囊去测，语料里只有 008tak-ss006 的 19 片大裙摆在用。
- `CapsuleHit` 的裙摆屏障（`useSkirtBarrier`）：裙片自己的外侧法线与腿轴对齐时，把它
  挡在穿过大腿中轴的平面自己那一侧；26 个模型 247 个碰撞体开着。
- `CalcRotate` 的 `HitMuteForce` / `HitMuteRate`：命中帧按比例把推出量留在速度里；
  022ser 的 5 片裙 + 2 束头发在用。
- 尾点用游戏的 tip 标记骨（`skirt_RD1` 之类），不是顶点质心；静止时 RC0 的角度误差
  从 35.7° 降到 0.9° 以内。

语料层面已经没有「没实现的碰撞体类型或开关」：`CapsuleSphere1/2`、`useBindDir`、
`isWing`、`isZConstraint`、`HitOneCollider` 都只存在于编辑器参数或被运行时忽略
（`CapsuleSphere*` 根本不在 `SwayBoneMT.ColliderParams` 里）。

## 四、已知近似（够用，但和游戏不完全一样）

1. **侧线的施加方式**。游戏把 `pushOutV` 交给 il2cpp 方法表里的调用者处理，静态拿不到
   那段应用代码；我们把它并进方向空间的松弛里（和点推一同收敛）。方向和量级对，
   但不是逐行等价。
2. **Plane / Bridge 的侧线变体**（`CheckSideLine` 的类型分支 2、3）没实现——没有任何
   衣装把 side line 连到这两类碰撞体。
3. **culling 早退**没做（纯优化，行为不变）。
4. **`CalcSideLineDistance` 的抗弹簧**（`sideAntiSpring*`）只做了拉的那一半；2 根骨
   有 0.2 的抗弹簧系数，影响可忽略。
5. **`resolveDepthFactor`** 默认 0.9 已写死在侧线里，没有从数据读。

## 五、还没解决、但不是碰撞的

- **头发插进头模**：31/109 个模型的头发数据没有引用头部球体碰撞体；任何求解器都救不了
  没给数据的碰撞。要修只能补碰撞体或加游戏里没有的安全网（用户已选择忠于数据）。
- **头发「漂浮感」**：舞蹈曲线的 hair 骨骼幅度大 + 我们的方向空间求解器，观感与游戏
  还有差距；先按「有严重问题再回来」搁置。
- **动作不是每个角色各自的**：MLTD 的舞蹈按歌给，不是按偶像；109 个模型共用
  `loveig` 一套舞蹈，物理 sidecar 才是逐模型/逐衣装的。

## 六、调试手段（都在本机，不入库）

- 离线复刻：`/tmp/swayloop/harness {sway|audit|hair|dump|root|base}`，直接吃
  `sidecar + 静止姿势 + 曲线`，比开模拟器快一个数量级。
- 模拟器开关：`EIDOLON_3D_START`、`EIDOLON_3D_PAUSE_AT`、`EIDOLON_3D_NO_OUTLINE`、
  `EIDOLON_3D_NO_SWAY_COLLIDERS`（碰撞 A/B）、`EIDOLON_3D_NO_SWAY` 等，见 README。
- 验证：`xcodebuild test -scheme Eidolon3DSpike`（74 个单测）+ 全语料 harness 扫描
  （109 个模型 0 崩溃）。

## 七、下次要动的时候

1. 先在 harness 里复现并量化（`audit` 看裙摆离群、`hair` 看朝上与插头），再改求解器。
2. 改动后必须跑：全部单测、全语料扫描、至少一个模拟器截图 A/B。
3. 尾点、限位、碰撞的每个判据都在 `MotionSwayTests` 里有一条用例，改判据就先改用例。

## 八、原地动作（照相模式，2026-11-01 追加）

`chr_anim_pho_*` 的格式和 `/motion` 里那些都不一样，但**不需要 Unity 编辑器**：

- 它是普通 Generic `AnimationClip`（`isHumanMotion == false`），60 条
  `m_ClipBindingConstant.genericBindings` 用**路径 CRC32** 指向骨骼——Unity 的
  `Animator.StringToHash` 对 Transform 路径就是 CRC32，所以 Python 能用
  `zlib.crc32` 反查 MLTD 的 58 条规范路径。
- 曲线键在 `m_MuscleClip.m_Clip` 的容器里：一帧 = `float time` + `int32 keyCount`
  + keyCount × (`int32 曲线号` + 4 个 float Bezier 系数，第 4 个是值)。首帧时间
  -3.4e38 是「之前」哨兵，末帧 `inf`。每个 binding 三条曲线：位置（attribute 1）
  是 Unity 单位，旋转（attribute 4）是欧拉角、度和舞蹈同一套 Z-X-Y 约定——同一
  根骨的数值与 `.imo` 对得上（`BASE` 都在 -97° 附近）。
- `photo_pose.py` 把这套解成 `eidolon.motion/1`，端上用现有 `MotionPlayback` 就能放。

已验证 `pho_standd_ver01..03` 九段（base 循环 + check/gretng 待机小动作）在模拟器里
姿势自然、能播放。遗留：其他动作包（cherup、phone、gift、umbre…）还没进缓存，
要先在游戏里触发对应拍照姿势；`birth_*`、`straw_*` 这些同尺寸包是道具模型。
