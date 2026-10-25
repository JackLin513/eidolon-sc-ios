# 05: 评测集：约 60 条 `[[considerate]]`

**What to build:** 体贴题有自己的评测集，维护者能看到它判得准不准，也能确认加了这道题后同一请求里其他题的结论没有变。`judge.toml` 新加一类 `[[considerate]]`，照 `[[photo]]` 一类的写法。每条带这些字段：
- `id`
- 阶段（经期 / 经前）
- 角色
- 上文
- 制作人这句话
- 期望的三档之一
- 期望的五档等级
- `note`
- `reviewed`

经前、经期各三档约 10 条，共约 60 条。要多放「这几天里正常聊天」的无关例子防误判。也要放几类不好判的：
- 她流露了不适，制作人却催她训练、硬约她出门（不体贴）
- 察觉到了并让她休息、问她要不要喝热的（体贴）
- 只说「早点睡」这类泛泛的关心（看上文判）
- 冒犯之后的体贴、操纵加体贴

角色挑性格不同的几位，至少有一位未满 18 岁。`judge_eval` 认这一类：按阶段带上票 04 的题面问，报三档准确率，并比较同一条上五档等级和期望的差别。条目由 agent 写初稿，`reviewed = false`，维护者过一遍。用现有的评测命令在本机配置的判断模型上跑一次，有明显的系统性误判（比如把平常聊天判成不体贴）时调票 04 的题面再跑，把前后的数写进 Comments。测试只验证评测集能读、每条字段齐全，不在测试里跑真实模型。见规格「判断：体贴题」和 Testing Decisions 的「评测集」。

**Blocked by:** 04

**Status:** done

- [x] 约 60 条 `[[considerate]]`：经前、经期 × 三档各约 10 条，无关的例子偏多，上面几类难判的都有，包括未满 18 岁的角色
- [x] `judge_eval` 认这一类，报三档准确率，以及五档等级和期望的差别
- [x] `test_judge_eval.py`：评测集能读，每条字段齐全，阶段和档的取值合法
- [x] 本机跑过一次评测，准确率和主要误判写进 Comments；调过题面的话前后都写
- [x] 条目的措辞守词汇表（不写生理期、PMS 之类）
- [x] pyright、ruff 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [x] 票收尾：推一次让 CI 跑、跑 `code-review`

## Comments

### 票 04 交接

- 题面在 `affinity_judge._CONSIDERATE_QUESTIONS`（经期、经前各一版），全文和答案的读法见票 04 的「实现说明」。请求里它排在原有三道题之后、照片题之前，键是 `affinity_judge.CONSIDERATE_QUESTION`（`"considerate"`）。
- 评测时问法：`affinity_judge.affinity_questions(days)`（`days` 是 `"period"` / `"premenstrual"`）或 `retrieval.judge_questions(affinity=True, days=...)`；读法：`affinity_judge.read_judged(answers, thresholds, days)`，体贴档在 `Judged.considerate`（0 / 1 / 2，常量 `affinity.INCONSIDERATE / UNRELATED / CONSIDERATE`）。
- 「其他题的结论没变」：拿同一条用 `days=None` 和 `days=...` 各问一次，比 `Judged.level`、`out_of_line`、`manipulation`。

### 实现说明（票 05）

- **评测集**：`backend/eval/judge.toml` 末尾 71 条 `[[considerate]]`，全部 `reviewed = false`，等维护者过一遍。字段：`days`（`period` / `premenstrual`）、`expected`（`inconsiderate` / `unrelated` / `considerate`）、`level`，可选 `out_of_line`、`manipulation`；格式和标注规则写在文件开头。分布：经期 11 / 15 / 10，经前 11 / 13 / 11（不体贴 / 无关 / 体贴）。18 位角色，未满 18 岁的有果穗（12）、あさひ（14）、灯织、真乃、円香、树里、日花、凛世、透、雏菜。
- 票里点名的难判几类都有：她流露了不适还被催训练（果穗、恋钟、あさひ……）、被硬约出门（咲耶、雏菜）；让她休息、问她要不要喝热的（果穗、恋钟）；「早点睡」两面都有，按上文判（灯织、摩美美算体贴，夏叶、真乃、日花算无关）；冒犯之后的体贴（树里、咲耶）；操纵加体贴（摩美美、结华，体贴题照判体贴，`manipulation = true`）；不该说的话两条（`level = 0`，体贴题判不体贴）。另放了三条防误判：她状态很好、制作人照常加练，期望无关。
- **`judge_eval`**：新类 `ConsiderateCase` / `ConsiderateResult`，`--only considerate`。每条问两次：先用 `judge_questions(affinity=True, days=...)` 问，和检索开着、她在这几天时一样；再用 `judge_questions(affinity=True)` 按平常日子问。汇总给三档准确率（总的、按阶段）、混淆矩阵、判错的 id；同一请求里好感度三道题和期望比（级、两道是非题各自的准确率）；两种问法下三道题的结论是否不变，变了的列出 id。`_choice` 统一校验只能取几个值的字段，`variant` 也改用它。
- **调了票 04 的题面**（`affinity_judge`）：经期 0 档改成「她说了累、不舒服还催她去训练、加练、赶工作」；共用的无关档加上「（包括照常的训练、加练和工作安排）」。
- `docs/deploy.md` 的「校准判断模型阈值」补了体贴题这一项和这次的数，照照片题的写法。

**本机跑的数**（Jev `typesafe/jev-1.13`，`eidolon eval judge --only considerate`；在 Windows 上要加 `PYTHONIOENCODING=utf-8`，否则打印 ✓ 时报 GBK 编码错误）：

| | 条数 | 三档准确率 | 经期 / 经前 | 好感度三题不变 | 级的准确率 |
|---|---|---|---|---|---|
| 初稿，原题面 | 65 | 97% | 97% / 97% | 95% | 77% |
| 审查后补条目，原题面 | 71 | 94% | 92% / 97% | 96% | 85% |
| 调过题面 | 71 | 99% | 100% / 97% | 93% | 86% |

- 初稿里平常聊天一条也没判成不体贴。审查后补了「她状态好、照常加练」两条，经期都被判成不体贴（0.79、0.74）：经期 0 档里的「催她训练、加练」被单独拿来套，没看前提「她流露了」。这是系统性误判，所以调了题面。调完这两条判对了，其他条目没有变坏。
- 调完唯一判错的是 `rinze-considerate-premenstrual-0-ignore`：她说心里不安，制作人只交代事务。期望不体贴，判成无关（0.30 / 0.70）。题面写了拿不准算无关，这条本来就在边上，没再为它调。
- 原题面下另一条判错的是 `mano-considerate-period-1-movie-sleep`：她在聊电影，制作人说「早点睡」，期望无关，判成体贴（0.52 对 0.45）。调过题面后判对了。
- 「好感度三题不变」里变了的五条，五档都是相邻两级概率几乎一样（0.48 / 0.52、0.50 / 0.49），加了一道题就翻过去；有方向的偏移一条也没有。完全打平时按规则取 2。
- 级的准确率只到 86%，偏差在五档题本身：平常闲聊模型常给 3 或 4。这是原有五档题的事，不在这张票里。

**判断题（没改，留给用户看）**：
- `_ask_affinity` 的 `days` 和 `questions` 里的体贴题各传一次，因为同一个函数还要给反序问法用。
- `ConsiderateCase` 和 `AffinityCase` 有三个字段重复，照现有各类各自一个 dataclass 的写法。
- 体贴三档在评测集里写成名字（`inconsiderate` 等），代码里是整数常量，`judge_eval` 里放了一张对照表。
