# 帮用户部署 Eidolon-SC

读者是替用户部署的 Agent。用户多半是新手：会照着做，但看不懂报错，也不知道该申请哪些服务。你负责判断和执行，用户只做必须由本人做的事：注册账号、申请 key、把 key 填进 `.env`、在浏览器里试用。

几条贯穿始终的做法：

- **key 由用户自己填进 `.env`**。你告诉用户打开哪个文件、填在哪一行（比如 `CHAT_LLM_API_KEY=` 后面），填完说一声；要确认填得对，就跑 doctor。让用户别把 key 贴进对话：对话记录会留在 Agent 的服务商那里。
- **命令按用户的系统给**。Windows 用 PowerShell，`.sh` 脚本用 Git Bash 跑（装 Git 时自带）；macOS 和 Linux 用终端。PowerShell 里给一条命令设环境变量要写成 `$env:名字="值"; 命令`，不能写 `名字=值 命令`。
- **变量的含义以 `.env.example` 为准**，每一项的注释都写在那里。这份指南只讲流程、选哪家服务、哪里容易踩坑。功能的细节见 `docs/configuration.md`，服务器部署的细节见 `docs/deploy.md`。
- **出错先跑 doctor**（见「排障」），照它的提示改；doctor 说不清时，再看后端的输出。

## 1. 先问用户三件事

1. **在自己电脑上试，还是部署到服务器给别人用？** 前者走「本机体验」，后者走「公网部署」。没把握时先做本机体验，跑通以后再上服务器。
2. **电脑或服务器在中国大陆吗？** 这决定了推荐哪几家服务，以及要不要配代理（见「网络和代理」）。
3. **想要哪些功能？** 文字聊天必须有，其余按需：语音通话、剧情回忆和记忆、照片、通话立绘。每多一项功能就多申请一两个服务，有的按量收费，先把这一点告诉用户。

三个问题都有了答案，这一步才算完。

## 三种跑法

本机体验默认用**直接跑**：在 Windows、macOS、Linux 上都一样，只要装 Git、uv 和 Node.js 这三个普通程序，不用开虚拟化、不用装 WSL。用户已经装好、并且用惯了 Docker 时，可以改用 **Docker 跑**。公网部署用**服务器**这一列。

| | 直接跑 | Docker 跑 | 服务器 |
|---|---|---|---|
| doctor | 在 `backend/` 下：`uv run --env-file=../.env eidolon doctor` | `docker compose run --rm backend eidolon doctor` | `docker compose -f docker-compose.prod.yml run --rm backend eidolon doctor` |
| 改了 `.env` 以后 | 在后端的终端按 Ctrl+C，再运行一次 `eidolon serve` | `docker compose up -d` | `docker compose -f docker-compose.prod.yml up -d` |
| 后端的输出 | 后端那个终端 | `docker compose logs backend` | `docker compose -f docker-compose.prod.yml logs backend` |
| 代理地址里的主机 | `127.0.0.1` | `host.docker.internal` | `127.0.0.1` |

只 `restart` 读不到新的 `.env`，一定要用上表的写法。doctor 加 `--json` 输出 JSON，你读那个更方便。

## 2. 本机体验

### 2.1 直接跑：装 Git、uv、Node.js

- **Windows**：在 PowerShell 里依次运行 `winget install --id Git.Git -e`、`winget install --id astral-sh.uv -e`、`winget install --id OpenJS.NodeJS.LTS -e`。没有 winget 的老系统，就去 git-scm.com、docs.astral.sh/uv、nodejs.org 下载安装程序。装完要**关掉 PowerShell 再重新打开**，新装的命令才找得到。
- **macOS**：有 Homebrew 就 `brew install git uv node`；没有的话 Git 用 `xcode-select --install`，uv 用 `curl -LsSf https://astral.sh/uv/install.sh | sh`，Node.js 从 nodejs.org 下载。
- **Linux**：Git 用发行版的包管理器装，uv 用上面那条 `curl` 命令，Node.js 用 nvm 或 NodeSource 装（发行版自带的 Node 往往太旧）。

`git --version`、`uv --version` 能运行，`node --version` 是 22.18 以上，才算装好。Python 不用自己装，uv 会自动装好 3.11。

### 2.1 Docker 跑：装 Docker

- **Windows / macOS**：装 Docker Desktop。Windows 要开 WSL2，打不开时多半是 BIOS 里没开虚拟化；这一步卡住，就改用直接跑。
- **Linux**：装 Docker Engine 和 compose 插件，按 Docker 官方文档的步骤装。

`docker compose version` 能运行、`docker run --rm hello-world` 能跑完，才算装好。

### 2.2 克隆和最小配置

```sh
git clone https://github.com/Sallyn0225/eidolon-sc.git
cd eidolon-sc
cp .env.example .env        # PowerShell：Copy-Item .env.example .env
```

让用户在 `.env` 里填好对话模型的三项：`CHAT_LLM_BASE_URL`、`CHAT_LLM_API_KEY`、`CHAT_LLM_MODEL`（怎么选见「服务一览」）。另外加一行 `EIDOLON_DEV_LOGIN=1`，本机体验不用配 GitHub 或 Google 登录。

**在中国大陆**：第一次下载依赖、构建前端时要连 GitHub、PyPI、npm 和 Google Fonts（前端构建时要从 Google Fonts 下载字体，连不上就构建失败）。用户有代理软件时，在接下来运行命令的那个终端里先设上代理（`HTTPS_PROXY` 的写法见「网络和代理」），依赖装好、前端构建完之后就不需要了。Docker 跑的，还要在 Docker Desktop 的 Settings → Resources → Proxies 里填代理（Linux 上配 docker 守护进程的代理），构建时拉镜像、装依赖、下载字体都走它。

### 2.3 启动

**直接跑**：开两个终端，都在仓库根目录。你自己操作时，就把两条命令放到后台运行。

```sh
# 终端一：后端（:8000）
cd backend
uv run --env-file=../.env eidolon serve
```

```sh
# 终端二：前端（:3000）
cd frontend
npm ci
npm run build
BACKEND_URL=http://localhost:8000 npm run start
# PowerShell：$env:BACKEND_URL="http://localhost:8000"; npm run start
```

两个终端都一直开着，关掉终端就停了。停前端时，只关掉命令还不够：`next start` 的子进程还占着 3000 端口，要按端口找到进程再结束（PowerShell：`Get-NetTCPConnection -LocalPort 3000 -State Listen` 拿到 `OwningProcess`，再 `Stop-Process -Id <它>`；macOS/Linux：`lsof -ti:3000 | xargs kill`）。

**Docker 跑**：

```sh
docker compose up -d --build
```

两种跑法接下来都一样：跑 doctor（命令见「三种跑法」），退出码是 0、最后一行是「全部正常」，才算这一步完成；不是 0 就看「排障」。然后让用户打开 <http://localhost:3000>，点「登录」→「开发登录」，随便填一个名字，点一位偶像发一句话。她回复了，就说明文字聊天跑通了。

后端起不来时，看后端的输出（位置见「三种跑法」）：最后几行会写明是哪一项配置不对。

### 2.4 按功能加服务

用户要哪项功能，就照「服务一览」申请对应的服务、填进 `.env`，再按「三种跑法」里「改了 `.env` 以后」那一行重启后端，然后跑 doctor。每加一项都跑一次 doctor，全部正常了再加下一项。

**本机的语音通话**：浏览器在 `localhost` 下允许用麦克风。直接跑时，本机通话能打通。Docker Desktop 的容器网络可能让 WebRTC 连不上，表现是一直「接通中」然后失败，这种情况还没有实际验证过；碰到时改用直接跑。

### 2.5 剧情和立绘

见下面的「剧情库」和「立绘」。

## 3. 公网部署

完整步骤在 `docs/deploy.md`，照着做。要点和容易漏的地方：

- 要有一台 Linux 服务器（有公网 IPv4）和一个域名。国内的服务器要求域名已备案，否则 80、443 端口会被拦截。云厂商的安全组按 `docs/deploy.md`「准备」那张表放行端口。
- 生产配置只能在 Linux 上用（host 网络）。前后端镜像从 GHCR 拉，只有 amd64 一种；arm64 的服务器要用 `up -d --build` 在服务器上构建。国内的服务器拉 GHCR 的镜像经常超时，要给 docker 守护进程配代理。
- 你多半是通过 SSH 在服务器上操作。key 同样让用户自己填：让用户在服务器上用 `nano .env` 之类的编辑器填，或者在本地填好再用 `scp` 传上去。
- `EIDOLON_TURN_SECRET`、`EIDOLON_SECRET_KEY` 用 `openssl rand -hex 32` 生成，可以由你生成并写入。**`EIDOLON_SECRET_KEY` 一旦填了就不要再换**，告诉用户把它备份好。
- 登录要配 GitHub 或 Google 的 OAuth 应用，至少一家。见 `docs/deploy.md`「配置 OAuth 应用」，也可以用 `scripts/setup-oauth.sh`，这是一个交互式脚本，让用户自己在终端里运行。
- 公网部署不能留 `EIDOLON_DEV_LOGIN`。它让任何人都能冒充任何用户，配置了 `EIDOLON_DOMAIN` 时后端会拒绝启动。
- 之后的命令都带 `-f docker-compose.prod.yml`，或者先 `export COMPOSE_FILE=docker-compose.prod.yml`。`.env` 缺了 `EIDOLON_DOMAIN`、`EIDOLON_TURN_SECRET` 时，compose 自己会先报「请在 .env 里填写 …」，所有命令（包括 doctor）都跑不起来，先补上。
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

最常见的问题：电脑或服务器在中国大陆，连不上海外的服务。表现是 doctor 报「连不上（network）」，或者「地区不支持（region）」。

1. **问用户有没有代理软件**（Clash、mihomo、v2rayN 等）、HTTP 或 SOCKS 端口是多少。常见端口有 7890、7897、10808、1080；你也可以在本机查一下哪个端口在监听（PowerShell：`Get-NetTCPConnection -State Listen`；macOS/Linux：`lsof -iTCP -sTCP:LISTEN`）。
2. **写 `EIDOLON_PROXY_URL`**：`http://主机:端口`，SOCKS 写成 `socks5h://主机:端口`。主机按「三种跑法」那张表填。Docker 跑时，容器里的 `127.0.0.1` 是容器自己，所以要写 `host.docker.internal`；Linux 上还要在代理软件里打开「允许局域网连接」。
3. `EIDOLON_PROXY_SERVICES` 先空着，重启后端再跑 doctor。连不上的服务它会经代理再试一次，最后打印「建议把 .env 里的这一行改成：EIDOLON_PROXY_SERVICES=…」。照抄进 `.env`，再重启后端。
4. doctor 报「✗ 代理：连不上代理」时，先解决代理本身的问题（代理软件没开、端口不对、Docker 跑时没用 `host.docker.internal`），它的提示里写了原因。

**`EIDOLON_PROXY_*` 和 `HTTPS_PROXY` 管的不是同一批东西。** 后端连各项服务只认 `EIDOLON_PROXY_*`，不认 `HTTPS_PROXY`。装依赖（uv、npm）、构建前端、git，以及下载剧情和立绘的命令（`eidolon story sync`、`eidolon stand fetch`），反过来只认 `HTTPS_PROXY`，连不上时在那个终端里先设上：

```sh
export HTTPS_PROXY=http://127.0.0.1:7890     # macOS、Linux、Git Bash
$env:HTTPS_PROXY="http://127.0.0.1:7890"     # PowerShell
```

git 也可以单独设代理：`git config --global http.https://github.com.proxy http://127.0.0.1:端口`。

## 剧情库

用户常问：「为什么仓库里没有剧情？」这样回答：剧情文本的版权不属于本项目，所以不随仓库分发（`docs/adr/0003-corpus-and-voices-stay-private.md`），仓库里只有同步工具。没同步之前，角色只凭人设回复，不会回忆原作剧情。

同步之前要先配好向量化服务（`SILICONFLOW_API_KEY`）。同步会先拿到汉化版 SCTranslationData，再从镜像补齐还缺的原文剧情：

```sh
# 直接跑：在仓库根目录。后端开着、停着都行
git clone --depth 1 https://github.com/ShinyGroup/SCTranslationData.git corpus/SCTranslationData
cd backend
uv run --env-file=../.env eidolon story sync
```

```sh
# Docker 跑：后端要在运行。Windows 在 Git Bash 里运行
COMPOSE_FILE=docker-compose.yml sh deploy/story-sync.sh
# 服务器
deploy/story-sync.sh
```

- 第一次要下载几千个剧本，镜像要求逐个下载、间隔约一秒，所以要一到两个小时（另加向量化的时间）。中途断了重新运行会接着做，已经下载的不会再下。
- 直接跑时，结果就是命令的输出，退出码 0 是完全成功，2 是镜像出了错（汉化版已经导入了，再运行一次会接着拉）。之后要更新，先 `git -C corpus/SCTranslationData pull --ff-only`，再运行一次 `story sync`。
- 用脚本时，进度写在 `logs/story-sync.log`，最后一行「结束：退出码 N（含义）」就是结果，退出码的含义见 `docs/deploy.md`「每周自动同步」那张表。脚本不会把 `HTTPS_PROXY` 带进容器，镜像连不上（退出码 2）时，改成直接在容器里运行：`docker compose exec -e HTTPS_PROXY=http://host.docker.internal:端口 backend eidolon story sync`（服务器上加 `-f docker-compose.prod.yml`，主机写 `127.0.0.1`）。
- 向量化按量计费，费用见服务商的价格页，同步之前先告诉用户。
- 同步完跑 doctor，「剧情库：N 段剧情」里的 N 大于 0 就是成功了。

## 立绘

用户常问：「为什么通话时只有背景图，没有会动的立绘？」这样回答：立绘是原作的 Spine 素材，同样不随仓库分发，要从 ShinyColorsDB 拉取。落地页的招呼语音和酒吧音乐也是同样的情况，没配时落地页会安静一些，这不是坏了。

**本机体验**：只看通话里的默认衣装，不用存储桶。直接跑和 Docker 跑都要先装 uv 和 Node.js（见 2.1）。在仓库根目录：

```sh
cd backend
uv run --env-file=../.env eidolon stand fetch     # 连不上 ShinyColorsDB 时先设 HTTPS_PROXY
cd ..
npx http-server corpus/stand/source/assets -p 8765 --cors   # 一直开着
```

- 第一次拉取的是 29 位角色的全部衣装，有几 GB，要很久。只想先看效果的话，拉完几位角色就可以按 Ctrl+C 停下，下次运行会接着拉。
- `.env` 里填 `EIDOLON_STAND_ASSETS_URL=http://localhost:8765`，然后重启后端。直接跑时**前端也要带上这个地址**重新启动：`BACKEND_URL=http://localhost:8000 EIDOLON_STAND_ASSETS_URL=http://localhost:8765 npm run start`（PowerShell 写成两条 `$env:…=` 再 `npm run start`）。前端只允许页面从这个地址加载立绘，不带上它，立绘会被浏览器挡掉。Docker 跑时用 `docker compose up -d`，它会自动把地址传给前端。
- 换衣装面板要有衣装清单和缩略图，本机体验没有，这是正常的。

**公网部署**要一个公开可读的 S3 兼容存储桶（推荐 Cloudflare R2，不收流量费），然后用 `deploy/stand-sync.sh` 拉取、渲染缩略图、上传。存储桶的设置（公开访问、CORS）、要装的东西和退出码都在 `docs/deploy.md`「立绘素材」。存储桶和 API 令牌要用户在 Cloudflare 控制台里自己建：你一步步告诉用户点哪里，用户把四项 `EIDOLON_STAND_S3_*` 和公开地址填进 `.env`。

## 排障

先跑 doctor（命令见「三种跑法」）。后端起不来时它也能用。它按 `.env` 逐项试一次每个服务：直连不通时经代理再试，反过来也一样。每一项会报成下面某一类，并附上服务商的原话：

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
- Windows 上中文显示成乱码时，先在那个终端里运行 `chcp 65001`，再运行一次。
- doctor 全部正常、问题却还在，就按现象查：
  - **打不开 localhost:3000**：直接跑时，看前端那个终端有没有报错、`npm run build` 是不是成功了；Docker 跑时，用 `docker compose ps` 看两个容器是不是都在运行。端口被占时，按 2.3 的办法结束占用端口的进程。
  - **前端构建报连不上 Google Fonts（`Failed to fetch font`）**：设上 `HTTPS_PROXY` 再构建（见「网络和代理」）。
  - **公网部署时网站打不开、语音一直「接通中」、`/admin` 是 404**：见 `docs/deploy.md`「排障」。
