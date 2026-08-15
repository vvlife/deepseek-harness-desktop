#!/usr/bin/env bash
# 构建自包含的 DeepSeek Harness Desktop.app（universal）并打成 DMG。
#
#   app/make-app.sh [版本号]      # 默认取 git describe 或 0.3.1
#
# APP 内置 universal Node 运行时、完整 Paseo（daemon + Web UI + 移动端直连）
# 与完整 dsh（作为 Paseo 的 agent provider，经 ACP 桥接入）。
# 用户零前置依赖：拖进「应用程序」即用；使用私有 PASEO_HOME/DSH_HOME 与非默认端口，
# 不依赖、不干扰本机已有的 Node/Homebrew/dsh/Paseo。
#
# 构建机需要：swiftc（xcode-select --install）、curl、node+npm（用于 dsh 依赖树与 asar 解包）。
# 产出：app/build/DeepSeek-Harness-Desktop-<version>.dmg
#
# 签名：优先使用钥匙串里的「DSH Desktop Local Code Signing」自签名证书（身份稳定，
# macOS 的目录访问授权按证书锚定、跨重新构建持久，不会每次构建后重新弹窗）；
# 没有该证书则回退 ad-hoc（--sign -，cdhash 逐构建变化，授权记录随之失效）。
# 可用 DSH_SIGN_IDENTITY 显式指定身份（如 "Apple Development: …"，"-" 强制 ad-hoc）。
# 无付费开发者账号：用户在 macOS 15 首次打开需「系统设置 → 隐私与安全性 → 仍要打开」，
# 或 xattr -d com.apple.quarantine。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/app"
BUILD="$APP_SRC/build"
APP="$BUILD/DeepSeek Harness Desktop.app"
BIN="DSHDesktop"
VERSION="${1:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.3.6)}"
DMG="$BUILD/DeepSeek-Harness-Desktop-${VERSION}.dmg"

NODE_VERSION="22.22.1"
DSH_PKG="@deepseek-ai/dsh@0.1.0-rc.6"
PASEO_VERSION="0.4.0"

RES="$APP/Contents/Resources"
RUNTIME="$RES/runtime"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die() { printf '✘ %s\n' "$*" >&2; exit 1; }

command -v swiftc >/dev/null 2>&1 || die "需要 swiftc（xcode-select --install）"
command -v npm   >/dev/null 2>&1 || die "构建机需要 node+npm（用于安装 dsh 依赖树）"
command -v lipo  >/dev/null 2>&1 || die "需要 lipo（Xcode 命令行工具）"

echo "==> 清理并创建 bundle（v${VERSION}）"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$RUNTIME/node/bin" "$RES/installer" \
  "$BUILD/dl" "$BUILD/stage-arm64" "$BUILD/stage-x64" \
  "$BUILD/paseo-arm64" "$BUILD/paseo-x64"

# 下载缓存（跨构建复用，gitignore）：存在即跳过，否则断点续传 + 重试
CACHE="$APP_SRC/.cache/dl"
mkdir -p "$CACHE"
download() { # download <url> <dest>
  local url="$1" dest="$2"
  [ -s "$dest" ] && { printf '    缓存命中：%s\n' "$(basename "$dest")"; return 0; }
  curl -fSL --connect-timeout 30 --retry 5 --retry-delay 5 --retry-all-errors -C - \
    "$url" -o "$dest"
}

# ---------------------------------------------------------------------------
# 1. universal Node 运行时（官方 per-arch dist，lipo 合并）
# ---------------------------------------------------------------------------
log "下载 Node v${NODE_VERSION}（arm64 + x64）"
SHASUMS="$CACHE/SHASUMS256-node-v${NODE_VERSION}.txt"
download "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" "$SHASUMS" \
  || die "Node 校验和下载失败"
for arch in arm64 x64; do
  tgz="$CACHE/node-v${NODE_VERSION}-darwin-${arch}.tar.gz"
  download "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-darwin-${arch}.tar.gz" \
    "$tgz" || die "Node ${arch} 下载失败"
  (cd "$CACHE" && grep "darwin-${arch}.tar.gz" "SHASUMS256-node-v${NODE_VERSION}.txt" | shasum -a 256 -c - >/dev/null) \
    || { rm -f "$tgz"; die "Node ${arch} 校验和不匹配（已删除缓存，请重跑）"; }
  mkdir -p "$BUILD/node-${arch}"
  tar -xzf "$tgz" -C "$BUILD/node-${arch}" --strip-components 1
done

log "lipo 合并 universal node"
lipo -create \
  "$BUILD/node-arm64/bin/node" "$BUILD/node-x64/bin/node" \
  -output "$RUNTIME/node/bin/node"
chmod 755 "$RUNTIME/node/bin/node"
cp "$BUILD/node-arm64/LICENSE" "$RUNTIME/node/LICENSE-node"

# dsh shim：让内置运行时表现得像装了 dsh 的 bin 目录（Paseo 桥/用户脚本可用）
cat > "$RUNTIME/node/bin/dsh" <<'EOF'
#!/bin/sh
# DeepSeek Harness Desktop 内置 dsh 入口（等价于全局安装的 dsh CLI）
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/node" "$DIR/../../dsh/lib/bin.js" "$@"
EOF
chmod 755 "$RUNTIME/node/bin/dsh"

# ---------------------------------------------------------------------------
# 2. dsh 依赖树（arm64 基准 + x64 原生包合并）
# ---------------------------------------------------------------------------
log "安装 dsh 依赖树（arm64，global-style 嵌套布局）"
npm install --prefix "$BUILD/stage-arm64" --global-style --no-audit --no-fund --loglevel=error "$DSH_PKG"
log "安装 dsh 依赖树（x64 原生包）"
# x64 树仅作原生包供体：--ignore-scripts 跳过 install 脚本
# （koffi 等按 process.arch 探测预编译包，交叉安装时会误编译源码而失败）
npm install --prefix "$BUILD/stage-x64" --global-style --no-audit --no-fund --loglevel=error \
  --os=darwin --cpu=x64 --ignore-scripts "$DSH_PKG"

# --global-style：依赖嵌套在包内 node_modules（同全局安装布局），不做提升。
# 这样运行时只需拷贝 dsh 包自身（含其 node_modules）即可独立运行。
ARM_NM="$BUILD/stage-arm64/node_modules/@deepseek-ai/dsh"
X64_NM="$BUILD/stage-x64/node_modules/@deepseek-ai/dsh/node_modules"
[ -d "$ARM_NM/node_modules" ] || die "dsh 依赖树布局异常（$ARM_NM/node_modules 不存在）"

log "合并 x64 平台专属包（*darwin-x64*）"
copied=0
while IFS= read -r dir; do
  rel="${dir#"$X64_NM"/}"
  dest="$ARM_NM/node_modules/$rel"
  if [ ! -d "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    cp -R "$dir" "$dest"
    copied=$((copied + 1))
    printf '    + %s\n' "$rel"
  fi
done < <(find "$X64_NM" -maxdepth 2 -mindepth 1 -type d -name "*darwin-x64*")
[ "$copied" -gt 0 ] || die "未找到任何 x64 平台包，合并失败"

# 完整性校验：x64 树的每个 .node 都必须在合并后的树里有对应文件
missing=0
while IFS= read -r f; do
  rel="${f#"$X64_NM"/}"
  case "$rel" in *win32*|*linux*|*darwin-arm64*) continue;; esac
  [ -f "$ARM_NM/node_modules/$rel" ] || { printf '    ✘ 缺失 %s\n' "$rel"; missing=$((missing + 1)); }
done < <(find "$X64_NM" -name "*.node" -type f)
[ "$missing" -eq 0 ] || die "x64 原生模块合并不完整（$missing 个缺失）"

log "裁剪（win32 prebuilds）"
rm -rf "$ARM_NM/node_modules/node-pty/prebuilds/win32-arm64" \
       "$ARM_NM/node_modules/node-pty/prebuilds/win32-x64"

log "拷贝 dsh 运行时到 APP"
mkdir -p "$RUNTIME/dsh"
cp "$ARM_NM/package.json" "$ARM_NM/LICENSE" "$RUNTIME/dsh/"
cp -R "$ARM_NM/lib" "$ARM_NM/config" "$ARM_NM/node_modules" "$RUNTIME/dsh/"

# ---------------------------------------------------------------------------
# 2.5 Paseo 运行时（官方 DMG 解包；daemon/CLI/服务端为纯 Node，可脱离 Electron）
# ---------------------------------------------------------------------------
# 只取纯 JS 的 app.asar 解包树 + app.asar.unpacked（原生模块，N-API 双架构合并）
# + app-dist（Web UI 静态资源）；不取 Electron 本体（daemon 用内置 Node 跑）。
PASEO_BASE="https://github.com/getpaseo/paseo/releases/download/v${PASEO_VERSION}"
for arch in arm64 x64; do
  pdmg="$CACHE/Paseo-${PASEO_VERSION}-${arch}.dmg"
  log "下载 Paseo v${PASEO_VERSION}（${arch}）"
  download "${PASEO_BASE}/Paseo-${PASEO_VERSION}-${arch}.dmg" "$pdmg" \
    || die "Paseo ${arch} DMG 下载失败"
  if ! hdiutil verify "$pdmg" >/dev/null 2>&1; then
    warn "Paseo ${arch} DMG 校验失败，删除缓存重试"
    rm -f "$pdmg"
    download "${PASEO_BASE}/Paseo-${PASEO_VERSION}-${arch}.dmg" "$pdmg" \
      || die "Paseo ${arch} DMG 重试下载失败"
    hdiutil verify "$pdmg" >/dev/null 2>&1 || { rm -f "$pdmg"; die "Paseo ${arch} DMG 仍损坏"; }
  fi
  mnt="$BUILD/paseo-mnt-${arch}"
  mkdir -p "$mnt"
  hdiutil attach "$pdmg" -mountpoint "$mnt" -nobrowse -quiet || die "Paseo DMG 挂载失败（${arch}）"
  cp -R "$mnt/Paseo.app" "$BUILD/paseo-${arch}/"
  hdiutil detach "$mnt" -quiet || die "Paseo DMG 卸载失败（${arch}）"
done

PRES_ARM="$BUILD/paseo-arm64/Paseo.app/Contents/Resources"
PRES_X64="$BUILD/paseo-x64/Paseo.app/Contents/Resources"
cp "$PRES_ARM/../Info.plist" "$BUILD/paseo-arm64/Info.plist" 2>/dev/null || true

log "解包 Paseo app.asar 并叠加 unpacked 原生树"
# v0.4.0 的 asar 头仍引用已从 unpacked 中裁剪的文件（他架构 prebuilds、个别 LICENSE），
# extractAll 会逐个报错但仍解出全部可用文件——用容忍模式解包，事后校验关键文件。
npm install --prefix "$BUILD/asar-tool" --no-audit --no-fund --loglevel=error @electron/asar \
  || die "asar 工具安装失败"
ASAR_LIB="$BUILD/asar-tool/node_modules/@electron/asar" \
  node -e '
    const { pathToFileURL } = require("node:url");
    (async () => {
      const asar = await import(pathToFileURL(process.env.ASAR_LIB + "/lib/asar.js").href);
      try {
        await asar.extractAll(process.argv[1], process.argv[2]);
        console.log("    asar 完整解包");
      } catch {
        console.warn("    ! 部分文件解包失败（官方包中本就缺失的负载），已容忍");
      }
    })();
  ' "$PRES_ARM/app.asar" "$RUNTIME/paseo"
cp -R "$PRES_ARM/app.asar.unpacked/" "$RUNTIME/paseo/"
cp -R "$PRES_ARM/app-dist" "$RUNTIME/paseo-app-dist"
cp "$PRES_ARM/app-update.yml" "$RUNTIME/paseo-app-dist/" 2>/dev/null || true
[ -f "$RUNTIME/paseo/node_modules/@getpaseo/cli/dist/index.js" ] || die "Paseo CLI 缺失（解包不完整）"
[ -d "$RUNTIME/paseo/node_modules/@getpaseo/server" ] || die "Paseo server 缺失（解包不完整）"

log "合并 Paseo x64 原生包"
PX64_NM="$PRES_X64/app.asar.unpacked/node_modules"
pcopied=0
# 1) *darwin-x64* 平台包整包拷贝
while IFS= read -r dir; do
  rel="${dir#"$PX64_NM"/}"
  dest="$RUNTIME/paseo/node_modules/$rel"
  if [ ! -d "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    cp -R "$dir" "$dest"
    pcopied=$((pcopied + 1))
    printf '    + %s\n' "$rel"
  fi
done < <(find "$PX64_NM" -maxdepth 2 -mindepth 1 -type d -name "*darwin-x64*")
# 2) 其余缺失 .node 按文件补齐（如 node-pty/prebuilds/darwin-x64——
#    v0.4.0 起 arm64 包的 unpacked 不再包含他架构 prebuild）
while IFS= read -r f; do
  rel="${f#"$PX64_NM"/}"
  case "$rel" in *win32*|*linux*|*darwin-arm64*) continue;; esac
  dest="$RUNTIME/paseo/node_modules/$rel"
  if [ ! -f "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    cp "$f" "$dest"
    pcopied=$((pcopied + 1))
    printf '    + %s（单文件）\n' "$rel"
  fi
done < <(find "$PX64_NM" -name "*.node" -type f)
[ "$pcopied" -gt 0 ] || die "未找到 Paseo x64 原生包，合并失败"

# 完整性校验：x64 unpacked 树的每个 .node 都必须在合并后的树里有对应文件
pmissing=0
while IFS= read -r f; do
  rel="${f#"$PX64_NM"/}"
  case "$rel" in *win32*|*linux*|*darwin-arm64*) continue;; esac
  [ -f "$RUNTIME/paseo/node_modules/$rel" ] || { printf '    ✘ 缺失 %s\n' "$rel"; pmissing=$((pmissing + 1)); }
done < <(find "$PX64_NM" -name "*.node" -type f)
[ "$pmissing" -eq 0 ] || die "Paseo x64 原生模块合并不完整（$pmissing 个缺失）"

log "裁剪 Paseo（linux/win32 prebuilds）"
rm -rf "$RUNTIME/paseo/node_modules/node-pty/prebuilds/linux-arm64" \
       "$RUNTIME/paseo/node_modules/node-pty/prebuilds/linux-x64" \
       "$RUNTIME/paseo/node_modules/node-pty/prebuilds/win32-arm64" \
       "$RUNTIME/paseo/node_modules/node-pty/prebuilds/win32-x64"

# paseo shim：内置 Paseo CLI（等价于 Paseo.app 里的 bin/paseo）
cat > "$RUNTIME/node/bin/paseo" <<'EOF'
#!/bin/sh
# DeepSeek Harness Desktop 内置 Paseo CLI
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/node" "$DIR/../../paseo/node_modules/@getpaseo/cli/dist/index.js" "$@"
EOF
chmod 755 "$RUNTIME/node/bin/paseo"

# ---------------------------------------------------------------------------
# 3. 配置脚本与 ACP 桥（设置页 / Paseo 接入用）
# ---------------------------------------------------------------------------
cp -R "$ROOT/scripts" "$ROOT/bridge" "$RES/installer/"
chmod 755 "$RES/installer/scripts/"*.mjs "$RES/installer/bridge/"*.mjs

# ---------------------------------------------------------------------------
# 4. 编译 SwiftUI 壳（universal）
# ---------------------------------------------------------------------------
log "编译 universal 壳（arm64 + x86_64, macOS 12+）"
for arch in arm64 x86_64; do
  swiftc -O -whole-module-optimization -parse-as-library \
    -target "${arch}-apple-macosx12.0" \
    -o "$BUILD/${BIN}-${arch}" "$APP_SRC/DesktopApp.swift"
done
lipo -create -output "$APP/Contents/MacOS/$BIN" "$BUILD/${BIN}-arm64" "$BUILD/${BIN}-x86_64"
rm "$BUILD/${BIN}-arm64" "$BUILD/${BIN}-x86_64"

sed "s/@VERSION@/${VERSION}/g" "$APP_SRC/Info.plist" > "$APP/Contents/Info.plist"

# ---------------------------------------------------------------------------
# 4.5 应用图标（AppKit 离屏绘制 iconset → iconutil 打 icns）
# ---------------------------------------------------------------------------
log "生成 AppIcon.icns"
swiftc -O -o "$BUILD/make-icon" "$APP_SRC/make-icon.swift"
"$BUILD/make-icon" "$BUILD/AppIcon.iconset" >/dev/null
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$RES/AppIcon.icns"

# ---------------------------------------------------------------------------
# 5. 签名（优先稳定身份「DSH Desktop Local Code Signing」，否则 ad-hoc；--deep 覆盖 node 与全部 .node）
# ---------------------------------------------------------------------------
SIGN_IDENTITY="${DSH_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "DSH Desktop Local Code Signing"; then
    SIGN_IDENTITY="DSH Desktop Local Code Signing"
  else
    SIGN_IDENTITY="-"
  fi
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
  log "ad-hoc 签名（文件较多，需一两分钟）"
else
  log "签名（身份：$SIGN_IDENTITY；文件较多，需一两分钟）"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

# ---------------------------------------------------------------------------
# 6. 构建后自测：包内运行时真跑 dsh web + Paseo daemon（含 provider 注册）
# ---------------------------------------------------------------------------
log "自测：包内运行时启动 dsh web"
TEST_HOME="$(mktemp -d)"
TEST_LOG="$BUILD/smoke.log"
DSH_HOME="$TEST_HOME/dsh" DSH_TELEMETRY_DISABLED=1 \
  "$RUNTIME/node/bin/node" "$RUNTIME/dsh/lib/bin.js" web --host 127.0.0.1 --port 0 \
  >"$TEST_LOG" 2>&1 &
TEST_PID=$!
TEST_URL=""
for _ in $(seq 1 60); do
  TEST_URL="$(grep -o 'http://127\.0\.0\.1:[0-9]*' "$TEST_LOG" 2>/dev/null | head -1 || true)"
  [ -n "$TEST_URL" ] && break
  sleep 1
done
[ -n "$TEST_URL" ] || { cat "$TEST_LOG"; kill "$TEST_PID" 2>/dev/null; die "自测：未等到 dsh web 地址"; }
curl -sf "$TEST_URL" -o /dev/null || { cat "$TEST_LOG"; kill "$TEST_PID" 2>/dev/null; die "自测：dsh web HTTP 失败"; }
kill "$TEST_PID" 2>/dev/null || true
wait "$TEST_PID" 2>/dev/null || true
echo "    ✔ dsh web 自测通过（${TEST_URL}）"

log "自测：Paseo daemon + provider 注册全链路"
SMOKE_P_HOME="$TEST_HOME/paseo-home"
SMOKE_D_HOME="$TEST_HOME/dsh-home"
SMOKE_PORT="19767"
mkdir -p "$SMOKE_P_HOME" "$SMOKE_D_HOME/paseo-bridge"

# 桥 + wrapper（与 APP 首次启动所做准备一致）
cp "$RES/installer/bridge/"*.mjs "$SMOKE_D_HOME/paseo-bridge/"
chmod 755 "$SMOKE_D_HOME/paseo-bridge/"*.mjs
cat > "$SMOKE_D_HOME/paseo-bridge/bridge-wrapper.sh" <<EOF
#!/bin/sh
export DSH_HOME="$SMOKE_D_HOME"
export DSH_BIN="$RUNTIME/node/bin/dsh"
export PATH="$RUNTIME/node/bin:/usr/bin:/bin"
exec "$RUNTIME/node/bin/node" "$SMOKE_D_HOME/paseo-bridge/dsh-acp-bridge.mjs"
EOF
chmod 755 "$SMOKE_D_HOME/paseo-bridge/bridge-wrapper.sh"

export PASEO_HOME="$SMOKE_P_HOME" PASEO_LISTEN="127.0.0.1:$SMOKE_PORT" \
  PASEO_WEB_UI_ENABLED=1 PASEO_WEB_UI_DIST_DIR="$RUNTIME/paseo-app-dist" \
  DSH_HOME="$SMOKE_D_HOME"
PCLI=( "$RUNTIME/node/bin/node" "$RUNTIME/paseo/node_modules/@getpaseo/cli/dist/index.js" )

"${PCLI[@]}" daemon start >"$TEST_LOG" 2>&1 || { cat "$TEST_LOG"; die "自测：daemon start 失败"; }
WEB_OK=""
for _ in $(seq 1 60); do
  curl -sf "http://127.0.0.1:$SMOKE_PORT/" -o /dev/null 2>/dev/null && { WEB_OK=1; break; }
  sleep 1
done
[ -n "$WEB_OK" ] || { "${PCLI[@]}" daemon stop >/dev/null 2>&1; die "自测：Paseo Web UI 未就绪"; }
echo "    ✔ Paseo Web UI 就绪（127.0.0.1:${SMOKE_PORT}）"

node "$RES/installer/scripts/setup-provider.mjs" --provider deepseek --skip-auth --yes \
  --bridge-command "$SMOKE_D_HOME/paseo-bridge/bridge-wrapper.sh" >"$TEST_LOG" 2>&1 \
  || { cat "$TEST_LOG"; "${PCLI[@]}" daemon stop >/dev/null 2>&1; die "自测：provider 注册失败"; }
"${PCLI[@]}" daemon restart >"$TEST_LOG" 2>&1 || { cat "$TEST_LOG"; die "自测：daemon restart 失败"; }
sleep 6
"${PCLI[@]}" provider ls 2>/dev/null | grep -qi "DeepSeek Harness" \
  || { "${PCLI[@]}" provider ls; "${PCLI[@]}" daemon stop >/dev/null 2>&1; die "自测：provider ls 未见 DeepSeek Harness"; }
echo "    ✔ provider「DeepSeek Harness」已注册并识别"

log "自测：dsh 会话镜像（session/list → 自动导入 → 回放）"
# 造一个合成 dsh 会话（每行一个独立 zstd 帧，与 dsh 实际格式一致）
SMOKE_SESS_DIR="$SMOKE_D_HOME/sessions/--tmp--/session-smoketest01"
mkdir -p "$SMOKE_SESS_DIR"
DSH_HOME="$SMOKE_D_HOME" "$RUNTIME/node/bin/node" -e '
  const { zstdCompressSync } = require("node:zlib");
  const { writeFileSync } = require("node:fs");
  const lines = [
    JSON.stringify({type:"session",version:0,id:"session-smoketest01",createdAt:Date.now(),cwd:"/tmp",delegationDepth:0}),
    JSON.stringify({type:"user/message",seq:1,time:Date.now(),data:{content:[{type:"text",text:"镜像自测问题"}],role:"user",id:"m1"}}),
    JSON.stringify({type:"session/title",seq:2,time:Date.now(),data:{title:"镜像自测",messageSeqs:[1]}}),
    JSON.stringify({type:"assistant/message",seq:3,time:Date.now(),data:{turn:1,step:1,message:{role:"assistant",content:[{type:"text",text:"镜像自测回答"}]}}}),
  ];
  writeFileSync(process.argv[1], Buffer.concat(lines.map((l) => zstdCompressSync(Buffer.from(l + "\n")))));
' "$SMOKE_SESS_DIR/session.jsonl.zstd"
"$RUNTIME/node/bin/node" "$ROOT/scripts/sync-dsh-sessions.mjs" --paseo-cli "${PCLI[1]}" --min-age-ms 0 >"$TEST_LOG" 2>&1 \
  || { cat "$TEST_LOG"; "${PCLI[@]}" daemon stop >/dev/null 2>&1; die "自测：会话同步脚本失败"; }
sleep 3
# 标题由 daemon 元数据生成（无凭据时可能滞后），按 provider+cwd 定位，用 logs 断言内容
aid=$("${PCLI[@]}" agent ls 2>/dev/null | grep "deepseek/" | grep "/tmp" | awk '{print $1}' | head -1)
[ -n "$aid" ] || { cat "$TEST_LOG"; "${PCLI[@]}" agent ls; "${PCLI[@]}" daemon stop >/dev/null 2>&1; die "自测：镜像 agent 未出现"; }
if "${PCLI[@]}" agent logs "$aid" 2>/dev/null | grep -q "镜像自测回答"; then
  echo "    ✔ 镜像 agent 时间线回放正确（${aid}）"
else
  "${PCLI[@]}" agent logs "$aid"
  "${PCLI[@]}" daemon stop >/dev/null 2>&1
  die "自测：镜像回放内容缺失"
fi
"${PCLI[@]}" daemon stop >"$TEST_LOG" 2>&1 || die "自测：daemon stop 失败"
unset PASEO_HOME PASEO_LISTEN PASEO_WEB_UI_ENABLED PASEO_WEB_UI_DIST_DIR DSH_HOME
rm -rf "$TEST_HOME"
echo "    ✔ 全链路自测通过"

# ---------------------------------------------------------------------------
# 7. 打 DMG（APP + /Applications 符号链接，拖拽安装布局）
# ---------------------------------------------------------------------------
log "打 DMG"
DMG_ROOT="$BUILD/dmg-root"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "DeepSeek Harness Desktop" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

echo "✔ 产出：$DMG"
lipo -info "$APP/Contents/MacOS/$BIN"
lipo -info "$RUNTIME/node/bin/node"
du -sh "$APP" | cut -f1 | xargs printf 'APP 体积：%s\n'
du -h "$DMG" | cut -f1 | xargs printf 'DMG 体积：%s\n'
