#!/bin/bash
# Builds SarashinaOCR.app for local, personal use.
#
#   scripts/build-app.sh [debug|release]
#
# This is a development build: the app resolves the repository's .venv,
# engine/, and models/ at runtime. A relocatable Python runtime is not bundled;
# see the known limitations in README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
  echo "usage: $0 [debug|release]" >&2
  exit 2
fi

cd "$ROOT/app"
# Build output must live outside ~/Documents: the file-provider volume attaches
# Finder metadata that makes nested bundles fail codesign on recent macOS.
SCRATCH="${SARASHINA_BUILD_DIR:-$HOME/Library/Caches/SarashinaOCR-build}"
xattr -cr "$SCRATCH" 2>/dev/null || true
swift build -c "$CONFIG" --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"
APP="$ROOT/dist/SarashinaOCR.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SarashinaOCR" "$APP/Contents/MacOS/SarashinaOCR"
cp -R "$BIN_DIR/SarashinaOCR_SarashinaOCR.bundle" "$APP/Contents/Resources/"
cp "$ROOT/app/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# macOS file-provider and Finder metadata can be attached to bundles inside
# ~/Documents. codesign treats those xattrs as detritus, so clear them before
# creating the ad-hoc signature. The file provider may re-attach FinderInfo
# immediately, so retry with an explicit check.
signed=0
for _ in 1 2 3 4; do
  xattr -cr "$APP" 2>/dev/null || true
  xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$APP" 2>/dev/null || true
  if codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
     && codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    signed=1
    break
  fi
  sleep 0.2
done
if [[ "$signed" != "1" ]]; then
  echo "warning: ad-hoc codesign failed; the app may still run locally" >&2
fi

echo "built: $APP"
