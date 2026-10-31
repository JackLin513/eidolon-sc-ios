# MLTD 3D 预览：原生资产管线处理总结

- 日期：2026-10-31
- 代码：worktree `~/Developer/IdeaProjects/eidolon-sc-ios-3dspike`，分支 `spike/mltd-3d-static`
- 总 spec：[#9](https://github.com/JackLin513/eidolon-sc-ios/issues/9)；路线决策：[ADR-0022](../adr/0022-3d-native-assets-runtime-skinning.md)
- 过程流水账：`spikes/porting-3d/notes.md`（在本机 worktree 内，含逐次实验与踩坑）

本文只记录**结论与遗留**，不重复 notes 里的实验过程。游戏素材、USDZ、贴图、截图、dump 一律不进仓库。

## 结论

静态蒙皮这条线成立：游戏自己的 UnityFS bundle 可以直接导出为 RealityKit 能渲染的 USDZ，58 组（001–052 角色、101kot/102mis、4 个通用 `xxx`）共 109 个模型、49 套演出服已全部导出，自动截图扫描无取景异常。

动画链（#27 曲线解码 → #28 端上骨骼驱动 → #29 表情）尚未开始；3D 仍只在独立 target `Eidolon3DSpike` 里，不接入 `EidolonIOS` / `EidolonCore` / `StandRenderer`。

全语料是**回归语料**，不是产品范围承诺——#9 仍只承诺 `014mir` 的 `pr001` + `ss003` 两套。

## 管线

### 1. 取包与读取

- `mltd_assets.py` 从 MLTD CDN 拉当前版本的 bundle（`ch_*` / `cb_*` / `ca_*` / `cas_*` / `dan_*.imo`）。
- `unity_mesh.py` 用 UnityPy 解 `Mesh`、`SkinnedMeshRenderer.m_Bones`、`Avatar.m_TOS`、`m_BindPose`、`m_Skin`、贴图与材质。
- 顶点通道按网格实际给的槽位补齐到 4：常规角色 4 个影响骨，双骨骼道具 2 个，刚性配件 0 权重 + 1 个 32 位索引。此前记录的「18 个角色导不出」就属于最后一类，已由 `5a8eea59` 解决，notes 里那段「下一步要解打包布局」已过期。

### 2. 导出

`export_character.py` 输出 glTF 2.0，`export_corpus.py` 串起三个阶段：

```text
glTF（UnityPy，本进程）
  → .usdc（Blender，仅格式转换）
  → .usdz（pack_usd.py：面法线平均回顶点 + 打包）
```

- 手性在导出器里做：`(x, y, z) → (x, y, −z)`，同时反法线 Z 与三角形绕序；不用根节点负缩放。
- Blender 无条件写 face-varying 法线，RealityKit 不做面法线插值，所以 `pack_usd.py` 把面法线平均回顶点、改 `interpolation=vertex` 后再打 USDZ。
- 产物过 `usdchecker`。USDZ 只承载静态蒙皮，不烘动画。
- 已知坑：四元数手性共轭是 `(-x,-y,z,w)`；`scenes[0].nodes` 必须是真根索引；Blender 的骨骼冰球（42 顶点 Icosphere）要按 Armature 修改器过滤；`m_BindPose` 等于 rest 世界矩阵的逆；顶点色全零。

### 3. 材质与着色

- 按游戏 `m_ParsedForm` 重建材质表，导出 `<stem>-materials.json` 与 `<stem>-params.png` 参数图集；端上用 `CustomMaterial` 移植 toon。
- alpha 三条线：`Chr_Alpha` 真混合；`MASK` 真裁切（保留 alpha，不用「近黑即丢弃」）；透明像素里的 RGB 必须保留——金边就是画在 alpha≈13 的像素里的，洗黑会整条消失。
- 采样：464 个 primitive 里 241 个材质的 UV 越出 `[0,1]`，用 `address::repeat`，不能 `clamp_to_edge`；mipmap 渗色单独处理。
- 描边：只给真有两 pass 的 6 个 shader（`Chr_Basic` / `Chr_Color` / `Chr_Face` / `Chr_Glow` / `Chr_Hair` / `Chr_Span`）套壳，其余单 pass。
- `Chr_Span` 亮片：alpha 必须真的进 GPU（否则 `_MainTex.a` 恒为 1）；采样空间用纯法线 matcap，不是布料 UV；`_USEREFLECT_ON` 反射走 base_color 效果槽。

### 4. 取景

RealityKit 对蒙皮网格报的 `visualBounds` 是**绑定姿势**的框；根关节带位移时，框和画出来的人能差一个身子（003mik 实测 0.873）。

- `skinned_bounds.py` 按 `global(joint) · inverseBind · p` 逐顶点复算实际盒。
- `export_character.py` 每次导出同时写 `<stem>-bounds.json`；预览按其中的 Y 中心取景，无 sidecar 时退回原路径。
- 全语料回归：49 套演出服批量截图，按逐像素中位数基线分割轮廓，**0 异常**（头顶 327–602px，脚底 2199–2239px，中位身高 1641px）。

### 5. 语料与预览

- `export_corpus.py` 按内容配对，不靠文件名：带 `cb_pr001_<idol>_01_m` 的是身体，带 `ch_pr001_<idol>_face_m` 且无身体材质的是头；材质最少的头胜出（大的是别的服装的配件）。
- 支持断点续跑；已导出的 USDZ 可跳过。
- 预览 App `Eidolon3DSpike` 从 Documents 递归发现模型，底部按钮换角色/衣装；调试开关：`EIDOLON_3D_START`、`EIDOLON_3D_OUTFIT`、`EIDOLON_3D_YAW`、`EIDOLON_3D_NO_OUTLINE`、`EIDOLON_3D_LOG_MATERIALS`、`EIDOLON_3D_DEBUG_ALPHA`、`EIDOLON_3D_DEBUG_ALBEDO`、`EIDOLON_3D_ISOLATE_ROW`、`EIDOLON_3D_DEBUG_MASTER`。

## 验证工具

- `python -m unittest discover -s spikes/porting-3d/tests`：38 个纯函数单测（解码、手性、材质参数、曲线、资源定位），不联网。
- `audit_materials.py`：静态检查 shader / 图集 / 贴图 / UV，包括「有多少颜色藏在透明像素里」。
- `audit_outline.py`：开/关描边两张截图的形态学差分，找「消失一块」而不是「细一圈」。
- 批量截图扫描：`/tmp` 本地脚本，逐模型启动 + 截图 + 中位数基线分割；不进仓库。

## 遗留账

| 条目 | 类别 | 状态 |
|---|---|---|
| 006mak-ss003 黑色肩带悬空、039kon-ss005 白蝴蝶结落在靴下 | 正确性 | [#33](https://github.com/JackLin513/eidolon-sc-ios/issues/33)。已排除描边壳与取景；假设是配件附着变换没导出 |
| 009rit-ss010、050jul-ss008 配件错挂（`ch_pr001_009rit_acc01_m`、`ch_pr001_050jul_acc01_m`） | 正确性 | 并入 #33 |
| 019min / 031tom / 052kao 没有 ss0 演出服导出 | 数据 | [#34](https://github.com/JackLin513/eidolon-sc-ios/issues/34) |
| `Texture count [34] exceeds limit [31]` 告警 | 噪声 | #34；目前仍正常渲染 |
| 描边外扩用 NORMAL 而非 TANGENT 硬法线；缺深度偏移；宽度系数 0.0014 是量出来的；`normal()` 空间未测 | 外观 | 记录在 #26 评论 |
| 几何变体 `_USEREFLECT_ON` / `MOSAIC_ON` / `_ISREDDISH_ON` 未覆盖；`_BumpMap_ST` 硬编码 30；加法层只在默认值验证 | 外观 | #26 评论 |
| 全部像素实验在 iOS 27 模拟器；`ToneMappingComponent` 未文档化 | 运行时 | 真机复验并入 [#13](https://github.com/JackLin513/eidolon-sc-ios/issues/13) |
| T2 按钮/动作状态机未接 | 交互 | [#10](https://github.com/JackLin513/eidolon-sc-ios/issues/10) |
| notes 里「18 个角色导不出」段落已过期 | 文档 | 已在 notes 中加结账说明 |
| spike README 仍写 PMX 路线与旧分支名 | 文档 | 已改写 |
| 旧 PMX 路线遗留文件（`mltools-headless.patch`、`pmx_to_usdz.py`、`render_vmd.py`） | 仓库卫生 | 已删除，git 历史可查 |

## 下一步

按 #9 的 Phase 推进：

1. **#27 曲线解码**：用 rea 反编译确认 Euler 顺序与符号、`FullFrame` / `Discreate` 的采样与插值、`MODEL_00/BODY_SCALE` 是否存在；产出压缩曲线（折叠 Const、30 fps、int16 量化，单支舞 < 2 MB）。
2. **#28 端上骨骼驱动**：`SkeletalPosesComponent` 逐帧写关节，锁根调试开关，与游戏运行时数值对照。
3. **#29 表情**：32 个 blend shape → `BlendShapeWeightsComponent`，7 情绪权重表。
4. 之后 #10 → #11 → #12 → #13 补齐预览状态、按钮矩阵、原版舞蹈和 Air 验收。
5. #33 / #34 是并行的小账，不阻塞曲线链。

## 待决的产品问题

- **全语料与 spec 范围**：58 组已导出，但 #9 明确把「全部 52/55 个角色」列为不在范围内。目前把全语料当回归语料用；是否扩大产品范围要另开 spec。
- **合并进聊天软件**：`GLOSSARY.md` 的「3D 预览」是固定机位的立绘替代呈现，还没有「聊天页里的 3D 角色」这个产品词条。锚点、构图、换角色/换衣装的切换规则需要在合并 spec + ADR 里定义；#9 只加了「切换时锚点不跳变」这条验收。
- **3D 与 Spine 的取舍**：两者是替代关系还是并存，未定。
