#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
STAGING="$DIST/dmg"
APP="$STAGING/Tiles.app"
DMG="$DIST/Tiles.dmg"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

CORE_BUILD="$DIST/TilesCore"
mkdir -p "$CORE_BUILD"
swiftc -O \
    -whole-module-optimization \
    -parse-as-library \
    -emit-object \
    -emit-module \
    -module-name TilesCore \
    "$ROOT/Sources/TilesCore/"*.swift \
    -o "$CORE_BUILD/TilesCore.o" \
    -emit-module-path "$CORE_BUILD/TilesCore.swiftmodule"

swiftc -O \
    -framework AppKit \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -I "$CORE_BUILD" \
    "$ROOT/Sources/Tiles/main.swift" \
    "$CORE_BUILD/TilesCore.o" \
    -o "$APP/Contents/MacOS/Tiles"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
ICONSET="$DIST/AppIcon.iconset"
swift "$ROOT/scripts/generate-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
codesign --force --deep --sign - \
    --identifier "app.tiles.windowmanager" \
    --requirements '=designated => identifier "app.tiles.windowmanager"' \
    "$APP"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Tiles" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG"

echo "Created $DMG"
