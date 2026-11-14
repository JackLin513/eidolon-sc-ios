# ADR-0033：3D 支线按原生语义整体迁移，不做近似与自创

日期：2026-11-07
状态：已接受

## 背景

`spikes/porting-3d/unity-spike` 是 3D 原生资产路线的技术验证工程。它已经证明「游戏自己的 bundle →
骨骼/蒙皮/材质 → 动作曲线 → 辅助骨 → sway → 表情 → 截图」这条链路能跑通，但迁移完整性审计
（`spikes/porting-3d/audit-migration-2026-11-07.md`）显示：它只是「静态角色 + 一支舞能看」的最小骨架，
与原生实现有大量语义差异，其中一部分是此前为了尽快出画面而做的近似：

- 动作被离线重采样为 30 fps + 端上最近帧（原生 1/60 网格 + 按 key_type 插值）；
- sway 把 `<joint>#n` 当成扁平碰撞体下标（原生是该关节下第 n 个），裙摆只撞骨盆球；
- body/head 两份 `_sway` 没有合并成一个 rig（原生 `SwayFileIO.ImportCommon` 合并）；
- `CalcRotate` 用世界 up/径向近似角度窗、不把钳位后的尾点写回（原生写回，还有 HitMute）；
- 裙摆基线硬编码 0.7（原生是 `HelperBones` 的 slerp + SwayMove 的 skirt fall follow）；
- 表情缺脸红/TransitionModule/muteLip/口型表；EyeTracking、DropShadow、CharacterDrawer 联动完全缺失；
- CalcBone 只实现 4/8 种算法（TITE_* 缺失）。

这些近似会持续制造「看起来像但总有奇怪小 bug」的现象，且每个 bug 都要重新对照原生代码才能定位。

## 决定

1. **范围：先把角色本体与动作迁移完整，再谈舞台。** 本轮迁移批次固定为：
   - B1 动作数据与播放器（原始 imo、1/60 求值、全部 key_type、optional 曲线、多动作/循环/位置语义）
     + `CalcBone` 全部 8 种算法（含 4 个 TITE）；
   - B2 `SwayBoneMT` V01 全语义（SwayManager/SwayBone/SwayCollider/MT 结构、合并 rig、per-joint 碰撞体、
     Plane/Bridge、四趟更新顺序、CalcRotate 回写/HitMute、followRate/damper/antiFold/侧线、固定步长）；
   - B3 `FaceCtrl` + `TransitionModule` + 脸红材质联动 + muteLip/lip 表/闭眼/唱歌；
   - B4 `EyeTracking` + `DropShadow`（资产在、组件接线按原生重建）；
   - B5 `CharacterDrawer`（角色相关的描边/颜色/mono/rim/z-shift/眼高光/spotlight）与 `JointBodyHead` 装配/开关。
   舞台与 Live 编排（风场、升降/走位、Bookmark、CommandBuffer 绘制/镜像、LOD/裁剪、Record/临时调参、
   加载进度）**不在本轮**，等角色本体完整后再单独立项。
   - **B6（2026-11-07 追加，载体见 [ADR-0034](0034-3d-stand-unity-as-a-library.md)）**：B1–B5 的 23 个原生文件
     原样搬入 iOS App（Unity as a Library，Unity 6000.3）；新增 Swift 侧 `UnityStandRenderer`（ADR-0017
     `StandRenderer` 的第三实现）与对话驱动（上游 `standDirection` 语义 → FaceCtrl 表情/lip/眨眼循环）；
     内容包承载 UnityFS bundle（本体不变），Unity 运行时 framework 进 App。舞台与 Live 编排的排除不变。

2. **实现形态：按原生类边界重写，删除近似实现。** 新代码按原生类/结构体一一对应
   （`SwayBoneMT.FixedParams/WorkingParams/SideLinkParams/ColliderParams`、`SwayManager/SwayBone/SwayCollider`、
   `CalcBone`、`FaceCtrl/TransitionModule`、`CharacterImasMotionPlayer(Dance)/Data`、`JointBodyHead`、
   `EyeTracking`、`DropShadow`、`CharacterDrawer` 子集）。旧的 `SwaySolver`/`SwayPhysics` 等近似实现删除
   （git 历史保留）；Editor 探针保留并改造成验收工具。

3. **只允许性能层的等价替换，禁止行为层自创。**
   允许：Jobs/Burst → 串行 C#；`TransformAccess`/`NativeArray` → `Transform`/数组；原生内联 helper 按语义展开；
   对象池。
   禁止：改公式/常数/参数默认值；用硬编码替代数据（0.7 基线、30 fps 烘焙之类）；用近似几何替代原生几何；
   跳过原生分支；用「看起来差不多」的默认值顶替缺失数据。

4. **动作数据：端上消费原始 imo 资产。** 逐条曲线保留 `property_type`/`key_type`/keys 与
   `CharaOptionalImoData` 的 optional 资产，端上按原生 `SolveCurve` 在 1/60 网格上求值与插值。
   禁止改用 30 fps 重采样或最近帧。端上数据格式必须无损（允许量化，但量化误差与原生一致并记录）。

5. **资产：版本锁定快照，不从游戏运行时依赖。** 用 matsurihi.me 的资产版本 API 取得
   `asset.version` 与 `indexName`（或指定版本），从 `td-assets.bn765.com` 拉 manifest 与指定资产，
   校验大小并记录 sha256；快照落在 `$MLTD_WORK/assets/<version>/`（manifest、条目映射、每个文件的 sha256）。
   游戏安装缓存只做交叉核对，不作为首选来源。**不伪造资源**：原生资产缺失时记 `data-gap`，
   代码按原生写全、以空资源跑通，等资产补齐立即生效。

6. **验收：公式级 + 数值级 + 视觉抽查。**
   - 每个迁移函数与 IDA 反编译逐行对应（地址写在注释里）；
   - 数值对拍：EditMode/PlayMode 测试 + 全量语料参数回归 + 运行态探针；
   - 关键姿态截图与游戏内参考截图人工对比（用户提供或自动化采集）；
   - 表情名称等纯元数据未知记为 `known-unknown`，不阻塞行为迁移，也不假装已解出。

7. **交付节奏：每批可运行、可截图、可回滚。** 每批结束：Unity 编译零错误、场景能跑、截图 + 探针数值、
   commit 到 `spike/mltd-3d-static`；ADR/GLOSSARY/审计文档随批次更新。

## 后果

- 工作量显著增加：这是「重新实现」而不是「打补丁」。好处是每个差异都能对着 IDA 定位，bug 面收敛。
- 现有截图外观会变化（更接近游戏），旧近似组件的删除会让 `CharacterBootstrap` 接线重写。
- 动作与资产数据体积变化：保留原始曲线结构、可选曲线与版本快照，需要新的端上二进制格式与导出脚本。
- `GLOSSARY.md` 增加「3D 迁移」词汇（原生一致、性能层等价替换、数据快照、批次、已知未知）。
- 推翻了此前 spike 的隐含默认（「近似到能看即可」）；此后 3D 支线的验收标准以本 ADR 为准。
