# 01: 调研：陪伴类产品的主动消息怎么做

Type: research
Status: resolved
Blocked by: none

## Question

issue #121 说主要参考 Muse AI，也参考 Grok 的陪伴角色。这些产品（再加上 Character.AI、Replika、Talkie、猫箱/星野这类有主动消息的陪伴产品，查得到几家算几家）的主动消息是怎么做的：

- 多久发一次，一天最多几条；分不分时段，夜里发不发；按谁的时区算。
- 发什么：由头有哪些（问候、想你了、很久没联系、接着上次的话题、节日或生日），一次几句，带不带图或语音。
- 和关系或好感度挂不挂钩：关系越好越常发吗。
- 用户不回时怎么收敛：连着几条没回就停吗，停多久。
- 用户和运营方各能怎么控制：整个关、按角色关、调频率。
- 用户的反馈：哪些做法被夸、哪些被骂（太烦、太假、重复、半夜吵人）。
- 消息是到点生成、推送，还是用户回来时才补上。

只要事实和出处，不要给 Eidolon-SC 的方案；后面的拍板票拿它当参考。

## Answer

全文（带出处）在 `research/proactive-messages-companions` 分支（3cda133）的 `.scratch/proactive-messages/research/companion-apps.md`，用 `git show origin/research/proactive-messages-companions:.scratch/proactive-messages/research/companion-apps.md` 看。另外加了 Nomi 和 Kindroid，规则写得最细的是这两家。

要点：

1. 只有 Nomi 公开了完整的节奏：每个角色单独选档（关、约 1 小时、约 3 小时、约 1 天、约 4 天）；用户不回，下一次的间隔大约翻倍，最低档只发一条就等用户回；按用户本地时间 22:00–08:00 不发，运营方定死；只发文字。
2. 没有哪家公开「一天最多几条」，查到的硬上限都跟成本有关（Kindroid 主动自拍每天免费 5 张、TalkieClaw 每天 1 条免费）。第三方 12 天的记录：Replika 14 条、Nomi 11 条、Kindroid 8 条、Character.AI 3 条（二手）。
3. 「不回就慢下来」很常见，但只有 Nomi 给了数字；没查到「连着几条没回就停、停多久」。
4. 由头：陪伴类是问候、想你、接着聊过的事（Kindroid 还参考时间、天气）；节日只查到星野有，生日没查到哪家专门做。
5. 形式不止文字：Kindroid 让角色自己挑文字、语音、自拍、电话，星野有主动来电；Nomi 只发文字。
6. 没查到哪家写明「关系越好发得越勤」；Common Sense Media 把 Grok 的推送、连续天数、关系等级一起列为「制造依赖」的机制（二手）。
7. 用户控制三种：按角色调（Nomi、Kindroid、Character.AI），一个总开关（星野、Replika），直接跟它说（Muse）。
8. 被骂得最多的是空洞、重复、像在拉留存（每天同一句早安、没内容的推送），其次是不合时宜（深夜、上课时）；被夸的是提到真实聊过的事（三天后追问「那八小节练得怎么样了」）。
9. 各家都是用户离开期间在服务器上生成、推送，没查到哪家等用户回来才补；Nomi 没开推送时用户回来看到未读。Nomi 把「关掉主动」当作给角色扮演用户的选项，免得角色在用户离开时「想别的事」。

注意：issue 里的「Muse AI」「grok bot」，调研按 Meta 2026-09 发布的个人智能体 Muse 和 xAI 2026-08 发布的 Grok Bot 理解（都偏智能体，定时任务、提醒），Grok 的 3D 陪伴模式 2026-09 已下线；如果 issue 指的是别的同名陪伴应用，要另查。猫箱、星野的部分只有下载站来源，不能当事实用；Reddit 的帖子多经第三方快照站引用。
