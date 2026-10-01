#!/bin/bash
# Builds build/AiWallpaper.app from the Swift package.
#
#   scripts/build.sh              release build for this Mac
#   scripts/build.sh --universal  Apple Silicon + Intel
#   scripts/build.sh --install    also copy the app to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="AiWallpaper"
APP="build/$APP_NAME.app"
INSTALL=0
ARCH_FLAGS=()

for argument in "$@"; do
    case "$argument" in
        --install) INSTALL=1 ;;
        --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
        *) echo "Unknown option: $argument" >&2; exit 1 ;;
    esac
done

echo "→ Compiling…"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

if [ ! -f Resources/AppIcon.icns ]; then
    echo "→ Drawing the icon…"
    swift scripts/make-icon.swift Resources/AppIcon.icns
fi

echo "→ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

echo "→ Signing (ad hoc)…"
codesign --force --sign - --timestamp=none "$APP"

if [ "$INSTALL" -eq 1 ]; then
    echo "→ Installing to /Applications…"
    if pgrep -x "$APP_NAME" >/dev/null; then
        osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || pkill -x "$APP_NAME" || true
        sleep 1
    fi
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    APP="/Applications/$APP_NAME.app"
fi

echo "✓ $APP"
