#!/bin/bash
# Makes (or updates) appcast.xml for Sparkle from the release files in a folder.
#
#   ./scripts/make_appcast.sh <folder with the .dmg / .zip releases> [download URL prefix]
#
# generate_appcast signs every file with your private update key (kept in your login keychain by generate_keys) and writes
# appcast.xml into the same folder. Put that file at the address in SUFeedURL (Info.plist), for example in the repository root
# of the main branch. See docs/RELEASING.md, "Automatic updates with Sparkle".
set -euo pipefail
cd "$(dirname "$0")/.."

DIR="${1:?usage: ./scripts/make_appcast.sh <folder with releases> [download URL prefix]}"
PREFIX="${2:-https://github.com/thorin-eifel/LaserCraft/releases/download/}"
TOOL="$(find .build/artifacts -path '*/bin/generate_appcast' -maxdepth 6 | head -1)"
[ -x "$TOOL" ] || { echo "Run 'swift package resolve' first (it downloads Sparkle and its tools)."; exit 1; }

"$TOOL" --download-url-prefix "$PREFIX" "$DIR"
echo "Wrote $DIR/appcast.xml"
