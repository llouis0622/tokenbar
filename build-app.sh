#!/bin/bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
cd "$(dirname "$0")"

APP="TokenBar.app"
VERSION="$(tr -d '[:space:]' < VERSION)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

PRODUCTS=(TokenBar tokenbar-fan)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    BINS=()
    for ARCH in arm64 x86_64; do
        FLAGS=(-c release --build-system native --triple "$ARCH-apple-macosx14.0")
        swift build "${FLAGS[@]}"
        BINS+=("$(swift build "${FLAGS[@]}" --show-bin-path)")
    done
    for PRODUCT in "${PRODUCTS[@]}"; do
        lipo -create "${BINS[0]}/$PRODUCT" "${BINS[1]}/$PRODUCT" -output "$APP/Contents/MacOS/$PRODUCT"
    done
else
    FLAGS=(-c release --build-system native)
    swift build "${FLAGS[@]}"
    BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"
    for PRODUCT in "${PRODUCTS[@]}"; do
        cp "$BIN/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
    done
fi

for PRODUCT in "${PRODUCTS[@]}"; do
    strip -x "$APP/Contents/MacOS/$PRODUCT"
done
cp Resources/fan-helper.sh "$APP/Contents/Resources/fan-helper.sh"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$VERSION" "$PLIST"
codesign --force --options runtime --identifier io.github.llouis0622.tokenbar.fan --sign - "$APP/Contents/MacOS/tokenbar-fan"
codesign --force --options runtime --sign - "$APP"
echo "built $APP ($VERSION)"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x TokenBar 2>/dev/null || true
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    open "/Applications/$APP"
    echo "installed /Applications/$APP"
fi
