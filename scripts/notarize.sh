#!/bin/bash
# Sends the signed disk image (or app zip) to Apple for notarisation and staples the ticket.
#
# One-time setup (needs a paid Apple Developer account and a "Developer ID Application" certificate in your keychain):
#   xcrun notarytool store-credentials "lasercraft-notary" --apple-id you@example.com --team-id TEAMID --password <app-specific password>
#
# Then:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build_app.sh
#   ./scripts/make_dmg.sh
#   NOTARY_PROFILE=lasercraft-notary ./scripts/notarize.sh build/LaserCraft-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

FILE="${1:?usage: NOTARY_PROFILE=<keychain profile> ./scripts/notarize.sh <file.dmg>}"
PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE to the name of your notarytool keychain profile}"

if ! codesign -dv --verbose=2 build/LaserCraft.app 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "build/LaserCraft.app is not signed with a Developer ID certificate. See docs/RELEASING.md."
    exit 1
fi

xcrun notarytool submit "$FILE" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$FILE"
xcrun stapler validate "$FILE"
spctl --assess --type open --context context:primary-signature -v "$FILE" || true
echo "Notarised and stapled: $FILE"
