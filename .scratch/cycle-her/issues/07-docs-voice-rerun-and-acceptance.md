# 07: 收尾：配置指南、线上模型重跑说话原型、本地验收

**What to build:** 「她的周期」可以合并：部署者从配置指南里知道多了什么，用户看过线上模型说出来的措辞，本地构建版上整条路走过一遍。**配置指南**：`docs/configuration.md` 三语新加一节「周期」，写这几样：
- 是什么：每位用户的每位角色各有一个周期，经前、经期影响她的言行、好感度、挂断和暖礼物
- `EIDOLON_CYCLES` 和后台的卡；用户也能在设置里关
- 她真实的周期不存库，由密钥派生，改密钥会重抽
- 开发口子只在开发登录下有

周期页那一半由第二份规格补上。**重跑说话原型**：把 `origin/prototype/cycles-voice` 的 `prototype_cycles_voice.py` 换成线上的对话模型，提示词照这一份实现后的真实拼法，再跑一遍：果穗、円香、冬优子、千雪，经期、经前、被直接问各几轮，加上通话和搭话。结果整理成一页给用户看，用户认可措辞后才合并。脚本和结果不进 main。线上模型的名字向用户确认，key 用用户本机已有的配置，不新开付费项。**验收**：照 `docs/agents/local-acceptance.md`，在本地构建版上用 Playwright：
- 用开发口子让一位角色进经期第 3 天，打一个回合：看对话里的事件和列表的最后一句，通话层里不显示
- 设置里关掉周期后，事件不再出现
- 后台的卡切换后，设置分类出现、消失

**清单**：列出人工验证项（措辞、真机上的样子），以及部署前要手动备份的几样：好感度表的一列、「关掉周期」的表。公告草稿等两份规格都合进 main、一起部署时再在对话里给，不写进票。见规格「文档和上线」和 Testing Decisions 的「验收」。

**Blocked by:** 02, 03, 04, 05, 06

**Status:** ready-for-agent

- [ ] `docs/configuration.md`、`.en.md`、`.ja.md` 都有「周期」一节，三语内容一致
- [ ] 线上模型重跑完，结果给了用户，用户认可了措辞（记进 Comments）；有没有一次说出经期、月经、生理期、出血，统计后写进 Comments
- [ ] Playwright 验收上面三条都过，截图或结论写进 Comments
- [ ] 人工验证清单、部署前备份清单写进 Comments
- [ ] 这一波最后一次推送后 CI 是绿的
- [ ] 票收尾：跑 `code-review`；转正式 PR 和合并等用户当次说

## Comments

### 票 03 交接

- 验收「列表的最后一句」：这条事件总记在那个回合之前，打完回合后列表的最后一句是她的回复，看不到这条事件；列表显示它的写法只在它是最后一条时出现（导入的包），后端测试 `test_the_conversation_lists_last_message_says_since_when_should_it_be_last` 管着。验收时看对话里的分隔线就够。
- 本机 Playwright 包升级后要的 `chromium_headless_shell-1248` 没装，只有 `chromium-1243`：票 03 的脚本里用 `executablePath` 指到 `C:/Users/z1921/AppData/Local/ms-playwright/chromium-1243/chrome-win64/chrome.exe` 跑通；或者先 `npx playwright install chromium`（要下载）。
- 开发口子强制的经期在后端重启后就没了；验收时用一个专用的开发登录用户（票 03 用的是 `unwell-accept`，验完删了），不动 Sallyn。

