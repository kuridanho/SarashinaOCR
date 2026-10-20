#!/bin/bash
# Download the pinned Sarashina2.2-OCR MLX 4bit model for development.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION="6585fb9ed1fbb263eb39c57a2b45c5c21a8aadff"
TARGET="${1:-$ROOT/models/sarashina2.2-ocr-mlx-4bit}"

if [ ! -x "$ROOT/.venv/bin/python" ]; then
  echo "error: $ROOT/.venv is missing; run scripts/setup-engine.sh first" >&2
  exit 1
fi

mkdir -p "$TARGET"
"$ROOT/.venv/bin/python" - "$TARGET" "$REVISION" <<'PY'
import sys
from huggingface_hub import snapshot_download

target, revision = sys.argv[1], sys.argv[2]
snapshot_download(
    "tokimoa/sarashina2.2-ocr-mlx-4bit",
    revision=revision,
    local_dir=target,
)
open(f"{target}/.revision", "w").write(revision + "\n")
print("model ready:", target)
PY
