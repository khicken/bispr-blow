#!/bin/bash
# Builds .build/BisprBlow.dmg — the app, drag-and-drop, self-contained.
#
# Why this can exist at all: the Fast weights now ride inside the bundle
# (BUNDLE_WEIGHTS=1 below, and LocalEngine.searchRoots reads Contents/Resources/models).
# The .pkg was a .pkg *only* because those weights had to be written to /Library, which a
# disk image cannot do. package.sh is still there and still correct for anyone who wants
# the /Library install; this is the one to put behind a download link.
#
# NOT NOTARIZED. Downloaded from a browser this gets a quarantine flag, and macOS will
# refuse to open it with a message about unverified developer. That is not a bug in this
# script — it needs the Developer ID membership. See README, "Signing and notarization".
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${VERSION:-1.0}
OUT=.build/dmg
DMG=".build/BisprBlow.dmg"

BUNDLE_WEIGHTS=1 ./build.sh

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

echo "Built $DMG ($(du -sh "$DMG" | cut -f1))."
codesign --verify --deep --strict .build/BisprBlow.app \
    && echo "Bundle signature verifies." || echo "Bundle signature does NOT verify." >&2
