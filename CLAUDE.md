## Agent skills

### Issue tracker

Issues live in GitHub Issues for this private repo. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## 项目背景

上游是 [Sallyn0225/eidolon-sc](https://github.com/Sallyn0225/eidolon-sc)：FastAPI + Pipecat 后端、Next.js 前端，AGPL-3.0。它是本仓库的参考实现和离线数据准备工具；本仓库不运行它。

本仓库是自用的 iOS 原生实验客户端，不打算上架。目标形态是**手机独立运行**：

- 最终数据、剧情索引、对话引擎、记忆、礼物和统计都在 iPhone 上，不依赖 FastAPI / Next.js / WebRTC。
- 手机直接调用这些外部 API：对话 LLM、Fish Audio TTS、Soniox 或百炼 STT、硅基流动 embedding/rerank、判断模型、NovelAI。
- 剧情同步和 embedding 仍在 Mac 上用上游的 Python 工具跑，产出 SQLite/索引后导入手机；手机运行时不需要 Python。

`EidolonCore/` 是端上引擎（内容包、回合、判断、检索、记忆、搭话、标题、追踪、通话状态机），`EidolonIOS/` 是 SwiftUI 客户端。里程碑 1（文字对话）已完成；里程碑 2（通话 MVP：Soniox 实时识别 + Fish Audio 逐段语音）已实现并装到真机，剩一次 5 分钟以上的长通话验收（见 #18）。两者都不依赖后端；没有登录、OAuth、多用户和后台，外部服务的密钥存钥匙串。

本地验证用的密钥只从 `../eidolon-sc/.env` 读取，不要写进仓库、提交或 issue；上游 checkout 只读。改提示词后必须跑 `tools/oracle/run.sh`，三个场景都要与上游 `identical`；平时 `swift test --package-path EidolonCore` 不联网。模拟器调试用的注入开关见 README「测试」一节。

已经讨论过的取舍：

- 把除对话 LLM 以外的模型全部搬到端上代价很大（TTS 音色、生图质量），所以版本 1 允许手机直连多个模型 API。
- TTS 音色是端上化最大的降级点：全本地只能用系统语音或自训练音色；版本 1 仍用 Fish Audio。
- 首版范围：文字对话 + 通话 MVP。照片、礼物、每日任务、成就、统计、数据包先不做。
- 不做登录、OAuth、多用户和后台；密钥存 Keychain。

领域词汇见 `GLOSSARY.md`（从上游复制）；架构决策写在 `docs/adr/`，由 `/grill-with-docs` 逐步产生。
