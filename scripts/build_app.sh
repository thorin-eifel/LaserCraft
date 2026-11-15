#!/bin/bash
# Builds LaserCraft.app (a normal double-clickable Mac app) into build/.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. translations (fails if a text used in the code has no German/French version)
python3 -I scripts/make_strings.py

# 2. program
swift build -c release
BIN="$(swift build -c release --show-bin-path)/LaserGRBLMac"

# 3. app bundle
APP="build/LaserCraft.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LaserCraft"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Translations (English, German, French)
for lang in en de fr; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    cp "Resources/$lang.lproj/Localizable.strings" "$APP/Contents/Resources/$lang.lproj/"
done

# Ad-hoc signature so macOS will run it locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
