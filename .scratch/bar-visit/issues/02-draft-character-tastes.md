# 02: 起草：每位角色的口味

**What to build:** 给 29 位角色每人写好酒吧口味的五样，写在 `characters.toml` 里，和 `liked_gifts` 放在一起：`bar_flavors`（喜欢的口味，1–2 种，必填）、`bar_kind`（喜欢的种类，0–1 种）、`bar_favorites`（爱喝的饮品，1–3 款饮品 id，必填）、`bar_disliked_flavor`（讨厌的口味，0–1 种，推不出来就不填）、`bar_tolerance`（酒量 `weak`、`medium`、`strong`，必填）。每位的出处文件 `facts/<id>.sources.md` 新开一节「酒吧口味」，每一条写一句理由。加载时校验这五列，写错了后端起不来。做完先停下，等用户校对。见规格「角色的口味」和票 04 的答案。

**Blocked by:** 01（饮品 id 要来自目录）

**Status:** done

- [x] 依据：剧情里有饮食偏好的就引剧情，找不到的从人设推，标「人设推断」并写清理由。种类和讨厌的口味也一样，可以从人设推。酒量按年龄和性格推：刚到能喝酒年纪的偏弱，成年组、性格豪爽的偏强。爱喝的饮品从口味和种类对过去。
- [x] 爱喝的饮品尽量分散，不让一半人都爱同一款；不要求每款都有人爱。はづき 也要写。
- [x] 校验：口味、种类、酒量都在列表里；爱喝的都在饮品目录里，两份都加载完再查，照 `gift_catalog.check_liked_gifts`；讨厌的口味不能和喜欢的口味重合；爱喝的饮品不能是讨厌的口味。坏了报配置错误，并指出是哪一位。测试的 `CharacterConfig` 能带上这几列。
- [x] 测试（照 `test_characters.py`）：真实的 `characters.toml` 通过校验；临时配置里缺必填项、爱喝的不在目录里、讨厌的和喜欢的重合各被拒。
- [x] 做完停下，不往下做别的票。Comments 里列一张 29 人的总表（五样加一句话的依据），等用户校对，用户改完再关票。

## Comments

### 实现说明（票 02）

- **配置**：`characters.toml` 每人在 `liked_gifts` 后面加五列：`bar_flavors`（列表）、`bar_kind`（字符串，可省）、`bar_favorites`（列表，饮品 id）、`bar_disliked_flavor`（字符串，可省）、`bar_tolerance`（字符串）。
- **加载**：`characters.py` 只查形状（列表里是字符串、单值是字符串），读进 `Character.bar_flavors`、`bar_kind`、`bar_favorites`、`bar_disliked_flavor`、`bar_tolerance`，类型都是 `str`，和 `liked_gifts` 一样。
- **校验**：`drink_catalog.check_bar_tastes(characters, catalog)`，照 `gift_catalog.check_liked_gifts` 写，`assembly.build` 在饮品目录加载完以后调用，坏了报 `CharacterConfigError` 并点出是哪一位。规则：口味 1–`MAX_FLAVORS`（2）种，不重复，都在 `Flavor` 里；种类在 `Kind` 里；爱喝的 1–`MAX_FAVORITES`（3）款，不重复，都在目录里；讨厌的口味在 `Flavor` 里，不在喜欢的口味里，爱喝的没有这个口味；酒量必填，在新的 `Tolerance`（`weak`、`medium`、`strong`）里。
  - 这个函数放在 `drink_catalog`，因为它要导入 `characters`（和 `gift_catalog` 一样）；所以 `characters.py` 不能反过来导入 `Flavor`、`Kind`、`Tolerance`，`Character` 上这几列只能是 `str`。
- **测试**：`test_drink_catalog.py`；`conftest.BAR_TASTE` 是 `CharacterConfig.add(bar=…)` 默认写的必填三项（`sweet`、`sugar-rush`、`medium`），传 `None` 就一列都不写。fixture 里的角色都爱喝 `sugar-rush`，自带小目录的测试要把它写进目录里。
- **仓库数据的测试会卡出处文件的格式**：每位出处文件「酒吧口味」一节，每一项要写成 `- 口味 sweet（…`、`- 种类 girly（…`、`- 爱喝 sugar-rush（…`、`- 讨厌 bitter（…`、`- 酒量 weak（…`，顺序和 `characters.toml` 一致；不填的写 `- 种类：不填，…`。改了配置，记得同步改这一节。
- **初稿怎么写的**：29 人的依据都来自各自的角色资料和出处文件。讨厌的口味只给剧情里能找到原话的 8 位。没引剧情或官方资料的条目，以及只靠口味、种类对过去的爱喝饮品，一律标「人设推断」。一款饮品最多 3 人爱喝，共 50 个；没人爱喝的只有 Rum。酒量弱 13、中 11、强 5。

### 校对（票 02）

2026-10-26 用户校对通过（看的是按配置和出处文件生成的本地 HTML），没有改动；風野灯織记「苦」、和泉愛依记酒量「强」都照初稿保留。

### 审查（票 02）

`code-review`（固定点 a3717797）两份报告里建议修的已经改了：
- 测试里走同一分支的参数行合并掉了：缺必填项只留爱喝的和酒量，拼错只留口味，超上限只留饮品。
- 两个辅助函数补了 docstring，`bar_tolerance` 说明了 None 的意思，`assembly` 的 docstring 重新折行。
- 三条写成两句的依据改成一句。
- 「人设推断」的标法统一了。

留下没改的判断题：
- `_some_of` 的三项检查（空、超上限、重复）和 `check_liked_gifts` 是同一个形状，没有抽公共件（加载骨架抽公共件也是票 01 留下的判断题）。
- 五列可以收成一个 `BarTaste` 类型，`bar_tolerance` 也可以用 `Tolerance` 而不是 `str`。现在照 `liked_gifts` 的先例平铺成 `str`，等票 05 用起来顺不顺手再看。
- 数据上请你校对时特别看两处。風野灯織记「苦」：剧情只说她喝得惯黑咖啡，她自己说不是喜欢。和泉愛依记酒量「强」：依据是「楽天的で大雑把」，算不上「豪爽」，是边缘情况。

### 29 人总表（用户已校对）

口味、种类、讨厌：甜 sweet、苦 bitter、酸 sour、辣 spicy、发泡 bubbly；女性化 girly、男性化 manly、经典 classic、时尚 classy、宣传 promo。每一条的理由和出处见各自 `facts/<id>.sources.md` 的「酒吧口味」一节。

| 角色 | 口味 | 种类 | 爱喝 | 讨厌 | 酒量 | 依据 |
|---|---|---|---|---|---|---|
| mano 櫻木真乃 | 甜 | 女性化 | `sugar-rush`、`mulan-tea` | — | 弱 | 没有饮食剧情，按温和的人设记甜；红茶对应调味茶 |
| hiori 風野灯織 | 苦 | 时尚 | `sunshine-cloud`、`mercury-blast` | — | 弱 | 小时候从咖啡牛奶喝到黑咖啡，记苦（她说不是喜欢，只是喝得惯）；酷，记时尚 |
| meguru 八宮めぐる | 甜、发泡 | — | `sparkle-star`、`frothy-water` | — | 中 | 蜂蜜热牛奶、冰淇淋；自己说几乎没有讨厌的；好动，记发泡 |
| kogane 月岡恋鐘 | 发泡、甜 | 经典 | `beer`、`piano-woman` | 苦 | 强 | 喝汽水像泡完澡的大叔、甜食忍不住；黑咖啡要加一堆糖，讨厌苦；居酒屋打过工，酒量强 |
| mamimi 田中摩美々 | 甜、发泡 | — | `blue-fairy`、`cobalt-velvet` | 苦 | 中 | 巧克力蛋糕、メロンソーダ；咖啡喝完说「苦ぁ」；爱恶作剧，配让牙变蓝的 Blue Fairy |
| sakuya 白瀬咲耶 | 苦 | 时尚 | `bad-touch`、`brandtini` | — | 中 | 吃蛋糕配苦咖啡；王子气质，记时尚 |
| yuika 三峰結華 | 甜、苦 | 宣传 | `grizzly-temple`、`piano-woman` | — | 中 | 蛋糕配咖啡；偶像宅，配「只有影迷才点」的宣传款 Grizzly Temple |
| kiriko 幽谷霧子 | 甜 | 女性化 | `sunshine-cloud`、`mulan-tea` | — | 弱 | 銭湯的咖啡牛奶、学习前泡茶；爱可爱的东西；性子柔弱，酒量弱 |
| toru 浅倉透 | 酸、辣 | — | `bleeding-jane`、`bloom-light` | — | 中 | 酸辣汤番茄面「すっぱうまい」、担々麺，记酸、辣 |
| madoka 樋口円香 | 酸 | 时尚 | `mercury-blast`、`bad-touch` | 苦 | 中 | 最常点柠檬红茶；不喝黑咖啡（「なんでこんなに苦いのを」）；酷，记时尚 |
| koito 福丸小糸 | 甜 | 女性化 | `blue-fairy` | — | 弱 | 最爱糖果，喫茶店看上的是蓝色奶油苏打，对应 Blue Fairy |
| hinana 市川雛菜 | 甜 | 女性化 | `sugar-rush`、`moonblast` | 苦 | 弱 | 最爱甜的，尝了黑咖啡喊「きらい」 |
| nichika 七草にちか | 甜、酸 | 宣传 | `fluffy-dream`、`piano-man` | — | 弱 | 奶茶、给美琴做蜂蜜柠檬；偶像宅、唱片店打工，记宣传 |
| mikoto 緋田美琴 | 酸、甜 | — | `fluffy-dream` | — | 弱 | 蜂蜜柠檬；剧情里不喝酒，酒量弱；只记一款，照「一途」 |
| asahi 芹沢あさひ | 甜 | 宣传 | `sparkle-star`、`zen-star` | 苦 | 弱 | 果汁胜过红茶、爱新奇的东西；苦巧克力「美味しくない」 |
| fuyuko 黛冬優子 | 辣、甜 | 女性化 | `sugar-rush`、`marsblast` | — | 中 | 对外的「ふゆ」爱甜，私下爱激辛：Sugar Rush 和 Marsblast 各对一面 |
| mei 和泉愛依 | 甜 | 女性化 | `sparkle-star` | — | 强 | 可丽饼、珍珠奶茶；楽天的・大雑把，酒量强 |
| kaho 小宮果穂 | 甜 | 男性化 | `gut-punch`、`moonblast` | 辣 | 弱 | 甜食和駄菓子；憧憬英雄，记男性化；辣的不行（黑醋、酸橘子也不行，只取辣） |
| chiyoko 園田智代子 | 甜 | 女性化 | `sunshine-cloud`、`brandtini` | — | 弱 | 巧克力偶像，配「像巧克力牛奶」的 Sunshine Cloud；酒心蛋糕都不敢吃，酒量弱 |
| juri 西城樹里 | 苦、发泡 | 男性化 | `piledriver`、`suplex` | — | 强 | 拿铁「苦いけど うめー」、苏打冰棒；男孩子气、运动全能，酒量强 |
| rinze 杜野凛世 | 甜 | 经典 | `mulan-tea`、`a-fedora` | — | 弱 | 甜食、抹茶牛奶、会泡茶；大和抚子，记经典；酒席斟酒都应付不来，酒量弱 |
| natsuha 有栖川夏葉 | 发泡 | 时尚 | `cobalt-velvet`、`fringe-weaver` | — | 中 | 大小姐，记发泡（香槟）和时尚；生日会喝多、要人挡酒，酒量中 |
| amana 大崎甘奈 | 甜 | 女性化 | `piano-woman` | 辣 | 中 | 有奶油的布丁；辣的不行 |
| tenka 大崎甜花 | 甜 | — | `blue-fairy` | 苦 | 弱 | 草莓可可、布丁；咖啡和高可可巧克力都喊苦 |
| chiyuki 桑山千雪 | 甜 | 时尚 | `brandtini` | — | 弱 | 和果子、红叶馒头；自己说酒量不强 |
| luca 斑鳩ルカ | 酸、苦 | 男性化 | `absinthe`、`crevice-spike` | — | 强 | 芒果雪葩、纯红茶；说话凶，记男性化；「普通に飲める」，酒量强 |
| hana 鈴木羽那 | 甜 | 女性化 | `moonblast` | — | 中 | 各种甜点和白巧克力焦糖拿铁 |
| haruki 郁田はるき | 甜、酸 | — | `fluffy-dream` | — | 中 | 奶茶、可可、老家的柠檬水，记甜、酸 |
| hazuki 七草はづき | 甜、发泡 | 经典 | `beer`、`frothy-water` | — | 强 | 爱甜点；下班和千雪喝酒、会要チェイサー，记发泡、经典，酒量强 |
