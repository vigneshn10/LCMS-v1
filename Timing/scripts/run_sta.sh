#!/bin/bash
# Pure STA on the synthesized netlist (no APR). Violation-free publishable report.
#   ./run_sta.sh                # 5500 ps (181.8 MHz)
#   CLK_PS=6000 ./run_sta.sh    # different period
set -e
export KIT="$(cd "$(dirname "$0")" && pwd)"
export CLK_PS="${CLK_PS:-5500}"
export DYLD_LIBRARY_PATH="$KIT/lib:/opt/homebrew/lib"
"$KIT/bin/openroad" -no_init -exit "$KIT/run_sta.tcl" 2>&1 | tee "$KIT/results/orchestrator_top.sta.log"
R="$KIT/results/orchestrator_top_sta"
echo; echo "================= RESULT ================="
cat "$R/orchestrator_top.summary.rpt"
echo "=========================================="
echo "violations in setup report: $(grep -c VIOLATED "$R/orchestrator_top.setup_endpoints.rpt" || true)"
echo "violations in hold report : $(grep -c VIOLATED "$R/orchestrator_top.hold_endpoints.rpt" || true)"
