#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="TokenBar.app"
VERSION="$(tr -d '[:space:]' < VERSION)"

FLAGS=(-c release --build-system native)
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/TokenBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TokenBar"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $APP ($VERSION)"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x TokenBar 2>/dev/null || true
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    open "/Applications/$APP"
    echo "installed /Applications/$APP"
fi
