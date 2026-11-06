#!/bin/sh
# 在 NAS 上构建并启动服务（spec #120）。只碰 docker，不传文件：
#
# 构建一律走这条（或在 NAS 上手动 `docker compose up -d --build`）。Container Manager
# 的「项目 → 构建」用的是它自己建项目时拷的一份副本，推上去的新代码进不了镜像。
# 传文件用 tools/upload_server.sh，或者直接推 build/ 里的包。
#
#   tools/build_server.sh
#   tools/build_server.sh 用户@主机 /部署目录
set -eu

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

if [ $# -ge 1 ]; then HOST=$1; fi
if [ $# -ge 2 ]; then DIR=$2; fi

echo "→ 在 $HOST 上构建并启动"
ssh -o BatchMode=no -t "$HOST" \
  "sudo bash -lc \"cd '$DIR/server' && docker compose up -d --build\""

echo "→ 探活（容器刚起来，给它 20 秒）"
attempt=1
while [ "$attempt" -le 20 ]; do
  if ssh "$HOST" "bash -lc 'curl -fsS http://127.0.0.1:$PORT/v1/health'" 2>/dev/null; then
    echo
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 1
done

echo "还是不通，上去看日志：ssh -t $HOST 'sudo bash -lc \"cd $DIR/server && docker compose logs --tail 50\"'" >&2
exit 1
