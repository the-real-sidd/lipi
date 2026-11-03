#!/bin/bash
# Installs Lipi on an Apple Silicon Mac running macOS 26 or newer.
#   curl -fsSL https://raw.githubusercontent.com/the-real-sidd/lipi/main/install.sh | bash
# Build from source instead (needs Xcode Command Line Tools):
#   curl -fsSL https://raw.githubusercontent.com/the-real-sidd/lipi/main/install.sh | bash -s -- --source
set -euo pipefail

REPO="the-real-sidd/lipi"
ZIP_URL="https://github.com/$REPO/releases/latest/download/Lipi.zip"
SUM_URL="https://github.com/$REPO/releases/latest/download/Lipi.zip.sha256"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
stop() { printf '\nLipi was not installed: %s\n' "$1" >&2; exit 1; }

main() {
    [ "$(uname -s)" = "Darwin" ] || stop "Lipi is a Mac app."
    [ "$(uname -m)" = "arm64" ] || stop "Lipi needs an Apple Silicon Mac (M1 or newer)."
    local major
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$major" -ge 26 ] || stop "Lipi needs macOS 26 or newer (it uses Apple's new on-device speech and translation)."

    if [ -w /Applications ]; then APPS=/Applications; else APPS="$HOME/Applications"; mkdir -p "$APPS"; fi
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT

    if [ "${1:-}" = "--source" ]; then
        command -v swift >/dev/null || stop "Swift isn't installed. Run: xcode-select --install"
        say "Building Lipi from source"
        git clone --depth 1 "https://github.com/$REPO.git" "$WORK/src"
        (cd "$WORK/src" && scripts/build.sh)
        APP="$WORK/src/build/Lipi.app"
    else
        say "Downloading Lipi (about 1.5 MB)"
        curl -fL --progress-bar -o "$WORK/Lipi.zip" "$ZIP_URL" || stop "the download failed. Check your internet and try again."
        if curl -fsL -o "$WORK/Lipi.zip.sha256" "$SUM_URL"; then
            local expected actual
            expected=$(tr -d '[:space:]' < "$WORK/Lipi.zip.sha256")
            actual=$(shasum -a 256 "$WORK/Lipi.zip" | awk '{print $1}')
            [ "$expected" = "$actual" ] || stop "the download was damaged or changed. Please try again."
        fi
        ditto -x -k "$WORK/Lipi.zip" "$WORK/app"
        APP="$WORK/app/Lipi.app"
    fi

    codesign --verify "$APP" 2>/dev/null || stop "the app failed its signature check."

    say "Installing to $APPS"
    pkill -x Lipi 2>/dev/null || true
    rm -rf "$APPS/Lipi.app"
    mv "$APP" "$APPS/"
    open "$APPS/Lipi.app"

    cat <<'DONE'

==> Lipi is installed and open.

In the Lipi window:
  1. Allow the Microphone.
  2. Turn on Lipi in System Settings > Privacy & Security > Accessibility.
  3. Download the Hindi speech model and the Hindi <-> English translation
     (macOS downloads these itself, shares them with other apps, and keeps them updated).

Then hold Right Option, speak in Hindi, and let go. Lipi types it in English.
DONE
}

# Everything runs from here, so a cut-off download can't run half a script.
main "$@"
