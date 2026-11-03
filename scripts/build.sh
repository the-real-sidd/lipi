#!/bin/bash
# Builds Lipi.app (and Lipi.zip for releases) from source.
# Usage: scripts/build.sh [--zip]
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Lipi.app
swift build -c release --build-system native 2>&1 | grep -v "deprecated" || true
BIN=$(swift build -c release --build-system native --show-bin-path 2>/dev/null)/Lipi
[ -x "$BIN" ] || { echo "Build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lipi"
strip -x "$APP/Contents/MacOS/Lipi" 2>/dev/null || true
cp Support/Info.plist "$APP/Contents/Info.plist"
[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature. A stable identifier keeps macOS permissions tied to "app.lipi.mac".
codesign --force --sign - --identifier app.lipi.mac --options runtime \
    --entitlements Support/Lipi.entitlements "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--zip" ]; then
    rm -f build/Lipi.zip
    ditto -c -k --keepParent "$APP" build/Lipi.zip
    shasum -a 256 build/Lipi.zip | awk '{print $1}' > build/Lipi.zip.sha256
    echo "Packed build/Lipi.zip ($(du -h build/Lipi.zip | cut -f1)), sha256 $(cat build/Lipi.zip.sha256)"
fi
