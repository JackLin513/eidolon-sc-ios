# 01: 开关、饮品目录和读接口

**What to build:** 酒吧有了开关和饮品目录，用接口就能验。部署者用 `.env` 的 `EIDOLON_BAR` 开关酒吧：不填或 `1` 开，`0` 关，其他值启动报错，写法同 `EIDOLON_SCHEDULE`。管理者在后台「限额与玩法」的「酒吧」卡上开关，后台改的优先（ADR-0013）。仓库里新加 `characters/drinks.toml`，照调研分支 `research/bar-drinks` 的 `drinks.csv` 转过来，共 28 款：24 款调制、4 款瓶装，不收 Flaming Moai。启动时校验，写错了后端起不来。配方匹配函数把调酒台的样子（五种材料份数、冰、陈化、mix 或 blend，或者一款瓶装）认成一款饮品加「大杯没有」，或者「调坏了」，同时给出这一杯含不含酒、酒精几份。`GET /api/bar` 关着时返回 `{"enabled": false}`，开着时返回 `enabled` 和饮品目录。`reward_today` 留给票 08。见规格「饮品目录」「配方匹配」「开关和后台」和接口一节里的 `GET /api/bar`。

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] `drinks.toml` 一共 28 款，每款的字段照规格：`id`（好认的写法）、`name`、`name_ja`、`short_name`、五种材料的份数（Karmotrine 可以是 `"optional"`）、`ice`、`aged`、`method`、`big`、`flavor`、`kind`、`page`、`description`；瓶装的 `karmotrine` 份数是 Absinthe 6、Rum 6、A Fedora 3、Mulan Tea 0。数据冲突照票 01 的建议处理（Piano Man 是 Sour 等）。
- [ ] 加载时校验：id 唯一合法；份数是 0–20 的整数且合计不超过 20；调制的和瓶装的字段各不混用；口味、种类、调法都在列表里；有配方卡的要有 `page` 和 `description`；任意两款配方不重合，翻倍和可选 Karmotrine 展开后也不能重合。坏了报配置错误，并指出是哪一款。
- [ ] 配方匹配的规则：份数（可选 Karmotrine 那一项不比）、冰、陈化、调法完全一致；大杯是份数全部翻倍；本身就是大杯的没有翻倍版；都对不上算调坏。Flaming Moai 的配方也算调坏。瓶装认 id。
- [ ] 含不含酒、酒精份数：调制的按实际加的 Karmotrine 份数算，大杯自然是翻倍后的；瓶装按目录里的份数。
- [ ] `EIDOLON_BAR`（`.env.example` 也补上）、实时配置项 `bar`（字段 `enabled`）、`LiveConfig.bar_on`、后台配置接口能读写；后台配置页「限额与玩法」加一张「酒吧」卡，只有开关，照「日程」卡的样子，不「试」。
- [ ] `GET /api/bar`：只给登录并同意了条款的用户；关着时返回 `{"enabled": false}`；开着时的目录不含 `name_ja` 和配方卡描述（瓶装的小字和份数要给），不含任何角色的口味。
- [ ] 测试（接缝二，照 `test_job_list.py`、`test_gift_catalog.py`）：真实目录通过校验；临时目录缺字段、重复 id、份数超 20、两款配方重合（含翻倍后）、口味拼错各被拒；28 款每款匹配到自己；每款的大杯；本身大的没有翻倍版；可选 Karmotrine 加 0 份和加几份都是那一款，含不含酒、份数都对；冰、陈化、调法差一样就对不上；Flaming Moai 调坏；瓶装能认。
- [ ] 测试（接缝一）：开关不填为开、`0` 为关、其他值报错；后台配置改了优先（先例 `test_schedule_switch.py`、`test_live_config.py`）；`GET /api/bar` 开着和关着的返回；前端 `adminConfig` 多一项「酒吧」的测试。
- [ ] pyright、ruff 通过，前端类型检查通过；提交前跑 `sh scripts/affected-tests.sh <开工前的提交>`。
- [ ] 收尾：在 Comments 里写下 `GET /api/bar` 的返回形状、饮品 id 的写法和匹配函数的接口，给后面的票用。

## Comments
