# ADR-0040：内容包提供用户身份与称呼（提示词层）

日期：2026-11-13
状态：已接受

## 背景

文字对话的系统提示词长期假定用户是闪耀色彩（SC）的制作人：
`ProducerProfile` 固定注入「# 制作人」和「制作人是男性，和原作一致。」，
`FranchisePrompt` 的内置 `.totsulover` 也写着「制作人」，
`WorldSetting` 是事务所/偶像结构，`Judge`、`Retrieval`、`BarPrompt`、`Moments` 等模块还散落着「制作人」字样。
导入 Dimension Lover（totsulover）后，夜乃桜会把用户叫作「制作人」，并混入 283 事务所、偶像、学园等 SC 概念。

本仓库的 `ADR-0036` 把复合用户身份与跨包隔离留给 Phase B（`ADR-0037`）；
但提示词层可以在不改数据库身份键的前提下先与内容包对齐。

## 决定

1. `FranchisePrompt` 增加可选字段：`protagonistTerm`、`userSection`、`adultBoundary`、`worldPrompt`、
   `vocabulary`（JSON：`protagonist_term`、`user_section`、`adult_boundary`、`world_prompt`、`vocabulary`）。
   全部可缺省，`.shiny` 保持字节级不变。
2. `FranchisePromptContext.localize(_:)` 按最长键优先替换词汇。所有拼系统提示词的入口都经过它，
   包括 `PromptAssembler`、判断、判断题、记忆、标题、检索、酒吧、朋友圈。
3. 第二个 system message 从固定 `producer.prompt` 改为 `franchise.userSection ?? localized(producer.prompt)`。
   totsulover 的 `userSection` 直接描述原作男主崩月槐，并按角色列出原作称呼：
   夜乃桜/ソフィア「槐くん」、海漫華淡「槐さん」、崩月水仙「槐お兄ちゃん」。
4. 成人边界句从基础人设移到 `adultBoundary`，只在成人模式关闭时注入；SC 不定义该字段，行为不变。
5. 非 shiny 包在设置页隐藏「制作人资料」和系统日历导出；该分类改名为「你的资料」，
   周期、搭话等角色侧设置仍保留。
6. totsulover 内容包重新生成（v5）：`characters/franchise.json`、角色 sheet/fact、世界设定、
   `episode_lines.speaker` 都改为「槐」；旧包保留在 `previous`。

## 后果

- 同一套运行时可以支持不同企划的用户身份；提示词不再假定 SC 的制作人制度。
- `.shiny` 的提示词、golden、上游 oracle 不受影响；`ADR-0004` 的字节一致性仍然成立。
- 内容包仍是唯一身份来源；改称呼不需要改 Swift 代码，重新打包即可。
- 本 ADR 只处理提示词与显示层，不改 `conversations`/`messages`/`memories` 的裸 id 语义；
  跨包隔离仍按 `ADR-0036`/`ADR-0037` 的 Phase B 推进。

## 考虑过的选项

- **在 Swift 里按 franchise 硬编码称呼**：改一次要发版，且外部包无法自带身份。
- **只改 debug 显示**：会留下实际请求里的污染，用户看到的回复仍然错。
- **把「男主角」当通用称呼**：失去原作称呼的代入感，且不同女主称呼不同。
- **强制所有包使用「你」**：第二人称在系统提示词里会与「和你对话的人」混淆，也丢失角色关系。
