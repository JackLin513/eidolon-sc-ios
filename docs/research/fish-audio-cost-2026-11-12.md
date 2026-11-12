# Fish Audio 训练与成本调研：Sakura / VO01 数据集（2026-11-12）

- 日期：2026-11-12
- 范围：本地数据集 `build/sakura-voice/`（VO01，159 段 WAV，12.04 min，仅本机）、本仓库现状接缝（`FishSynthesis.swift`、`ChatSettings.fishModel`、内容包 `characters.json`）、Fish Audio 官方文档 / 官方定价页 / 官方定价接口（2026-11-12 当天核对）。
- 目的：回答"这份 12.04 min 的 Sakura 数据能不能训、训一次要多少钱、每次用要多少钱、钱从哪一步花出去"。
- 性质：**调研结论，不是 spec、不是 ADR、不是已实现设计**。落地仍要走 grill → spec → implement。
- 合规声明：本次调研**没有**上传任何音频、**没有**创建/训练/发布任何模型、**没有**产生任何费用。只发生过一次免费读请求（`GET /model?self=true`，见 §8）。`FISH_AUDIO_API_KEY` 只读取、不打印、不落盘；本文不含任何密钥。

---

## 0. 摘要

| 问题 | 结论 | 置信度 |
|---|---|---|
| 推荐的训练方式 | **API 模型创建（`train_mode=fast`，即时克隆）**，不需要订阅；不是 PVC | 高 |
| 一次性成本 | **$0**（模型创建无公开计价项；可选 ASR 转写 20 段 ≈ **$0.017**，全 159 段 ≈ **$0.081**） | 中高（"无训练费"是"没有计价项"的推断） |
| 每次使用成本 | **现在 $0**：App 默认模型 `s2.1-pro-free` 在公平使用下免费；免费窗口官方写"至 2026-11-30"，之后**未知** | 高（现状）/ 未知（12 月后） |
| 若改付费 TTS | `s2.1-pro` **$15 / 1M UTF-8 字节**；日文约 3 B/字 → 50 字一段 ≈ **$0.00225**；1000 段 ≈ **$2.25** | 高 |
| PVC（专业克隆）的一次性成本 | 需付费套餐：**Plus $15/月（年付 $132，合 $11/月）含 1 个 PVC 槽**；Pro $100/月（$900/年）含 5 个；**训练本身没有单独收费项** | 高（价格）/ 中（"含在套餐"的表述） |
| PVC 能不能用在这份数据上 | 时长够（12.04 min ≥ 10 min），但 **PVC 必须做声纹/授权验证**：本人录音或代理上传授权证明；Sakura 是声优（北大路ゆき）的声音，**大概率过不了验证** | 高 |
| 数据形式是否合规 | 159 段全是 **2.0–9.7 s 的短句**，没有一段 ≥ 45 s；PVC 推荐 12–15 段 × 45–60 s，需要本地拼接 | 高（实测） |
| `VO01` 是否 Sakura | **按通道顺序推定，未验证**；仓库自己的调研也这么写 | 中低 |
| 全量 galgame 重录参考 | 70k 行 × 约 66 B ≈ 4.62 MB → `s2.1-pro` ≈ **$69**；`drama-3` ≈ **$231**（促销 $10/M 时至 2026-12-01 08:00 UTC ≈ **$46**）；ASR 全量 24.55 h ≈ **$8.84** | 中（行数与字符数是估算） |
| 折人民币（≈7.1） | $0；$15 ≈ **¥107**；$132 ≈ **¥937**；$69 ≈ **¥492** | 低（汇率浮动，仅量级） |

**一句话**：现在走 API 即时克隆，钱基本是 **$0**；唯一确定会花钱的小项是可选 ASR（几美分）。PVC 要 **$15 起**，而且以 Sakura 是别人的声音这一点，**声纹/授权验证基本过不了**——先别买套餐。

---

## 1. 方法与来源等级

| 等级 | 含义 | 本文例子 |
|---|---|---|
| **官方页面** | 2026-11-12 当天直接抓取的 Fish 官方页面/接口 | `fish.audio/plan/`、`api.fish.audio/pricing/plans` |
| **官方文档** | `docs.fish.audio` 的 Markdown（Mintlify 支持给页面 URL 加 `.md` 直接取原文） | 定价、PVC、Create Model、ASR、术语 |
| **实测** | 本机对数据集与 API 的不花钱读操作 | 159 段时长/响度、`GET /model` 返回 200 |
| **推断** | 由事实推出、未被官方文字直说 | "模型创建不收费"、"跨套餐槽位语义" |

所有价格均为 **USD 挂牌价**；人民币按 **1 USD ≈ 7.1 CNY** 粗折，仅表量级。

---

## 2. Fish Audio 的三种"克隆"与各自的计费

### 2.1 三种方式（容易混淆，先分清）

| 方式 | 在哪做 | 是否要训练 | 要不要付费套餐 | 要声纹/授权验证吗 | 计费 |
|---|---|---|---|---|---|
| **即时克隆 / fast 模型** | API `POST /model`（`train_mode=fast`）或 Web 应用 | "训练"= 即时可用，几秒级 | **不要**（API 是纯按量付费） | **不要**（技术上不问） | 创建无公开计价项；用 TTS 时按字节计费 |
| **PVC（专业克隆）** | **仅 Web 应用**（文档原文 "Web app only"） | 要，10–30 min | **要**：付费套餐含 PVC 槽 | **要**：本人录音，或 Proxy 上传授权证明 + 人工审核 | 含在套餐里，**没有单独的"训练费"计价项** |
| **API TTS** | API `POST /v1/tts` | 不涉及 | **不要** | 不涉及 | 按输入文本的 UTF-8 字节数 |

> 结论先记住：**PVC 不是 API 能做的事**。OpenAPI 里 `POST /model` 的请求字段 `train_mode` 是 `const: fast`（只接受 `fast`）；响应模型实体里虽然还能看到 `full` 这个枚举，但**请求侧无法创建 `full` 模型**。完整训练只能在网页应用里走 PVC 流程。
> （[Create Model](https://docs.fish.audio/api-reference/endpoint/model/create-model)、[Voice Cloning](https://docs.fish.audio/features/voice-cloning)）

### 2.2 订阅套餐价格（2026-11-12，官方定价页）

| 套餐 | 月付 | 年付 | 每月积分 | 生成时长 | 音色槽位 | PVC 槽位 |
|---|---|---|---|---|---|---|
| Free Tier | $0 | — | 8,000 | ~7 min | 3 个公开 | **无**（PVC 不含在 Free） |
| Plus | **$15/月** | **$132/年**（合 $11/月） | 250,000 | ~200 min | 公开不限 + 10 私有 | **1 个专业槽** |
| Pro | **$100/月** | **$900/年**（合 $75/月） | 2,000,000 | ~1,620 min | 音色不限 | **5 个专业槽** |

- 来源：[`fish.audio/plan/`](https://fish.audio/plan/)（中文版 [`/zh-CN/plan/`](https://fish.audio/zh-CN/plan/)），2026-11-12 抓取；并交叉核对官方定价接口 [`https://api.fish.audio/pricing/plans`](https://api.fish.audio/pricing/plans)。
- 官方定价接口同一个响应里还返回 `lite`（$6/月、$54/年）与 `max`（$999/月、$8,988/年），但**套餐页上没有展示**，其 PVC/槽位权益**未知**，不要拿它做预算。
- "You save $48/$300"、"3 months off"、`campaign_promo_ends_at = 2026-12-01T08:00:00Z` 说明页面价格含阶段性活动；不同地区/时间可能看到不同促销价（例如部分地区首年 50% off）。**买之前以结账页为准。**
- 订阅与 API **分开计费**：官方 FAQ 写明 API 是 pay-as-you-go、无需订阅；套餐积分用于 Web 应用生成。

### 2.3 API 计价（2026-11-12）

| 项目 | 价格 | 说明 |
|---|---|---|
| `s2.1-pro` / `s2-pro` | **$15.00 / 1M UTF-8 字节** | 约等于 18 万英文词或 12 小时英文语音（官方口径，按英文估） |
| `s2.1-pro-free` | **$0.00 / 1M 字节** | 同一个模型，公平使用；官方博客写免费窗口"至 **2026-11-30**"，之后**未公布** |
| `drama-3` | **$50.00 / 1M 字节** | 2026-12-01 08:00 UTC 前促销 **$10.00 / 1M** |
| `s1` | $15.00 / 1M | 2026-12-31 退役，请求会被 `s2.1-pro` 接管并按同价计费 |
| ASR `transcribe-1-pro` / `transcribe-1` | **$0.36 / 音频小时** | 按秒向上取整、含静音、每个成功请求计一次；错误请求不计费 |
| ASR `transcribe-stream-1` | $0.36 / 会话小时 | 实时预览版 |
| Voice Design `voice-design-1` | **$0.01 / 成功请求** | 一次请求返回多个候选也只收一次；报错/余额不足不计费 |
| 并发 | < $100 累计付费 → **5**；≥ $100 → 15；≥ $1000 → 50 | 超限 429，**没有 Retry-After**，要指数退避 |

来源：[Pricing & Rate Limits](https://docs.fish.audio/developer-guide/models-pricing/pricing-and-rate-limits)、[S2.1 Pro Free 博客](https://fish.audio/blog/s2-1-pro-free-api/)、[Changelog](https://docs.fish.audio/developer-guide/getting-started/changelog)。

`drama-3` 的 $10 促销价是"到 2026-12-01 08:00 UTC"的限时价，**本文之后的价格判断都要按"促销会结束"来预留**。

**免费模型的实际边界**（官方博客原文要点）：无硬性字符上限、best-effort（无 SLA/TTFA 保证）、**请求可能被用于改进模型质量（数据留存）**、商业用途有限制（ARR > $1M 要先联系）。个人本机自用没问题，但"把游戏语音传上去"这件事本身会进入它的 User Submissions 条款（见 §7）。

### 2.4 "训练是否单独收费"——直接回答

- **API 即时克隆**：官方没有任何"创建模型/克隆一次收 X"的计价项；只有 TTS 按字节、ASR 按小时、Voice Design 按请求。所以按公开价目，**即时克隆一次性成本 = $0**。
- **PVC**：文档说"付费套餐 + 一个 free PVC slot"、"每个付费套餐包含若干 PVC 槽位"，训练 10–30 min；**也没有单独的"训练费"**。也就是说 PVC 的成本 = **套餐订阅费**（最低 Plus $15/月），训练次数受槽位数限制（Plus 只有 1 个槽）。
- **但**"创建模型 $0"是**没有计价项**的推断，不是官方一句"免费"。**账户是否允许在 Free 套餐下创建私有 API 模型、是否占用"3 公开 / 10 私有槽位"**，文档没有写清（套餐页的槽位措辞更像 Web 应用音色库的槽位）。这一条只能靠实际发一次 `POST /model` 才能确定（见 §5，需用户批准后执行）。

---

## 3. 数据集核查：这份 12.04 min 能不能用

### 3.1 实测事实

来源：`build/sakura-voice/manifest.json` + `ffprobe`/`ffmpeg`（2026-11-12，本机）。

| 指标 | 实测值 | 说明 |
|---|---|---|
| 段数 | **159** | 命名 `VO01_xxxx.OGG.wav` |
| 总时长 | **722.12 s = 12.04 min** | 与 manifest 一致 |
| 单段时长 | **2.001–9.655 s** | **没有一段 ≥ 45 s**；最长的 20 段合计只有 **2.58 min** |
| 格式 | PCM s16le / **24 kHz** / 单声道 | 由 Ogg 转出；Fish 接受 WAV |
| 响度（EBU R128） | **−35.8 … −14.8 LUFS**，中位 −17.7，跨度 **21 dB** | 135/159 段 ≥ −20 LUFS；最安静几段低到 −35.8，像弱音/噪声 |
| 转写文本 | **没有** | 目录里只有 `manifest.json` 与 `wav/` |
| 来源 | `voice.pac` 前缀 `VO01` | 仅本机，不提交仓库 |

### 3.2 PVC 门槛逐条对照

| PVC 要求（官方） | 这份数据 | 判定 |
|---|---|---|
| **总时长 ≥ 10 min** | 12.04 min | ✅ 满足（余量 2 min） |
| 上限 180 min | 12.04 min | ✅ |
| **每段 < 1 min** | 最长 9.655 s | ✅ |
| 推荐 **12–15 段 × 45–60 s**、一致音色 | 159 段短句，0 段 ≥ 45 s | ❌ 形式不符；**需本地拼接成约 13 段（12 段 53–59 s + 1 段约 41 s）**（用现有 159 段拼，总时长不变，见 §6） |
| 格式 MP3/WAV/FLAC，单一说话人、干净 | WAV、单人通道（推定） | ⚠️ 24 kHz 非高保真、部分段响度很低、是否含 BGM/SE **未抽听验证** |
| 声纹验证（本人录音或 Proxy 授权） | Sakura = 声优 北大路ゆき 的声音 | ❌ **不是用户本人的声音，也没有书面授权** → 大概率无法通过 |
| 发布时间线（1/2/3 年通知期）、可见性 | — | ⚠️ 发布 = 把克隆音色放进 Fish 平台，公开/Unlisted 都有外泄风险 |

### 3.3 `VO01` 是否 Sakura（**未验证**）

- 游戏 `voice.pac` 的语音通道 `VO01..VO29/97/98/99` 与 `STAND.CSV` 的 `st01..st20` 对位；仓库调研把 `st01 = 夜乃桜（CV 北大路ゆき）`、`vo01 = 4,085 条 / 4.22 h` 列在 cast 表第 1 行，并用特典文件 `Sakura_omake1_*.wav` 作为旁证。
- 但同一份调研在"仍需注意"里明确写：**`VO01` 与夜乃桜的对应关系目前按通道顺序推定，正式训练前要用 `.MIX`/脚本 voice id 或人工试听确认**。
- 本文结论：**plausible but unverified**。训练前至少做两件事之一：① 人工抽听 5–10 段，确认是同一女声且与特典 Sakura 音色一致；② 从 `.MIX`/脚本恢复 voice id 与角色的静态绑定（调研 §3.3/§12.4.3 的 P4 工作）。**这一步不花钱，但决定"训出来的是谁"。**

---

## 4. 成本估算

### 4.1 方案 A（推荐）：API 即时克隆 + 免费 TTS 模型

| 项目 | 假设 | 成本 |
|---|---|---|
| 选片 | 20 段（≤ API 上限 20 个文件），例如按时长+响度筛出的 20 段 = **155.1 s = 2.58 min** | $0（本地） |
| 模型创建 | `POST /model`，`train_mode=fast`，`visibility=private`，`enhance_audio_quality=true` | **$0**（无公开计价项；是否有账户限制未知） |
| 转写（可选） | 省略 `texts` 则 Fish 内部跑 ASR（**这部分是否计费未公开**）；或自己调 `/v1/asr`：20 段共 155.1 s，按秒向上取整合计 163 s → **$0.0163**；全 159 段逐段请求合计 805 s → **$0.0805**（若拼接成单文件则 723 s → $0.0723） | $0–0.08 |
| 上传 | 20 段约 2.58 min 音频 | 无公开费用 |
| **一次性合计** | | **$0.00 – 0.08**（¥0 – ¥0.6） |
| 每次 TTS（当前） | `s2.1-pro-free`，公平使用 | **$0** |
| 每次 TTS（若 12 月后转付费） | `s2.1-pro` $15/M：一段 50 日文字 ≈ 150 B → **$0.00225**；1000 段 ≈ **$2.25**（¥16） | 见左 |

### 4.2 方案 B：PVC（专业克隆）

| 项目 | 假设 | 成本 |
|---|---|---|
| 订阅 | Plus 月付 **$15**（¥107）/ 年付 **$132**（¥937）；Pro $100/月 或 $900/年 | **$15 起** |
| PVC 槽位 | Plus 1 个（Pro 5 个） | 已含 |
| 训练 | 10–30 min，官方无单独收费项 | $0（在套餐内） |
| 音频准备 | 本地把 159 段拼成约 13 段（12 段 53–59 s + 1 段约 41 s） | $0（本地 ffmpeg） |
| 声纹验证 | 本人录音 → **对 Sakura 不成立**；Proxy → 要授权证明 + 人工审核 | **卡点** |
| 发布 | 必须选可见性（Public/Unlisted）+ 1/2/3 年通知期；"Platform/API availability"发布后锁定 | 0 元但有外泄/法律风险 |
| **一次性合计** | | **$15（若月付并在一个月内做完）**，但**大概率验证失败、钱白花** |

> 备注：文档说"升级套餐拿 PVC 槽"，但**套餐到期后已发布音色在 API 上还能不能用、未发布（只训练）的模型能不能直接用 API**，官方都没写 → **未知**。
> 另外 Voice Design 在套餐页属于 Plus 起的功能，但 API 侧的 `voice-design-1` 是 $0.01/请求；**API 是否需要套餐/最低充值未知**。

### 4.3 方案 C（合规替代）：Voice Design 原创造音

| 项目 | 假设 | 成本 |
|---|---|---|
| `POST /v1/voice-design` | $0.01/成功请求，一次可出多个候选 | **$0.01/次**（¥0.07） |
| 之后 TTS | 用候选签名建模型（`voice_design_signatures`）或直接当 `reference_id` | 同方案 A 的 TTS 价 |
| 优点 | 不克隆真人、不碰声优权利，可公开发布 | — |

如果目标是"一个像 Sakura 的原创音色"而不是"复刻北大路ゆき"，这是唯一干净的路，成本 **1 美分**。

### 4.4 全量 galgame 重录的参考量级（不是这次要花的钱）

- 70,111 行 × 约 22 日文字/行 × 3 B ≈ **4.62 MB** → `s2.1-pro` ≈ **$69.3**（¥492）；`drama-3` ≈ $231（促销期 $46.2）。
- 全量 ASR（24.55 h）≈ **$8.84**。
- 结论与仓库既有调研一致：**TTS 本身不是大头**，贵的是 embedding、人工和合规。

---

## 5. 会花钱的确切步骤（当前全部未执行）

| # | 动作 | 花费 | 风险/备注 |
|---|---|---|---|
| 0 | `GET /model?self=true`（已执行，免费读） | **$0** | 已确认密钥有效、账号自有模型 **0 个** |
| 1 | `POST /v1/asr` 转写（可选） | **$0.0163**（20 段）/ **$0.0805**（159 段逐段） | 每文件一次请求、按秒向上取整；错误请求不计费 |
| 2 | `POST /model`（`train_mode=fast`） | **$0**（无计价项） | **会往 Fish 上传音频**；是否在 Free 套餐受限未知；创建即产生私有模型 |
| 3 | `POST /v1/tts`（每次生成） | `s2.1-pro-free` 现在 **$0**；12 月后未知 | 免费模型请求可能被用于改进模型（数据留存） |
| 4 | **升级 Plus 套餐**（`fish.audio/app/billing`） | **$15/月** 或 **$132/年** | **这是 PVC 路线唯一真正的扣费点**，点了就扣 |
| 5 | `POST /v1/voice-design` | **$0.01/次** | 需要 API 余额；余额不足请求不计费 |
| 6 | 全量 TTS 重录（若做） | 约 **$69**（`s2.1-pro`，4.62 MB 估） | 量级参考，不是本轮动作 |

**一句话**：**想让"训练"这件事花出第一笔钱，只有两条**——自己调 ASR（几分钱），或**买 Plus 套餐（$15）走 PVC**。`POST /model` 的即时克隆按公开价目是 $0。

---

## 6. 可运行但**未执行**的命令/API 序列（方案 A）

> 前提：用户看过 §7 之后明确批准"把 Sakura 的音频上传到 Fish Audio 并创建私有模型"。**不要**在批准前跑第 2 步以后。

### 6.1 本地准备（$0，纯本机）

```bash
# 在仓库 worktree 根目录；不 echo 密钥
export FISH_AUDIO_API_KEY="$(grep -E '^FISH_AUDIO_API_KEY=' ../eidolon-sc/.env | cut -d= -f2- | tr -d '"'"'"' \r')"

mkdir -p /tmp/sakura-train
# 1) 从 159 段里挑 20 段：按时长降序、响度 ≥ -20 LUFS（本机可复现的选法）
python3 - <<'PY'
import json, subprocess
m = json.load(open('build/sakura-voice/manifest.json'))
rows = []
for c in m['clips']:
    p = 'build/sakura-voice/' + c['file']
    out = subprocess.run(['ffmpeg','-hide_banner','-nostats','-i',p,
        '-af','ebur128=framelog=quiet','-f','null','-'],capture_output=True,text=True).stderr
    lufs = next((float(t.split()[0]) for t in out.split('I:') if 'LUFS' in t), -99.0)
    if lufs >= -20.0:
        rows.append((c['duration'], p))
rows.sort(reverse=True)
sel = rows[:20]
open('/tmp/sakura-train/files.txt','w').write('\n'.join(p for _,p in sel))
print(len(sel), 'clips', round(sum(d for d,_ in sel),1), 's')
PY

# 2) 可选：把这 20 段拼成 5 个 ~30 s 文件，满足“单段 ≥10 s”的推荐
python3 - <<'PY'
files = open('/tmp/sakura-train/files.txt').read().split()
groups = [files[i::5] for i in range(5)]
for gi, g in enumerate(groups):
    with open(f'/tmp/sakura-train/concat{gi}.txt','w') as f:
        for p in g: f.write(f"file '{p}'\n")
PY
# for i in 0 1 2 3 4; do ffmpeg -y -v error -f concat -safe 0 \
#   -i /tmp/sakura-train/concat$i.txt -ac 1 -ar 24000 /tmp/sakura-train/voice$i.wav; done
```

### 6.2 转写（可选，**会花钱**：20 段约 $0.0163）

```bash
# 每段一次请求；响应取 text 字段。也可以跳过，让 POST /model 内部跑 ASR（计费未公开）。
while read -r p; do
  curl -sS https://api.fish.audio/v1/asr \
    -H "Authorization: Bearer $FISH_AUDIO_API_KEY" -H "model: transcribe-1-pro" \
    -F "audio=@$p" -F ignore_timestamps=false
done < /tmp/sakura-train/files.txt > /tmp/sakura-train/asr.jsonl
```

### 6.3 创建模型（**会往 Fish 上传音频**；公开价目 $0，账户限制未知）

```bash
# multipart；voices 最多 20 个，texts 可选且必须与 voices 同数量
curl -sS https://api.fish.audio/model \
  -H "Authorization: Bearer $FISH_AUDIO_API_KEY" \
  -F type=tts \
  -F 'title=Sakura (VO01, local-only)' \
  -F train_mode=fast \
  -F visibility=private \
  -F 'description=Local-only experiment from voice.pac channel VO01; personal use only' \
  -F enhance_audio_quality=true \
  -F generate_sample=false \
  -F voices=@/tmp/sakura-train/voice0.wav \
  -F voices=@/tmp/sakura-train/voice1.wav \
  -F voices=@/tmp/sakura-train/voice2.wav \
  -F voices=@/tmp/sakura-train/voice3.wav \
  -F voices=@/tmp/sakura-train/voice4.wav
  # 若上一步做了 ASR：再加 -F texts='...' -F texts='...' …（数量与 voices 相同）
# 返回 {"_id": "<voiceID>", "state": "trained", "train_mode": "fast", ...}
```

字段依据：[Create Model API](https://docs.fish.audio/api-reference/endpoint/model/create-model) —— `type=tts`/`title`/`train_mode=fast`/`voices` 必填；`visibility` 默认 `private`，传 `public` 会被降级为 `private`；`texts` 省略则跑 ASR；`voices`/`texts` 各 ≤ 20。

### 6.4 接上 App（**需要改内容包/代码，属于另一张批准单**）

- 现在内容包 `characters.json` 的 `voice_id` 是占位串 `"sakura"`（`tools/build_sakura_pack.py:131`），不是 Fish 模型 id；App 默认 `fishModel = "s2.1-pro-free"`（`EidolonIOS/Core/ChatSettings.swift:81`）。
- 拿到 `_id` 后回填 `voice_id`（重新打内容包），通话链路（`FishSynthesis` → `reference_id`）即可用真音色。

### 6.5 冒烟测试（**免费**，用免费模型）

```bash
curl -sS https://api.fish.audio/v1/tts \
  -H "Authorization: Bearer $FISH_AUDIO_API_KEY" \
  -H 'Content-Type: application/json' -H 'model: s2.1-pro-free' \
  -d '{"text":"おはよう、先輩。今日も一緒に頑張りましょう。","reference_id":"<voiceID>"}' \
  -o /tmp/sakura-train/smoke.mp3
```

### 6.6 若坚持 PVC：Web 应用步骤（**第 1 步就扣 $15**）

1. `fish.audio/app/billing` → 升级 **Plus**（$15/月，或 $132/年）→ **扣费发生在这里**。
2. 本地把 159 段拼成 **约 13 段（12 段 53–59 s + 1 段约 41 s）**（§3.2；`ffmpeg concat`，$0），统一响度到 −16 LUFS 左右。
3. `fish.audio/app/create-voice` → **Professional Voice Clone** → 上传 13 段（总 12.04 min）。
4. **Analyze Audio** → **Verify Voice Ownership**：本人录音（对 Sakura 不成立）或 **Proxy**（上传授权证明，人工审核）。
5. 训练 10–30 min（含在套餐）→ Preview → **Release**（选 Public/Unlisted + 1/2/3 年通知期；训练素材、可见性、Platform/API availability 发布后锁定）。
6. 拿 model id 回来填 `voice_id`；TTS 仍可继续用 `s2.1-pro-free`（$0）。

---

## 7. 风险与未知（按重要性）

| # | 事项 | 性质 | 说明 |
|---|---|---|---|
| R1 | **授权** | 高 | Fish 官方 Best Practices 明确："只克隆你自己、或给你书面许可的人的声音；**不要**用未经许可的网络/名人声音"。Sakura 是声优 北大路ゆき 的声音 → **两条路都踩这条线**。即时克隆技术上一声不问，但**合规上仍违反 Fish 政策**；被 DMCA/投诉会下架模型（模型实体有 `dmca_taken_down` 字段）。 |
| R2 | **PVC 验证** | 高 | 声纹验证要求"本人朗读提示词"或 Proxy 授权证明。用户不是该声优、也无授权 → **PVC 实际不可用**。 |
| R3 | **ToS 授权** | 高 | 上传内容会给 Fish "royalty-free, perpetual, sublicensable, irrevocable, worldwide" 的许可（ToS 第 2 类条款，删除账户后 Public 内容仍可能保留）。游戏音频上传即触发。 |
| R4 | **免费窗口** | 高 | `s2.1-pro-free` 官方说"免费至 **2026-11-30**"（此前多次延期）；之后的处理**未公布**（可能转 $15/M、可能再延）。当前 `.env` 与 App 默认都靠它，**12 月前要复核一次**。 |
| R5 | **Free 套餐能否建私有 API 模型** | 中 | 文档没写；套餐页"槽位"是 Web 音色库语义。**只能靠一次 `POST /model` 验证**（需批准）。若不允许，最低要 Plus $15/月。 |
| R6 | **`VO01` ≠ Sakura 的可能** | 中 | §3.3；先抽听/解 `.MIX` 再训，否则训错人。 |
| R7 | **音频质量** | 中 | 24 kHz、来自游戏 Ogg 有损转码；21 dB 响度差；是否含 BGM/SE 未抽听。PVC 的"Analyze"可能拒掉部分段；即时克隆有 `enhance_audio_quality=true` 兜底。 |
| R8 | **PVC 发布语义** | 中 | 必须 Release（Public/Unlisted）才能用；通知期 1–3 年不可缩短。套餐到期后模型/API 可用性**未知**。 |
| R9 | **素材不出仓** | 已遵守 | 所有产物在 `build/`（ignore），本文不含音频、字幕、密钥、UDID。 |

---

## 8. 证据与复现

### 8.1 本机实测（2026-11-12）

```bash
# 段数/时长（manifest 与 ffprobe 一致）
python3 -c "import json;m=json.load(open('build/sakura-voice/manifest.json'));print(len(m['clips']),m['minutes'])"
# 159 12.04
ffprobe -v error -show_entries stream=codec_name,sample_rate,channels,bits_per_sample \
  -of default=nw=1 build/sakura-voice/wav/VO01_0000.OGG.wav
# codec_name=pcm_s16le sample_rate=24000 channels=1 bits_per_sample=16

# 响度分布（159 段全部测过）：min -35.8 / p10 -23.6 / median -17.7 / max -14.8 LUFS
# 单段时长：min 2.001 s / max 9.655 s；≥45 s 的段数 0；最长 20 段合计 2.58 min
```

### 8.2 不花钱的 API 读检查（只读，无扣费）

```bash
# 密钥存在性只判断非空，不打印
grep -q '^FISH_AUDIO_API_KEY=.\+' ../eidolon-sc/.env && echo present
curl -s -o /tmp/models.json -w '%{http_code}' \
  -H "Authorization: Bearer $FISH_AUDIO_API_KEY" \
  'https://api.fish.audio/model?self=true&page_size=20&page_number=1'
# → HTTP 200；total = 0（账号自有模型 0 个，未创建过任何模型）
```

### 8.3 官方来源（2026-11-12 核对）

- 定价与限流：[Pricing & Rate Limits](https://docs.fish.audio/developer-guide/models-pricing/pricing-and-rate-limits)
- 模型总览（含 s2.1-pro-free 条目）：[Models Overview](https://docs.fish.audio/developer-guide/models-pricing/models-overview)
- 更新日志（s2.1-pro-free 免费窗口表述）：[Changelog](https://docs.fish.audio/developer-guide/getting-started/changelog)
- S2.1 Pro Free 公告（公平使用、数据留存、商业限制）：[fish.audio/blog/s2-1-pro-free-api](https://fish.audio/blog/s2-1-pro-free-api/)
- 创建模型（字段、`train_mode=fast`、voices/texts ≤20）：[Create Model](https://docs.fish.audio/api-reference/endpoint/model/create-model)
- 语音克隆（即时克隆 vs 持久模型、10 s 起）：[Voice Cloning](https://docs.fish.audio/features/voice-cloning)
- PVC（付费套餐 + 槽位、≥10 min、12–15×45–60 s、声纹/Proxy、发布）：[Professional Voice Clone](https://docs.fish.audio/overview/platform/create-voice/professional-voice-clone)
- 克隆授权红线：[Voice Cloning Best Practices](https://docs.fish.audio/developer-guide/best-practices/voice-cloning)
- ASR 计费与请求方式：[Speech to Text](https://docs.fish.audio/api-reference/endpoint/openapi-v1/speech-to-text)
- Voice Design（$0.01/成功请求）：[Voice Design](https://docs.fish.audio/features/voice-design)
- 套餐页：[fish.audio/plan](https://fish.audio/plan/) / [zh-CN](https://fish.audio/zh-CN/plan/)；官方定价接口：[api.fish.audio/pricing/plans](https://api.fish.audio/pricing/plans)
- 服务条款（上传许可、perpetual/irrevocable）：[fish.audio/terms](https://fish.audio/terms/)

---

## 9. 2026-11-12 实测：API 即时克隆被账户额度拦住

在用户批准“测试即时克隆”后，做了两次只读/创建尝试；**没有模型被创建，没有产生费用**：

1. `GET /wallet/self/api-credit`：`credit = 0.0`，`cumulative_top_up = 0`。
2. 先把 `build/sakura-voice/` 的 159 段拼成 20 个约 36 s 的 WAV（共 12.04 min，34.6 MB）上传 `POST /model`：**HTTP 413 Request Entity Too Large**。
3. 转成 20 个 FLAC（共 17.2 MB）再上传：请求体通过，但被 **HTTP 403** 拒绝：

```json
{"status":403,"message":"API model creation limit reached (0/0). Top up API credit to raise the limit."}
```

结论：

- **API 模型创建受 API credit 限制，0 余额时额度是 0/0**；不是“创建完全免费”。
- 官方 API 文档没有写最低充值额；第三方资料常见 **$5 首充**，实际以 API Billing 结账页为准。
- 20 个文件是 `POST /model` 的硬上限；12 min 可以塞进 20 个拼接片段，但请求体要压到服务端大小限制内（FLAC/MP3）。
- 在没有 API credit 前，无法通过 API 做即时克隆；如要走这条路，需要先充值，再重新跑同一请求。

---

## 10. 2026-11-12 实测：API 即时克隆成功（$0，私有模型）

充值 $1 API credit 后重试：

- 先传 12.04 min（20×FLAC）→ `400 Total duration of audios is too long, it should be less than 270 seconds`
- 改成 **19 个 FLAC、71 段、约 261 s（4.35 min）** → `201`，`state=trained`，`train_mode=fast`，`visibility=private`
- 用 `s2.1-pro-free` + `reference_id=<模型 id>` 生成 3 段试听：
  - 日文台词 5.59 s / 89 KB
  - 日文台词 5.3 s / 86 KB
  - 中文台词约 2.6 s / 40 KB
- 生成前后 API credit 都是 **$1.00**；即时克隆创建与本次 TTS 均未扣费
- 模型 ID 与音频只保留在本地 `build/sakura-voice/`（`model.json`、`instant-clone-sample-*.mp3`），不写入公开仓库

**新事实**：`POST /model` 的 fast clone 当前版本有 **总时长 < 270 s** 的限制，不是“20 个文件可无限拼接”。12 min PVC 数据不能直接喂给 fast clone；要更多参考只能走 PVC。

结论：API 即时克隆可用于本机试听；相似度/情绪表现有限，且用 game 原声克隆仍受 Fish 条款与授权约束。
