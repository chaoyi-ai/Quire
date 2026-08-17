#!/bin/zsh
# 拉取固定版本的 mermaid.min.js 到 Sources/QuireRender/Resources/Mermaid/（不入库）
# 校验 SHA256；版本升级时同时更新 VERSION 与 SHA256。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="11.16.1"
URL="https://cdn.jsdelivr.net/npm/mermaid@${VERSION}/dist/mermaid.min.js"
DEST="Sources/QuireRender/Resources/Mermaid/mermaid.min.js"
SHA256_FILE="Sources/QuireRender/Resources/Mermaid/mermaid.sha256"

mkdir -p "$(dirname "$DEST")"
echo "▸ 下载 mermaid@${VERSION}"
curl -fsSL "$URL" -o "$DEST.tmp"

ACTUAL=$(shasum -a 256 "$DEST.tmp" | cut -d' ' -f1)
if [ -f "$SHA256_FILE" ]; then
  EXPECTED=$(cut -d' ' -f1 < "$SHA256_FILE")
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "✗ SHA256 不匹配：期望 $EXPECTED，实际 $ACTUAL" >&2
    rm -f "$DEST.tmp"; exit 1
  fi
else
  echo "$ACTUAL  mermaid@${VERSION}/dist/mermaid.min.js" > "$SHA256_FILE"
  echo "▸ 首次记录 SHA256 → $SHA256_FILE"
fi
mv "$DEST.tmp" "$DEST"
echo "✓ $DEST ($(du -h "$DEST" | cut -f1)) sha256=$ACTUAL"
