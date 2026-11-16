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

# Sparkle (automatic updates): the framework goes next to the program; it only starts when Info.plist has SUPublicEDKey
SPARKLE="$(find .build/artifacts -path '*macos-arm64_x86_64/Sparkle.framework' -maxdepth 8 -type d 2>/dev/null | head -1)"
if [ -n "$SPARKLE" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/LaserCraft" 2>/dev/null || true
fi

# Translations: every Resources/<language>.lproj folder
for dir in Resources/*.lproj; do
    lang="$(basename "$dir")"
    mkdir -p "$APP/Contents/Resources/$lang"
    cp "$dir/Localizable.strings" "$APP/Contents/Resources/$lang/"
done

# 4. signature
if [ "$IDENTITY" = "-" ]; then
    # ad hoc: runs on this Mac and, after right-click -> Open, on others; cannot be notarised
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
else
    # inside out: Sparkle's helpers, then the framework, then the app
    FW="$APP/Contents/Frameworks/Sparkle.framework"
    if [ -d "$FW" ]; then
        for item in "$FW"/Versions/B/XPCServices/*.xpc "$FW"/Versions/B/Autoupdate "$FW"/Versions/B/Updater.app; do
            [ -e "$item" ] && codesign --force --options runtime --timestamp --sign "$IDENTITY" "$item"
        done
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW"
    fi
    codesign --force --options runtime --timestamp --entitlements Resources/LaserCraft.entitlements --sign "$IDENTITY" "$APP"
fi

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/LaserCraft"))"
