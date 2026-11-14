# ADR-0037：多企划复合身份与数据隔离（S3 Phase B）

日期：2026-11-14
状态：已接受

## 背景

ADR-0036 把多内容包拆成 Phase A（包根、kind 路由、`CharacterKey` 边界）和 Phase B（复合用户身份、跨包隔离、删除/恢复、检索作用域）。Phase A 已经完成：内容包可以并存、切换，`CharacterKey = "<franchise>:<localID>"` 也已经定义并在测试里使用。但 Phase B 一直没有落地：

- 用户库仍是单 active franchise 的裸 `character_id` 语义；`affinities`、`current_conversations`、`cycle_seeds`、`achievement_progress`、`achievement_stages` 等表直接按裸 id 存。
- `currentConversationID` 按裸 `character_id` 接续；两个企划如果有相同 local id，会续到同一个会话。
- 朋友圈、统计、日程、礼物、酒吧、记忆、debug snapshot、turn trace 等仍有全局或按裸 id 聚合的路径。
- 删除内容包没有正式 API/UI；旁挂资源（Spine/静态立绘/3D）只按 active 包工作，删除/重导入没有明确语义。
- model3d 是全局单槽，未来多个企划都用 Unity3D 时无法并存。
- `UserSchema.version = 24` 已被 `turn_debug_snapshots` 占用；Phase B 的目标版本是 **v25**。
- 全量审计见 `docs/research/s3-phaseb-gap-audit-2026-11-14.md`：39 张用户表里，15 张直接裸字符键、11 张经 conversation/message/post 间接归属、13 张全局单例。

继续在 v24 上逐表打补丁，会让 S4 的多角色同屏、跨企划场景再次迁移；而旧库的数据迁移本身没有用户价值——这是自用单机客户端，内容包和用户进度都可以重建。

## 决定

### 1. v25 是复合身份的完整 schema，不写旧数据迁移

- 用户库升级到 v25，一次包含所有角色域/企划域表、`conversation_participants`、`messages.speaker_kind`/`speaker_franchise`/`speaker_character`。
- 旧库不迁移：`user_version < 25` 时先备份，再重建为空 v25 库。旧聊天、好感、成就等不搬运。
- 只有 `user_version < 25` 才允许自动重置；已经是 v25 但打开/迁移失败时直接报错，**不删库**。
- 备份名为 `eidolon.sqlite.bak-<时间戳>`，最多保留最近 3 份。
- 重置只动用户库，不动已安装的 content/stand/static-stand/model3d 包。

### 2. `CharacterKey` 是生产身份，API 显式接收作用域

- 允许不同 franchise 使用相同 local id；运行时身份是 `CharacterKey(franchise:localID:)`。
- core 的用户数据 API 显式接收 franchise 或 `CharacterKey`；不提供“默认读全局 active franchise”的隐式重载。
- UI 从 active content bundle 构造 scope，不自行按裸 id 过滤。
- 内容包 manifest 的 `franchise` 是唯一作品身份来源；不按设备、语言或角色 id 猜测。
- 会话参与者新增 `conversation_participants`（conversation、franchise、character、role、joined_at）；消息用 `speaker_kind` + `speaker_franchise` + `speaker_character` 表达“谁说的”，用户发言不塞假 character id。

### 3. 游戏状态按 franchise 拆，API/UI 设置保持全局

- 角色域状态：好感、当前会话、周期种子、成就进度/阶段、记忆、debug snapshot、turn trace 等全部带 franchise/CharacterKey。
- 企划域单例：制作人资料、礼物/抽奖、周期设置、朋友圈状态、成就启动状态、日程周池、酒吧状态、保存的摆放等按 franchise 拆。
- 角色偏好（置顶/隐藏、衣装、静态外观、roster 选择）在 UserDefaults 中也按 franchise 命名空间；禁止裸 character id。
- API base URL、模型、密钥、界面偏好保持全局，不按企划重复填写。
- 记忆全局存，但每条带 `source_franchise_id`；默认只注入当前企划，跨企划检索不默认开放。

### 4. 旁挂资源按 franchise 分槽，生命周期跟随内容包

- content 包根仍为 `Content/<franchise>/current`；活动包通过相对 symlink 切换。
- static-stand、model3d 也按 franchise 分槽，各有 active/previous 或 bundle 键；不允许全局单槽。
- 删除 content 包时，同时删除该 franchise 的 content、static-stand、model3d；用户数据保留为孤儿。
- 重新导入 content 后，用户数据自动可见；资源需要重新导入；缺失时 UI 明确提示并回退 avatar/2D。
- 3D：每个 franchise 最多一个 active 包 + 一个 previous；切换时只加载当前 active franchise，Unity UaaL 单实例可以卸载/重建；失败回退 2D/静态/avatar；不借用别的企划 3D。
- MLTD 在 S3 只做架构验证：用合成 mltd/shiny 包验证多槽互不覆盖、切包读对；真实 MLTD content/3D 素材与视觉/性能验收归 #142。

### 5. 切包与聚合语义

- 切包回该企划首页并关闭当前聊天；旧会话保留，切回可见。
- 用户可见聚合页（朋友圈、统计、日程、礼物、酒吧等）按当前企划过滤；跨企划聚合视图后置。
- 内容包管理 UI 显示当前包、旁挂资源可用/缺失、删除与重导入入口。
- S2.4 Duo 的界面适配不属于本 ADR。

### 6. 实施顺序与测试锚点

1. 第一个 PR：本 ADR + 一个会失败的“同 local id 隔离”测试，固定验收锚点。
2. 第二个 PR：v25 schema + 硬重置 + 复合身份 API。
3. 后续：记忆/检索作用域、删包/重导入、3D 多槽、包管理 UI、MLTD 合成包验证。

测试只验证外部行为：临时数据库、公开的 `Eidolon`/store API、内容包 registry。覆盖同 local id 隔离、v25 硬重置/备份、当前版本故障不删库、删包/重导入、3D 多槽、聚合过滤；不写 v24→v25 数据迁移测试。

## 后果

- 旧用户库会被一次性删除（保留备份），这是明确的取舍；不承担迁移代码与迁移失败风险。
- 所有裸 `character_id` 调用点都要改成显式 `CharacterKey`/franchise；改动面大，但 S4 不需要再迁一次身份。
- 两个企划可以安全使用相同 local id；切包不会串会话、好感、成就、记忆或聚合数据。
- 删除内容包会同时删除该企划资源；重导入 content 恢复用户数据，但立绘/3D 需要重新导入。这是“卸载该企划”的一致语义。
- 3D 多槽让未来多个 Unity3D 企划可以并存；Unity runtime 仍是单实例，切换时需要卸载/重建，失败回退 2D。
- 旧库 `user_version = 24` 不会再被 Phase B 使用；`turn_debug_snapshots` 的 v24 迁移保持不变。
- 测试会在 schema/API 改动前先红；实现完成后同一个隔离测试转绿，作为 S3 Phase B 的验收锚点。

## 考虑过的选项

- **只加 `franchise_id` 列，API 继续裸 id，靠调用方保证**：改动小，但每个调用点都可能漏；后台任务/切包竞态无法防。否决。
- **core 内部用全局 active franchise 自动过滤**：UI 简单，但后台任务在切包后会读到新企划；隐式上下文正是当前 bug 的来源。否决。
- **保留 v24→v25 数据迁移**：能保留旧聊天，但需要为 39 张表写映射、处理同 id 冲突和回滚；自用客户端没有这个价值。否决。
- **保留全局 3D 单槽**：与“多企划都使用 Unity3D”的目标冲突。否决。
- **API/UI 设置也按企划拆**：会让同一台设备重复填写 key/模型，没有收益。否决。
