# 22: 合照

**What to build:** 动态的配图偶尔是她和一两位组合伙伴的合照：可以是自拍，也可以是别人帮她们拍的，一眼认得出是谁，外貌不串。合照里的人一定也在赞的人里。只在部署者用 NovelAI 形态的中转时才有合照，OpenAI 形态的中转从不出合照。规格见 `../spec.md`：「写一条动态」里讲允许的构图和名单规矩的两处，「配图的提示词」里讲合照、坐标、只在 NovelAI 形态的几条。来历是 `04-post-image-prototype.md`（合照实测：两人 6/6、三人 2/2）和 `11-post-image-prompt.md`。

**Blocked by:** 20, 21

**Status:** ready-for-agent

- [ ] **什么时候允许合照**，三条都满足才允许：
  - 部署者的生图是 NovelAI 形态；
  - 她自己配齐了 `photo_tag` 和 `photo_appearance`；
  - 这条动态的圈子里至少有一位也配齐了。
  
  不满足时，「这次允许的构图」里就没有合照，她不用另外知道。
- [ ] **提示词**：
  - 圈子成员那一节里，标出哪几位能进合照（配齐了外貌的）。
  - `<image>` 多一栏 `with`，写合照里的人，1–2 个 id。
  - 规则加一句：想拍成自拍，就在 `action` 里写 `selfie`；不写就是别人帮她们拍。
- [ ] **请求体**：
  - 多角色提示框里，她本人和 `with` 里的每个人各一个框，每框写 `girl, <角色 tag>, <外貌>`；负面也照这个结构写。
  - centers 发 `(0,0)`，`use_coords` 发 `false`。返回的 PNG 元数据会把它记成 `true`，这不影响出图，别去「修」。在代码注释里记一句。
  - 人数 tag 只写在 base 里：
    - `action` 里有 `selfie`（合照里不剥）：写 `{n}girls, selfie`，景别收到 `portrait` 或 `upper body`；
    - 没有 `selfie`，就是别人拍：两人写 `2girls, side-by-side`，三人写 `3girls, group picture`，景别 `upper body` 或 `cowboy shot`。
  - `outfit` 全员共用。合照里放行 `holding hands`。去重用的那个固定集合，按实际人数换。
  - 人数 tag 和每个人的外貌由服务器写进去，不经过清洗。
- [ ] **尺寸**：合照用 1216×832 的横图。
- [ ] **降级**：选了合照，`with` 却是空的，或者有人不在可选名单里，就降成她一个人的摆拍，景别保留，记一次降级。
- [ ] **名单**：合照里的人一定算进赞的人，她没写也补上。
- [ ] **测试**，都看 `FakeImageService` 收到的请求体：
  - 两人、三人；自拍和别人拍；
  - 景别的范围；
  - `with` 无效时降成摆拍；
  - OpenAI 形态下、圈子里没有配齐的人、她自己没配外貌时，都不允许合照；
  - 合照里的人进了赞的人。
- [ ] **验收**：在本地构建版上用假生图造一条合照动态，看时间线显示横图。要用真中转出图看效果时，先向用户报张数，等他点头再出。
- [ ] `sh scripts/affected-tests.sh <基点>` 通过，推送后 CI 全绿。

## Comments

### 票 20 交接

- 合照的人从圈子里选：`PostMaterial.circle` 是 `Member(character, relation)` 的列表，`character.photo_tag`、`photo_appearance` 在那里。「圈子里至少一位配齐外貌才允许合照」照它判断。
- 「合照里的人必定算进赞」放进 `moment_prompt.parse_post`：现在赞是先去掉圈子外的、去重，再截到 `LIKES`/`BIRTHDAY_LIKES`（超了记 `likes_over`）。补人的时候要放在截掉之前还是之后，自己定。
