import DriftedKit
import Foundation

/// Linking on demand, through a relay (relay.json `"link": "onDemand"`).
///
/// The relay has one 2.4 GHz radio for Wi-Fi and Bluetooth. While it holds the table's Bluetooth link its Wi-Fi
/// stalls for a second or two every few seconds (measured: with the table linked 17% of pings took over a
/// second; with it released, none), and the connection to this host drops again and again. The table doesn't
/// need a host to keep drawing, or to run its own playlist. So here the relay holds the table only while there
/// is work for it: a job (a drawing, a setting, a switch, the schedule's steps), a live session, or a short
/// check-in every `checkInMinutes` for fresh status. The rest of the time the relay connection stays up with the
/// table released (`DriftTable.Status.standby`), which is also when the HoMedics app can connect.
///
/// What it costs: something sent while standing by first waits for the relay to reach the table (some seconds),
/// and /status describes the table as of the last time it was linked (`stateAt`).
extension Daemon {
    /// A wake that hasn't reached ready by now is abandoned (the relay gives a Bluetooth connect 10 s per try).
    static let linkWakeTimeout: TimeInterval = 75
    /// How long a check-in keeps the table: long enough for the init dump and a few state broadcasts.
    static let linkCheckInLinger: TimeInterval = 8

    var linkOnDemand: Bool { table.viaRelay && relaySettings.onDemand }

    /// Why the table link is needed right now, or nil when the relay can let go of it.
    func linkNeed(now: Date = Date()) -> String? {
        if live != nil || liveStarting { return "live" }
        if let j = jobs.values.filter({ $0.state == .queued || $0.state == .running }).min(by: { $0.id < $1.id }) { return j.kind }
        // Without the table's own playlist, drifted-host starts each pattern itself and has to see the last one end.
        if playlist.active, !playlist.onTable, playlist.pausedBy == nil, switches.power { return "playlist" }
        // Linked and the table has stopped with the playlist on: stay until playlistTick has started the next one.
        if table.status == .ready, playlistIdleSince != nil, playlist.active, playlist.pausedBy == nil, switches.power { return "playlist" }
        if now >= linkNextCheckIn { return "check-in" }
        return nil
    }

    /// One pass of supervise() in on-demand mode (twice a second).
    func superviseOnDemand() async {
        let need = linkNeed()
        switch table.status {
        case .ready:
            linkBusySince = nil
            if need == "check-in" {
                // Already linked, which is all a check-in is.
                linkNextCheckIn = Date().addingTimeInterval(relaySettings.checkIn)
                linkLingerUntil = max(linkLingerUntil, Date().addingTimeInterval(Self.linkCheckInLinger))
            } else if need != nil {
                linkLingerUntil = max(linkLingerUntil, Date().addingTimeInterval(relaySettings.linger))
            } else if Date() >= linkLingerUntil {
                log("link: nothing more to do; standing by (the relay lets go of the table)")
                table.relayStandby()
            }
        case .standby:
            linkBusySince = nil
            guard let need else { break }
            if relayJobs, !Self.linkNeedsLive(need) {
                // The relay does this by itself (RelayJobs.swift). Queued jobs hand themselves over; a
                // check-in is ours to start.
                if need == "check-in" { relayCheckIn() }
            } else {
                await linkWake(need)
            }
        case .connecting, .handshaking, .scanning:
            // Something else started this (Choose table, a switch of mode). Give it the same time as a wake.
            if table.status == .scanning { linkBusySince = nil; break }
            if let since = linkBusySince {
                if Date().timeIntervalSince(since) > Self.linkWakeTimeout {
                    linkBusySince = nil
                    table.abandonConnection("not ready after \(Int(Self.linkWakeTimeout)) s")
                }
            } else {
                linkBusySince = Date()
            }
        default:
            linkBusySince = nil
            // Not connected to the relay. Unless the work has to be done live, connect without taking the
            // table: the relay's welcome says whether it runs jobs (it may have been updated since we last
            // spoke), and from standing by the next pass hands the work over or takes the table.
            if let need, relaySettings.jobs == false || Self.linkNeedsLive(need) {
                await linkWake(need)
            } else {
                await linkStandBy()
            }
        }
    }

    /// Has the relay take the table and waits for the handshake to finish.
    private func linkWake(_ why: String) async {
        let start = Date()
        let from = table.status == .standby ? "standby" : "down"
        log("link: taking the table (\(why))")
        table.connectRelay()
        let ok = await table.waitUntilReady(timeout: Self.linkWakeTimeout)
        let seconds = Date().timeIntervalSince(start)
        var failure: String?
        if ok {
            log(String(format: "link: ready in %.1f s, %d patterns stored", seconds, table.storedPatternIds.count))
        } else {
            if case .disconnected(let reason) = table.status { failure = reason ?? "disconnected" } else { failure = "not ready after \(Int(Self.linkWakeTimeout)) s" }
            table.abandonConnection(failure!)
            log(String(format: "link: couldn't take the table in %.0f s (%@)", seconds, failure!))
            // A check-in isn't worth holding the radio for, or another try straight away: the table may be off,
            // the HoMedics app may have it, or the relay's Wi-Fi is having a bad hour, and every handshake cut
            // short risks leaving the table stuck mid-way (it then needs a host on Bluetooth, or a power cycle).
            // Jobs keep trying until they give up themselves.
            if why == "check-in" { linkNextCheckIn = Date().addingTimeInterval(relaySettings.checkIn) }
        }
        telemetryWake(why: why, from: from, seconds: seconds, error: failure)
        if !ok { try? await Task.sleep(nanoseconds: 3_000_000_000) }   // don't hammer a relay that isn't answering
    }

    /// Opens the relay connection without taking the table.
    private func linkStandBy() async {
        table.relayStandby()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, table.status == .connecting { try? await Task.sleep(nanoseconds: 100_000_000) }
        if table.status == .connecting { table.abandonConnection("no answer from the relay") }
        if table.status != .standby { try? await Task.sleep(nanoseconds: 3_000_000_000) }
    }

    /// Every status change (before `table.status` itself changes).
    func linkStatusChanged(_ s: DriftTable.Status) {
        if s == .ready {
            // Any link is as good as a check-in: the init dump and the state broadcasts bring everything up to date.
            linkLastLinked = Date()
            linkNextCheckIn = Date().addingTimeInterval(relaySettings.checkIn)
            linkLingerUntil = max(linkLingerUntil, Date().addingTimeInterval(Self.linkCheckInLinger))
        } else if telemetryStatus == .ready {
            linkLastLinked = Date()
        }
        telemetryStatusChanged(to: s)
    }
}
