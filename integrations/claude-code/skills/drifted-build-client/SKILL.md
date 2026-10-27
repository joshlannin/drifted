---
name: drifted-build-client
description: Build software that controls a HoMedics Drift sand table (Bluetooth models), such as an iOS app, a Windows or Linux client, or a client in another language, using the documented BLE protocol. Use when the user wants their own app or client rather than the packaged Mac host.
---

# Building a Drift client or app

This applies only to the Bluetooth Drift tables (16" ST-300, 21" ST-400). The Wi-Fi models (11" ST-200,
ST-250) use a different, cloud-based system that isn't documented here; tell the user rather than guessing.

Clone https://github.com/joshlannin/drifted and read, in order:

1. `docs/building-clients.md`: choose a layer (the HTTP/MCP host, the Swift DriftedKit library, or the raw protocol).
2. `docs/protocol.md`: transport, framing, session, commands, uploads.
3. `docs/failure-modes.md`: the traps (lost last pages, latched alarms, ignored Starts). Don't skip it.
4. `docs/behaviour.md`: timings for designing the UX.

Then:

- Apple platforms: depend on the `DriftedKit` product of the Swift package (`DriftTable`, `PatternValidator`,
  `PatternPreview`, `LiveSession`).
- Other platforms: implement framing first and test it against `spec/vectors/protocol.json` (byte-exact host
  packets, table messages and full exchanges, including the lost-last-page recovery). Then the session, then
  commands, then uploads. Use any BLE central library (WinRT, BlueZ/bleak, Android BLE, btleplug…).
- Test on hardware in this order: handshake → play a stock id → upload a small circle to id 50000 → overwrite
  50000 → alternate two slots.

Rules: never send `0x15` (firmware update) or `0x14/12`; use ids ≥ 50000; only `0x34/3` means stored.
