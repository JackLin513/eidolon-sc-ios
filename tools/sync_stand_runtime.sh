#!/bin/sh
# Copy the official Spine 3.6 WebGL runtime out of the upstream checkout into the app's
# resources (ADR-0017). The runtime is third-party code and never enters this repository;
# her outfits travel in the separate stand bundle instead (ADR-0020).
#
#   sync_stand_runtime.sh <destination-directory> [upstream-checkout]
#
# The checkout defaults to ../eidolon-sc next to this repository, or to $EIDOLON_UPSTREAM.
# When the checkout or the runtime is missing, this prints a warning and succeeds: the app
# builds and runs without a stand.
set -eu

destination="${1:?用法: sync_stand_runtime.sh <目标资源目录> [上游 checkout 路径]}"
upstream="${2:-${EIDOLON_UPSTREAM:-../eidolon-sc}}"
runtime="$upstream/frontend/public/vendor/spine-3.6/spine-webgl.js"

if [ ! -f "$runtime" ]; then
  echo "warning: 没有找到 ${runtime}；本次构建不带 Spine 运行时，App 里没有立绘。" >&2
  exit 0
fi

mkdir -p "$destination"
cp "$runtime" "$destination/spine-webgl.js"
echo "note: 已同步 Spine 运行时 ${runtime} → $destination/spine-webgl.js"
