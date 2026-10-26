# 01: 开关、饮品目录和读接口

**What to build:** 酒吧有了开关和饮品目录，用接口就能验。部署者用 `.env` 的 `EIDOLON_BAR` 开关酒吧：不填或 `1` 开，`0` 关，其他值启动报错，写法同 `EIDOLON_SCHEDULE`。管理者在后台「限额与玩法」的「酒吧」卡上开关，后台改的优先（ADR-0013）。仓库里新加 `characters/drinks.toml`，照调研分支 `research/bar-drinks` 的 `drinks.csv` 转过来，共 28 款：24 款调制、4 款瓶装，不收 Flaming Moai。启动时校验，写错了后端起不来。配方匹配函数把调酒台的样子（五种材料份数、冰、陈化、mix 或 blend，或者一款瓶装）认成一款饮品加「大杯没有」，或者「调坏了」，同时给出这一杯含不含酒、酒精几份。`GET /api/bar` 关着时返回 `{"enabled": false}`，开着时返回 `enabled` 和饮品目录。`reward_today` 留给票 08。见规格「饮品目录」「配方匹配」「开关和后台」和接口一节里的 `GET /api/bar`。

**Blocked by:** None (can start immediately)

**Status:** done

- [x] `drinks.toml` 一共 28 款，每款的字段照规格：`id`（好认的写法）、`name`、`name_ja`、`short_name`、五种材料的份数（Karmotrine 可以是 `"optional"`）、`ice`、`aged`、`method`、`big`、`flavor`、`kind`、`page`、`description`；瓶装的 `karmotrine` 份数是 Absinthe 6、Rum 6、A Fedora 3、Mulan Tea 0。数据冲突照票 01 的建议处理（Piano Man 是 Sour 等）。
- [x] 加载时校验：id 唯一合法；份数是 0–20 的整数且合计不超过 20；调制的和瓶装的字段各不混用；口味、种类、调法都在列表里；有配方卡的要有 `page` 和 `description`；任意两款配方不重合，翻倍和可选 Karmotrine 展开后也不能重合。坏了报配置错误，并指出是哪一款。
- [x] 配方匹配的规则：份数（可选 Karmotrine 那一项不比）、冰、陈化、调法完全一致；大杯是份数全部翻倍；本身就是大杯的没有翻倍版；都对不上算调坏。Flaming Moai 的配方也算调坏。瓶装认 id。
- [x] 含不含酒、酒精份数：调制的按实际加的 Karmotrine 份数算，大杯自然是翻倍后的；瓶装按目录里的份数。
- [x] `EIDOLON_BAR`（`.env.example` 也补上）、实时配置项 `bar`（字段 `enabled`）、`LiveConfig.bar_on`、后台配置接口能读写；后台配置页「限额与玩法」加一张「酒吧」卡，只有开关，照「日程」卡的样子，不「试」。
- [x] `GET /api/bar`：只给登录并同意了条款的用户；关着时返回 `{"enabled": false}`；开着时的目录不含 `name_ja` 和配方卡描述（瓶装的小字和份数要给），不含任何角色的口味。
- [x] 测试（接缝二，照 `test_job_list.py`、`test_gift_catalog.py`）：真实目录通过校验；临时目录缺字段、重复 id、份数超 20、两款配方重合（含翻倍后）、口味拼错各被拒；28 款每款匹配到自己；每款的大杯；本身大的没有翻倍版；可选 Karmotrine 加 0 份和加几份都是那一款，含不含酒、份数都对；冰、陈化、调法差一样就对不上；Flaming Moai 调坏；瓶装能认。
- [x] 测试（接缝一）：开关不填为开、`0` 为关、其他值报错；后台配置改了优先（先例 `test_schedule_switch.py`、`test_live_config.py`）；`GET /api/bar` 开着和关着的返回；前端 `adminConfig` 多一项「酒吧」的测试。
- [x] pyright、ruff 通过，前端类型检查通过；提交前跑 `sh scripts/affected-tests.sh <开工前的提交>`。
- [x] 收尾：在 Comments 里写下 `GET /api/bar` 的返回形状、饮品 id 的写法和匹配函数的接口，给后面的票用。

## Comments

### 实现说明（票 01）

- **饮品目录**：`characters/drinks.toml`，后端 `eidolon/drink_catalog.py`（照 `gift_catalog.py`）。启动时由 `assembly` 加载，挂在 `Backend.drink_catalog`（`DrinkCatalog`）上；测试的 `CharacterConfig` 照礼物目录、工作清单的做法把仓库这份带到临时目录，测试要自己的目录就 `characters.write(DRINKS_FILE, …)`。
- **饮品 id**：英文原名小写、空格换成 `-`：`sugar-rush`、`bad-touch`、`piano-man`、`a-fedora`、`mulan-tea`。目录顺序照原版代码的判定顺序（先按种类 Girly→Manly→Classic→Classy→Promo），瓶装 4 款在最后。
- **数据冲突**：Piano Man 记 `sour`，Beer 记 `classic`（照配方卡和菜单分类名）。A Fedora 的 `short_name` 照 csv 是原版的 `Plumfume`，Mulan Tea 的是 `Tea`。
- **匹配函数**：`DrinkCatalog.match(served: Mixture | str) -> Served | None`。
  - `Mixture(adelhyde, bronson_extract, powdered_delta, flanergide, karmotrine, *, ice, aged, method)`，`method` 是 `"mix"` 或 `"blend"`；传字符串就是瓶装的 id。
  - 返回 `None` 是调坏了：对不上任何配方、合计超过 20 份、某项不是从 0 起的整数、瓶装 id 不存在或不是瓶装。
  - `Served.drink` 是 `Drink`；`Served.big` 只表示「翻倍的那一杯」，本身就大的（`drink.recipe.big`）和瓶装永远是 `False`；`Served.karmotrine` 是这一杯的酒精份数（调制的是实际加的，大杯自然是翻倍后的；瓶装是目录里的），`Served.alcoholic` 是它大于 0。
  - `Drink.recipe` 是 `Recipe | None`（None 是瓶装），`Recipe.karmotrine` 是 `None` 时为可选；瓶装的份数在 `Drink.bottled_karmotrine`。`DrinkCatalog.drinks` 按目录顺序以 id 为键，`DrinkCatalog.mixed()` 只列调制的，`DrinkCatalog.described()` 是接口给的那份列表。配方重合在构造 `DrinkCatalog` 时就查。
- **校验**里多了两条票上没写的：配方一份材料都没有的拒绝（不然空的摇酒壶就是它）；不是 `big` 的翻倍后超过 20 份的拒绝（大杯调不出来），要写 `big = true`。`page` 不查重，由仓库目录的测试看 1–24 各一张。
- **开关**：`Settings.bar`（`EIDOLON_BAR`）、实时配置项 `bar`（`enabled`）、`LiveConfig.bar_on`、后台 `PUT/DELETE /api/admin/config/bar`；前端 `adminConfig` 的 `bar` 排在「限额与玩法」最后、`cycles` 之后，文案在 `zh.ts` 的 `config.items.bar`。
- **`GET /api/bar`**（`eidolon/bar_api.py`，`UserId` 依赖：没登录 401，没同意条款 `CONSENT_REQUIRED`）：
  - 关着：`{"enabled": false}`。
  - 开着：`{"enabled": true, "drinks": [...]}`，按目录顺序，每款由 `Drink.described()` 给（`DrinkCatalog.described()` 按顺序列出）：
    - 调制的：`{"id", "name", "short_name", "flavor", "kind", "method": "mix"|"blend", "adelhyde", "bronson_extract", "powdered_delta", "flanergide", "karmotrine": <整数>|"optional", "ice", "aged", "big", "page"}`。
    - 瓶装的：`{"id", "name", "short_name", "flavor", "kind", "method": "bottle", "description", "karmotrine"}`。
  - 不含 `name_ja`、调制的 `description`、任何角色的口味。`reward_today` 是票 08 的。

### 审查（票 01）

`code-review`（固定点 ebcda3fe）两份报告里建议修的已经改了：测试里不分支的参数行、和日程同路径的前端用例、开关的 `0`/其他值（归 `test_exempting_keys` 管，照 `test_cycles_switch.py` 只留「不填为开」）都并掉或删掉；条款的检查挪进 `test_consent.py` 的接口清单；`match` 拒掉负数和不是整数的份数；配方重合改在构造 `DrinkCatalog` 时查，不再算两遍；`Backend.drinks` 照先例改名 `drink_catalog`；文案「调酒」改成「调饮品」（GLOSSARY「饮品」）。

留下没改的判断题：

- 四种材料的份数在 `Recipe`、`Mixture`、`_Glass` 和 `described()` 里各写一遍（数据泥团），可以收成一个份数类型；目前每处都短，先不动。
- 加载骨架和 `_one_of` 是 `gift_catalog`、`job_list` 之后的第三份拷贝，没有抽公共件。
- `match(served: Mixture | str)` 一个函数接两种输入，照规格「调酒台的样子或者一款瓶装的 id」写的；也可以拆成两个方法，等票 05 接上酒正文时再看顺不顺手。
- 调制款的未知字段（比如把 `big` 拼错）不报错，只有瓶装带了配方字段才拒；规格没要求拒掉未知字段。本身就大的 4 款拼错 `big` 会被「翻倍超过 20 份」那条拦下。
- `DrinkCatalog.mixed()` 现在只有测试在用，票 05 抽目标饮品时会用上。
