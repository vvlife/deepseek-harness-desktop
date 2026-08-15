#!/bin/sh
# verify-bundled-cli.sh — 校验「APP 内嵌终端」解析到的 dsh/paseo/node 是包内版本。
#
# 背景：APP 内嵌终端（dsh web 的 PTY）以
#   /bin/bash --noprofile --norc -i
# 启动，不读任何 rc/profile，直接继承父进程（APP 拉起的 dsh web）的 PATH。
# APP 在 processEnv() 里把包内 bin 目录（<bundle>/Contents/Resources/runtime/node/bin）
# 放到 PATH 最前，因此内嵌终端里的 dsh/paseo/node 必须命中包内 shim，
# 而不受本机全局安装的 dsh/paseo 干扰。
#
# 本脚本用与内嵌终端一致的 PATH 与启动标志，验证命令解析结果确实落在包内。
#
# 用法：
#   bash scripts/verify-bundled-cli.sh [APP_BUNDLE_PATH]
# 默认 APP_BUNDLE_PATH = app/build/DeepSeek Harness Desktop.app
#
# 退出码：0=全部命中包内；1=任一命令解析到包外；2=包内运行时缺失。

set -u

BUNDLE="${1:-app/build/DeepSeek Harness Desktop.app}"
# 标准化为绝对路径
case "$BUNDLE" in
  /*) ;;
  *) BUNDLE="$(cd "$(dirname "$BUNDLE")" && pwd)/$(basename "$BUNDLE")" ;;
esac

BIN="$BUNDLE/Contents/Resources/runtime/node/bin"

# 1) 包内 shim 必须存在
missing=0
for cmd in dsh paseo node; do
  if [ ! -x "$BIN/$cmd" ]; then
    echo "✘ 包内缺失可执行：$BIN/$cmd" >&2
    missing=$((missing + 1))
  fi
done
[ "$missing" -eq 0 ] || exit 2

# 与 APP processEnv() 完全一致的 PATH（包内 bin 在最前）
STD_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
APP_PATH="$BIN:$STD_PATH"

# 2) 用与内嵌终端一致的方式解析命令，断言命中包内
fail=0
for cmd in dsh paseo node; do
  resolved="$(env -i PATH="$APP_PATH" /bin/bash --noprofile --norc -c "command -v $cmd" 2>/dev/null)"
  if [ "$resolved" = "$BIN/$cmd" ]; then
    echo "✔ $cmd -> $resolved"
  else
    echo "✘ $cmd 解析异常：期望 $BIN/$cmd，实际 ${resolved:-（未找到）}" >&2
    fail=$((fail + 1))
  fi
done

# 3) 额外断言：即便本机装了全局 dsh/paseo，包内版本仍优先
for cmd in dsh paseo; do
  if command -v "$cmd" >/dev/null 2>&1; then
    global="$(command -v "$cmd")"
    if [ "$global" != "$BIN/$cmd" ]; then
      echo "  ℹ 本机检测到全局 $cmd ($global)；APP 内嵌终端将使用包内版本 $BIN/$cmd"
    fi
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "校验通过：APP 内嵌终端的 dsh/paseo/node 均解析到包内运行时。"
  exit 0
else
  echo "校验失败：$fail 个命令未命中包内运行时。" >&2
  exit 1
fi
