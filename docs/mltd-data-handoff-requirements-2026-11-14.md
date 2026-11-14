# MLTD 剧情 / 语音 / 日常动作数据交接需求

日期：2026-11-14（P0 于 2026-11-15 由接收方侧补齐，见 §3.3）
交接对象：上一个负责 MLTD 拆包 / 3D 资产管线的 agent
接收方：当前 iOS 客户端 `feat/mltd-3d-stand` 线
目标：让 MLTD 线具备「按原作剧情说话、带语音、3D 角色做日常动作」的数据基础

## 0. 一句话（2026-11-15 更新）

P0 已经不再是「等交接」的状态：接收方用 `~/mltd-work` 里已有的解码产物 + `tools/fetch_unity3d_content.py`
本地重跑，把 **56 个角色的 7 个 stand 状态动作** 和 `motions/catalog.json` 合进了
`build/eidolon-model3d-mltd.eidolonpkg`（§3.3）。现在真正缺的是：

1. **P1 剧情文本** — 现有内容包里只有 1 条合成 episode，没有一个真实的 MLTD 剧情行。
2. **P2 语音** — 现有 schema 没有语音表，也没有任何可播放的剧情语音映射。
3. **P0 剩余** — 游戏只发 7 个「待机/反应」状态剪辑，没有 `greet/bow/wave/think/laugh/drink/phone/stretch/sit`
   这类语义动作；要补需要从剧情 scene 动画 / Live 演出里另挖（§3.2），以及客户端侧还没实现 `PlayAction`
   播放协议（§3.4）。

## 1. 当前客户端状态（2026-11-15 实测）

- 3D 模型包：`build/eidolon-model3d-mltd.eidolonpkg`（约 119 MB，615 个 zip 条目）。
  - 57 个角色，每个角色有 `pr001`（常服）/ `ss003`（演出服）两套 outfit（`cb_*` 身体 + `ch_*` 头）。
  - manifest `files` 共 614 条，全部 `size` + `crc32` 与包内字节一致（重建后逐个复算校验通过）。
- 动作文件（本次已更新）：
  - 392 个 `motions/<localID>/<action>.tsv`：56 个角色 × 7 个动作
    （`act/swt/yes/noo/str/lop/end`），60 fps flat TSV。
  - `motions/catalog.json`：每个角色的动作清单（`file/loop/duration/frames/tags/source`）。
  - 缺动作的角色：`052tmg`（`~/mltd-work/motion-daily-merged/index.json` 里没有它的动作条目，本地也没有
    可解的动作包）。客户端必须把「无 motions」当作合法状态处理（§3.3 fallback）。
- 内容包：`build/eidolon-content-mltd.eidolonpkg` 仍是 57 角色测试壳，角色 sheet 为占位，只有 1 个合成
  episode；没有 MLTD 剧情和语音。
- 现有内容库 schema（剧情文本）：
  - `episodes(id, category, source, title, imported_from, imported_at)`
  - `episode_cast(episode_id, character_id)`
  - `episode_lines(episode_id, seq, speaker, ja, zh)`
  - `episode_passages(episode_id, seq, text, model, embedding)`
- 现有内容库没有语音表；语音播放/映射需要新增数据契约（见 §4）。
- 相关代码 / 文档：
  - `EidolonIOS/Runtime/Unity/UnityCharacterRenderer.swift`
  - `spikes/porting-3d/unity-spike/Assets/Scripts/EidolonStandHost.cs`
  - `spikes/porting-3d/unity-spike/Assets/Scripts/EidolonStandMotion.cs`
  - `docs/research/mltd-3d-pipeline-2026-10-31.md`
  - `spikes/porting-3d/export_daily_motions.py`（两层动作合并成 7 动作的原始脚本）

## 2. 交付优先级

- **P0：日常动作** —— 数据侧已完成（§3.3），剩客户端播放协议与「7 个状态动作之外」的语义动作扩充。
- **P1：剧情文本** —— 未交付。让 MLTD 角色能检索/引用原作剧情，而不是只靠人设说话。
- **P2：语音** —— 未交付。给剧情行/日常台词匹配语音，先做可播放和映射正确，不要求端上实时合成。

如果时间有限，先交 P1 的一个 episode 样例（30 行以上日文原文）和 P2 的 10 条带音频样例。

## 3. P0：3D 日常动作

### 3.1 游戏实际提供的动作集合（已核实）

MLTD 的 stand 日常动作只有这 7 个状态剪辑，没有更细的语义动作。证据：
`spikes/porting-3d/README.md:81-95` + `spikes/porting-3d/export_daily_motions.py` 的模块注释
——游戏按两层发：per-idol `chr_anim_com_<idol>.unity3d` 与 commu pose set
`chr_anim_com_<cat>_<pose><variant>.unity3d`（`cat` ∈ `cut/col/pas`）；反应组带
`noo/yes/str/lop/end`，待机组带 `act/swt`。`export_daily_motions.py` 合并两层后
`~/mltd-work/motion-daily-merged/index.json` 覆盖 62 个角色，每个角色都有这 7 个动作。

| action | 用途 tag | loop | 帧数（30fps 源 / 60fps 输出） | 时长 | 来源示例（001har） |
|---|---|---|---|---|---|
| `act` | `idle` | 是 | 56 / 111 | 1.85 s | `com_001har_18y_act`（native） |
| `swt` | `idle-variant` | 是 | 56 / 111 | 1.85 s | `com_001har_18y_swt`（native） |
| `yes` | `agree` | 否 | 31 / 61 | 1.02 s | `com_001har_18y_yes`（native） |
| `noo` | `disagree` | 否 | 31 / 61 | 1.02 s | `com_001har_18y_noo`（native） |
| `str` | `surprise` | 否 | 26 / 51 | 0.85 s | `com_001har_18y_str`（native） |
| `lop` | `relax` | 否 | 46 / 91 | 1.52 s | `com_001har_18y_lop`（native） |
| `end` | `leave` | 否 | 31 / 61 | 1.02 s | `com_001har_18y_end`（native） |

> 帧数是逐角色实测（001har 与其余角色多数一致，个别角色源帧数不同）；`catalog.json` 里存的是实际值。
> loop 划分依据是剪辑在游戏 stand 里的角色（待机两态循环、反应一次性），不是原始资源里的显式字段。

### 3.2 为什么没有 `greet/bow/wave/think/laugh/drink/phone/stretch/sit`

- 这些不是 stand 状态剪辑。游戏 stand 只播放上面 7 个 clip；`greet/bow/wave` 这类动作在
  **剧情 scene 动画**、**Live 演出**、**卡面/首页触摸反应**里，属于另外的资源和驱动方式。
- `~/mltd-work/chranim-scene` 里是 `chr_anim_com_col_*` 这类**共用 collab 动画**，不是逐角色日常动作。
- Live 舞蹈是 `.imo` 曲线包（`imo_*`），和 stand 状态剪辑不是一套东西，不要混用（见 §8.3）。
- 如果产品确实需要 10 个语义动作，建议另开 P0.5：从剧情 scene 动画里挑全身一次性动作 + 做时长/镜像适配，
  或直接接受「7 个状态动作 + 面部表情 + 说话口型」的表达力上限。

### 3.3 本次已交付（接收方侧完成）

- 重建了 `build/eidolon-model3d-mltd.eidolonpkg`：把 `motions/` 换成 56 角色 × 7 动作，
  新增 `motions/catalog.json`，并重算 manifest `files` 的 size/crc32。
- 复现命令（不需要 asset-server token，纯本地解码）：

```bash
# 1) 只解码动作，跳过模型/shared 下载
~/mltd-work/venv/bin/python tools/fetch_unity3d_content.py \
  --motions-only --out /tmp/mltd-motions

# 2) 把动作 + catalog 合进 model3d 包（重算 files 校验）
python3 tools/build_mltd_3d_packages.py \
  --model-source /tmp/prev-model3d.eidolonpkg \
  --content-base /tmp/prev-content.eidolonpkg \
  --out-model build/eidolon-model3d-mltd.eidolonpkg \
  --out-content build/eidolon-content-mltd.eidolonpkg \
  --motions-dir /tmp/mltd-motions
```

- `motions/catalog.json` 实际结构（`version:1`，`format:"eidolon.motions/1"`，`fps:60`）：

```json
{
  "version": 1,
  "format": "eidolon.motions/1",
  "fps": 60,
  "characters": {
    "001har": {
      "actions": [
        {
          "id": "act",
          "file": "motions/001har/act.tsv",
          "loop": true,
          "duration": 1.85,
          "frames": 111,
          "tags": ["idle"],
          "source": {"clip": "com_001har_18y_act", "pack": "chr_anim_com_001har.reduc.unity3d", "origin": "native"}
        }
      ]
    }
  }
}
```

- 根位移：每个 TSV 都有根节点 `POSITION` 的位置轨道，实测 x/y 恒为 0，z 只有
  `±0.00025 ~ ±0.01625`（身体缩放层，不是角色位移），即**全部原地动作，无平面根位移**。
- 缺动作 fallback（客户端侧约定，尚未实现）：角色没有 motions 时只播静态姿势 + 面部/口型；
  不跨角色借用动作（骨架相同但姿势会串味）。

### 3.4 待接收方客户端实现（不在本次数据交接范围）

- Unity 宿主加 `PlayAction(string action)`（一次性动作播完回 `act`，循环动作可被下一次请求打断）。
- Swift `UnityCharacterRenderer` 读 `motions/catalog.json`，按 `tags`/情绪选动作，发 `PlayAction`。
- 切换 crossfade、动作与 `SetSpeaking` 口型叠加、动作队列去重。

## 4. P1：剧情文本（未交付）

### 4.1 最小交付

- 1 条完整路线的 episode（建议 `001har` 相关主线/日常），包含：
  - episode id、category、title、route/chapter
  - cast（哪些角色出场）
  - 每行：seq、speaker id、日文原文、中文翻译（没有翻译可空）
  - 行级可选字段：背景/立绘/表情/语音 cue
- 全量交付时按 episode 分文件，附一个总索引。

### 4.2 推荐格式

优先直接给 SQLite，表结构对齐现有 `ContentSchema`：

```sql
episodes(id, category, source, title, imported_from, imported_at)
episode_cast(episode_id, character_id)
episode_lines(episode_id, seq, speaker, ja, zh)
```

如果原始格式不是 SQLite，给 CSV + 导出脚本即可，但字段名必须能无歧义映射到上面。

### 4.3 需要说明的语义

- `category` 的取值（主线 / 日常 / 活动 / 卡面剧情 / 剧场对话等）。
- `speaker` 用角色 localID 还是游戏内 speaker id；如果是后者，给对照表。
- 是否有路线分支；一条 episode 是否可能包含多个分支文本。
- 文本里是否混入 Live/演出指令、ruby、控制标签；如何清洗。
- 是否已有中文翻译；如果没有，给日文原文即可，不要机器翻译后冒充原文。

## 5. P2：语音（未交付）

### 5.1 最小交付

- 10 条带语音的剧情行样例：
  - episode id + seq
  - 角色 localID
  - 音频文件（未加密的 ogg/m4a/wav 均可）
  - 时长、采样率
  - 原始 cue / 文件名
- 全量交付时给「剧情行 → 音频文件」映射表。

### 5.2 推荐映射格式

建议新增独立文件，不强行塞进现有 `episode_lines`：

```json
{
  "version": 1,
  "episode_id": "mltd_main_001",
  "lines": [
    {"seq": 12, "character": "001har", "file": "voice/001har/xxx.ogg", "duration_ms": 2340, "cue": "..."}
  ]
}
```

或 SQLite：

```sql
episode_voices(episode_id, seq, character_id, audio_file, duration_ms, cue, source)
```

### 5.3 音频要求

- 优先未加密原始音频；如果必须解密，提供解密脚本、key 来源和解密后文件清单。
- 文件名不要只给 hash；至少给 `episode/seq/character` 可追溯的映射。
- 说明是否包含 BGM/SE；剧情语音和 Live 音频要分开。

## 6. 通用数据契约

- 角色 ID 必须与 3D 包一致：`001har`、`002chi`……不要用游戏内的另一个数值 ID 混用；如果有内部 ID，给对照表。
- 所有包必须声明 `franchise=mltd`；内容包 manifest 使用 `format_version=5`。
- 所有数据路径不得写死个人机器绝对路径；脚本用参数/环境变量。
- 原始游戏资产、语音、解包 dump 不进仓库；只提交脚本、schema、映射和可公开的样例说明。
- 交付时附 SHA-256 或文件大小校验；如果脚本会联网拉取，注明版本/日期。

## 7. 验收标准

### P0 动作

- [x] `motions/catalog.json` 能解析，动作 ID 唯一，loop/时长字段齐全。
- [x] 56/57 个角色各有 7 个动作（`052tmg` 无动作包，客户端按 fallback 处理）。
- [ ] 客户端能依次播放 `act → lop → yes → noo → str → end → act`，肉眼可见不同姿势，结束后回 idle。
      （数据已就绪，`PlayAction` 协议待实现）
- [ ] 动作切换无 T-pose、无穿模；根位移已确认不存在（§3.3）。
- [ ] 至少一个动作可与 `SetSpeaking` 口型同时工作。
- [ ] 3 个角色（`001har`、`002chi`、`014mir`）抽样确认动作来自各自角色包，不是共用动作。

### P1 剧情样例（未交付）

- [ ] 1 条完整 episode 可导入现有 `episodes/episode_cast/episode_lines`。
- [ ] 每一行 speaker 都能映射到 57 个角色 localID 之一（旁白/未知可空）。
- [ ] 至少 30 行日文原文；中文翻译可空但字段存在。
- [ ] 客户端能按角色检索到这条 episode，不跨角色串线。

### P2 语音样例（未交付）

- [ ] 10 条剧情行有对应音频，能按 `episode + seq` 精确播放。
- [ ] 音频时长与映射表一致；乱序/缺失有明确错误。
- [ ] 不要求端上实时合成，只要求本地播放。

## 8. 需要上一 agent 明确回答（接收方已能自行回答的，直接写结论）

1. **原始游戏 dump 根目录在哪？** `~/mltd-work`（本机工作目录，不在仓库内）：
   `bundles/`（原始 UnityFS）、`characters/`（cb/ch 模型）、`chranim-com/`、`chranim-scene/`（动作包）、
   `motion-daily-merged/`（合并后的 motion JSON + `index.json`）、`asset-manifest/manifest.msgpack`
   （版本锁定的资源名清单）、`venv/`（解码用的 Python 环境）。影子数据 `out/` 存截图/探针结果。
2. **哪些拆包脚本能直接复用？** `spikes/porting-3d/export_daily_motions.py`（两层动作合并、产出
   `motion-daily-merged`）、`spikes/porting-3d/photo_pose.py` 等导出脚本、
   `tools/fetch_unity3d_content.py`（把 motion JSON 重采样成 60fps flat TSV，写 `catalog.json`）、
   `tools/build_mltd_3d_packages.py`（组装包 + 重算 size/crc32）。
3. **日常动作在游戏资源里是什么格式？和 Live 舞蹈如何区分？**
   是 Unity AnimationClip（EULR 曲线包，经 `export_daily_motions.py` 解码成 `eidolon.motion/1` JSON）。
   区分方式：stand 状态剪辑在 `chr_anim_com_<idol>` / `chr_anim_com_<cat>_<pose><variant>` 包里，
   clip 名形如 `com_<idol>_<age>_<action>`；Live 舞蹈是 `.imo` 曲线包（`imo_*`），另一套读取器
   （`ios/MotionSway.swift` 那类），不要混用。
4. **语音是否加密？key/解密脚本在哪？语音 cue 如何对应剧情行？** UNKNOWN：本次没有推进语音，
   仓库里没有已验证的语音解密/映射脚本。
5. **剧情文本是 scenario 文件、masterdata 还是数据库？有没有现成 parser？** UNKNOWN：
   本次没有推进剧情文本抽取；`episode_lines` 目前只有合成样例。
6. **有没有现成中文翻译？** UNKNOWN。已知内容包里 `zh` 字段存在但只有占位。
7. **57 个角色是否都有日常动作？没有的用什么 fallback？** 56/57 有 7 动作；`052tmg` 没有
   （`index.json` 无条目、本地也无动作包）。客户端 fallback：只播静态姿势 + 表情/口型。
8. **现有 3D 资产管线的哪些代码/文档可以直接交接？** 可直接用：
   `spikes/porting-3d/README.md`（动作两层、裙摆解算、色彩空间等一手结论）、
   `spikes/porting-3d/notes.md`（Gamma 色彩空间验证）、`docs/research/mltd-3d-pipeline-2026-10-31.md`、
   `docs/3d-stand-prototype-status.md`（客户端入口与已知限制）。
   已过期/仅历史参考：早期 `haruka3d` 单角色补丁包（`tools/add_3d_test_character.py` 产出的
   SC 内容包变体）、旧 `eidolon-content-3dtest.eidolonpkg` 的 3 动作 `motions/`。

## 9. 不在本次交接范围

- 客户端 Swift/Unity 运行时实现（动作选择、crossfade、播放协议由接收方做，见 §3.4）。
- 中文翻译质量、人工校对。
- Live 舞蹈/演出完整还原。
- 正式 UI、剧情播放器、语音播放器交互。
