<p align="center">
  <img src="docs/images/icon.png" width="96" alt="DeepSeek Harness Desktop 图标">
</p>

# DeepSeek Harness Desktop

**[🐋 宣传站](https://dsh-desktop.vercel.app)**（[国内镜像](https://vvlife.github.io/deepseek-harness-desktop/)）·
**[⬇ DMG 下载](https://github.com/vvlife/deepseek-harness-desktop/releases/latest)** ·
[Release Notes](https://github.com/vvlife/deepseek-harness-desktop/releases)

**DeepSeek Harness（dsh）的一站式 macOS 桌面版**：把 Node 运行时、完整的 dsh、完整的
[Paseo](https://github.com/getpaseo/paseo)（daemon + Web UI + 移动端直连）全部打进一个 APP。
拖进「应用程序」双击即用——**不需要预装任何东西**；手机上扫码就能直连你的 agent；
再接上插件市场，HTML 预览、公网发布点一下就完事。

使用私有 `PASEO_HOME` / `DSH_HOME` 与非默认端口，**不读不写、也不干扰**你本机已有的 dsh 和 Paseo。

> **一句话**：从安装、出门遥控 agent，到把作品发上公网——每一步都只要点一下。

| ⚡ 0 前置依赖 | 📱 2 端实时同步 | 🧩 66+ 社区插件 | 🚀 1 键发布公网 | 🗂 技能管理 |
|---|---|---|---|---|
| 拖进应用程序即用 | 桌面 ↔ 手机对话镜像 | 市场内一键安装 | 免账号，拿到链接即分享 | 全局 / 项目级 skills 集中管理 |

## 快速开始（Quick Start）

### 一行安装（推荐给 Agent / CI / 无图形界面）

`install.sh` 走命令行路径，**不下载 DMG、不触发 Gatekeeper**，最适合自动化环境：

```sh
# 最小安装（不配置 key，稍后在 dsh web 里填）
curl -fsSL https://raw.githubusercontent.com/vvlife/deepseek-harness-desktop/main/install.sh | bash -s -- --yes --skip-auth

# 带 DeepSeek key 直接装好 provider
curl -fsSL https://raw.githubusercontent.com/vvlife/deepseek-harness-desktop/main/install.sh | bash -s -- --provider deepseek --key sk-xxxx --yes
```

脚本会自动补齐 Node ≥22.19（经 Homebrew）、安装 dsh 与 Paseo、部署零依赖 ACP 桥并把
「DeepSeek Harness」注册为 Paseo provider，最后跑冒烟自检。完成后在 Paseo（启动台或
`open -a Paseo`）里新建 agent 选「DeepSeek Harness」即可。

> **Agent 友好**：加 `--yes` 即非交互；首次安装若本机没有 Node，脚本会**自动以非交互方式
> 安装 Homebrew + Node**，无需人工值守。也可用 `--provider agnes|custom`、`--base-url`、
> `--model`、`--env-name` 等参数透传给 provider 配置。

### 图形化安装（人类，DMG 已公证）

1. 下载 [最新 DMG](https://github.com/vvlife/deepseek-harness-desktop/releases/latest)
2. 打开拖进「应用程序」
3. 双击打开即用（Developer ID 签名 + Apple 公证，无安全弹窗）

### 本地开发构建

见文末「[本地开发与自签名](#本地开发与自签名)」。

## 六大特性

### 🚀 一站式安装：拖进「应用程序」，双击，完

Node v22 运行时、完整 dsh、完整 Paseo（daemon + Web UI + 移动端配对）全在包里——
不需要 Homebrew、不需要 npm、不需要任何预装。dsh 经零依赖 ACP 桥自动注册为 Paseo 的
「DeepSeek Harness」provider，打开就在列表里，没有强行引导向导。

<p><img src="docs/images/shot-paseo.png" width="72%" alt="打开即用：Paseo 界面，provider 已注册"></p>

### 📱 移动端访问：手机扫码，agent 随身走

内置完整 Paseo 移动端直连：Web 界面一键生成配对二维码，手机 Paseo App 扫码即连
（经官方 relay，端到端加密）。Web 界面里的对话还会**自动镜像**成 Paseo agent——
手机端实时可见（含思考过程），还能在手机上追问续聊。退出 APP 服务默认保持运行，移动端不掉线。

<p><img src="docs/images/shot-mobile-mirror.png" width="32%" alt="手机端实时看到 Harness Web 的镜像对话"></p>

### 🧩 插件市场：66+ 社区插件，点一下就装好

dsh 的信条是「Everything is a Plugin」。接上 [WhaleHub](https://github.com/vvlife/whalehub-dsh)
市场插件后，Web 界面的「设置 → Plugins」会多出「**🐋 插件市场**」Tab：浏览、搜索、
**一键安装**皮肤、TUI、视觉工具、工作流等 66+ 社区插件，不用再翻仓库抄命令
（市场数据每日同步自社区精选列表 [awesome-deepseek-harness-plugins](https://github.com/vvlife/awesome-deepseek-harness-plugins)）：

```sh
dsh plugin --profile web add "github:vvlife/whalehub-dsh#main&path:/plugin"
# 重启 Web 界面 → 设置 → Plugins → 🐋 插件市场
```

<p><img src="docs/images/shot-plugin-market.png" width="72%" alt="Web 界面内置的 WhaleHub 插件市场"></p>

### 🗂 技能管理：全局 / 项目级 skills 集中管理

装上 [dsh-skill-manager](https://github.com/vvlife/dsh-skill-manager) 插件（一条命令），Web 界面的
「设置」就多出「🧩 技能管理」面板：卡片式**浏览**全局（`~/.dsh/skills/`）与项目级
（`.agents/skills/`、`.claude/skills/`）skills，**新建 / 编辑 / 删除 / 导入**（符号链接或拷贝）一步到位；
另带「🐋 ClawHub」市场 tab，从 GitHub 社区仓库浏览并一键安装技能：

```sh
dsh plugin --profile web add github:vvlife/dsh-skill-manager
```

### 👁 内置预览：HTML / 文件即点即看

Web 界面自带工作区文件预览，HTML 页面（含游戏、交互页）直接在侧边栏里跑，
改完刷新即看，不用离开对话。

### 🌐 发布公网：一键部署，拿到链接就分享

装上 [dsh-deploy-share](https://github.com/vvlife/dsh-deploy-share) 插件，HTML 预览顶部多出
「🚀 部署 / 📋 分享」按钮：把 agent 写的页面一键部署到**免账号**匿名托管，
拿到公开链接发给任何人；部署后自动回读校验，真渲染成功才算数：

```sh
dsh plugin --profile web add github:vvlife/dsh-deploy-share
```

<p><img src="docs/images/shot-deploy-share.png" width="72%" alt="HTML 预览 + 一键部署到公网"></p>

### 🔎 免 Key 联网搜索：web_search 不烧模型额度

内置 web_search 默认走 DeepSeek 官方搜索 provider：每次搜索是一次模型调用，
需要 `DEEPSEEK_API_KEY` 且消耗 API 额度。本仓库自带 [dsh-web-search-free](plugin/)
插件，装上后 web_search 改走**免 API Key** 通道——DuckDuckGo 与 Bing 公开搜索页
双通道竞速，哪边先出结果用哪边（任一引擎在你的网络不可达时自动落到另一家），
零凭据、零额度：

```sh
dsh plugin --profile web add "github:vvlife/deepseek-harness-desktop#main&path:/plugin"
```

装上即接管 web_search（web seam 的 `searchProvider` 指向 `free`）；
想改回官方搜索，卸载插件即可。插件零依赖，自测见 `plugin/test.mjs`
（离线 fixture + 在线实测）。

> 🖥 **双界面切换**（Mobile / Web 常驻不重载）· 🔌 **提供商可选**（DeepSeek 官方 / Agnes / OpenAI 兼容端点）· 🛡 **环境隔离**（私有 home + 独立端口，不碰 `~/.dsh` / `~/.paseo`）· 🗂 **技能管理**（全局 / 项目级 skills 集中管理 + ClawHub 市场）· 🧪 **构建即自测**（每个 DMG 真起服务全链路断言，全绿才发布）

> A self-contained macOS app bundling a universal Node runtime + full Paseo
> (daemon, Web UI, mobile pairing) + full DeepSeek Harness as a Paseo provider
> (via a zero-dependency ACP bridge). Drag to Applications and go — one-stop install,
> mobile access, a plugin marketplace, built-in preview, one-click public deploy
> and optional key-free web search (via plugins), fully isolated from any dsh/Paseo
> you already have installed.

## 安装（DMG，推荐）

1. 下载 [DeepSeek-Harness-Desktop-0.3.8.dmg](https://github.com/vvlife/deepseek-harness-desktop/releases/latest/download/DeepSeek-Harness-Desktop-0.3.8.dmg)（约 350MB，universal）
2. 打开 DMG，把 **DeepSeek Harness Desktop** 拖进 **Applications**
3. 双击打开即可（已用 Developer ID 签名并经过 Apple 公证，不会触发 Gatekeeper 拦截）。
   若个别系统仍提示，请先在「系统设置 → 隐私与安全性」确认，或右键 → 打开。

打开后 APP 会启动内置 Paseo daemon（127.0.0.1 独立端口）并在窗口里显示 Paseo Web UI，
「DeepSeek Harness」provider 已自动注册好。新建 agent 时选择它即可。
工具栏可在「**Mobile / Web**」两个界面间切换（Mobile = Paseo agent 界面，与手机同步；
Web = dsh 自带的 Web 界面，同一私有 `DSH_HOME`；两个视图常驻内存，切换不重载）。
要真正对话时：切到 **Web** 界面 → 其内置设置的「模型」页粘贴 DeepSeek 官方或 Agnes 的 API Key，保存即可。

<p><img src="docs/images/shot-harness-web.png" width="72%" alt="Harness Web 界面"></p>

### 移动端直连（手机遥控 agent）

切到 **Web** 界面 → 右上角**手机图标** →「**生成配对二维码**」→ 用手机 Paseo App
扫码（或打开配对链接）即可连到本 APP 的内置服务（经 Paseo 官方 relay，端到端加密）。
Paseo 界面里的 agent 对话在手机与电脑之间**实时同步**；退出 APP 后内置服务**默认保持运行**，
移动端可继续连接。若手机提示超时，点「刷新配对码」后立刻重扫（relay 重连窗口期会导致偶发超时）。

> **Web 界面的对话也能上手机**：APP 每 20s 把 Web 界面（dsh web）里的新会话
> 自动镜像为 Paseo agent（标题同名，含完整对话与思考过程），手机端直接可见；
> 在手机上追问也能接续原对话（带上下文注入，回合写入 overlay 持久化）。
> 镜像通过 ACP `session/list` + `session/load` 回放实现，dsh web 本体零改动。

### 备选：curl|bash 命令行安装器

适合把 dsh 装进系统（全局 npm）并接通**你已有的** Paseo 的场景，无 Gatekeeper 提示：

```sh
curl -fsSL https://raw.githubusercontent.com/vvlife/deepseek-harness-desktop/main/install.sh | bash
```

详见[常用参数](#常用参数)。DMG 与 curl 两条路线互不影响。

## APP 做了什么

- 以私有 `PASEO_HOME`（`~/Library/Application Support/DeepSeek Harness Desktop/paseo-home`）
  启动内置 Paseo daemon，监听 `127.0.0.1` 的独立端口（默认 6868 起自动挑选，避开本机 Paseo 的 6767）
- Web UI 由 daemon 直接服务（`PASEO_WEB_UI_ENABLED` 等效配置已持久化到私有 config.json）
- 私有 `DSH_HOME` 下的 ACP 桥 + wrapper 把 dsh 注册为 Paseo provider「DeepSeek Harness」，
  桥与 dsh 全部走 APP 内置 Node 运行时
- 双界面切换：Mobile（Paseo Web UI）与 Web（dsh web，独立端口 3180 起自动挑选）；
  两视图常驻内存、切换不重载；界面切换不影响 daemon，移动端连接与会话状态保持同步
- LLM 提供商/API Key 在 Web 界面的内置「模型」设置里配置（dsh 原生 UI）；
  移动端配对二维码在 Web 界面右上角手机图标里
- 全部数据都在自己的 Application Support 目录，**不碰** `~/.dsh` / `~/.paseo`

## 内置终端：dsh / paseo 解析保证

APP 内置的 dsh web 带一个交互式终端。终端里的 `dsh` / `paseo` / `node`
**永远指向 APP 包内的那一份**，不会误用你本机全局安装的版本——这是
“零前置依赖、不干扰本机已有 dsh/Paseo” 承诺的关键一环。

原理（双层保险）：

1. **PATH 注入**：APP 拉起 dsh web 时，把包内 bin 目录
   `<bundle>/Contents/Resources/runtime/node/bin`（内含 `node` 及 `dsh` / `paseo`
   两个 shim）放到 `PATH` **最前**（见 `app/DesktopApp.swift` 的 `processEnv()` /
   `bundledBinDir`）。
2. **终端继承 PATH**：内嵌终端以 `/bin/bash --noprofile --norc -i` 启动，
   不读取任何 `~/.bashrc` / `/etc/profile`，直接继承父进程（dsh web）的 PATH，
   因此命中的一定是包内 shim，全局安装无法遮蔽。

验证（开发者 / CI）：

```sh
# 校验内嵌终端解析到的 dsh/paseo/node 是否命中包内版本
bash scripts/verify-bundled-cli.sh "app/build/DeepSeek Harness Desktop.app"

# 想在自己终端里临时用上包内 dsh/paseo/node（不影响系统配置）：
source app/scripts/dsh-desktop-env.sh          # 自动探测已装 APP
# 之后 which dsh / which paseo / which node 都指向包内
```

DMG 构建流程（`dmg.yml`）在出包前会自动跑上面的校验，命中包外即失败、拒绝发版。

## 关于"DeepSeek 登录"

DeepSeek 的 API **没有账号 OAuth 登录**。设置页里的「获取 Key」= 帮你打开
[platform.deepseek.com](https://platform.deepseek.com/api_keys)（在那里登录 DeepSeek 账号、
创建 API Key），回到 APP 粘贴即可。key 写入 APP 私有的 `.credentials.yaml`（权限 0600）。

## 卸载

```sh
# 1. 停掉内置服务（若在运行）
"/Applications/DeepSeek Harness Desktop.app/Contents/Resources/runtime/node/bin/paseo" daemon stop
# 2. APP 拖进废纸篓，删除数据目录
rm -rf ~/Library/Application\ Support/DeepSeek\ Harness\ Desktop
```

不碰系统里任何其他东西（内置服务使用私有 home，无注册表项残留）。

## 常用参数（curl|bash 安装器）

```sh
# 非交互：直接指定 provider 与 key
curl -fsSL .../install.sh | bash -s -- --yes --provider deepseek --key sk-...

# 用 Agnes / 自定义 OpenAI 兼容端点
... bash -s -- --yes --provider agnes --key sk-...
... bash -s -- --yes --provider custom --base-url https://api.example.com/v1 --model my-model --key sk-...

# 跳过凭据（稍后在 dsh web 的模型设置页填）
... bash -s -- --yes --skip-auth

# 本机已装好 dsh / 不想动 Paseo
... bash -s -- --skip-dsh --skip-paseo
```

| flag | 作用 |
|---|---|
| `--provider deepseek\|agnes\|custom` | 选择 LLM 提供商（默认交互询问，deepseek 为推荐项） |
| `--key` | API Key（不给则查环境变量/凭据层，交互模式会提示粘贴） |
| `--base-url --model --provider-id --env-name --display-name` | custom provider 的细节 |
| `--yes` | 非交互模式（全默认） |
| `--skip-auth` | 跳过凭据配置 |
| `--skip-dsh` / `--skip-paseo` | 跳过对应组件安装 |
| `--restart-daemon` | 装完立即重启 Paseo daemon（默认不打扰正在运行的 daemon） |
| `--uninstall` | 卸载安装器写入的内容（桥/provider 注册/路由 patch） |

## 自检

curl|bash 安装末尾自动跑 `scripts/smoke-test.mjs`（ACP 协议握手 + 配置断言，不发起真实 LLM 调用）。
手动重跑：

```sh
node scripts/smoke-test.mjs                # 基础自检
node scripts/smoke-test.mjs --e2e          # 追加一次真实 dsh 调用（消耗少量 API 额度）
```

DMG 构建时会做更完整的自测：包内运行时真启动一次 dsh web 断言 200；
再以临时私有 home 启动 Paseo daemon → 断言 Web UI 200 → 注册 provider →
断言 `provider ls` 出现「DeepSeek Harness」→ 停 daemon。全绿才出包。

## FAQ

**DMG 为什么有 350MB？** 因为把 Node 运行时、完整 dsh 和完整 Paseo（含双架构原生模块）
都打进了包里，换来「零前置依赖、不与本机环境互相干扰」。

**Paseo 不是 Electron 应用吗，怎么内置的？** Paseo 的 daemon / CLI / 服务端是纯 Node 程序
（桌面版只是借用 Electron 二进制当 Node 运行时）。我们从官方 DMG 原样解包这部分，
用内置 Node 运行，不经任何修改；Web UI 静态资源同样来自官方 DMG。

**会动我本地的 dsh / Paseo 吗？** 不会。私有 home + 独立端口，和你已有的实例完全平行；
你的 Paseo（若有）照常使用 `~/.paseo` 与 6767 端口。

**插件市场 / 公网发布 / 免 Key 搜索是 APP 内置的吗？** 插件体系是 dsh 原生的，APP 里的 Web 界面完整支持；
「插件市场 Tab」「部署分享按钮」「免 Key web_search」分别由 WhaleHub 市场插件、dsh-deploy-share
插件与本仓库自带的 dsh-web-search-free 插件提供，都是一条 `dsh plugin add` 命令装好
（命令见上文对应小节）。

**Paseo 里的对话为什么没有上下文？** 每个 prompt 回合是一次独立的 `dsh --profile headless`
运行（dsh headless 无 resume），回合间不保留对话上下文。

**设置里的 Providers 页显示 "Connect to this host to see providers"？** 这是 v0.3.0 的已知问题：
数据目录重建后 daemon 身份（serverId）变化，Web UI 的 host 注册表拒绝接受新身份。v0.3.1 起
APP 固定 serverId 并在身份变化时自动重置 Web UI 本地数据；旧版本手动修复 = 退出 APP，
删除 `~/Library/WebKit/com.vvlife.dsh-desktop` 后重开。

**和 dsh-agnes-paseo 什么关系？** 本仓库是其演进形态：provider 从写死 Agnes 变为可选，
并升级为自包含桌面 APP。旧插件不受影响。

**本地构建 DMG？** `app/make-app.sh`（swiftc 直编 SwiftUI + Node 官方 dist lipo 合并 +
npm 双架构 dsh 依赖树合并 + Paseo 官方 DMG 解包双架构合并 + 签名 + 全链路自测 + hdiutil）。
默认用环境变量 `DSH_SIGN_IDENTITY` 注入的「Developer ID Application」证书做 hardened runtime
签名，随后由 `app/notarize.sh` 提交 Apple 公证（用户人人可装）。未配置 Developer ID 证书时
回退到钥匙串里的自签证书「DSH Desktop Local Code Signing」或 ad-hoc（仅供本机调试，他人
下载仍会被 Gatekeeper 拦截——上一个未公证版本即是此情况）。

**发布前准备（一次性）：** 在仓库 `Settings → Secrets and variables → Actions` 配置
`DSH_MAC_CERT_P12` / `DSH_MAC_CERT_PASSWORD`（Developer ID Application 证书），以及公证凭证
`APPLE_API_KEY`+`APPLE_API_ISSUER`+`APPLE_API_KEY_PEM` 或 `APPLE_ID`+`APPLE_APP_SPECIFIC_PASSWORD`
+`APPLE_TEAM_ID`。详见 `app/notarize.sh` 头部注释。

## 本地开发与自签名

### 为什么需要「自签名」

未加入 Apple Developer Program（$99/年）时，拿不到 **Developer ID Application** 证书，
也就无法做 Apple 公证。此时本地构建可用一把**自签名证书** `DSH Desktop Local Code Signing`
签名，让 app 在本机直接运行（macOS 的目录访问授权按证书锚定，跨重新构建持久）。

⚠️ **自签名证书只在本机有效**：它没经过 Apple 信任链，分发到他人机器会被 Gatekeeper 拦截
（"无法验证是否包含恶意软件"）。要"人人下载都能装"，必须走 Developer ID 签名 + 公证
（见上文「发布前准备」）。自签名**仅用于本地开发调试**，不是发布手段。

### 1. 创建自签证书（一次）

**方式 A · 钥匙串访问（GUI）**
1. 打开「钥匙串访问」→ 菜单「证书助理」→「创建证书…」
2. 名称填 `DSH Desktop Local Code Signing`，身份类型选「代码签名」，证书类型「自签名根证书」
3. 一路继续到创建完成
4. 双击该证书 →「信任」→「代码签名」设为「始终信任」

**方式 B · 命令行**
```sh
CERT="DSH Desktop Local Code Signing"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 365 -nodes -subj "/CN=$CERT"
openssl pkcs12 -export -out dsh-local.p12 -inkey key.pem -in cert.pem -passout pass:changeit
security import dsh-local.p12 -k ~/Library/Keychains/login.keychain-db -P changeit
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain cert.pem
```

### 2. 构建

```sh
bash app/make-app.sh          # 自动找到 DSH Desktop Local Code Signing 并签名
# 或显式指定身份
DSH_SIGN_IDENTITY="DSH Desktop Local Code Signing" bash app/make-app.sh
```
产物：`app/build/DeepSeek-Harness-Desktop-<ver>.dmg`。

### 3. 在本机运行自签构建（绕过 Gatekeeper）

自签 app 首次打开会被拦，本机调试时去掉 quarantine 即可：

```sh
xattr -dr com.apple.quarantine "/Applications/DeepSeek Harness Desktop.app"
# 或一次性放行（仅本机）：spctl --add "/Applications/DeepSeek Harness Desktop.app"
# 也可从「系统设置 → 隐私与安全性 → 仍要打开」点一次
```

> 这些步骤**只对当前这台机器**有效，不能让他人免拦截——那是 Developer ID + 公证的职责。

## 许可

本仓库代码 MIT（`LICENSE`）。APP 内置的 Node.js（MIT，`LICENSE-node`）、
`@deepseek-ai/dsh`（MIT）与 Paseo 服务端组件（**AGPL-3.0**，未经修改、附源码链接）
均为上游发布物原样打包。详见 `THIRD-PARTY-LICENSES.md`。
