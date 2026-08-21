#!/bin/bash
# Regenerates Resources/AppIcon.icns from the app's own icon view.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product ccmux >/dev/null
BIN="$(swift build -c release --show-bin-path)/ccmux"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$BIN" --render-icon "$WORK/icon1024.png" >/dev/null

IS="$WORK/AppIcon.iconset"
mkdir -p "$IS"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512"; do
  set -- $spec
  sips -z "$1" "$1" "$WORK/icon1024.png" --out "$IS/$2.png" >/dev/null
done
cp "$WORK/icon1024.png" "$IS/icon_512x512@2x.png"

iconutil -c icns "$IS" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
