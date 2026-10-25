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

**Status:** ready-for-agent

- [ ] 约 60 条 `[[considerate]]`：经前、经期 × 三档各约 10 条，无关的例子偏多，上面几类难判的都有，包括未满 18 岁的角色
- [ ] `judge_eval` 认这一类，报三档准确率，以及五档等级和期望的差别
- [ ] `test_judge_eval.py`：评测集能读，每条字段齐全，阶段和档的取值合法
- [ ] 本机跑过一次评测，准确率和主要误判写进 Comments；调过题面的话前后都写
- [ ] 条目的措辞守词汇表（不写生理期、PMS 之类）
- [ ] pyright、ruff 过；提交前 `sh scripts/affected-tests.sh <开工前的提交>`
- [ ] 票收尾：推一次让 CI 跑、跑 `code-review`

## Comments

### 票 04 交接

- 题面在 `affinity_judge._CONSIDERATE_QUESTIONS`（经期、经前各一版），全文和答案的读法见票 04 的「实现说明」。请求里它排在原有三道题之后、照片题之前，键是 `affinity_judge.CONSIDERATE_QUESTION`（`"considerate"`）。
- 评测时问法：`affinity_judge.affinity_questions(days)`（`days` 是 `"period"` / `"premenstrual"`）或 `retrieval.judge_questions(affinity=True, days=...)`；读法：`affinity_judge.read_judged(answers, thresholds, days)`，体贴档在 `Judged.considerate`（0 / 1 / 2，常量 `affinity.INCONSIDERATE / UNRELATED / CONSIDERATE`）。
- 「其他题的结论没变」：拿同一条用 `days=None` 和 `days=...` 各问一次，比 `Judged.level`、`out_of_line`、`manipulation`。
