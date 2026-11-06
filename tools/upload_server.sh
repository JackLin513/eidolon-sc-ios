#!/bin/sh
# 把 server/ 整个目录传到 NAS 上的部署目录（spec #120）。只传文件，不碰 docker 和 sudo：
# 构建交给 tools/build_server.sh，或者 Container Manager 的「项目」页。
#
#   tools/upload_server.sh                  # 只传服务端代码（很快）
#   tools/upload_server.sh --with-packages  # 顺带把 build/*.eidolonpkg 放进 data/packages
#   tools/upload_server.sh 用户@主机 /部署目录
#
# 部署目标（主机、目录、端口）从 tools/deploy.env 或环境变量来，脚本里没有默认值：
# 这是你自己的机器，不该写在仓库里。管理员账号在远端的 docker-compose.override.yml 里，
# 那个文件不上传、不覆盖，远端没有时脚本照 .example 抄一份并停下来让你填。
#
# 为什么不用 rsync / scp：macOS 自带的 rsync 是 openrsync，跟这台 NAS 的 sshd 握手不过；
# scp 走 SFTP 子系统，DSM 上通常是关着的。只靠一个 shell 的 tar 管道两边都能用。
set -eu

WITH_PACKAGES=no
POSITIONAL=""

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# 部署目标放你自己的 tools/deploy.env 里（那个文件不进仓库），也可以用环境变量给。
if [ -f "$ROOT/tools/deploy.env" ]; then
  . "$ROOT/tools/deploy.env"
fi
HOST=${EIDOLON_SERVER_HOST:-}
DIR=${EIDOLON_SERVER_DIR:-}
if [ -z "$HOST" ] || [ -z "$DIR" ]; then
  echo "先抄一份 tools/deploy.env.example 成 tools/deploy.env，填好主机和部署目录；" >&2
  echo "或者直接给环境变量 EIDOLON_SERVER_HOST=用户@主机 EIDOLON_SERVER_DIR=/路径。" >&2
  exit 2
fi


for argument in "$@"; do
  case "$argument" in
    --with-packages) WITH_PACKAGES=yes ;;
    --*) echo "不认识的参数：$argument" >&2; exit 2 ;;
    *) POSITIONAL="$POSITIONAL $argument" ;;
  esac
done

if [ -n "$POSITIONAL" ]; then
  set -- $POSITIONAL
  HOST=$1
  if [ $# -ge 2 ]; then DIR=$2; fi
fi

echo "→ 推 server/ 到 $HOST:$DIR/server"
COPYFILE_DISABLE=1 tar czf - -C "$ROOT/server" --no-xattrs \
  --exclude .venv --exclude data --exclude __pycache__ \
  --exclude .pytest_cache --exclude docker-compose.override.yml --exclude tests \
  . | ssh -o BatchMode=no "$HOST" "mkdir -p '$DIR/server/data/packages' && tar xzf - -C '$DIR/server'"

if ! ssh "$HOST" "test -f '$DIR/server/docker-compose.override.yml'"; then
  ssh "$HOST" "cp '$DIR/server/docker-compose.override.yml.example' '$DIR/server/docker-compose.override.yml'"
  echo "远端还没有 docker-compose.override.yml，已经照 .example 抄了一份："
  echo "  ssh -t $HOST \"vi $DIR/server/docker-compose.override.yml\"   # 填管理员用户名和密码"
  echo "改完再跑一次这个脚本。"
  exit 0
fi

if [ "$WITH_PACKAGES" = yes ]; then
  echo "→ 传内容包"
  for bundle in "$ROOT"/build/*.eidolonpkg; do
    [ -e "${bundle}" ] || continue
    name=$(basename "${bundle}")
    total=$(wc -c < "${bundle}" | tr -d ' ')
    have=$(ssh "$HOST" "test -f '$DIR/server/data/packages/${name}' && wc -c < '$DIR/server/data/packages/${name}' || echo 0" | tr -d ' ')
    if [ "${have}" -eq "${total}" ]; then
      echo "= ${name} 已经在服务器上"
      continue
    fi
    [ "${have}" -gt "${total}" ] && { have=0; ssh "$HOST" ": > '$DIR/server/data/packages/${name}'"; }
    if [ "${have}" -gt 0 ]; then
      echo "→ ${name} 从 $((have / 1048576)) MB 处接着传（共 $((total / 1048576)) MB）"
      tail -c +$((have + 1)) "${bundle}" | ssh -o BatchMode=no "$HOST" "cat >> '$DIR/server/data/packages/${name}'"
    else
      echo "→ ${name}（$((total / 1048576)) MB）"
      ssh -o BatchMode=no "$HOST" "cat > '$DIR/server/data/packages/${name}'" < "${bundle}"
    fi
  done
fi

echo "✓ 文件都在 $HOST:$DIR/server"
