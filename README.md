# Eidolon-SC iOS

[Eidolon-SC](https://github.com/Sallyn0225/eidolon-sc) 的 iOS 原生客户端，自用，不上架。

手机独立运行：剧情、对话引擎、记忆和好感都在 iPhone 上，运行时只调用外部模型 API（对话 LLM、向量化/重排、TTS、STT），不依赖 FastAPI / Next.js / WebRTC。上游仓库只作为参考实现和离线数据准备工具。

## 现在能做什么

- 首次启动导入内容包（`.eidolonpkg`），角色列表带搜索、最新消息预览和未读搭话标记
- 流式文字对话：日语原文 + 中文字幕，逐段到达；可中途停下
- 判断模型逐回合给好感打分，五档好感、每日回涨、冷却与对话结束、告别与警告台词
- 端上检索：判断决定查不查、查什么；剧情段落、角色资料、作品资料、记忆在端上余弦取候选、云端重排，必要时她还能自己调用「回顾剧情」
- 记忆：回合后在后台提炼，所有角色共享，新记忆可取代旧记忆；App 被杀没跑完的，下次启动补跑
- 她知道自己过的哪一天（按东京时间）：自己的生日总在提示词里，生日当天、其他偶像的生日、日本的节假日、往年同一天她站上过的演出日只在当天加一句；文字、通话、搭话用同一套规则
- 搭话：隔久了打开 App，她会先发一条；列表有未读标记
- 对话标题：第 3 回合后自动生成；历史对话可翻看、可删
- 制作人档案：称呼、性别、时区、生日，改完下一回合生效
- 回合追踪：提示词、判断原文、检索候选与分数、降级原因，本地查看与导出
- 通话（v1 里程碑 2）：静默接通、Soniox 实时识别（角色名作为热词随连接发出，与上游一致）、同一套回合引擎按「通话模式」作答、Fish Audio 逐段合成并在上一段播放时预取下一段；识别断线显示「重连中」并自动恢复，语音服务本身出故障时区分「没能接通」和「中断」；回合失败提示「她那边没声音」但通话继续；每回合与计时到点按「她挂断 → 时长 → 回合」判定结束，先把已排队的语音播完再给说明、写对话事件与追踪；时长与回合上限在设置里改，默认 10 分钟 / 40 回合，可配置，0 为不限
- 设置里配置对话模型、判断模型（百炼 / Jev / Cloudflare / 对话模型）、向量化/重排、Soniox 与 Fish Audio、搭话间隔、追踪

## 还没做

- 通话里的打断与补充（barge-in）：现在她说话时麦克风是合上的，这段时间你说的话会丢掉；上游靠浏览器回声消除一直开麦，可以插话。下一步把播放并进同一个 `AVAudioEngine`（voice processing）后再提前做
- 立绘、照片、礼物、每日任务、成就、统计、数据包
- 一次 5 分钟以上的真机长通话验收（App 已装到 iPhone Air，短通话已跑过）

## 结构

```text
EidolonCore/            # 端上引擎（SPM 包，GRDB + ZIPFoundation）
├── Sources/EidolonCore # 内容包、回合、判断、检索、记忆、搭话、标题、追踪
├── Sources/PromptOracle# 与上游逐字对照提示词的可执行目标
└── Tests/EidolonCoreTests
EidolonIOS/             # SwiftUI 客户端（xcodegen 生成工程）
tools/
├── export_content_bundle.py  # Mac 上把上游数据导出成 .eidolonpkg
└── oracle/                   # 上游提示词对照组
docs/adr/               # 架构决策
GLOSSARY.md             # 领域词汇
```

## 跑起来

1. **准备内容包**（Mac，一次性）：

   ```sh
   cd ../eidolon-sc/backend
   uv run --env-file=../.env python ../../eidolon-sc-ios/tools/export_content_bundle.py \
     --upstream .. --db data/eidolon.db --characters ../characters \
     --out ../../eidolon-sc-ios/build/eidolon-content.eidolonpkg
   ```

   要带上她的立绘，先用上游的 `eidolon stand fetch` 和 `eidolon stand outfits` 把素材整理到
   `build/stand`（`EIDOLON_STAND_BUILD_PATH` 指到这里），再给导出工具加 `--stand`：

   ```sh
   # 默认衣装 + 清单里的前 3 张卡；--stand-all-outfits 打全部，--stand-cards 0 只打默认衣装
   uv run --env-file=../.env python ../../eidolon-sc-ios/tools/export_content_bundle.py \
     --upstream .. --db data/eidolon.db --characters ../characters \
     --stand ../../eidolon-sc-ios/build/stand \
     --stand-cards 3 --out ../../eidolon-sc-ios/build/eidolon-content.eidolonpkg
   ```

   没有偶像编号、默认衣装或素材的角色跳过（同步还没跑完也能导出）。

2. **生成并打开工程**：

   ```sh
   brew install xcodegen   # 只需一次
   xcodegen generate
   open EidolonIOS.xcodeproj
   ```

   构建时 `tools/sync_stand_runtime.sh` 从上游 checkout（默认 `../eidolon-sc`，可用 `EIDOLON_UPSTREAM` 指定）把 `spine-webgl.js` 拷进 App 资源。运行时是第三方代码，不进仓库；没有 checkout 或运行时缺失时脚本只打印一条警告，App 照常编译，只是立绘显示「没有立绘」。

3. 选一个 iPhone 模拟器运行，首次启动点「选择内容包」导入；然后在设置里填对话模型、向量化/重排，以及通话用的 Soniox 与 Fish Audio 密钥（密钥存钥匙串）。

4. 通话：在角色聊天页右上角点电话按钮（模拟器第一次用麦克风时，Mac 会要求给 **Simulator** 麦克风权限：系统设置 → 隐私与安全性 → 麦克风；另外确认 Simulator 菜单 I/O → Audio Input 选的是内置麦克风而不是 None）。接通是静默的——她不会先说话；对着麦克风说一句（中文或日文都行，识别同时提示 zh/ja，她用日语回答并配中文字幕），停一下等句末判定，她就按回合回答。首次通话会请求麦克风权限。设置里的「通话」一节：Soniox 密钥与识别模型（默认 `stt-rt-v5`）、Fish Audio 密钥与语音模型（默认免费档 `s2.1-pro-free`；只有 `drama-3` 会读朗读标记）。没有 Fish 密钥时她的话只显示字幕，通话流程不变。

### 判断模型

设置 →「判断模型」里四选一（ADR-0016）。每家各存一份密钥，换服务不会读到别家的密钥。

- **阿里云百炼**（默认）：业务空间 ID、地域（北京 / 新加坡）、百炼密钥；模型默认 `decision-model-preview`。地址由业务空间 ID 和地域拼出，按 decision-model 的阈值读概率。
- **Jev**：接口地址（默认 `https://openrouter.ai/api/v1`，用它加 `/systemone`）、模型名（默认 `typesafe/jev-1.13`）、密钥。OpenRouter、Vercel AI Gateway 或 TypeSafe 自己的地址都可以，只要提供 `/systemone`。
- **Cloudflare**：账号 ID、模型名（`clef` 或 `clef-flash`）、Workers AI 的 API token。地址按账号 ID 与模型名拼出，请求体里只写裸模型名；`clef` 和 `clef-flash` 各用自己那一行阈值，每天免费 1 万 neurons。
- **对话模型（JSON）**：用对话模型自己再判一次，读它的 JSON 回答；地址、模型名和密钥留空时沿用对话模型的设置。

模型名不属于 jev / clef / clef-flash / decision-model 任何一族（没有校准）时，按 jev 的阈值算，设置页与回合追踪里会写明「这个模型没有校准，按 Jev 的阈值算」。

「测试判断模型」用屏幕上当前的配置发一次只含一道是非题的请求：成功显示服务、模型与阈值族；失败分开说清业务空间 / 地域不匹配、密钥无效、模型名不对、账号不对、当天额度用完，其余原样显示服务返回的错误。测试不保存配置，改完记得点「保存」。

从旧版本升级时，如果以前已经把「对话模型」判断的地址、模型或密钥填过，第一次打开会继续用它，不会默认切到百炼。

## 测试

```sh
swift test --package-path EidolonCore
```

`swift test` 不联网。真实内容包冒烟测试需要环境变量开启。

模拟器里的调试验证可以用环境变量（仅 DEBUG 构建）注入识别与操作：

- `EIDOLON_CALL_FAKE_SPEECH='一行|另一行'`：不打开麦克风，按行注入识别结果（用 `|` 分隔多行）
- `EIDOLON_CALL_SPEECH_INTERVAL_MS`：注入的句子按间隔重复，用来排练长通话
- `EIDOLON_CALL_DROP_ONCE=1`、`EIDOLON_CALL_RECONNECT_MS`：让首次识别连接断开、放慢重连
- `EIDOLON_CALL_HANGUP_MS`：到点自动挂断
- `EIDOLON_OPEN_CHARACTER` / `EIDOLON_OPEN_CALL=1`：直接打开某角色的聊天并发起通话
- `EIDOLON_OPEN_STAND_PREVIEW=1`：直接打开设置里的立绘预览（她站在深色背景上待机）
- `EIDOLON_BAILIAN_WORKSPACE` / `_REGION` / `_MODEL` / `_API_KEY`：预置百炼判断配置，其余设置不动；真机也能用 `xcrun devicectl device process launch --environment-variables` 传入

这些值和真实密钥一样只用于本地验证，不要提交。

## 上游对照

```sh
tools/oracle/run.sh
```

同一场景分别交给上游 Python 引擎和 `EidolonCore` 组装提示词，逐字比较，指出第一个差异的位置与上下文（ADR-0012）。需要上游 checkout 和从它导出的内容包。
