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

Check it: `GET /status` shows `"connection": "ready"` (or `"standby"` when [linking on demand](#linking-on-demand)) and
`"link": {"via": "relay", "rssi": -58, "wifiRssi": -50, …}`. `rssi` is the relay's signal to the table: −40 to −70
is solid; below about −85 the link drops now and then. The relay's LED is **green** while Drifted is connected.
Drifted's menu shows "Connected to … through the relay" and the relay's signal.

## LED and button

| LED | Meaning |
|---|---|
| purple, blinking | needs setup (no Wi-Fi network or token): run `setup.py` |
| red, blinking | can't join Wi-Fi (wrong password, 5 GHz-only network, out of range) |
| amber, blinking | on Wi-Fi; looking for the table or connecting to it |
| blue, blinking | a job: the relay is doing table work by itself ([Jobs](#jobs-the-relay-works-alone)) |
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

## Linking on demand

The relay has one 2.4 GHz radio for Wi-Fi and Bluetooth. While it holds the table's Bluetooth link, its Wi-Fi
can stall for a second or two every few seconds. On one setup, pinging the relay five times a second for a
minute, 17% of pings took over a second with the table linked and none did with it released; the connection to
Drifted dropped hundreds of times a night. If `GET /link` shows many lost connections, turn this on:

```sh
curl -X PUT -H "Authorization: Bearer $(cat ~/Library/Application\ Support/Drifted/token)" \
  localhost:8765/relay -d '{"link": "onDemand"}'
```

Drifted then keeps its connection to the relay but has it let go of the table (`"connection": "standby"`), and
takes the table only while there is something to do:

- a job: a drawing, a setting, a power or lamp switch, the schedule's weather and playlist steps;
- a live session, for as long as it runs;
- a check-in every `checkInMinutes` (default 30): a few seconds linked, for fresh status and to notice alarms.

After a job it keeps the table for `lingerSeconds` (default 60) in case more follows. The table needs no host to
keep drawing or to run its own playlist (`PUT /playlist {"onTable": true}`); with drifted-host's own playlist
(`onTable` false) the table stays linked, because drifted-host has to see each pattern end.

What changes for you:

- Something sent while standing by first waits for the relay to reach the table, usually some seconds.
- `/status` describes the table as of the last time it was linked; `stateAt` says when that was.
- The HoMedics app can connect while the relay stands by. Drifted can't take the table while the app has it,
  so use **Disconnect** first if you want the app for more than a moment.

`{"link": "always"}` goes back to holding the table all the time.

### Jobs: the relay works alone

Standing by keeps the relay reachable between pieces of work, but taking the table over the network still
needs Wi-Fi to work all through the handshake, and that is when the relay's Wi-Fi is at its worst. On the setup
above, in the daytime, most attempts failed.

So with relay firmware 0.2 or later (and link on demand), Drifted doesn't drive the table over the network at
all. It hands the relay a **job** while the table is released and Wi-Fi is clean: a short list of steps and,
for a drawing, the pattern itself. The relay then links to the table, answers its handshake and start-up
lists, uploads, plays and checks that the pattern started, lets go, and keeps the outcome until Drifted
collects it. Nothing in between needs the network: if the connection to Drifted drops meanwhile, the job
carries on and Drifted asks for the result when it's back.

- Every drawing, setting, switch, schedule step, table-playlist write and check-in goes this way. `/status`
  `link.jobs` is true when it does, and the log has lines starting `link: handing … to the relay`.
- The relay keeps a pattern in its spare firmware slot (flash), so size isn't a concern: any pattern Drifted
  accepts fits.
- The relay repeats what a host would: lost pages are sent again, a refused slot gets the next one, a play that
  the table ignores is sent again, and a lost Bluetooth link or a session the table restarts means a new
  handshake and the step again. If it can't reach the table at all, Drifted queues the job again (three tries).
- The relay never sends firmware-update commands (`0x15`) or the reserved reset (`0x14/12`): it refuses a job
  that contains one.
- Two things still take a live link, because the host has to answer the table as it goes: a live session, and
  drifted-host's own playlist (`onTable` false).
- `PUT /relay {"jobs": false}` goes back to driving the table over the network (to compare the two).

A relay with older firmware works as before; update it over the network (below) to get jobs.

### Is it working?

`GET /link` (or the `relay` MCP tool with `action: "telemetry"`) keeps count, day by day, in every mode:

- `reachablePercent`: how much of the day the table was linked or the relay was standing by, ready to take it;
- `relayJobs`: jobs the relay did by itself: how many, how many failed and where (`link`: no Bluetooth
  connection; `handshake`; `step`; `relay`: the relay couldn't be reached or refused), how long until it had
  the Bluetooth link and until the table was ready, and how often it had to link again or restart a step;
- `wakes`: how often Drifted took the table over the network, how long that took, and how many failed;
- `drops`: connections lost, by cause, and how many were while linked or during a job;
- `jobs` and `uploads`: failures, retries and pages the table asked for again;
- `relay`: its Wi-Fi and table signal, and restarts; with firmware 0.2 also how often it lost its Wi-Fi
  association (`wifiLost`, by 802.11 reason code) and gave up sending to Drifted (`sendsGivenUp`).

`?days=30` gives more days (120 are kept, in `link-telemetry.json` in the state folder) and `recent` lists the
latest events. Each midnight the day goes to Drifted's log as one line starting `link:`.

## Updating the firmware over the network

Build (`pio run` in `relay/firmware`), then send it through Drifted:

```sh
python3 relay/ota.py --drifted http://mac-mini.local:8765 --drifted-token "<Drifted's API token>"
```

or straight to the relay with `--relay <address> --token <relay token>`. The relay downloads the image from this
computer, writes it to its spare slot (4 MB flash: two 1.9 MB app slots) and restarts into it, in under a minute.
If the new firmware doesn't get back on Wi-Fi within 5 minutes, it restarts into the previous one.

Update while the table is released (standing by, or after **Disconnect**): the download needs the relay's
Wi-Fi, which is poor while it holds the table. `ota.py` waits for as long as the download keeps moving; from
firmware 0.1 over a weak signal that can be several minutes. The spare slot is also where a [job](#jobs-the-relay-works-alone)
keeps its pattern, so the relay refuses an update while a job runs, and after an update the first job with a
pattern waits until the new firmware has been confirmed (about 20 s).

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
| the relay's network connection is slow (an update takes many minutes) or keeps stalling, though small pings get through | A weak Wi-Fi signal loses long packets first (measured at −70 dBm: none of 400 bytes, a quarter of 1400). Firmware 0.2.1 keeps its TCP packets small, which made the same link about 15 times faster; update to it (`ping -s 1400 <relay>` against `ping -s 56 <relay>` shows whether a link has the problem) |
| Drifted loses the relay again and again ("the relay went quiet", "the relay closed the connection") | The relay's Wi-Fi stalls while it holds the table. `GET /link` counts the drops. [Link on demand](#linking-on-demand) keeps the table released between pieces of work, and with firmware 0.2 the relay does the work [by itself](#jobs-the-relay-works-alone), so a drop no longer costs anything. A stronger Wi-Fi signal at the relay still helps |
| a job fails with "couldn't connect to the table over Bluetooth" | The table is off, out of the relay's range, or the HoMedics app has it. `GET /link` `relayJobs.failedAt.link` counts these |
| the relay links, but the table never asks for a handshake ("no handshake request from the table for 8 s", over and over) | The table can get stuck part-way through its start-up lists when a handshake is cut short: it keeps repeating one message (seen: `7B 06 36 01 01 B9`) and waits for an answer. Firmware 0.2 answers it (log: "the table is half-way through an old handshake"; `stats.unstuck` counts), and a job answers everything itself. With firmware 0.1: connect once over a Mac's own Bluetooth (Drifted with `{"enabled": false}`, in range of the table, relay released), or switch the table off and on |
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
| `0x02` WELCOME | relay → host | JSON `{"proto":2,"firmware":"0.2.1","name":"drifted-relay-1a2b3c"}`. `proto` 2 and up: jobs (below) |
| `0x03` ERROR | relay → host | JSON `{"error":"wrong token"}`; the relay then closes the connection |
| `0x10` TABLE_DATA | relay → host | bytes from the table's notifications (FFE4), in order, in arbitrary pieces: reassemble packets by `7B len` |
| `0x11` TABLE_WRITE | host → relay | one table packet (≤ 255 bytes), written to FFE9 |
| `0x20` STATUS | relay → host | JSON, on every change and every 5 s (below) |
| `0x21` SCAN | relay → host | JSON `{"tables":[{"name","address","addrType","rssi"}]}` after `scan` |
| `0x30` COMMAND | host → relay | a command line (table above) |
| `0x31` RESULT | relay → host | JSON `{"command","ok","message"}` (`scan` adds `tables`; `ota` answers again when done) |
| `0x40` LOG | relay → host | one log line (UTF-8) |
| `0x50` JOB_BEGIN | host → relay | a job's header and steps (below) |
| `0x51` JOB_DATA | host → relay | `job:u32, offset:u32`, then pattern points; offsets rising with no gaps |
| `0x52` JOB_RUN | host → relay | `job:u32`: everything has been sent; run it |
| `0x53` JOB_QUERY | host → relay | empty: where is the job? Answered with JOB_STATE, and the result again if it has finished |
| `0x58` JOB_STATE | relay → host | JSON `{"job","state","op","ops","progress","got"}`; `state` is `receiving`, `queued`, `linking`, `handshake`, `running`, `done`, or `refused` with `error`; `got` is how many bytes of pattern data have arrived |
| `0x59` JOB_RESULT | relay → host | JSON, when the job ends (below) |
| `0x5A` JOB_TABLE_DATA | relay → host | `job:u32`, then bytes the table sent during the job; sent just before the result |

Unknown types are ignored both ways. STATUS:

```json
{"link":"linked","released":false,"hold":true,
 "table":{"name":"KS2106100812","address":"aa:bb:cc:dd:ee:ff","addrType":0},
 "rssi":-58,"mtu":247,"maxWrite":244,"gate":"open","host":true,"wifiRssi":-50,"ip":"192.168.1.40",
 "name":"drifted-relay-1a2b3c","uptime":3600,"firmware":"0.2.1","proto":2,"heap":180000,"ota":false,
 "stats":{"notifyBytes":0,"writes":0,"droppedBeforeHandshake":0,"droppedFull":0,"pagesPaced":0,
          "handshakeRequests":0,"maxPageGapMs":0,"keepalives":0,"unstuck":0,"wifiDrops":0,
          "wifiLastReason":0,"hostSessions":1,"sendFails":0},
 "job":{"id":1234,"state":"running","op":1,"ops":3,"progress":40}}
```

`link` is `off` (Bluetooth starting), `released`, `idle` (hold off, no host), `waiting` (backing off before the
next try), `scanning`, `connecting` or `linked` (connected with notifications on: the same point as
CoreBluetooth's "subscribed"). A host treats `linked` as "waiting for the table's handshake" and anything else
as "table not connected". A STATUS saying `linked` always arrives before that link's first TABLE_DATA. `gate` is
`open` once the table has asked this host for a handshake; writes before that are dropped. `job` is the
relay's current or last job, if there has been one; while it is `queued`, `linking`, `handshake` or `running`
the table link is the job's: `release` waits until it's done, TABLE_WRITE is dropped and no TABLE_DATA is sent.

### Jobs

A job is a list of steps the relay runs against the table by itself ([why](#jobs-the-relay-works-alone)).
Send JOB_BEGIN and wait for JOB_STATE `receiving`; send the pattern points (if any) in JOB_DATA messages of up
to 4000 bytes, then JOB_RUN, and wait for `queued`. A JOB_STATE `refused` gives the reason: send the job again.
If the connection drops part-way, reconnect and send JOB_QUERY: while the state is `receiving`, `got` says how
many bytes of points the relay has, and the rest can follow from there. The relay then links to the table, and
when the job ends sends what the table said (JOB_TABLE_DATA) and the JOB_RESULT. Expect to lose the connection
while it works; reconnect (observing) and send JOB_QUERY. The relay keeps the result until the next JOB_BEGIN,
and runs one job at a time (`busy with another job` otherwise).

JOB_BEGIN, little-endian:

```
job:u32            your id for it
localTime:u32      seconds since 1970, in local time: the relay has no clock, and the table asks for the time
lingerMs:u16       how long to keep listening after the last step (a play just sent shows in the state)
dataLength:u32     bytes of pattern points to follow in JOB_DATA
dataCrc32:u32      CRC-32 (zlib) of them
steps:u8           at most 32, their bodies at most 2048 bytes together
steps × { kind:u8, onFail:u8, length:u16, body }
```

`onFail` is `0xFF` (the job fails) or the index of the step to carry on from.

| kind | body | what it does |
|---|---|---|
| 1 send | one table packet | writes it. Refused for `0x15` and `0x14/12` |
| 2 expect | `timeoutMs:u16`, then `1, cmd:u8, action:u8 (0xFF any), n:u8, n bytes` or `2, patternId:u16` | waits for a packet with that command whose data contains the bytes, or for the running state to show the pattern drawing. Straight after a send, it listens from the moment of the send |
| 3 play | `patternId:u16` (0: the id the last upload went into) | un-pauses if needed, sends play, and repeats it (up to 4 times, 4 s apart) until the state shows the pattern drawing |
| 4 upload | `points:u32, offset:u32, n:u8, n × patternId:u16`, then optionally `pageGapMs:u8, resendGapMs:u8` | uploads `points` points (4 bytes each: `t:u16, r:u16`, as in a page) from `offset` in the data, with the retries in [docs/protocol.md](../docs/protocol.md#uploading); if the table refuses an id at Start, the next id is tried. Pages go 100 ms apart (200 ms when sent again) unless the gaps are given |
| 5 wait | `ms:u16` | |
| 6 end | | stops here, successfully |

During the whole job the relay answers the table as a host must (docs/protocol.md, Session): the handshake,
ConfirmData for every message, the time when asked, and a keepalive after a second of silence.

JOB_RESULT:

```json
{"job":1234,"ok":true,"error":"","stage":"","failedOp":-1,"linkMs":4100,"readyMs":6000,"totalMs":52000,
 "rssi":-50,"links":1,"handshakes":1,"restarts":0,"tableBytes":640,"truncated":false,
 "ops":[[1,1,0,0,210],[1,1,50001,2,43800],[1,1,50001,1,900]]}
```

`stage` says where a failed job stopped: `link` (no Bluetooth connection), `handshake`, or `step` (`failedOp`).
`linkMs` and `readyMs` are from the start of the job to the Bluetooth link and to the end of the table's
start-up lists. Each step reports `[ran, ok, value, count, ms]`: for an upload, the id it went into and the
pages sent again; for a play, the id and how many times play was sent. `tableBytes` is how many bytes of
JOB_TABLE_DATA belong to this result: the table's lists and upload replies in order, then its latest running
state and alarms (not every broadcast). Feed them to the same packet parser as TABLE_DATA to learn the stored
patterns, playlists and what the table is doing.

## Testing without hardware

`relay/tools/fake_relay.py` speaks this protocol with a simulated table behind it (handshake, init dump, state
broadcasts, the 2 s session reset, uploads, plays, playlists), and `relay/tools/test-fake-relay.sh` runs
drifted-host against it end to end: handshake, staying ready, drawing, a lost table link, a dropped TCP
connection, release/connect, both kinds of update, linking on demand, and a table that never re-asks for a
handshake. It uses its own state folder and ports, so a running Drifted is untouched.

Jobs are tested with the firmware's own code. The job engine (`relay/firmware/main/job.c`) is plain C with no
ESP-IDF in it, so it builds for the Mac as well as for the relay:

- `relay/tools/test-job-engine.py` runs it against the simulated table on a clock of its own and breaks one
  thing at a time, at every step: the Bluetooth link dropping at each write the relay makes and after each
  message the table sends, the table restarting its session at each write, each single message lost in either
  direction, thousands of random combinations of those, and a table that is absent, late, silent, stuck,
  out of storage, or that refuses or abandons uploads and ignores Start, End or play. Every run has to end, in
  bounded time, and may only say "ok" if the table really ended up with the pattern stored and drawing. It
  finishes with `fuzz-job-engine.c`: hundreds of thousands of random and half-broken jobs and table bytes with
  the engine built under the address and undefined-behaviour sanitizers.
- `test-fake-relay.sh` runs drifted-host against the fake relay with that engine inside it (`--engine`), through
  faults the fake can inject (`--faults`): the ones above, plus the connection between Drifted and the relay
  lost at every stage of a job (while it's handed over, as it's accepted, while the relay links, handshakes and
  works, as the result comes back), results lost on the way, a pattern stored wrong, the relay killed in the
  middle of a job, and drifted-host killed in the middle of a job.

What that covers, in short: a job is done once and its result collected whatever drops; if the relay loses a
job (it restarted), Drifted hands it over again, except for the few commands that toggle or step something
(play/pause, next, previous), which fail saying they may or may not have reached the table rather than risk
doing them twice. What it can't cover is the firmware's own Bluetooth and flash code, which only runs on the
relay.

## Security

The relay accepts only connections that present its token, but the connection isn't encrypted: anyone who can
watch your local network traffic could read the token. Keep the relay on a network you trust. The token can
be changed any time with `setup.py --token …` (then PUT the new one to Drifted).
