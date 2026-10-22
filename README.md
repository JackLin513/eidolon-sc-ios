# Eidolon-SC iOS

[Eidolon-SC](https://github.com/Sallyn0225/eidolon-sc) 的 iOS 原生实验客户端，自用。

后端完全沿用原项目的 FastAPI 服务，这里只做 SwiftUI 客户端：直连后端，不经过 Next.js 的 `/api` 代理，也不打包落地页和后台。

## 现在能做什么

- 开发登录（后端需要 `EIDOLON_DEV_LOGIN=1`）
- 同意隐私政策和使用条款
- 角色列表：搜索中文名、假名、罗马字、组合名；显示最新一条消息和没看过的搭话
- 流式文字对话：日语原文 + 中文字幕，逐段到达
- 设置：改后端地址、刷新角色列表、退出登录

## 还没做

- 语音通话（计划用 `pipecat-client-ios` + `pipecat-client-ios-small-webrtc`）
- 立绘（原作是 Spine 3.6，iOS 上没有现成的 3.6 runtime，见下面的「下一步」）
- 礼物、每日任务、成就
- 统计与分享图
- 照片
- 自带密钥（计划存 Keychain）
- 数据包导入导出
- 公告、服务状态、后台

## 跑起来

### 1. 起后端

```sh
cd ../eidolon-sc
cp .env.example .env    # 至少填 CHAT_LLM_BASE_URL、CHAT_LLM_API_KEY、CHAT_LLM_MODEL
echo 'EIDOLON_DEV_LOGIN=1' >> .env
cd backend
uv run --env-file=../.env eidolon serve
```

后端在 `:8000`。没有配对话模型的话，登录和角色列表能看，发消息会失败。

### 2. 生成并打开工程

```sh
brew install xcodegen   # 只需一次
xcodegen generate
open EidolonIOS.xcodeproj
```

选一个 iPhone 模拟器运行。默认后端地址是 `http://127.0.0.1:8000`，登录名随便填。

> 如果 Xcode 里没有可用的模拟器，先在 Xcode → Settings → Components 下载一个 iOS runtime。

### 3. 登录

「开发登录」直接按名字创建/登录用户，和网页版的开发登录是同一条路由。第一次进会停在同意条款页，点一下继续。

## 三个和网页版不同的地方

- **直连后端**：网页版走 `Next.js /api/[...path]` 代理；iOS 直接请求 `http://127.0.0.1:8000/api/...`。
- **会话还是 cookie**：后端把会话放在 `eidolon_session` cookie 里，`URLSession` 的共享 cookie 存储会替我们带上。后端对写请求检查 `Origin`，所以 `APIClient` 给每个请求都加了 `Origin: <baseURL>`。开发模式下 `localhost` / `127.0.0.1` 都放行。
- **文字回合是 SSE**：`POST /api/conversations/{id}/turns` 返回 `text/event-stream`，`APIClient` 用 `URLSession.bytes` 逐行读 `data:`，再把 `delta` 按 segment 拼起来。

## 真机

模拟器的 `127.0.0.1` 就是这台 Mac；真机不行。而且后端开发模式的 Origin 校验只接受 `localhost` / `127.0.0.1` / `::1`（`backend/src/eidolon/sessions.py` 的 `_LOCAL_HOSTS`）。真机上有两条路：

1. 用域名 + HTTPS 部署后端，把 `EIDOLON_DOMAIN` 设成那个域名，App 里把后端地址改成它；
2. 临时改 `sessions.py`，把 Mac 的局域网地址加进允许的 Origin，再用 `http://<Mac 的 IP>:8000`。

`Info.plist` 目前开了 `NSAllowsArbitraryLoads`，只是为了本地调试明文 HTTP；上真机或以后想收緊时记得改回来。

## 目录

```text
EidolonIOS/
├── App/
│   ├── EidolonIOSApp.swift
│   ├── RootView.swift        # 按登录 / 同意 / 就绪切换
│   └── AppModel.swift        # 会话、角色、最新对话
├── Core/
│   ├── APIClient.swift       # cookie、Origin、SSE
│   ├── Models.swift
│   ├── Backend.swift         # 后端地址（UserDefaults）
│   └── Theme.swift           # 她的印象色
├── Features/
│   ├── Login/                # 开发登录、同意条款
│   ├── Conversations/        # 角色列表
│   ├── Chat/                 # 流式文字对话
│   └── Settings/
└── Info.plist
```

`EidolonIOS.xcodeproj` 是 `xcodegen generate` 生成的，已提交，改完 `project.yml` 重新生成即可。

## 下一步

按投入产出排序：

1. **通话**：加 Swift Package
   `https://github.com/pipecat-ai/pipecat-client-ios-small-webrtc`（会带上 `pipecat-client-ios` 和 `stasel/WebRTC`）。
   它的 `sendOffer` 目前只发 `{sdp, type, pc_id}`，忽略 `APIRequest.requestData`；而后端把 `requestData` 当作 `call`（`backend/src/eidolon/app.py` 的 `Offer`）。需要在本地 fork 里把 `requestData` 合进 offer 的 JSON，或者在后端加一个原生专用的通话启动接口。
2. **立绘**：最省事的做法是透明 `WKWebView` 里继续跑现有的 `spine-webgl.js`，原生只负责传「立绘指令」。想纯原生的话，3.6 分支只有 `spine-c` 和 `spine-cocos2d-objc`，要自己写 Metal/GLES 渲染器。
3. 礼物 / 统计 / 设置：接口都在，照着 `frontend/src/lib` 里的模型逐个补。
4. 搭话通知：后端已经有定时生成搭话的逻辑，补 APNs 设备登记即可。

## License

代码以 [AGPL-3.0-or-later](LICENSE) 发布，和上游一致。角色、剧情、立绘、音色等原作内容不在这个仓库里。
