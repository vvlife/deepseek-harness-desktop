#!/bin/sh
# dsh-desktop-env.sh — 让当前 shell 使用 DeepSeek Harness Desktop 内置的
# dsh / paseo / node（而不是本机全局安装的那一份）。
#
# 用法：
#   source dsh-desktop-env.sh [APP_BUNDLE_PATH]
#   # 之后：which dsh / which paseo / which node 都指向包内版本
#   dsh --version
#   paseo --version
#
# 不传 APP_BUNDLE_PATH 时按以下顺序自动探测：
#   1. 环境变量 DSH_DESKTOP_BUNDLE
#   2. /Applications/DeepSeek Harness Desktop.app
#   3. 仓库内的构建产物 app/build/DeepSeek Harness Desktop.app
#
# 原理：把 <bundle>/Contents/Resources/runtime/node/bin 放到 PATH 最前，
# 并导出 DSH_DESKTOP_BIN / DSH_HOME / PASEO_HOME。
# 这与 APP 自身拉起 dsh web 时注入 PATH 的逻辑一致——保证「APP 内嵌终端」
# 与「本脚本」解析到的 dsh/paseo 是同一份包内命令。
#
# 注意：本脚本只影响「source 它的那个 shell 进程」，不会改动系统任何配置。

set -e

# 自动探测 .app 包路径
detect_bundle() {
  if [ -n "${DSH_DESKTOP_BUNDLE:-}" ]; then
    printf '%s\n' "$DSH_DESKTOP_BUNDLE"; return 0
  fi
  local candidates="/Applications/DeepSeek Harness Desktop.app"
  # 仓库内构建产物（相对脚本位置回溯两级到仓库根，再进 app/build）
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  local repo_root="$script_dir/../.."
  candidates="$candidates $repo_root/app/build/DeepSeek Harness Desktop.app"
  for c in $candidates; do
    if [ -d "$c" ]; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}

BUNDLE="${1:-}"
if [ -z "$BUNDLE" ]; then
  BUNDLE="$(detect_bundle)" || {
    echo "dsh-desktop-env: 找不到 DeepSeek Harness Desktop.app，请传入路径或设置 DSH_DESKTOP_BUNDLE" >&2
    return 1 2>/dev/null || exit 1
  }
fi

# 标准化为绝对路径
case "$BUNDLE" in
  /*) ;;
  *) BUNDLE="$(cd "$(dirname "$BUNDLE")" && pwd)/$(basename "$BUNDLE")" ;;
esac

BIN="$BUNDLE/Contents/Resources/runtime/node/bin"
if [ ! -x "$BIN/dsh" ] || [ ! -x "$BIN/paseo" ] || [ ! -x "$BIN/node" ]; then
  echo "dsh-desktop-env: 包内运行时不完整（缺少 $BIN 下的 dsh/paseo/node）" >&2
  return 1 2>/dev/null || exit 1
fi

# 放进 PATH 最前（与 APP 自身 processEnv() 一致）
case ":$PATH:" in
  *":$BIN:"*) ;;                              # 已在 PATH 中，无需重复
  *) PATH="$BIN:$PATH" ;;
esac
export PATH
export DSH_DESKTOP_BIN="$BIN"

# 私有数据目录（与 APP 内 DaemonManager 的 paseo-home / dsh-home 对齐，
# 仅用于让命令行 dsh/paseo 复用同一份配置；不强制覆盖用户已有值）
APP_SUPPORT="$HOME/Library/Application Support/DeepSeek Harness Desktop"
export DSH_HOME="${DSH_HOME:-$APP_SUPPORT/dsh-home}"
export PASEO_HOME="${PASEO_HOME:-$APP_SUPPORT/paseo-home}"

echo "dsh-desktop-env: 已切换为包内运行时 ($BIN)"
echo "  dsh  -> $(command -v dsh)"
echo "  paseo-> $(command -v paseo)"
echo "  node -> $(command -v node)"
