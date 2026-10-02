#!/bin/bash
# Builds build/AiWallpaper.app from the Swift package.
#
#   scripts/build.sh            universal app: Apple Silicon and Intel
#   scripts/build.sh --native   only for this Mac's processor; twice as fast, for development
#   scripts/build.sh --install  also copy the app to /Applications
#   scripts/build.sh --dist     also pack the app into dist/AiWallpaper.zip, the download in the README
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="AiWallpaper"
APP="build/$APP_NAME.app"
INSTALL=0
DIST=0
NATIVE=0
ARCH_FLAGS=(--arch arm64 --arch x86_64)

for argument in "$@"; do
    case "$argument" in
        --install) INSTALL=1 ;;
        --dist) DIST=1 ;;
        --native) NATIVE=1; ARCH_FLAGS=() ;;
        *) echo "Unknown option: $argument" >&2; exit 1 ;;
    esac
done

if [ "$DIST" -eq 1 ] && [ "$NATIVE" -eq 1 ]; then
    echo "--dist packs the universal app for every Mac; drop --native" >&2
    exit 1
fi

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

if [ "$DIST" -eq 1 ]; then
    echo "→ Packing dist/$APP_NAME.zip…"
    mkdir -p dist
    rm -f "dist/$APP_NAME.zip"
    # The signature lives in the bundle's files, so this Mac's extended attributes (provenance)
    # are left out; they would only add a __MACOSX folder to the archive.
    ditto -c -k --keepParent --norsrc --noextattr --noacl "$APP" "dist/$APP_NAME.zip"
fi

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
