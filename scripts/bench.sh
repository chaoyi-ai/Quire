#!/bin/zsh
# 跑全部基准并与预算比对（本机：factor 1）
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product quire-bench >/dev/null
.build/release/quire-bench all 2>/dev/null > /tmp/quire-bench.json
scripts/bench_gate.sh /tmp/quire-bench.json "${1:-1}"
