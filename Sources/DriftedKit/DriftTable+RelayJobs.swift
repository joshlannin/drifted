import Foundation

/// A job the relay is doing for us, as far as we've heard.
final class RelayJobRun {
    enum Phase {
        /// Not with the relay (yet, or any more): to be sent from the start.
        case new
        /// The header and steps are sent; waiting for the relay to say it has them.
        case begun
        /// The pattern and "run" are sent; waiting for the relay to say it has it all.
        case handed
        /// The connection went during the hand-over; asked the relay how much it has.
        case asking
        /// The relay has the job: it runs whatever happens to the connection.
        case accepted
    }

    let id: UInt32
    let progress: (Double) -> Void
    var phase = Phase.new
    /// The relay's last word on this job: its state, and how much of the pattern it has (firmware 0.2.1).
    var state: String?
    var got: Int?
    /// The relay answered about some other job (or none): it doesn't have this one.
    var other = false
    /// We've asked where the job is since the relay accepted it.
    var queried = false
    var refusal: String?
    var result: [String: Any]?
    /// What the table said during the job, as the relay passes it on before the result.
    var tableBytes: [UInt8] = []
    var heard = Date()

    init(id: UInt32, progress: @escaping (Double) -> Void) {
        self.id = id
        self.progress = progress
    }
}

/// Jobs: table work the relay does by itself (RelayJob.swift; relay/README.md, "Jobs").
///
/// The connection to the relay is expected to fail while the relay has the table: its Wi-Fi is poor then. So a
/// job is handed over whole, and after that this side only waits. If the connection drops, whoever owns it
/// (drifted-host's supervisor) reconnects, and we ask the relay where the job is. The relay keeps the result
/// until the next job.
extension DriftTable {
    /// The relay can run jobs (firmware 0.2 and up). Known once it has accepted a connection.
    public var relayRunsJobs: Bool { viaRelay && (relayProto ?? 0) >= 2 }

    /// A job is with the relay now, or on its way there.
    public var relayJobRunning: Bool { relayJob.map { $0.phase != .new } ?? false }

    /// Hands `job` to the relay and waits for its result. One at a time: a second call waits for the first.
    ///
    /// Returns the relay's report whether or not the job succeeded. Throws `DriftError.relayJob` when there is
    /// no report: the relay couldn't be reached or refused the job. What the table said during the job (its
    /// pattern list, playlists, running state) is applied here as if it had just arrived.
    public func runRelayJob(_ job: RelayJob, progress: @escaping (Double) -> Void = { _ in }) async throws -> RelayJobResult {
        let previous = relayJobTail
        let task = Task { @MainActor () throws -> RelayJobResult in
            _ = await previous.value
            return try await self.relayJobNow(job, progress)
        }
        relayJobTail = Task { _ = try? await task.value }
        return try await task.value
    }

    /// The hand-over is in steps, each confirmed by the relay, because its Wi-Fi can be slow even at its best
    /// (a few KB/s where large packets get lost): header and steps, then the pattern, then "run". If the
    /// connection goes part-way, the relay is asked how much it has and the rest follows.
    private func relayJobNow(_ job: RelayJob, _ progress: @escaping (Double) -> Void) async throws -> RelayJobResult {
        guard viaRelay else { throw DriftError.relayJob("not using a relay", retry: false) }
        let id = UInt32.random(in: 1...UInt32.max)
        let run = RelayJobRun(id: id, progress: progress)
        relayJob = run
        defer { if relayJob === run { relayJob = nil } }
        let idBytes = [UInt8(id & 0xFF), UInt8(id >> 8 & 0xFF), UInt8(id >> 16 & 0xFF), UInt8(id >> 24)]
        let begin: [UInt8], blob: [UInt8]
        do {
            (begin, blob) = try job.encoded(id: id)
        } catch {
            throw DriftError.relayJob(error.localizedDescription, retry: false)
        }
        // Slow enough for the worst link seen (about 3 KB/s), on top of the job itself.
        let deadline = Date().addingTimeInterval(job.timeLimit + 60 + Double(blob.count) / 1000)
        var submits = 0, refetches = 0
        var sentOn: RelayLink?
        var since = Date()                 // when the current phase began
        var lastAsk = Date.distantPast
        var notBefore = Date.distantPast
        var down: Date?
        var ackLimit = 30.0
        var mayHaveRun = false             // "run" has been sent at some point: the relay may have started it
        var asks = 0

        /// Back to the start: hand the whole job over again. Not for a job that can't safely be done twice
        /// once the relay may have begun it.
        func startOver(_ why: String) throws {
            if mayHaveRun, !job.repeatable {
                throw DriftError.relayJob("\(why), and this can't safely be sent twice: it may or may not have reached the table", retry: false)
            }
            run.phase = .new
        }
        relay?.quietLimit = RelayLink.busyQuietLimit   // (until its next status: the hand-over itself can be slow)

        /// The pattern from `offset`, then "run".
        func sendRest(_ relay: RelayLink, from start: Int) async -> Bool {
            do {
                var offset = start
                while offset < blob.count {
                    let n = min(3600, blob.count - offset)
                    let at = UInt32(offset)
                    let head = idBytes + [UInt8(at & 0xFF), UInt8(at >> 8 & 0xFF), UInt8(at >> 16 & 0xFF), UInt8(at >> 24)]
                    try await relay.send(RelayFrame(.jobData, head + blob[offset..<(offset + n)]))
                    offset += n
                }
                try await relay.send(RelayFrame(.jobRun, idBytes))
            } catch {
                return false
            }
            mayHaveRun = true
            run.state = nil
            run.phase = .handed
            since = Date()
            ackLimit = 30 + Double(blob.count - start) / 1500
            return true
        }

        while Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let relay, relay.isOpen else {
                if down == nil { down = Date() }
                // Not with the relay yet: don't sit here; the caller decides whether to try again later. (Once
                // "run" has gone out the relay may be doing it: then we wait for word of it.)
                if !mayHaveRun, Date().timeIntervalSince(down!) > 60 { throw DriftError.relayJob("no connection to the relay", retry: true) }
                continue
            }
            down = nil

            if let j = run.result {
                guard let result = RelayJobResult(json: j) else { throw DriftError.relayJob("the relay's report couldn't be read", retry: true) }
                if run.tableBytes.count < result.tableBytes, refetches < 2 {
                    // Part of what the table said didn't reach us (we weren't connected when it was sent).
                    refetches += 1
                    run.result = nil
                    run.tableBytes = []
                    try? await relay.send(RelayFrame(.jobQuery))
                    lastAsk = Date()
                    continue
                }
                if run.tableBytes.count >= result.tableBytes { replayTable(Array(run.tableBytes.suffix(result.tableBytes))) }
                return result
            }
            if let why = run.refusal {
                run.refusal = nil
                run.phase = .new
                if why.contains("busy") {
                    notBefore = Date().addingTimeInterval(3)   // another job (an earlier one of ours, say): wait it out
                    submits = max(0, submits - 1)
                } else if why.contains("no such job") || why.contains("out of order") || why.contains("incomplete") || why.contains("intact") {
                    notBefore = Date().addingTimeInterval(1)   // it arrived damaged or in pieces: send it again
                } else if why.contains("settling") {
                    notBefore = Date().addingTimeInterval(20)  // just updated: its spare flash isn't free yet
                    submits = max(0, submits - 1)
                } else {
                    throw DriftError.relayJob("the relay refused the job: \(why)", retry: false)
                }
            }

            switch run.phase {
            case .new:
                guard Date() >= notBefore else { continue }
                guard submits < 6 else { throw DriftError.relayJob("couldn't hand the job to the relay", retry: true) }
                submits += 1
                run.state = nil
                run.got = nil
                run.other = false
                run.queried = false
                run.result = nil
                run.tableBytes = []
                guard (try? await relay.send(RelayFrame(.jobBegin, begin))) != nil else {
                    notBefore = Date().addingTimeInterval(1)
                    continue
                }
                run.phase = .begun
                run.heard = Date()
                sentOn = relay
                since = Date()

            case .begun:
                if relay !== sentOn {
                    run.phase = .new
                } else if run.state == "receiving" {
                    if !(await sendRest(relay, from: 0)) { run.phase = .new; notBefore = Date().addingTimeInterval(1) }
                } else if Date().timeIntervalSince(since) > 20 {
                    note("The relay didn't confirm the job's steps in 20 s; sending them again")
                    run.phase = .new
                }

            case .handed:
                if relay !== sentOn {
                    // The connection went before the relay said it had everything: ask what it has.
                    sentOn = relay
                    run.state = nil
                    run.got = nil
                    run.other = false
                    run.phase = .asking
                    since = Date()
                    try? await relay.send(RelayFrame(.jobQuery))
                } else if Date().timeIntervalSince(since) > ackLimit {
                    // It may have it and be busy with the table: ask before sending anything twice.
                    note("The relay didn't confirm the job in \(Int(ackLimit)) s; asking where it is")
                    run.state = nil
                    run.got = nil
                    run.other = false
                    run.phase = .asking
                    since = Date()
                    try? await relay.send(RelayFrame(.jobQuery))
                }

            case .asking:
                if relay !== sentOn {
                    sentOn = relay
                    since = Date()
                    try? await relay.send(RelayFrame(.jobQuery))
                } else if run.state == "receiving", let got = run.got, got <= blob.count {
                    note("The relay has \(got) of \(blob.count) bytes of the pattern; sending the rest")
                    if !(await sendRest(relay, from: got)) { run.phase = .new; notBefore = Date().addingTimeInterval(1) }
                } else if run.state == "receiving" || run.state == "idle" {
                    run.phase = .new   // it has the steps but can't say how much of the pattern (or nothing): it hasn't run; from the start
                } else if run.other {
                    try startOver("the relay no longer has the job")
                } else if Date().timeIntervalSince(since) > 20 {
                    // No answer. Ask again for a while (it keeps the answer until the next job), then start over.
                    since = Date()
                    asks += 1
                    if asks > 6 { asks = 0; try startOver("the relay doesn't say where the job is") } else { try? await relay.send(RelayFrame(.jobQuery)) }
                }

            case .accepted:
                if run.other, run.queried {
                    note("The relay no longer has the job (did it restart?); sending it again")
                    try startOver("the relay lost the job (did it restart?)")
                } else if relay !== sentOn || Date().timeIntervalSince(max(lastAsk, run.heard)) > 8 {
                    // A new connection (the last one died while the relay was busy with the table), or a long
                    // silence: ask where the job is. If it has finished, the answer is its result.
                    sentOn = relay
                    lastAsk = Date()
                    run.other = false
                    run.queried = true
                    try? await relay.send(RelayFrame(.jobQuery))
                }
            }
        }
        throw DriftError.relayJob("no word from the relay about the job in \(Int(job.timeLimit)) s", retry: !mayHaveRun || job.repeatable)
    }

    func relayJobState(_ j: [String: Any]) {
        guard let run = relayJob, let id = (j["job"] as? Int).flatMap({ UInt32(exactly: $0) }) else { return }
        let state = (j["state"] as? String) ?? ""
        guard id == run.id else {
            if state != "refused" { run.other = true }
            return
        }
        run.heard = Date()
        if state == "refused" {
            run.refusal = (j["error"] as? String) ?? "refused"
            return
        }
        run.state = state
        run.got = j["got"] as? Int
        if ["queued", "linking", "handshake", "running", "done"].contains(state) {
            if run.phase != .new { run.phase = .accepted }
        } else if run.phase == .accepted {
            run.other = true   // "receiving" or nothing, for a job it had accepted: it has lost it
        }
        if let p = j["progress"] as? Int, state == "running" { run.progress(min(0.99, Double(p) / 100)) }
    }

    func relayJobResult(_ j: [String: Any]) {
        guard let run = relayJob, run.phase != .new, (j["job"] as? Int).flatMap({ UInt32(exactly: $0) }) == run.id else { return }
        run.heard = Date()
        run.phase = .accepted
        run.result = j
    }

    func relayJobTableData(_ id: UInt32, _ bytes: [UInt8]) {
        guard let run = relayJob, id == run.id else { return }
        run.heard = Date()
        run.tableBytes += bytes
    }

    /// The relay's status, every 5 s: the only progress report during a long upload.
    func relayJobStatus(_ s: RelayStatus) {
        guard let run = relayJob, run.phase == .accepted, s.jobId == run.id else { return }
        run.heard = Date()
        if s.jobState == "running", let p = s.jobProgress { run.progress(min(0.99, Double(p) / 100)) }
    }

    /// Applies what the table said while the relay had it: the same packets, handled as if they'd just come in,
    /// except that nothing is answered and the connection status stays as it is.
    func replayTable(_ bytes: [UInt8]) {
        var parser = PacketParser()
        replaying = true
        defer { replaying = false }
        for packet in parser.feed(bytes) { handle(packet) }
    }
}
