## Agent skills

### Issue tracker

Issues live in GitHub Issues for this public repo. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## 项目背景

上游是 [Sallyn0225/eidolon-sc](https://github.com/Sallyn0225/eidolon-sc)：FastAPI + Pipecat 后端、Next.js 前端，AGPL-3.0。它是本仓库的参考实现和离线数据准备工具；本仓库不运行它。

本仓库是自用的 iOS 原生实验客户端，不打算上架。目标形态是**手机独立运行**：

- 最终数据、剧情索引、对话引擎、记忆都在 iPhone 上，不依赖 FastAPI / Next.js / WebRTC。手机直连对话 LLM、Fish Audio TTS、Soniox 或百炼 STT、硅基流动 embedding/rerank、判断模型、NovelAI。
- 剧情同步和 embedding 在 Mac 上用上游的 Python 工具跑，产出 SQLite/索引后导入手机；手机运行时不需要 Python。
- `EidolonCore/` 是端上引擎（内容包、回合、判断、检索、记忆、搭话、标题、追踪、通话状态机、立绘指令、酒吧、日程、周期），`EidolonIOS/` 是 SwiftUI 客户端。
- 现状以 `README.md`「现状与边界」为准：文字对话、通话、照片、朋友圈、立绘/换衣装、记忆/检索、搭话、酒吧、礼物/抽奖/成就、日历/周期、统计/用量都已接上；还没做的是通话打断、每日任务、数据包，以及一次 5 分钟以上的真机长通话验收（#18）。

## 当前方向（2026-11-09）

调研完成、**尚未实现**，不要当成已落地设计：

- 组件化 / 多运行时 / 多企划：见 `docs/research/componentization-2026-11-09.md`、`migration-template-2026-11-09.md`、`extension-points-and-platforms-2026-11-09.md`、`cross-franchise-model-2026-11-09.md`；阶段与验收见 `docs/roadmap.md`。
- 3D 立绘：本地分支 `feat/mltd-3d-stand`（Unity as a Library），**未合入 main**；先补 main 契约，再按 roadmap M1 迁入。另外两个 worktree：`spike/mltd-3d-static` 是资产管线。
- iPad / macOS：未开始。iPad 先做；macOS 先用 Xcode My Mac / Designed for iPad 冒烟，不承诺 Unity/UE。

## 硬约束

- 本地验证用的密钥只从 `../eidolon-sc/.env` 读取，不写进仓库、提交或 issue；App 运行时密钥存钥匙串。
- 上游 checkout 只读；`tools/oracle/run.sh` 六个场景必须与上游 `identical`；`swift test --package-path EidolonCore` 平时不联网。
- 仓库是公开的：不写主机名、内网地址、个人邮箱、设备 UDID、任何密钥；部署目标放 `tools/deploy.env`（已 ignore）。
- 新增 Swift 文件后跑 `xcodegen generate`；Xcode 会把 `EidolonIOS.xcodeproj/xcshareddata/xcschemes/EidolonIOS.xcscheme` 回写成旧格式，提交前还原。
- Spine 运行时、立绘、酒吧素材、3D 资产都不进仓库；由构建脚本或内容包在用户本机生成/导入。


## GitHub 写操作

- 本仓库的写操作目标只有一个：`JackLin513/eidolon-sc-ios`。所有会写 GitHub 的 `gh` 命令（`issue` / `pr` 的 create、edit、comment、close、reopen、merge，以及 `gh api` 的 POST/PATCH/PUT/DELETE）必须显式带 `-R JackLin513/eidolon-sc-ios`，不要依赖当前目录推断。
- `upstream`（`Sallyn0225/eidolon-sc`）和 `archive` 只读；这两个 remote 的 push URL 已设为 `DISABLED`，不要改回，也不要对它们创建/修改 issue、PR 或评论。
- 执行写操作前先跑 `gh repo view --json nameWithOwner -q .nameWithOwner`，输出必须是 `JackLin513/eidolon-sc-ios`；不一致就停下。

## 已经讨论过的取舍

- 把除对话 LLM 以外的模型全部搬到端上代价很大（TTS 音色、生图质量），所以允许手机直连多个模型 API。
- TTS 音色是端上化最大的降级点：全本地只能用系统语音或自训练音色；当前仍用 Fish Audio。
- App 本身不做登录、OAuth、多用户和后台，密钥存 Keychain。唯一的服务端是 `server/`（可选、自托管，只管「包从哪来」和「公告在哪看」）；不连它 App 照旧能用。
- 3D 与 Spine 是替代关系，不是叠加；Unity UaaL 只支持 iOS/Android，没有 macOS/Catalyst 路径；UE 没有官方嵌入路径。

领域词汇见 `GLOSSARY.md`（从上游复制）；架构决策写在 `docs/adr/`，由 `/grill-with-docs` 逐步产生。
