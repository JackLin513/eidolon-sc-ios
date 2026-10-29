# 帮用户部署 Eidolon-SC

读者是替用户部署的 Agent。用户多半是新手：会照着做，但看不懂报错，也不知道该申请哪些服务。你负责判断和执行，用户只做必须由本人做的事：注册账号、申请 key、把 key 填进 `.env`、在浏览器里试用。

几条贯穿始终的做法：

- **key 由用户自己填进 `.env`**。你告诉用户打开哪个文件、填在哪一行（比如 `CHAT_LLM_API_KEY=` 后面），填完说一声；要确认填得对，就跑 `eidolon doctor`。让用户别把 key 贴进对话：对话记录会留在 Agent 的服务商那里。
- **命令按用户的系统给**。Windows 用 PowerShell，或者 Git Bash（装 Git 时自带，`.sh` 脚本要用它跑）；macOS 和 Linux 用终端。
- **变量的含义以 `.env.example` 为准**，每一项的注释都写在那里。这份指南只讲流程、选哪家服务、哪里容易踩坑。功能的细节见 `docs/configuration.md`，服务器部署的细节见 `docs/deploy.md`。
- **出错先跑 doctor**（见「排障」），照它的提示改；doctor 说不清时，再看后端日志。

## 1. 先问用户三件事

1. **在自己电脑上试，还是部署到服务器给别人用？** 前者走「本机体验」，后者走「公网部署」。没把握时先做本机体验，跑通以后再上服务器。
2. **电脑或服务器在中国大陆吗？** 这决定了推荐哪几家服务，以及要不要配代理（见「网络和代理」）。
3. **想要哪些功能？** 文字聊天必须有，其余按需：语音通话、剧情回忆和记忆、照片、通话立绘。每多一项功能就多申请一两个服务，有的按量收费，先把这一点告诉用户。

三个问题都有了答案，这一步才算完。

## 2. 本机体验

### 2.1 装好 Docker

- **Windows / macOS**：装 Docker Desktop。Windows 要开 WSL2，打不开时多半是 BIOS 里没开虚拟化。Apple Silicon 的 Mac 也能用，本机体验是在本机构建镜像的。
- **Linux**：装 Docker Engine 和 compose 插件，按 Docker 官方文档的步骤装。

`docker compose version` 能运行、`docker run --rm hello-world` 能跑完，才算装好。

**在中国大陆**：构建时要拉 `python:3.11-slim`、`node:22-alpine`，还要装 pip 和 npm 的依赖，这一步经常超时。超时的话，先确认用户有没有代理：Docker Desktop 在 Settings → Resources → Proxies 里填代理；Linux 上给 docker 守护进程配 systemd 的 `HTTP_PROXY`/`HTTPS_PROXY`，或者配镜像加速地址。改完重试。

### 2.2 克隆和最小配置

```sh
git clone https://github.com/Sallyn0225/eidolon-sc.git
cd eidolon-sc
cp .env.example .env        # PowerShell：Copy-Item .env.example .env
```

让用户在 `.env` 里填好对话模型的三项：`CHAT_LLM_BASE_URL`、`CHAT_LLM_API_KEY`、`CHAT_LLM_MODEL`（怎么选见「服务一览」）。另外加一行 `EIDOLON_DEV_LOGIN=1`，本机体验不用配 GitHub 或 Google 登录。

### 2.3 启动

```sh
docker compose up -d --build
docker compose run --rm backend eidolon doctor
```

doctor 的退出码是 0（最后一行是「全部正常」）才算这一步完成；不是 0 就看「排障」。然后让用户打开 <http://localhost:3000>，点「登录」→「开发登录」，随便填一个名字，点一位偶像发一句话。她回复了，就说明文字聊天跑通了。

后端起不来时，看 `docker compose logs backend` 的最后几行：它会写明是哪一项配置不对。

### 2.4 按功能加服务

用户要哪项功能，就照「服务一览」申请对应的服务、填进 `.env`，再执行：

```sh
docker compose up -d                              # 只 restart 读不到新的 .env
docker compose run --rm backend eidolon doctor
```

每加一项都跑一次 doctor，全部正常了再加下一项。

**本机的语音通话**：浏览器在 `localhost` 下允许用麦克风。Docker Desktop 的容器网络可能让 WebRTC 连不上，表现是一直「接通中」然后失败。这种情况还没有实际验证过。碰到时改用不经 Docker 的跑法：按 `README.md` 的「开发」一节，用 uv 起后端、用 npm 起前端，两者共用仓库根目录的 `.env`。

### 2.5 剧情和立绘

见下面的「剧情库」和「立绘」。

## 3. 公网部署

完整步骤在 `docs/deploy.md`，照着做。要点和容易漏的地方：

- 要有一台 Linux 服务器（有公网 IPv4）和一个域名。国内的服务器要求域名已备案，否则 80、443 端口会被拦截。云厂商的安全组按 `docs/deploy.md`「准备」那张表放行端口。
- 生产配置只能在 Linux 上用（host 网络）。镜像只有 amd64，arm64 的服务器要用 `up -d --build` 在服务器上构建。
- 你多半是通过 SSH 在服务器上操作。key 同样让用户自己填：让用户在服务器上用 `nano .env` 之类的编辑器填，或者在本地填好再用 `scp` 传上去。
- `EIDOLON_TURN_SECRET`、`EIDOLON_SECRET_KEY` 用 `openssl rand -hex 32` 生成，可以由你生成并写入。**`EIDOLON_SECRET_KEY` 一旦填了就不要再换**，告诉用户把它备份好。
- 登录要配 GitHub 或 Google 的 OAuth 应用，至少一家。见 `docs/deploy.md`「配置 OAuth 应用」，也可以用 `scripts/setup-oauth.sh`，这是一个交互式脚本，让用户自己在终端里运行。
- 公网部署不能留 `EIDOLON_DEV_LOGIN`。它让任何人都能冒充任何用户，配置了 `EIDOLON_DOMAIN` 时后端会拒绝启动。
- 之后的命令都带 `-f docker-compose.prod.yml`，或者先 `export COMPOSE_FILE=docker-compose.prod.yml`。doctor 是 `docker compose -f docker-compose.prod.yml run --rm backend eidolon doctor`。
- 用 `https://域名` 能打开网站、用户能登录、doctor 全部正常，才算部署完成。接着建议用户配好每天的备份（`docs/deploy.md`「备份」）和每周的剧情同步（「每周自动同步」）。

## 服务一览

| 功能 | 要申请的服务 | 填哪些变量 | 中国大陆 |
|---|---|---|---|
| 文字聊天（必填） | 任何支持**流式输出和工具调用**的对话模型，三种接口任选 | `CHAT_LLM_*` | 选国内能直连的 OpenAI 兼容服务（DeepSeek、硅基流动、阿里云百炼等）；OpenAI、Anthropic、Gemini 要代理 |
| 语音通话：合成 | Fish Audio（fish.audio 的 API Keys 页面） | `FISH_AUDIO_API_KEY` | 通常要代理 |
| 语音通话：识别 | Soniox（console.soniox.com），或者阿里云百炼（bailian.console.aliyun.com，北京地域有免费额度，要先开通识别模型） | `SONIOX_API_KEY`；或 `STT_PROVIDER=bailian` 加 `DASHSCOPE_API_KEY` | 推荐百炼，能直连 |
| 剧情回忆、记忆：向量化和重排 | 硅基流动（cloud.siliconflow.cn），向量化和重排一个 key 就够 | `SILICONFLOW_API_KEY` | 能直连。Gemini 向量化不对中国大陆、香港、澳门开放 |
| 剧情回忆、记忆：判断模型 | 三家选一家：Jev（经 OpenRouter，`JEV_API_KEY`）、Cloudflare Workers AI（每天有免费额度）、阿里云百炼的决策模型 | 见 `.env.example`「判断模型」 | 推荐百炼；OpenRouter 要代理 |
| 照片 | NovelAI，或者兼容的中转；还要配好判断模型 | `NOVELAI_*` | 要代理 |
| 通话立绘 | 不用申请服务，见「立绘」 | `EIDOLON_STAND_ASSETS_URL` | |

- 对话模型必须支持工具调用，否则后端拒绝启动，doctor 会报「模型不对」。模型名以服务商文档为准，填进去以后由 doctor 实测。
- 后台模型（`BACKGROUND_LLM_*`，用来提炼记忆和起标题）不填就沿用对话模型。想省钱可以只填 `BACKGROUND_LLM_MODEL`，在同一家换一个便宜的模型。
- Fish Audio 的默认模型 `s2.1-pro-free` 不消耗 API 额度，但它的免费期限以 Fish Audio 的公告为准。到期后改用付费模型，要充值。
- 「中国大陆」这一列只是起点。哪一项到底要不要代理，以 doctor 在用户机器上的实测为准。

## 网络和代理

最常见的问题：服务器在中国大陆，连不上海外的服务。表现是 doctor 报「连不上（network）」，或者「地区不支持（region）」。

1. **问用户有没有代理软件**（Clash、mihomo、v2rayN 等）、HTTP 或 SOCKS 端口是多少。常见端口有 7890、7897、10808、1080；你也可以在本机查一下哪个端口在监听。
2. **按跑法写 `EIDOLON_PROXY_URL`**：
   - 本机体验（`docker-compose.yml`）：后端在容器里，容器里的 `127.0.0.1` 是容器自己。要写 `http://host.docker.internal:端口`（SOCKS 写 `socks5h://host.docker.internal:端口`）。Linux 上还要在代理软件里打开「允许局域网连接」。
   - 公网部署（`docker-compose.prod.yml`）：后端和服务器共用网络，服务器上的代理直接写 `http://127.0.0.1:端口`。
   - 不经 Docker 跑后端：直接写 `127.0.0.1`。
3. `EIDOLON_PROXY_SERVICES` 先空着，`docker compose up -d` 以后跑 doctor。连不上的服务它会经代理再试一次，最后打印「建议把 .env 里的这一行改成：EIDOLON_PROXY_SERVICES=…」，照抄进 `.env` 再 `up -d`。
4. doctor 报「✗ 代理：连不上代理」时，先解决代理本身的问题（代理软件没开、端口不对、地址该用 `host.docker.internal`）；它的提示里写了原因。

`HTTPS_PROXY` 这类环境变量对后端的这几项服务不起作用，只有 `EIDOLON_PROXY_*` 有用。下载剧情和立绘的命令反过来，只认 `HTTPS_PROXY`，连不上时给那条命令临时带上它（写法见「剧情库」「立绘」）。

## 剧情库

用户常问：「为什么仓库里没有剧情？」这样回答：剧情文本的版权不属于本项目，所以不随仓库分发（`docs/adr/0003-corpus-and-voices-stay-private.md`），仓库里只有同步工具。没同步之前，角色只凭人设回复，不会回忆原作剧情。

同步之前要先配好向量化服务（`SILICONFLOW_API_KEY`），后端要在运行：

```sh
# 本机体验（Windows 在 Git Bash 里运行）
COMPOSE_FILE=docker-compose.yml sh deploy/story-sync.sh
# 公网部署
deploy/story-sync.sh
```

- 第一次要下载几千个剧本，镜像要求逐个下载、间隔约一秒，所以要一到两个小时（另加向量化的时间）。中途断了重新运行会接着做。进度在 `logs/story-sync.log`，最后一行「结束：退出码 N（含义）」告诉你结果，退出码的含义见 `docs/deploy.md`「每周自动同步」那张表。
- 向量化按量计费，费用见服务商的价格页。同步之前先告诉用户。
- 克隆 SCTranslationData 失败（退出码 3，在中国大陆常见）时，给 git 配上代理再运行：`git config --global http.https://github.com.proxy http://127.0.0.1:端口`。
- 镜像连不上（退出码 2，日志里是连接错误）时，脚本不会把代理带进容器，改成直接在容器里运行同步：`docker compose exec -e HTTPS_PROXY=http://host.docker.internal:端口 backend eidolon story sync`（公网部署加 `-f docker-compose.prod.yml`，地址写 `127.0.0.1`）。
- 同步完再跑 doctor，「剧情库：N 段剧情」的 N 大于 0 就是成功了。

## 立绘

用户常问：「为什么通话时只有背景图，没有会动的立绘？」这样回答：立绘是原作的 Spine 素材，同样不随仓库分发，要从 ShinyColorsDB 拉取。落地页的招呼语音和酒吧音乐也是同样的情况，没配时落地页会安静一些，这不是坏了。

**本机体验**，只看通话里的默认衣装，不用存储桶。要装 uv 和 Node.js：

```sh
cd backend
uv run --env-file=../.env eidolon stand fetch     # 连不上 ShinyColorsDB 时先设 HTTPS_PROXY
cd ..
npx http-server corpus/stand/source/assets -p 8765 --cors   # 一直开着
```

然后在 `.env` 里填 `EIDOLON_STAND_ASSETS_URL=http://localhost:8765`，执行 `docker compose up -d`。第一次拉取是 29 位角色的全部衣装，有几 GB，要很久；只想先看效果时，可以先停在拉完几位角色的时候。换衣装面板要有衣装清单和缩略图，本机体验没有，这是正常的。

**公网部署**要一个公开可读的 S3 兼容存储桶（推荐 Cloudflare R2，不收流量费），然后用 `deploy/stand-sync.sh` 拉取、渲染缩略图、上传。存储桶的设置（公开访问、CORS）、要装的东西和退出码都在 `docs/deploy.md`「立绘素材」。存储桶和 API 令牌要用户在 Cloudflare 控制台里自己建：你一步步告诉用户点哪里，用户把四项 `EIDOLON_STAND_S3_*` 和公开地址填进 `.env`。

## 排障

先跑 doctor：

```sh
docker compose run --rm backend eidolon doctor          # 公网部署加 -f docker-compose.prod.yml
docker compose run --rm backend eidolon doctor --json   # 给你读的 JSON
```

后端起不来时它也能用。它按 `.env` 逐项试一次每个服务：直连不通时经代理再试，反过来也一样。每一项会报成下面某一类，并附上服务商的原话：

| 类别 | 意思 | 怎么办 |
|---|---|---|
| `network` 连不上 | 网络不通 | 看「网络和代理」。如果标着「!」、提示「经代理能用」，照最后的建议改 `EIDOLON_PROXY_SERVICES` |
| `region` 地区不支持 | 服务商不对这个地区开放 | 让它走代理，或者换一家服务 |
| `key` key 不对 | key 错了、复制时多带了空格或引号、key 没有这项权限、填错了变量 | 让用户到控制台重新复制一遍；百炼判断模型的 key 必须属于填的那个业务空间 |
| `balance` 余额不足 | 余额或额度用完了 | 让用户充值，或者换免费的模型 |
| `model` 模型不对 | 模型名错了、没开通，或者不支持工具调用 | 对照服务商的模型列表核对，或者换一个模型 |
| `other` | 以上都不是 | 读原话判断 |

- 第一行是「✗ .env 有错」时，后端连启动都不会，照它说的改 `.env`。
- 设了管理者时，后台配置页改过的项优先于 `.env`，doctor 只查 `.env`。
- 生图 doctor 不试，因为每张都花钱。
- doctor 全部正常、问题却还在，就按现象查：
  - **打不开 localhost:3000**：`docker compose ps` 看两个容器是不是都在运行，`docker compose logs frontend backend` 看报错。端口被占时，先停掉占用 3000 端口的程序。
  - **公网部署时网站打不开、语音一直「接通中」、`/admin` 是 404、改了 `.env` 不生效**：见 `docs/deploy.md`「排障」。
  - **改了 `.env` 不生效**：要 `docker compose up -d`，只 `restart` 不会读新的 `.env`。
