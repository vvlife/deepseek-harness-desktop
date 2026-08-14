# 第三方组件许可（Third-Party Licenses）

本仓库的安装脚本会下载并安装以下**未经修改**的上游组件。各组件由其各自权利人授权，
本仓库不包含、不修改、也不重新分发它们的二进制（安装时从官方渠道获取）。

## Paseo — AGPL-3.0

- 项目：https://github.com/getpaseo/paseo
- 许可：GNU Affero General Public License v3.0（见上游仓库 `LICENSE`）
- 获取渠道：Homebrew cask `paseo` 或上游 GitHub Releases 的官方 DMG
- 说明：本安装器仅原样安装上游发布物，未做任何修改；对应完整源码可在上方链接按版本获取。

## DeepSeek Harness（dsh）— MIT

- 项目：https://github.com/deepseek-ai/deepseek-harness
- npm：`@deepseek-ai/dsh`（安装器固定安装 `0.1.0-rc.6`）
- 许可：MIT（见上游仓库）

## Node.js — MIT

- 项目：https://nodejs.org/（许可：https://raw.githubusercontent.com/nodejs/node/main/LICENSE）
- 仅在目标机缺少 Node ≥22.19 时，由安装器通过 Homebrew 安装。

以上组件的商标与名称归各自所有者。本仓库自身代码采用 MIT 许可（见 `LICENSE`）。
