#!/bin/zsh
# 构建 Quire.app：swift build -c release → 组装 bundle → ad-hoc 签名
# 用法：scripts/build_app.sh [--debug] [--no-mermaid]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
FETCH_MERMAID=1
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --no-mermaid) FETCH_MERMAID=0 ;;
  esac
done

if [ "$FETCH_MERMAID" = 1 ] && [ ! -f Sources/QuireRender/Resources/Mermaid/mermaid.min.js ]; then
  echo "▸ 拉取 mermaid.min.js（首次）"
  scripts/fetch_mermaid.sh
fi

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG" --product Quire

BUILD_DIR=".build/$CONFIG"
APP="dist/Quire.app"
BIN="$BUILD_DIR/Quire"

echo "▸ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Quire"
# SwiftPM 资源 bundle（主题、Mermaid 壳）
for b in "$BUILD_DIR"/Quire_*.bundle; do
  [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done
cp assets/Info.plist "$APP/Contents/Info.plist"
# 主 bundle 的语言目录：AppKit 按这里决定系统面板 / 标准菜单项的语言（字符串本身在 Quire_*.bundle 里）
for loc in zh-Hans en; do
  mkdir -p "$APP/Contents/Resources/$loc.lproj"
  printf 'CFBundleDisplayName = "Quire";\nCFBundleName = "Quire";\n' > "$APP/Contents/Resources/$loc.lproj/InfoPlist.strings"
done

# 图标（缺失时现场生成）
if [ ! -f assets/AppIcon.icns ]; then
  echo "▸ 生成图标"
  swift scripts/make_icon.swift assets/AppIcon.iconset
  iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
fi
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▸ ad-hoc 签名"
codesign --force --deep --sign - "$APP"

echo "✓ 完成: $APP ($(du -sh "$APP" | cut -f1))"
