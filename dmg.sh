#!/bin/bash
# Builds .build/BisprBlow.dmg — the app, drag-and-drop, self-contained.
#
# Why this can exist at all: the Fast weights now ride inside the bundle
# (BUNDLE_WEIGHTS=1 below, and LocalEngine.searchRoots reads Contents/Resources/models).
# The .pkg was a .pkg *only* because those weights had to be written to /Library, which a
# disk image cannot do. package.sh is still there and still correct for anyone who wants
# the /Library install; this is the one to put behind a download link.
#
# Signed with the Developer ID (build.sh picks it), then notarized and stapled when the
# notarytool profile exists, so a browser download opens without a Gatekeeper warning.
# Store the profile once: xcrun notarytool store-credentials bisprblow --apple-id <id> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")"

# Same newest-tag version build.sh stamps into the bundle, so the installer cannot claim a
# different version than the app inside it.
VERSION=${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 1.0)}
OUT=.build/dmg
DMG=".build/BisprBlow.dmg"

BUNDLE_WEIGHTS=1 BUNDLE_SPEECH=1 ./build.sh

# Same guard as package.sh: MLX aborts the process on first dictation without this, rather
# than throwing, so there is no degraded mode to notice later.
[ -f ".build/BisprBlow.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" ] \
    || { echo "Bundle has no metallib — MLX would abort on first dictation." >&2; exit 1; }
[ -d ".build/BisprBlow.app/Contents/Resources/models/Qwen3-0.6B-MLX-4bit" ] \
    || { echo "Bundle has no Fast weights — the app would launch into rule-based cleanup." >&2; exit 1; }

rm -rf "$OUT" "$DMG"
mkdir -p "$OUT"
cp -R .build/BisprBlow.app "$OUT/"
ln -s /Applications "$OUT/Applications"   # the drag target, and the whole UI of a .dmg

hdiutil create -volname BisprBlow -srcfolder "$OUT" -ov -format UDZO -quiet "$DMG"

codesign --verify --deep --strict .build/BisprBlow.app \
    || { echo "Bundle signature does NOT verify." >&2; exit 1; }

DEVID=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
if [ -z "$DEVID" ]; then
    echo "Built $DMG ($(du -sh "$DMG" | cut -f1)). No Developer ID, so not notarized." >&2
    exit 0
fi
codesign --force -s "$DEVID" --timestamp "$DMG"

PROFILE=${NOTARY_PROFILE:-bisprblow}
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    # --wait blocks until Apple answers, usually a few minutes for a file this size.
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl -a -t open --context context:primary-signature -vv "$DMG"
    echo "Built, notarized and stapled $DMG ($(du -sh "$DMG" | cut -f1))."
else
    echo "Built and signed $DMG, NOT notarized: no notarytool profile \"$PROFILE\"." >&2
fi
