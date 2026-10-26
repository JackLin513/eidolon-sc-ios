# 11: 开发脚本和看措辞

**What to build:** 给维护者用的终端脚本，不进 `eidolon` 命令。它载入根目录的 `.env`，用部署者的对话模型直接驱动酒吧模块，完整走一次光顾。可以指定角色、每单的说法、每杯上成哪一档（脚本替制作人挑一款符合的），也可以让她喝醉。每句台词都打印出来：说话人、情绪、日语、中文；还有备忘、名字检查重写了几次，以及每次调用的用量和用时。脚本用临时库，不写真库，不发奖励。用线上的对话模型把每种说法、每种档位都跑一遍，用户看过措辞，再按反馈改提示词和写死的句子。见规格「开发用的终端脚本」和 Further Notes 的「人工验收」。

**Blocked by:** 06、07、08、10

**Status:** ready-for-agent

- [ ] 脚本能指定角色、说法、档位、醉，也能全随机；默认在临时目录建临时库。跑法照「本机跑判断评测」那样载入 `.env`，设好角色路径和 `PYTHONIOENCODING=utf-8`。
- [ ] 跑一遍并把输出存成文件给用户看：九种说法各一次；三种档位各至少一次；讨厌的口味、不要酒却有酒这两种错各一次；醉一次；不醉的告别一次；兜底句一次（模型调用可以故意弄坏）。
- [ ] 自己先看一遍：点单有没有漏名字、说偏；制作人的话是不是太多（每段最多一两句）；她的日语和中文字幕对不对得上；有没有越过 IF 的护栏。能改的直接改提示词，改了再跑。
- [ ] 停下等用户看措辞；用户的意见改进提示词或 `bar_lines.toml`，改完再跑一遍相关的几条。
- [ ] 脚本不写测试。pyright、ruff 通过。

## Comments

### 票 07 交接

- 「让她喝醉」：酒量弱的上一杯大杯 Beer（8 份）就醉；中等的要 14 份，强的要 20 份。能选 Karmotrine 的饮品可以直接多加。醉的告别调用写的是「这杯的反应照常写；写完反应，从这一段起你醉了……」。看的时候留意两点：反应有没有提前写成醉的；醉了以后有没有越过 IF 的护栏。
- 共用块 `_WRITING` 写「闲聊：6 到 10 句」，告别调用（醉没醉都一样）写「一小段闲聊」，两处可能对不上，看措辞时一起调。

### 票 08 交接

- 「不发奖励」：构造 `Bar` 时不传 `gifts`（或者不传 `affinities`），`_rewarding` 就恒为假，`done` 的 `rewarded` 恒为 `null`，库里也不动抽奖和好感度。

### 票 09 交接

- `Bar` 现在要一个 `Admissions`（代替原来的 `OwnKeys`）：`Admissions(UsageLimiter(db, UsageLimits(visits_per_hour=None), clock), ActivityLog(db, clock), own_keys, cooldown_until=...)`。`cooldown_until` 光顾不问，给一个返回 `None` 的就行。每次调用的用量和用时在临时库的 `service_calls` 里，按 `record_id` 挂在这次光顾的 `activity_records` 下面，脚本可以直接从这里读出来打印。
- `Bar.enter`、`Bar.serve` 返回 `BarCall`：用 `async for` 读，读完调 `aclose()`；`Bar.leave` 是 async。脚本最后调 `bar.aclose()`，让运行记录写完。

### 票 10 交接

- `Bar.serve` 和 `Bar.retry` 现在是 `async`，要 `await` 后才拿到 `BarCall`。新事件 `Retrying`（`retrying`）和 `VisitFailed`（`failed`）；`failed` 以后光顾停住，`Bar.retry` 接着走同一单。
- 「兜底句一次」：告别那次调用要连着失败两次（`bar.ATTEMPTS`）才会换兜底句，比如给模型包一层，在告别调用时连抛两次 `LLMError`。兜底的反应按这一杯的档位，告别按醉没醉，都从 `bar_lines.toml` 随机挑。
