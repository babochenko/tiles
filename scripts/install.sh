#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="$ROOT/dist/Tiles.dmg"
DESTINATION="/Applications/Tiles.app"
MOUNT_POINT="$(mktemp -d /tmp/tiles-dmg.XXXXXX)"

cleanup() {
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Building Tiles from source..."
"$ROOT/scripts/package.sh"

hdiutil attach "$DMG" -mountpoint "$MOUNT_POINT" -nobrowse -readonly -quiet

if [[ ! -d "$MOUNT_POINT/Tiles.app" ]]; then
    echo "Tiles.app was not found in $DMG" >&2
    exit 1
fi

pkill -x Tiles 2>/dev/null || true

if [[ -w /Applications ]]; then
    rm -rf "$DESTINATION"
    ditto "$MOUNT_POINT/Tiles.app" "$DESTINATION"
else
    sudo rm -rf "$DESTINATION"
    sudo ditto "$MOUNT_POINT/Tiles.app" "$DESTINATION"
fi

open "$DESTINATION"
echo "Installed and launched $DESTINATION"
