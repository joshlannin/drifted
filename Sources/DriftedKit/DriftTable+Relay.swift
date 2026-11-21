import Foundation

/// DriftTable through a Drifted relay (relay/ in this repo) instead of this Mac's Bluetooth. Only the transport
/// changes: the relay hands over the table's bytes and writes ours, so the handshake, ConfirmData replies,
/// uploads and retries above are exactly the Bluetooth ones.
///
/// Mapping onto `Status`:
/// - connecting: opening the TCP connection, or connected and the relay hasn't got the table yet
/// - handshaking: the relay is linked to the table (notifications on); waiting for 0x50/1 … 0x4F/1
/// - ready / disconnected: as over Bluetooth. The relay losing the table or the TCP connection both count as
///   a dropped link, so the host's reconnect and job-retry logic carries on unchanged.
/// - standby: connected to the relay, which has let go of the table because we asked (`relayStandby()`). The
///   relay has one radio for Wi-Fi and Bluetooth, and its Wi-Fi stalls for seconds at a time while it holds
///   the table, so a host that only needs the table now and then keeps it released in between.
extension DriftTable {
    /// Switches between Bluetooth (nil) and a relay. Drops the current link; the caller's supervisor reconnects.
    public func useRelay(_ endpoint: RelayEndpoint?) {
        guard endpoint != relayEndpoint else { return }
        let wasRelay = viaRelay
        if wasRelay {
            relayStopScan()
            relay?.close("switching to \(endpoint.map { "relay \($0.description)" } ?? "Bluetooth")")
            relay = nil
        } else {
            stopScan()
            disconnect()
        }
        relayEndpoint = endpoint
        relayParked = false
        relayProto = nil
        relayStatus = nil
        relayStatusJSON = nil
        note(endpoint.map { "Reaching the table through relay \($0.description)" } ?? "Reaching the table over this Mac's Bluetooth")
        relayPending = []
        if endpoint == nil { _ = bluetooth }
        setStatus(.disconnected("switched transport"))
    }

    /// Connects to the relay (or reuses the open connection) and asks it to hold the table for us. With `table`
    /// (an id from a relay scan), the relay switches to that table and remembers it.
    public func connectRelay(table: UUID? = nil) {
        guard let endpoint = relayEndpoint else { return }
        relayParked = false
        setStatus(.connecting)
        if let id = table, let address = RelayTable.address(fromId: id) {
            sendRelayCommand("select \(address)")
        }
        if let relay, relay.isOpen {
            // An observer connection (Choose table, standby) becomes the host's: "connect" undoes a release, and
            // the relay passes our writes on from the table's next handshake request.
            relay.quietLimit = RelayLink.busyQuietLimit   // its Wi-Fi goes quiet while it reaches the table
            sendRelayCommand("connect")
            if relayStatus?.linked == true { setStatus(.handshaking) }
            return
        }
        openRelay(endpoint, observe: false)
        note("Connecting to relay \(endpoint.description)…")
    }

    /// Keeps the connection to the relay but has it let go of the table until `connectRelay()`. The table
    /// carries on drawing (and its own playlist) with nobody connected, and the relay's Wi-Fi is dependable
    /// again. Status becomes `.standby` (after `.connecting` if the relay connection has to be opened first).
    public func relayStandby() {
        guard let endpoint = relayEndpoint else { return }
        relayParked = true
        if let relay, relay.isOpen {
            relayLastParkRelease = Date()
            sendRelayCommand("release")
            relayStatus?.link = "released"   // don't act on "linked" from before the release
            linkParked()
            return
        }
        setStatus(.connecting)
        openRelay(endpoint, observe: true)   // observing: a released table stays released
        note("Connecting to relay \(endpoint.description) (to stand by)…")
    }

    /// Tells the relay to use this table from now on (an id from `discovered` while scanning through the relay).
    /// It remembers it across restarts.
    public func selectRelayTable(_ id: UUID) {
        guard let address = RelayTable.address(fromId: id) else { return }
        sendRelayCommand("select \(address)")
    }

    /// The `discovered` id of the table the relay is linked to (or was last).
    public var relayTableId: UUID? { relayStatus?.table?.id }

    /// The relay's Bonjour name and network address, once connected.
    public var relayDescription: String? {
        guard let relay else { return nil }
        let parts = [relay.relayName, relay.remote].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " at ")
    }

    public var relayConnected: Bool { relay?.isOpen ?? false }

    /// Asks the relay to let go of the table (so the HoMedics app can connect), then closes the connection.
    func relayRelease() {
        relayParked = false
        relayStopScan()
        guard let relay, relay.isOpen else {
            relay?.close("released")
            return
        }
        Task {
            try? await relay.send(.command("release"))
            relay.close("released the table")
        }
    }

    func relayWrite(_ packet: Packet) async throws {
        guard let relay, relay.isOpen, relayStatus?.linked == true else { throw DriftError.notConnected }
        let bytes = packet.encoded()
        if logPackets { note("> \(bytes.hex)") }
        try await relay.send(RelayFrame(.tableWrite, bytes))
    }

    // MARK: Scanning through the relay (Choose table)

    func relayStartScan() {
        guard let endpoint = relayEndpoint else { return }
        setDiscovered([])
        setStatus(.scanning)
        if relay == nil { openRelay(endpoint, observe: true) }
        if relay?.isOpen == true { sendRelayCommand("scan") }
        // The relay scans for 5 s per request; keep asking while the window is open.
        relayScanTimer?.invalidate()
        relayScanTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.status == .scanning else { return }
                if self.relay?.isOpen == true { self.sendRelayCommand("scan") }
            }
        }
    }

    func relayStopScan() {
        relayScanTimer?.invalidate()
        relayScanTimer = nil
        if status == .scanning { setStatus(.idle) }
    }

    // MARK: Commands

    /// Sends a command line to the relay and waits for its result (JSON `{command, ok, message}`).
    public func relayCommand(_ line: String, timeout: TimeInterval = 10) async throws -> [String: Any] {
        guard let relay, relay.isOpen else { throw DriftError.notConnected }
        let word = String(line.split(separator: " ").first ?? "")
        try await relay.send(.command(line))
        return await withCheckedContinuation { cont in
            relayResultWaiters.append((word, cont))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let i = self.relayResultWaiters.firstIndex(where: { $0.command == word }) else { return }
                    self.relayResultWaiters.remove(at: i).cont.resume(returning: ["command": word, "ok": false, "message": "no answer from the relay"])
                }
            }
        }
    }

    /// Sends a command line now, or once the relay accepts the connection.
    private func sendRelayCommand(_ line: String) {
        guard let relay, relay.isOpen else { relayPending.append(line); return }
        Task { try? await relay.send(.command(line)) }
    }

    // MARK: Connection and events

    private func openRelay(_ endpoint: RelayEndpoint, observe: Bool) {
        let link = RelayLink(endpoint: endpoint, observe: observe)
        relay = link
        link.onEvent = { [weak self, weak link] event in
            guard let self, let link, self.relay === link else { return }
            self.relayEvent(event, observe: observe)
        }
        link.open()
    }

    private func relayEvent(_ event: RelayLink.Event, observe: Bool) {
        switch event {
        case .opened(let name, let firmware, let proto):
            relayProto = proto
            note("Relay \(name) (firmware \(firmware)) accepted the connection")
            let pending = relayPending
            relayPending = []
            if let relay { Task { for line in pending { try? await relay.send(.command(line)) } } }
            if status == .scanning { sendRelayCommand("scan") }
            if relayParked {
                // A relay that just started holds the table by itself, so ask even on an observing connection.
                relayLastParkRelease = Date()
                sendRelayCommand("release")
                linkParked()
                note("Standing by: the relay lets go of the table until there's work for it")
            }

        case .status(let s, let raw):
            let wasLinked = relayStatus?.linked ?? false
            relayStatusJSON = raw   // first: `relayStatus` is what observers are told about
            relayStatus = s
            setConnectedName(s.table?.name)
            // (A job on its way to the relay or running there: its Wi-Fi is busy or about to be poor.)
            relay?.quietLimit = ["released", "idle", "off"].contains(s.link) && relayJob == nil ? RelayLink.idleQuietLimit : RelayLink.busyQuietLimit
            relayJobStatus(s)
            if relayParked {
                // Standing by. A relay that restarted takes the table again by itself: ask it to let go.
                // (Not while it has the table for a job of ours: it lets go by itself when that's done.)
                if s.link != "released", !s.jobRunning, !relayJobRunning, status == .standby,
                   Date().timeIntervalSince(relayLastParkRelease) > 5 {
                    relayLastParkRelease = Date()
                    sendRelayCommand("release")
                }
            } else if s.linked {
                setRSSI(s.rssi)
                if status == .connecting {
                    setStatus(.handshaking)
                    note("Relay is linked to \(s.table?.name ?? "the table"); waiting for the table's handshake…")
                }
            } else if wasLinked || status == .handshaking || status == .ready {
                // The relay lost the table. It reconnects by itself; our supervisor sees the drop and waits.
                linkDropped("the relay lost the table (\(s.link))")
            }

        case .tableData(let bytes):
            if relayParked { break }   // the last bytes before a release
            if status == .connecting { setStatus(.handshaking) }
            received(bytes)

        case .scan(let tables):
            let list = tables.map { Discovered(id: $0.id, name: $0.name.isEmpty ? "(unnamed)" : $0.name, rssi: $0.rssi ?? -127) }
            for t in list where !discovered.contains(where: { $0.id == t.id }) {
                note("Relay found \(t.name) [\(RelayTable.address(fromId: t.id) ?? "")] rssi \(t.rssi)")
            }
            if status == .scanning || !list.isEmpty { setDiscovered(list) }

        case .result(let j):
            let word = (j["command"] as? String) ?? ""
            if (j["ok"] as? Bool) == false { note("Relay: \(word) failed: \((j["message"] as? String) ?? "")") }
            if let i = relayResultWaiters.firstIndex(where: { $0.command == word }) {
                relayResultWaiters.remove(at: i).cont.resume(returning: j)
            }

        case .log(let line):
            note("relay: \(line)")

        case .jobState(let j):
            relayJobState(j)

        case .jobResult(let j):
            relayJobResult(j)

        case .jobTableData(let id, let bytes):
            relayJobTableData(id, bytes)

        case .closed(let reason):
            relay = nil
            relayStatus = nil
            relayStatusJSON = nil
            relayScanTimer?.invalidate(); relayScanTimer = nil
            for w in relayResultWaiters { w.cont.resume(returning: ["command": w.command, "ok": false, "message": reason ?? "relay connection closed"]) }
            relayResultWaiters = []
            relayPending = []
            if case .disconnected(let earlier) = status {
                linkDropped(earlier, quiet: true)   // already reported (abandon or release)
            } else if status == .scanning || status == .idle {
                setStatus(.idle)
            } else {
                linkDropped(reason.map { "relay: \($0)" } ?? "relay connection closed")
            }
        }
    }
}
