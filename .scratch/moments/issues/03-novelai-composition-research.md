# 03: 调研：NovelAI 非自拍构图和多角色

Type: research
Status: open
Blocked by: none

## Question

现在的照片提示词把「只拍她本人、多半是自拍」写死了（`backend/src/eidolon/photo_prompt.py`：`1girl, solo`、拍法只有 `selfie`/`other`、别人拍时补 `looking at viewer`）。配图要能拍风景、物品和食物、别人给她拍的、和其他偶像的合照。要查清楚：

- **成熟的提示词指南**：NovelAI（V4.5 / V5）以及 Danbooru tag 体系下，写风景、静物、食物、「朋友圈随手拍」风格的提示词有哪些可信的指南、仓库、网站（官方文档、NovelAI 官方博客和 Discord 整理、知名的 tag 指南仓库）。哪些 tag 决定构图（`no humans`、`scenery`、`still life`、`food focus`、`from behind`、`candid` 之类），哪些会和我们的画风插槽（`0.7::artist:rella::`）冲突。
- **他拍而不是自拍**：怎么让画面像朋友帮她拍的生活照，而不是摆拍立绘；`looking at viewer` 什么时候该去掉。
- **多角色**：V4 以后的多角色提示框（`v4_prompt.caption.char_captions` 加 `use_coords`）在 V4.5 和 V5 上的官方说明和社区实测效果：两三个人时外貌串不串、人数准不准、要不要给坐标。V5 Curated 支不支持；中转（OpenAI images 形态）会不会把这个字段吞掉。
- **人数上限和失败形态**：三人以上是否明显崩，常见的失败（多一个人、脸串了、手）。
- 起点：远端分支 `research/novelai-prompting` 上的 `.scratch/photos/research/novelai-prompting.md`（只实测了自拍，5.4 节提过 `char_captions`），以及 `.scratch/photos/issues/04`、`05`、`11` 的结论。
- 结论给出：建议的构图枚举、每种构图的固定前后缀草案、合照值不值得进 v1，以及原型实测要测哪几组（为「原型：配图实测」准备）。
