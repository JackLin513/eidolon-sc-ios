# 3D 支线交接（MLTD 原生资源移植 → Unity spike）

日期：2026-11-07
接手对象：下一个 agent / 新会话
本文件不重复实现细节，细节以 `spikes/porting-3d/notes.md` 与 git 历史为准。

---

## 0. 一分钟速览

- **代码位置**：`/Users/jacklin/Developer/IdeaProjects/eidolon-sc-ios-3dspike`，是同一个仓库的 **git worktree**，分支 `spike/mltd-3d-static`（主仓库在 `../eidolon-sc-ios`，分支 `feat/welcome-web`）。**3D 工作只在这个 worktree 里做**，不要改 `EidolonIOS/`、`EidolonCore/`、`StandRenderer/`。
- **Unity 工程**：`spikes/porting-3d/unity-spike`（Unity 6000.3.27f2，走 `com.unity.pipeline`，可用 `unity` CLI 驱动）。
- **能做什么**（全部在 Unity 里验证过）：从游戏原始 UnityFS bundle 加载角色 → 播动作曲线 → 30 根辅助骨 → 头发/蝴蝶结/裙摆 sway → 32 个 blend shape 表情（眨眼、口型层叠）。
- **现在的状态（重要）**：`/tmp/mltd-*` 下的派生数据**已被系统清空**，`/tmp/mltd-venv` 也没了，Unity Editor 当前**没有在运行**。按 §1 重建即可，代码和结论都还在仓库里。（2026-11-07 上午已复验并恢复，见 §0.5：`build/` 里的派生数据其实没丢，恢复只需一条命令。）
- **游戏本体只读**：`~/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents`（6.9 GB bundle 缓存）。不要改游戏文件、不要绕过完整性检查、不要操作游戏窗口。

---

## 0.5 复验记录（2026-11-07 08:50–09:10，新会话）

**结论：工具链可用，端到端跑通**（游戏缓存 → bundle → 动作 EULR → 辅助骨 / sway / 表情 → Unity 截图）。下面只记本次实测到的事实和与上文不一致的地方。

### 工具与安装位置（都已在位，无需再装）

| 工具 | 版本 / 位置 | 备注 |
| --- | --- | --- |
| `unity` CLI | 1.0.0-beta.15，`~/.unity/bin/unity` | 有 beta.17 更新提示，未升 |
| Unity Editor | 6000.3.27f2，`/Applications/Unity/Hub/Editor/6000.3.27f2/Unity.app` | Personal license assigned |
| Python venv | `~/mltd-work/venv`，Python 3.12.0 + UnityPy 1.25.4 | 用 `/Library/Frameworks/Python.framework/Versions/3.12/bin/python3` 建；系统 `python3` 已是 3.14/3.15，别拿它装 UnityPy |
| `unity-cli` skill | `~/.claude/skills/unity-cli/SKILL.md` + `references/playmode-verification-loop.md` | 不在本会话的 DSH skill 目录里，直接读文件即可，内容仍适用 |

### 与上文不一致 / 需要更正的地方

1. **`build/` 没被清，别重新生成动作和 IL2CPP 数据。** `eidolon-sc-ios-3dspike/build/mltd-spike/out/curves/loveig.motion.json`（1.32 MB、3901 帧）和 `out/il2cpp/{loveig-curves.json,dump.cs,il2cpp.h,native-*.json}` 都在；索引 `build/mltd-index.jsonl`（1557 行）、`build/mltd-index-assets.jsonl`（9564 行）也在。只有 `build/mltd-spike/assets/`（下载下来的 bundle 拷贝）没了。
2. **恢复根本不需要 §1 的手工 4 步**：新脚本 `spikes/porting-3d/prepare_work.py` 一条命令搞定（见下）。
3. **§2.1 的两条命令必须显式开**，否则未聚焦 Editor 会冻在 frame 1、`status` 却仍报 `playing`：
   `unity command editor.set_auto_tick`、`unity command editor.playmode set_run_in_background`。
4. 本工程 pipeline 包是 0.10.0-exp.1，**没有 `wait_for`**。证明在推进用 `editor status` 的 `frameCount` + 两张不同帧截图。
5. 表情表扫描**要 ~3 分钟**（Cache00 约 1.77 万个候选文件逐个开 UnityPy），不是卡死。

### 一条命令重建第 2 层（本次新增 `prepare_work.py`）

```sh
WT=/Users/jacklin/Developer/IdeaProjects/eidolon-sc-ios-3dspike
~/mltd-work/venv/bin/python $WT/spikes/porting-3d/prepare_work.py \
  --cache ~/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents \
  --work ~/mltd-work --index $WT/build/mltd-index.jsonl \
  --costume ss003 --character 001har \
  --motion $WT/build/mltd-spike/out/curves/loveig.motion.json --start 600 --frames 900
```

幂等：已有的 bundle / 表情表 / 动作会复用（`--force` 重做）。它顺带写 `~/mltd-work/scene.json`，Unity 侧据此建场景，**不再需要往组件字段里手填绝对路径**。

### Unity 侧的变化（本次改动，未提交）

- `Assets/Editor/PlayMotion.cs`：`MLTD/Play Motion` 现在**打开已保存的场景**再进 Play；新增 `MLTD/Rebuild Play Scene`（`PlayMotion.BuildAndSaveScene()`），从 `$MLTD_WORK/scene.json` 构造 `CharacterBootstrap` 并存成 `Assets/Scenes/MLTDPlay.unity`。
- `Assets/Scripts/CharacterBootstrap.cs`：字段默认值从 `/tmp/...` 改成 `$MLTD_WORK`（默认 `~/mltd-work`）。
- `Assets/Scenes/MLTDPlay.unity` 已落盘（7427 字节）。注意 §5 的 `.gitignore` 大小写问题：它被 `assets/` 命中，`git status` 看不到，要入库得 `git add -f`。
- 三个改动都在 `spike/mltd-3d-static` 上，**没有 commit**。

### 本次验证到的运行状态（Editor 内 eval 读数）

- `Character` 加载 `cb_ss003_001har.unity3d` + `ch_ss003_001har.unity3d`；`EidolonMotionClip` 900 帧 / 56 track（POSITION 轨被 motion_to_eulr 滤掉，原 57）。
- `FaceCtrl`：61 个角色 / 28 个表情，`cid=001har`，`Describe()` 正常；`SetFace(6)+SetLip("A")`、`SetFace(18)+SetLip("I")` 都出图。
- `SwayPhysics` 两组：身体 16 根、头发 17 根（与 §4 的 ss003 记录一致）。
- Console：`error 0`；warn 全是既有的 `FindObjectOfType` 弃用等，无新增。

### 证据截图（在 `~/mltd-work/out/`）

`shot-01.png`、`shot-02.png`（不同帧，证明动作在推进）、`shot-face.png`（face 6 + 口型 A）、`shot-face2.png`（face 18 + 口型 I）、`shot-final.png`（用新入口重建场景后重放）、`shot-reopen.png`（关掉 Editor 再打开后的第一帧）。

**场景落盘验证过**：把 Editor 整个关掉重开（新进程 PID），只跑 `PlayMotion.Play()` 就直接加载 ss003 + 900 帧动作 + 61×28 表情表——磁盘上的 `MLTDPlay.unity` 已经带着正确配置，不再需要 eval 手填字段。

### 复跑路径（下次直接照做）

```sh
unity open $WT/spikes/porting-3d/unity-spike
unity status --until-ready --project-path $WT/spikes/porting-3d/unity-spike
unity command eval 'PlayMotion.Play()' --project-path $WT/spikes/porting-3d/unity-spike
# 等 12~16 s，确认在跑
unity command eval 'SwayShot.Request("/Users/jacklin/mltd-work/out/shot.png", 700);' --project-path …
```

收尾：`unity command editor.playmode stop`、`unity close <project>`（本次已做，Editor 现处于关闭状态）。

---

### 迁移完整性审计（2026-11-07，REA + IDA）

**结论：没有完整迁移**，当前是「静态角色 + 一支舞能看」的最小骨架。完整报告（矩阵、缺口、证据、修复顺序）：

- `spikes/porting-3d/audit-migration-2026-11-07.md`（3D worktree 里；含 P0/P1/P2 清单与函数级证据）

审计用了 REA 6.8.0（`global-metadata.dat` 清单：45,483 类型 / 270,248 方法，`FaceCtrl`=9605、`CalcBone`=15265、`SwayBone`=15301）+ IDA Pro 9.5（本次重新分析 702,223 函数，反编译 80+ 原生函数）。**IDA 已分析库已持久化到 `~/mltd-work/ida/UnityFramework.i64`**（原 `/tmp` 那份很容易被系统清掉，别再浪费时间重分析；反编译源码在 `~/mltd-work/ida-decomp/`，两份子审计在 `~/mltd-work/audit/`）。

当前 ss003 上就生效的 P0（不是"换衣服才暴露"）：

1. **Sway 碰撞体 `#n` 语义搞错**：`_sway` 的 `<joint>#n` 是「该关节下第 n 个 SwayCollider」（IDA `SwayFileIO.AttachSwayBone` 0x1C7726C 已证），移植当成文件扁平下标 → ss003 裙骨 22/22 全绑 KOSHI 骨盆球，大腿胶囊从未参与碰撞（Unity 运行态已复现）。
2. **body/head 两份 `_sway` 没合并**：游戏 `SwayFileIO.ImportCommon`（0x1C764FC）把 body/head 的 manager/collider/bone 全挂到同一个模型；移植拆成两个 `SwayPhysics` → 头发引用的 `KATA_L#0`/`KUBI#1/#2` 查不到，7 条绑错 ATAMA、1 条丢弃。
3. **Plane/Bridge 碰撞体未实现**（`SwayColliderMT.Check` 0x1C73424 分派 4 类），`bridgetgt` 未解析；ss003 就有 4 Plane + 2 Bridge。
4. **`CalcRotate` 不回写尾点**（原生 0x1C72220 在钳位后重算 curTip 并写 prevTip，还有 HitMuteForce 混合）；移植下一帧从窗口外继续积分。
5. **脸红链路 0%**：原生 `FaceCtrl.SetCheekValue`（0x379F840）写 `_IsReddish`/`_ReddishIntensity` + `CharacterDrawer`；移植没有，材质 `_IsReddish=0` → 永远不脸红。
6. **动作 30 fps 最近帧**：游戏 1/60 求值 + 插值（`SolveCurve` 0x37E80B8、`SetResultToTransforms` 0x37EE99C），移植无插值。

缺口分级与修复顺序见审计报告 §3/§6；ROT 轴语义与 `facialMenu` 名字仍是未知项（§4.6）。

---

## 1. 从零恢复环境

> 下面命令里的 `WORK` 建议改成体面目录（见 §5 隔离方案），现在等于 `/tmp/mltd-unity-*` 的老布局。

```sh
WT=/Users/jacklin/Developer/IdeaProjects/eidolon-sc-ios-3dspike
PRJ=$WT/spikes/porting-3d
CACHE=~/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents

# 1) venv（UnityPy 1.25.4）。别放 /tmp，会被清。
python3 -m venv ~/mltd-work/venv
~/mltd-work/venv/bin/pip install UnityPy

# 2) 派生数据目录
mkdir -p ~/mltd-work/{bundles,motions,out}

# 3) 从游戏缓存里取角色/演出服 bundle（按内容识别，不靠文件名）
#    缓存里的文件名是 68~72 位哈希；索引 build/mltd-index.jsonl 记录了每个包里的对象统计
#    （脚本在 §2.3，需要按 costume 过滤后复制，并把 AssetBundle 的内嵌名当文件名）

# 4) Unity 工程
unity open $PRJ/unity-spike
unity status --until-ready --project-path $PRJ/unity-spike
```

**重建场景（当前没有 .unity 文件，必须重建）**：
工程里没有保存的场景，`Assets/Editor/PlayMotion.cs` 的 `MLTD/Play Motion` 菜单会新建 `Character`（挂 `CharacterBootstrap`）+ 平行光并进入 Play。当前配置（ss003 演出服 + 30 秒舞蹈）是手填在 `CharacterBootstrap` 字段上的，重启后要重新填：

```sh
unity command eval 'var b=GameObject.Find("Character").GetComponent<CharacterBootstrap>(); b.bundleDirectory="…/bundles"; b.bodyBundle="cb_ss003_001har.unity3d"; b.headBundle="ch_ss003_001har.unity3d"; b.clipPath="…/out/dance.bin"; b.facialParamsPath="…/out/facial_chara.json";' --project-path $PRJ/unity-spike
```

> 这一步本身就是缺陷（见 §5）：配置没有落到磁盘。接手后第一件事建议先把 `PlayMotion` 改成从环境变量 + 参数构造，让它成为唯一入口。

---

## 2. 工具用法（重点，踩过的坑都在这）

### 2.1 `unity` CLI 驱动 Editor

`unity` 是命令行工具，通过 `com.unity.pipeline` 连本地 Editor。常用：

```sh
unity command eval '<C# 语句>' --project-path $PRJ/unity-spike   # 在 Editor 里跑任意 C#
unity command editor.playmode start|stop --project-path …         # 进出 Play
unity command editor.set_auto_tick --project-path …               # Play 时后台仍推进
unity command editor.playmode set_run_in_background --project-path …
unity command editor status --project-path …                     # 看 playMode / frameCount / ticking
unity command console get --project-path …                        # 看编译/运行错误
unity command capture game_view --project-path … -- --output-path … --width 700 --height 700
```

**三条必须记住的坑**：

1. **改脚本（recompile）之后，正在运行的 Play 会话里的组件状态会失效**——典型表现是 `SwayPhysics.rig == null`、`Count == 0`。`eval` 不会报错，只是所有绑定都没了。**改完代码必须 `playmode stop` → 等 4~5 秒 → `playmode start` → 等 12~16 秒**，然后再操作。
2. **未聚焦的 Editor 截图 / `Camera.Render()` 可能拿到旧蒙皮帧**（改骨骼完全没反应，浪费过一整轮排查）。可靠做法是 `Application.onBeforeRender` 里渲到 RenderTexture 再存 PNG——已经封装成 `SwayShot.Request(path, size)`（`Assets/Editor/SwayProbe.cs`），**所有验证截图都走它**。
3. `eval` 里别写多行/泛型推断太复杂的代码；出错信息只有一句 CS 错误。字符串拼接、`System.Text.StringBuilder` 写文件（`File.WriteAllText("/tmp/x.txt", …)`）再 `cat` 是最稳的取值方式——直接返回大字符串会被 CLI 截断。

### 2.2 Editor 端探针（`Assets/Editor/`）

| 探针 | 用途 |
| --- | --- |
| `SwayShot.Request(path, size)` | 可靠截图（onBeforeRender → RenderTexture → PNG） |
| `SwayProbe.Describe/Settle/Clearance` | sway 骨骼状态、与碰撞体的最小间隙（负值=陷进去） |
| `SwayMeshProbe.Measure(SwaySolver)` / `MeasureRig(SwayPhysics)` | 布料顶点陷进大腿胶囊的数量与最大深度 |
| `ArmProbe.Hit/Drawn/DrawnGrid` | 逐三角形射线求交：某像素下是哪一层表面、法线朝向、深度层数 |
| `ElbowProbe.Bones(renderer, joint, radius)` | 某关节附近的顶点由哪些骨骼主导（权重统计） |
| `MotionProbe` / `BundleProbe` / `DriveProbe` | 包内对象、动作曲线、驱动参数的一次性报告 |
| `ShowCharacter.Show()`（菜单 `MLTD/Show Character`） | 把角色 prefab 静态放进场景看 |
| `PlayMotion.Play()`（菜单 `MLTD/Play Motion`） | 建场景 + 进 Play |

### 2.3 Python 工具（`spikes/porting-3d/`）

| 脚本 | 作用 | 备注 |
| --- | --- | --- |
| `index_cache.py` | 扫游戏缓存，输出每个包的对象统计 → `build/mltd-index.jsonl` | 按**内容**识别，缓存文件名是哈希 |
| `extract_facial_params.py` | 在缓存里找 `facial_chara`（`FaceScrObj`）→ 导出表情权重表 JSON | **已验证可重复生成**（两次输出 md5 一致） |
| `motion_to_eulr.py` | `eidolon.motion/1` → Unity spike 的 `EULR` 二进制 | 新增，支持 `--start/--frames/--skip-position` |
| `photo_pose.py` | 从照片姿势 clip 解码曲线（含 `m_ClipBindingConstant` 解析） | 参考它的 binding 解析方式 |
| `compress_motion.py` | `loveig-curves.json` → `eidolon.motion/1` | 舞蹈 130 秒 / 3901 帧 |
| `mltd_assets.py` / `fetch_assets.py` | 走 MLTD CDN 下载包 | **CDN 现在对匿名请求一律 403**（连不存在的文件名也是 403），暂时不可用 |
| `motion.py` | 曲线采样/量化/打包（`unpack_curve`、`decode_channel`） | `motion_to_eulr.py` 复用它的语义 |

### 2.4 排查渲染问题的取证套路

一个"看起来坏了"的区域，按这个顺序定性，别猜：

1. 换 **`Unlit/Color` 或 `Unlit/Texture`** 材质 → 还难看不见说明几何/UV 没问题，是着色。
2. 换 **`_OutlineColor` 成绿色** → 整块变绿就是描边壳；换 **`_CullMode`** 0/1/2 → 区分正反面。
3. 用 `ArmProbe.Hit` 看同一像素底下有几层表面、法线是不是朝相机（`nDotView < 0` 才是正向面）。
4. 用 `ElbowProbe.Bones` 看权重，判断是不是某根（辅助）骨没被驱动。
5. 数值化再收尾：`SwayMeshProbe.Measure*`、`SwayProbe.Clearance`。

---

## 3. 运行时结构（`Assets/Scripts/`）

| 文件 | 职责 |
| --- | --- |
| `CharacterBootstrap.cs` | 从 bundle 建角色、把头挂到 `ATAMA`、加载 `EULR` 动作、副作用修正（描边深度）、绑定 sway 与表情 |
| `EidolonMotionClip.cs` | `EULR` 读取 |
| `HelperBones.cs` | 复刻 `Imas.BoneLib.CalcBone`：30 根辅助骨，slerp/twist/rot/const，参数首字母选轴 |
| `SwayData.cs` / `SwayRig.cs` | `_sway` 文本解析与绑到 Transform 树 |
| `SwayPhysics.cs` | 复刻 `SwayBoneMT` V01：骨尖弹簧 + 碰撞推出 + 角度窗口 + sideLink |
| `SwaySolver.cs` | 旧的裙摆 `i70` 直摆实现，默认已关（`useSkirtDrape=false`），留作 A/B |
| `FaceCtrl.cs` | 表情表（`cid` → 28 个表情 × 2 列权重）、眨眼、0.1333 s 过渡、口型层叠 |
| `OrbitCamera.cs` | Game 窗口右键旋转 / 中键平移 / 滚轮缩放 / F 复位 |

---

## 4. 已完成 / 未完成

已完成（细节见 `notes.md` 对应小节，提交见 `git log -- spikes/porting-3d`）：
辅助骨（手肘压皱）、描边壳穿出裙褶、头发+蝴蝶结 sway、裙摆物理（含 i70 基线与 sideLink）、面部表情（原生参数表 + 过渡 + 口型层叠）、演出服 ss003 + 30 秒舞蹈验证。

未完成：
1. **表情语义**：表里只有 `cid` + 28 个无名表情；哪个对应高兴/害羞还没标。
2. **表情/口型联动**：`SetLip` 有了但没人驱动（要等通话链路给音量/音素）。
3. **动作库**：只有一条站立 clip + 一段舞蹈切片；没有动作过渡/混合。
4. **搬到 iOS**：整车仍在 Unity spike；`EidolonIOS`/`EidolonCore` 未动（按约定）。
5. **场景未落盘**（见 §5）。

---

## 5. 隔离：现在"串在一起"的三个地方 + 建议

### 诊断

1. **派生数据和工程靠 `/tmp` 绝对路径耦合**：角色 bundle、动作、表情 JSON 全在 `/tmp/mltd-unity-*`，`CharacterBootstrap` 的字段和场景里存的就是这些绝对路径。`/tmp` 一被清（今天已经发生），工程就打不开数据。
2. **`.gitignore` 把 Unity 的 `Assets/` 整个忽略了**：`spikes/porting-3d/.gitignore` 第一行是 `assets/`（小写）。macOS 文件系统大小写不敏感，于是 `Assets/` 也命中——新加的 `.cs` 不会出现在 `git status` 里，必须 `git add -f`。这很容易被误判成"文件混进游戏目录/没进库"。
3. **场景/配置不落盘**：工程里没有 `.unity`、`m_Scenes` 为空，运行配置是手填在内存里的组件字段。等于"环境只活在一次 Editor 会话里"。

另外确认过：**仓库里没有任何游戏二进制**（`git ls-files` 里 `.unity3d/.usdz/.png` 为 0），游戏缓存只读，这一点是干净的。

### 建议的三层隔离（推荐直接做）

```
第 1 层  游戏安装          ~/Library/Containers/jp.co.../Documents   ← 只读，工具只接受 --cache 参数，绝不写
第 2 层  派生工作区        ~/mltd-work/{venv,bundles,motions,out}     ← 不在仓库内，可随时删了重建
第 3 层  仓库              eidolon-sc-ios-3dspike/spikes/porting-3d   ← 只有代码/文档；派生数据一律 gitignore
```

具体改动（按优先级）：

1. **把 `/tmp` 换成一个环境变量**：所有 Python 工具和 C# 探针统一读 `MLTD_WORK`（默认 `~/mltd-work`），派生目录为 `$MLTD_WORK/{bundles,motions,out}`。C# 侧现在已经有 `MLTD_BUNDLES/MLTD_MOTIONS/MLTD_OUT/MLTD_CLIP` 的先例，`CharacterBootstrap` 的字段也改成"空则读环境变量"。
2. **一条幂等的 `prepare_work.py`**：`--cache … --costume ss003 --character 001har` → 复制 bundle、跑 `extract_facial_params.py`、跑 `motion_to_eulr.py`，一次把第 2 层整个重建出来。今天手工做了 4 步，应该合成 1 条命令。
3. **`PlayMotion` 变成唯一入口**：从环境变量/命令行参数构造 `CharacterBootstrap`，并且**把场景存成 `Assets/Scenes/MLTDPlay.unity`**（现在这个分支根本没生成过这个文件）。这样"打开工程 → 跑一条命令 → 就能看"。
4. **修 `.gitignore`**：把 `assets/` 改成精确路径（例如把下载目录改名 `spikes/porting-3d/downloaded/` 并只忽略它），Unity 的 `Assets/` 必须正常入库；同时只忽略 `unity-spike/Library/`、`Temp/`、`Logs/`、`obj/`。
5. （可选）如果希望 3D 支线彻底不污染主仓库历史，可以把它拆成独立仓库而不是 worktree；但以现在"只在一个 worktree、一个分支、从不 push"的用法，worktree + 精确 gitignore 已经够了，不建议为此拆库。

---

## 6. 已知坑速查

| 现象 | 原因 / 解法 |
| --- | --- |
| `SwayPhysics.rig == null`、绑定数 0 | recompile 造成 domain reload；重启 Play（§2.1 坑 1） |
| 截图和实际不符、改骨骼没反应 | 未聚焦 Editor 的旧帧；一律用 `SwayShot` |
| 新 `.cs` 不进 `git status` | `.gitignore` 的 `assets/` 大小写命中 `Assets/`；`git add -f` 或按 §5 修掉 |
| 裙摆塌成"伞" | 乘法顺序：必须 `follow * (parent.rotation * restLocal)`，反过来就错 |
| 手肘深色楔形 | 辅助骨 `HIJI_*__rot_*` 没驱动；ROT 必须按参数首字母选轴 |
| 裙背深棕色块 | 描边壳穿出布料；推 `_ZShift1000Min/Max`（`FixOutlineDepth`） |
| 表情错位（`SetFace(5)` 取到别的角色） | 表情表顶层是**角色**，要先按 `cid` 收窄 |
| CDN 下载 403 | 匿名请求一律 403，改用本地游戏缓存 |
| `/tmp/mltd-*` 消失 | 系统清理 `/tmp`；按 §5 迁到 `~/mltd-work` |

---

## 7. 建议技能（下个 agent 开局先调）

- **`unity:unity-cli`** —— 必调。驱动 Editor、playmode、eval、截图都在这里，本交接 §2.1 的坑它也有类似说明。
- 需要再反编译游戏时：**`reverse-engineer-anything`**（REA），以及 IDA 相关 MCP；本次用到的地址/结论已写进 `notes.md` 与 `research-mltd-*.md`。
- 要改 iOS 端渲染器时：**`unity` 那套技能用不上**，直接看 `spikes/porting-3d/ios/`（Swift 侧的 `MotionAssist`/`MotionSway` 是同一套算法的参考实现）。

---

## 8. 建议的下一步（按价值排序）

1. 做 §5 的第 1~4 项（隔离 + 一键重建 + 场景落盘）——今天 `/tmp` 蒸发已经证明这不是洁癖问题。
2. 把 28 个表情逐个渲染出来命名，接到对话引擎的情绪上。
3. 通话链路接进来后，用音量驱动 `FaceCtrl.SetLip`。
4. 决定"搬进 iOS"的范围，再开单独的 spec（按项目规矩：先 spec 后实现）。

---

## 9. 原生一致迁移状态（2026-11-07 下午–晚，ADR-0033）

按 `docs/adr/0033-native-faithful-3d-migration.md` 执行；进度与证据以 `spikes/porting-3d/migration-progress.md`、`spikes/porting-3d/audit-migration-2026-11-07.md` 和 git log 为准。

- **B1 动作 + CalcBone：完成**。原始 imo（8 key_type/optional/多动作/连续求值）+ `CalcBoneNative`（8 算法含 TITE、z 轴 `__rot` 走原生 SLERP 分支）。
- **B2 Sway：完成**。5 文件按原生类边界重写；合并 body/head rig、`<joint>#k` per-joint、四趟、Plane/Bridge、CalcRotate 回写、followRate/damper/antiFold 等；数值探针修掉胶囊半径 bug（-63mm→-5.5mm）。
- **B3 表情：完成**。`FaceCtrlNative`+`TransitionModuleNative`；**28 个表情名已解出**（通常/明るい/…/右ウィンク/左ウィンク）、lipChar[60]、cheek 材质联动（`_IsReddish`/`_ReddishIntensity`/`_ISREDDISH_ON`）。
- **B4 视线+接地影：完成**。`EyeTrackingNative`+`EyeTrackingDriver`（每帧 EyeUpdate）、`DropShadowNative`（CIRCLE 等 4 模式）+ `chara_shadow.unity3d`；脚下接地影已出现。
- **B5 装配/材质：部分**。`CharacterSoulNative`（61 角色，cheek intensity 已注入 FaceCtrl）、`CharacterDrawerNative` 角色子集、`JointBodyHeadNative` 开关/运行时 sway 数组；JDK 完整 Initialize/模型切换/眼镜/配件显示、Drawer apply_color/Live 绘制管线仍是已知缺口。
- **旧近似实现已删除**：HelperBones/SwayPhysics/SwayRig/SwayData/SwaySolver/EidolonMotionClip/旧 SwayProbe；`CharacterBootstrap` 收敛为纯原生管线。

资源与运行：

```sh
# 版本锁定快照（matsurihi 版本 API + CDN manifest）
python3 spikes/porting-3d/fetch_snapshot.py --work ~/mltd-work --version latest --names dan_loveig_01.imo.unity3d,chara_shadow.unity3d,chara_soul.unity3d,...
# 原始 imo 导出
python3 spikes/porting-3d/export_imo.py --bundle <imo.unity3d> --out ~/mltd-work/motion
# Unity：打开工程 -> PlayMotion.Play()
```

- 当前快照：asset version **1078590**（2026-11-06）；`~/mltd-work/assets/1078590/`
- 游戏内参考图：`~/mltd-work/ref/game/`（15 张；缺舞蹈帧——进 LIVE 需选曲/体力，未操作；服装 ss003 未确认）
- 自采对照图：`~/mltd-work/out/native-ref-{front,side,back,face,skirt}.png`、`final-native-pipeline.png`

已知未知/data-gap（均不伪造，代码里标 UNKNOWN/known-unknown）：`lipParam[11,14]`（metadata 编译器 blob）、B5 的 JBH 完整装配与颜色/bodyScale/breast sway 映射、B4 的舞台相机/LiveInfo 输入与 `shadowScaleVectorOverride`、Live/舞台管线明确 out-of-scope。
