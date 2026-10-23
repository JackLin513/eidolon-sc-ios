# 判断模型改为 chat 模型加结构化 JSON

上游的判断走专用协议 `POST /systemone`（Jev / Cloudflare / 百炼的 decision model）。端上不复刻这个协议，改用任意 OpenAI 兼容的便宜 chat 模型：把上游 `judge.py` / `affinity_judge.py` 的问题描述移植成 prompt，要求输出固定结构的 JSON。`Judge` 抽成协议，将来可以加专用 provider；判断失败按上游的 advisory 语义降级。

**考虑过的选项**：百炼 `decision-model-preview`（国内直连，但账号与可用性未知）；OpenRouter 的 Jev（要走代理）；端上规则（会毁掉好感度的手感）。
