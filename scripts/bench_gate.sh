#!/bin/zsh
# 基准门禁：把 quire-bench 的 JSON 与 docs/PERFORMANCE.md 的预算比对，超预算即失败。
# 用法：scripts/bench_gate.sh bench.json [factor]
#   factor：预算放宽倍数（CI 共享 runner 慢，默认 3；本机用 1）
set -euo pipefail
JSON="${1:-bench.json}"
FACTOR="${2:-${BENCH_FACTOR:-1}}"

python3 - "$JSON" "$FACTOR" <<'PY'
import json, sys
path, factor = sys.argv[1], float(sys.argv[2])
budgets_ms = {  # 与 docs/PERFORMANCE.md §1 保持一致
    "parse/large-1mb": 60,
    "render/large-1mb": 140,
    "full/large-1mb (parse+render)": 200,
    "theme/switch-large-1mb": 150,
    "incremental/edit-middle-1mb": 16,
    "view/reader-setRendered-1mb": 60,
    "view/editor-keystroke-1mb": 8,
    "stats/large-1mb": 5,
}
budgets_mbps = {"highlight/swift": 20, "highlight/javascript": 20, "highlight/python": 20}
data = json.load(open(path))
results = {r["name"]: r for r in data["results"]}
fail = False
for name, budget in budgets_ms.items():
    r = results.get(name)
    if not r: print(f"?  {name}: 缺失"); fail = True; continue
    ok = r["medianMs"] <= budget * factor
    print(f"{'✓' if ok else '✗'}  {name:34s} {r['medianMs']:8.1f} ms  (预算 {budget} × {factor:g})")
    fail |= not ok
for name, budget in budgets_mbps.items():
    r = results.get(name)
    if not r: continue
    ok = r["throughputMBps"] >= budget / factor
    print(f"{'✓' if ok else '✗'}  {name:34s} {r['throughputMBps']:8.1f} MB/s (预算 ≥ {budget} / {factor:g})")
    fail |= not ok
sys.exit(1 if fail else 0)
PY
