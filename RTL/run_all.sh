#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

check_same() {
    local canonical="$1"
    local copy="$2"
    if ! cmp -s "$canonical" "$copy"; then
        echo "ERROR: ${copy#"$SCRIPT_DIR/"} has drifted from ${canonical#"$SCRIPT_DIR/"}" >&2
        return 1
    fi
}

check_same "$SCRIPT_DIR/Fastpath/fastpath.sv" "$SCRIPT_DIR/Cache/fastpath.sv"
check_same "$SCRIPT_DIR/Slowpath/slowpath.sv" "$SCRIPT_DIR/Cache/slowpath.sv"
check_same "$SCRIPT_DIR/Fastpath/fakeram7_256x8.v" "$SCRIPT_DIR/Slowpath/fakeram7_256x8.v"
check_same "$SCRIPT_DIR/Fastpath/fakeram7_256x8.v" "$SCRIPT_DIR/Cache/fakeram7_256x8.v"

for suite in Fastpath Slowpath Cache; do
    echo "==> Running ${suite} verification"
    "$SCRIPT_DIR/$suite/run.sh"
done
