# 私有服务（spec #120）

只服务自己人的一台小服务：邀请码注册、令牌登录、内容包下载（支持断点续传）、公告。
手机上不登录也能用，这里只解决「包从哪来」和「公告在哪看」。

这个目录是**自包含的**：`docker compose up -d --build` 只要它自己，不需要仓库的其它部分，也不需要 Python 环境。
放到任何一台常开的机器上都能跑；仓库根目录那几个 `tools/*_server.sh` 只是给维护者自己用的传输脚本。

放服务器上怎么部署、怎么升级、日志和备份在哪，见 [docs/server.md](../docs/server.md)。下面是本机开发时怎么跑。

## 自己部署一份

```sh
cp docker-compose.override.yml.example docker-compose.override.yml   # 改成你自己的管理员账号
docker compose up -d --build
```

端口、数据目录、项目名都能用环境变量改，见 `docker-compose.yml` 顶部。对外只走反向代理和证书。
App 里「设置 → 账号」填 `https://你的域名` 就能连上；不连它，对话、记忆、通话照旧能用。

## 跑起来

```sh
# 本机
python3 -m venv .venv && ./.venv/bin/pip install -r requirements-dev.txt
EIDOLON_SERVER_DB=data/eidolon.sqlite3 EIDOLON_SERVER_PACKAGES=data/packages \
  ./.venv/bin/uvicorn eidolon_server.asgi:app --port 9090

# 容器
docker build -t eidolon-server .
docker run -d --name eidolon-server -p 2830:9090 -v /你的数据目录:/data eidolon-server
```

前面挂反向代理和证书走 HTTPS；容器只暴露一个端口。

管理员不用先去注册：在同目录写一个 `docker-compose.override.yml`（照 `.example` 抄），服务第一次起来会把账号建好、角色设成 admin。本机直接跑时也可以给环境变量：

```sh
EIDOLON_SERVER_ADMIN_USER=你的用户名 \
EIDOLON_SERVER_ADMIN_PASSWORD=至少八位 \
  ./.venv/bin/uvicorn eidolon_server.asgi:app --port 9090
```

已经在的账号只会升角色，不会覆盖密码。

## 维护命令

```sh
python -m eidolon_server invite --days 7      # 生成邀请码
python -m eidolon_server invites              # 看邀请码用没用
python -m eidolon_server password <用户名>     # 重设密码（旧令牌一起作废）
python -m eidolon_server announcement <标题>   # 正文从标准输入读
python -m eidolon_server scan <目录>           # 登记导出好的 .eidolonpkg
python -m eidolon_server admin <用户名>        # 建管理员 / 升成管理员，密码当场输入
python -m eidolon_server grant <用户名>        # 只升角色，不动密码（管理界面在 #122）
```

包文件名带种类和版本，`scan` 按 `种类-版本.eidolonpkg` 认，例如
`content-2026-11-06.eidolonpkg`、`stand-2026-11-06.eidolonpkg`。

## 接口

| 方法 | 路径 | 要令牌 | 说明 |
|---|---|---|---|
| GET | `/v1/health` | 否 | 探活 |
| POST | `/v1/register` | 否 | 邀请码 + 用户名 + 密码 |
| POST | `/v1/login` | 否 | 用户名 + 密码 → 令牌（180 天，滑窗续期） |
| POST | `/v1/logout` | 是 | 作废当前令牌 |
| GET | `/v1/packages` | 是 | 包列表 |
| GET | `/v1/packages/{id}/download` | 是 | 支持 `Range`，206 / 416 |
| GET | `/v1/announcements?since=` | 是 | 游标之后的公告 |

登录失败 5 次锁 15 分钟。

## 测试

```sh
cd server && ./.venv/bin/python -m pytest -q
```
