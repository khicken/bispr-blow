#!/bin/bash
# Builds BisprBlow.pkg: the app and the Fast weights. Nothing else.
#
# The Accurate weights are NOT in here — 1.7 GB of the old 2.06 GB package. They are fetched on
# demand by `ModelDownloader`, from the same repo this used to install, and Settings offers that
# download exactly when Accurate would collapse onto Fast (`LLMCleaner.accurateNeedsModel`).
# That removed the installer's only question, so this stays a .pkg only for the /Library write
# below, not for a choice pane.
#
# Weights land in /Library, not ~/Library: a .pkg cannot write to a home directory without moving
# the whole install to the user domain, which drags the app out of /Applications with it.
set -euo pipefail
cd "$(dirname "$0")"

MODELS="$HOME/Library/Application Support/BisprBlow/models"
FAST=Qwen3-0.6B-MLX-4bit
INSTALL_TO="/Library/Application Support/BisprBlow/models"
VERSION=${VERSION:-1.0}
OUT=.build/pkg

[ -d "$MODELS/$FAST" ] || { echo "Missing weights: $MODELS/$FAST" >&2; exit 1; }

./build.sh

# A missing metallib aborts the process on first dictation rather than throwing — no degraded mode.
[ -f ".build/BisprBlow.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" ] \
    || { echo "Bundle has no metallib — MLX would abort on first dictation." >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

pkgbuild --component .build/BisprBlow.app --install-location /Applications \
    --identifier ai.getbluejay.bisprblow.app --version "$VERSION" "$OUT/app.pkg" >/dev/null

# `--filter` excludes, so naming every other model is how Fast alone gets kept — and no payload has
# to copy gigabytes into a staging tree. Any GGUF on disk is excluded the same way: it is the
# fallback for the metallib the check above guarantees.
filters=()
for d in "$MODELS"/*; do
    [ "$(basename "$d")" = "$FAST" ] || filters+=(--filter "$(basename "$d")")
done
pkgbuild --root "$MODELS" --install-location "$INSTALL_TO" \
    --identifier ai.getbluejay.bisprblow.model.fast --version "$VERSION" \
    "${filters[@]}" "$OUT/fast.pkg" >/dev/null

# Fast ships with the app and is not optional: Fast means the smallest model present, so a machine
# holding only the 1.7B would resolve Fast to it and the Writing setting would become a label with
# one model behind both sides.
cat > "$OUT/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>BisprBlow</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <os-version min="26.0"/>
    <choices-outline>
        <line choice="app"/>
    </choices-outline>
    <choice id="app" title="BisprBlow" start_enabled="false">
        <pkg-ref id="ai.getbluejay.bisprblow.app"/>
        <pkg-ref id="ai.getbluejay.bisprblow.model.fast"/>
    </choice>
    <pkg-ref id="ai.getbluejay.bisprblow.app" version="$VERSION">#app.pkg</pkg-ref>
    <pkg-ref id="ai.getbluejay.bisprblow.model.fast" version="$VERSION">#fast.pkg</pkg-ref>
</installer-gui-script>
EOF

# Unsigned: signing an installer needs a Developer ID Installer certificate, which comes with the
# paid Apple Developer Program. Without one the installer is refused on first open and has to be
# started with right-click > Open — see README.
productbuild --distribution "$OUT/distribution.xml" --package-path "$OUT" \
    --resources "$OUT" .build/BisprBlow.pkg >/dev/null

echo "Built .build/BisprBlow.pkg ($(du -h .build/BisprBlow.pkg | cut -f1))"
