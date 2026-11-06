# 私有服务：部署与维护

`server/` 是那个只服务自己人的小服务（spec #120）：邀请码注册、令牌登录、内容包下载（断点续传）、公告。
它**只管「包从哪来」和「公告在哪看」**——不登录、没有网、服务关机，App 照旧能用。

代码在 `server/`，下面是把它放到一台常开的机器（NAS、小主机、VPS 都行）上跑起来的步骤。
**这台机器是谁的、域名是什么、端口开在哪，一律不写进仓库**：脚本里的部署目标从
`tools/deploy.env`（不进仓库）或环境变量来，compose 里的端口、数据目录和时区也都能用环境变量改。
本机开发时怎么跑见 `server/README.md`。

## 一、放到一台机器上

服务只依赖 `server/` 这一个目录（FastAPI + SQLite，`Dockerfile` 也只拷它），**不需要 git，也不需要仓库的其它部分**——Swift 那套一概不上传。

先写一份部署目标（只在你自己的机器上）：

```sh
cp tools/deploy.env.example tools/deploy.env   # 填 EIDOLON_SERVER_HOST / _DIR，这个文件不进仓库
```

然后传文件和构建是两条命令，分开跑：

```sh
tools/upload_server.sh     # 只把 server/（不含 override、.venv、data、测试）推上去
tools/build_server.sh      # 在那边 docker compose up -d --build，然后探活
```

远端没有 `docker-compose.override.yml` 时，`upload_server.sh` 会照 `.example` 抄一份并停下来——管理员账号填在那里：

```yaml
services:
  eidolon-server:
    environment:
      EIDOLON_SERVER_ADMIN_USER: 你的用户名
      EIDOLON_SERVER_ADMIN_PASSWORD: 你的密码
```

这个文件**只存在那台机器上**：不上传、不覆盖、不进仓库（compose 会自动把它合并进 `docker-compose.yml`）。
端口、数据目录、项目名也都可以写进这个 override：`EIDOLON_SERVER_PORT`、`EIDOLON_DATA_DIR`、`EIDOLON_PROJECT`。

**构建只走命令行。** Container Manager 的「项目 → 构建」用的是它建项目时拷的一份副本，推上去的新代码进不了镜像（2026-11-06 实际踩过：代码推了、GUI 也点了构建，容器里跑的还是没有新代码的旧镜像）。GUI 只用来看容器状态和日志。

内容包也不在这两条命令里（`upload_server.sh --with-packages` 可以带上），平时单独传，见下一节。

端口默认 2830（容器里还是 9090），要换就设 `EIDOLON_SERVER_PORT`，compose 文件里的 `ports` 用的是同一个变量。

主机和目录也可以当参数传，或者临时用环境变量给：

```sh
EIDOLON_SERVER_HOST=you@nas.local EIDOLON_SERVER_DIR=/srv/eidolon tools/upload_server.sh
```

手工做也一样，就三步：

```sh
ssh -t you@your-server 'sudo mkdir -p /srv/eidolon/server/data/packages && sudo chown $(id -un) /srv/eidolon/server'
tar czf - -C server --exclude .venv --exclude data --exclude docker-compose.override.yml . | ssh you@your-server 'tar xzf - -C /srv/eidolon/server'
ssh -t you@your-server 'cd /srv/eidolon/server && cp docker-compose.override.yml.example docker-compose.override.yml && vi docker-compose.override.yml'
ssh -t you@your-server 'sudo bash -lc "cd /srv/eidolon/server && docker compose up -d --build"'
```

（在 macOS 上：自带的 `rsync` 是 openrsync，跟不少 NAS 的 sshd 握手不过；`scp` 走 SFTP，DSM 上默认关着。所以用 tar 管道，远端命令一律 `bash -lc`——非登录 shell 的 PATH 里可能没有 docker。）

第一次启动会用 override 里的用户名和密码把管理员建出来（`role=admin`），以后不会覆盖密码。

验证：

```sh
curl http://127.0.0.1:2830/v1/health     # {"ok":true}
```

想从 Container Manager 里看，容器叫 `eidolon-server`，项目（compose project）名默认是 `eidolon`——不写的话 compose 会拿目录名 `server` 当项目名，装第二份时用 `EIDOLON_PROJECT` 分开。

以后升级就是 `upload_server.sh` + `build_server.sh` 两条；换包只跑 `upload_packages.sh`。互不干扰。

## 二、对外只走反向代理

宿主端口 2830（容器里还是 9090）只在内网露着，对外一律走 DSM 的反向代理加证书：

1. 控制面板 → 登录门户 → 高级 → 反向代理 → 新增。
2. 来源：`HTTPS`，主机名填你给这个服务用的那个域名，端口 `443`。
3. 目的地：`HTTP`，`127.0.0.1`，端口 `2830`。
4. 在「自定义标题」里加 `X-Forwarded-For`、`X-Forwarded-Proto`（有些版本叫「WebSocket」附近的几项）。
5. 到「安全性 → 证书」把这个域名指到你那张泛域名证书上。

手机上的地址就填 `https://你的域名`。**不要**让 2830 直接暴露到公网：令牌走的是明文 HTTP。

## 三、日常操作

```sh
cd /srv/eidolon/server

# 发一个邀请码（7 天有效，只能用一次）
sudo docker compose exec eidolon-server python -m eidolon_server invite --days 7

# 看邀请码用没用
sudo docker compose exec eidolon-server python -m eidolon_server invites

# 忘了密码就重设（会同时作废这个账号已有的令牌）
sudo docker compose exec eidolon-server python -m eidolon_server password 用户名

# 强制重算包目录（换了内容但大小没变时用）
sudo docker compose exec eidolon-server python -m eidolon_server scan /data/packages

# 发一条公告（正文从标准输入读）
echo "内容包 11 月这一版换了新的立绘" | \
  sudo docker compose exec -T eidolon-server python -m eidolon_server announcement "新内容包"

# 放包：从 Mac 上跑（断了会接着传，不重来）。放进 data/packages 就登记了，
# 服务启动时会扫一遍；只有「换了内容但大小没变」才需要强制重算。
tools/upload_packages.sh
tools/upload_packages.sh build/eidolon-content.eidolonpkg   # 只传一个
```

包文件名带种类和版本：`eidolon-content-2026-11-06.eidolonpkg`、`eidolon-stand-2026-11-06.eidolonpkg`、
`eidolon-bar-2026-11-06.eidolonpkg`。服务启动时扫目录、算大小和 sha256 登记，同一类里最新的一份标成当前版本。

## 四、升级

服务器上不需要 git：在 Mac 上 `tools/upload_server.sh` 传代码，再 `tools/build_server.sh` 重建。

数据都在 `server/data/`（SQLite 库和包文件），重建容器不影响它。升级前备份一次这个目录：

```sh
sudo tar czf /backup/eidolon-$(date +%F).tgz -C /srv/eidolon/server data
```

## 五、出问题的时候

```sh
sudo docker compose ps                    # 容器在不在、健康检查过没过
sudo docker compose logs -f --tail 200    # 日志
sudo docker compose restart               # 重启
```

- 手机登录一直失败：先在服务器上 `curl http://127.0.0.1:2830/v1/health`，再看反代是不是把它转到了同一个端口。
- 下载到一半断了：客户端会带 `Range` 重新请求，服务端返回 206；416 说明本地那份和服务器的对不上，客户端会丢掉重下。
- 换了证书或域名：手机上「设置 → 账号」里的地址跟着改。

## 六、接口

| 方法 | 路径 | 要令牌 | 说明 |
|---|---|---|---|
| GET | `/v1/health` | 否 | 探活 |
| POST | `/v1/register` | 否 | 邀请码 + 用户名 + 密码 |
| POST | `/v1/login` | 否 | 用户名 + 密码 → 令牌（180 天，滑窗续期） |
| POST | `/v1/logout` | 是 | 作废当前令牌 |
| GET | `/v1/packages` | 是 | 包列表 |
| GET | `/v1/packages/{id}/download` | 是 | 支持 `Range`（206 / 416） |
| GET | `/v1/announcements?since=` | 是 | 游标之后的公告 |

登录失败 5 次锁 15 分钟（按用户名和 IP 各记一份）。

管理动作（账号、邀请码、公告、重新扫描）在 App 里就能做（spec #122）：`设置 → 账号`，
用管理员账号登录后多一项「管理」。对应的接口都在 `/v1/admin/` 下，每个都校验角色，
普通账号调用一律 403：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/v1/admin/users` | 账号列表 |
| POST | `/v1/admin/users/{id}/disable` `/enable` | 停用 / 启用（停用会作废它的令牌） |
| POST | `/v1/admin/users/{id}/password` | 直接设新密码（旧令牌一起作废） |
| DELETE | `/v1/admin/users/{id}` | 删除账号 |
| GET / POST | `/v1/admin/invites` | 看邀请码 / 生成一个（默认 7 天） |
| DELETE | `/v1/admin/invites/{id}` | 作废一个没用过的码 |
| POST / DELETE | `/v1/admin/announcements` | 发公告 / 删公告 |
| POST | `/v1/admin/packages/rescan` | 重新登记包目录 |

**角色没有接口能改**，只能在服务器上 `python -m eidolon_server grant <用户名>`（或启动时的管理员环境变量）。
每个管理动作都在 `audit` 表里留一条记录（谁、什么时候、做了什么），这一版没有它的界面。
公告在 App 里读的位置是对话页首的铃铛，不再是设置。
