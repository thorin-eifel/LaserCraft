#!/bin/bash
# Packs build/LaserCraft.app into a disk image with an "Applications" shortcut:
#   ./scripts/make_dmg.sh            ->  build/LaserCraft-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/LaserCraft.app"
[ -d "$APP" ] || { echo "Build the app first: ./scripts/build_app.sh"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LaserCraftVersion' "$APP/Contents/Info.plist" 2>/dev/null \
           || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/LaserCraft-$VERSION.dmg"
STAGE="build/dmg-stage"

mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -sf /Applications "$STAGE/Applications"

hdiutil create -volname "LaserCraft $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "Created $DMG"
