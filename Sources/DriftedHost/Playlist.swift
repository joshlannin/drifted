import DriftedKit
import Foundation

/// drifted-host's own playlist. The table's random and loop modes cycle a playlist the HoMedics app set up;
/// when that's empty or gone (after deleting patterns, for one) the table stops after a single pattern. So
/// while the playlist is on, drifted-host starts the next pattern itself whenever the table finishes one.
struct Playlist: Codable {
    var active = false
    var shuffle = true
    /// Pattern ids to play. Empty means every stored pattern except the `show` slots.
    var ids: [UInt16] = []
    /// Shuffle order: what's left to play this round (played from the end).
    var queue: [UInt16] = []
    /// The playlist pattern drawing now, or last.
    var current: UInt16?
    /// Set when something drawn on request should stay on the sand ("show", "live"). The playlist carries on
    /// after `next`, or `PUT /playlist {"active": true}`.
    var pausedBy: String?
    /// Keep the shuffle on the table itself: each advance writes the next picks (at most 20) as the table's own
    /// playlist and starts it with loop on, so the table carries on with no host in range.
    var onTable = true
    /// What was last written to the table's playlist.
    var tableIds: [UInt16] = []
    var tableWritten: Date?
    var file: URL?

    enum CodingKeys: String, CodingKey { case active, shuffle, ids, queue, current, pausedBy, onTable, tableIds, tableWritten }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? true
        ids = try c.decodeIfPresent([UInt16].self, forKey: .ids) ?? []
        queue = try c.decodeIfPresent([UInt16].self, forKey: .queue) ?? []
        current = try c.decodeIfPresent(UInt16.self, forKey: .current)
        pausedBy = try c.decodeIfPresent(String.self, forKey: .pausedBy)
        onTable = try c.decodeIfPresent(Bool.self, forKey: .onTable) ?? false   // existing setups opt in with PUT /playlist
        tableIds = try c.decodeIfPresent([UInt16].self, forKey: .tableIds) ?? []
        tableWritten = try c.decodeIfPresent(Date.self, forKey: .tableWritten)
    }

    static func load(_ file: URL) -> Playlist {
        var p = (try? JSONDecoder().decode(Playlist.self, from: Data(contentsOf: file))) ?? Playlist()
        p.file = file
        return p
    }

    func save() {
        guard let file else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: file, options: .atomic)
    }
}

struct PlaylistInput: Decodable {
    var active: Bool?
    var shuffle: Bool?
    var ids: [Int]?
    var onTable: Bool?
}

extension Daemon {
    /// How long the table must sit finished before the next pattern starts. The table's own loop, when it
    /// works, starts the next one within about a second, so this never races it.
    static let playlistIdleSeconds: TimeInterval = 8

    /// Called with every state broadcast (about 2 Hz).
    func playlistObserve(_ s: TableState) {
        // Finished = pattern 0 and not drawing. Paused (power off, the table's button) keeps its pattern id.
        if s.patternId == 0 && s.status != 1 {
            if playlistIdleSince == nil { playlistIdleSince = Date() }
        } else {
            playlistIdleSince = nil
        }
        if s.status == 1, s.patternId != 0, playlist.current != s.patternId,
           playlistPool().contains(s.patternId) || seasonPool().ids.contains(s.patternId) {
            playlist.current = s.patternId
            playlist.save()
            // The table moved on by itself (its own playlist): the season lamp steps as it would for ours.
            if playlist.onTable, s.playlistId == Self.tablePlaylistName, Date().timeIntervalSince(playlistLastStart) > 15 {
                log("playlist: the table moved on to \(s.patternId)\(slots.name(of: s.patternId).map { " (\($0))" } ?? "")")
                syncSeasonLamp(advance: true)
                emit("playlist", playlistJSON())
            }
        }
    }

    /// Runs every few seconds: starts the next pattern once the table has been finished for a while.
    func playlistTick() {
        guard playlist.active, playlist.pausedBy == nil, switches.power, !liveRunning, tableUsable,
              let since = playlistIdleSince, Date().timeIntervalSince(since) >= Self.playlistIdleSeconds,
              Date().timeIntervalSince(playlistLastStart) >= 30, !playlistJobPending else { return }
        playlistAdvance("the table finished")
    }

    var playlistJobPending: Bool {
        guard let id = playlistJob, let j = job(id) else { return false }
        return j.state == .queued || j.state == .running
    }

    /// The ids the playlist draws from, as stored on the table now. "Every stored pattern" leaves out the show
    /// slots and any id a schedule season lists (those play only in season, mixed in by `playlistNextId`).
    func playlistPool() -> [UInt16] {
        let stored = table.storedPatternIds
        if playlist.ids.isEmpty {
            let seasonal = schedule.seasonIds
            return stored.filter { !SlotStore.ringIds.contains($0) && !seasonal.contains($0) }.sorted()
        }
        return playlist.ids.filter { stored.contains($0) }
    }

    private func playlistNextId() -> UInt16? {
        let pool = playlistPool()
        // In a season, its patterns take `weight` of the picks: credit builds by weight per pick and each whole
        // point is spent on a seasonal one (0.5 = every other pattern, 1 = only seasonal).
        let (seasonal, weight) = seasonPool()
        if !seasonal.isEmpty, weight > 0 {
            seasonCredit += weight
            if seasonCredit >= 1 - 1e-9 || pool.isEmpty {
                seasonCredit = max(0, seasonCredit - 1)
                return Self.nextShuffled(seasonal, queue: &seasonQueue, current: playlist.current)
            }
        }
        guard !pool.isEmpty else { return nil }
        guard playlist.shuffle else {
            let i = playlist.current.flatMap { pool.firstIndex(of: $0) }.map { ($0 + 1) % pool.count } ?? 0
            return pool[i]
        }
        return Self.nextShuffled(pool, queue: &playlist.queue, current: playlist.current)
    }

    /// Shuffle without repeats: plays `queue` from the end, refilling it with the pool when it runs out.
    private static func nextShuffled(_ pool: [UInt16], queue: inout [UInt16], current: UInt16?) -> UInt16? {
        queue.removeAll { !pool.contains($0) }
        if queue.isEmpty {
            queue = pool.shuffled()
            // Don't repeat the pattern that just finished at the start of a new round.
            if pool.count > 1, queue.last == current { queue.swapAt(0, queue.count - 1) }
        }
        return queue.popLast()
    }

    /// Starts the next pattern. Returns nil if there's nothing to play.
    @discardableResult
    func playlistAdvance(_ why: String) -> Job? {
        playlist.pausedBy = nil
        if playlist.onTable { return tablePlaylistWrite(why, start: true) }
        guard let id = playlistNextId() else {
            log("playlist: nothing to play (no stored patterns match)")
            playlist.save()
            return nil
        }
        playlist.current = id
        playlist.save()
        playlistLastStart = Date()
        log("playlist: \(why); playing \(id)\(slots.name(of: id).map { " (\($0))" } ?? "")")
        syncSeasonLamp(advance: true)
        let job = play(id)
        playlistJob = job.id
        emit("playlist", playlistJSON())
        return job
    }

    /// Something was drawn on request: keep it on the sand instead of playing over it when it finishes.
    func playlistHold(_ reason: String) {
        guard playlist.active, playlist.pausedBy != reason else { return }
        playlist.pausedBy = reason
        playlist.save()
        // The table's own loop would move on after the drawing; loop goes back on when the playlist carries on.
        if playlist.onTable { _ = command("loop off", [Command.loopMode(false)]) }
        log("playlist: holding (\(reason)); it carries on after next or PUT /playlist {\"active\": true}")
        emit("playlist", playlistJSON())
    }

    func setPlaylist(_ input: PlaylistInput) throws {
        if let ids = input.ids {
            guard ids.allSatisfy({ UInt16(exactly: $0) != nil }) else { throw HTTPError(400, "ids must be pattern ids (0-65535)") }
            playlist.ids = ids.compactMap { UInt16(exactly: $0) }
            playlist.queue = []
        }
        if let s = input.shuffle, s != playlist.shuffle { playlist.shuffle = s; playlist.queue = [] }
        let wasTable = playlist.active && playlist.onTable
        if let t = input.onTable { playlist.onTable = t }
        if let a = input.active {
            playlist.active = a
            playlist.pausedBy = nil
            playlistLastStart = .distantPast
        }
        playlist.save()
        // Leaving table mode: stop the table's own loop so drifted-host's tick is the only thing that advances.
        if wasTable && !(playlist.active && playlist.onTable) { _ = command("loop off", [Command.loopMode(false)]) }
        // Entering it: write the list now; it starts at the next advance, so nothing on the sand is drawn over.
        if !wasTable && playlist.active && playlist.onTable { tablePlaylistWrite("table playlist on", start: false) }
        log("playlist: \(playlist.active ? "on" : "off"), \(playlist.shuffle ? "shuffle" : "in order"), "
            + "\(playlist.ids.isEmpty ? "all stored patterns" : "\(playlist.ids.count) ids")")
        emit("playlist", playlistJSON())
    }

    func playlistJSON() -> [String: Any] {
        let pool = playlistPool()
        var out: [String: Any] = ["active": playlist.active, "shuffle": playlist.shuffle,
                                  "ids": playlist.ids.map(Int.init), "patterns": pool.count, "onTable": playlist.onTable]
        var onTable: [String: Any] = ["name": Self.tablePlaylistName, "ids": playlist.tableIds.map(Int.init),
                                      "current": table.tableState?.playlistId ?? NSNull(),
                                      "stored": table.tablePlaylists.map { ["name": $0.name, "count": $0.ids.count] as [String: Any] }]
        if let w = playlist.tableWritten { onTable["written"] = ISO8601DateFormatter().string(from: w) }
        out["table"] = onTable
        if let c = playlist.current { out["current"] = Int(c) }
        if let p = playlist.pausedBy { out["holding"] = p }
        if playlist.shuffle { out["leftThisRound"] = playlist.queue.filter(pool.contains).count }
        let seasonal = seasonPool().ids
        if !seasonal.isEmpty { out["seasonPatterns"] = seasonal.count }
        return out
    }

    // MARK: The table's own playlist

    /// Ours, on the table. Short and plain (Command.isSafePlaylistName).
    static let tablePlaylistName = "drifted_mix"

    /// The next picks for the table's playlist: up to 20, in play order, from the same shuffle (and seasons).
    func playlistNextBatch() -> [UInt16] {
        var out: [UInt16] = []
        let seasonal = Set(seasonPool().ids)
        var tries = 0
        while out.count < Command.maxPlaylistIds, tries < 4 * Command.maxPlaylistIds {
            tries += 1
            guard let id = playlistNextId() else { break }
            playlist.current = id   // in-order mode steps from the last pick
            // Everyday patterns once per list; seasonal ones may repeat, never back to back.
            if id == 0 || id == out.last || (out.contains(id) && !seasonal.contains(id)) { continue }
            out.append(id)
        }
        return out
    }

    /// Writes the next picks to the table as `drifted_mix` and, with `start`, starts it (loop on, random off).
    @discardableResult
    func tablePlaylistWrite(_ why: String, start: Bool) -> Job? {
        let before = playlist.current
        let batch = playlistNextBatch()
        guard let first = batch.first else {
            playlist.current = before
            log("playlist: nothing to play (no stored patterns match)")
            playlist.save()
            return nil
        }
        playlist.current = start ? first : before
        playlist.tableIds = batch
        playlist.save()
        if start { playlistLastStart = Date() }
        log("playlist: \(why); writing \(batch.count) patterns to the table's playlist \(Self.tablePlaylistName)"
            + (start ? ", starting with \(first)\(slots.name(of: first).map { " (\($0))" } ?? "")" : ""))
        if start { syncSeasonLamp(advance: true) }
        let job = enqueue("table playlist") { _ in
            if self.viaRelayJob { return try await self.relayTablePlaylist(batch, first: first, start: start) }
            if start { try await self.wakeForDrawing() }
            do {
                try await self.writeTablePlaylist(batch)
            } catch DriftError.timeout(let what) where start {
                // Keep drawing even if the table didn't take the list; drifted-host's own tick carries on.
                self.log("playlist: the table didn't confirm its playlist (\(what)); playing \(first) directly")
                try await self.table.play(first)
                return ["playlist": "not written", "id": "\(first)"]
            }
            self.playlist.tableWritten = Date()
            self.playlist.save()
            if start { try await self.startTablePlaylist(first) }
            return ["playlist": Self.tablePlaylistName, "ids": batch.map(String.init).joined(separator: ",")]
        }
        if start { playlistJob = job.id }
        emit("playlist", playlistJSON())
        return job
    }

    /// Writes the list and waits for the table to re-send its playlists with it saved.
    private func writeTablePlaylist(_ ids: [UInt16]) async throws {
        let name = Self.tablePlaylistName
        let exists = table.tablePlaylists.contains { $0.name == name }
        if !exists && table.tablePlaylists.count >= Command.maxPlaylists {
            throw HTTPError(507, "the table already holds \(Command.maxPlaylists) playlists")
        }
        let m = table.mark()
        try await table.send(exists ? Command.replacePlaylist(name, name: name, ids: ids) : Command.createPlaylist(name, ids: ids))
        let want = TablePlaylist(name: name, ids: ids)
        _ = try await table.waitFor(after: m, timeout: 20, what: "the table to save playlist \(name)") { msg -> Bool? in
            if case .playlists(_, let lists) = msg, lists.contains(want) { return true }
            return nil
        }
    }

    /// Loop on, random off (the table's random never picks the first or last entry), then select: that
    /// starts the list's first pattern. Falls back to a plain play if the table doesn't start it.
    private func startTablePlaylist(_ first: UInt16) async throws {
        if let s = table.tableState {
            if s.randomMode { try await table.send(Command.randomMode(false)) }
            if !s.loopMode { try await table.send(Command.loopMode(true)) }
        } else {
            try await table.send(Command.randomMode(false))
            try await table.send(Command.loopMode(true))
        }
        let m = table.mark()
        try await table.send(Command.selectPlaylist(Self.tablePlaylistName))
        do {
            _ = try await table.waitFor(after: m, timeout: 6, what: "the table playlist to start") { msg -> Bool? in
                if case .state(let s) = msg, s.status == 1, s.patternId == first { return true }
                return nil
            }
        } catch DriftError.timeout {
            log("playlist: selecting the table playlist didn't start \(first); playing it directly")
            try await table.play(first)
        }
    }
}
