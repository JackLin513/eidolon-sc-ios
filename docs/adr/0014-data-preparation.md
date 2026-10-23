# 数据准备与导出

剧情库由上游生成：配置好对话模型与 `SILICONFLOW_API_KEY`，把 SCTranslationData 克隆到 `corpus/`，跑 `eidolon story sync` 和 `eidolon reembed`（首次全量约一到两小时）。本仓库 `tools/` 下的脚本读上游的 `data/eidolon.db` 和 `characters/`，产出内容包。第一次先用 `--idol 1` 跑通同步 → 导出 → 导入 → 对话，再全量同步。

**后果**：上游每次更新剧情都要重跑这条链；导出脚本要跟上游 schema 一起维护。
