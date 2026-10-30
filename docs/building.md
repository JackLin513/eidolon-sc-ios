# 构建与安装

把仓库变成手机上能跑的东西：先导出内容包与立绘包，再生成工程、构建、导入、填密钥。

> 密钥只用于本地验证时，从上游 checkout 的 `.env` 读取，不要写进仓库、提交或 issue。

## 跑起来

1. **准备内容包与立绘包**（Mac，一次性）：

   剧情内容包不带立绘：

   ```sh
   cd ../eidolon-sc/backend
   uv run --env-file=../.env python ../../eidolon-sc-ios/tools/export_content_bundle.py \
     --upstream .. --db data/eidolon.db --characters ../characters \
     --out ../../eidolon-sc-ios/build/eidolon-content.eidolonpkg
   ```

   立绘包先用上游的 `eidolon stand fetch` 和 `eidolon stand outfits` 把素材整理到
   `build/stand`（`EIDOLON_STAND_BUILD_PATH` 指到这里），再单独导出。立绘包默认全量：

   ```sh
   uv run --env-file=../.env python ../../eidolon-sc-ios/tools/export_content_bundle.py \
     --upstream .. --characters ../characters --stand ../../eidolon-sc-ios/build/stand \
     --stand-only --stand-all-outfits \
     --out ../../eidolon-sc-ios/build/eidolon-stand.eidolonpkg
   ```

   全量立绘包实测 29 个角色、6131 个文件、586.9 MB（原始素材约 2.5 GB）。只用前几张卡时加
   `--stand-cards N`。立绘有新增时，先重新同步 `build/stand`，再用手机导出的清单只打增量：

   ```sh
   # 自动从连接的 iPhone 读清单（推荐；没有设备时用 --have stand-index.json）
   uv run --env-file=../.env python ../../eidolon-sc-ios/tools/export_content_bundle.py \
     --upstream .. --characters ../characters --stand ../../eidolon-sc-ios/build/stand \
     --stand-only --stand-all-outfits --device <UDID> \
     --out ../../eidolon-sc-ios/build/eidolon-stand-add.eidolonpkg
   ```

   没有偶像编号、默认衣装或素材的角色跳过（同步还没跑完也能导出）。素材同步是一次一个请求、每秒一个，
   全量要一两个小时；中断后重跑会接着拉。macOS 的系统代理会影响 Python 的 `urllib`，必要时用
   `env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy NO_PROXY='*' no_proxy='*'` 绕开。

2. **生成并打开工程**：

   ```sh
   brew install xcodegen   # 只需一次
   xcodegen generate
   open EidolonIOS.xcodeproj
   ```

   构建时 `tools/sync_stand_runtime.sh` 从上游 checkout（默认 `../eidolon-sc`，可用 `EIDOLON_UPSTREAM` 指定）把 `spine-webgl.js` 拷进 App 资源。运行时是第三方代码，不进仓库；没有 checkout 或运行时缺失时脚本只打印一条警告，App 照常编译，只是立绘显示「没有立绘」。

3. **运行**：选一个 iPhone 模拟器，首次启动点「选择内容包」导入内容包；再在设置 →「立绘包」导入立绘包（全量一次，之后可导入增量包）。然后在设置里填对话模型、向量化/重排，以及通话用的 Soniox 与 Fish Audio 密钥（密钥存钥匙串）。

4. **上真机（可选）**：

   ```sh
   xcodebuild -project EidolonIOS.xcodeproj -scheme EidolonIOS -configuration Debug \
     -destination 'platform=iOS,id=<UDID>' -derivedDataPath build/DerivedData \
     -clonedSourcePackagesDirPath build/DerivedData/SourcePackages \
     -onlyUsePackageVersionsFromResolvedFile build
   xcrun devicectl device install app --device <UDID> \
     build/DerivedData/Build/Products/Debug-iphoneos/Eidolon.app
   xcrun devicectl device copy to --device <UDID> --domain-type appDataContainer \
     --domain-identifier com.jacklin.eidolon --destination Documents/你的内容包.eidolonpkg \
     --source build/eidolon-content.eidolonpkg
   xcrun devicectl device copy to --device <UDID> --domain-type appDataContainer \
     --domain-identifier com.jacklin.eidolon --destination Documents/你的立绘包.eidolonpkg \
     --source build/eidolon-stand.eidolonpkg
   xcrun devicectl device process launch --device <UDID> \
     -e '{"EIDOLON_IMPORT_BUNDLE":"你的内容包.eidolonpkg","EIDOLON_IMPORT_STAND_BUNDLE":"你的立绘包.eidolonpkg"}' \
     com.jacklin.eidolon
   ```

   自动签名要求 Xcode 里登录了开发者账号；没有账号时可以先无签名构建、再用设备上已有的描述文件手工 `codesign`。

5. **通话**：在角色聊天页右上角点电话按钮（模拟器第一次用麦克风时，Mac 会要求给 **Simulator** 麦克风权限：系统设置 → 隐私与安全性 → 麦克风；另外确认 Simulator 菜单 I/O → Audio Input 选的是内置麦克风而不是 None）。接通是静默的——她不会先说话；对着麦克风说一句（中文或日文都行），停一下等句末判定，她就按回合回答。首次通话会请求麦克风权限。
