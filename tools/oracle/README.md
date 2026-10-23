# 上游对照（oracle）

同一份场景分别交给上游 Python 引擎和 `EidolonCore` 组装提示词，逐字比较（ADR-0012）。
它是之后改提示词的回归闸门：任何一个字不同都会指出第一个差异的位置和上下文。

```sh
tools/oracle/run.sh
# 输出相同：identical: 6 messages, 13824 characters（退出码 0）
# 有差异：first difference in message 4 (system) + 行号、列号与两侧上下文（退出码 1）
```

- 场景在 `scenario.json`：角色、时区、历史回合、当前消息、两个固定时刻。
- 上游脚本 `upstream_prompt.py` 用真的 `ConversationEngine`，替身回复、替身时钟、不开检索与记忆。
- 端上脚本是 SPM 可执行目标 `prompt-oracle`（`EidolonCore/Sources/PromptOracle`），用假回复和固定时钟，也不开检索。
- 两边都不调用真实模型，可以重复运行。
- 前提：`UPSTREAM` 指向上游 checkout，且 `BUNDLE` 是从那份 checkout 的数据导出的内容包（`tools/export_content_bundle.py`）。
