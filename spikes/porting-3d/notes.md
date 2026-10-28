# MLTD 3D spike notes

## 资源

- 游戏/平台：
- 版本：
- 资源路径（仅本机）：`build/mltd-spike/assets/`
- 来源/所有权：

## 工具

- Windows VM：
- .NET Framework 4.7.2：
- MLTDTools：
- Blender / MMD Tools：

## 2026-10-28 iOS 容器只读探测

- 容器：`~/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents`（本机已有 iOS 版缓存）
- 扫描：4885 个文件，4422 个 UnityFS bundle，约 1.36GB；没有导出/复制素材。
- Unity revision 分布：
  - `2018.4.11f1` 1575
  - `2018.4.12f1` 882
  - `2020.3.28f1` 44
  - `2020.3.32f1` 270
  - `2021.3.21f1` 412
  - `2021.3.36f1` 896
  - `6000.2.6f2` 343
- 结论：缓存不是单一版本；2018.4 的 2457 个 bundle 与 MLTDTools v0.3.0 的年代接近，可能可读；2020.3/2021/6000 不应假设旧 AssetStudio 能读。下一步要在 2018.4 bundle 中定位目标角色的 `ch_*`/`cb_*`/`dan_*`，再决定是否启动 Windows VM。
- 探测工具：`unityfs_probe.py`；测试：`tests/test_unityfs_probe.py`（4 tests）。只读 header，不解析资源内容。

## 2026-10-28 模型/贴图实际读取

- 在 iOS 缓存中定位到 `014mir`（春日未来）的 2018.4 bundle：`ch_pr001_014mir` / `cb_pr001_014mir` / `ch_ss003_014mir` / `cb_ss003_014mir`。
- UnityPy 能读：head 有 3 个 Mesh、6 张 Texture、Avatar/SkinnedMeshRenderer；body 有 1 个 Mesh、2 张 Texture、Avatar/SkinnedMeshRenderer。
- 已用 UnityPy 导出 OBJ + PNG 到 `build/mltd-spike/out/`，再用 Blender 4.5 headless 渲染静态 T-pose 到 `build/mltd-spike/out/mirai.png`。
- 结果：身体/衣服/头发/鞋/裙纹理基本正确；脸与眼睛材质仍不完整（脸是闭眼贴图，眼睛层还没接对）。
- 这一步证明“iOS 缓存里的 2018.4 模型可读、可在 Mac 显示”，不证明 MLTDTools 的 PMX/VMD 转换可用。

## 2026-10-28 Headless MLTDTools

- 给 MLTDTools 加了 `--config` 控制台入口（`MainWorker` 改成 `IMainWorkerHost`，ConsoleHost 不依赖 WinForms），补丁见 `mltools-headless.patch`。
- 用 Mac Mono/xbuild + 预编译依赖构建出 `MillionDance.exe --config ...`，在 Windows VM 上运行成功（Windows 侧只需 .NET 4.8 + 预编译 DLL；不必装 Visual Studio）。
- 用 2018.4 的 `ch_pr001_014mir` + `cb_pr001_014mir` + `dan_loveig_01` + `scrobj_loveig` 生成：
  - `mirai.pmx`（约 694KB）
  - `mirai.vmd`（约 24MB，3900 帧）
  - `tex/` 贴图
- PMX 在 Blender + MMD Tools 里能正确导入并渲染 T-pose；VMD 导入后模型爆炸/拉伸，尚未解决。
- 失败点已定位到 VMD 的动画坐标/骨骼映射，不是 PMX/贴图；下一步比较 VMD 与 PMX 的骨骼名/缩放，或用 MillionDanceView 复核 VMD。
- 脸/皮肤偏白不是贴图丢失：PMX 的基础色贴图本身很浅，游戏里还叠了 toon/环境光；Blender 中性光下会显得平、白。眼睛是独立 mesh + 贴图，PMX-only 图里是正常的。
- Blender 4.2.23 LTS + 对应 MMD Tools 4.5.14（bl4.2）仍复现 VMD 爆炸；因此不是 Blender 4.5 单点兼容问题。
- `MillionDanceView` 不能用来复核 PMX/VMD：它加载的是 MLTD 原始 head/body Unity 资源并在 Unity/OpenGL 里播放，不读 PMX/VMD。B 方案不成立，需要 MMD 本体或其他 PMX/VMD 查看器。
- 输出只在 `build/mltd-spike/out/mltd/`，不提交。

## 结果

- [x] head/body 读取（UnityPy）
- [x] 静态模型 + 贴图渲染（Blender，T-pose）
- [x] Headless MLTDTools 生成 PMX/VMD
- [x] PMX 导入 Blender 显示正确
- [ ] VMD 动画导入显示正确
- [ ] PMX 导出
- [ ] 贴图
- [ ] 骨架
- [ ] VMD 动作
- [ ] Blender 导入

## 失败点 / issue 对照

## 截图/录屏（仅本机，不提交）

`build/mltd-spike/out/`


## 2026-10-28 3D 支线（spec #53）

- 新增独立 `Eidolon3DSpike` target：RealityKit + `Model3DPreview`，不碰 Spine/Core。
- PMX → USDZ：[pmx_to_usdz.py](pmx_to_usdz.py)；`usdchecker` 返回 Success。
- RealityKit macOS 能加载 `mirai.usdz`；原始 extents 约 0.106 × 0.127 × 0.023，App 按高度归一化到 1.6m。
- Simulator build 成功；模拟器 UI 测试环境当前 `simctl`/launchd_sim 卡住，未拿到截图。
- Air 安装失败：设备 free developer profile 已装 3 个 App（AltStore / Eidolon / Bangumi），spike 是第 4 个，需先删一个或换付费账号。
- `usdchecker` 输出 `Success!`；RealityKit macOS 加载 extents ≈ 0.106 × 0.127 × 0.023，App 归一化到 1.6m。
- Review 修正：文件选择的 security-scoped URL 先复制到 Documents；灯光只加一次；空 bounds 报错；empty/failure 共用 placeholder。
- Air 已安装并截到静态模型：几何、比例、orbit 相机正常；但当前截图仍是灰色材质，纹理 USDZ 已包含 PNG 且在 USD 里是 UsdPreviewSurface，RealityKit 在 Air 上没有显示贴图。Air 截图：`build/mltd-spike/out/ios-3d-air-2.png`。
- 纹理问题未解决；不要把它当作“完成”。下一步需要检查 USDZ 材质绑定/RealityKit 对 MMD 转换材质支持。
- 增加 `Model3DResourceLocator` 与 iOS XCTest：env → bundle（递归）→ Documents；`xcodebuild test` 因模拟器 boot timeout 未执行，但测试代码已编译。
- 多次 uninstall/reinstall 后 Air 仍显示旧空页面/旧二进制现象；可能是设备安装/SpringBoard 快照缓存，需重启 Air 或清理安装后复核。
