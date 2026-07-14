#!/bin/bash
# Regenerates resources/RadioOperator.icns from resources/app-icon-source.png
# (the illustrated Marine radio-operator icon). ponytail: sips + iconutil on the
# finished art — no vector drawing needed.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="resources/app-icon-source.png"
WORK="$(mktemp -d)/RadioOperator.iconset"
mkdir -p "$WORK"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$SRC" --out "$WORK/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s * 2))" "$((s * 2))" "$SRC" --out "$WORK/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$WORK" -o resources/RadioOperator.icns
rm -rf "$(dirname "$WORK")"
echo "→ wrote resources/RadioOperator.icns ($(du -h resources/RadioOperator.icns | cut -f1))"
