# 更新日志

本文件按版本记录变更。GitHub Release 的发布说明会自动取**最新版本**一节（由 `dmg.yml` 抽取），无需手动粘贴。

## [v0.3.9] - 2026-08-16

### 修复（重要：安装拦截）
- **DMG 安装拦截修复**：旧版本用构建机自签名证书（`DSH Desktop Local Code Signing`）签名且
  未做 Apple 公证，导致所有下载用户被 Gatekeeper 拦截（"无法验证是否包含恶意软件"）。
  新版本改用 **Developer ID Application** 证书签名（hardened runtime + 可信时间戳），并由
  `app/notarize.sh` 自动提交 Apple 公证、装订票据。下载即装，不再弹安全警告。
- 配套新增 `app/entitlements.plist`（放行内嵌 node / node-pty 的 fork+exec 与网络访问）、
  改造 `app/make-app.sh` 签名段与 `.github/workflows/dmg.yml`（从 secrets 注入 Developer ID
  证书与公证凭证）。详见 `app/notarize.sh` 头部注释与 README「发布前准备」。

### 新增
- 接入 [dsh-skill-manager](https://github.com/vvlife/dsh-skill-manager) 插件：Web 界面「设置」新增「🧩 技能管理」面板，浏览 / 新建 / 编辑 / 删除 / 导入全局与项目级 skills，另带「🐋 ClawHub」市场 tab 一键安装社区技能。README / 宣传站同步更新。

## [v0.3.8] - 2026-08-15

### 修复
- **内嵌终端命令解析保证**：`app/DesktopApp.swift` 的 `processEnv()` 把包内 `runtime/node/bin`（内含 `dsh`/`paseo`/`node` shim）放到 `PATH` **最前**。此前放在末尾，一旦本机装了全局 `dsh`/`paseo`，APP 内嵌终端会优先命中全局版，违背"零前置依赖、不干扰本机 dsh/Paseo"的承诺。现在内嵌终端（`/bin/bash --noprofile --norc -i`）继承父进程 PATH 后，命中的一定是包内版本。

### 改进（可复用 / 可验证）
- 抽出 `bundledBinDir` 单一来源；运行时缺失时退回标准 PATH，避免 PATH 以冒号开头的空段隐患；并导出 `DSH_DESKTOP_BIN`。
- 新增 `app/scripts/dsh-desktop-env.sh`：用户/协作者在自己终端 `source` 一下即可临时使用包内 `dsh`/`paseo`/`node`（不改任何系统配置）。
- 新增 `scripts/verify-bundled-cli.sh`：模拟内嵌终端校验 `dsh`/`paseo`/`node` 命中包内版本，已挂到 `dmg.yml`，**每次出 DMG 前自动跑，命中包外即拒绝发版**。

### 其他
- 新增免 Key 联网搜索插件 `dsh-web-search-free`（`plugin/`）。
- CI（`full` job）补装 `pnpm`（`dsh plugin add` 依赖）。
- 宣传站改版为白蓝风格 + 互链 awesome 插件精选列表；插件市场截图更新为亮色主题。

## [v0.3.7] - 2026-08-15
- 更换应用图标（蓝绿渐变 D + 星点）。

## [v0.3.6] - 2026-08-15
- 切换器贴合分段宽度；右侧工具栏按钮恢复默认间距，分开排列。

## [v0.3.5] - 2026-08-15
- 工具栏 UI：配对按钮双界面常驻、去掉浏览器按钮、图标收紧。

## [v0.3.4] - 2026-08-15
- 界面改名 Mobile / Web，Web 视图常驻不重载。

## [v0.3.3] - 2026-08-15
- Harness Web 会话跨端镜像（手机可见 / 可续聊）。

## [v0.3.2] - 2026-08-14
- 双界面切换（Paseo ↔ Harness Web）、移动端直连子页面、启动健壮性增强。

## [v0.3.1] - 2026-08-14
- 修复 Web UI host 连接死循环、首次引导、APP 图标。

## [v0.3.0] - 2026-08-14
- 自包含桌面 APP：内置 Paseo + dsh provider，开箱即用。

## [v0.2.0] - 2026-08-14
- DMG 图形安装器 + 宣传站。

## [v0.1.0] - 2026-08-14
- 首个版本。
