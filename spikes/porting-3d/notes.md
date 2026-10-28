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

## 结果

- [x] head/body 读取（UnityPy）
- [x] 静态模型 + 贴图渲染（Blender，T-pose）
- [ ] MLTDTools PMX/VMD
- [ ] PMX 导出
- [ ] 贴图
- [ ] 骨架
- [ ] VMD 动作
- [ ] Blender 导入

## 失败点 / issue 对照

## 截图/录屏（仅本机，不提交）

`build/mltd-spike/out/`
