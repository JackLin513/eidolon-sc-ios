#!/bin/sh
# 酒吧素材包的 Mac 入口（docs/design/bar-room.md）：默认路径就是 README 里的那套。
#
#     tools/export_bar_bundle.sh --out build/eidolon-bar.eidolonpkg
#
# 画面和字体从 $EIDOLON_UPSTREAM/frontend/public/bar/ 读，音频从
# $EIDOLON_BAR_AUDIO（原版提取目录的 audio/）读；没设音频路径时出一个只有画面和字体的包。
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
upstream=${EIDOLON_UPSTREAM:-$root/../eidolon-sc}

set -- --upstream "$upstream" "$@"
if [ -n "${EIDOLON_BAR_AUDIO:-}" ]; then
	set -- "$@" --audio "$EIDOLON_BAR_AUDIO"
fi
exec python3 "$here/export_bar_bundle.py" "$@"
