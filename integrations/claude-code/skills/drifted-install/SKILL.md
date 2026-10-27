---
name: drifted-install
description: Install Drifted on the user's Mac so you can draw on their HoMedics Drift sand table (Bluetooth models). Use when the user asks to set up, install or connect their Drift table, or when the drifted MCP tools fail because the host isn't running.
---

# Install Drifted (macOS)

0. Check the table is supported: Bluetooth Drift 16" (ST-300) or 21" (ST-400), using the "HoMedics Drift" app.
   The Wi-Fi models (11" ST-200, ST-250, app "Homedics Drift (Wi-Fi)") don't work with Drifted; if that's what
   the user has, say so and stop.
1. Prerequisites: macOS 13+, `xcode-select -p` succeeds (otherwise ask the user to run `xcode-select --install`),
   the table is on, and the HoMedics phone app is closed (the table takes one connection at a time).
2. Get the source and build the host app:
   ```sh
   git clone https://github.com/joshlannin/drifted ~/drifted 2>/dev/null || git -C ~/drifted pull
   cd ~/drifted && scripts/build-host-app.sh
   cp -R "build/Drifted.app" /Applications/ && open "/Applications/Drifted.app"
   ```
   If the user prefers, they can instead download Drifted from the repo's Releases page.
3. Ask the user to click **Allow** on the Bluetooth prompt.
4. Confirm the connection (repeat for up to a minute):
   ```sh
   curl -s -H "Authorization: Bearer $(cat ~/Library/Application\ Support/Drifted/token)" localhost:8765/status
   ```
   `"connection": "ready"` means done.
5. This plugin's MCP server points at `/Applications/Drifted.app/Contents/MacOS/drifted-mcp`; the Drifted tools
   become available in the next session. Suggest **Start at login** in the Drifted menu-bar menu.
6. Test with a small circle (`show_pattern` with `xy` points of a 0.3-radius circle, or `POST /show`) and ask
   the user whether the table draws it.

Full details and other situations: AGENTS.md in the repo.
