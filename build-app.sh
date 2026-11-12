#!/bin/bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
cd "$(dirname "$0")"

if [[ "${1:-}" == "--update" ]]; then
    export GIT_TERMINAL_PROMPT=0
    git pull --ff-only origin main
    exec /bin/bash "$PWD/build-app.sh" --install
fi

APP="TokenBar.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    SLICES=()
    for ARCH in arm64 x86_64; do
        FLAGS=(-c release --build-system native --triple "$ARCH-apple-macosx14.0")
        swift build "${FLAGS[@]}"
        SLICES+=("$(swift build "${FLAGS[@]}" --show-bin-path)/TokenBar")
    done
    lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/TokenBar"
else
    FLAGS=(-c release --build-system native)
    swift build "${FLAGS[@]}"
    cp "$(swift build "${FLAGS[@]}" --show-bin-path)/TokenBar" "$APP/Contents/MacOS/TokenBar"
fi

strip -x "$APP/Contents/MacOS/TokenBar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$VERSION" "$PLIST"
plutil -replace TBCommit -string "$COMMIT" "$PLIST"
codesign --force --options runtime --sign - "$APP"
echo "built $APP ($VERSION, ${COMMIT:0:7})"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x TokenBar 2>/dev/null || true
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    open "/Applications/$APP"
    echo "installed /Applications/$APP"
fi
