#!/bin/bash
# Renders the README screenshots into docs/screenshots from the built app, using your library
# and settings. The windows appear on screen for a few seconds while they are captured; the
# copy of AiWallpaper you are running is not affected.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/AiWallpaper.app"
[ -x "$APP/Contents/MacOS/AiWallpaper" ] || scripts/build.sh --native

mkdir -p docs/screenshots
"$APP/Contents/MacOS/AiWallpaper" --screenshots "$PWD/docs/screenshots"
