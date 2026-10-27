#!/bin/zsh
# Builds DriftedStudio.app (release) into ./build using only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product DriftedStudio
BIN="$(swift build -c release --show-bin-path)/DriftedStudio"
APP=build/DriftedStudio.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DriftedStudio"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP — open it with: open $APP"
