#!/bin/bash
# Runs the Swift test suite with build products outside ~/Documents.
#
# Recent macOS versions attach file-provider/Finder xattrs to bundles created
# inside ~/Documents. codesign rejects those xattrs for the test bundle, so the
# scratch path defaults to ~/Library/Caches.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${SARASHINA_BUILD_DIR:-$HOME/Library/Caches/SarashinaOCR-build}"

cd "$ROOT/app"
xattr -cr "$SCRATCH" 2>/dev/null || true
swift test --scratch-path "$SCRATCH"
