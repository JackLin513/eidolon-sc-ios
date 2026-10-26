# 01: 调研：原版的饮品、材料和调法

Type: research
Status: resolved
Blocked by: none

## Question

定图时定了照搬原版的饮品和调法，这张票把数据提取出来、核对清楚，给票 04、05、07 用。要查：

- **全部饮品**：英文名、官方中文名、配方（五种材料各几份，Adelhyde、Bronson Extract、Powdered Delta、Flanergide、Karmotrine）、加冰、陈化、摇和还是搅拌（mix / blend）、价格、口味（甜、酸、苦、辣、气泡……）、种类（Girly、Manly、Classy、Promo、Classic、Bland、Burning、Sobering、Sophisticated……以原版为准），以及原版对这款饮品的描述。官方中文描述在 `sprites/170_recipes_cn_*.png` 的配方图上，要读出来、对上饮品。
- **可选 Karmotrine 和大杯**：哪些饮品的 Karmotrine 是「可选」，大杯怎么调（份数翻倍？），原版有没有「酒精度」这个量、怎么算。
- **调法规则**：每种材料最多几份、调制器的总容量、调错（份数不对、忘了冰、摇和搅拌搞反）时原版出的是什么（一律算失败的饮品，还是会落到另一款上）；有没有「怎么调都对不上任何配方」的成品。
- **原版的分类和菜单**：配方书（BAR 界面的饮品列表）怎么排列、能不能按名称、口味、种类筛选或排序，界面上一页显示几款。
- 来源按可信度：`data.win` 里的 GML（可以用 UndertaleModTool 一类工具反编译，或者在 `STRG` 里找字符串）、提取目录的配方图、Fandom 之类的 wiki（只作交叉核对）。各条数据注明来源，有冲突时以游戏数据为准。

产出是一份结构化的表（Markdown 或 CSV，放在调研分支），能直接改写成仓库里的饮品表。

## Answer

全文在调研分支 [`research/bar-drinks`](https://github.com/Sallyn0225/eidolon-sc/blob/research/bar-drinks/.scratch/bar/research/drinks.md)（6a1994e5），另附 `drinks.csv`（29 行）。数据来自反编译的 `data.win`（`drink_a`/`drink_b`），和配方卡逐条核对，两边全部一致；wiki 只作交叉核对。

- **29 款**：25 款用材料调（24 款有配方卡，Flaming Moai 是隐藏款、没有卡），4 款瓶装直接上（Absinthe、Rum、Mulan Tea、A Fedora，一律 $500）。
- **官方中文版不译饮品名**，配方卡和中文剧本都用英文原名；要中文名就是我们的新决定。日文版有译名。
- **口味 5 种**（Sweet、Bitter、Sour、Spicy、Bubbly）、**种类 5 种**（Girly、Manly、Classic、Classy、Promo），每款各一个；点单判定只看口味、种类、含不含酒、大小。配方卡上另有 7 个「第三标签」（Vintage、Sobering、Bland、Soft、Happy、Burning、Strong），不参与判定。
- **调法**：调制器总共 20 份，单种材料不设上限；加冰、陈化两个开关；摇不到 5 秒停是 mix，摇满 5 秒后再停是 blend。**精确匹配**：份数、冰、陈化、调法都要和某个配方完全一致。
- **调错**：对不上任何配方就是「故障瓶」，**上不了**，只能重做；恰好等于另一款配方时就是那一款，可以上，后果由剧情定。
- **大杯**：份数全部翻倍；原本超过 10 份的 5 款没有大杯（本身就大）。**可选 Karmotrine** 7 款，加 0 份为无酒精；Bleeding Jane、Frothy Water 固定无酒精。原版没有「酒精度」，只有含不含酒，以及醉意（累计上过的 Karmotrine 份数，剧本按阈值分支）。
- **价格**：上对拿价格，点单允许大杯又上了大杯 +$100，上错 $0。
- **配方书**：四个标签：按名称（首字母）、按口味、按种类、瓶装；每类最多 6 款，点开看配方卡；不能组合筛选。
- **原版数据冲突**：Piano Man 口味（卡写 Sour、代码写 `"Bitter"`）、Flaming Moai 口味（代码 Spicy、wiki Sour）、大杯 Crevice Spike 拼错、Beer 中文卡把 Classic 印成「时尚」。建议以配方卡为准，Flaming Moai 按代码记 Spicy/Classy，中文标签用菜单分类名（Classic 经典、Classy 时尚）。

新冒出来的待定：饮品要不要起中文名、瓶装和隐藏款要不要、故障瓶照搬与否，并进票 05 和票 07。
