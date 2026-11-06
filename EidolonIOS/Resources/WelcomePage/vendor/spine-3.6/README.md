# Spine Runtimes 3.6（spine-ts WebGL）

这个目录里的 `spine-webgl.js` 和 `LICENSE` 是 Esoteric Software 的 Spine Runtimes，原样取自官方仓库，**一个字都没有改**。它们不属于本项目，**不受本项目的 AGPL-3.0-or-later 约束**，适用的是同目录下它自己的 `LICENSE`（Spine Runtimes Software License v2.5）。本项目许可证里的附加许可允许两者组合在一起、一起分发（见仓库根目录的 `LICENSING.md` 和 ADR-0009）。

| 文件 | 来源 | SHA-256 |
|---|---|---|
| `spine-webgl.js` | `spine-ts/build/spine-webgl.js` | `2883daee81ae60b25f6205b83feb82b76812bf63cfdf0886f04f390b12891794` |
| `LICENSE` | `spine-ts/LICENSE` | `d2af98ecac7e4bb6e4c4491fc734db7762b94626b18bcc87c7eac6febd86e1b5` |

- 仓库：<https://github.com/EsotericSoftware/spine-runtimes>，分支 `3.6`，提交 `654c20e5b0e523040b6366bbd1042510d2645134`（2019-05-13，这个分支的最后一次提交，之后不会再有修复）。
- 版本：3.6，能读原作立绘导出的 3.6.53 数据。
- 取得方式：`https://raw.githubusercontent.com/EsotericSoftware/spine-runtimes/3.6/spine-ts/build/spine-webgl.js`（`LICENSE` 同理），2026-10-01 下载，校验和与调研时（ShinyColorsPet 的 THIRD_PARTY_NOTICES）记下的一致。

**使用方式**：页面用 `<script>` 在客户端加载 `/vendor/spine-3.6/spine-webgl.js`，代码通过 `window.spine` 调用（`frontend/src/components/conversations/stand/spineRuntime.ts`）。不要改这个文件，也不要加 `export`；runtime 的已知问题（例如剪裁的结束插槽为空时剪裁不结束）在调用方绕开。

`.gitattributes` 把这个目录标成 `-text`，换行符不会被转换，校验和保持不变。核对：

```sh
sha256sum frontend/public/vendor/spine-3.6/spine-webgl.js frontend/public/vendor/spine-3.6/LICENSE
```
