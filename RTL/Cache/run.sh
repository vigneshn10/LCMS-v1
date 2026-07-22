#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON:-python3}"
if [[ "$PYTHON_BIN" == */* ]]; then
    PYTHON_BIN="$(cd -- "$(dirname -- "$PYTHON_BIN")" && pwd)/$(basename -- "$PYTHON_BIN")"
fi

export SIM="${SIM:-icarus}"
cd "$SCRIPT_DIR"
exec "$PYTHON_BIN" testbench.py
