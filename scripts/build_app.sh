#!/bin/bash
# Builds LaserCraft.app (a normal double-clickable Mac app) into build/.
#
#   ./scripts/build_app.sh                      universal app (Apple silicon + Intel), ad-hoc signed
#   UNIVERSAL=0 ./scripts/build_app.sh          only for this Mac's processor (faster)
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build_app.sh
#                                               signed with your Developer ID (hardened runtime, ready for notarisation)
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${CODESIGN_IDENTITY:--}"

# 1. translations (fails if a text used in the code has no translation)
python3 -I scripts/make_strings.py

# 2. program
if [ "${UNIVERSAL:-1}" = "1" ]; then
    ARCHS=(--arch arm64 --arch x86_64)
else
    ARCHS=()
fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/LaserGRBLMac"

# 3. app bundle
APP="build/LaserCraft.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LaserCraft"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Materials.json "$APP/Contents/Resources/Materials.json"

# Translations: every Resources/<language>.lproj folder
for dir in Resources/*.lproj; do
    lang="$(basename "$dir")"
    mkdir -p "$APP/Contents/Resources/$lang"
    cp "$dir/Localizable.strings" "$APP/Contents/Resources/$lang/"
done

# 4. signature
if [ "$IDENTITY" = "-" ]; then
    # ad hoc: runs on this Mac and, after right-click -> Open, on others; cannot be notarised
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
else
    codesign --force --options runtime --timestamp --entitlements Resources/LaserCraft.entitlements --sign "$IDENTITY" "$APP"
fi

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/LaserCraft"))"
