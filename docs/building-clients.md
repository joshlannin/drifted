# Building your own client or app

You don't need this repo's code to control a Drift. The protocol is small; the traps are what take time,
and they're written down here. This page tells you (or your coding assistant) which layer to build on.

This covers the **Bluetooth** Drift tables (16" ST-300, 21" ST-400) only. The Wi-Fi models (11" ST-200,
ST-250) are controlled through a cloud service with a different protocol and aren't covered.

Whatever you build, you can check drawings on the [digital twin](digital-twin.md) first: through the host's
`POST /patterns/preview` and `/patterns/validate`, or `PatternPreview` and `TableTwin` in DriftedKit.

## Pick a layer

| You want | Build on |
|---|---|
| To draw things from an assistant, a script or a schedule | **drifted-host's HTTP API** ([`spec/openapi.yaml`](../spec/openapi.yaml)) or its **MCP server**. No Bluetooth code at all. |
| An Apple app (iOS, iPadOS, macOS) | The **DriftedKit** Swift library in this repo: connection, handshake, uploads with recovery, validation, previews, live streaming. |
| A client in another language or OS (Windows, Linux, Android, a microcontroller) | The **protocol directly**: [protocol.md](protocol.md), [failure-modes.md](failure-modes.md) and the test data in [`spec/vectors/`](../spec/vectors/). |

## Writing a protocol client from scratch

A minimal client is four pieces, in this order:

1. **Framing:** encode packets and parse the notify stream (packets can arrive split or joined).
   Check against `spec/vectors/` before touching hardware.
2. **Session:** connect, answer `0x50/1` with confirm-connection, reply ConfirmData to everything
   (including ack-bit packets), answer `0x32/2` with the time, and wait for `0x4F/1`.
3. **Commands:** play, pause, speed, brightness and the light-mode recipe are one packet each.
4. **Upload:** pages of 40, 100 ms apart, success only on `0x34/3`, and handling for missing pages and
   lost trailing pages (the [upload section](protocol.md#uploading) has the full loop).

Then test on the table in this order: handshake → play a stock id → upload a small circle to id 50000 and
play it → upload something else over 50000 → stream two alternating slots.

## Bluetooth libraries that work

The table is a plain BLE UART (service FFE0), with no pairing, so any central-role library works: CoreBluetooth
(Apple), WinRT `Windows.Devices.Bluetooth` (Windows 10+), BlueZ (Linux), Android BLE, or cross-platform
libraries such as `bleak` (Python), `btleplug` (Rust) or `noble` (Node).

## Rules every client should keep

- Never send `0x15` (firmware update).
- Use ids ≥ 50000 for your own patterns; overwrite in place.
- Don't upload to the id that is drawing; don't delete ids the table didn't list.
- Report alarms as new codes only. They latch until reboot.

## Contributing back

Found something new (another model, another firmware version, a new command, a timing)? Post it in the
repo's Discussions. Published a client in another language? Share it there too, and it can be linked from
the README.
