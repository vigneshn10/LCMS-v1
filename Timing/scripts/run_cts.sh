#!/bin/bash
# CTS-only characterization (no routing): timing + power + clock-tree estimates.
#   DESIGN=smoke_top ./run_cts.sh       # ~40 s self-test
#   ./run_cts.sh                        # orchestrator_top, ~10-20 min
#   CLK_PS=3000 ./run_cts.sh            # different target period
set -e
export KIT="$(cd "$(dirname "$0")" && pwd)"
export DESIGN="${DESIGN:-orchestrator_top}"
[ -f "$KIT/designs/$DESIGN.tcl" ] || { echo "no design '$DESIGN'"; ls "$KIT/designs/"; exit 1; }
export CLK_PS="${CLK_PS:-$(sed -n 's/^set DEF_PERIOD *\([0-9]*\).*/\1/p' "$KIT/designs/$DESIGN.tcl")}"
export DYLD_LIBRARY_PATH="$KIT/lib:/opt/homebrew/lib"

MHZ=$(awk "BEGIN{printf \"%.1f\", 1000000/$CLK_PS}")
echo "=== CTS-only: $DESIGN @ ${CLK_PS}ps (${MHZ} MHz) ==="
mkdir -p "$KIT/results"
"$KIT/bin/openroad" -no_init -exit "$KIT/run_cts.tcl" 2>&1 | tee "$KIT/results/$DESIGN.cts.log"

R="$KIT/results/${DESIGN}_cts"
echo; echo "================= RESULT ================="
[ -f "$R/$DESIGN.summary.rpt" ] && cat "$R/$DESIGN.summary.rpt"
echo "=========================================="
echo "reports in $R/:  setup.rpt hold.rpt skew.rpt cts_stats.rpt power.rpt drv.rpt summary.rpt"
