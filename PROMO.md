# DeepSeek Harness Desktop：拖进「应用程序」即用，手机还能直连你的 agent

> 内置 Paseo + 完整 dsh 的自包含 Mac APP。零前置依赖，打开即用，手机扫码就能遥控 agent。

---

## 你是不是也卡在这一步？

想用 [DeepSeek Harness（dsh）](https://github.com/deepseek-ai/deepseek-harness) 搭一个能随时干活的本地 agent，结果：

- 要先装 Node ≥22.19，再 `npm i -g` 一个 340MB 的 CLI；
- 想要 [Paseo](https://github.com/getpaseo/paseo) 的移动端直连（手机上给 agent 派活），还得再装 Paseo、配 provider、对端口；
- 装完发现和你本机已有的 dsh、Paseo daemon 搅在一起，谁占了 6767 端口都要查半天。

**DeepSeek Harness Desktop** 把这一整套收进一个 350MB 的 APP 里：

**拖进「应用程序」，双击，完。手机扫个码，agent 随身走。**

---

## 它是什么？

一个自包含的 macOS 桌面 APP（原生 SwiftUI 壳 + WKWebView）：

- **内置** universal Node v22 运行时、完整的 Paseo（daemon + Web UI + 移动端配对）和完整的 `@deepseek-ai/dsh`；
- dsh 经零依赖 ACP 桥自动注册为 Paseo 的「**DeepSeek Harness**」provider，开箱就在列表里；
- **双界面一键切换**：「Mobile」界面管 agent（与手机同步）、「Web」界面（dsh 自带 Web 界面）管模型与插件，顶部切换、常驻不重载；LLM Key 在 Web 的「模型」设置里填；
- **会话跨端镜像**：Web 界面里的对话自动镜像成 Paseo agent，手机端实时可见、可追问续聊（ACP session/list + session/load 回放 + 文件监听实时推送）；
- **移动端直连**：Web 界面手机图标一键生成配对二维码，手机 Paseo App 扫码即连（经官方 relay）；退出 APP 服务默认保持运行，移动端不掉线；
- 数据目录完全私有、端口独立挑选（避开你本机 Paseo 的 6767），**不读不写** `~/.dsh`、`~/.paseo`；
- dsh 遥测默认关闭。

---

## 一分钟上手

1. 下载 DMG（约 350MB）：[Releases 页](https://github.com/vvlife/deepseek-harness-desktop/releases/latest)
2. 打开，把鲸鱼拖进 **Applications**；
3. 双击打开（未公证，首次需右键 → 打开）——Paseo 界面直接出现，「DeepSeek Harness」provider 已就位；
4. 要聊天时：`⌘,` → 选 DeepSeek 官方 / Agnes / 自定义 OpenAI 兼容端点 → 粘贴 Key → 保存（服务自动重启生效）；
5. 想用手机：同一页「生成配对二维码」→ 手机 Paseo App 扫码直连。

偏爱终端的话，也保留了经典的 `curl | bash` 安装路线（装进系统 + 接通你已有的 Paseo，互不影响）：

```bash
curl -fsSL https://raw.githubusercontent.com/vvlife/deepseek-harness-desktop/main/install.sh | bash
```

---

## 核心亮点

| 特性 | 说明 |
|------|------|
| **📱 手机直连 agent** | 内置 Paseo daemon + 配对二维码，手机 App 扫码即连；退出 APP 服务默认常驻 |
| **真·开箱即用** | Node + 完整 dsh + 完整 Paseo 都在包里，不需要 Homebrew/npm/任何预装 |
| **不做强行向导** | 打开直接进界面，provider 已注册；要配 Key 时 ⌘, 设置页随时配 |
| **提供商可选** | DeepSeek 官方 / Agnes / 任意 OpenAI 兼容端点，随时切换 |
| **与环境隔离** | 私有 home + 独立端口，不碰 `~/.dsh`、`~/.paseo`；遥测默认关 |
| **构建即全链路自测** | 每个 DMG 打包时真起 dsh + Paseo daemon 注册 provider 断言通过才发布 |

---

## 几个诚实的说明

1. **DMG 有 350MB**：零前置依赖的代价。Node 运行时 + 完整 dsh + 完整 Paseo（含双架构原生模块）都在里面。
2. **DeepSeek 不支持 OAuth 登录**，只能贴 API Key。「获取 Key」按钮会帮你打开 platform.deepseek.com 建 key；key 只存本机 APP 私有凭据文件（0600），不外传。
3. **未做 Apple 公证**：macOS 15 首次打开请右键 → 打开，或在「隐私与安全性」中允许。
4. **Paseo 为 AGPL-3.0**：APP 内的 Paseo 组件是从官方 DMG 原样解包、未经修改的服务端部分，源码与许可见仓库 `THIRD-PARTY-LICENSES.md`。
5. **这不是 DeepSeek / Paseo 官方项目**，是一个让两者在 Mac 上开箱即用的社区作品。

---

## 立即体验

- 🌐 宣传站：https://dsh-desktop.vercel.app
- 💾 最新 Release：https://github.com/vvlife/deepseek-harness-desktop/releases/latest
- 📦 DMG 直链：https://github.com/vvlife/deepseek-harness-desktop/releases/latest/download/DeepSeek-Harness-Desktop-0.3.5.dmg
- 🐙 源码仓库：https://github.com/vvlife/deepseek-harness-desktop

欢迎提 Issue、PR，或者只是来点个赞。

---

## 社交媒体文案（可直接复制）

### 标题

> DeepSeek Harness Desktop：内置 Paseo 的 dsh 桌面版——拖进应用程序即用，手机扫码直连你的 agent。

### 正文（140 字内）

想玩 DeepSeek Harness 又不想折腾环境？这个 Mac APP 把 Node、完整 dsh 和完整 Paseo 全打进一个包：拖进应用程序双击即用，provider 已注册好，⌘, 图形化配 Key。内置 Paseo 移动端配对——手机扫码，出门在外也能给 agent 派活。与本机已有 dsh/Paseo 完全隔离。

🔗 https://dsh-desktop.vercel.app
📦 https://github.com/vvlife/deepseek-harness-desktop/releases/latest

---

*最后更新：v0.3.5*
