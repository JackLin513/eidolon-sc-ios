# 立绘包：全量衣装、拆包与增量更新

设计于 2026-10-28，已实现。目标是把端上立绘从「每个角色前 3 张卡」扩到上游全量，并把立绘素材从内容包里拆出来，使剧情更新不必重传 GB 级素材。决策记录见 [ADR-0020](../adr/0020-stand-bundles-split-and-incremental.md)。

## 背景

- 端上现在的立绘是内容包里的 `stand/` 树。导出工具默认 `--stand-cards 3`，所以每个角色只有 3 张卡（每张卡有私服/演出两套，最多 6 套衣装）。
- 上游的换衣装列表是全部卡（1522 张卡、2034 套衣装、29 个角色），素材按需从存储桶下载。端上离线，不能照搬。
- 设置里的「立绘预览」是本仓库的调试页（#30/#31），固定载入默认衣装；上游没有这个页面。
- 素材现状：`build/stand` 2.5 GB，2034 套全部完整；全量打进内容包不现实，尤其是每更新一次剧情都要重传。
- 现有的全量内容包约 118 MB，其中立绘解压后约 175 MB；去掉立绘后故事内容很小。

## 目标

1. 立绘数据与上游全量对齐：29 个角色、1522 张卡、2034 套衣装。
2. 内容包与立绘包分开：第一次传全量立绘，之后剧情更新只传小内容包；立绘追加只传增量。
3. 设置里的立绘预览可以换衣装，行为和通话页的换衣装一致。
4. 导入大立绘包时有可见进度、不会因锁屏中断，失败保留上一份。
5. 不引入运行时 HTTP 服务；复用现有 `devicectl` 通道和离线文件。

## 非目标

- 不在这一版做「从上游 CDN 按需下载衣装」；离线包模型保持不变。
- 不在这一版把上游缩略图打进包；先端上生成，实测 62 张卡的手感后再决定。
- 不为立绘包加 HTTP endpoint。
- 不自动删除上游已经下架的衣装文件（保留无害，列表会不再引用）。

## 领域词汇

新增/调整的术语写进 [GLOSSARY.md](../../GLOSSARY.md)：

- **内容包**：只读的故事内容归档（内容库、角色、世界设定、节假日）。
- **立绘包**：单独导入的只读立绘归档；有全量和增量两种。
- **全量立绘包**：包含所选角色的全部立绘素材、衣装清单和角色映射。
- **增量立绘包**：只含本机还没有/已变化的素材和更新后的衣装清单；导入时合并。
- **立绘清单**：本机已安装的衣装编号、文件大小与校验值；用来生成增量包。不是上游的「衣装清单」（卡片列表）。
- **立绘目录**：手机端保存立绘包内容的目录，和内容包的 `current` 分开。
- **衣装卡**：原作里的一张卡，带私服和/或演出服；换衣装列表按卡排列。

## 已定决策

| # | 决策 |
|---|---|
| D1 | 立绘采用上游全量：29 个角色、1522 张卡、2034 套衣装，不按 3 张卡截取。 |
| D2 | 内容包与立绘包拆开；内容包永远不带立绘素材。 |
| D3 | 设置里两个明确入口：「剧情内容」和「立绘素材」，各自独立、顺序随意、互不覆盖。 |
| D4 | 立绘包默认全量；导出工具保留 `--stand-cards N` 作为缩小选项。 |
| D5 | 立绘支持增量：App 维护立绘清单，导出工具只打缺失/变更的素材。 |
| D6 | 清单通过 `stand-index.json` 提供；导出工具 `--device` 用 `devicectl` 自动拉取，`--have` 作为手动回退。 |
| D7 | 设置预览复用通话页的 `OutfitPickerView`：点卡片只预览，「穿这套」才持久化。 |
| D8 | 设置预览换装后保留当前动作/情绪；新衣装载入完成后重新应用当前立绘指令。 |
| D9 | 升级时自动把现有 `current/stand` 迁移到独立立绘目录；旧 3 张卡继续可用。 |
| D10 | 缩略图先保持端上生成（懒加载 + 缓存）；62 张卡的实测手感决定是否再做打包缩略图。 |
| D11 | 导入加进度、防锁屏、清理临时包；GB 级包允许几分钟的导入时间。 |
| D12 | 不做手机上的 HTTP 接口。 |

## 数据与包格式

### 内容包

- 沿用现有 `.eidolonpkg` 格式（format 2）；manifest 新增可选的 `kind: "content"`，旧包没有这个字段也照常导入。App 的两个导入入口仍然区分内容包和立绘包。
- 不再包含 `stand/` 素材；`characters.json` 不再依赖 `stand` 字段。
- 内容包继续原子替换：`Content/current`，失败保留 `Content/previous`。
- 剧情更新仍然全量导入，但不再包含立绘，体积回到很小。

### 立绘包

- 同样是 zip，建议沿用 `.eidolonpkg` 扩展名；manifest 带 `kind: "stand"`、`mode: "full" | "delta"`、`format_version`、`files`（大小 + CRC32/哈希）。
- 包内布局：
  ```text
  manifest.json         # kind/mode、角色 id → 默认衣装/衣装清单、文件大小/CRC
  stand/outfits/<idol_id>.json
  stand/idols/<outfit_id>/{data.json,data.atlas,data.png}
  ```
- 全量包包含全部角色；增量包只含新增/变更的 outfit 文件，但带上 `stand/outfits/*.json` 和 manifest 里的角色映射，保证卡片/默认衣装的变化能被看到。`index.json` 由 App 在安装后生成，不要求包自带。
- 立绘包不包含内容库，不依赖 App 的剧情 schema。

### 立绘目录

- `Content/stand/`：
  ```text
  manifest.json
  stand/outfits/
  stand/idols/
  index.json            # App 生成的已安装文件大小/CRC
  ```
- `Content/stand-previous/` 只用于全量包导入的失败回滚；增量包不复制整个目录。
- 旧版把立绘放在 `Content/current/stand/`；迁移后 `Content/current` 不再持有立绘。

### 角色与立绘的关联

- 立绘包 manifest 的 `characters` 是「角色 → 默认衣装 / 衣装清单」的唯一来源；故事包的 `characters.json` 不需要保留 `stand` 字段。
- `Eidolon.stand(for:)` 先查立绘目录，再回退到旧内容包里的 `stand`（legacy）。
- 设置预览的角色筛选、通话页的立绘加载都走同一个查找，不再依赖 `CharacterConfig.stand`。

## 导入

### 内容包

- 现有流程不变，但不再校验/携带 `stand/` 素材。
- 导入完成后 `Content/current` 替换；`Content/stand` 不受影响。

### 全量立绘包

- 解压到 `Content/stand/.staging`；校验 manifest、文件大小、CRC32。
- 校验通过后替换 `Content/stand`，旧的移到 `previous`；失败保留旧目录。
- 更新立绘清单（`index.json`）。

### 增量立绘包

- 解压到临时目录；校验每个新文件。
- 新/变更的 outfit 文件按路径移入 `Content/stand/stand/idols/`；未变更的素材不在包内，已有的旧衣装保留。
- `stand/outfits/*.json`、manifest 和 `index.json` 用原子替换写入；列表更新失败时保留旧列表。
- 不删除已有衣装；新目录先落盘、后改列表，失败时最多留下不会被列表引用的孤儿文件，重试即可。
- 增量包可以更新已存在 outfit 的素材（按大小/CRC 判断变化）；上游的 outfit 编号稳定，变更时保留同一编号。

### 进度与资源

- `ContentBundleInstaller` 提供字节/文件进度回调；导入页显示进度条。
- 导入期间禁用系统自动锁屏；App 进入后台时提示需要保持前台。
- 导入完成删除临时拷贝；如果 `.eidolonpkg` 还在 App Documents，设置里提供清理入口/提示。
- 实测全量包 586.9 MB（原始素材 2.5 GB）；解压后约 2.4 GB，逐文件 CRC 约 1–2 分钟，峰值磁盘约 3 GB。

## 增量流程

1. Mac 上先跑上游的 `eidolon stand fetch` / `eidolon stand outfits`，把新素材拉到 `build/stand`。
2. 手机上 App 已有立绘清单（`Content/stand/index.json`），设置里可以分享/导出这份 JSON。
3. 导出工具：
   ```sh
   # 立绘全量包（第一次）
   ... export_content_bundle.py --stand build/stand --stand-all-outfits \
       --out build/eidolon-stand.eidolonpkg

   # 立绘增量包：自动从设备读清单
   ... export_content_bundle.py --stand build/stand --stand-all-outfits \
       --device <UDID> --out build/eidolon-stand-add.eidolonpkg

   # 没有连接设备时用文件
   ... export_content_bundle.py --stand build/stand --stand-all-outfits \
       --have stand-index.json --out build/eidolon-stand-add.eidolonpkg

   # 剧情包：不带 --stand
   ... export_content_bundle.py --upstream .. --db data/eidolon.db --characters ../characters \
       --out build/eidolon-content.eidolonpkg
   ```
4. `--device` 用 `xcrun devicectl device copy from` 把 `Content/stand/index.json` 拉到 Mac；没有设备时用 `--have`。
5. 导出工具按 outfit 编号 + 大小/校验值比较，只把缺失/变更的素材和更新后的列表打进增量包。
6. 手机上导入增量包；旧衣装和用户选择保持不变。

## App 端行为

### 设置

- 「剧情内容」：导入/替换内容包，显示剧情/段落/角色数、安装时间。
- 「立绘素材」：导入全量或增量立绘包，显示已安装角色/衣装数、包类型、最近导入时间；提供「导出立绘清单」。
- 「立绘预览」：保留，作为调试页；复用通话页的 `OutfitPickerView` 换衣装。
- 导入进度、失败原因、保留上一份的提示和现在一致，只是增加进度。

### 设置预览换衣装

- 进入预览时加载 `CharacterStand`；工具栏加「换衣装」按钮，打开 `OutfitPickerView`。
- 点卡片只改预览；「穿这套」写入 `StandOutfitChoiceStore`、重新载入预览的 renderer。
- 换装完成后重新应用当前 `StandDirector` 的 direction（情绪、说话、看镜头、点头、通话结束状态），不回到平静。
- 角色切换仍走现有菜单；新角色加载其记住的衣装或默认衣装。
- 没有立绘清单/素材时回退默认衣装，和通话页一致。

### 通话

- 不改变现有布局和交互；`CharacterStand` 从立绘目录读，列表可能从 3 张卡变成最多 62 张。
- 缩略图仍由 `OutfitThumbnailStore` 按需生成；`LazyVGrid` 只请求可见卡片。
- 已选衣装、默认衣装回退、加载失败回退都不变。

## 迁移

- App 启动时：
  1. 若 `Content/stand` 不存在、`Content/current/stand` 存在，把旧目录搬到 `Content/stand/stand/`。
  2. 从旧 `characters.json` 的 `stand` 字段生成 `Content/stand/manifest.json` 和 `index.json`。
  3. 迁移失败时保留旧内容包里的立绘，走 legacy 查找；不阻塞启动。
- 迁移后第一次导入不带立绘的内容包不会丢立绘；全量/增量立绘包导入后再替换/合并。
- 旧的全量内容包（内容 + 立绘）仍可导入：识别为 legacy，立绘作为迁移来源。

## 缩略图与性能

- 62 张卡的 `LazyVGrid` 首屏约 9 张；当前串行缩略图每张约 0.4 秒 + 载入，首屏可能要几秒。
- 先按 D10 端上生成；缓存按衣装编号 + 内容包版本，滚动回来不再重画。
- 如果实测首屏超过约 3–5 秒或滚动明显卡顿，再评估：
  - 把上游缩略图抓进立绘包（新增抓取/导出步骤）；
  - 或在导入时后台预生成可见卡片缩略图。
- 不因为 62 张卡就改成分页/搜索；上游就是按清单顺序列全部卡。

## 风险与代价

- **导入**：全量包 586.9 MB，解压后约 2.4 GB；6000 多个文件 CRC，约 1–2 分钟；峰值磁盘约 3 GB；手机需保持前台。
- **首屏**：62 张卡的缩略图首次打开偏慢；缓存后正常。
- **格式/代码**：两个 manifest 类型、两个导入入口、独立立绘目录、增量合并、迁移，都比单包复杂。
- **增量一致性**：增量包依赖手机清单；清单过期/设备不同步时可能漏文件，回退全量。
- **ZIP**：全量包目前 586.9 MB，离 ZIP32 上限还远；超过 4 GB 时再转 ZIP64。
- **兼容**：旧 all-in-one 内容包要能继续读；迁移失败不能丢立绘。

## 验收

- 在 iPhone Air 上导入内容包 + 全量立绘包：设置显示 29 个角色、2034 套；打开一个有 62 张卡的角色，换装、打电话确认穿着。
- 更新内容包但不导入立绘包：立绘仍在，选择仍在。
- 新增一套衣装：导出全量/增量的差异只包含新素材；导入增量包后旧衣装和选择不变。
- 现有 3 张卡设备升级后立绘不消失；迁移后第一次内容包更新不丢立绘。
- 导入全量包时进度可见、不锁屏、失败保留上一份。
- 导出工具单测：全量/增量/`--have`/`--device` 路径；Core 测试：两个根、全量替换、增量合并、迁移、清单；Air 实机验收。

## 留给 spec 的实现细节

- 实际 manifest schema、`format_version`、`kind`/`mode` 的最终字段名，以及旧 v2 包的兼容方式。
- 立绘包 manifest 的 `characters` 与 `index.json` 的精确结构；哈希用 CRC32 还是更强的校验。
- 增量合并的原子性/回滚实现；全量包是否也允许合并（建议全量替换）。
- 导入进度的粒度和取消行为；临时包清理入口的位置。
- 缩略图性能阈值与回退方案的触发条件。
- `Eidolon.stand(for:)` 和 `CharacterConfig.stand` 的最终迁移路径；旧包 fallback 的保留时长。
