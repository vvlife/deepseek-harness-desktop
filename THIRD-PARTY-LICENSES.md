# 第三方组件许可（Third-Party Licenses）

本项目涉及以下上游组件。各组件由其各自权利人授权；APP 内置的组件均为**未经修改**的
上游发布物原样打包，并保留各自 LICENSE / 版权信息。

## 随 APP 一起分发的组件（DeepSeek Harness Desktop.app 内置）

### Paseo（daemon / CLI / 服务端 / Web UI）— AGPL-3.0

- 项目：https://github.com/getpaseo/paseo
- 许可：GNU Affero General Public License v3.0（见上游仓库 `LICENSE`）
- 获取渠道：上游 GitHub Releases 官方 DMG（`Paseo-0.4.0-arm64/x64.dmg`）
- 打包方式：从官方 DMG **原样**解包 `app.asar`（纯 JS：daemon、CLI、服务端）、
  `app.asar.unpacked`（N-API 原生模块，arm64/x64 双架构合并）与 `app-dist`（Web UI 静态资源），
  不修改任何文件；**不包含** Electron 本体（daemon/CLI 为纯 Node 程序，用下方内置 Node 运行）。
- 对应完整源码：https://github.com/getpaseo/paseo （按 v0.4.0 tag 获取）

### Node.js — MIT

- 项目：https://nodejs.org/
- 许可：MIT（见 `Contents/Resources/runtime/node/LICENSE-node`，
  上游：https://raw.githubusercontent.com/nodejs/node/main/LICENSE）
- 获取渠道：nodejs.org 官方 dist（`node-v22.22.1-darwin-arm64/x64.tar.gz`，
  构建时校验 SHASUMS256 后用 lipo 合并为 universal 二进制）

### DeepSeek Harness（dsh）— MIT

- 项目：https://github.com/deepseek-ai/deepseek-harness
- npm：`@deepseek-ai/dsh@0.1.0-rc.6`（固定版本）
- 许可：MIT（见 `Contents/Resources/runtime/dsh/LICENSE`）
- 说明：完整 npm 依赖树（含 node-pty、sharp、koffi 等原生模块的 darwin arm64/x64
  预编译产物）经 npm 从官方 registry 原样安装，各依赖许可见其各自包内文件。

## 仅在用户选择时从官方渠道安装的组件

### Paseo 桌面版 / Node.js（curl|bash 安装器路径）

- 使用 curl|bash 安装器时：Paseo 经 Homebrew cask 或上游官方 DMG 原样安装；
  目标机缺少 Node ≥22.19 时经 Homebrew 安装 Node。均不涉及重新分发。

以上组件的商标与名称归各自所有者。本仓库自身代码采用 MIT 许可（见 `LICENSE`）。
