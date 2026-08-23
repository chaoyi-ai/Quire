#!/bin/sh
# quire — 从命令行打开 Markdown 文件 / 文件夹到 Quire。随 Quire.app 附带，可由 设置 → 安装命令行工具 复制到 /usr/local/bin。
#   quire README.md        打开文件
#   quire .                在侧栏打开当前目录（会打开里面的第一个 .md；没有则新建）
#   quire                  启动 Quire
APP="$(dirname "$(dirname "$(readlink "$0" || echo "$0")")")"
if [ ! -d "$APP/Contents" ]; then APP="/Applications/Quire.app"; fi
if [ ! -d "$APP/Contents" ]; then APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.korako.quire'" | head -1)"; fi
[ -d "$APP/Contents" ] || { echo "quire: 找不到 Quire.app" >&2; exit 1; }
if [ $# -eq 0 ]; then exec open -a "$APP"; fi
ARGS=""
for f in "$@"; do
  if [ -d "$f" ]; then
    first="$(ls "$f"/*.md "$f"/*.markdown 2>/dev/null | head -1)"
    if [ -n "$first" ]; then ARGS="$ARGS \"$first\""; else open -a "$APP" --args -QuireOpenFolder "$(cd "$f" && pwd)"; exit 0; fi
  else ARGS="$ARGS \"$f\""; fi
done
eval exec open -a \"\$APP\" $ARGS
