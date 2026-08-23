#!/bin/zsh
# 冒烟：模拟"别人的机器"——App 拷到临时目录、沙盒禁止读本仓库的 .build，然后打开一个带公式 / 表格 / 中文的文档并导出 PDF。
# 任何一步失败（fatalError、导出失败、PDF 太小）都以非零退出，让 build_app.sh / release.sh 停下来。
# 用法：scripts/smoke_app.sh dist/Quire.app
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-dist/Quire.app}
WORK=$(mktemp -d -t quire-smoke)
trap 'rm -rf "$WORK"' EXIT
cp -R "$APP" "$WORK/Quire.app"
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
QUIRE_EXPORT_PDF="$OUT" timeout 40 sandbox-exec -f "$WORK/deny.sb" "$WORK/Quire.app/Contents/MacOS/Quire" "$WORK/doc.md" -ApplePersistenceIgnoreState YES > "$WORK/log.txt" 2>&1
STATUS=$?
set -e
if ! grep -q "QUIRE_EXPORT_PDF=ok" "$WORK/log.txt"; then
  echo "✗ 冒烟失败（exit $STATUS）："; tail -20 "$WORK/log.txt"; exit 1
fi
SIZE=$(stat -f %z "$OUT" 2>/dev/null || echo 0)
[ "$SIZE" -gt 8000 ] || { echo "✗ 冒烟失败：PDF 只有 $SIZE 字节"; exit 1 }
echo "✓ 冒烟通过（PDF $SIZE 字节）"
