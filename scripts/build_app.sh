#!/bin/zsh
# 构建 Quire.app：swift build -c release → 组装 bundle → ad-hoc 签名
# 用法：scripts/build_app.sh [--debug] [--no-mermaid]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
FETCH_MERMAID=1
SMOKE=1
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --no-mermaid) FETCH_MERMAID=0 ;;
    --no-smoke) SMOKE=0 ;;
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
for b in "$BUILD_DIR"/Quire_*.bundle "$BUILD_DIR"/SwiftMath_SwiftMath.bundle; do
  [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done
# 数学字体：Vendor/SwiftMath 的 bundle 本身已只留 Latin Modern（0.7 MB），这里再保险一次
MATHFONTS="$APP/Contents/Resources/SwiftMath_SwiftMath.bundle/mathFonts.bundle"
if [ -d "$MATHFONTS" ]; then
  find "$MATHFONTS" -type f ! -name 'latinmodern-math.*' ! -name 'Info.plist' ! -name '*LICENSE*' -delete
fi
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
cp assets/quire-cli.sh "$APP/Contents/Resources/quire"   # 命令行工具（设置里一键装到 /usr/local/bin）
chmod +x "$APP/Contents/Resources/quire"

echo "▸ App Intents 元数据（Shortcuts 动作）"
scripts/appintents_metadata.sh "$CONFIG" "$APP"   # 失败就让构建失败：否则包里悄悄少了 Shortcuts 动作没人知道

echo "▸ ad-hoc 签名"
codesign --force --deep --sign - "$APP"

echo "✓ 完成: $APP ($(du -sh "$APP" | cut -f1))"

# 冒烟：把 App 拷到别处、禁止读 .build，再跑一次"打开 → 渲染（含公式）→ 导出 PDF"。
# 0.3.0–0.5.8 的发布包在别的机器上一启动就 fatalError（SwiftPM 的 Bundle.module 找不到装进 Contents/Resources 的资源），本机从没发现。
if [ "$SMOKE" = 1 ]; then
  echo "▸ 冒烟测试（隔离 .build）"
  scripts/smoke_app.sh "$APP"
fi
