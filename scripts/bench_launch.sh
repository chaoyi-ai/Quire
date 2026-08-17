#!/bin/zsh
# 冷/热启动到首帧：需要先 scripts/build_app.sh。打印 N 次的毫秒数。
set -euo pipefail
cd "$(dirname "$0")/.."
APP=dist/Quire.app/Contents/MacOS/Quire
FILE="${1:-Tests/QuireCoreTests/Fixtures/small.md}"
N="${2:-5}"
for i in $(seq 1 $N); do
  QUIRE_MEASURE_LAUNCH=exit "$APP" "$FILE" 2>&1 | grep QUIRE_LAUNCH_MS || true
done
