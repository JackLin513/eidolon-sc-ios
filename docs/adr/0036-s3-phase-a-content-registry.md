# ADR-0036：S3 Phase A 内容包先行（ADR-0035 的多包例外）

日期：2026-11-11
状态：已接受

## 背景

ADR-0035 决定 S1 只预留 `ContentManifest.franchise`，把多包 registry 与复合用户身份留到 S3。调研（`docs/research/content-packs-galgame-gakumas-2026-11-11.md`）之后，用户希望在两天内先验证两个外部企划的**包/运行时接缝**：SC、Sakura（Galgame）与 Haruka（MLTD）。

如果等 v24 复合身份迁移全部完成再验证包，会把内容迁移风险与数据库迁移风险绑在一起。反过来，直接让多个包共享裸 `character_id` 又会造成不可恢复的数据合并，违反跨企划调研的结论。

## 决定

引入 **Phase A**：只验证内容包根、kind 与身份边界，不迁移用户库。

1. `Content/<franchise>/current` 是每个内容包的根；`Content/current` 是指向 active 包的**相对 symlink**，替换用原子 rename。
2. `Eidolon` 增加内存/`app_state` 的包清单、active franchise、安装/切换 API；旧单包 `install` 视为 `shiny`。
3. `ContentManifest` 增加可选 `engineFamily`、`characters.characterKeys`；`ContentBundleInfo` 带 `franchise`/`kind`/`characterKeys`。新字段都可缺省，旧包读取不变。
4. 内容 installer 先按 manifest `kind` 校验；`installContentPackage` 从包内 manifest 取 franchise，避免 Sakura 覆盖 Shiny。
5. Phase A 的“切换”只用于本机验收：**不**把 `conversations`/`messages`/`memories`/`affinities` 等用户数据改成复合键，**不**新增 `conversation_participants`/`messages.speaker`。
6. Phase A 结束后必须进入 Phase B：ADR-0037 的 v24 复合身份迁移、跨包隔离、删除/恢复与检索作用域；在 Phase B 完成前，不把多包切换作为正常发布的默认行为。

## 后果

- 两天内可以验证 SC 回归、Sakura 内容包、MLTD/Haruka model3d 接缝，而不把 v24 迁移塞进同一刀。
- 用户库仍是单 active franchise 的裸 id 语义；切换包只用于验证，不能承诺跨包数据隔离。Sakura/SC 当前 local id 不同，验证路径安全；将来若两个包 local id 重叠，Phase B 之前不得同时启用。
- 包根、kind、相对 symlink 与 manifest 路由成为 Phase B 的稳定前置；Phase B 不再重写这些接缝。
- ADR-0035 的后果段落中“S1 只预留、不实现多包 registry”被本 ADR 的 Phase A 局部覆盖；S1 的运行时/内容契约本身不变。

## 考虑过的选项

- **先做完整 v24 再验包**：安全但把两天目标拖成数周，无法尽早暴露外部包格式问题。
- **直接共享单 `current/`**：最小改动，但第二个包会覆盖第一个，且 local id 冲突不可恢复。
- **按引擎族做 franchise**：会让同引擎多作品撞 local id；Phase A 明确按作品取 franchise，engine 另存 `engineFamily`。
