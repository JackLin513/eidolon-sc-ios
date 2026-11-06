#!/bin/sh
# 把导出的内容包传到 NAS 上的服务器目录（spec #120）。和部署分开：服务器已经在跑的时候，
# 单独跑这个脚本换一份包。
#
#   tools/upload_packages.sh                      # 传 build/ 里全部 .eidolonpkg
#   tools/upload_packages.sh build/eidolon-content.eidolonpkg
#   tools/upload_packages.sh --scan               # 传完顺带登记一次
#
# 断了可以重来：脚本按远端已有的字节数接着传（从断点往后追加），最后核对两边大小。
set -eu

SCAN=no
FILES=""

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# 部署目标放你自己的 tools/deploy.env 里（那个文件不进仓库），也可以用环境变量给。
if [ -f "$ROOT/tools/deploy.env" ]; then
  . "$ROOT/tools/deploy.env"
fi
HOST=${EIDOLON_SERVER_HOST:-}
DIR=${EIDOLON_SERVER_DIR:-}
PORT=${EIDOLON_SERVER_PORT:-2830}
if [ -z "$HOST" ] || [ -z "$DIR" ]; then
  echo "先抄一份 tools/deploy.env.example 成 tools/deploy.env，填好主机和部署目录；" >&2
  echo "或者直接给环境变量 EIDOLON_SERVER_HOST=用户@主机 EIDOLON_SERVER_DIR=/路径。" >&2
  exit 2
fi


for argument in "$@"; do
  case "$argument" in
    --scan) SCAN=yes ;;
    --*) echo "不认识的参数：$argument" >&2; exit 2 ;;
    *) FILES="$FILES $argument" ;;
  esac
done

if [ -z "$FILES" ]; then
  for bundle in "$ROOT"/build/*.eidolonpkg; do
    [ -e "$bundle" ] || continue
    FILES="$FILES $bundle"
  done
fi

if [ -z "$FILES" ]; then
  echo "build/ 里没有 .eidolonpkg" >&2
  exit 1
fi

ssh -o BatchMode=no "$HOST" "mkdir -p '$DIR/server/data/packages'"

for source in $FILES; do
  name=$(basename "${source}")
  target="$DIR/server/data/packages/${name}"
  total=$(wc -c < "${source}" | tr -d ' ')
  have=$(ssh "$HOST" "test -f '${target}' && wc -c < '${target}' || echo 0" | tr -d ' ')

  if [ "${have}" -eq "${total}" ]; then
    echo "= ${name} 已经在服务器上（$(du -m "${source}" | cut -f1) MB），跳过"
    continue
  fi
  if [ "${have}" -gt "${total}" ]; then
    echo "! ${name} 服务器上那份比本地大，从头重传"
    have=0
    ssh "$HOST" ": > '${target}'"
  fi

  if [ "${have}" -gt 0 ]; then
    echo "→ ${name} 从 $((have / 1048576)) MB 处接着传（共 $((total / 1048576)) MB）"
    tail -c +$((have + 1)) "${source}" | ssh -o BatchMode=no "$HOST" "cat >> '${target}'"
  else
    echo "→ ${name}（$((total / 1048576)) MB）"
    ssh -o BatchMode=no "$HOST" "cat > '${target}'" < "${source}"
  fi

  landed=$(ssh "$HOST" "wc -c < '${target}'" | tr -d ' ')
  if [ "${landed}" -ne "${total}" ]; then
    echo "✗ ${name} 传完是 ${landed} 字节，本地是 ${total}；再跑一次会接着传" >&2
    exit 1
  fi
  echo "✓ ${name}"
done

if [ "$SCAN" = yes ]; then
  echo "→ 登记"
  ssh -o BatchMode=no -t "$HOST" \
    "sudo bash -lc \"cd '$DIR/server' && docker compose exec -T eidolon-server python -m eidolon_server scan /data/packages\""
fi
