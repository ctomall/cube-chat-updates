#!/usr/bin/env bash
# 原子发布（顺序修正版）：
#   0) 签名核对 → 1) 版本核对 → 2) 写清单并提交推送 → 3) 在该提交上打 tag 建 Release → 4) 上传资产 → 5) CDN 镜像 → 6) 校验
# 用法: ./release.sh <version> <apk> [note]      （SKIP_C_SHA=1 时用本机 CDN 文件核对 sha）
set -euo pipefail
VER=${1:?usage: ./release.sh <version> <apk> [note]}
APK=${2:?apk path}
NOTE=${3:-release $VER}
OWNER_REPO=ctomall/cube-chat-updates
CDN_DIR=/var/www/tongpin-demo/cube-chat
CDN_BASE=https://dsh.ila3.top/demo/cube-chat
cd "$(dirname "$0")"

AAPT2=/home/pro/Android/Sdk/build-tools/34.0.0/aapt2
[ -x "$AAPT2" ] || { echo "✗ 找不到 aapt2"; exit 1; }
BADGING=$("$AAPT2" dump badging "$APK" 2>/dev/null | sed -n 1p)
APK_NAME=$(echo "$BADGING" | sed -E "s/.*versionName='([^']+)'.*/\1/")
APK_CODE=$(echo "$BADGING" | sed -E "s/.*versionCode='([0-9]+)'.*/\1/")
WANT_CODE=$(( $(echo "$VER" | cut -d. -f1) * 10000 + $(echo "$VER" | cut -d. -f2) * 100 + $(echo "$VER" | cut -d. -f3) ))
[ "$APK_NAME" = "$VER" ] && [ "$APK_CODE" = "$WANT_CODE" ] || {
  echo "✗ 包内版本 $APK_NAME($APK_CODE) ≠ 目标 $VER($WANT_CODE)"; exit 1; }

# 签名闸门：必须是正式证书，且签名方案校验通过。
# 缺这道检查时，没拿到 keystore 的构建机会产出 debug 签名包，脚本照发，
# 已装用户的 OTA 链当场断掉（只能卸载重装）。
EXPECTED_CERT_SHA256=9c899e3973c7c63797bdcc510e8c07fcfc28204bad6d1c8c25615a60ce76521a
APKSIGNER=/home/pro/Android/Sdk/build-tools/34.0.0/apksigner
[ -x "$APKSIGNER" ] || { echo "✗ 找不到 apksigner"; exit 1; }
CERT_SHA=$("$APKSIGNER" verify --print-certs "$APK" 2>/dev/null | sed -n 's/.*certificate SHA-256 digest: //p' | head -1 | tr -d ' ')
if [ "$CERT_SHA" != "$EXPECTED_CERT_SHA256" ]; then
  echo "✗ 签名证书不符，拒绝发布"
  echo "  实际：${CERT_SHA:-<读不出>}"
  echo "  期望：$EXPECTED_CERT_SHA256（CN=CTO Agent, O=CTO）"
  echo "  常见原因：构建机没有 ~/.android/keys/cto-agent-release.jks，回落到 debug 签名。"
  exit 1
fi
"$APKSIGNER" verify "$APK" >/dev/null 2>&1 || { echo "✗ APK 签名校验不通过"; exit 1; }

BASE="cube-chat-$VER.apk"
cp "$APK" "$BASE"
SHA=$(sha256sum "$BASE" | cut -d' ' -f1)
SIZE=$(stat -c%s "$BASE")

TOKEN=${GH_TOKEN:-$(python3 - <<'PY'
import re,pathlib
p=pathlib.Path('/home/pro/.dsh/.credentials.yaml')
m=re.search(r'(gh[pousr]_[A-Za-z0-9_]{20,})', p.read_text())
print(m.group(1) if m else '')
PY
)}
[ -n "$TOKEN" ] || { echo "✗ 没有 GitHub token"; exit 1; }
api() { curl -sS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

# 1) 清单先落库并推送（tag 必须指向含新清单的提交）
cat > android.json <<JSON
{
  "version": "$VER",
  "versionCode": $WANT_CODE,
  "size": $SIZE,
  "url": "https://github.com/$OWNER_REPO/releases/download/v$VER/$BASE",
  "fallback": "$CDN_BASE/$BASE",
  "sha256": "$SHA",
  "notes": ["$NOTE"]
}
JSON
git add -A
git commit -q -m "release $VER: $NOTE"
git push -q origin main
COMMIT=$(git rev-parse HEAD)

# 2) 在该提交上建 Release（幂等）
REL_ID=$(api "https://api.github.com/repos/$OWNER_REPO/releases/tags/v$VER" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('id',''))" 2>/dev/null || true)
if [ -z "$REL_ID" ]; then
  REL_ID=$(api -X POST "https://api.github.com/repos/$OWNER_REPO/releases" \
    -d "{\"tag_name\":\"v$VER\",\"target_commitish\":\"$COMMIT\",\"name\":\"CTO Agent $VER\",\"body\":\"$NOTE\"}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
fi

# 3) 上传资产（同名先删）
api "https://api.github.com/repos/$OWNER_REPO/releases/$REL_ID/assets" \
  | python3 -c "import sys,json;[print(a['id']) for a in json.load(sys.stdin) if a['name']=='$BASE']" \
  | while read -r AID; do [ -n "$AID" ] && api -X DELETE "https://api.github.com/repos/$OWNER_REPO/releases/assets/$AID" >/dev/null; done
api -X POST -H "Content-Type: application/vnd.android.package-archive" \
  --data-binary @"$BASE" \
  "https://uploads.github.com/repos/$OWNER_REPO/releases/$REL_ID/assets?name=$BASE" >/dev/null

# 4) CDN 镜像
sudo mkdir -p "$CDN_DIR"
sudo cp "$BASE" "$CDN_DIR/$BASE"
sudo chmod 644 "$CDN_DIR/$BASE"
# 清单也必须镜像：否则 CDN 源永远返回旧版本（历史缺陷：0.1.0 之后一直没同步）
sudo cp android.json "$CDN_DIR/android.json"
sudo chmod 644 "$CDN_DIR/android.json"

# 5) 校验：API 资产尺寸 + CDN sha（可用 SKIP_C_SHA=1 走本机文件）
R_SIZE=$(api "https://api.github.com/repos/$OWNER_REPO/releases/$REL_ID/assets" | python3 -c "import sys,json;a=[x for x in json.load(sys.stdin) if x['name']=='$BASE'];print(a[0]['size'] if a else 0)")
[ "$R_SIZE" = "$SIZE" ] || { echo "✗ Release 资产大小不符（$R_SIZE != $SIZE）"; exit 1; }
if [ "${SKIP_C_SHA:-0}" = "1" ]; then
  C_SHA=$(sudo sha256sum "$CDN_DIR/$BASE" | cut -d' ' -f1)
else
  C_SHA=$(curl -sSL --max-time 120 "$CDN_BASE/$BASE" | sha256sum | cut -d' ' -f1)
fi
[ "$C_SHA" = "$SHA" ] || { echo "✗ CDN 镜像 sha 不一致"; exit 1; }
echo "✓ 发布 $VER ($WANT_CODE) size=$SIZE sha256=$SHA commit=$COMMIT"
echo "  release: https://github.com/$OWNER_REPO/releases/tag/v$VER"
