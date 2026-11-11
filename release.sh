#!/usr/bin/env bash
# 原子发布：核对包内版本 → 算 sha256 → 落仓 → 写清单 → 提交 → 推送（SSH）
set -euo pipefail
VER=${1:?usage: ./release.sh <version> <apk> [note]}
APK=${2:?apk path}
NOTE=${3:-release $VER}
cd "$(dirname "$0")"

AAPT2=""
for c in /home/pro/Android/Sdk/build-tools/34.0.0/aapt2 /home/pro/android-sdk/build-tools/34.0.0/aapt2; do
  [ -x "$c" ] && AAPT2="$c" && break
done
[ -n "$AAPT2" ] || { echo "✗ 找不到 aapt2"; exit 1; }

BADGING=$("$AAPT2" dump badging "$APK" 2>/dev/null | sed -n 1p)
APK_NAME=$(echo "$BADGING" | sed -E "s/.*versionName='([^']+)'.*/\1/")
APK_CODE=$(echo "$BADGING" | sed -E "s/.*versionCode='([0-9]+)'.*/\1/")
WANT_CODE=$(( $(echo "$VER" | cut -d. -f1) * 10000 + $(echo "$VER" | cut -d. -f2) * 100 + $(echo "$VER" | cut -d. -f3) ))
[ "$APK_NAME" = "$VER" ] && [ "$APK_CODE" = "$WANT_CODE" ] || { echo "✗ 包内版本 $APK_NAME($APK_CODE) ≠ 目标 $VER($WANT_CODE)"; exit 1; }

BASE="cube-chat-$VER.apk"
cp "$APK" "$BASE"
SHA=$(sha256sum "$BASE" | cut -d' ' -f1)
SIZE=$(stat -c%s "$BASE")
cat > android.json <<JSON
{
  "version": "$VER",
  "versionCode": $WANT_CODE,
  "size": $SIZE,
  "url": "https://github.com/ctomall/cube-chat-updates/releases/download/v$VER/$BASE",
  "fallback": "https://dsh.ila3.top/demo/cube-chat/$BASE",
  "sha256": "$SHA",
  "notes": ["$NOTE"]
}
JSON
git add -A
git commit -q -m "release $VER: $NOTE"
git push origin main
echo "✓ 发布 $VER ($WANT_CODE) sha256=$SHA size=$SIZE"
