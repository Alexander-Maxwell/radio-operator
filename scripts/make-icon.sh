#!/bin/bash
# Regenerates resources/RadioOperator.icns from the in-app vector mark.
# The app renders the .iconset via `--export-iconset` (one geometry source of
# truth shared with the menu-bar glyph and pill), then iconutil folds it to
# .icns. No SVG rasterizer, Xcode, or asset catalog needed.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build   # debug build is fine — the exporter is offscreen AppKit drawing

WORK="$(mktemp -d)"
ICONSET="$WORK/RadioOperator.iconset"
mkdir -p "$ICONSET"

.build/debug/RadioOperator --export-iconset "$ICONSET"

iconutil -c icns "$ICONSET" -o resources/RadioOperator.icns
rm -rf "$WORK"

echo "→ wrote resources/RadioOperator.icns ($(du -h resources/RadioOperator.icns | cut -f1))"
