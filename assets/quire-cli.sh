#!/bin/sh
# quire — 从命令行驱动 Quire。随 Quire.app 附带，可由 设置 → 安装命令行工具 复制到 /usr/local/bin。
#   quire                              启动 Quire
#   quire README.md                    打开文件
#   quire .                            在侧栏打开当前目录（会打开里面的第一个 .md；没有则新建）
#   quire open <file> [--line N]       打开并跳到第 N 行
#   quire new [text] [--path <file>]   新建文档（可带初始文本；给 --path 则直接创建文件）
#   quire append <file> <text>         追加文本到文件末尾（text 为 - 时读 stdin）
#   quire export <file> <out.pdf|.html>  导出 PDF / HTML
# open / new / append / export 走 quire:// URL scheme，Shortcuts 的「打开 URL」动作也可以直接用同样的 URL。
# 自己在 Quire.app/Contents/Resources/quire（可能经 /usr/local/bin 的符号链接）→ 往上三层是 .app
SELF="$(readlink "$0" || echo "$0")"
case "$SELF" in /*) ;; *) SELF="$(dirname "$0")/$SELF" ;; esac
APP="$(cd "$(dirname "$SELF")/../.." 2>/dev/null && pwd)"
if [ ! -d "$APP/Contents" ]; then APP="/Applications/Quire.app"; fi
if [ ! -d "$APP/Contents" ]; then APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.korako.quire'" | head -1)"; fi
[ -d "$APP/Contents" ] || { echo "quire: 找不到 Quire.app" >&2; exit 1; }

abspath() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$(pwd)" "$1" ;; esac; }
urlenc() { printf '%s' "$1" | xxd -p | tr -d '\n' | sed 's/\(..\)/%\1/g'; }
launch_url() { exec open -a "$APP" "$1"; }

case "$1" in
  open)
    shift; f=""; line=""
    while [ $# -gt 0 ]; do case "$1" in --line) line="$2"; shift 2 ;; *) f="$1"; shift ;; esac; done
    [ -n "$f" ] || { echo "quire open <file> [--line N]" >&2; exit 2; }
    u="quire://open?path=$(urlenc "$(abspath "$f")")"; [ -n "$line" ] && u="$u&line=$line"
    launch_url "$u" ;;
  new)
    shift; text=""; path=""
    while [ $# -gt 0 ]; do case "$1" in --path) path="$2"; shift 2 ;; *) text="$1"; shift ;; esac; done
    u="quire://new?text=$(urlenc "$text")"; [ -n "$path" ] && u="$u&path=$(urlenc "$(abspath "$path")")"
    launch_url "$u" ;;
  append)
    [ $# -ge 3 ] || { echo "quire append <file> <text|->" >&2; exit 2; }
    text="$3"; [ "$text" = "-" ] && text="$(cat)"
    launch_url "quire://append?path=$(urlenc "$(abspath "$2")")&text=$(urlenc "$text")" ;;
  export)
    [ $# -ge 3 ] || { echo "quire export <file> <out.pdf|out.html>" >&2; exit 2; }
    launch_url "quire://export?path=$(urlenc "$(abspath "$2")")&to=$(urlenc "$(abspath "$3")")" ;;
  -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

if [ $# -eq 0 ]; then exec open -a "$APP"; fi
# 文件和文件夹都直接交给 App：文件夹由 App 自己按 README / 第一篇 Markdown 打开并设侧栏根目录
# （以前脚本自己挑第一个 .md、没有就走 --args，App 已在运行时 --args 根本到不了）
exec open -a "$APP" "$@"
