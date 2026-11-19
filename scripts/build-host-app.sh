#!/bin/zsh
# Builds "Drifted.app" (menu-bar host + drifted-mcp) into ./build.
# Signing: set DRIFTED_SIGN_IDENTITY="Developer ID Application: …" for a distributable build
# (hardened runtime + timestamp, ready for notarization); otherwise it is ad-hoc signed for local use.
# WeatherKit (optional, for the schedule's weather picture): also set DRIFTED_PROVISIONING_PROFILE to a
# Developer ID provisioning profile for this bundle id with the WeatherKit capability. It's embedded and the
# app is signed with its entitlements. Without it Drifted gets the forecast from Open-Meteo. Never commit a profile.
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
PROFILE="${DRIFTED_PROVISIONING_PROFILE:-}"
ENTITLEMENTS=()
if [[ -n "$PROFILE" ]]; then
  [[ "$IDENTITY" != "-" ]] || { echo "DRIFTED_PROVISIONING_PROFILE needs DRIFTED_SIGN_IDENTITY (the profile's Developer ID)" >&2; exit 1; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  security cms -D -i "$PROFILE" > "$TMP/profile.plist"
  pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true; }
  APPID="$(pb Entitlements:com.apple.application-identifier "$TMP/profile.plist")"
  TEAM="$(pb Entitlements:com.apple.developer.team-identifier "$TMP/profile.plist")"
  BUNDLE="$(pb CFBundleIdentifier Support/Drifted-Info.plist)"
  [[ "$APPID" == "$TEAM.$BUNDLE" ]] || { echo "the profile is for $APPID, not $TEAM.$BUNDLE" >&2; exit 1; }
  [[ "$(pb Entitlements:com.apple.developer.weatherkit "$TMP/profile.plist")" == "true" ]] \
    || { echo "the profile doesn't include WeatherKit" >&2; exit 1; }
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  cat > "$TMP/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.application-identifier</key><string>$APPID</string>
<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
<key>com.apple.developer.weatherkit</key><true/>
</dict></plist>
EOF
  ENTITLEMENTS=(--entitlements "$TMP/entitlements.plist")
fi

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP/Contents/MacOS/drifted-mcp"
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/drifted-mcp"
  codesign --force --options runtime --timestamp "${ENTITLEMENTS[@]}" --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP (signed: $IDENTITY${PROFILE:+, with WeatherKit})"
