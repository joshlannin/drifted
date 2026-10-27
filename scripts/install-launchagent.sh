#!/bin/zsh
# Installs drifted-host as a per-user LaunchAgent so it starts at login and restarts if it exits.
# Usage: scripts/install-launchagent.sh [--menu]      (--menu runs the DriftedMenu menu-bar host instead of headless drifted-host)
#        scripts/install-launchagent.sh --uninstall
# First run: macOS asks once for Bluetooth permission for the binary. On a headless Mac Mini, approve it over
# Screen Sharing (System Settings → Privacy & Security → Bluetooth).
set -euo pipefail
cd "$(dirname "$0")/.."
LABEL=net.altimix.drifted-host
PLIST=~/Library/LaunchAgents/$LABEL.plist
DEST=~/Library/Application\ Support/Drifted/bin

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
  rm -f $PLIST
  echo "Removed $LABEL (state in ~/Library/Application Support/Drifted kept)"
  exit 0
fi

PRODUCT=drifted-host
[[ "${1:-}" == "--menu" ]] && PRODUCT=DriftedMenu
swift build -c release --product $PRODUCT
swift build -c release --product drifted-mcp
mkdir -p "$DEST"
cp .build/release/$PRODUCT .build/release/drifted-mcp "$DEST/"

cat > $PLIST <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST/$PRODUCT</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/drifted-host.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/drifted-host.log</string>
</dict></plist>
PL

launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
launchctl bootstrap gui/$UID $PLIST
echo "Installed $LABEL running $DEST/$PRODUCT (log: ~/Library/Logs/drifted-host.log)"
echo "MCP: claude mcp add drifted -- \"$DEST/drifted-mcp\""
