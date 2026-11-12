# 调研笔记索引

调研笔记记录的是**调查结论，不是 spec、ADR 或已实现设计**。任何一条要落地，都要再走 grill → spec → implement。阶段与验收见 [`docs/roadmap.md`](../roadmap.md)。

## 当前方向（2026-11-09）

| 笔记 | 回答什么 |
|---|---|
| [组件化调研](componentization-2026-11-09.md) | 本仓库的边界、耦合、候选组件与迁移阶段 |
| [迁移模板调研](migration-template-2026-11-09.md) | 3D 支线合入准备；学マス/CGSS/星耀/galgame 的迁移事实与模板 |
| [扩展点与平台适配](extension-points-and-platforms-2026-11-09.md) | 运行时/内容扩展点；Unity/UE/2D 运行时边界；iPad/macOS 路径 |
| [多企划与跨企划场景](cross-franchise-model-2026-11-09.md) | 多内容包、复合身份、会话参与者、Scene/Universe/P0-P2 |
| [两个外部企划的内容包可行性（2026-11-11）](content-packs-galgame-gakumas-2026-11-11.md) | galgame（T-Script 引擎）与 Gakumas-Player 各能提供什么内容、格式清单、提取管线、#135 映射与风险 |
| [Galgame 全量迁移（2026-11-12）](galgame-full-migration-2026-11-12.md) | 全量文本/语音/立绘/世界观、PGD 解码、Sv20、Fish Audio、分阶段迁移与 CHS v1.1 汉化补丁分析 |
| [Fish Audio 训练与成本（2026-11-12）](fish-audio-cost-2026-11-12.md) | Sakura/VO01 数据集能否训练、PVC/API/套餐各怎么收费、$0 与 $15 两条路的确切花钱步骤 |

## 历史参考

这些笔记的事实仍可引用，但结论已被上表或代码超越；读的时候先看日期与前提。

| 笔记 | 内容 |
|---|---|
| [上游对齐调查（2026-10-25）](upstream-parity-2026-10-25.md) | 早期提示词/好感/通话与上游的逐字差异 |
| [MLTD 3D 管线（2026-10-31）](mltd-3d-pipeline-2026-10-31.md) | 静态蒙皮 USDZ、材质、取景、遗留账 |
| [偶像大师移植调查（2026-10-28）](idolmaster-porting-2026-10-28.md) | MLTD / 星耀季节素材迁移的早期可行性 |
| [整屏画布（无日期）](full-bleed-canvas.md) | iPhone 全幅布局的 API 调查 |

## 不在 main 的文档

3D 支线自己的文档只在本地分支 `feat/mltd-3d-stand`（如 `docs/3d-stand-integration-plan.md`、`docs/research/unity-uaal-ios-2026-11-09.md`）；main 上不复制，等 M1 按路线图迁入时再整理。
