#!/bin/bash
# Builds BluejayWispr.app from the SPM package and signs it.
# Run ./setup-signing.sh once to create a stable "Bluejay Wispr Dev" identity —
# with it, TCC permission grants (Accessibility etc.) survive rebuilds.
# Without it, falls back to ad-hoc signing (permissions reset every build).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=BluejayWispr.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BluejayWispr "$APP/Contents/MacOS/"
cp -R .build/release/BluejayWispr_BluejayWispr.bundle "$APP/Contents/Resources/" 2>/dev/null || true
cp Info.plist "$APP/Contents/"

IDENTITY="Bluejay Wispr Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force -s "$IDENTITY" --identifier ai.getbluejay.wispr "$APP"
    echo "Signed with \"$IDENTITY\" (stable — permissions persist across rebuilds)."
else
    codesign --force -s - --identifier ai.getbluejay.wispr "$APP"
    echo "Signed ad-hoc (run ./setup-signing.sh once for stable permissions)."
fi
echo "Built $APP — launch with: open $APP"
