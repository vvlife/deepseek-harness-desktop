# DeepSeek Harness Desktop

**[🐋 宣传站](https://vvlife.github.io/deepseek-harness-desktop/)** ·
**[⬇ DMG 下载](https://github.com/vvlife/deepseek-harness-desktop/releases/latest)** ·
[Release Notes](https://github.com/vvlife/deepseek-harness-desktop/releases)

一行命令（或双击 DMG），把 **DeepSeek Harness（dsh）+ Paseo** 装好并接通：打开 Paseo，新建 agent 选
**DeepSeek Harness** 即可使用。LLM 提供商在安装向导中可选：**DeepSeek 官方（默认）/
Agnes AI / 自定义 OpenAI 兼容端点**。

> One-line macOS installer for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
> + [Paseo](https://github.com/getpaseo/paseo): installs dsh (pinned), Paseo, and a zero-dependency
> ACP bridge, then walks you through picking an LLM provider and pasting an API key.
> Also available as a tiny native SwiftUI DMG installer.

## 一键安装

方式一：终端一行命令（无 Gatekeeper 提示，推荐）

```sh
curl -fsSL https://raw.githubusercontent.com/vvlife/deepseek-harness-desktop/main/install.sh | bash
```

方式二：DMG 图形安装器（原生 SwiftUI，universal，约 330KB）

下载 [DeepSeek-Harness-Desktop-0.2.0.dmg](https://github.com/vvlife/deepseek-harness-desktop/releases/latest/download/DeepSeek-Harness-Desktop-0.2.0.dmg)
打开，选 provider、填/留空 Key，点「开始安装」。
未做 Apple 公证：macOS 15 首次打开需「系统设置 → 隐私与安全性 → 仍要打开」，
或 `xattr -d com.apple.quarantine "DeepSeek Harness Desktop Installer.app"`。

安装器会依次：

1. 预检 macOS 与 Node ≥22.19（缺失时经 Homebrew 补齐；Homebrew 也没有时可引导安装）
2. 安装 dsh：`npm i -g @deepseek-ai/dsh@0.1.0-rc.6`（固定版本）
3. 安装 Paseo：`brew install --cask paseo`（无 brew 时退到官方 DMG）
4. 安装 ACP 桥并进入**首次配置向导**：选 provider → 帮你打开对应平台建 key 页面 → 粘贴 key（自动校验）
5. 注册 Paseo provider 并跑冒烟自检。**默认不打扰正在运行的 Paseo daemon**
   （配置在下次重启 Paseo 时生效；想立即生效可加 `--restart-daemon`）

装完自动打开 Paseo。新建 agent 时 provider 选 **DeepSeek Harness**，可按会话切换模型。

### 关于"DeepSeek 登录"

DeepSeek 的 API **没有账号 OAuth 登录**。向导中的"登录"= 帮你打开
[platform.deepseek.com](https://platform.deepseek.com/api_keys)（在那里登录 DeepSeek 账号、
创建 API Key），回到终端粘贴即可。key 写入 `~/.dsh/.credentials.yaml`（权限 0600）。

## 常用参数

```sh
# 非交互：直接指定 provider 与 key
curl -fsSL .../install.sh | bash -s -- --yes --provider deepseek --key sk-...

# 用 Agnes / 自定义 OpenAI 兼容端点
... bash -s -- --yes --provider agnes --key sk-...
... bash -s -- --yes --provider custom --base-url https://api.example.com/v1 --model my-model --key sk-...

# 跳过凭据（稍后在 dsh web 的模型设置页填，127.0.0.1:3080）
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
| `--uninstall` | 卸载本安装器写入的内容（见下） |

## 卸载

```sh
bash install.sh --uninstall
```

移除 ACP 桥、`provider.json`、Paseo provider 注册、`~/.dsh/cordis.patch.yml` 中本工具写入的路由块。
**不动**：`~/.dsh/.credentials.yaml` 里的 key、dsh 本体（`npm uninstall -g @deepseek-ai/dsh`）、
Paseo 本体（`brew uninstall --cask paseo`）。

## 自检

安装末尾自动跑 `scripts/smoke-test.mjs`（ACP 协议握手 + 配置断言，不发起真实 LLM 调用）。
手动重跑：

```sh
node scripts/smoke-test.mjs                # 基础自检
node scripts/smoke-test.mjs --e2e          # 追加一次真实 dsh 调用（消耗少量 API 额度）
```

## FAQ

**会被 Gatekeeper 拦吗？** curl 方式不会（不经过 Gatekeeper）。DMG 图形安装器是 ad-hoc 签名、
未公证：macOS 15 首次打开需「系统设置 → 隐私与安全性 → 仍要打开」或
`xattr -d com.apple.quarantine` 该 app。dsh/Paseo 分别从 npm 与官方签名 DMG 原样安装。

**Paseo 里的对话为什么没有上下文？** 每个 prompt 回合是一次独立的 `dsh --profile headless`
运行（dsh headless 无 resume），回合间不保留对话上下文。

**dsh 的遥测怎么关？** dsh 默认向 deepseeksvc.com 上报遥测，退出方式：
`export DSH_TELEMETRY_DISABLED=1`（写入 shell rc 持久化）。

**和 dsh-agnes-paseo 什么关系？** 本仓库是其演进形态：provider 从写死 Agnes 变为可选，
并升级为完整的一键安装包。旧插件不受影响；想清理可
`dsh plugin --profile headless remove dsh-agnes-paseo`。

**想换 provider？** 重跑一次安装脚本（或 `node scripts/setup-provider.mjs`）选择新的即可，
凭据层中已有的其他 key 不受影响。

**DMG 图形安装器在哪？** [Releases 页](https://github.com/vvlife/deepseek-harness-desktop/releases/latest)
直接下载（`app/make-app.sh` 本地可复现构建：swiftc 直编 SwiftUI + ad-hoc 签名 + hdiutil）。

## 许可

本仓库代码 MIT（`LICENSE`）。安装的第三方组件均为**未修改**的上游发布物，
许可与源码链接见 `THIRD-PARTY-LICENSES.md`（Paseo 为 AGPL-3.0）。
