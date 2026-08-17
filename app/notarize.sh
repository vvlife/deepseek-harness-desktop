#!/usr/bin/env bash
# 提交已用「Developer ID Application」签名的产物到 Apple 公证（notarize），并把票据 stapler 装订。
#
#   app/notarize.sh <path-to-dmg-or-app> [bundle-id]
#
# 凭证（二选一，推荐方式 1 的 API Key，无需开启 2FA 也能 CI 跑）：
#
#   方式 1 · App Store Connect API Key（推荐，CI 友好、可长期有效）
#     APPLE_API_KEY          API Key ID（如 XYZ1234567）
#     APPLE_API_ISSUER       Issuer ID（UUID，在 App Store Connect → 用户和访问 → 密钥 页面）
#     APPLE_API_KEY_PEM      *.p8 私钥全文（含 -----BEGIN PRIVATE KEY----- 头尾）
#
#   方式 2 · Apple ID + 专用密码（App Store Connect 里生成，非登录密码）
#     APPLE_ID               Apple 账号邮箱
#     APPLE_APP_SPECIFIC_PASSWORD  专用密码（如 abcd-efgh-ijkl-mnop）
#     APPLE_TEAM_ID          开发者团队 ID（10 位大写，可不加，但建议加上避免多团队歧义）
#
# 退出码非 0 表示公证失败（CI 应据此阻断发布）。
set -euo pipefail

TARGET="${1:-}"
BUNDLE_ID="${2:-com.vvlife.dsh-desktop}"
[ -n "$TARGET" ] || { echo "用法：notarize.sh <dmg|app> [bundle-id]" >&2; exit 2; }
[ -e "$TARGET" ] || { echo "✘ 找不到待公证文件：$TARGET" >&2; exit 2; }

log() { printf '\033[1;34m==> notarize:\033[0m %s\n' "$*"; }
die() { printf '✘ notarize: %s\n' "$*" >&2; exit 1; }

# 准备 API Key 私钥文件（若为方式 1）
API_KEY_FILE=""
cleanup() { [ -n "$API_KEY_FILE" ] && [ -f "$API_KEY_FILE" ] && rm -f "$API_KEY_FILE"; }
trap cleanup EXIT

NOTARY_ARGS=()
if [ -n "${APPLE_API_KEY:-}" ] && [ -n "${APPLE_API_ISSUER:-}" ]; then
  log "使用 App Store Connect API Key 方式公证"
  [ -n "${APPLE_API_KEY_PEM:-}" ] || die "缺少 APPLE_API_KEY_PEM（.p8 私钥内容）"
  API_KEY_FILE="$(mktemp -d)/AuthKey_${APPLE_API_KEY}.p8"
  printf '%s\n' "$APPLE_API_KEY_PEM" > "$API_KEY_FILE"
  chmod 600 "$API_KEY_FILE"
  NOTARY_ARGS=( --key "$API_KEY_FILE" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER" )
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
  log "使用 Apple ID + 专用密码方式公证"
  NOTARY_ARGS=( --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" )
  [ -n "${APPLE_TEAM_ID:-}" ] && NOTARY_ARGS+=( --team-id "$APPLE_TEAM_ID" )
else
  die "未提供任何公证凭证：请设置 App Store Connect API Key（APPLE_API_KEY/ISSUER/PEM）或 Apple ID+专用密码（APPLE_ID/APPLE_APP_SPECIFIC_PASSWORD）"
fi

# 0) 预校验：必须先有 Developer ID 签名与 hardened runtime
if ! codesign -dv --verbose=2 "$TARGET" 2>&1 | grep -q "Authority=Developer ID Application"; then
  die "目标未用「Developer ID Application」签名，无法公证（请先用 Developer ID 证书签名）"
fi
if ! codesign -dv --verbose=2 "$TARGET" 2>&1 | grep -q "Runtime Version"; then
  die "目标未开启 hardened runtime（--options runtime），无法公证"
fi

# 1) 提交公证
log "提交公证：$TARGET"
for attempt in 1 2 3; do
  SUBMIT_LOG="$(mktemp)"
  if xcrun notarytool submit "$TARGET" --wait \
        --output-format json "${NOTARY_ARGS[@]}" > "$SUBMIT_LOG" 2>&1; then
    echo "    公证提交成功（第 ${attempt} 次）"
    break
  fi
  echo "    第 ${attempt} 次提交失败：$("cat" "$SUBMIT_LOG" | tail -3)" >&2
  if [ "$attempt" -eq 3 ]; then
    cat "$SUBMIT_LOG" >&2
    die "公证提交 3 次均失败"
  fi
  sleep 5
done

# 2) 取 request UUID（失败时打印详细日志便于排错）
UUID="$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[a-f0-9-]+"' "$SUBMIT_LOG" | head -1 | awk -F'"' '{print $4}')"
if [ -z "$UUID" ]; then
  # 兜底：从 --wait 文本输出里抓
  UUID="$(grep -oE '[a-f0-9]{8}-[a-f0-9-]+' "$SUBMIT_LOG" | head -1 || true)"
fi

# 3) 装订票据（stapler）
log "装订公证票据（stapler）"
for attempt in 1 2 3; do
  if xcrun stapler staple "$TARGET" 2>&1 | grep -q "The staple and validate action"; then
    echo "    票据装订成功"
    break
  fi
  echo "    第 ${attempt} 次 staple 失败，重试…" >&2
  [ "$attempt" -eq 3 ] && die "stapler 装订失败"
  sleep 3
done

# 4) 验证
log "校验票据（stapler validate）"
xcrun stapler validate "$TARGET" 2>&1 | tail -3 | sed 's/^/    /'
echo "✔ 公证完成：$TARGET"
