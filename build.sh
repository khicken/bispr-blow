#!/bin/bash
# Builds, signs, and installs Bluejay Wispr to /Applications, then relaunches it.
# Run ./setup-signing.sh once for a stable identity, or TCC grants reset every build.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# Staged in .build: a second launchable copy means two fn event taps fighting.
APP=.build/BluejayWispr.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BluejayWispr "$APP/Contents/MacOS/"
cp -R .build/release/BluejayWispr_BluejayWispr.bundle "$APP/Contents/Resources/" 2>/dev/null || true
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"

IDENTITY="Bluejay Wispr Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force -s "$IDENTITY" --identifier ai.getbluejay.wispr "$APP"
    echo "Signed with \"$IDENTITY\" (stable — permissions persist across rebuilds)."
else
    codesign --force -s - --identifier ai.getbluejay.wispr "$APP"
    echo "Signed ad-hoc (run ./setup-signing.sh once for stable permissions)."
fi
DEST=/Applications/BluejayWispr.app
pkill -x BluejayWispr 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed $DEST and relaunched."
