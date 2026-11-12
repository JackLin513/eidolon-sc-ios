# ADR-0038：立绘包按企划归属，不再保留全局 stand

日期：2026-11-12
状态：已接受

## 背景

ADR-0036 的 Phase A 先让内容包按 `Content/<franchise>/current` 分开，但 Spine 立绘包仍留在 `Content/stand`，`stand.bundle` 也是全局 app_state。结果是切到 Sakura 后，设置页仍显示 SC 的立绘包；静态立绘包则已经按 `Content/<franchise>/static-stand` 存放，两个立绘入口语义不一致。

## 决定

1. **Spine 立绘包**存到 `Content/<franchise>/stand`；`StandBundleInfo` 存到 `stand.bundle.<franchise>`。
2. **静态立绘包**继续存到 `Content/<franchise>/static-stand`；两者的 `contentSetID` 都只对当前内容包绑定。
3. 删除 `Location.standDirectory` 这个全局路径接口；所有读取走 active franchise（`Eidolon.standDirectory`），安装可显式传 franchise。
4. 老数据只做一次性迁移，不保留兼容接口：
   - `Content/stand` → `Content/shiny/stand`
   - `stand.bundle` → `stand.bundle.shiny`
   - 老内容包内部的 `Content/current/stand` → `Content/shiny/stand`
5. 切换内容包时清空 `cachedStandConfigs`，避免旧企划的立绘图谱泄漏到新企划。
6. 设置页把 Spine 与静态立绘都按当前内容包显示；旧的全局 stand 不再作为可读接口。

## 后果

- 切到 Sakura 时 `standInfo` 为空，设置页只显示 Sakura 的静态立绘包与绑定，不再显示 SC 的角色/衣装数。
- 旧 iPhone 数据第一次启动时自动迁移；迁移只在目标不存在时执行，失败时保留原目录。
- 没有 `Content/stand` 全局路径后，以后新增企划的立绘只需按 franchise 放包，不必再改全局路径。
- 这是一次性迁移；不保留“全局 stand 仍可读”的 fallback，避免新代码继续依赖历史接口。

## 考虑过的选项

- **保留 `Content/stand` 软链到 active stand**：能兼容旧代码，但会留下第二套接口，切包时容易指错；不采用。
- **只改设置显示、不改存储**：改动最小，但问题会留在数据层；不采用。
