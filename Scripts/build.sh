#!/bin/bash
# Builds ThumbPrint and launches it.
#
#   ./Scripts/build.sh            # debug build, then run
#   ./Scripts/build.sh release    # release build, then run
#   ./Scripts/build.sh install    # release build, then copy to /Applications
#
# DEVELOPER_DIR is set explicitly because `xcode-select` on this machine points
# at the Command Line Tools rather than Xcode. Setting it here avoids a global
# `sudo xcode-select -s`, which would change the machine for every other tool.

set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

MODE="${1:-debug}"
CONFIG="Debug"
[[ "$MODE" == "release" || "$MODE" == "install" ]] && CONFIG="Release"

echo "Building ThumbPrint ($CONFIG)…"
xcodebuild \
    -project ThumbPrint.xcodeproj \
    -scheme ThumbPrint \
    -configuration "$CONFIG" \
    build \
    | grep -E "error:|warning:|BUILD" || true

BUILT_DIR=$(xcodebuild -project ThumbPrint.xcodeproj -scheme ThumbPrint \
    -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
    | awk '/ BUILT_PRODUCTS_DIR =/ { print $3 }')

APP="$BUILT_DIR/ThumbPrint.app"

if [[ ! -d "$APP" ]]; then
    echo "Build did not produce $APP" >&2
    exit 1
fi

if [[ "$MODE" == "install" ]]; then
    echo "Installing to /Applications…"
    rm -rf /Applications/ThumbPrint.app
    cp -R "$APP" /Applications/ThumbPrint.app
    echo "Installed /Applications/ThumbPrint.app"
    open /Applications/ThumbPrint.app
else
    echo "Launching $APP"
    open "$APP"
fi
