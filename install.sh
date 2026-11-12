#!/bin/bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

REPO="llouis0622/tokenbar"
BASE="https://github.com/$REPO/releases/latest/download"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() {
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-filesize 16777216 -o "$WORK/$1" "$BASE/$1"
}

fetch TokenBar.zip
fetch TokenBar.zip.sha256
(cd "$WORK" && shasum -a 256 -c TokenBar.zip.sha256 >/dev/null)
ditto -x -k "$WORK/TokenBar.zip" "$WORK/unpacked"
codesign --verify --strict --deep "$WORK/unpacked/TokenBar.app"
[[ "$(plutil -extract CFBundleIdentifier raw "$WORK/unpacked/TokenBar.app/Contents/Info.plist")" == "io.github.llouis0622.tokenbar" ]]

pkill -x TokenBar 2>/dev/null || true
rm -rf /Applications/TokenBar.app
ditto "$WORK/unpacked/TokenBar.app" /Applications/TokenBar.app
open /Applications/TokenBar.app
echo "TokenBar $(plutil -extract CFBundleShortVersionString raw /Applications/TokenBar.app/Contents/Info.plist) installed"
