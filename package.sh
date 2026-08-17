#!/bin/bash
# Builds BisprBlow.pkg: the app, the Fast weights, and the Accurate weights as an installer choice.
#
# A .pkg rather than a .dmg because a disk image is drag-and-drop with no UI, and which weights to
# install has to be asked. `customize="always"` below is what makes Installer show that choice.
#
# Weights land in /Library, not ~/Library: a .pkg cannot write to a home directory without moving
# the whole install to the user domain, which drags the app out of /Applications with it.
set -euo pipefail
cd "$(dirname "$0")"

MODELS="$HOME/Library/Application Support/BluejayWispr/models"
FAST=Qwen3-0.6B-MLX-4bit
ACCURATE=Qwen3-1.7B-MLX-8bit
INSTALL_TO="/Library/Application Support/BluejayWispr/models"
VERSION=${VERSION:-1.0}
OUT=.build/pkg

for m in "$FAST" "$ACCURATE"; do
    [ -d "$MODELS/$m" ] || { echo "Missing weights: $MODELS/$m" >&2; exit 1; }
done

./build.sh

# A missing metallib aborts the process on first dictation rather than throwing — no degraded mode.
[ -f ".build/BisprBlow.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" ] \
    || { echo "Bundle has no metallib — MLX would abort on first dictation." >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

pkgbuild --component .build/BisprBlow.app --install-location /Applications \
    --identifier ai.getbluejay.wispr.app --version "$VERSION" "$OUT/app.pkg" >/dev/null

# `--filter` excludes, so naming every other model is how one gets kept — and no payload has to copy
# gigabytes into a staging tree. GGUF is excluded from both: it is the fallback for the metallib the
# check above guarantees.
weights() {  # weights <model-dir> <identifier> <output>
    local keep=$1 filters=() d
    for d in "$MODELS"/*; do
        [ "$(basename "$d")" = "$keep" ] || filters+=(--filter "$(basename "$d")")
    done
    pkgbuild --root "$MODELS" --install-location "$INSTALL_TO" \
        --identifier "$2" --version "$VERSION" "${filters[@]}" "$3" >/dev/null
}
weights "$FAST" ai.getbluejay.wispr.model.fast "$OUT/fast.pkg"
weights "$ACCURATE" ai.getbluejay.wispr.model.accurate "$OUT/accurate.pkg"

# Fast ships with the app and cannot be deselected. Installing only Accurate would not give you a
# careful tier — it would make "Fast" resolve to the 1.7B too, since Fast means the smallest model
# present. One model installed makes the Writing setting a label with nothing behind it.
cat > "$OUT/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>BisprBlow</title>
    <options customize="always" require-scripts="false" hostArchitectures="arm64"/>
    <os-version min="26.0"/>
    <choices-outline>
        <line choice="app"/>
        <line choice="accurate"/>
    </choices-outline>
    <choice id="app" title="BisprBlow" start_enabled="false"
            description="The app, and the fast model it cleans up your words with. 335 MB.">
        <pkg-ref id="ai.getbluejay.wispr.app"/>
        <pkg-ref id="ai.getbluejay.wispr.model.fast"/>
    </choice>
    <choice id="accurate" title="Accurate writing" start_selected="false"
            description="A larger model for the Accurate setting, which reads longer dictations more carefully. Leave this off and BisprBlow still works, but Accurate writes the same as Fast. 1.7 GB.">
        <pkg-ref id="ai.getbluejay.wispr.model.accurate"/>
    </choice>
    <pkg-ref id="ai.getbluejay.wispr.app" version="$VERSION">#app.pkg</pkg-ref>
    <pkg-ref id="ai.getbluejay.wispr.model.fast" version="$VERSION">#fast.pkg</pkg-ref>
    <pkg-ref id="ai.getbluejay.wispr.model.accurate" version="$VERSION">#accurate.pkg</pkg-ref>
</installer-gui-script>
EOF

# Unsigned: signing an installer needs a Developer ID Installer certificate, which comes with the
# paid Apple Developer Program. Without one the installer is refused on first open and has to be
# started with right-click > Open — see README.
productbuild --distribution "$OUT/distribution.xml" --package-path "$OUT" \
    --resources "$OUT" .build/BisprBlow.pkg >/dev/null

echo "Built .build/BisprBlow.pkg ($(du -h .build/BisprBlow.pkg | cut -f1))"
