#!/bin/zsh
# 跑全部基准并与预算比对（本机：factor 1）
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product quire-bench >/dev/null
# stderr 留着：基准崩了要能看到原因，不能只剩一个非零退出码
.build/release/quire-bench all 2> /tmp/quire-bench.err > /tmp/quire-bench.json || { echo "✗ quire-bench 退出失败："; tail -20 /tmp/quire-bench.err; exit 1 }
scripts/bench_gate.sh /tmp/quire-bench.json "${1:-1}"
