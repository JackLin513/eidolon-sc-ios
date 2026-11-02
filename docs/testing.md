# 测试与调试

```sh
swift test --package-path EidolonCore       # 不联网
python3 -m unittest discover -s tools/tests  # 导出工具
tools/oracle/run.sh                          # 与上游逐字对照提示词（需要上游 checkout 与内容包）
```

真实内容包冒烟测试需要环境变量开启（`EIDOLON_TEST_BUNDLE`）。

模拟器与真机上的调试验证可以用环境变量（仅 DEBUG 构建）注入识别与操作：

- `EIDOLON_IMPORT_BUNDLE`：导入这个内容包（裸文件名会在 Documents 里找），真机也能用
- `EIDOLON_CHAT_BASE_URL` / `_MODEL` / `_API_KEY` / `_EXTRA_BODY`：预置对话模型，并顺带保存下面这些设置；只在传了 `EIDOLON_CHAT_API_KEY` 时生效
- `EIDOLON_ADULT_MODE=1`：单独预置成人模式开关，不依赖对话模型密钥（只对内容包中 18 岁及以上的角色生效）
- `EIDOLON_RETRIEVAL_BASE_URL` / `_API_KEY`、`EIDOLON_EMBEDDING_MODEL`、`EIDOLON_RERANK_MODEL`：预置检索、向量化与重排
- `EIDOLON_SONIOX_API_KEY` / `_MODEL`、`EIDOLON_FISH_API_KEY` / `_MODEL`：预置识别与配音
- `EIDOLON_CALL_FAKE_SPEECH='一行|另一行'`：不打开麦克风，按行注入识别结果
- `EIDOLON_CALL_SPEECH_INTERVAL_MS`：注入的句子按间隔重复，用来排练长通话
- `EIDOLON_CALL_DROP_ONCE=1`、`EIDOLON_CALL_RECONNECT_MS`：让首次识别连接断开、放慢重连
- `EIDOLON_CALL_HANGUP_MS`：到点自动挂断
- `EIDOLON_OPEN_CHARACTER` / `EIDOLON_OPEN_CALL=1`：直接打开某角色的聊天并发起通话
- `EIDOLON_SEND_TEXT='一句话'`：打开聊天后自动发一句
- `EIDOLON_REACH_OUT_HOURS`：把搭话间隔改短，方便看搭话
- `EIDOLON_NO_JUDGE=1`：不接判断模型，由对话模型自行决定是否调用「回顾剧情」
- `EIDOLON_OPEN_HISTORY` / `_TRACES` / `_LATEST_TRACE` / `_MEMORIES`：直接打开历史、追踪、最新追踪或记忆页
- `EIDOLON_IMPORT_STAND_BUNDLE`：导入这个立绘包（裸文件名会在 Documents 里找），真机也能用
- `EIDOLON_OPEN_STAND_PREVIEW=1`：启动时自动打开设置里的立绘预览（只自动进入一次；之后手动打开设置不会再自动跳转）
- `EIDOLON_OPEN_OUTFITS=1`：配合预览直接打开换衣装面板
- `EIDOLON_PREVIEW_WEAR=<outfit id>`：预览打开后直接换到这套衣装（回归检查用）
- `EIDOLON_BAILIAN_WORKSPACE` / `_REGION` / `_MODEL` / `_API_KEY`：预置百炼判断配置，其余设置不动；真机也能用 `xcrun devicectl device process launch --environment-variables` 传入

真机上这些变量用 `xcrun devicectl device process launch --environment-variables` 传入（键值写成 JSON）。

这些值和真实密钥一样只用于本地验证，不要提交。

## 调试模式（App 内）

设置页最后一节「调试」里有一个「调试模式」开关，默认关闭，所有构建都有。打开后，角色对话页的 `⋯` 菜单末尾出现「调试」，点开可以：

- **清除这段对话的记忆**：只列当前打开的那段对话产出的记忆，勾选后批量删除。记忆是跨角色共享的，删掉后所有偶像都不再想起。
- **修改好感度**：0–100 的滑杆，实时显示档位；「回到 50」复位。设到 0 会开始冷却，设到 0 以上会结束冷却。
- **恢复或切换对话**：已结束的当前对话可以恢复；历史对话可以设为当前（已结束的会同时解除结束）。调试模式下也可以直接在「对话记录」里右滑一段历史对话设为当前，不必打开它再进调试页。
- **保持对话**：打开「不因好感度下降而结束」后，这段对话不会因为冷却、两次越界或累计伤害而结束或挂断；好感度照常下降，只对这一条对话有效，新对话默认关闭。

写操作在她正在回复或通话进行中会禁用；删除记忆、恢复和切换对话都要确认。这些操作直接写本机用户库，不写对话事件、回合追踪、标题或统计，也不能撤销；平时请保持关闭。领域规则的例外和 schema v14 的当前对话指针见 `docs/adr/0026-debug-mode.md`。

