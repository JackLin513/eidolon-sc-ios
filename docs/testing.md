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
