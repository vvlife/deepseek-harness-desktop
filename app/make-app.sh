#!/usr/bin/env bash
# 构建 DeepSeek Harness Desktop Installer.app（universal）并打成 DMG。
#
#   app/make-app.sh [版本号]      # 默认取 git describe 或 0.2.0
#
# 产出：app/build/DeepSeek-Harness-Desktop-<version>.dmg
# 无付费开发者账号：ad-hoc 签名（--sign -）。用户在 macOS 15 首次打开需
# 「系统设置 → 隐私与安全性 → 仍要打开」，或 xattr -d com.apple.quarantine。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/app"
BUILD="$APP_SRC/build"
APP="$BUILD/DeepSeek Harness Desktop Installer.app"
BIN="DSHDesktopInstaller"
VERSION="${1:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.2.0)}"
DMG="$BUILD/DeepSeek-Harness-Desktop-${VERSION}.dmg"

command -v swiftc >/dev/null 2>&1 || { echo "需要 swiftc（xcode-select --install）" >&2; exit 1; }

echo "==> 清理并创建 bundle（v${VERSION}）"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/installer"

echo "==> 编译 universal 二进制（arm64 + x86_64, macOS 12+）"
for arch in arm64 x86_64; do
  swiftc -O -whole-module-optimization -parse-as-library \
    -target "${arch}-apple-macosx12.0" \
    -o "$BUILD/${BIN}-${arch}" "$APP_SRC/InstallerApp.swift"
done
lipo -create -output "$APP/Contents/MacOS/$BIN" "$BUILD/${BIN}-arm64" "$BUILD/${BIN}-x86_64"
rm "$BUILD/${BIN}-arm64" "$BUILD/${BIN}-x86_64"

echo "==> 写入 Info.plist 与内置安装器资源"
sed "s/@VERSION@/${VERSION}/g" "$APP_SRC/Info.plist" > "$APP/Contents/Info.plist"
cp "$ROOT/install.sh" "$APP/Contents/Resources/installer/"
cp -R "$ROOT/scripts" "$ROOT/bridge" "$APP/Contents/Resources/installer/"
chmod 755 "$APP/Contents/Resources/installer/install.sh" \
  "$APP/Contents/Resources/installer/scripts/"*.mjs \
  "$APP/Contents/Resources/installer/bridge/"*.mjs

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

echo "==> 打 DMG"
hdiutil create -volname "DeepSeek Harness Desktop" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

echo "✔ 产出：$DMG"
lipo -info "$APP/Contents/MacOS/$BIN"
du -h "$DMG" | cut -f1
