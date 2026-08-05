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

# llama.framework resolves via @loader_path beside the CLI binary, so `swift build` output runs
# fine while an installed bundle without its own copy dies at launch: "Library not loaded".
mkdir -p "$APP/Contents/Frameworks"
cp -R .build/arm64-apple-macosx/release/llama.framework "$APP/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/BluejayWispr"

IDENTITY="Bluejay Wispr Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    SIGN_ID="$IDENTITY"
    echo "Signing with \"$IDENTITY\" (stable — permissions persist across rebuilds)."
else
    SIGN_ID="-"
    echo "Signing ad-hoc (run ./setup-signing.sh once for stable permissions)."
fi
codesign --force -s "$SIGN_ID" "$APP/Contents/Frameworks/llama.framework"
codesign --force -s "$SIGN_ID" --identifier ai.getbluejay.wispr "$APP"
DEST=/Applications/BluejayWispr.app
pkill -x BluejayWispr 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed $DEST and relaunched."
