#!/usr/bin/env bash
# DeepSeek Harness Desktop — 一键安装（macOS）
#
#   curl -fsSL https://raw.githubusercontent.com/vvlife/deepseek-harness-desktop/main/install.sh | bash
#
# 做什么：
#   1. 预检 macOS / Node ≥22.19（缺失时经 Homebrew 补齐，Homebrew 也没有可引导安装）
#   2. 安装 dsh（npm 全局，固定 @deepseek-ai/dsh@0.1.0-rc.6）
#   3. 安装 Paseo（brew cask；无 brew 时退到官方 DMG）
#   4. 安装 ACP 桥并运行首次配置向导（provider 可选：DeepSeek 官方 / Agnes / 自定义）
#   5. 注册 Paseo provider、跑冒烟自检（默认不重启正在运行的 Paseo daemon）
#
# flags：
#   --provider deepseek|agnes|custom  --key sk-...  --base-url --model
#   --provider-id --env-name --display-name   （以上透传给 setup-provider.mjs）
#   --yes          非交互（全默认；仍需 --key 或已有凭据，除非 --skip-auth）
#   --skip-auth    跳过凭据配置（稍后可重跑或在 dsh web 里填）
#   --skip-dsh     跳过 dsh 安装
#   --skip-paseo   跳过 Paseo 安装与注册
#   --restart-daemon 装完重启 Paseo daemon（默认不打扰正在运行的 daemon，
#                    配置在下次重启 Paseo 时生效）
#   --uninstall    移除桥/provider 注册/路由 patch（不动 dsh、Paseo 本体与凭据）
# 环境变量：DSH_HOME、PASEO_HOME、INSTALL_REF（默认 main）、DSH_BIN
set -euo pipefail

DSH_PKG="@deepseek-ai/dsh@0.1.0-rc.6"
DSH_VERSION="0.1.0-rc.6"
PASEO_DMG_VERSION="0.4.0"
REPO="vvlife/deepseek-harness-desktop"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '✔ %s\n' "$*"; }
warn(){ printf '! %s\n' "$*" >&2; }
die() { printf '✘ %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,28p' "$0"; }

SKIP_DSH=0
SKIP_PASEO=0
UNINSTALL=0
RESTART_DAEMON=0
SETUP_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-dsh) SKIP_DSH=1 ;;
    --skip-paseo) SKIP_PASEO=1; SETUP_ARGS+=("$1") ;;
    --restart-daemon) RESTART_DAEMON=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --help|-h) usage; exit 0 ;;
    *) SETUP_ARGS+=("$1") ;;
  esac
  shift
done

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# --- 工作目录与仓库文件（curl|bash 时先拉 tarball） ---------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SOURCE="${BASH_SOURCE[0]:-}"
if [ -n "$SOURCE" ] && [ -f "$SOURCE" ] && [ -d "$(dirname "$SOURCE")/scripts" ]; then
  REPO_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
else
  REF="${INSTALL_REF:-main}"
  log "下载仓库文件（$REPO@$REF）"
  curl -fSL "https://codeload.github.com/$REPO/tar.gz/$REF" -o "$WORK/repo.tar.gz" \
    || die "下载失败，请检查网络或 INSTALL_REF"
  tar -xzf "$WORK/repo.tar.gz" -C "$WORK"
  REPO_DIR="$(find "$WORK" -maxdepth 1 -type d -name 'deepseek-harness-desktop-*' | head -1)"
  [ -n "$REPO_DIR" ] || die "解压仓库失败"
fi

DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
BRIDGE_DIR="$DSH_HOME_DIR/paseo-bridge"

# --- 卸载 ---------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  log "卸载 DeepSeek Harness Desktop 组件"
  node "$REPO_DIR/scripts/setup-provider.mjs" --uninstall
  if [ "$SKIP_PASEO" = 0 ] && command -v paseo >/dev/null 2>&1 && paseo daemon status >/dev/null 2>&1; then
    ok "Paseo daemon 正在运行（未打扰）；方便时执行 paseo daemon restart 使移除生效"
  fi
  ok "卸载完成"
  exit 0
fi

# --- 1. 预检 -------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "仅支持 macOS"
log "预检环境（macOS $(sw_vers -productVersion)，$(uname -m)）"

node_ok() {
  command -v node >/dev/null 2>&1 && \
    node -e "const [a,b]=process.versions.node.split('.').map(Number);process.exit(a>22||(a===22&&b>=19)?0:1)"
}

find_brew() {
  command -v brew >/dev/null 2>&1 && return 0
  [ -x /opt/homebrew/bin/brew ] && { export PATH="/opt/homebrew/bin:$PATH"; return 0; }
  [ -x /usr/local/bin/brew ] && { export PATH="/usr/local/bin:$PATH"; return 0; }
  return 1
}

if ! node_ok; then
  if find_brew; then
    log "安装 Node.js（brew install node）"
    brew install node || die "Node 安装失败"
  else
    warn "未检测到 Homebrew；dsh 需要 Node ≥22.19，最省事的途径是 Homebrew。"
    if [ -e /dev/tty ]; then
      printf '按回车安装 Homebrew（可能提示输入开机密码），Ctrl-C 取消: ' >/dev/tty
      read -r _ </dev/tty
      NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty \
        || die "Homebrew 安装失败"
      find_brew || die "装完 Homebrew 后仍找不到 brew，请新开终端重跑"
      brew install node || die "Node 安装失败"
    else
      die "无交互终端，无法引导安装 Homebrew；请手动安装 Node ≥22.19 后重跑"
    fi
  fi
  node_ok || die "Node ≥22.19 仍不可用"
fi
ok "Node $(node -v)"

# --- 2. dsh ---------------------------------------------------------------------
if [ "$SKIP_DSH" = 1 ]; then
  warn "跳过 dsh 安装（--skip-dsh）"
elif [ "${DSH_BIN:-}" = "" ] && command -v dsh >/dev/null 2>&1 && [ "$(dsh --version 2>/dev/null)" = "$DSH_VERSION" ]; then
  ok "dsh $DSH_VERSION 已安装"
else
  log "安装 dsh（npm i -g $DSH_PKG，约 340MB，请稍候）"
  npm install -g "$DSH_PKG" || die "dsh 安装失败"
  ok "dsh $(dsh --version 2>/dev/null || echo "$DSH_VERSION")"
fi

# --- 3. Paseo -------------------------------------------------------------------
if [ "$SKIP_PASEO" = 1 ]; then
  warn "跳过 Paseo 安装（--skip-paseo）"
elif [ -d /Applications/Paseo.app ]; then
  ok "Paseo 已安装"
else
  if find_brew; then
    log "安装 Paseo（brew install --cask paseo）"
    brew install --cask paseo || die "Paseo 安装失败"
  else
    arch="$(uname -m)"; [ "$arch" = "arm64" ] || arch="x64"
    url="https://github.com/getpaseo/paseo/releases/download/v${PASEO_DMG_VERSION}/Paseo-${PASEO_DMG_VERSION}-${arch}.dmg"
    log "安装 Paseo（官方 DMG：$url）"
    curl -fSL "$url" -o "$WORK/paseo.dmg" || die "Paseo DMG 下载失败"
    mnt="$WORK/paseo-mnt"; mkdir -p "$mnt"
    hdiutil attach "$WORK/paseo.dmg" -mountpoint "$mnt" -nobrowse -quiet || die "DMG 挂载失败"
    cp -R "$mnt/Paseo.app" /Applications/ || { hdiutil detach "$mnt" -quiet; die "复制 Paseo.app 失败（/Applications 权限不足？）"; }
    hdiutil detach "$mnt" -quiet || true
  fi
  ok "Paseo 已安装"
fi

# --- 4. ACP 桥 + 首次配置向导 ----------------------------------------------------
log "安装 ACP 桥"
mkdir -p "$BRIDGE_DIR"
cp "$REPO_DIR/bridge/dsh-acp-bridge.mjs" "$BRIDGE_DIR/dsh-acp-bridge.mjs"
chmod 755 "$BRIDGE_DIR/dsh-acp-bridge.mjs"
ok "桥已就位 $BRIDGE_DIR/dsh-acp-bridge.mjs"

log "首次运行配置（provider 选择 + 凭据）"
node "$REPO_DIR/scripts/setup-provider.mjs" "${SETUP_ARGS[@]}"

# --- 5. daemon 与冒烟自检 -------------------------------------------------------
PASEO_CLI=""
if command -v paseo >/dev/null 2>&1; then PASEO_CLI="paseo";
elif [ -x /Applications/Paseo.app/Contents/Resources/bin/paseo ]; then PASEO_CLI="/Applications/Paseo.app/Contents/Resources/bin/paseo"; fi

# 默认不打扰正在运行的 daemon（用户可能正在用 Paseo）；--restart-daemon 才显式重启
if [ "$SKIP_PASEO" = 0 ] && [ -n "$PASEO_CLI" ] && [ -d "${PASEO_HOME:-$HOME/.paseo}" ]; then
  if [ "$RESTART_DAEMON" = 1 ]; then
    log "重启 Paseo daemon（--restart-daemon）"
    "$PASEO_CLI" daemon restart >/dev/null 2>&1 || "$PASEO_CLI" daemon start >/dev/null 2>&1 || \
      warn "daemon 重启失败，可稍后手动执行 paseo daemon restart"
  elif "$PASEO_CLI" daemon status >/dev/null 2>&1; then
    ok "Paseo daemon 正在运行（未打扰）；配置已写入，方便时执行 paseo daemon restart 生效"
  else
    ok "Paseo daemon 未运行；配置会在下次启动 Paseo 时生效"
  fi
fi

log "冒烟自检"
SMOKE_ARGS=()
[ "$SKIP_PASEO" = 0 ] && SMOKE_ARGS+=(--require-paseo)
case " ${SETUP_ARGS[*]} " in *" --skip-auth "*) SMOKE_ARGS+=(--skip-auth);; esac
node "$REPO_DIR/scripts/smoke-test.mjs" "${SMOKE_ARGS[@]}" || die "冒烟自检未通过，请把上方输出发给维护者"

cat <<'EOF'

🐋 DeepSeek Harness Desktop 安装完成！

  打开 Paseo（启动台或 open -a Paseo）→ 新建 agent → 选择 "DeepSeek Harness"。
  切换 provider / 补填 key：重跑本脚本（--provider/--key），或用 dsh web 的模型设置页。
  卸载：bash install.sh --uninstall
EOF

# 交互终端里顺手帮用户打开 Paseo
if [ "$SKIP_PASEO" = 0 ] && [ -t 1 ] && [ -z "${CI:-}" ] && [ -d /Applications/Paseo.app ]; then
  open -a Paseo || true
fi
