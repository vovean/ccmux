#!/bin/bash
# Assembles the .app bundle from the SwiftPM build. No Xcode required.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/dist/ccmux.app"
CONF="${1:-release}"

swift build -c "$CONF" --product ccmux
BIN="$(swift build -c "$CONF" --show-bin-path)/ccmux"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ccmux"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" \
  "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - --identifier io.vovean.ccmux "$APP" >/dev/null
echo "built $APP"
