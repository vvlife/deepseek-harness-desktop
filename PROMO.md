# DeepSeek Harness Desktop：把 Paseo 和 dsh 一键装进 Mac

> 一行命令 / 一个 DMG，让 Mac 立刻拥有本地 AI Harness 能力。

---

## 你是不是也卡在这一步？

[Paseo](https://github.com/paseo-project/paseo) 是个很有意思的本地模型 runtime，但官方文档默认你已经配好了 `dsh`（DeepSeek Harness）环境。

现实往往是：

- Homebrew 没装、Python 环境一团糟；
- `pip install dsh` 报依赖冲突；
- 终于跑起来，发现 Paseo daemon 和 CLI 版本对不上；
- 想换个 DeepSeek API key，却不知道配置文件在哪。

**DeepSeek Harness Desktop** 就是为这种“我只想双击就能用”的时刻做的。

---

## 它是什么？

一个原生 SwiftUI 的 macOS 安装器 / 启动台：

- 一键装好 `dsh` CLI + Paseo 依赖；
- 内置 ACP 桥，让 Paseo daemon 和 dsh 插件零配置通信；
- 支持多种 LLM Provider：DeepSeek 官方 API、Agnes，或任意 OpenAI 兼容端点；
- 不破坏你正在运行的 Paseo daemon；
- 整个安装包只有 **331 KB**（universal binary），无 Electron、无 Docker、无 Python 虚拟环境。

---

## 三步上手

### 方式一：命令行（最快）

```bash
curl -fsSL https://raw.githubusercontent.com/vvlife/deepseek-harness-desktop/main/install.sh | bash
```

### 方式二：图形化（最直观）

1. 下载 DMG：[DeepSeek-Harness-Desktop-0.2.0.dmg](https://github.com/vvlife/deepseek-harness-desktop/releases/latest/download/DeepSeek-Harness-Desktop-0.2.0.dmg)
2. 拖到 Applications；
3. 打开 App，填入 API Key，点击“Connect”。

---

## 核心亮点

| 特性 | 说明 |
|------|------|
| **原生 SwiftUI** | 331 KB universal DMG，秒开 |
| **LLM Provider 可选** | DeepSeek 官方 / Agnes / 自定义 OpenAI 兼容端点 |
| **零依赖 ACP 桥** | Paseo daemon 与 dsh 插件直接通信 |
| **热插拔** | 不重启正在运行的 Paseo 进程 |
| **开源免费** | MIT 主协议，AGPL 第三方声明齐全 |

---

## 几个诚实的说明

1. **DeepSeek 目前不支持 OAuth 登录**，所以只能贴 API Key。App 不会上传你的 key，只保存在本地钥匙串 / 配置文件中。
2. **DMG 第一次打开可能触发 Gatekeeper**：因为暂时没做 Apple 公证。请右键 → 打开，或在“系统设置 > 隐私与安全性”中允许。
3. **这不是 Paseo 官方项目**，是一个让 Paseo + dsh 更快跑起来的社区工具。

---

## 立即体验

- 🌐 宣传站：https://dsh-desktop.vercel.app
- 💾 最新 Release：https://github.com/vvlife/deepseek-harness-desktop/releases/latest
- 📦 DMG 直链：https://github.com/vvlife/deepseek-harness-desktop/releases/latest/download/DeepSeek-Harness-Desktop-0.2.0.dmg
- 🐙 源码仓库：https://github.com/vvlife/deepseek-harness-desktop

欢迎提 Issue、PR，或者只是来点个赞。

---

## 社交媒体文案（可直接复制）

### 标题

> DeepSeek Harness Desktop：331 KB 的 Mac 安装器，一键把 Paseo + dsh 跑起来。

### 正文（140 字内）

厌倦了给 Paseo 配 dsh 环境？DeepSeek Harness Desktop 用一个原生 SwiftUI App 解决：双击 DMG 装好 CLI、填 API Key 就能用。支持 DeepSeek 官方 / Agnes / 自定义 OpenAI 端点，不重启 Paseo daemon。开源免费，MIT 协议。

🔗 https://dsh-desktop.vercel.app
📦 https://github.com/vvlife/deepseek-harness-desktop/releases/latest

---

*最后更新：v0.2.0*
