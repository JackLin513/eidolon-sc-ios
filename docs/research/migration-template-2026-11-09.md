# 3D 支线合入与跨企划迁移模板调研（2026-11-09）

调查日期 2026-11-09。**只读调查**：没有改代码、没有提交、没有读 `.env`；没有运行 Unity / Xcode / App，也没有下载或解包任何游戏资源。三个来源：

| 来源 | 版本 | 用途 |
|---|---|---|
| 本仓库 main | worktree HEAD `8c05c7de` | 被调查基线；承接上一份 [组件化调研](componentization-2026-11-09.md) |
| 3D 支线 | 主仓库 checkout `feat/mltd-3d-stand` `f9b09b8a`（比 main 多 306 个提交）；spike worktree `spike/mltd-3d-static` `962ade0d` | 「3D 内容如何合入 main」 |
| 四个迁移目标 | 官方站点、App Store / Google Play 元数据、官方开发者演讲（CEDEC / Epic Games Japan）、官方规约与 EULA 原文、开源工具仓库 | 「未来怎么模板化」 |

方法：3D 部分读代码与 git diff，构建前提在 `/tmp` 复制 `project.yml` 做了最小复现（未动 checkout）；迁移目标部分由三路后台调研分头查一手来源，本笔记汇总并抽查了关键官方页面（App Store lookup、CEDiL、Steam EULA、官方公告）。社区事实与未知分开标注，推断处写「推断」。

## 0 结论摘要

1. **接缝成立，契约没跟上。** 3D 支线没有改 `EidolonCore`，`StandRenderer` 协议也零改动，`UnityStandRenderer` 作为第三个实现接上了（`EidolonIOS/Features/Stand/UnityStandRenderer.swift:16`）。但 `StandRenderer` 的回报类型是 Spine 形状（动画名→时长），3D 适配器只能伪造一整张 Spine 名字表（`UnityStandRenderer.swift:226-244`）；`load(outfit)` 也被绕过，真正加载哪个模型来自环境变量。
2. **合入 main 的阻塞不是代码，是构建前提与仓库卫生。** 3D 运行时/内容是被 `.gitignore` 的生成物，却被 `project.yml:50-53` 写成必需源目录——干净 checkout 跑 `xcodegen` 会直接失败；`UnityStandRuntime.swift:3` 的 `import UnityFramework` 是编译期硬依赖；App 体积实际约 +378 MB；已提交的 `EidolonIOS.xcodeproj` 落后于源码；仓库里还有约 4 MB 游戏派生数据。
3. **推翻已接受 ADR 的决策没有落地。** 3D 支线引用 `ADR-0034`（Unity as a Library），但 `docs/adr/` 里只有 0033，链接是死的；而 main 上已接受的 ADR-0022 明确把「在 iOS 上跑 Unity 运行时」列为不选（`docs/adr/0022-3d-native-assets-runtime-skinning.md:13`）。合入前必须补 0034 并在 0022 标「被取代」。
4. **main 侧 P0 只有六件事**：可选编译/目标隔离、渲染器能力契约替代 `standIs3D`、3D 内容包 kind/manifest、角色↔模型映射、仓库卫生与提交工程、补 ADR-0034 + 文档。它们都属于组件化的 Phase 0/1/2，**不需要先拆包**。
5. **四类迁移目标的结论不同。** 学マス / CGSS 技术上最可行的是「2D 卡面 + 剧情语料 + 语音」；两作都是 Unity + CRI 音频、资产管线同构，但 3D Live 不建议进模板。星耀季节应作为**负向测试用例**：UE4.24 + 自定义 toon 渲染，且 EULA 明确禁止逆向/修改/衍生。galgame 是「引擎族问题」，模板应定义**中性 VN IR + 每作品适配器**，设备只跑 IR。
6. **模板的核心不是「支持更多格式」，是「输出侧契约 + 输入侧适配器」。** 模板只分发 schema、IR、提取器接口与展示逻辑；素材由用户在本机生成、不上传、不分发。每作品真正必须单独做的是清单/容器/字段解码，这部分无法模板化。

## 1 3D 支线现状

### 1.1 分支账

`git diff --stat 8c05c7de..feat/mltd-3d-stand`：**342 个文件，+53,866 −40**；`git log --oneline 8c05c7de..feat/mltd-3d-stand` 共 **306 个提交**。

| 组 | 文件 | 行数 | 说明 |
|---|---:|---:|---|
| 主 App 代码（Stand 4 新 + Support 4 + App 2 + Call 2 + Chat 1 + Settings 1） | 14 | +1,182 −24 | 渲染器适配器、UaaL 桥、预览/诊断页、通话页接入 |
| 工程定义（`project.yml` + `EidolonIOS.xcodeproj`） | 3 | +125 −16 | `xcodeproj` 是 xcodegen 产物，仓库约定也入库 |
| UI 测试 | 1 | +52 | `EidolonIOSUITests/Stand3DPlaygroundUITests.swift` |
| 工具 | 4 | +556 | 3D 内容抓取、测试角色注入、模拟器构建、iPad 安装 |
| `spikes/porting-3d`（Unity 工程 + 移植代码 + 证据） | 310 | +49,683 | 入库约 6.2 MB；本地工作目录约 12 GB（`Library/` 等被忽略） |
| 文档 + GLOSSARY + `.gitignore` | 10 | +2,268 | 其中 3 篇 1,460 行与本支线无关（P2-1） |
| **`EidolonCore`** | **0** | **0** | `git diff --stat … -- EidolonCore` 为空；1,155 个 Core 测试无冲突面 |

生成物（都不在仓库，被 `.gitignore` 覆盖）：`EidolonIOS/UnityRuntime/`（`UnityFramework.framework` 约 129 MB）、`EidolonIOS/Resources/Unity/`（Unity `Data` 约 22 MB）、`build/Unity3DContent/`（约 227 MB：模型 103 MB + 动作 122 MB + 共享表）。

### 1.2 接缝评估：协议成立，语义不合

**成立的部分**：`StandRenderer` 协议本体零改动（`EidolonIOS/Features/Stand/StandRenderer.swift:10`），`UnityStandRenderer` 实现全部成员并复用 `StandHostView`；2D 仍是默认路径（`CallView.swift:304-306`）；加载失败能退回 2D/头像（`CallView.swift:256-263`）。这说明上一份调研的判断是对的：**渲染器接缝是这套代码里最成功的一处抽象**。

**语义不合的四处**：

| # | 问题 | 证据 |
|---|---|---|
| 1 | 回报类型是 Spine 形状 | `StandPose.Report.animations: [String: Double]`（`EidolonCore/Sources/EidolonCore/StandRender.swift:208-216`）；3D 适配器伪造整张表（`UnityStandRenderer.swift:226-244`） |
| 2 | `load(_ outfit:)` 契约没被遵守 | 传入的 outfit 只存成 `model`，真正发送的角色/衣装来自环境变量与 UserDefaults（`UnityStandRenderer.swift:50-59,96-99`） |
| 3 | 页面知道自己是 3D | `standIs3D` 布尔 + 整屏层 + 46pt 下移 + 背景压暗（`CallView.swift:57,70-105,195`） |
| 4 | 失败语义不同 | 3D 先重试约 30 次×1.5 秒才报失败（`UnityStandRenderer.swift:129-150`），Web 渲染器是即时报错 |

### 1.3 原型假设清单

| # | 假设 | 证据 | 为什么是问题 |
|---|---|---|---|
| L1 | `EIDOLON_3D_*` 环境变量在 Release 也生效 | `RootView.swift:15-16`（无 `#if DEBUG`）、`CallView.swift:220,277`、`UnityStandRenderer.swift:50-59` | 正式包可被环境变量改渲染路径 |
| L2 | 默认模型 `001har`、衣装 `pr001` | `UnityStandRenderer.swift:55,59` | 没有角色↔模型的数据映射 |
| L3 | `standIs3D` 布尔 | `CallView.swift:57,89,101,195,259` | 渲染器能力被压成二值；第三种渲染器/无 3D 能力无处表达 |
| L4 | 2D 名册与 MLTD 角色不对应 | `UnityStandRenderer.swift:10-14` 自认；`CallView.swift:222,274,288`；`tools/add_3d_test_character.py` | 3D 只是「SC 角色框架 + 可选 MLTD 形象」；`haruka3d` 是注入的占位角色 |
| L5 | 3D 内容从 App bundle 读 | `UnityStandRuntime.swift:19-49`、`UnityStandCatalog.swift:22-49`、`project.yml:50-53` | 绕过 ADR-0020 立绘包机制：无版本、无 CRC、无原子安装；227 MB 进二进制 |
| L6 | `UnityFramework` 编译期依赖 | `UnityStandRuntime.swift:3`、`UnityStandBridge.mm:3`、`EidolonIOS-Bridging-Header.h:2`、`project.yml:30` | 没有 framework 就没有 `import`，App target 编不过 |
| L7 | 测试角色注入内容包 | `tools/add_3d_test_character.py:16-17`、`tools/install_ipad.sh:9` | 正式内容包要能被「打补丁」，说明角色不在数据管线里 |
| L8 | 表情映射双写 | `UnityStandRenderer.swift:214-223` vs `tools/fetch_unity3d_content.py` 的 `EMOTION_MAP` | 两份表会漂移；「内容包优先」没有实现 |
| L9 | 调试偏好直读 `UserDefaults` | `UnityStandRenderer.swift:51-59`、`EidolonIOS/Features/Stand/UnityStandPlaygroundView.swift:93-101,134`、`SettingsView.swift:35-36` | App 直接读写全局偏好，不经设置层 |
| L10 | Unity 窗口/透明黑魔法 | `UnityStandBridge.mm:53-66`（隐藏 Unity window 防吞触摸）、`docs/3d-stand-prototype-status.md`（透明合成失败，只能深色底） | 平台集成细节仍在试错，不是稳定接口 |

### 1.4 构建与仓库风险（合入前必须知道）

1. **干净 checkout 的 `xcodegen` 会失败。** `project.yml:50-53` 把两个被忽略的目录写成必需 source；实测（xcodegen 2.46.0，在 `/tmp` 复制 `project.yml` + 空目录）删除这两个目录后报 `2 Spec validations errors`、退出码 1。给 folder source 加 `optional: true` 后 generate 通过（退出码 0）。
2. **缺 framework 不阻塞 generate，但阻塞编译/嵌入。** 实测缺 `UnityFramework.framework` 时 generate 仍返回 0，只生成悬挂的 `PBXFileReference`；真正失败发生在 Swift `import` 与 Embed Frameworks。`project.yml:28` 的注释说「缺它时 xcodegen 会报错」并不准确。
3. **体积是 +378 MB，不是 +200 MB。** framework 129 MB + Unity `Data` 22 MB + 3D 内容 227 MB；真机安装包约 500 MB（`docs/3d-stand-prototype-status.md` 记 500 MB）。`docs/3d-stand-integration-plan.md:168` 的「+~200MB」已过时。
4. **已提交的工程文件落后于源码。** `git show HEAD:EidolonIOS.xcodeproj/project.pbxproj | grep -c 'Stand3DPlaygroundUITests\|UnityStandPlaygroundView'` 为 0；committed scheme 的 `BuildableName` 与 `project.yml:59` 的 `PRODUCT_NAME = Eidolon` 不一致。工作区有 4 个未提交文件（pbxproj / xcscheme / StandScene.unity / ProjectSettings.asset）正是补齐这些。
5. **仓库卫生破了自家规矩。** 入库了约 3.96 MB 游戏派生动作数据（`spikes/porting-3d/evidence/daily-motion/haruka_intro.imo.json`，内容含源 bundle 名与曲线数值），以及一张被 force-add 的 png；与 `spikes/porting-3d/README.md:3`「游戏素材与转换产物一律不进仓库」、`docs/3d-branch-handoff-2026-11-07.md:241` 冲突。
6. **ADR-0034 不存在且与 ADR-0022 冲突。** `docs/adr/` 止于 `0033-native-faithful-3d-migration.md`；0033:35 链接的 `0034-3d-stand-unity-as-a-library.md` 是死链；main 的 ADR-0022:13 把「在 iOS 上跑 Unity 运行时」列为不选。推翻已接受 ADR 的决定不能只活在 `project.yml` 注释里。
7. **今天可以 fast-forward，但人工前提没满足。** merge-base 就是 `8c05c7de`，`git log 8c05c7de..feat/mltd-3d-stand` 306 条、反向为空；若 main 再前进，热点是 `AppModel` / `CallView` / `SettingsView` / `RootView` / `ChatView` / `project.yml`。仓库没有 CI，`main 还能构建`只能靠人跑验收命令。
8. **调试基础设施痕迹。** `tools/fetch_unity3d_content.py` 里硬编码了内网资产服务器地址与本地 token 文件路径（具体值不在这里复述）；`spikes/porting-3d/verification-playbook.md` 也有内网主机信息。公开仓库里应收敛为环境变量、无默认值。

## 2 main 侧操作清单

原则：这些操作属于组件化的 **Phase 0（写下来）/ Phase 1（shell 分层）/ Phase 2（typed 契约）**，不是 Phase 3 的拆包。组件化笔记明确「等真的出现第二种资产格式（比如 3D）再拆 `EidolonStand`」（`docs/research/componentization-2026-11-09.md` §4.1）。

### 2.1 P0（不满足就不该合入 main）

| # | 操作 | 理由 | 验收信号 |
|---|---|---|---|
| P0-1 | **可选编译 / 目标隔离**：两个 folder source 加 `optional: true`；把 Unity framework 依赖与 3D 文件拆到 `project-3d.yml`（xcodegen `include`），默认 spec 不含；Swift 用 `#if canImport(UnityFramework)`、ObjC 用 `#if __has_include(...)`，桥接头同条件引入 | 干净 checkout 目前 generate 失败；`import UnityFramework` 是编译期硬依赖 | 删掉 `EidolonIOS/UnityRuntime`、`EidolonIOS/Resources/Unity`、`build/Unity3DContent` 后 `xcodegen generate` 退出 0、`xcodebuild` 成功、`swift test` 全绿；有产物时 3D 变体也能构建 |
| P0-2 | **渲染器能力契约**：Core 加 `StandCapability`（表情集合/口型/点头/取景/动作集合 + `enabled(reason)`）；`StandPose.Report` 从「Spine 名→时长」改为「语义→可用性」；Spine 适配器把动画名映射成语义，3D 直接声明语义；`CallView` 按 capability 选布局，删 `standIs3D` | `StandRender.swift:208-216` + `StandAnimator.swift:8-45` 是这套 Spine 资产的字面量；3D 只能伪造 | Core 纯函数单测（emotion→可用性、缺能力退化、3D bounds→camera）；`grep -rn 'face_shy\|smile1' EidolonIOS` 归零；3D 不再有 `static let report` |
| P0-3 | **3D 内容包 kind/manifest**：按 ADR-0020 的 `StandManifest` 形状（`kind`/`mode`/`formatVersion`/`files[size,crc32]`，`StandManifest.swift:9-11,26-34`）新增 3D kind，或给 `kind: stand` 加 `renderer: unity`；内容 manifest 升级为逐文件校验；`UnityStandRuntime.contentRoot` 改为注入内容包目录；framework + `Data` 定义为引擎构建产物留 App 内，并记录配对哈希 | 227 MB 走 folder reference 进二进制，违反内容包边界与 ADR-0003/0020 的原子安装 | 安装包不再含 `models/`、`motions/`（-227 MB）；导入失败保留旧包；无内容包时 3D 入口 disabled；`emotion-map.json` 只从内容包读 |
| P0-4 | **角色↔模型映射**：内容包 `StandConfig` 增加 `model3d { renderer, idolID, outfits }`；删 `threeDTestCharacterID` 与默认 `001har`；`haruka3d` 要么转正（人设/音色/头像/语音索引），要么不进 main | 现在靠「占位角色 + 环境变量」串起来，2D 名册与 3D 模型没有数据关系 | 同一 character id 在 2D/3D 下分别解析 `stand` 与 `model3d`，缺任一则退化；`grep` 后只剩测试里允许的常量 |
| P0-5 | **仓库卫生 + 提交工程**：`xcodegen generate` 后提交 `EidolonIOS.xcodeproj`（或另开决策把生成工程移出仓库）；`git rm` 3.96 MB 派生动作数据，png 按 README 口径决定去留；处理 4 个未提交文件与未跟踪 `log.txt` | 分支不干净 + 工程与源码不同步，合并后「工程文件也入库」的承诺失效 | `git status --porcelain` 为空；`xcodegen generate && git diff --exit-code EidolonIOS.xcodeproj` 为空；仓库无 >1 MB 的游戏派生数据 |
| P0-6 | **ADR-0034 落地 + 取代 ADR-0022 + 文档口径**：写 `docs/adr/0034-3d-stand-unity-as-a-library.md`（UaaL 决策、+129 MB framework / +22 MB Data / 透明合成不可用 / Unity 版本锁 / 版权边界）；ADR-0022 顶部标「被 0034 取代」；README、`docs/building.md`、`docs/testing.md` 补 3D 前置与调试变量 | 0033:35 的链接是死链；ADR-0022 仍写「不选 Unity 运行时」 | 0034 文件存在且被 0033/README 链接；`grep '0034-3d-stand-unity-as-a-library' docs` 无死链；0022 有 supersede 头；文档能分别构建「3D 版/无 3D 版」 |

### 2.2 P1（合入后第一个迭代）

| # | 操作 | 验收 |
|---|---|---|
| P1-1 | 调试注入收进 `#if DEBUG`（`RootView.swift:15-16`、`CallView.swift:220,277`、`UnityStandRenderer.swift:50-59`、Playground） | Release 产物 `grep -a EIDOLON_3D_` 无命中 |
| P1-2 | 清理测试角色注入链：`tools/add_3d_test_character.py`、`tools/install_ipad.sh:9`、`SettingsView.swift:544` 文案 | 与 P0-4 一起删，或明确标注「仅本机开发」 |
| P1-3 | 测试补齐：Core 纯函数（emotion→表情、bounds→camera、report→pose）；UI 测试条件化（无内容构建时不失败）；回退测试（`EIDOLON_3D_FORCE_FAIL=1` 走 2D/头像） | `swift test` + 模拟器 UI 测试通过 |
| P1-4 | 引擎产物配对校验：`UnityFramework` 与 `Data` 必须同一次导出（`tools/build_sim_app.sh:9-17` 已证明 device/sim 混用会崩在 il2cpp 初始化） | 构建期哈希校验，文档写清 |
| P1-5 | spike 文档/死代码：`spikes/porting-3d/README.md` 仍写 `Eidolon3DSpike` target 与 Swift 单测，但 `project.yml` 没有该 target；`spikes/porting-3d/ios`（21 文件/5,456 行）不参与编译 | 改文档或删 |
| P1-6 | 偏差审计重跑：`deviation-audit-2026-11-08.md` 的 B-1/B-4 在当前 HEAD 已修，审计快照过期；C 类 27 项未知仍在 | 合入前给 HEAD 版结论，产品确认「雏形可接受」还是「B 类清零」 |

### 2.3 P2（可排期）

- P2-1：把 3 篇与 3D 无关的调研（`local-llm-5090`、`novelai-tags`、`online-uncensored-models`，+1,460 行）从 3D 分支拆出。
- P2-2：spike 是否出仓（入库 310 文件/6.2 MB，本地 12 GB）；RealityKit 遗留 `spikes/porting-3d/ios` 已不在 target。
- P2-3：私有基础设施痕迹改环境变量、无默认值。
- P2-4：文档漂移：`3d-stand-integration-plan.md` 写 `Resources/Unity3D/`（实际 `Resources/Unity/`）、体积过时；`3d-stand-prototype-status.md` 说设置里有「3D 立绘（实验）」开关，**代码里没有**（判定走角色 id + 环境变量）。

### 2.4 与组件化阶段的对应

| 3D 操作 | 组件化阶段 | 关系 |
|---|---|---|
| P0-1、P0-5 | Phase 1（shell/构建） | 不做，Phase 1 的「编译通过」验收不成立 |
| P0-2、P0-3、P0-4 | Phase 2（typed 契约/内容契约） | 正是「第二种资产格式」出现时该做的契约设计 |
| P0-6 | Phase 0（ADR/文档） | 推翻 ADR-0022 必须补决策 |
| 拆 `EidolonStand` 包 | Phase 3（可选） | 等第二种 3D 格式或第二企划出现再拆，不是合入前提 |

## 3 迁移目标事实卡

### 3.1 总览

| 目标 | 平台 / 状态 | 引擎（可信度） | 资产 / 剧情 / 语音 | 法律 | 对模板的结论 |
|---|---|---|---|---|---|
| **学マス** | iOS / Android / DMM PC；2024-05-16 上线，在营（App Store v3.5.3，2026-11-02，约 722 MB，仅 JA） | **官方**：CEDEC 2024，QualiArts，Unity 2022.3 + URP（Deferred + Forward+） | 3D Live + 2D 卡面 + ADV + 语音；容器社区事实：加密 protobuf 清单、Unity AssetBundle、AWB、USM | BNE 应用规约 9.1 禁逆向/解析/复制/改変，9.4 禁日本国外使用 | 2D 卡面/剧情/语音可进模板；3D Live 不进 |
| **CGSS** | iOS / Android；2015-09 上线，内容冻结、维护中（v11.7.0，2026-11-02，约 466 MB，仅 JA）；PC 版 2025-08-21 终了 | **一手报道**：CEDEC 2016，Cygames，立项时选 Unity | 3D Live（5/15 人）+ 2D 卡面 + コミュ + 语音；社区：`.unity3d` + ACB/HCA + bdb/mdb | 同一份 BNE 规约 | 同构于学マス；关服风险 → 档案类工作尽早 |
| **星耀季节** | PS4 / Steam（Windows only）；2021-10-14，ILCA/BNE | **官方**：Epic Games Japan 讲演资料，UE4.24，Deferred，ToonLit/ToonHybridLit，CRIWARE 旁证 | 3D cel-look + Live + 剧情；`.pak/.sig`（社区）；文本/音频 cue 未知 | Steam EULA 3(b) 禁逆向/修改/衍生/绕安全措施；实况政策不覆盖素材 | **负向测试用例**；3D→iOS 必须单独立项 |
| **galgame** | PC 为主，部分有主机/移动版 | **引擎族**：Ren'Py / KiriKiri / NScripter 有官方或开源资料；Siglus/AdvHD/Majiro/BGI 只有社区逆向 | 2D VN：脚本 + 立绘/CG + 语音 + 分支；格式逐引擎不同 | 引擎 license ≠ 内容 license；商业作品 EULA 因发行商而异 | 中性 VN IR + 每作品适配器；设备只跑 IR |

### 3.2 学マス（Gakuen iDOLM@STER）

- **官方平台与状态**：官方站自述类型「歌とダンスが上手くなるアイドル育成シミュレーション」，平台 App Store / Google Play / DMM GAMES，配信日 2024-05-16（<https://gakuen.idolmaster-official.jp/>）。App Store lookup：`jp.co.bandainamcoent.BNEI0421`、iOS 16.0+、722,100,224 B、语言仅 `JA`、v3.5.3（2026-11-02）（<https://itunes.apple.com/lookup?id=6446659989&country=jp>）。**无官方中文**。
- **引擎（官方）**：CEDEC 2024 讲演《学園アイドルマスターにおけるモバイルの性能を限界まで引き出すレンダリングパイプライン》，讲者 QualiArts，明确「Unity 2022.3 的 URP + Deferred + Forward+ 自建管线」（<https://cedil.cesa.or.jp/cedil_sessions/view/2936>）。这是四类目标里最硬的一手技术披露。
- **资产（社区事实）**：加密 protobuf master 清单、Unity AssetBundle、AWB（CRI ADX2 系）音频、USM 视频；卡面分 `img.cidol.*` / `img.csprt.*`；剧情为 ADV コミュ + 语音（<https://github.com/AllenHeartcore/GkmasObjectManager>）。
- **法律（官方）**：BNE 应用规约 <https://legal.bandainamcoent.co.jp/terms/nejp> 9.1 禁止「逆コンパイル、逆アセンブル、リバースエンジニアリングその他の解析」「複製（転載を含む）、編集、改変もしくは翻案」「ツール等を使用して情報を取得する行為」；9.4 禁止在日本国外使用。伴奏音源规约只「明文容忍」非营利粉丝视频，不覆盖游戏内立绘/模型/剧情/语音。
- **工具（社区）**：GkmasObjectManager（GPL-3.0）、HatsuboshiToolkit（无 license，需 root/模拟器）、Gakumas-PMX-Export（MIT）、gakumas-tools（BSD-3-Clause）等；均不构成素材授权。
- **对当前架构**：`card_art`、`adv_script`、`voice_set`、`cast_meta` 四种 kind 可覆盖；每作品必须单独做「清单/DB 解析 + 容器解码 + 字段映射 + 语音 id 对齐」；3D Live 不建议进模板。

### 3.3 CGSS（Starlight Stage / デレステ）

- **官方平台与状态**：官方站 <https://cinderella.idolmaster.jp/sl-stage/> 自述「アイドルリズムゲーム」，App Store / Google Play；App Store lookup：`jp.co.bandainamcoent.BNEI0242`、iOS 15.0+、465,800,192 B、语言仅 `JA`、v11.7.0（2026-11-02）。官方公告：2025-10-01 起变更开发/运营体制；2025-07 起陆续停止内容更新；PC 版与「スターライトスポット」2025-08-21 终了；**本体未关服**，但内容冻结。
- **引擎（一手报道）**：CEDEC 2016 Cygames 讲演，立项时在 Unity / Cocos2d-x 间评估后选 Unity；报道 <https://www.4gamer.net/games/307/G030796/20160829088/>。
- **资产（社区）**：`.unity3d`（Unity AssetBundle）+ ACB/HCA（CRI ADX2 系）+ 主数据库 `bdb`/`mdb`（<https://github.com/toyobayashi/mishiro>）；剧情在 master DB 还是 AssetBundle 内**未知**。
- **法律**：与学マス同一份 BNE 规约；App Store 说明直接链到该规约。视频政策只覆盖直播/实况。
- **工具（社区）**：DereTore（MIT，ACB/HCA）、libcgss（自定义 license）、mishiro（MIT）等。
- **对当前架构**：与学マス同构；卡面 schema 需要 `card_id / idol_id / rarity / before_after`；**内容冻结是机会也是紧迫性**——趁商店页/元数据还在，档案类工作尽早做。

### 3.4 星耀季节（STARLIT SEASON）

- **官方平台**：PS4 / Steam，2021-10-14，开发者 ILCA，发行 BNE；Steam 仅 Windows，日语全音频 + 简中/繁中/韩，15 GB，137 个 DLC（<https://store.steampowered.com/app/1046480/>，<https://store.steampowered.com/api/appdetails?appids=1046480>）。
- **引擎（官方）**：Epic Games Japan 公开的 UNREAL FEST EXTREME '22 讲演资料明确 **UE4.24**、Deferred、自定义 Shading Model **ToonLit/ToonHybridLit**、legacy tonemapper、法线外扩描边、约 5 万观众 Foliage+VAT；音频出现「プロジェクト設定（CRIWARE）」旁证（<https://docswell.com/s/EpicGamesJapan/5G68XZ-UE_UFE22S_BNE_ILCA>）。
- **包体（社区）**：`.pak`/`.sig`（<https://github.com/MakotoIchinose/StarlitSeasonMO2>）；UE4.24 与 4.25+ pak 格式不同（UE Viewer 变更日志）；文本/本地化落点、pak 加密、音频 cue 结构**未知**，本文不追。
- **法律**：Steam EULA 3(b) 明确禁止 reverse engineer / modify / derivative / circumvent（<https://store.steampowered.com/eula/1046480_eula_0>）；官方实况政策只许可实况/配信（<https://starlit-season.idolmaster.jp/game_commentary_policy/>）；日本著作权法第 30 条第 1 项第 2 号把「回避技术性保护手段后的私用复制」排除在例外外，第 120 条之 2 对回避工具入刑（<https://elaws.e-gov.go.jp/document?lawid=345AC0000000048>）。
- **对当前架构**：模型→glTF/USDZ 工程上可做，但 ToonLit 材质、G-Buffer 改造、描边、AnimBP/Sequencer/面部系统都要重写；**结论是负向测试用例**：模板应明确说「不支持」，3D 管线单独立项。

### 3.5 galgame（按引擎族）

| 引擎族 | 官方/公开资料 | 归档/脚本/图像/音频 | license 边界 |
|---|---|---|---|
| Ren'Py | 官方文档完整（含 iOS 构建）<https://www.renpy.org/doc/html/> | `.rpa` / `.rpy`、`.rpyc`；png/jpg/ogg/opus | 引擎 MIT + 部分 LGPL，发行需 LGPL 声明；内容另计 |
| KiriKiri / KAG3 | 吉里吉里Z 官方站/FAQ <https://krkrz.github.io/> | `.xp3`（含 `.tlg`）/ `.ks`、`.scn` | 吉里吉里2 GPL + 独自双许可；krkrz BSD-3 类；内容另计 |
| NScripter / NScripter2 | 官方站 <https://nscripter.com/>、GitHub 镜像 | `.nsa`/`.sar` / `.nscript` | 未见 OSS license 声明，不能默认可再分发源码 |
| Siglus / AdvHD / Majiro / BGI | 只有社区逆向笔记（MIT 工具） | `Scene.pck`、`.arc`、`.mjo`、`BURIKO ARC20` 等；逐族不同 | 引擎专有；工具 license 不等于内容授权 |
| Unity / 其他 | 无统一 VN 格式 | AssetBundle + 自研脚本，逐作品逆向 | 商业引擎 + 内容另计 |

**模板结论**：不要在设备上解析 `.xp3/.rpa/.ws2/.mjo/Scene`；在 **Mac 侧**写每引擎适配器，把脚本编译成中性 **VN IR**（scene → `say/show/hide/bg/bgm/menu/jump/if/wait/...`），设备只跑 IR。现有 `EidolonCore` 的回合/判断/检索/记忆可作为 VN 之上的「AI 陪伴层」复用；缺的是 `vn` 内容包 kind、VN 运行时（立绘分层/打字机/语音 cue/backlog/存读档）与文本编码处理（Shift-JIS/UTF-8、ruby、禁则）。

### 3.6 可信度与未知

- 可信度：学マス引擎/CEDEC、CGSS 选型、星耀 UE4.24/Toon/CRIWARE 均有官方或一手报道；资产容器细节多为社区事实；galgame 引擎资料官方程度差异很大。
- 主要未知：学マス master DB 完整 schema/剧情落点/语音 id；CGSS 文本落点与当前 Unity 版本；星耀文本/音频 cue/pak 加密；各商业 galgame 的逐作品 EULA；iOS 侧在「不越狱」前提下基本拿不到手机游戏资源（社区工具依赖 root 安卓/模拟器或 PC/CDN）——本文不提供任何越权步骤。

## 4 迁移模板（Migration Kit）

### 4.1 设计原则

1. **只定义输出侧契约。** 模板 = 内容包 schema + 中性 IR + 运行时/展示逻辑 + 适配器接口；不携带任何游戏数据。
2. **输入侧适配器每作品一个。** 清单/容器/脚本/字段解码必须单独立项；模板只规定它要产出什么。
3. **素材本机生成、不上传、不分发。** 内容包是用户在自己机器上生成的产物；模板与仓库只分发代码/schema。
4. **法律元数据是必填字段。** 每个内容包 manifest 必须带目标 id、来源说明、EULA/规约链接、生成时间；无法律元数据的包拒收。
5. **能力声明 + 退化。** 每个包声明它能提供什么（卡面/剧情/语音/3D/立绘），运行时按 capability 显示/隐藏，而不是假定全都有。

### 4.2 内容包 kind（推断命名）

| kind | 内容 | 对应现有机制 | 状态 |
|---|---|---|---|
| `cast_meta` | 角色 id、姓名、CV、生日、组合/班级、官方档案 URL | 现有 `characters.json` 的扩展 | 新增 |
| `card_art` | 角色 id、卡 id、稀有度、前后版本、图路径、尺寸 | 无（现有立绘是 Spine 三件套） | 新增 |
| `adv_script` | 场景/说话人/文本/语音 id/分支/解锁条件 | 现有 `episodes` 线性表的扩展 | 新增 |
| `voice_set` | 语音 id → 音频文件、时长、文本对齐 | 现有 `SpeechSynthesis` 无 cue 表 | 新增 |
| `vn_scene` | 中性 VN IR（scene/op 序列） | 无 | 新增；设备只跑 IR |
| `model3d` | 静态模型/材质/动作清单（可选，默认不做） | 3D 支线现有内容 | 可选 |
| `content` / `stand` / `bar` | 现有剧情/立绘/酒吧包 | 已实现 | 保持 |

### 4.3 流水线（Mac 侧 → 设备）

| 阶段 | 在哪 | 做什么 | 失败处理 |
|---|---|---|---|
| 获取 | Mac | 用户自己拥有/导出的副本；版本锁定 + sha256 快照 | 无快照不进入下一步 |
| 解码 | Mac | 每作品适配器：清单/DB、容器、脚本、图像、音频 | 记录 unsupported 清单 |
| 归一 | Mac | PNG/WebP、Opus、JSON/IR、glTF（若做 3D）；文本编码统一 UTF-8 | 有损转换需记录 |
| 索引 | Mac | 剧情/资料切段 + embedding；卡面/语音 id 表 | 与现有检索管线对齐 |
| 打包 | Mac | `.eidolonpkg`（zip + manifest + 逐文件 CRC）+ 法律元数据 | 失败保留旧包 |
| 导入 | 设备 | 原子替换 + schema/版本校验 | 旧包回退 |
| 运行 | 设备 | 只读 IR/内容，不解析原始归档 | capability 退化 |

### 4.4 适配器契约（推断）

```
MigrationAdapter {
  target_id, franchise, engine_family,
  supported_containers, script_codec, image_codec, audio_codec,
  text_encoding, id_mapping,
  opcode_to_ir, unsupported_opcodes,
  fixture, license_note,
  output_kinds: [cast_meta, card_art, adv_script, voice_set, vn_scene, ...]
}
```

模板测试 = 每个 adapter 至少一个 fixture（自有/合成数据）+ IR golden 输出；设备侧只测 IR 与包格式，不测原始归档。

### 4.5 法律门（写进模板）

- 不提供、不设计、不测试任何绕过 DRM/完整性校验/解密的能力；遇到加密变体就登记为 unsupported。
- 用户必须拥有游戏副本；内容包只在本机生成与使用；不分发素材。
- 每作品 EULA/规约在 manifest 中留链接；日本法 TDR 条款作为风险提示（星耀/商业 galgame 尤其）。
- 仓库/Apache/AGPL 等代码 license 与游戏内容 license 分开写；Spine/VA-11 等第三方资产继续不进仓库。

### 4.6 覆盖度矩阵

| 目标 | cast_meta | card_art | adv_script | voice_set | vn_scene | model3d | 结论 |
|---|---|---|---|---|---|---|---|
| 学マス | ✅ | ✅ | ✅（需 DB 解析） | ✅（AWB） | ◻ | ⚠️（仅静态） | 前四类可进模板 |
| CGSS | ✅ | ✅ | ✅（落点未知） | ✅（ACB/HCA） | ◻ | ⚠️ | 前四类可进模板；尽早 |
| 星耀季节 | ✅ | ⚠️（游戏内是否有卡面未知） | ⚠️ | ⚠️ | ◻ | ❌（重写渲染） | **负向用例** |
| galgame | ✅ | ✅ | ✅（脚本→IR） | ✅ | ✅ | ❌ | VN IR 是主路径 |

图例：✅ 可模板化；⚠️ 需单独立项/证据不足；◻ 不适用；❌ 明确不做。

## 5 与组件化笔记的衔接

- **ADR 编号要改。** 上一份笔记建议「组件化边界暂定 ADR-0033」；现在 ADR-0033 已被 3D 原生迁移占用，3D 支线又引用缺失的 ADR-0034（UaaL）。顺序应为：0033 = 3D 原生迁移（已在分支）、0034 = UaaL（合入前补）、**0035 = 组件化边界**（下一步）。[组件化笔记](componentization-2026-11-09.md) 里的编号需同步修正。
- **3D 支线正是组件化里的「第二种资产格式」**：P0-2/P0-3/P0-4 就是组件化 §5.3 的「资产清单化 + 内容契约 + 能力声明」；P0-1/P0-5 属于 shell/构建层。这个顺序与组件化建议的 C → B → A 一致。
- **跨企划迁移模板是组件化的下游**：先有 `EidolonKit` 的回合/检索/记忆与内容包契约，才能把「学マス/ CGSS / galgame」当不同 kind 装进来；反过来，模板调研也验证了「内核不该认识具体企划」这条边界。
- **产品形态差异**：学マス/CGSS 是「偶像 Live + 卡面」、星耀是「3D 主机作品」、galgame 是「视觉小说」；三者对运行时的要求不同，模板要允许「同一 App 装不同 kind 的内容包」，而不是为每个作品改引擎。

## 6 风险、未知与下一步

### 风险

1. **合入即把 main 变成「必须有 Unity 产物才能构建」**——P0-1 不做，main 的干净 checkout 就坏了。
2. **3D 范围膨胀**：#9 只承诺 `014mir` 的 `pr001 + ss003`，支线已做到 57 角色×2 套；不要把回归语料当产品范围。
3. **偏差未清零**：`deviation-audit` 的 B 类偏差与 C 类 27 项未知仍在；B-1/B-4 已修但审计快照过期，需要 HEAD 版结论。
4. **Unity 版本锁死**：Unity 6000.3.27f2 + 自定义 C# 移植，升级 Unity 的回归成本很高；UaaL 的 `Data` 与 framework 必须同次导出。
5. **透明合成不可用**：3D 目前是深色不透明底；做成产品要改 Unity 渲染层（CAMetalLayer/framebuffer），不是 Swift 侧能解决的。
6. **法律**：3D 模型/动作/卡面/剧情/语音都受原作版权与 EULA 限制；模板只能服务「用户本机私有使用」，不能变成分发工具。
7. **文档/证据漂移**：分支里 integration-plan、prototype-status、README、审计四处口径不一致；AI 生成的文档很容易再漂。

### 未知（需要拿到本体/工具后验证）

- 学マス master DB 完整 schema、剧情文本落点、语音 id 规则；CGSS 文本落点与当前 Unity 版本；星耀文本/音频 cue/pak 加密；各商业 galgame 的逐作品 EULA；iOS 不越狱时的资源可获取性（社区工具依赖 root/模拟器/PC）。
- 3D：Unity 视图透明合成、真实帧率/内存、长时间通话稳定性、真机 5 分钟以上验收。

### 下一步（不实施）

1. **先做 P0-1（可选编译）+ P0-5（提交工程/清派生数据）**：这两条让 main 恢复「干净可构建」，风险最低。
2. **再做 P0-6（ADR-0034 + supersede 0022）和 P0-2/P0-3/P0-4**：这是一个完整 PR/迭代，验收用 Core 纯函数 + `swift test` + `xcodegen` 无产物构建。
3. **3D 以 experimental 合入**：保留 2D 默认，3D 入口由内容包能力控制；先不接舞台/Live。
4. **第二企划文本 fixture**：按组件化 Phase 4，做一个纯文本内容包（新角色/新世界/不同语言对）跑通回合/判断/检索/记忆；这是模板的第一个真实用例。
5. **写模板 spec**（下一步，不是本次）：`docs/design/migration-kit.md` + 一个 ADR，定义 kind、IR、adapter 契约、法律门；模板本身不携带任何作品数据。

## 附录 A 来源与证据索引

- 3D 分支：`git diff --stat 8c05c7de..feat/mltd-3d-stand`、`git log --oneline 8c05c7de..feat/mltd-3d-stand`；`project.yml:24-53`；`docs/3d-stand-integration-plan.md`、`docs/3d-stand-prototype-status.md`、`docs/3d-branch-handoff-2026-11-07.md`、`docs/adr/0033-native-faithful-3d-migration.md`；`spikes/porting-3d/{README,migration-progress,audit-migration-2026-11-07,deviation-audit-2026-11-08,verification-playbook}.md`。
- 代码：`EidolonIOS/Features/Stand/{StandRenderer,UnityStandRenderer,UnityStandCatalog,UnityStandPlaygroundView}.swift`、`EidolonIOS/Support/{UnityStandBridge.h,.mm,UnityStandRuntime.swift}`、`EidolonIOS/Features/Call/CallView.swift`、`EidolonIOS/App/{AppModel,RootView}.swift`、`EidolonCore/Sources/EidolonCore/{StandRender,StandAnimator,StandManifest}.swift`。
- 学マス：官方站 <https://gakuen.idolmaster-official.jp/>；商店 <https://apps.apple.com/jp/app/id6446659989>；Apple lookup <https://itunes.apple.com/lookup?id=6446659989&country=jp>；CEDiL <https://cedil.cesa.or.jp/cedil_sessions/view/2936>；规约 <https://legal.bandainamcoent.co.jp/terms/nejp>；伴奏音源规约 <https://gakuen-label.idolmaster-official.jp/download>；社区工具 <https://github.com/AllenHeartcore/GkmasObjectManager>。
- CGSS：官方站 <https://cinderella.idolmaster.jp/sl-stage/>；商店 <https://apps.apple.com/jp/app/id1016318735>；Apple lookup <https://itunes.apple.com/lookup?id=1016318735&country=jp>；4Gamer CEDEC 2016 <https://www.4gamer.net/games/307/G030796/20160829088/>；mishiro <https://github.com/toyobayashi/mishiro>；DereTore <https://github.com/OpenCGSS/DereTore>。
- 星耀季节：官方站 <https://starlit-season.idolmaster.jp/>；Steam <https://store.steampowered.com/app/1046480/>；appdetails <https://store.steampowered.com/api/appdetails?appids=1046480>；EULA <https://store.steampowered.com/eula/1046480_eula_0>；实况政策 <https://starlit-season.idolmaster.jp/game_commentary_policy/>；Epic 讲演资料 <https://docswell.com/s/EpicGamesJapan/5G68XZ-UE_UFE22S_BNE_ILCA>；e-Gov 著作权法 <https://elaws.e-gov.go.jp/document?lawid=345AC0000000048>；MO2 <https://github.com/MakotoIchinose/StarlitSeasonMO2>。
- galgame：Ren'Py <https://www.renpy.org/doc/html/> + license <https://www.renpy.org/doc/html/license.html>；吉里吉里Z <https://krkrz.github.io/>；NScripter <https://nscripter.com/>；GARbro <https://github.com/morkt/GARbro>；arc_unpacker <https://github.com/vn-tools/arc_unpacker>。
- 上一份调研：[componentization-2026-11-09.md](componentization-2026-11-09.md)、[idolmaster-porting-2026-10-28.md](idolmaster-porting-2026-10-28.md)、[mltd-3d-pipeline-2026-10-31.md](mltd-3d-pipeline-2026-10-31.md)。

> 注：本文是调研笔记，不是实现计划；没有改代码、没有提交 git、没有下载或解包游戏资源。3D 部分的构建前提复现是在 `/tmp` 复制 `project.yml` 做的，未动任何 checkout。
