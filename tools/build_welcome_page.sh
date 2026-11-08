#!/bin/sh
# 把 welcome/ 构建成 App 里的静态页（spec #118）：产物进 EidolonIOS/Resources/WelcomePage，
# 和立绘运行时一样随 App 打包，运行时不开网络。
#
#   tools/sync_welcome_page.sh    # 先同步上游源码（改了上游才需要）
#   tools/build_welcome_page.sh   # 构建并拷进 Resources
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/EidolonIOS/Resources/WelcomePage"

cd "$ROOT/welcome"
[ -d node_modules ] || npm install --no-fund --no-audit
npm run build

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R dist/. "$DEST"
UPSTREAM_COMMIT=$(cat "$ROOT/welcome/UPSTREAM" 2>/dev/null || echo "?")
echo "✓ 欢迎页构建到 ${DEST}（上游 ${UPSTREAM_COMMIT}）"
