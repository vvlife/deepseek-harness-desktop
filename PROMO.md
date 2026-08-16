# DeepSeek Harness Desktop：拖进「应用程序」即用，手机、插件市场、公网发布全都有

> 内置 Paseo + 完整 dsh 的自包含 Mac APP。零前置依赖，打开即用；手机扫码直连 agent；插件市场、HTML 预览、一键发布公网，点一下就完事。

---

## 你是不是也卡在这一步？

想用 [DeepSeek Harness（dsh）](https://github.com/deepseek-ai/deepseek-harness) 搭一个能随时干活的本地 agent，结果：

- 要先装 Node ≥22.19，再 `npm i -g` 一个 340MB 的 CLI；
- 想要 [Paseo](https://github.com/getpaseo/paseo) 的移动端直连（手机上给 agent 派活），还得再装 Paseo、配 provider、对端口；
- 想找几个好用的插件（皮肤、预览、部署），得去 GitHub 一个一个翻仓库、抄安装命令；
- 装完发现和你本机已有的 dsh、Paseo daemon 搅在一起，谁占了 6767 端口都要查半天。

**DeepSeek Harness Desktop** 把这一整套收进一个 APP 里：

**拖进「应用程序」，双击，完。手机扫个码，agent 随身走。**

---

## 六大特性

### 🚀 一站式安装

Node v22 运行时、完整 dsh、完整 Paseo（daemon + Web UI + 移动端配对）全部在包里。
不需要 Homebrew、不需要 npm、不需要任何预装；dsh 自动注册为 Paseo 的「DeepSeek Harness」provider，
打开就在列表里，没有强行向导。私有 home + 独立端口，**不碰**你本机已有的 dsh 和 Paseo。

### 📱 移动端访问

内置完整 Paseo 移动端直连：一键生成配对二维码，手机 Paseo App 扫码即连（官方 relay，端到端加密）。
Web 界面里的对话**自动镜像**成 Paseo agent——手机上实时看到完整对话与思考过程，还能直接追问续聊。
退出 APP 服务默认保持运行，出门在外也能给 agent 派活。

![手机端实时看到 Harness Web 的镜像对话](docs/images/shot-mobile-mirror.png)

### 🧩 插件市场

dsh 的生态信条是「Everything is a Plugin」。接上 [WhaleHub](https://github.com/vvlife/whalehub-dsh)
市场插件（一条命令），Web 界面的「设置 → Plugins」就多出「🐋 插件市场」Tab：
66+ 社区插件——皮肤、TUI、视觉工具、工作流——浏览、搜索、**点一下就装好**：

```sh
dsh plugin --profile web add "github:vvlife/whalehub-dsh#main&path:/plugin"
```

![Web 界面内置的 WhaleHub 插件市场](docs/images/shot-plugin-market.png)

### 🗂 技能管理

再装一个 [dsh-skill-manager](https://github.com/vvlife/dsh-skill-manager) 插件（同样一条命令），
「设置」就多出「🧩 技能管理」面板：卡片式浏览全局（`~/.dsh/skills/`）与项目级
（`.agents/skills/`、`.claude/skills/`）skills，新建 / 编辑 / 删除 / 导入一步到位；
另带「🐋 ClawHub」市场 tab，从 GitHub 社区仓库浏览并一键安装技能：

```sh
dsh plugin --profile web add github:vvlife/dsh-skill-manager
```

### 👁 内置预览

Web 界面自带工作区文件预览：agent 写的 HTML 页面（游戏、交互页都行）直接在侧边栏跑起来，
改完刷新即看，不用离开对话。

### 🌐 发布公网

再装一个 [dsh-deploy-share](https://github.com/vvlife/dsh-deploy-share) 插件（同样一条命令），
HTML 预览顶部就出现「🚀 部署 / 📋 分享」按钮：把页面一键部署到**免账号**匿名托管，
拿到公开链接直接发给别人；部署后自动回读校验，真渲染成功才算成功：

```sh
dsh plugin --profile web add github:vvlife/dsh-deploy-share
```

![HTML 预览 + 一键部署到公网](docs/images/shot-deploy-share.png)

### 🔎 免 Key 联网搜索

内置 web_search 默认每次搜索消耗一次模型调用、要 `DEEPSEEK_API_KEY`。
本仓库自带 dsh-web-search-free 插件，装上后 web_search 改走**免 API Key** 通道：
DuckDuckGo 与 Bing 公开搜索页双通道竞速，一家不可达自动落另一家，零凭据零额度：

```sh
dsh plugin --profile web add "github:vvlife/deepseek-harness-desktop#main&path:/plugin"
```

装上即接管 web_search；想改回官方搜索，卸载插件即可。

---

## 一分钟上手

1. 下载 DMG（约 350MB）：[Releases 页](https://github.com/vvlife/deepseek-harness-desktop/releases/latest)
2. 打开，把鲸鱼拖进 **Applications**；
3. 双击打开（未公证，首次需右键 → 打开）——Paseo 界面直接出现，「DeepSeek Harness」provider 已就位；
4. 要聊天时：切到 Web 界面 → 「模型」设置里选 DeepSeek 官方 / Agnes / 自定义 OpenAI 兼容端点 → 粘贴 Key → 保存；
5. 想用手机：Web 界面右上角手机图标 → 生成配对二维码 → 手机 Paseo App 扫码直连。

偏爱终端的话，也保留了经典的 `curl | bash` 安装路线（装进系统 + 接通你已有的 Paseo，互不影响）：

```bash
curl -fsSL https://raw.githubusercontent.com/vvlife/deepseek-harness-desktop/main/install.sh | bash
```

---

## 核心亮点速览

| 特性 | 说明 |
|------|------|
| **🚀 一站式安装** | Node + 完整 dsh + 完整 Paseo 都在包里，拖进应用程序双击即用，零前置依赖 |
| **📱 移动端访问** | 内置 Paseo 配对二维码，手机扫码即连；Web 会话自动镜像上手机，可追问续聊 |
| **🧩 插件市场** | 接上 WhaleHub 即得图形化市场，66+ 社区插件一键安装 |
| **🗂 技能管理** | dsh-skill-manager 集中管理全局/项目级 skills，带 ClawHub 市场 |
| **👁 内置预览** | HTML / 工作区文件即点即看，交互页直接跑 |
| **🌐 发布公网** | dsh-deploy-share 一键部署到免账号托管，拿到链接即分享 |
| **🔎 免 Key 联网搜索** | dsh-web-search-free 双引擎竞速，web_search 不要 Key、不烧模型额度 |
| **🔌 提供商可选** | DeepSeek 官方 / Agnes / 任意 OpenAI 兼容端点，随时切换 |
| **🛡 与环境隔离** | 私有 home + 独立端口，不碰 `~/.dsh`、`~/.paseo`；遥测默认关 |
| **🧪 构建即自测** | 每个 DMG 打包时真起 dsh + Paseo daemon 注册 provider，全绿才发布 |

---

## 几个诚实的说明

1. **DMG 有 350MB**：零前置依赖的代价。Node 运行时 + 完整 dsh + 完整 Paseo（含双架构原生模块）都在里面。
2. **插件市场 / 公网发布 / 免 Key 搜索是插件提供的**：dsh 的插件体系 APP 完整支持，WhaleHub 市场、dsh-deploy-share 与本仓库自带的 dsh-web-search-free 各一条命令装好（见上文），装上就是图形化体验。
3. **DeepSeek 不支持 OAuth 登录**，只能贴 API Key。「获取 Key」按钮会帮你打开 platform.deepseek.com 建 key；key 只存本机 APP 私有凭据文件（0600），不外传。
4. **未做 Apple 公证**：macOS 15 首次打开请右键 → 打开，或在「隐私与安全性」中允许。
5. **Paseo 为 AGPL-3.0**：APP 内的 Paseo 组件是从官方 DMG 原样解包、未经修改的服务端部分，源码与许可见仓库 `THIRD-PARTY-LICENSES.md`。
6. **这不是 DeepSeek / Paseo 官方项目**，是一个让两者在 Mac 上开箱即用的社区作品。

---

## 立即体验

- 🌐 宣传站：https://dsh-desktop.vercel.app （国内镜像：https://vvlife.github.io/deepseek-harness-desktop/）
- 💾 最新 Release：https://github.com/vvlife/deepseek-harness-desktop/releases/latest
- 📦 DMG 直链：https://github.com/vvlife/deepseek-harness-desktop/releases/latest/download/DeepSeek-Harness-Desktop-0.3.7.dmg
- 🐙 源码仓库：https://github.com/vvlife/deepseek-harness-desktop
- 🧩 插件市场：https://whalehub-dsh.vercel.app

欢迎提 Issue、PR，或者只是来点个赞。

---

## 社交媒体文案（可直接复制）

### 标题

> DeepSeek Harness Desktop：一站式 dsh 桌面版——拖进应用程序即用，手机扫码直连，插件市场 + 预览 + 一键发布公网。

### 正文（140 字内）

想玩 DeepSeek Harness 又不想折腾环境？这个 Mac APP 把 Node、完整 dsh 和完整 Paseo 全打进一个包：拖进应用程序双击即用，图形化配 Key；手机扫码直连 agent，出门在外也能派活；接上插件市场，皮肤/预览/一键发布公网点一下就装好。与本机已有 dsh/Paseo 完全隔离。

🔗 https://dsh-desktop.vercel.app （国内镜像 https://vvlife.github.io/deepseek-harness-desktop/）
📦 https://github.com/vvlife/deepseek-harness-desktop/releases/latest

---

*最后更新：v0.3.7*
