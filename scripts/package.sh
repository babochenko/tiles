#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
STAGING="$DIST/dmg"
APP="$STAGING/Tiles.app"
DMG="$DIST/Tiles.dmg"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
    -framework AppKit \
    -framework ApplicationServices \
    -framework ServiceManagement \
    "$ROOT/Sources/Tiles/main.swift" \
    -o "$APP/Contents/MacOS/Tiles"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Tiles" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG"

echo "Created $DMG"
