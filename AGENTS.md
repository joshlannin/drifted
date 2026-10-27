# For AI assistants

This repo lets you control a HoMedics Drift sand table (a steel ball drawn through sand by a magnet). Work out
which situation you're in, then follow that section.

**First, check the table is supported.** Drifted works with the Bluetooth Drift tables: 16" (ST-300) and
21" (ST-400), which use the "HoMedics Drift" app. It does **not** work with the Wi-Fi models (11" ST-200,
ST-250, and probably the 10" premium wood), which use the "Homedics Drift (Wi-Fi)" app: they're controlled
through a cloud service and don't use this protocol. If you don't know which the user has, ask which app they
use or the table's size. If it's a Wi-Fi model, tell them it isn't supported and stop: don't install anything
or build a client.

If the user asked you to look at this project and walk them through it, start by saying in a few sentences
what Drifted does (draw on their Drift table by asking an AI assistant, or build their own app), check their
table is supported, and ask what they'd like to do. Then follow the matching section below, explaining each
step before you do it.

**Don't assume Drifted is installed.** Most users arrive with nothing installed. Unless you can see the
drifted tools, or the user confirms the Drifted icon is in their Mac's menu bar, installing it is the first
step: give them the download link (<https://github.com/joshlannin/drifted/releases/latest>) and walk them
through it before anything else.

| Your situation | Go to |
|---|---|
| You can run shell commands on the user's **Mac** (Claude Code, Codex, Cursor…) and they want to draw on their table | [A. Install on a Mac](#a-install-on-a-mac) |
| You're **Claude Desktop**, a **web chat** (claude.ai, ChatGPT) or another app without a shell | [B. Guide the user](#b-guide-the-user-no-shell) |
| The user is on **Windows, Linux or Android**, or wants their own client | [C. Build a client](#c-build-a-client) |
| The user wants to **build an app** (e.g. iOS) | [D. Build an app](#d-build-an-app) |
| The drifted tools are **already available** to you | [Drawing on the table](#drawing-on-the-table) |

## A. Install on a Mac

1. Check prerequisites: macOS 13+, `xcode-select -p` succeeds (install the Command Line Tools if not), and the
   table is powered on and near the Mac. Ask the user to close the HoMedics app on their phone: the table accepts
   one connection at a time.
2. Build and install the host:
   ```sh
   scripts/build-host-app.sh
   cp -R "build/Drifted.app" /Applications/
   open "/Applications/Drifted.app"
   ```
3. Tell the user to click **Allow** on the Bluetooth prompt. You can't do this step for them.
4. Wait for the host to connect. The API token is created at `~/Library/Application Support/Drifted/token`.
   ```sh
   curl -s -H "Authorization: Bearer $(cat ~/Library/Application\ Support/Drifted/token)" localhost:8765/status
   ```
   `"connection": "ready"` means it's connected. If it never connects, check the HoMedics app is closed and the
   table is on; the Drifted menu says the same after a minute. With more than one table nearby, Drifted picks the
   strongest signal; the user can switch with **Drifted → Choose table…**.
5. With the user's OK, register the MCP server with the client you're running in:
   - Claude Code: `claude mcp add --scope user drifted -- "/Applications/Drifted.app/Contents/MacOS/drifted-mcp"`
   - Codex: add `[mcp_servers.drifted]` with `command = "/Applications/Drifted.app/Contents/MacOS/drifted-mcp"`
     to `~/.codex/config.toml`
   - Or ask the user to choose **Drifted → Connect your AI…** in the menu bar and paste the prompt it shows.
6. Suggest the user turn on **Start at login** in the Drifted menu.
7. Test: draw something small (a circle of radius 0.3) with `show_pattern`, or, if MCP isn't loaded in this
   session yet, with `POST /show` (see `spec/openapi.yaml`). Ask the user whether they see it.

For a headless always-on Mac, `scripts/install-launchagent.sh` installs `drifted-host` as a login agent instead of
the menu-bar app.

## B. Guide the user (no shell)

You can't install software yourself. Walk the user through every step, starting with the download, and
check each one worked before moving on. Drifted needs a Mac (macOS 13 or later) within Bluetooth range of the
table.

1. **Install Drifted.** Download the `.dmg` from <https://github.com/joshlannin/drifted/releases/latest>,
   open it and drag **Drifted** to Applications. It's signed and notarized, so it opens normally.
2. Open it and click **Allow** on the Bluetooth prompt. A Drifted icon appears in the menu bar and shows
   "Connected" once it finds the table. Close the HoMedics phone app first if it doesn't.
3. Ask them to choose **Drifted → Connect your AI…** in the menu bar, copy the prompt and paste it here. Then walk
   them through adding the server: in Claude Desktop, **Settings → Developer → Edit Config** opens
   `claude_desktop_config.json`; add the `drifted` entry under `mcpServers`, save, then quit and reopen Claude Desktop.
4. In a new conversation the Drifted tools are available; continue at [Drawing on the table](#drawing-on-the-table).

If you're a chat in a web browser (such as claude.ai), you can guide steps 1–2, but you can't reach the table
yourself: the browser can't run local tools. For step 3, have the user install a desktop AI app that supports
MCP (Claude Desktop is the simplest), and continue there.

## C. Build a client

There's no packaged host for non-Mac systems. Either:

- point the user's tools at a Mac running Drifted over the network (HTTP API in `spec/openapi.yaml`;
  the user gets the address and token from **Drifted → Connect your AI… → AI on another computer**), or
- build a client in the user's language from [docs/building-clients.md](docs/building-clients.md),
  [docs/protocol.md](docs/protocol.md) and [docs/failure-modes.md](docs/failure-modes.md). Check framing against
  the test data in `spec/vectors/` before touching the table, then follow the on-table test order in
  building-clients.md.

## D. Build an app

- Apple platforms: use the `DriftedKit` library from this Swift package (`DriftTable` for the connection,
  `PatternValidator`, `PatternPreview`, `LiveSession`).
- Anything else: as in C.
- Read [docs/behaviour.md](docs/behaviour.md) for timings before designing interactions.

## Drawing on the table

Tools (via MCP): `get_status`, `preview_pattern`, `animate_pattern`, `validate_pattern`, `show_pattern`,
`settings`, `playback`, `live_start` / `live_push` / `live_stop`, and others. Read
[docs/drawing-guide.md](docs/drawing-guide.md) first.

**There's a digital twin of the table** ([docs/digital-twin.md](docs/digital-twin.md)). `preview_pattern`
shows the sand as it will look afterwards (grooves as wide as the ball, so you can see what merges) and the
route; `animate_pattern` saves a GIF of the ball drawing it; `validate_pattern` checks it and estimates the
time. None of these move the ball, and they work while the table is busy. Iterate on the twin until the
drawing reads well, then send it. Without MCP: `drifted preview FILE out.png|out.gif` renders offline.

- The ball never lifts: **everything you send is drawn**, including moves between shapes. Plan stroke order.
- Coordinates: `xy` in table radii (unit disc, +x right, +y up), or `points` as `[theta, rho]`.
- **Always preview before showing**, and look at both images. Offer the user an animation for long drawings.
- Use `clear: "area"` for text and small drawings so they're readable. A full clear takes about 10 minutes.
- Drawing takes time: about 8 s per table radius of path. Tell the user roughly how long to expect.
- Settings: `color` takes `#rrggbb`; brightness and speed take 0–1.

## Rules

- Never send firmware-update commands (`0x15`) or the reserved reset (`0x14/12`).
- Don't delete patterns the user didn't create.
- Never add HoMedics software, firmware, code derived from them, or stock patterns to this repo or a user's project.
- Only make portraits from photos the user has the right to use, of people who agreed (see [LEGAL.md](LEGAL.md)).
- If the user wants to use the HoMedics app, release the table with the `connection` tool (`disconnect`).
