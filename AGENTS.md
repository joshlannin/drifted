# For AI assistants

This repo lets people control a HoMedics Drift sand table (a steel ball drawn through sand by a magnet) from
an AI assistant, their own scripts, or an app they build. This page tells you how it all fits together, how to
find out where a user stands, and the facts you'll need. It isn't a script: work out what this person wants
and the shortest sensible path to it, and use your judgement.

## What good help looks like

- **Find out what they want.** Usually that's drawing on their table by asking an AI. It might be building
  their own app or client, or just understanding the project. Let that decide what you do.
- **Do what you can yourself, and check instead of asking.** If you can run commands or operate the screen,
  do the steps, then look at the result (is the file there, is the app running, does `/status` say ready?).
  Ask the user only for what you can't do or find out: clicking a macOS permission prompt, physical things
  like switching the table on, and choices that are theirs to make.
- **Keep them oriented.** Say briefly what you're doing and why, what they'll see, and roughly how long it
  takes. When they have to act, be concrete: what to click, where it is, what happens next.
- **Don't assume anything is set up.** Most people start with nothing installed. Find out where things stand
  (below), then close the gap.
- **Get to a first drawing quickly.** That's the point at which it makes sense to people.

## How it fits together

```
AI app (MCP) ─┐
scripts (HTTP)─┼─▶ Drifted (menu-bar app on a Mac) ──Bluetooth──▶ Drift table
other computer┘     local API :8765, token auth
```

- **The table** must be a Bluetooth Drift: 16" (ST-300) or 21" (ST-400), used with the "HoMedics Drift" app.
  The Wi-Fi models (11" ST-200, ST-250, and probably the 10" premium wood) use the "Homedics Drift (Wi-Fi)" app
  and a cloud service; nothing here works with them. If you don't know which they have, ask which app they
  use or the table's size. If it's a Wi-Fi model, tell them, and don't install anything or build a client.
- **Drifted** is a Mac app (macOS 13 or later) that lives in the menu bar. It holds the Bluetooth connection,
  so the Mac has to be within Bluetooth range of the table. The table accepts one connection at a time, so the
  HoMedics phone app has to be closed (or disconnected) while Drifted is connected.
- **AI apps** connect to Drifted through its MCP server, `drifted-mcp`, inside the app bundle. They have to
  run on a computer that can launch local tools: Claude Desktop, Claude Code, Codex, Cursor and similar.
  **A chat in a web browser (claude.ai, ChatGPT on the web) can't reach Drifted at all.** It can help someone
  install Drifted and set up a desktop AI app, but it can never draw on the table itself.
- **Scripts and other computers** use the HTTP API ([spec/openapi.yaml](spec/openapi.yaml)) with a bearer
  token, from the same Mac or over the local network.

## Finding out where things stand

| Question | How to tell |
|---|---|
| Is the table supported? | Which phone app they use, or the table's size (above) |
| Is Drifted installed? | `/Applications/Drifted.app` exists |
| Is it running and connected? | A Drifted icon in the menu bar; its menu shows the connection state. Or `GET localhost:8765/status` with the token (below): `"connection": "ready"` means connected |
| Is your AI connected to it? | You can see the drifted tools (`get_status`, `show_pattern`…) |
| If it won't connect | The menu shows a hint after about a minute. Usual causes: the HoMedics app is still connected, the table is off or out of range, or Bluetooth permission wasn't allowed |

```sh
curl -s -H "Authorization: Bearer $(cat ~/Library/Application\ Support/Drifted/token)" localhost:8765/status
```

## Reference: setting things up

**Installing Drifted**
- Download: <https://github.com/joshlannin/drifted/releases/latest/download/Drifted.dmg> downloads the
  latest release directly (under 1 MB). It lands in the Downloads folder as `Drifted.dmg` (or
  `Drifted-<version>.dmg` if downloaded from the
  [release page](https://github.com/joshlannin/drifted/releases/latest)). From a shell: `curl -L -o`.
- Opening the `.dmg` shows Drifted and an Applications folder; drag Drifted onto Applications (or
  `cp -R` it), then eject the disk. It's signed and notarized, so it opens normally. macOS may ask to confirm
  opening an app from the internet.
- From source, with the Xcode Command Line Tools (`xcode-select -p`):
  `scripts/build-host-app.sh && cp -R build/Drifted.app /Applications/`.
- On first launch macOS asks for **Bluetooth** permission. Only the user can click **Allow**; tell them it's
  coming. Drifted then finds the nearest table and remembers it. **Drifted → Choose table…** switches tables.
- **Drifted → Start at login** keeps it running. For a headless, always-on Mac,
  `scripts/install-launchagent.sh` runs `drifted-host` (the same host, without the menu bar) as a login agent.

**Connecting an AI app.** The MCP server is `/Applications/Drifted.app/Contents/MacOS/drifted-mcp`
(stdio, no arguments). Changing another app's settings needs the user's OK.
- Claude Code: `claude mcp add --scope user drifted -- "/Applications/Drifted.app/Contents/MacOS/drifted-mcp"`
- Codex: `[mcp_servers.drifted]` with `command = "/Applications/Drifted.app/Contents/MacOS/drifted-mcp"` in
  `~/.codex/config.toml`
- Claude Desktop: **Settings → Developer → Edit Config** opens `claude_desktop_config.json`. Add
  `"drifted": {"command": "/Applications/Drifted.app/Contents/MacOS/drifted-mcp"}` under `mcpServers`, then
  quit and reopen Claude Desktop. The tools appear in new conversations.
- Anything else, or an AI on another computer: **Drifted → Connect your AI…** shows the exact details to
  paste, including the network address and token for another computer.
- A first test that works anywhere: draw a circle of radius 0.3 with `show_pattern` (or `POST /show`) and ask
  the user whether they see it.

**Building something else**
- Apple platforms: the `DriftedKit` library in this Swift package (`DriftTable` for the connection,
  `PatternValidator`, `PatternPreview`, `LiveSession`, and the digital twin).
- Windows, Linux, Android, a Raspberry Pi: either use the HTTP API of a Mac running Drifted, or build a client
  from [docs/building-clients.md](docs/building-clients.md), [docs/protocol.md](docs/protocol.md) and
  [docs/failure-modes.md](docs/failure-modes.md). Check framing against `spec/vectors/` before touching the
  table, then follow the on-table test order in building-clients.md.
- [docs/behaviour.md](docs/behaviour.md) has the timings to design interactions around.

## Drawing on the table

Tools (via MCP): `get_status`, `preview_pattern`, `animate_pattern`, `validate_pattern`, `show_pattern`,
`settings`, `playback`, `live_start` / `live_push` / `live_stop`, `connection`, and others
([spec/mcp-tools.json](spec/mcp-tools.json)). Read [docs/drawing-guide.md](docs/drawing-guide.md) first.

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
- Portraits from photos: see [docs/portraits.md](docs/portraits.md).

## Rules

These are firm, whatever the situation:

- Never send firmware-update commands (`0x15`) or the reserved reset (`0x14/12`).
- Don't delete patterns the user didn't create.
- Never add HoMedics software, firmware, code derived from them, or stock patterns to this repo or a user's project.
- Only make portraits from photos the user has the right to use, of people who agreed (see [LEGAL.md](LEGAL.md)).
- If the user wants to use the HoMedics app, release the table with the `connection` tool (`disconnect`).
