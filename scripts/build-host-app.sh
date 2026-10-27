#!/bin/zsh
# Builds "Drifted.app" (menu-bar host + drifted-mcp) into ./build.
# Signing: set DRIFTED_SIGN_IDENTITY="Developer ID Application: …" for a distributable build
# (hardened runtime + timestamp, ready for notarization); otherwise it is ad-hoc signed for local use.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product DriftedMenu
swift build -c release --product drifted-mcp
BIN="$(swift build -c release --show-bin-path)"
APP="build/Drifted.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/DriftedMenu" "$BIN/drifted-mcp" "$APP/Contents/MacOS/"
cp Support/Drifted-Info.plist "$APP/Contents/Info.plist"

IDENTITY="${DRIFTED_SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP/Contents/MacOS/drifted-mcp"
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/drifted-mcp"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP (signed: $IDENTITY)"
