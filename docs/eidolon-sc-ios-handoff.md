# Eidolon-SC iOS 交接文档

生成于 2026-10-27。写给一个全新上下文的 agent：读完这份就能接着干，不用回看旧对话。

## 0. 三十秒版本

- 仓库：`~/Developer/IdeaProjects/eidolon-sc-ios`（GitHub `JackLin513/eidolon-sc-ios`，私有，AGPL-3.0，自用不上架）。
- 上游参考实现：`~/Developer/IdeaProjects/eidolon-sc`（Sallyn0225/eidolon-sc，FastAPI + Pipecat + Next.js）。**上游 checkout 只读**，只作参考和离线数据准备，App 运行时不依赖它。
- 形态：手机独立运行的 iOS 原生客户端。剧情索引、对话引擎、记忆、好感、立绘、通话状态机都在端上；运行时只直连外部模型 API（对话 LLM、判断模型、embedding/rerank、Soniox STT、Fish Audio TTS）。
- 唯一分支 `main`，默认分支也是它。交接时 tip = `47a455e`（README 的两处状态修正）。
- 已验证绿：`swift test --package-path EidolonCore` 404 tests / 1 skipped / 0 failures；oracle 六场景全部 `identical`；iOS 模拟器与真机构建都 `BUILD SUCCEEDED`，新包已装到 iPhone Air。
- 唯一未完成的验收：**#18**，一次 5 分钟以上的真机长通话，需要用户的耳朵，**不许替跑或伪造结论**。

## 1. 先读什么（不要读全文，按需）

| 想知道 | 去哪里 |
| --- | --- |
| 项目能力、结构、怎么跑、调试注入开关 | `README.md`（「现在能做什么」「还没做 / 已知」「结构」「跑起来」「测试」） |
| 硬约束与领域背景 | `CLAUDE.md`（项目背景、已讨论过的取舍、密钥红线） |
| 领域词汇 | `GLOSSARY.md`（从上游复制；端上新增「台词卡」等条目） |
| 为什么这样做 | `docs/adr/0001–0020` |
| issue / 标签 / 领域文档约定 | `docs/agents/issue-tracker.md`、`triage-labels.md`、`domain.md` |
| issue 历史 | GitHub Issues（见下「时间线」） |

核心硬约束，来自 ADR-0004 / 0012：**对话引擎与提示词逐字复刻上游**。改任何提示词后必须跑 `tools/oracle/run.sh`，六个场景全部 `identical` 才算过。oracle 不覆盖事件/搭话旁白，那部分靠 `TurnTests` 里的逐字断言。

密钥红线：本地验证用的密钥**只从 `../eidolon-sc/.env` 读取**，不写进仓库、不提交、不写进 issue；App 运行时密钥存 Keychain。Spine 运行时与立绘素材有第三方版权，**都不进仓库**（`build/` 已忽略，运行时由构建脚本从上游 checkout 同步）。

## 2. 时间线（issue 即索引）

- **里程碑 1：文字对话** — spec #1（保持开启，别关）；ticket #2–#11 全部关闭。
- **里程碑 2：通话 MVP** — spec #12（保持开启）；ticket #13–#17 关闭；**#18 开着的验收项**（`ready-for-human`）。
- **对齐上游第一批** — spec #19（保持开启）；#20–#27 关闭（生日/今天、搭话措辞、好感权重、她挂断、通话上限、System One、Jev/Cloudflare）。
- **角色立绘** — spec #28（保持开启）；#29–#34 关闭（素材进内容包、Spine 播放器、情绪/嘴型/点头、通话页布局、换衣装）。ADR-0017 / 0018。
- **图标** — Icon Composer 工程 `AppIcon.icon`（commit `e66b83c`..`9b82d96`），资产目录里的旧 AppIcon 已删（同名冲突）。
- **对齐与修复第二批** — #35 汇总审查发现的 52 条问题（**仍开着**，作为复核清单），#36 拆成 #37–#42 在集成分支 `align/35-36` 实现，两轴 code review 的问题一次修在 `4bfa41b`；#37–#42 与 #36 均已关闭并带证据评论。
- **分支收敛（2026-10-27）** — 原先 `main` → `call-mvp` → `stand` 是一条直线，已把 `main` 快进到 `4bfa41b` 并删除远端与本地 `call-mvp`、`stand`、`align/35-36`。现在只有 `main`。
- **README 修正** — `47a455e`：对齐状态改为已完成，ADR 范围改到 0019。

## 3. 代码地图

`EidolonCore/`（SPM 包，GRDB + ZIPFoundation，`swift test` 不联网）

- 回合与提示词：`EidolonTurn.swift`（回合执行、旁白拼接、`PromptRecord`、`chatHistory`）、`PromptAssembler` 相关文件、`TodayPrompt.swift`、`WorldSetting.swift`、`ReplyParser.swift`
- 判断：`SystemOne` 相关 + `JudgeProvider` 接缝（ADR-0016）
- 检索：`Retrieval.swift`、`RetrievalStore.swift`、`Embedding.swift`
- 记忆：`Memory.swift`（提取、取代、删除/清空、队列补跑）
- 搭话 / 标题 / 事件：`ReachOut.swift`、`Title.swift`、`ConversationEventKind.swift`、`Conversation.swift`
- 通话状态机：`CallSession.swift`（音频与语音服务注入，ADR-0015）、`CallClock.swift`、`SonioxKeepalive.swift`、`SonioxTranscript.swift`、`CallHotWords.swift`、`Readings.swift`、`FishSynthesisError.swift`、`CueFilter.swift`、`DurationSeconds.swift`
- 内容包：`ContentBundleInstaller.swift`、`ContentManifest.swift`、`OutfitThumbnails.swift`、`StandOutfits.swift`
- 存储：`UserSchema.swift`（当前 v7）、`Eidolon.swift`
- 对照与追踪：`Sources/PromptOracle`、回合追踪相关

`EidolonIOS/`（SwiftUI，xcodegen 生成工程，改文件后跑 `xcodegen generate`）

- `App/`：入口、`AppModel.swift`
- `Core/Call/`：`SonioxRecognition.swift`、`MicrophoneCapture.swift`、`FishSynthesis.swift`、`SpeechPlayback.swift`、`DebugRecognition.swift`
- `Features/`：`Chat`、`Call`、`Stand`（`StandWebRenderer`、`StandThumbnails`、`OutfitPickerView`）、`Settings`、`Memories`、`Traces`、`Conversations`、`Import`

`tools/`：`export_content_bundle.py`（Mac 上导出 `.eidolonpkg`）、`sync_stand_runtime.sh`（构建时取 Spine 运行时）、`oracle/run.sh`、`tests/`。

已知的结构性取舍（code review 时判过、这次故意没动）：`contentVersion` 穿四层视图签名、`CallSession` 里直接写 SQL、`LoadWaiter` 放在 Core。

## 4. 验证与常用命令

```sh
swift test --package-path EidolonCore            # 404 tests, 1 skipped（交接时）
python3 -m unittest discover -s tools/tests      # 导出工具
BUNDLE=$PWD/build/eidolon-content.eidolonpkg \
  UPSTREAM=$HOME/Developer/IdeaProjects/eidolon-sc tools/oracle/run.sh   # 六场景必须全 identical
xcodebuild -project EidolonIOS.xcodeproj -scheme EidolonIOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

真机（iPhone Air，`com.jacklin.eidolon`）：

```sh
xcodebuild -project EidolonIOS.xcodeproj -scheme EidolonIOS -configuration Debug \
  -destination 'id=<UDID>' -derivedDataPath build/dd \
  DEVELOPMENT_TEAM=FF7NMQWZKK -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> --timeout 120 \
  build/dd/Build/Products/Debug-iphoneos/Eidolon.app
xcrun devicectl device process launch --device <UDID> com.jacklin.eidolon
```

内容包导入：`devicectl device copy to --domain-type appDataContainer --domain-identifier com.jacklin.eidolon --destination Documents/<包名>.eidolonpkg`，再以 `-e '{"EIDOLON_IMPORT_BUNDLE":"<包名>"}'` 启动。设备上现已有一份导入好的内容包（含 `stand/` 立绘素材）。

## 5. 未完成与坑

未完成：

- **#18** 长通话验收：人的听感，不能自动下结论。升级后第一次启动会跑 `UserSchema` v7 迁移（清理旧 `hung_up` / `call_*` 事件、`she_hung_up` → `hung_up`），建议先开一次 App 看历史是否正常。
- 父 spec #1 / #12 / #19 / #28 按约定保持开启；#35 保持开启留作复核清单。**不要改 #35 正文、不要关这些父 issue。**
- 通话 barge-in（她说话时打断）未做：麦克风在她说话期间合上；要先把播放并进同一个 `AVAudioEngine`（voice processing）。
- 日程与生理周期明确范围外（README「还没做 / 已知」）。照片、礼物、每日任务、成就、统计、数据包、酒吧同样范围外。

踩过的坑：

- **`| tail` 会吞掉构建失败**：`xcodebuild ... | tail` 的退出码是 `tail` 的 0。曾经因此把 `build/dd` 里 10月25 的旧产物装到真机，看起来像「远古版本」。看日志里的 `BUILD SUCCEEDED/FAILED`，别只看退出码。
- **签名**：工程里的 team `MFZ8WGP52J` 在这台机器上没有账号；唯一有效开发证书与 profile 属于 team `FF7NMQWZKK`，真机构建必须带 `DEVELOPMENT_TEAM=FF7NMQWZKK -allowProvisioningUpdates`。该 profile **2026-11-01 到期**，过期后要重新生成或登录账号。
- macOS 没有 `timeout` 命令；`devicectl` 偶发 `-402653181`，用 `--timeout` + 重试循环。
- `devicectl install` 成功不代表装的是新包，装完核对产物时间戳/大小。
- SourceKit 报 `No such module 'EidolonCore'` / `'XCTest'` 是索引问题，不代表编译失败，以 xcodebuild 为准。
- worktree 曾在仓库同级目录（`../eidolon-sc-ios-align-NN`），因为 oracle 要解析 `../eidolon-sc`；用完已清理。
- 时间戳用整数微秒（`EidolonTurn` 里 `timestamp(microseconds:)`），别退回 `Date + 1µs`，会舍入到同一微秒。
- 搭话在 22:00–08:00 不触发，写测试时别选凌晨。

## 6. 工作流约定

- issue 在 GitHub，读写用 `gh`；标签词表 `needs-triage / needs-info / ready-for-agent / ready-for-human / wontfix`。`/to-tickets` 产出的 ticket 不需要再 triage。
- 提交：中文 conventional commit；末尾加
  `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`。
- 每个 ticket 验证通过后主动提交，不等用户开口；推送只在用户要求或收尾时做。
- 改动提示词 → oracle 必须仍全 `identical`；改动 schema → 加迁移并补迁移测试。
- 多 ticket 并行时用「worktree + 集成分支」（这次是 `align/35-36`），完成后清理 worktree；现在没有集成分支，新工作从 `main` 开分支。

## 7. 建议技能

用 Skill 工具按需调用：

- **实现单个 ticket / 小功能**：`/tdd`（红-绿-重构，只测外部行为）。
- **实现整份 spec**：`/implement-spec`（任务图 + 前沿并行 + 集成分支 + 收尾 code-review）。
- **单个 issue 实现**：`/implement`。
- **分支/PR 收尾**：`/code-review`（固定点用 merge-base 或指定 commit，双轴：规范 + 规格）。这次就是这么做的。
- **间歇性/难复现的 bug**：`/diagnosing-bugs`。
- **改术语、写 ADR**：`/grill-with-docs`（内含 `domain-modeling`）。
- **新大功能从想法到可交付**：`/grill-with-docs` → `/to-spec` → `/to-tickets` → `/implement-spec`。
- **会话结束回顾环境改进**：`/retro`。
- **再次交接**：`/handoff`。

## 8. 敏感信息

本文不含密钥。所有 API 密钥、模型服务凭据只存在于两处：`../eidolon-sc/.env`（本地验证用）与 App 的 Keychain。设备 UDID 等标识也故意略去；需要时用 `xcrun devicectl list devices` 现查。
