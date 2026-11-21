import DriftedKit
import Foundation

/// How the link to the table holds up, day by day: kept in link-telemetry.json so it survives restarts and
/// weeks can be compared (GET /link). It answers "is this working?": how much of the day the table could be
/// reached, how long taking the table takes and how often that fails, connections lost and why, whether jobs
/// and uploads needed retries, and the relay's signal. One line per day also goes to the log.
struct LinkTelemetry: Codable {
    /// One day's counters, by name (plain numbers, so new ones can be added without a migration):
    /// `s.<phase>` seconds in linked / standby / connecting / down / released; `wakes`, `wakesFailed`,
    /// `wakeSeconds`, `wakeMax`, `wakeIn5|10|20|40|75`, `why.<reason>`; `drop.<cause>`, `dropLinked`,
    /// `dropStandby`, `dropInJob`, `connectFail.<cause>`; `jobs`, `jobsFailed`, `jobRetries`, `jobLinkWaitMax`;
    /// `uploads`, `uploadsFailed`, `uploadRetries`, `uploadSeconds`, `pagesResent`; `relayReboots`,
    /// `wifiMin|Sum|N`, `tableMin|Sum|N` (dBm), `relayWifiDrops`, `relayWifiReason.<code>`, `relaySendFails`,
    /// `relayUnstuck` (the relay's own counts, firmware 0.2). Jobs the relay ran by itself (RelayJobs.swift): `rjobs`,
    /// `rjobsFailed`, `rjobFail.<link|handshake|step|relay>`, `rjobWhy.<reason>`, `rjobSeconds`, `rjobMax`,
    /// `rjobLinkN|Seconds|Max` (to the Bluetooth link), `rjobReadyN|Seconds|Max` (to the end of the handshake),
    /// `rjobRelinks`, `rjobRestarts`, `rjobTruncated`, `s.job` (seconds the relay held the table for them).
    struct Day: Codable {
        var mode = ""
        var n: [String: Double] = [:]

        mutating func add(_ key: String, _ by: Double = 1) { n[key, default: 0] += by }
        mutating func raise(_ key: String, _ v: Double) { n[key] = max(n[key] ?? v, v) }
        mutating func lower(_ key: String, _ v: Double) { n[key] = min(n[key] ?? v, v) }
        func get(_ key: String) -> Double { n[key] ?? 0 }
        func int(_ key: String) -> Int { Int(get(key)) }
        func group(_ prefix: String) -> [String: Int] {
            var out: [String: Int] = [:]
            for (k, v) in n where k.hasPrefix(prefix) { out[String(k.dropFirst(prefix.count))] = Int(v) }
            return out
        }
    }

    struct Event: Codable {
        var at: Date
        /// wake, drop, connect, job, upload, relay
        var kind: String
        var what: String
        var seconds: Double?
        var ok: Bool?
    }

    static let keepDays = 120
    static let keepEvents = 400

    var days: [String: Day] = [:]
    var events: [Event] = []
    var file: URL?
    var dirty = false
    /// An event was recorded: write the file at the next tick, not the next minute.
    var urgent = false

    enum CodingKeys: String, CodingKey { case days, events }

    static func load(_ file: URL) -> LinkTelemetry {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var t = (try? dec.decode(LinkTelemetry.self, from: Data(contentsOf: file))) ?? LinkTelemetry()
        t.file = file
        return t
    }

    mutating func save() {
        guard let file else { return }
        for old in days.keys.sorted().dropLast(Self.keepDays) { days[old] = nil }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try? enc.encode(self).write(to: file, options: .atomic)
        dirty = false
        urgent = false
    }

    mutating func day(_ key: String, _ change: (inout Day) -> Void) {
        var d = days[key] ?? Day()
        change(&d)
        days[key] = d
        dirty = true
    }

    mutating func event(_ kind: String, _ what: String, seconds: Double? = nil, ok: Bool? = nil) {
        events.append(Event(at: Date(), kind: kind, what: what, seconds: seconds.map { ($0 * 10).rounded() / 10 }, ok: ok))
        if events.count > Self.keepEvents { events.removeFirst(events.count - Self.keepEvents) }
        dirty = true
        urgent = true
    }

    /// Why a connection was lost, from the reason DriftTable gave. Nil when it was let go on purpose.
    static func dropCause(_ reason: String?, viaRelay: Bool) -> String? {
        guard let r = reason?.lowercased() else { return "unknown" }
        if r.contains("released") || r.contains("switch") { return nil }
        guard viaRelay else { return "bluetooth" }
        if r.contains("went quiet") { return "relay went quiet" }
        if r.contains("closed the connection") { return "relay closed the connection" }
        if r.contains("another host") { return "another host took the relay" }
        if r.contains("can't reach") || r.contains("no answer") || r.contains("connection failed") { return "relay unreachable" }
        if r.contains("lost the table") { return "relay lost the table" }
        if r.contains("not ready after") { return "not ready in time" }
        if r.contains("connection error") { return "relay connection error" }
        return "other"
    }

    /// One day as JSON for GET /link, with the derived figures people actually read.
    static func json(_ date: String, _ d: Day) -> [String: Any] {
        let phases = ["linked", "standby", "connecting", "down", "released"]
        var seconds: [String: Int] = [:]
        for p in phases { seconds[p] = d.int("s.\(p)") }
        let wanted = d.get("s.linked") + d.get("s.standby") + d.get("s.connecting") + d.get("s.down")
        func percent(_ v: Double) -> Any { wanted > 0 ? ((1000 * v / wanted).rounded() / 10) as Any : NSNull() }
        func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        let wakes = d.int("wakes"), good = wakes - d.int("wakesFailed")
        var out: [String: Any] = [
            "date": date, "mode": d.mode, "seconds": seconds,
            // Reachable: the table linked, or the relay standing by and ready to take it.
            "reachablePercent": percent(d.get("s.linked") + d.get("s.standby")),
            "linkedPercent": percent(d.get("s.linked")),
            "wakes": ["count": wakes, "failed": d.int("wakesFailed"),
                      "averageSeconds": good > 0 ? round1(d.get("wakeSeconds") / Double(good)) as Any : NSNull(),
                      "slowestSeconds": round1(d.get("wakeMax")),
                      "within": ["5s": d.int("wakeIn5"), "10s": d.int("wakeIn10"), "20s": d.int("wakeIn20"),
                                 "40s": d.int("wakeIn40"), "75s": d.int("wakeIn75")],
                      "reasons": d.group("why.")] as [String: Any],
            "drops": ["total": d.group("drop.").values.reduce(0, +), "whileLinked": d.int("dropLinked"),
                      "whileStandingBy": d.int("dropStandby"), "duringJobs": d.int("dropInJob"),
                      "causes": d.group("drop.")] as [String: Any],
            "connectFailures": d.group("connectFail."),
            "jobs": ["count": d.int("jobs"), "failed": d.int("jobsFailed"), "retried": d.int("jobRetries"),
                     "longestLinkWaitSeconds": round1(d.get("jobLinkWaitMax"))] as [String: Any],
            "uploads": ["count": d.int("uploads"), "failed": d.int("uploadsFailed"), "retries": d.int("uploadRetries"),
                        "pagesResent": d.int("pagesResent"), "seconds": d.int("uploadSeconds")] as [String: Any],
        ]
        if d.int("rjobs") > 0 {
            func average(_ sum: String, _ n: String) -> Any { d.get(n) > 0 ? round1(d.get(sum) / d.get(n)) as Any : NSNull() }
            out["relayJobs"] = [
                "count": d.int("rjobs"), "failed": d.int("rjobsFailed"), "failedAt": d.group("rjobFail."),
                "reasons": d.group("rjobWhy."),
                "averageSeconds": average("rjobSeconds", "rjobs"), "slowestSeconds": round1(d.get("rjobMax")),
                // From the start of a job: until the relay had its Bluetooth link, and until the table's
                // handshake and init dump were done.
                "bluetoothLink": ["averageSeconds": average("rjobLinkSeconds", "rjobLinkN"), "slowestSeconds": round1(d.get("rjobLinkMax"))] as [String: Any],
                "tableReady": ["averageSeconds": average("rjobReadySeconds", "rjobReadyN"), "slowestSeconds": round1(d.get("rjobReadyMax"))] as [String: Any],
                "extraLinks": d.int("rjobRelinks"), "stepsRestarted": d.int("rjobRestarts"),
                "secondsHoldingTable": d.int("s.job"),
            ] as [String: Any]
        }
        var relay: [String: Any] = ["restarts": d.int("relayReboots")]
        // Firmware 0.2 reports these: its Wi-Fi association lost (by 802.11 reason code), sends to the host it
        // gave up on, and tables it found stuck in an old handshake.
        if d.int("relayWifiDrops") > 0 { relay["wifiLost"] = ["count": d.int("relayWifiDrops"), "reasons": d.group("relayWifiReason.")] as [String: Any] }
        if d.int("relaySendFails") > 0 { relay["sendsGivenUp"] = d.int("relaySendFails") }
        if d.int("relayUnstuck") > 0 { relay["stuckTableAnswers"] = d.int("relayUnstuck") }
        if d.get("wifiN") > 0 { relay["wifiRssi"] = ["min": d.int("wifiMin"), "average": Int((d.get("wifiSum") / d.get("wifiN")).rounded())] }
        if d.get("tableN") > 0 { relay["tableRssi"] = ["min": d.int("tableMin"), "average": Int((d.get("tableSum") / d.get("tableN")).rounded())] }
        out["relay"] = relay
        return out
    }

    /// The day in one log line.
    static func summary(_ date: String, _ d: Day) -> String {
        let wanted = d.get("s.linked") + d.get("s.standby") + d.get("s.connecting") + d.get("s.down")
        func pct(_ v: Double) -> String { wanted > 0 ? String(format: "%.1f%%", 100 * v / wanted) : "n/a" }
        let wakes = d.int("wakes"), good = wakes - d.int("wakesFailed")
        var parts = ["reachable \(pct(d.get("s.linked") + d.get("s.standby"))) of the time, table linked \(pct(d.get("s.linked")))"]
        if wakes > 0 {
            parts.append("\(wakes) wakes (\(d.int("wakesFailed")) failed"
                + (good > 0 ? String(format: ", average %.1f s, slowest %.0f s", d.get("wakeSeconds") / Double(good), d.get("wakeMax")) : "") + ")")
        }
        let drops = d.group("drop.")
        parts.append("\(drops.values.reduce(0, +)) connections lost (\(d.int("dropLinked")) while linked, \(d.int("dropInJob")) during a job)"
            + (drops.isEmpty ? "" : ": " + drops.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
        if d.int("rjobs") > 0 {
            let fails = d.group("rjobFail.")
            parts.append("\(d.int("rjobs")) relay jobs (\(d.int("rjobsFailed")) failed"
                + (fails.isEmpty ? "" : ": " + fails.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                + (d.get("rjobReadyN") > 0 ? String(format: "; table ready in %.1f s on average, slowest %.0f s", d.get("rjobReadySeconds") / d.get("rjobReadyN"), d.get("rjobReadyMax")) : "")
                + ")")
        }
        parts.append("\(d.int("jobs")) jobs (\(d.int("jobsFailed")) failed, \(d.int("jobRetries")) retried)")
        if d.int("uploads") > 0 || d.int("uploadsFailed") > 0 {
            parts.append("\(d.int("uploads")) uploads (\(d.int("uploadsFailed")) failed, \(d.int("uploadRetries")) retries, \(d.int("pagesResent")) pages resent)")
        }
        if d.get("wifiN") > 0 {
            parts.append("relay Wi-Fi \(Int((d.get("wifiSum") / d.get("wifiN")).rounded())) dBm average, \(d.int("relayReboots")) restarts")
        }
        return "link: \(date) (\(d.mode)): " + parts.joined(separator: "; ")
    }
}

extension Daemon {
    var linkModeName: String {
        table.viaRelay ? (linkOnDemand ? (relayJobs ? "relay, jobs" : "relay, on demand") : "relay, always linked") : "bluetooth"
    }

    private func phase(for s: DriftTable.Status) -> String {
        if !wantConnected { return "released" }
        switch s {
        case .ready: return "linked"
        case .standby: return "standby"
        case .connecting, .handshaking, .scanning: return "connecting"
        default: return "down"
        }
    }

    /// Books the time since the last call to the phase we were in, then moves to `next`.
    private func telemetryClock(next: String, now: Date = Date()) {
        let elapsed = now.timeIntervalSince(telemetryPhaseSince)
        if elapsed > 0, elapsed < 3600 {   // a longer gap means the Mac slept: not the link's doing
            let phase = telemetryPhase, mode = linkModeName
            telemetry.day(Self.dayString(now)) { $0.add("s.\(phase)", elapsed); $0.mode = mode }
        }
        telemetryPhase = next
        telemetryPhaseSince = now
    }

    /// Every few seconds: keeps the clock running, writes the file, and logs yesterday when the day turns.
    func telemetryTick(now: Date = Date()) {
        telemetryClock(next: phase(for: table.status), now: now)
        let today = Self.dayString(now)
        if telemetryDay.isEmpty { telemetryDay = today }
        if today != telemetryDay {
            if let d = telemetry.days[telemetryDay] { log(LinkTelemetry.summary(telemetryDay, d)) }
            telemetryDay = today
            telemetry.save()
            telemetryLastSave = now
        }
        if telemetry.dirty, telemetry.urgent || now.timeIntervalSince(telemetryLastSave) >= 60 {
            telemetry.save()
            telemetryLastSave = now
        }
    }

    /// A status change, called before `table.status` holds the new value.
    func telemetryStatusChanged(to s: DriftTable.Status) {
        let before = telemetryStatus
        telemetryStatus = s
        telemetryClock(next: phase(for: s))
        guard case .disconnected(let reason) = s, wantConnected else { return }
        guard let cause = LinkTelemetry.dropCause(reason, viaRelay: table.viaRelay) else { return }
        let inJob = jobRunning
        switch before {
        case .ready, .standby:
            // Something that was up went away.
            telemetry.day(Self.dayString(Date())) {
                $0.add("drop.\(cause)")
                $0.add(before == .ready ? "dropLinked" : "dropStandby")
                if inJob { $0.add("dropInJob") }
            }
            telemetry.event("drop", "\(cause) while \(before == .ready ? (inJob ? "running a job" : "linked") : "standing by")", ok: false)
        case .connecting, .handshaking:
            telemetry.day(Self.dayString(Date())) { $0.add("connectFail.\(cause)") }
        default:
            break
        }
    }

    func telemetryWake(why: String, from: String, seconds: Double, error: String?) {
        telemetry.day(Self.dayString(Date())) { d in
            d.add("wakes")
            d.add("why.\(why)")
            guard error == nil else { d.add("wakesFailed"); return }
            d.add("wakeSeconds", seconds)
            d.raise("wakeMax", seconds)
            d.add(seconds <= 5 ? "wakeIn5" : seconds <= 10 ? "wakeIn10" : seconds <= 20 ? "wakeIn20" : seconds <= 40 ? "wakeIn40" : "wakeIn75")
        }
        telemetry.event("wake", "\(why), from \(from)" + (error.map { ": \($0)" } ?? ""), seconds: seconds, ok: error == nil)
    }

    func telemetryJob(kind: String, error: String?, attempts: Int, linkWait: Double, seconds: Double) {
        telemetry.day(Self.dayString(Date())) { d in
            d.add("jobs")
            if error != nil { d.add("jobsFailed") }
            if attempts > 1 { d.add("jobRetries", Double(attempts - 1)) }
            d.raise("jobLinkWaitMax", linkWait)
        }
        telemetry.event("job", kind + (attempts > 1 ? ", \(attempts) attempts" : "")
            + String(format: ", waited %.1f s for the table", linkWait) + (error.map { ": \($0)" } ?? ""), seconds: seconds, ok: error == nil)
    }

    func telemetryUpload(ok: Bool, tries: Int, seconds: Double, points: Int) {
        telemetry.day(Self.dayString(Date())) { d in
            d.add(ok ? "uploads" : "uploadsFailed")
            if tries > 1 { d.add("uploadRetries", Double(tries - 1)) }
            d.add("uploadSeconds", seconds)
        }
        telemetry.event("upload", "\(points) points" + (tries > 1 ? ", \(tries) tries" : ""), seconds: seconds, ok: ok)
    }

    /// DriftTable's own log lines: the only place page resends show up.
    func telemetryTableNote(_ text: String) {
        guard text.hasPrefix("Table missing "), let n = Int(text.dropFirst("Table missing ".count).prefix { $0.isNumber }) else { return }
        telemetry.day(Self.dayString(Date())) { $0.add("pagesResent", Double(n)) }
    }

    /// The relay's status (every 5 s while connected to it).
    func telemetryRelay(_ s: RelayStatus) {
        let uptime = table.relayStatusJSON?["uptime"] as? Int
        let rebooted = uptime.flatMap { now in telemetryRelayUptime.map { now + 30 < $0 } } ?? false
        if let uptime { telemetryRelayUptime = uptime }
        // What the relay counts for itself since it started (firmware 0.2): times it lost Wi-Fi (and the
        // last reason code), times it gave up sending to us, tables it found stuck and answered.
        let stats = table.relayStatusJSON?["stats"] as? [String: Any] ?? [:]
        if rebooted { telemetryRelayCounts = [:] }
        var added: [String: Int] = [:]
        for (key, counter) in [("wifiDrops", "relayWifiDrops"), ("sendFails", "relaySendFails"), ("unstuck", "relayUnstuck")] {
            guard let now = stats[key] as? Int else { continue }
            if let before = telemetryRelayCounts[key], now > before { added[counter] = now - before }
            telemetryRelayCounts[key] = now
        }
        let wifiReason = stats["wifiLastReason"] as? Int
        telemetry.day(Self.dayString(Date())) { d in
            if let w = s.wifiRssi { d.lower("wifiMin", Double(w)); d.add("wifiSum", Double(w)); d.add("wifiN") }
            if s.linked, let r = s.rssi { d.lower("tableMin", Double(r)); d.add("tableSum", Double(r)); d.add("tableN") }
            if rebooted { d.add("relayReboots") }
            for (counter, n) in added { d.add(counter, Double(n)) }
            if let n = added["relayWifiDrops"], let wifiReason { d.add("relayWifiReason.\(wifiReason)", Double(n)) }
        }
        if let n = added["relayWifiDrops"] {
            telemetry.event("relay", "the relay lost Wi-Fi \(n == 1 ? "once" : "\(n) times")" + (wifiReason.map { " (reason \($0))" } ?? ""))
        }
        if added["relayUnstuck"] != nil { telemetry.event("relay", "the relay found the table stuck in an old handshake and answered it") }
        if rebooted {
            telemetry.event("relay", "the relay restarted")
            log("link: the relay restarted (its uptime went back to \(uptime ?? 0) s)")
        }
    }

    /// GET /link: where the link stands now, the last `days` days and the last `events` events.
    func linkTelemetryJSON(days: Int, events: Int) -> [String: Any] {
        telemetryClock(next: phase(for: table.status))
        let iso = ISO8601DateFormatter()
        var out: [String: Any] = [
            "mode": linkModeName, "phase": telemetryPhase, "connection": "\(table.status)",
            "lastLinked": linkLastLinked.map(iso.string(from:)) ?? NSNull(),
            "stateAt": lastStateAt.map(iso.string(from:)) ?? NSNull(),
        ]
        if linkOnDemand {
            out["checkInMinutes"] = relaySettings.checkIn / 60
            out["lingerSeconds"] = relaySettings.linger
            if wantConnected { out["nextCheckIn"] = iso.string(from: max(linkNextCheckIn, Date())) }
            out["need"] = linkNeed() ?? NSNull()
            out["jobs"] = relayJobs
        }
        if table.viaRelay { out["relay"] = table.relayStatusJSON ?? NSNull() }
        let keys = telemetry.days.keys.sorted().suffix(max(1, days))
        out["days"] = keys.reversed().map { LinkTelemetry.json($0, telemetry.days[$0]!) }
        out["recent"] = telemetry.events.suffix(max(0, events)).reversed().map { e -> [String: Any] in
            var j: [String: Any] = ["at": iso.string(from: e.at), "kind": e.kind, "what": e.what]
            if let s = e.seconds { j["seconds"] = s }
            if let ok = e.ok { j["ok"] = ok }
            return j
        }
        return out
    }
}
