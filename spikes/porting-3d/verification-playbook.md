# 3D 迁移验证手册（经验沉淀，2026-11-08）

## 一、游戏实机 Hook：如何避免"拿错角色"

跨进程比对（游戏 vs 移植）**必须先证明比较的是同一个对象**，否则所有数字都是假的。本次踩过的坑：#130 里连续多轮得出"BASE 差 11.76°、骨架差 85–103mm"，实际是把**别的偶像的管理器**当成了春香。

### 失败的判据（不要再用）
| 判据 | 为什么失败 |
|---|---|
| `SwayManager.fileName@0xE0` | 运行时为空 |
| il2cpp `Object.get_name` | 返回空（字符串通道不可靠） |
| 祖先链指针分组 | 各管理器挂载点不同，链深度不同，分组碎裂 |
| `BaseTr` 世界坐标聚类 | 全部是角色本地坐标 (0, 0.85, 0)，无法区分 |

### 可靠的判据（按优先级）
1. **骨数签名**：每个角色的 4 个 SwayManager 骨数组长度组合唯一。春香 ss001 = `{2, 20, 8, 17}`（root / skirt_GP / shoulderRibbon_GP / HAIR）。
2. **BASE 旋转序列匹配**：同时录全部管理器的 `BaseTr` 旋转，与我们的序列比对，中位差最小的一组即目标角色（春香实测 **0.90–1.03°**，其它角色 ≥10°）。
3. **相对质心偏移**：`BaseTr` 相对裙骨基点质心的偏移，同一角色约 (-0.003, -0.10, -0.015)m，与其它角色不同。

### 标准流程
1. hook `SwayManager.LateUpdate 0x1C817F0`，收集全部管理器（指针 → 骨数 + `BaseTr` 指针）
2. hook `PlayerDance.UpdateTime 0x37EDF1C` 取 `current_time (+0x44)` 作为舞蹈时间戳
3. 每 400ms 采样：各管理器 `BaseTr` 世界旋转（`Transform.get_rotation`）+ `swayBones[i].trs (+0xF8)` 的世界位置与 `get_localRotation`
4. 离线用**骨数签名**锁定角色，再用 **BASE 序列**复核
5. 通过后才做位置/旋转/pitch 对比

### 已确认的关键地址（9.0.350 构建）
| 名称 | RVA |
|---|---|
| `SwayManager.LateUpdate` | 0x1C817F0 |
| `SwayManager.PrepareUpdate` | 0x1C81A08 |
| `SwayCtrlAllMT.ExecuteParallelSwayIdols`（**游戏实际走的 MT 路径**） | 0x1C6CBD4 |
| `SwayCtrlMT.ResetParallelState`（取控制器实例，每帧调用） | 0x1C6CFD0 |
| `PlayerDance.UpdateTime` | 0x37EDF1C |
| `Transform.set_localRotation_Injected` | 0x70BF458 |
| 管理器字段：swayBones | +0x50 |
| 管理器字段：BaseTr | +0x70 |
| 管理器字段：BodyScale | +0x68 |
| WorkingParams：tip / prevTip / minZ / maxZ | +0x34 / +0x40 / +0x2C / +0x30 |
| ColliderParams：center / dir / radius / distance / barrier | +0x04 / +0x3C / +0x14 / +0x18 / +0x64 |

### 实测基线（正确角色下，可用于回归）
- 骨架基点位置差：中位 **6.3mm**、p90 28.4mm
- 骨架局部旋转差：中位 **1.77°**、p90 5.89°
- 裙骨 pitch 差：中位 **1.56°**、p90 7.29°
- 23 秒处 F0 pitch：我们 -47.5° vs 游戏 -44.4°

---

## 二、IDA 数据库：不要再浪费半小时重建

### 事故记录
- 旧库 2.0GB，`idapro.open_database` 返回 `rc=4`；IDA CLI 日志：`Database is empty -> OK` / `Database initialization failed with error 4`
- 根因：**对仍持有数据库的 IDA 进程用了 `kill -9`**，保存不完整 → 文件损坏

### 铁律
1. **绝不 `kill -9` 持有 IDA 库的进程**。要停就用 `idapro.close_database()` 或等它自然退出。
2. 一次只允许一个进程打开同一个库；跑批前先 `ps aux | grep idapro` 确认。
3. 建库完成后**立即验证**：`open_database(path, False)` 必须返回 0；再 `close_database()`。
4. 库固定放 `~/mltd-work/ida/UnityFramework.i64`，只保留一份；损坏的先 `mv` 改名再重建，不覆盖。
5. python 用 `env -u IDAPYTHON_VENV_EXECUTABLE ~/mltd-ida/venv/bin/python`（该环境变量会强制错误解释器）。

### 替代方案（不必等 IDA）
- **ARM64 BL 扫描**：直接读 Mach-O，解码 `BL` 指令得到调用图（本仓库多次用来验证调用者/被调用者）
- **Frida 运行时 hook**：能拿到真实调用者（`Thread.backtrace`）
- **objdump**：`inspect_with_objdump` 可做符号级反汇编

---

## 三、当前资产规模（决定验证策略）

来自 CDN 清单（版本 1078590）：
| 类别 | 数量 |
|---|---|
| 总条目 | 171,033 |
| 头部模型 `ch_*` | 7,692 |
| 身体模型 `cb_*` | 2,311 |
| 舞蹈动作 `dan_*.imo` | 955 |
| 摄像机 `cam_*.imo` | 474 |
| 表情/节拍 `scrobj_*` | 496 |
| 服装编号（`ss001` 等） | 398 |
| `rei`（玲音系）相关条目 | 1,887 |

→ 全量逐个"人眼验证"不可行，必须设计**分层自动化验证**。

---

## 四、NAS 资产库与按需下载（2026-11-08 实测）

### 环境事实
- NAS 主机：`JackLin@192.168.0.6`（`ds220plus` 被代理解析成假 IP `198.18.3.213`，**必须用 LAN IP**）
- 部署目录（沿用主线 `tools/deploy.env` 约定）：`/volume1/docker/eidolon/`
- 磁盘：23T 总 / **8.2T 可用**；NAS 有 python3(3.8)/wget/curl/rsync，**无 aria2c**
- 游戏 CDN：`https://td-assets.bn765.com/<version>/production/2018/iOS/<hashed>.unity3d`，需要 `User-Agent: UnityPlayer/2020.3.32f1` + `X-Unity-Version: 2020.3.32f1`，**文件名必须用 manifest 里的 hashed 名**（直接用 asset 名会 403/429）

### 全量快照规模（版本 1078590）
- **总计 46.89 GB / 171,033 个文件**（此前误以为要几百 GB）
- 模型相关：`cb_` 身体 1.95GB / `ch_` 头 2.62GB / `dan_` 动作 3.46GB / `cam_` 0.01GB
- 剩下 38.8GB 是音频、UI、背景等

### 验证过的按需下载链路（`tools/mltd_asset_server.py`，NAS 上 2872 端口）
| 情况 | 结果 |
|---|---|
| NAS 已缓存 | **HTTP 200**，附带 `X-Asset-Sha256`、`X-Storage: nas`；LAN 实测 **5.3 MB/s** |
| NAS 未缓存 | **HTTP 404** → 客户端回退官方 CDN |
| CDN 回退 | HTTP 200，**0.9 MB/s**（约 NAS 的 1/6） |

→ 单套模型 15–30MB，手机端按需取：LAN ≈ 3–6 秒，外网 CDN ≈ 15–30 秒。

### 重要坑：manifest 的 hash 不是文件内容哈希
manifest 每项是 `[hash, cdn_name, size]`，但该 hash 与下载文件的 SHA-1/SHA-256 **都对不上**（已验证：NAS 文件与 CDN 直下文件 sha1 完全一致，都是 `UnityFS` 头）。
**校验方式**：比 `size` + 检查 `UnityFS` 魔数 + 后续解析/导入成功，不要用 manifest hash。

### 动作资产的真实分类（供 LLM 对话选动作）
| 类别 | 数量 | 命名 | 用途 |
|---|---|---|---|
| Live 舞蹈 | 955 | `dan_<曲>_01.imo.unity3d`（`_ap` = solo 段） | MV 演出 |
| **日常/剧情动作** | **1,125** | `adv_imo_com_<idol>_<age>_<action>`，action ∈ yes/noo/lop/str/end/intro/greeting/convo/rank0-3/base/extra/suggest | **对话、日常** |
| 摄影姿势 | 189 | `chr_anim_pho_*` | 拍照 |
| 剧场/其他 | 1,167 | `chr_anim_com_*` / `chr_anim_the_*` | 其他场景 |
| 相机 | 474 | `cam_*.imo.unity3d` | 运镜 |

---

## 五、全量资产验证流水线（#131 后续，2026-11-08）

### 工具
- `spikes/porting-3d/tools/verify_pairs.py` —— 按配对清单从 NAS 资产接口取 bundle →
  `export_character.py` 导出 → 记录材质/贴图数与缺陷类型，可断点续跑
- `spikes/porting-3d/tools/preview_gltf.py` —— 不依赖 Blender 的轻量预览（点云泼溅）
- `spikes/porting-3d/render_gltf.py` —— Blender 正式渲染（已适配 Blender 5.x：`BLENDER_EEVEE_NEXT` → `BLENDER_EEVEE`）

### 已发现的缺陷类型（校验必须覆盖）
| 类型 | 例子 | 判定 |
|---|---|---|
| **texture-only bundle** | `cb_ex023_001har.unity3d` 只有 1 张 Texture2D、无 Mesh | 按名字配对会误当身体，导出只剩头 |
| 贴图少于材质 | — | `textures < materials` |
| 导出失败 | — | returncode ≠ 0 |

**教训**：素材类型必须**看 bundle 内容**（Mesh / SkinnedMeshRenderer 计数），不能看文件名。

### Blender 5.x 适配记录
- 渲染引擎枚举：`BLENDER_EEVEE_NEXT` 在 5.x 又改回 `BLENDER_EEVEE`
- `bpy.ops.wm.usd_export` 删掉了 `export_textures` 等参数 → 用
  `bpy.ops.wm.usd_export.get_rna_type().properties.keys()` 过滤后再传
