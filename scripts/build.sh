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

# Signing. With the "Lipi Signing" certificate, every build has the same identity, so macOS keeps
# Microphone and Accessibility permission across updates. Without it (e.g. building on another
# Mac), the build is ad-hoc signed and macOS asks for permissions again after each update.
SIGN_DIR="${LIPI_SIGNING_DIR:-$HOME/Library/Application Support/Lipi-Signing}"
KEYCHAIN="$SIGN_DIR/lipi-signing.keychain-db"
SIGN_ARGS=(--force --identifier app.lipi.mac --options runtime --entitlements Support/Lipi.entitlements)
if [ -f "$KEYCHAIN" ] && [ -f "$SIGN_DIR/keychain-password" ]; then
    security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$KEYCHAIN"
    IDENTITY=$(security find-identity -p codesigning "$KEYCHAIN" | awk '/"Lipi Signing"/ {print $2; exit}')
    codesign "${SIGN_ARGS[@]}" --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP"
    SIGNED_WITH="Lipi Signing"
else
    codesign "${SIGN_ARGS[@]}" --sign - "$APP"
    SIGNED_WITH="ad-hoc"
fi

echo "Built $APP ($(du -sh "$APP" | cut -f1), signed: $SIGNED_WITH)"

if [ "${1:-}" = "--zip" ]; then
    rm -f build/Lipi.zip
    ditto -c -k --keepParent "$APP" build/Lipi.zip
    shasum -a 256 build/Lipi.zip | awk '{print $1}' > build/Lipi.zip.sha256
    echo "Packed build/Lipi.zip ($(du -h build/Lipi.zip | cut -f1)), sha256 $(cat build/Lipi.zip.sha256)"
fi
