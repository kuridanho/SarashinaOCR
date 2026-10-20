#!/bin/bash
# Create the development venv and install pinned engine dependencies.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-python3.12}"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "error: $PYTHON not found. Install it with: brew install python@3.12" >&2
  exit 1
fi

cd "$ROOT"
"$PYTHON" -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/pip install -e "engine[dev]"
echo "engine environment ready: $ROOT/.venv"
