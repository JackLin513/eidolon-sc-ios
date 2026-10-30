# 3D 预览用游戏原生资产，动作在端上算

3D 支线（#54）走过一条弯路：把 MLTD 的模型交给 MLTDTools 转成 PMX/VMD，再想办法把原生动画曲线套到 PMX 骨架上，导成 animated USDZ 给 RealityKit 播。结果是每一轮都“爆炸”——直接套 Euler 爆炸、拿 PMX rest 当代理爆炸、拿 188 个 Unity Transform 当骨架爆炸。根因不是一个参数调错了，而是**两套骨架本来就不是一个人**：MLTDTools 会把骨骼改名并把父子关系改掉（`KUBI` 被挂到 `MUNE2` 且 local 归零），原生曲线按路径寻址的是游戏自己的层级。

**决定**：模型、骨骼、绑定、蒙皮权重、贴图、表情形变全部从游戏自己的 UnityFS 内容包里读，导成**纯静态蒙皮 USDZ**；动画曲线（原生 `AnimationClip`）单独解出来打进 App，端上逐帧用 RealityKit 的 `SkeletalPosesComponent` / `SkeletonPose` 写关节、用 `BlendShapeWeightsComponent` 写表情。USDZ 里不烘任何动画。

**为什么这条能成立**：舞蹈数据是游戏自己的 `Imas.CharacterImasMotionAsset`（`dan_loveig_01.imo.unity3d` 里只有 MonoBehaviour、MonoScript、AssetBundle 三个对象），180 条曲线按 Transform 路径索引（`MODEL_00/BODY_SCALE/BASE/MUNE1/...`），逐轴 Euler，不需要重定向到任何别家的骨架。Unity 的 `Avatar` 带骨骼名与路径，`SkinnedMeshRenderer` 带骨骼数组与绑定矩阵，`m_Skin` 带每顶点权重——这些都在 bundle 里，不需要从运行中的游戏抓。RealityKit 自 iOS 18 起可以写入自定义关节姿态与 blend shape 权重，本仓库部署目标是 iOS 26。

**代价**：要自己写一个 UnityPy 导出器（读数、翻手性、写 glTF），不能靠现成 GUI 工具；曲线要随 App 分发并在端上解码，所以需要压缩和纯函数测试；toon 着色保不住，先用 `UsdPreviewSurface` 近似。另外，动画不在资产里意味着“换一支舞”是换一个数据文件，不是重新导出模型——这一点反而比预烘焙省事。

**Blender 只做格式转换**：这条路里它只把 GLB 转成 USDZ，不做绑定、不做重定向、不改骨架。旧路线里它是“拿来修骨架”的工具，那是两套骨架踩坑的来源，代码和 spec 里都不再给它这个角色。

**考虑过的选项**：继续修 PMX 重定向（每次爆炸都只能退回去调 Blender 参数，因为缺的东西根本不在那里；而且 MLTDTools 在 2020.3 上直接失败、无维护、无 CLI）；VMD + 真 MikuMikuDance 仲裁（VMD 在真 MMD 里能播，但 Blender/MMD Tools 导入爆炸，Windows ARM 上 MMD 的 mesh 又不可见，无法验收）；把曲线预烘焙成 USDZ `SkelAnimation`（端上代码几乎为零，但每换一次衣装、每加一支舞都要重新烘，且短动作和长舞蹈两种时间语义会打架）；在 iOS 上跑 Unity 运行时（等于把整个游戏引擎塞进 App，与手机独立运行的目标冲突）。
