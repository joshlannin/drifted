import DriftedKit
import Foundation

/// Table work done by the relay itself (DriftedKit's RelayJob; relay/README.md, "Jobs").
///
/// Linking on demand (Link.swift) keeps the relay's radio free between jobs, but taking the table still needed
/// working Wi-Fi all through the handshake, and the relay's Wi-Fi is at its worst exactly then. A relay with
/// firmware 0.2 or later doesn't need the host for that: each operation here is written as a short list of
/// steps, handed over while the table is released, and the relay reports when it's done. The connection to
/// the relay may drop meanwhile; the job carries on.
///
/// What still takes a live link: a live session (the host answers the table as it draws) and a playlist run
/// by the host rather than kept on the table.
extension Daemon {
    /// The relay runs jobs for us: relay.json has link on demand (and not `"jobs": false`) and its firmware can.
    var relayJobs: Bool { linkOnDemand && relaySettings.jobs != false && table.relayRunsJobs }

    /// The next operation goes to the relay as a job, rather than over a link that's up for something live.
    var viaRelayJob: Bool { relayJobs && table.status != .ready }

    /// Something can be sent to the table now: it's linked, or the relay will take it for a job.
    var tableUsable: Bool { table.status == .ready || (relayJobs && wantConnected) }

    static func linkNeedsLive(_ need: String) -> Bool { need == "live" || need == "playlist" }

    /// Runs `steps` on the relay. Returns its report if everything worked, or if a step failed and `tolerate`
    /// is set (the caller reads which). Throws `DriftError.relayJob`: with `retry` when the relay never got to
    /// the table, so the job is worth queueing again.
    @discardableResult
    func relayRun(_ why: String, _ steps: [RelayJob.Step], linger: TimeInterval = 2, tolerate: Bool = false,
                  progress: @escaping (Double) -> Void = { _ in }) async throws -> RelayJobResult {
        // A firmware update needs the relay's Wi-Fi, which is poor while it has the table: let it finish.
        let patience = Date().addingTimeInterval(600)
        while (table.relayStatusJSON?["ota"] as? Bool) == true, Date() < patience {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let started = Date()
        let job = RelayJob(steps, linger: linger)
        log("link: handing \(why) to the relay (\(steps.count) step\(steps.count == 1 ? "" : "s")"
            + (job.uploadPoints > 0 ? ", \(job.uploadPoints) points" : "") + ")")
        let result: RelayJobResult
        do {
            result = try await table.runRelayJob(job, progress: progress)
        } catch {
            telemetryRelayJob(why: why, result: nil, error: error.localizedDescription, seconds: Date().timeIntervalSince(started))
            log("link: \(why) wasn't done: \(error.localizedDescription)")
            throw error
        }
        let seconds = Date().timeIntervalSince(started)
        telemetryRelayJob(why: why, result: result, error: result.ok ? nil : result.error, seconds: seconds)
        if result.readySeconds > 0 {
            // The relay had the table and its init dump: as good as a check-in.
            linkLastLinked = Date()
            linkNextCheckIn = Date().addingTimeInterval(relaySettings.checkIn)
        }
        for (i, step) in steps.enumerated() where i < result.steps.count && result.steps[i].ran {
            guard case .upload(let points, _) = step.op else { continue }
            let r = result.steps[i]
            telemetryUpload(ok: r.ok, tries: 1, seconds: r.seconds, points: points.count)
            if r.count > 0 { telemetry.day(Self.dayString(Date())) { $0.add("pagesResent", Double(r.count)) } }
            if r.ok, let id = UInt16(exactly: r.value) { table.markStored(id) }
        }
        let timing = String(format: "Bluetooth link after %.1f s, handshake done after %.1f s", result.linkSeconds, result.readySeconds)
            + (result.rssi.map { ", signal \($0) dBm" } ?? "")
            + (result.links > 1 ? ", \(result.links) links" : "") + (result.restarts > 0 ? ", \(result.restarts) restarts" : "")
        if result.ok {
            log(String(format: "link: the relay did %@ in %.1f s (%@)", why, result.totalSeconds, timing))
            if steps.contains(where: { $0.op == .send(Command.power(true)) }) { relayOwesPowerOn = false }
            return result
        }
        log(String(format: "link: the relay couldn't do %@: %@ (after %.1f s; %@)", why, result.error, result.totalSeconds,
                   result.readySeconds > 0 ? timing : result.linkSeconds > 0 ? "linked, but the handshake never finished" : "no Bluetooth link"))
        if result.failedAtStep {
            if tolerate { return result }
            throw DriftError.relayJob(result.error, retry: false)
        }
        throw DriftError.relayJob(result.error, retry: true)
    }

    /// Asking for a drawing means "on": the step that un-pauses the table, if the power switch is off (or was,
    /// and the job that carried the step never reached the table).
    func relayWake() -> [RelayJob.Step] {
        if !switches.power {
            powerSetBySettings(true)
            relayOwesPowerOn = true
        }
        return relayOwesPowerOn ? [.init(.send(Command.power(true)))] : []
    }

    /// A look at the table: the relay links, takes the init dump and a running state, and lets go.
    func relayCheckIn() {
        guard !linkCheckInRunning else { return }
        linkCheckInRunning = true
        // Whatever comes of it, the next one is a full interval away: a table that's off, or in the HoMedics
        // app's hands, shouldn't be tried over and over.
        linkNextCheckIn = Date().addingTimeInterval(relaySettings.checkIn)
        Task { @MainActor in
            defer { self.linkCheckInRunning = false }
            _ = try? await self.relayRun("check-in", [])
        }
    }

    // MARK: The operations, as steps

    /// `show`: play it if a ring slot already holds it, else upload it into the least recently used slot and play.
    func relayShow(points: [WirePoint], hash: String, name: String, progress: @escaping (Double) -> Void) async throws -> [String: String] {
        let wake = relayWake()
        if let id = slots.slot(holding: hash), table.storedPatternIds.contains(id) {
            let r = try await relayRun("show", wake + [.init(.play(id))], tolerate: true)
            if r.ok {
                slots.touch(id)
                return ["id": "\(id)", "uploaded": "false", "hash": hash]
            }
            // Our picture of the table was from the last time we looked. Upload it again.
            log("show: the table didn't start \(id) (\(r.error)); uploading the drawing again")
        }
        // The slots to try, least recently used first, leaving out the one drawing when we last looked. If
        // that has changed and the table refuses one, the relay moves on to the next.
        let playing = table.tableState.flatMap { $0.status == 1 ? $0.patternId : nil }
        var skip = Set([playing].compactMap { $0 })
        var ids: [UInt16] = []
        while ids.count < SlotStore.ringIds.count {
            let id = slots.leastRecentlyUsed(excluding: skip)
            if skip.contains(id) { break }
            ids.append(id)
            skip.insert(id)
        }
        if ids.isEmpty { ids = [SlotStore.ringIds[0]] }
        let wakeNow = relayWake()
        let r = try await relayRun("show", wakeNow + [.init(.upload(points: points, ids: ids)), .init(.play(nil))],
                                   tolerate: true, progress: { progress($0 * 0.95) })
        let upload = r.steps.count > wakeNow.count ? r.steps[wakeNow.count] : nil
        // Record the slot before anything else, so another try just plays it.
        if let upload, upload.ok, let id = UInt16(exactly: upload.value) { slots.assign(id, hash: hash, name: name) }
        guard r.ok, let id = upload?.value else { throw DriftError.relayJob(r.error, retry: false) }
        return ["id": "\(id)", "uploaded": "true", "hash": hash]
    }

    /// The table's own playlist (Playlist.swift): write the list, wait for the table to list it back, and with
    /// `start` set loop on, random off and select it, which starts `first`. If the table doesn't confirm the
    /// list, or selecting it doesn't start `first`, play `first` directly.
    func relayTablePlaylist(_ ids: [UInt16], first: UInt16, start: Bool) async throws -> [String: String] {
        // Whether the playlist exists decides between creating and rewriting it: look first if we never have.
        if linkLastLinked == nil { try await relayRun("check-in", []) }
        let name = Self.tablePlaylistName
        let exists = table.tablePlaylists.contains { $0.name == name }
        if !exists && table.tablePlaylists.count >= Command.maxPlaylists {
            throw HTTPError(507, "the table already holds \(Command.maxPlaylists) playlists")
        }
        let write = exists ? Command.replacePlaylist(name, name: name, ids: ids) : Command.createPlaylist(name, ids: ids)
        // How the list shows up in the table's 0x30/3: name, NUL, count, ids.
        let listed = Array(name.utf8) + [0, UInt8(ids.count)] + ids.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let confirmed = RelayJob.Op.expect(.packet(command: 0x30, action: 3, contains: listed), timeout: 20)
        let written = ["playlist": name, "ids": ids.map(String.init).joined(separator: ",")]
        guard start else {
            do {
                try await relayRun("table playlist", [.init(.send(write)), .init(confirmed)])
            } catch DriftError.relayJob(_, retry: false) {
                throw DriftError.timeout("the table to save playlist \(name)")
            }
            playlist.tableWritten = Date()
            playlist.save()
            return written
        }
        let wake = relayWake()
        let at = wake.count
        let steps = wake + [
            .init(.send(write)),                                            // at
            .init(confirmed, onFail: at + 7),                               // at + 1
            .init(.send(Command.randomMode(false))),                        // the table's random never picks the first or last entry
            .init(.send(Command.loopMode(true))),
            .init(.send(Command.selectPlaylist(name))),
            .init(.expect(.drawing(first), timeout: 6), onFail: at + 7),    // at + 5
            .init(.end),
            .init(.play(first)),                                            // at + 7: straight to the pattern
        ]
        let r = try await relayRun("table playlist", steps, linger: 3)
        guard r.steps.count > at + 1, r.steps[at + 1].ok else {
            log("playlist: the table didn't confirm its playlist; played \(first) directly")
            return ["playlist": "not written", "id": "\(first)"]
        }
        playlist.tableWritten = Date()
        playlist.save()
        if r.steps.count > at + 7, r.steps[at + 7].ran { log("playlist: selecting the table playlist didn't start \(first); played it directly") }
        return written
    }

    // MARK: Telemetry

    /// One job handed to the relay. `result` nil: the relay never reported (unreachable, or it refused).
    func telemetryRelayJob(why: String, result: RelayJobResult?, error: String?, seconds: Double) {
        let stage = result.map { $0.ok ? "" : ($0.stage.isEmpty ? "other" : $0.stage) } ?? "relay"
        telemetry.day(Self.dayString(Date())) { d in
            d.add("rjobs")
            d.add("rjobWhy.\(why)")
            d.add("rjobSeconds", seconds)
            d.raise("rjobMax", seconds)
            if error != nil { d.add("rjobsFailed"); d.add("rjobFail.\(stage)") }
            guard let r = result else { return }
            if r.linkSeconds > 0 { d.add("rjobLinkN"); d.add("rjobLinkSeconds", r.linkSeconds); d.raise("rjobLinkMax", r.linkSeconds) }
            if r.readySeconds > 0 { d.add("rjobReadyN"); d.add("rjobReadySeconds", r.readySeconds); d.raise("rjobReadyMax", r.readySeconds) }
            if r.links > 1 { d.add("rjobRelinks", Double(r.links - 1)) }
            if r.restarts > 0 { d.add("rjobRestarts", Double(r.restarts)) }
            if r.truncated { d.add("rjobTruncated") }
            // Time the relay held the table: the nearest thing to "linked" when it works alone.
            d.add("s.job", r.totalSeconds)
            if let rssi = r.rssi { d.lower("tableMin", Double(rssi)); d.add("tableSum", Double(rssi)); d.add("tableN") }
        }
        var what = why
        if let r = result, r.readySeconds > 0 { what += String(format: ": table ready after %.1f s", r.readySeconds) }
        if let r = result, r.links > 1 || r.restarts > 0 { what += ", \(r.links) links, \(r.restarts) restarts" }
        if let error { what += ": \(error)" }
        telemetry.event("relay job", what, seconds: seconds, ok: error == nil)
    }
}
