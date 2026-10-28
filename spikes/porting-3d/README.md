# MLTD 3D 模型迁移技术验证

状态：spike，不进入产品；分支 `spike/mltd-3d`，基于 `main`。游戏素材不进仓库。

## 目标

用合法取得的 MLTD 资源，在一个独立环境里验证：

1. 一个角色的 head/body 模型能被 OpenMLTD 工具链读出；
2. 导出 PMX + VMD（或等价格式），贴图、骨架、一个动作能正常显示；
3. 记录实际版本兼容性、失败点和后续 iOS 3D 管线的可行性。

**不包含**：内容包/`.eidolonpkg` 改造、`EidolonCore`/`EidolonIOS` 接入、多作品域模型、语音、舞台、相机、完整 Live、素材分发。

## 决策（2026-10-28）

- 结论形态：先离线验证，Blender/查看器里看效果；不在这一轮改 iOS App。
- 范围：1 个角色 + 1 套默认衣装 + 1 个动作。
- 隔离：spike 目录独立；素材放 `build/mltd-spike/`（根 `.gitignore` 已忽略 `build/`）；不提交 `.unity3d`/PMX/VMD/PNG/截图。
- 成功标准：模型 + 贴图正确显示，能播放一个动作，留下截图/视频和 notes。
- 时间盒：1 个工作日。若当前 MLTD 资源不被旧工具支持，停在兼容性探测并记录，不硬撑。

## 已知风险

- `MLTDTools` 是 **Windows / .NET Framework 4.7.2 / WinForms**，最新 release v0.3.0（2020-08-15）。
- MLTD 社区 issue 报告其已到 **Unity 2020.3.32f1**；旧版 MillionDance 读不了当前资源（[#62](https://github.com/OpenMLTD/MLTDTools/issues/62)、[#54](https://github.com/OpenMLTD/MLTDTools/issues/54)、[#74](https://github.com/OpenMLTD/MLTDTools/issues/74)）。
- 本机没有 Blender/Unity/Wine；只有 Parallels Windows 11 VM（suspended），也未确认 .NET 4.7.2/MLTDTools 是否已装。
- 工具代码是 BSD-3-Clause-Clear / MIT，但 **不覆盖 MLTD 模型、动作、语音**；没有官方素材再分发许可。

## 输入与产物

- 输入：你自己合法取得的 MLTD `.unity3d`（head `ch_*`、body `cb_*`、dance `dan_*`）；放 `build/mltd-spike/assets/`。
- 工具：Windows VM 里的 MLTDTools v0.3.0；Mac 上的 Blender + MMD Tools。
- 产物：`build/mltd-spike/out/` 里的 PMX/VMD/PNG、截图/录屏；不提交。
- 记录：`notes.md` 记录游戏版本、工具版本、每一步成功/失败、issue 对照。

## 只读探测

```sh
python3 spikes/porting-3d/unityfs_probe.py   "$HOME/Library/Containers/jp.co.bandainamcoent.BNEI0310/Data/Documents" --json
python3 -m unittest discover -s spikes/porting-3d/tests
```

`unityfs_probe.py` 只读 UnityFS header 的 Unity revision，不解析/导出素材。

已用 UnityPy 从 iOS 缓存导出 2018.4 的 `014mir`（春日未来）OBJ + PNG，并用 Blender headless 渲染：

```sh
build/mltd-spike/Blender.app/Contents/MacOS/Blender --background   --python spikes/porting-3d/render_obj.py --   --obj-dir build/mltd-spike/out   --texture-dir build/mltd-spike/out/textures   --out build/mltd-spike/out/mirai.png
```

这一步只验证静态模型；动画/PMX/VMD 仍需 MLTDTools。

Headless MLTDTools 补丁在 `mltools-headless.patch`（给 MillionDance 加 `--config`）。PMX/VMD 已能在 Windows VM 上生成，PMX 在 Blender 正常；VMD 导入仍会爆炸，见 `notes.md`。

## 执行清单

1. 确认资源版本与来源；只在本机处理。
2. 启动 Windows 11 VM，确认 .NET Framework 4.7.2 与 MLTDTools v0.3.0 可运行。
3. 用 MillionDance 尝试导出一个角色 + 一个动作到 PMX/VMD。
4. 把产物拷到 Mac，Blender + MMD Tools 导入，检查贴图、骨架、动作。
5. 截图/录屏，写 `notes.md`；若失败，记录第一个失败点和对应 issue。
6. 只有成功后才讨论是否做 iOS SceneKit/RealityKit 最小查看器；本轮不写产品代码。

## 不做

- 不提供/执行绕过 DRM、解密 `.pak`、提取 ACB/HCA 的步骤。
- 不把游戏原始资源或转换产物提交、上传、分发。

## 3D 支线（spec #53）

独立 target：`Eidolon3DSpike`，不依赖 `EidolonCore`/`EidolonIOS`。

```sh
xcodegen generate
xcodebuild -project EidolonIOS.xcodeproj -scheme Eidolon3DSpike \
  -destination 'platform=iOS Simulator,id=<sim>' build
```

App 从 Documents 的 `mirai.usdz` 或 `EIDOLON_3D_MODEL` 读取 USDZ；也支持文件选择。没有把 USDZ 打进仓库。

转换：

```sh
build/mltd-spike/Blender42.app/Contents/MacOS/Blender --background \
  --python spikes/porting-3d/pmx_to_usdz.py -- \
  --pmx build/mltd-spike/out/mltd/mirai.pmx \
  --out build/mltd-spike/out/mltd/mirai.usdz
```

已验证（本机命令）：

```text
$ usdchecker build/mltd-spike/out/mltd/mirai.usdz
Validation Result with no explicit variants set
Success!
```

RealityKit 在 macOS 上加载同一 USDZ 得到 `extents ≈ 0.106 × 0.127 × 0.023`；App 会按 y 高度归一化到 1.6m。Air 重启并清理安装后验收通过：textured USDZ 的头发/眼睛/衣服/裙子/鞋子贴图正常，比例/朝向可用。截图：`build/mltd-spike/out/ios-3d-reboot.png`。orbit 相机走 `realityViewCameraControls(.orbit)`，未做手势自动化。
