# Drift BLE protocol

How to talk to a HoMedics Drift sand table over Bluetooth LE, as verified by interoperability testing on a
gen-1 16" table (the table reports controller version `A_11_V0.7.12` and driver version `B_11_V0.3.3`).

Only the **Bluetooth** Drift tables (16" ST-300, 21" ST-400) use this protocol. The Wi-Fi models (11" ST-200,
ST-250) are a different system, controlled through a cloud service, and nothing here applies to them.

Read [failure-modes.md](failure-modes.md) before writing an uploader: most of the hard-won knowledge is there.

## Transport

| | UUID | Notes |
|---|---|---|
| Service | `0000FFE0-0000-1000-8000-00805F9B34FB` | a BLE-to-UART module; BLE is just a serial pipe into the controller |
| Write | `0000FFE9-0000-1000-8000-00805F9B34FB` | write whole packets, without response |
| Notify | `0000FFE4-0000-1000-8000-00805F9B34FB` | table → host; a byte stream, so reassemble packets by header and length |

- Tables advertise a name of 12+ characters starting with `KS`. The name may carry trailing `\r\n`; trim it.
- No pairing is needed. Only one central can be connected at a time.
- One packet per write. A full 40-point page is 168 bytes, which fits in one write on macOS (max 244);
  check your platform's maximum write length.

## Framing

```
+------+-----+--------+-------------+----------+
| 0x7B | len | ackCmd | data        | checksum |
+------+-----+--------+-------------+----------+
len      = total packet length = data.count + 4   (the table rejects len ≥ 200)
ackCmd   = cmd | 0x80 when the ack flag is set, else cmd & 0x7F
data[0]  = action byte for most commands, then arguments
checksum = (0x7B + len + ackCmd + sum(data)) & 0xFF
```

Arguments are little-endian: `u8`, `u16`, `u32`; `bool` = 1 byte; `string` = UTF-8 + `0x00`;
`u16 array` = `count:u8` + `count × u16`; colour = 3 bytes `r, g, b`.

**ConfirmData** is `0x50` with the ack bit and no data: `7B 04 D0 4F`. It is the general acknowledgement.

## Session

1. Connect and enable notifications on FFE4.
2. The table sends `0x50/1` (waiting for confirm). Reply `0x50/2 true` = `7B 06 50 02 01 D4`.
3. The table dumps its state: playlists, colours, schedule, stored pattern ids, running state.
   **Reply ConfirmData to every table message**, with two exceptions:
   - `0x32/2` (the table asks for the time): reply with the time packet `0x12/2` instead.
   - Packets with the ack bit set (`cmd | 0x80`) are the table acknowledging *your* command. Reply
     ConfirmData to those too, but never answer them in kind: answering `b2 02` with the time again loops
     forever, and ignoring it makes the table resend 4× and restart the handshake.
4. The table sends `0x4F/1` (init complete). Reply ConfirmData; the session is ready.

If the table hears nothing from the host for about 2 s it resets the session and the handshake restarts.
Drawing continues; an upload in progress fails (see failure modes). Hosts that stay connected should keep
answering the ~2 Hz state broadcast with ConfirmData, which keeps the session alive.

## Commands: host → table

| cmd | action | what | arguments |
|---|---|---|---|
| 0x10 | 1..8 | playlists and favourites | strings, u16 arrays |
| 0x11 | 1 / 3 / 2 | rewrite the colour palette: start(count) → data(page, list of name+rgb) → end(count) | each confirmed |
| 0x11 | 4 | **light mode** (persists) | `shifting:bool, shiftTime:u16 seconds, breathing:bool, brightness:u8 0..100` |
| 0x11 | 5 | request colours | – |
| 0x12 | 1 | sleep schedule | |
| 0x12 | 2 | **current time** | `yy%100, month (0-based), day, hour, min, sec, weekday (Mon=1..Sun=7)`, all u8 |
| 0x13 | 1 | **start upload** | `patternId:u16, pageCount:u32` |
| 0x13 | 2 | **end upload** | `patternId:u16, pageCount:u32` |
| 0x13 | 3 | delete patterns | u16 array of ids |
| 0x53 | 1 | **pattern page** | `pointCount:u8, pageIndex:u16 (1-based), pointCount × (t:u16, r:u16)` |
| 0x14 | 1 | **draw pattern** | `patternId:u16` |
| 0x14 | 2 | draw from playlist | `playlistId:string, patternId:u16` |
| 0x14 | 3 | play/pause toggle | – |
| 0x14 | 4 / 5 | next / previous | – |
| 0x14 | 6 | speed | `u8`, raw 30..75 (30 + p·45 for p in 0..1) |
| 0x14 | 7 | brightness | `u8` 0..100 |
| 0x14 | 10 / 11 | random / loop mode | bool |
| 0x14 | 12 | *reserved: appears to reset the controller. Untested; don't send.* | |
| 0x14 | 13 | **select palette colour by name** | string |
| 0x14 | 15 | **show colour and store it as palette entry "Temp"** | `enable:bool, r, g, b` |
| 0x14 | 16 | power | bool |
| 0x15 | 1..5 | firmware update. **Never send these.** | |
| 0x16 | 1 | light flags | 4 bytes: breathing, shifting, shiftTime u16 |
| 0x50 | 2 | confirm connection | bool `true` |

A fixed custom colour is three packets: `0x14/15 01 rr gg bb`, then `0x14/13 "Temp"`, then
`0x11/4 00 00 00 00 <brightness>` (shifting and breathing off). Leaving out the `enable` byte in `0x14/15`
shifts the colour bytes by one (white becomes yellow).

## Messages: table → host

| cmd | action | meaning |
|---|---|---|
| 0x30 | 1..4 | playlists |
| 0x31 | 1..4 | colours: `0x31/3 page:u8, count:u8, count × (name:string, r, g, b)`; `0x31/4` echoes light mode |
| 0x32 | 1 / 2 | sleep schedule / **asks for the current time** |
| 0x33 | 1..3 | stored pattern ids: start, end, data `page:u8, ids:u16 array`. Re-sent after uploads and deletes. |
| 0x34 | 1 | upload: missing pages, u16 array of 1-based indices, at most 20 per message. **An empty list is not success** (failure modes). |
| 0x34 | 2 | upload: started receiving `patternId` |
| 0x34 | 3 | upload: **stored** `patternId`. The only success signal. |
| 0x34 | 5 | upload failed `patternId` |
| 0x34 | 6 | not enough storage `patternId` |
| 0x35 | 1 | running state, about twice a second (below) |
| 0x36 | 1..3 | favourites |
| 0x37 | 1 / 2 / 3 | fatal / recoverable / warning alarm: u16 array of codes (below) |
| 0x38 | 1..6 | firmware update flow |
| 0x4F | 1 | init complete |
| 0x50 | 1 | waiting for connection confirm |

Upload replies usually arrive with the ack bit set (`b4 02`, `b4 01`, `b4 03`). The table acknowledges
commands such as draw with a bare ConfirmData.

### Running state (`0x35/1`)

```
brightness:u8, colorName:string, color:rgb, speed:u8, playlistId:string, patternId:u16,
progress:u16 (0..10000), status:u8 (1 drawing, 0 idle), random:bool, loop:bool, sleep:bool,
breathing:bool, shifting:bool, shiftTime:u16, controllerVersion:string, aUpdate:bool, aProgress:u8,
driverVersion:string, bUpdate:bool, bProgress:u8, powerOn:bool
```

Progress does not advance while the ball moves to a pattern's first point, and right after a new pattern
starts it can still show the previous pattern's 100% for a moment.

### Alarm codes

| code | meaning | | code | meaning |
|---|---|---|---|---|
| 1 | file queue full | | 11 | can't read pattern file |
| 2 | setting coordinates failed | | 12 | can't close pattern file |
| 3 | file download failed | | 13 | can't delete pattern file |
| 4 | SD card full | | 14 | file seek failed |
| 5 | file already open | | 15 | position reset failed |
| 6 | too much file data lost | | 16 | homing failed |
| 8 | motor driver error | | 17 | can't create received file |
| 9 | SD card init failed | | 19 | receive queue error |
| 10 | can't open pattern file | | | |

Fatal codes (8–17) latch until the table reboots and repeat every second (failure modes).

## Pattern data

A pattern is a list of polar points, sent in pages of 40.

- On the wire each point is two u16: `t = theta_millidegrees / 6` (0..59999) and `r = rho × 50000`
  (0 centre .. 50000 rim).
- Theta is sent modulo 360°. The table unwraps it only across the 314°→46° boundary, so **consecutive
  points must be less than about 45° apart**, or the ball goes the long way round. Densify first, then wrap.
- The table plays back exactly the points you sent.
- The common `.txt` pattern format is `theta,rho` per line, theta in thousandths of a degree 0..359999 and
  rho 0..100000. About 1% of the radius per step draws smoothly.

## Uploading

```
pages = ceil(points / 40)                 # exactly 40 per page except the last
wait for init complete
send Start(id, pages)                     # 0x13/1
await 0x34/2 for id (≤ 4 s; resend Start up to 3×)
repeat:
    for each pending page i: send Page(i + 1, points[40i ..< 40i+40]); sleep 100 ms
    sleep 100 ms; send End(id, pages)     # 0x13/2
    await 0x34/3 (stored) | 0x34/1 (missing) | 0x34/5 | 0x34/6   (≤ 15 s)
    0x34/3                → done
    0x34/1, non-empty     → pending = those pages; sleep 200 ms between resends
    0x34/1, empty         → the last page(s) were lost: resend the last few pages (grow each time), then End
    0x34/5 or 0x34/6      → failed
then play with 0x14/1 id
```

- **Pace pages at 100 ms.** At 1 ms the table drops the session after End.
- Never pause more than 5 s mid-upload, and never start an upload while the previous one is unfinished.
- Don't upload to the id that is drawing. Ids ≥ 50000 are safe for your own patterns; the table keeps room
  for 800 ids in total.
- Overwriting an existing id replaces it; there is no need to delete first.
