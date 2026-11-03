#!/bin/zsh
# 冒烟：模拟"别人的机器"——App 拷到临时目录、换成独立的 bundle id（偏好从空白开始，也不写本机真实的偏好）、沙盒禁止读本仓库的 .build，然后打开一个带公式 / 表格 / 中文的文档并导出 PDF。
# 任何一步失败（fatalError、导出失败、PDF 太小）都以非零退出，让 build_app.sh / release.sh 停下来。
# 用法：scripts/smoke_app.sh dist/Quire.app
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-dist/Quire.app}
SMOKE_ID=com.korako.quire.smoke
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
WORK=$(mktemp -d -t quire-smoke)
forget_prefs() {
  defaults delete "$SMOKE_ID" 2>/dev/null || true   # 域不存在时会报错，那正好
  rm -f "$HOME/Library/Preferences/$SMOKE_ID.plist"   # delete 只清内容，还留个空文件
}
cleanup() {
  # App 一启动就被 LaunchServices 记下。必须在删目录之前注销：路径没了，lsregister -u 就摘不掉这条记录了
  [ -z "${PID:-}" ] || "$LSREGISTER" -u "$WORK/Quire.app" || echo "⚠️ 没能从 LaunchServices 注销冒烟副本：$WORK/Quire.app"
  forget_prefs
  rm -rf "$WORK"
}
trap cleanup EXIT
forget_prefs   # 上次被中断可能留下旧偏好（zsh 被 Ctrl-C / kill 杀掉时不跑 EXIT trap）
cp -R "$APP" "$WORK/Quire.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SMOKE_ID" "$WORK/Quire.app/Contents/Info.plist"
codesign --force --deep --sign - "$WORK/Quire.app"   # 改了 Info.plist，签名要跟着重做
cat > "$WORK/doc.md" <<'MD'
# 冒烟测试

中文、**粗体**、`代码`、一个公式 $E = mc^2$ 和一个独立公式：

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

| 列 | 值 |
| --- | ---: |
| a | 1 |

```swift
let x = 1
```
MD
cat > "$WORK/deny.sb" <<SB
(version 1)
(allow default)
(deny file-read* (subpath "$(pwd)/.build"))
SB
OUT="$WORK/out.pdf"
set +e
# 不依赖 coreutils 的 timeout（CI 的 runner 没有）：后台跑 + 看门狗
QUIRE_EXPORT_PDF="$OUT" sandbox-exec -f "$WORK/deny.sb" "$WORK/Quire.app/Contents/MacOS/Quire" "$WORK/doc.md" -ApplePersistenceIgnoreState YES > "$WORK/log.txt" 2>&1 &
PID=$!
( sleep 60; kill "$PID" 2>/dev/null ) &
WATCHDOG=$!
wait "$PID"
STATUS=$?
kill "$WATCHDOG" 2>/dev/null
set -e
if ! grep -q "QUIRE_EXPORT_PDF=ok" "$WORK/log.txt"; then
  echo "✗ 冒烟失败（exit $STATUS）："; tail -20 "$WORK/log.txt"; exit 1
fi
SIZE=$(stat -f %z "$OUT" 2>/dev/null || echo 0)
[ "$SIZE" -gt 8000 ] || { echo "✗ 冒烟失败：PDF 只有 $SIZE 字节"; exit 1 }
echo "✓ 冒烟通过（PDF $SIZE 字节）"
