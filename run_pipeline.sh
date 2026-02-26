#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
if [[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="."
fi
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v Rscript >/dev/null 2>&1; then
  echo "Error: Rscript not found in PATH." >&2
  exit 1
fi

echo "[1/3] Running step1_get_data.R"
Rscript step1_get_data.R

echo "[2/3] Running step2_sweep_grid_windows.R"
Rscript step2_sweep_grid_windows.R

echo "[3/3] Running step3_build_3xportfolios_oos.R"
Rscript step3_build_3xportfolios_oos.R

echo "Pipeline complete."
