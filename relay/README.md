# Drifted relay

A small Wi-Fi board that sits next to the table and holds its Bluetooth link, so Drifted can run a table that's
out of the Mac's Bluetooth range. Drifted talks to the relay over your network; the relay passes the table's
bytes both ways. Everything Drifted does (handshake, uploads, retries, playlists) works the same as over its own
Bluetooth.

```
Drifted (Mac, anywhere on the LAN) ──TCP :8766, token──▶ relay (next to the table) ──Bluetooth──▶ Drift table
```

Firmware, scripts and protocol here are original work, MIT-licensed like the rest of the repo.

## What to buy

- **M5Stack NanoC6** (ESP32-C6, about US$8). The firmware is built for it: its RGB LED (GPIO 20, power on
  GPIO 19) and button (GPIO 9). Another ESP32-C6 board works if you change the pins in
  `firmware/main/relay.h`.
- A USB-C **data** cable for flashing (some only charge), and any USB charger to power it by the table.
- Your Wi-Fi must offer **2.4 GHz** (the ESP32-C6 has no 5 GHz).

## 1. Flash the firmware

Install PlatformIO once (in your user account; no admin needed):

```sh
python3 -m venv ~/.local/pio-venv && ~/.local/pio-venv/bin/pip install platformio
```

Plug the NanoC6 into the Mac, then from the repo:

```sh
cd relay/firmware
~/.local/pio-venv/bin/pio run -t upload      # builds (first time: downloads ESP-IDF, a few minutes) and flashes
~/.local/pio-venv/bin/pio device monitor     # optional: watch its log (Ctrl-C to quit)
```

If the upload can't find or sync with the board, hold its button while plugging it in (download mode), run the
upload again, then unplug and replug it. After flashing, the LED blinks **purple**: it needs setting up.

## 2. Wi-Fi and token

With the relay still plugged into the Mac:

```sh
~/.local/pio-venv/bin/python relay/setup.py
```

It asks for the Wi-Fi name and password, makes a random token, saves them on the relay (nowhere else), restarts
it and waits until it's on Wi-Fi. It prints the relay's name and address, the token, and the command for step 3.
`--show` prints the relay's settings (secrets masked); `--wifi-scan` lists the networks it can see.

Then unplug it, put it within a metre or two of the table on a USB charger, and switch the table on. The LED
goes **amber** while it looks for the table, then **blue** once linked. The first time, it takes the strongest
Drift it can see and remembers it.

## 3. Point Drifted at it

On the Mac that runs Drifted (here, the Mac Mini), with the token from step 2:

```sh
curl -X PUT -H "Authorization: Bearer $(cat ~/Library/Application\ Support/Drifted/token)" \
  localhost:8765/relay -d '{"enabled": true, "name": "drifted-relay-1a2b3c", "token": "…"}'
```

- `name` finds the relay by Bonjour, so a changed IP address doesn't matter. `host` (an IP address) works too,
  and without either Drifted uses the first relay it finds. `GET /relay/discover` lists relays on the network.
- It's saved in Drifted's state folder as `relay.json` (readable only by you) and takes effect at once.
  `{"enabled": false}` goes back to the Mac's own Bluetooth.
- AI assistants can do the same with the `relay` MCP tool.
- On macOS 15 or later, Drifted asks once for permission to find devices on the local network. Allow it.

Check it: `GET /status` shows `"connection": "ready"` and
`"link": {"via": "relay", "rssi": -58, "wifiRssi": -50, …}`. `rssi` is the relay's signal to the table: −40 to −70
is solid; below about −85 the link drops now and then. The relay's LED is **green** while Drifted is connected.
Drifted's menu shows "Connected to … through the relay" and the relay's signal.

## LED and button

| LED | Meaning |
|---|---|
| purple, blinking | needs setup (no Wi-Fi network or token): run `setup.py` |
| red, blinking | can't join Wi-Fi (wrong password, 5 GHz-only network, out of range) |
| amber, blinking | on Wi-Fi; looking for the table or connecting to it |
| cyan | released: the HoMedics phone app can connect now |
| blue | linked to the table; no Drifted connected |
| green, blinking | Drifted connected; waiting for the table to start a session (a few seconds) |
| green | Drifted connected and talking to the table |
| white, flashing | firmware update, or the button held for 3 s |

**Button:** a short press releases the table so the HoMedics app can connect (cyan); press again to take it
back. Hold it for 3 s to forget the table and take the strongest one in range.

## How it behaves

- **One host at a time.** A new connection must send the token within 5 s; only then does it replace the
  current host. Wrong tokens are refused (and slowed down).
- **It keeps the session alive only for a connected host.** The table drops its session after about 2 s without
  hearing from a host, and Wi-Fi on a busy 2.4 GHz band (shared with the relay's own Bluetooth) can hold
  packets back for that long. So while a host is connected and the gate is open, if the host has written nothing
  for 1 s the relay sends the table a ConfirmData (`7B 04 D0 4F`), the same reply a host sends to every message,
  and counts it in `stats.keepalives`. With no host connected it sends nothing: the table carries on as it does
  with no app connected (it keeps drawing), and the relay just stays linked so Drifted is back within seconds.
- **The handshake gate.** When Drifted connects, the relay holds its writes back until the table next asks for a
  handshake (0x50/1). The table asks again after each session reset, so Drifted always starts with a full
  handshake and init dump, as over its own Bluetooth. If the table hasn't asked within 8 s, the relay reconnects
  Bluetooth, which always starts a fresh session.
- **Page pacing.** Wi-Fi can deliver several pattern pages at once, and pages sent back to back make the table
  drop its session (docs/failure-modes.md). The relay keeps pages (0x53) at least 80 ms apart.
- **Connection interval.** The relay asks for 30–50 ms and refuses anything faster than 30 ms if the table asks
  (it logs both), so Bluetooth leaves Wi-Fi room on the shared radio. The ST-400 settles at 50 ms.
- **Finding the table.** The table names itself (`KS…`) only in its scan response and advertises no service
  UUIDs. The relay keeps a candidate slot only for adverts that look like a Drift (a `KS` name or service
  `FFE0`), so a room full of other Bluetooth devices can't crowd it out, and reads advert data leniently.
- Everything else passes through untouched, in order. Apart from those keepalives the relay originates
  nothing. (It doesn't filter
  either: the firmware-update and reset commands are as off-limits through it as anywhere.)
- **Releasing the table.** The table takes one Bluetooth connection, so while the relay holds it the phone app
  can't connect. Drifted's **Disconnect** (or `POST /disconnect`, or the MCP `connection` tool) tells the relay to
  let go; **Connect** takes it back. So does the button. `hold off` (serial or `/relay/command`) makes the relay
  let go by itself 30 s after the last host leaves.
- **Choosing a table.** Drifted's **Choose table…** lists the tables the relay can see. Or `POST /relay/command`
  with `select aa:bb:cc:dd:ee:ff` or `select KS2106100812`; `forget` goes back to the strongest.
- The relay's log lines appear in Drifted's log (`GET /log`) prefixed `relay:`.

## Updating the firmware over the network

Build (`pio run` in `relay/firmware`), then send it through Drifted:

```sh
python3 relay/ota.py --drifted http://mac-mini.local:8765 --drifted-token "<Drifted's API token>"
```

or straight to the relay with `--relay <address> --token <relay token>`. The relay downloads the image from this
computer, writes it to its spare slot (4 MB flash: two 1.9 MB app slots) and restarts into it, in under a minute.
If the new firmware doesn't get back on Wi-Fi within 5 minutes, it restarts into the previous one.

## Serial commands

Over USB (`pio device monitor --echo`, 115200 baud); each answers `ok …` or `error: …`.

| Command | |
|---|---|
| `show`, `status`, `version` | settings (secrets masked), status JSON, firmware |
| `set ssid NAME`, `set password PW`, `set token T` | settings (`sethex KEY HEX` for exact bytes); reboot to apply Wi-Fi |
| `wifi-scan` | 2.4 GHz networks it can see, with signal |
| `scan`, `select ADDRESS\|NAME`, `forget` | tables in range; which one to use |
| `release`, `connect` | let go of the table / take it back |
| `hold on\|off` | stay linked with no host connected (default on) |
| `ota URL`, `reboot`, `erase` | update from an http(s) URL; restart; erase all settings |

`scan`, `select`, `forget`, `hold`, `status`, `reboot` and `ota` also work from Drifted (`POST /relay/command`).
Wi-Fi and token settings work only over USB.

## Troubleshooting

| Symptom | Check |
|---|---|
| purple after setup | `setup.py --show`: the token must be 16+ characters and the SSID set |
| red | `setup.py --wifi-scan`: is the network listed (2.4 GHz)? Re-run `setup.py` with the right password |
| amber for a long time | Table on? HoMedics app closed on every phone? `pio device monitor` shows `found KS… at -60 dBm`, or `no Drift table found` |
| blue, but Drifted says it can't reach the relay | Same network? `GET /relay` shows the error. Try `host` with the IP address instead of `name`; allow Drifted's local network permission (System Settings → Privacy & Security → Local Network) |
| `wrong token` in Drifted's log | The token in `relay.json` differs from the relay's: re-run `setup.py --token <the one in Drifted>` or PUT the right one |
| link drops now and then | `GET /status` `link.rssi` below −85: move the relay closer to the table. `wifiRssi` below −80: closer to the router |
| Drifted keeps going back to "handshaking" | `GET /relay` `stats.handshakeRequests` climbing means the table is resetting its session: Wi-Fi stalls longer than the keepalive covers. `keepalives` counts the stalls it did cover. Move the relay or router, or move the router off a crowded 2.4 GHz channel |
| uploads fail with "upload failed" | `GET /relay` `status.stats.maxPageGapMs` (the table gives up after 5 s) and `pagesPaced`. Wi-Fi trouble shows up as long gaps |

## Relay protocol

For anyone writing their own host. TCP, port 8766, advertised by Bonjour as `_drifted-relay._tcp` (TXT
`firmware`, `proto`). Every message, both ways:

```
type:u8  length:u16 little-endian  payload[length]        (payload ≤ 4096 bytes)
```

| type | direction | payload |
|---|---|---|
| `0x01` HELLO | host → relay | `flags:u8` + token (UTF-8). Must be first, within 5 s. Flag bit 0 *observe*: don't undo a release |
| `0x02` WELCOME | relay → host | JSON `{"proto":1,"firmware":"0.1.0","name":"drifted-relay-1a2b3c"}` |
| `0x03` ERROR | relay → host | JSON `{"error":"wrong token"}`; the relay then closes the connection |
| `0x10` TABLE_DATA | relay → host | bytes from the table's notifications (FFE4), in order, in arbitrary pieces: reassemble packets by `7B len` |
| `0x11` TABLE_WRITE | host → relay | one table packet (≤ 255 bytes), written to FFE9 |
| `0x20` STATUS | relay → host | JSON, on every change and every 5 s (below) |
| `0x21` SCAN | relay → host | JSON `{"tables":[{"name","address","addrType","rssi"}]}` after `scan` |
| `0x30` COMMAND | host → relay | a command line (table above) |
| `0x31` RESULT | relay → host | JSON `{"command","ok","message"}` (`scan` adds `tables`; `ota` answers again when done) |
| `0x40` LOG | relay → host | one log line (UTF-8) |

Unknown types are ignored both ways. STATUS:

```json
{"link":"linked","released":false,"hold":true,
 "table":{"name":"KS2106100812","address":"aa:bb:cc:dd:ee:ff","addrType":0},
 "rssi":-58,"mtu":247,"maxWrite":244,"gate":"open","host":true,"wifiRssi":-50,"ip":"192.168.1.40",
 "name":"drifted-relay-1a2b3c","uptime":3600,"firmware":"0.1.0","heap":180000,"ota":false,
 "stats":{"notifyBytes":0,"writes":0,"droppedBeforeHandshake":0,"droppedFull":0,"pagesPaced":0,
          "handshakeRequests":0,"maxPageGapMs":0,"keepalives":0}}
```

`link` is `off` (Bluetooth starting), `released`, `idle` (hold off, no host), `waiting` (backing off before the
next try), `scanning`, `connecting` or `linked` (connected with notifications on: the same point as
CoreBluetooth's "subscribed"). A host treats `linked` as "waiting for the table's handshake" and anything else
as "table not connected". A STATUS saying `linked` always arrives before that link's first TABLE_DATA. `gate` is
`open` once the table has asked this host for a handshake; writes before that are dropped.

## Testing without hardware

`relay/tools/fake_relay.py` speaks this protocol with a simulated table behind it (handshake, init dump, state
broadcasts, the 2 s session reset, uploads, plays), and `relay/tools/test-fake-relay.sh` runs drifted-host
against it end to end: handshake, staying ready, drawing, a lost table link, a dropped TCP connection,
release/connect, both kinds of update, and a table that never re-asks for a handshake. It uses its own state
folder and ports, so a running Drifted is untouched.

## Security

The relay accepts only connections that present its token, but the connection isn't encrypted: anyone who can
watch your local network traffic could read the token. Keep the relay on a network you trust. The token can
be changed any time with `setup.py --token …` (then PUT the new one to Drifted).
