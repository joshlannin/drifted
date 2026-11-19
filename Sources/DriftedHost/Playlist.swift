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
    var file: URL?

    enum CodingKeys: String, CodingKey { case active, shuffle, ids, queue, current, pausedBy }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? true
        ids = try c.decodeIfPresent([UInt16].self, forKey: .ids) ?? []
        queue = try c.decodeIfPresent([UInt16].self, forKey: .queue) ?? []
        current = try c.decodeIfPresent(UInt16.self, forKey: .current)
        pausedBy = try c.decodeIfPresent(String.self, forKey: .pausedBy)
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
        if s.status == 1, s.patternId != 0, playlist.current != s.patternId, playlistPool().contains(s.patternId) {
            playlist.current = s.patternId
            playlist.save()
        }
    }

    /// Runs every few seconds: starts the next pattern once the table has been finished for a while.
    func playlistTick() {
        guard playlist.active, playlist.pausedBy == nil, switches.power, !liveRunning, table.status == .ready,
              let since = playlistIdleSince, Date().timeIntervalSince(since) >= Self.playlistIdleSeconds,
              Date().timeIntervalSince(playlistLastStart) >= 30, !playlistJobPending else { return }
        playlistAdvance("the table finished")
    }

    var playlistJobPending: Bool {
        guard let id = playlistJob, let j = job(id) else { return false }
        return j.state == .queued || j.state == .running
    }

    /// The ids the playlist draws from, as stored on the table now.
    func playlistPool() -> [UInt16] {
        let stored = table.storedPatternIds
        if playlist.ids.isEmpty { return stored.filter { !SlotStore.ringIds.contains($0) }.sorted() }
        return playlist.ids.filter { stored.contains($0) }
    }

    private func playlistNextId() -> UInt16? {
        let pool = playlistPool()
        guard !pool.isEmpty else { return nil }
        guard playlist.shuffle else {
            let i = playlist.current.flatMap { pool.firstIndex(of: $0) }.map { ($0 + 1) % pool.count } ?? 0
            return pool[i]
        }
        playlist.queue.removeAll { !pool.contains($0) }
        if playlist.queue.isEmpty {
            playlist.queue = pool.shuffled()
            // Don't repeat the pattern that just finished at the start of a new round.
            if pool.count > 1, playlist.queue.last == playlist.current { playlist.queue.swapAt(0, playlist.queue.count - 1) }
        }
        return playlist.queue.popLast()
    }

    /// Starts the next pattern. Returns nil if there's nothing to play.
    @discardableResult
    func playlistAdvance(_ why: String) -> Job? {
        playlist.pausedBy = nil
        guard let id = playlistNextId() else {
            log("playlist: nothing to play (no stored patterns match)")
            playlist.save()
            return nil
        }
        playlist.current = id
        playlist.save()
        playlistLastStart = Date()
        log("playlist: \(why); playing \(id)\(slots.name(of: id).map { " (\($0))" } ?? "")")
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
        if let a = input.active {
            playlist.active = a
            playlist.pausedBy = nil
            playlistLastStart = .distantPast
        }
        playlist.save()
        log("playlist: \(playlist.active ? "on" : "off"), \(playlist.shuffle ? "shuffle" : "in order"), "
            + "\(playlist.ids.isEmpty ? "all stored patterns" : "\(playlist.ids.count) ids")")
        emit("playlist", playlistJSON())
    }

    func playlistJSON() -> [String: Any] {
        let pool = playlistPool()
        var out: [String: Any] = ["active": playlist.active, "shuffle": playlist.shuffle,
                                  "ids": playlist.ids.map(Int.init), "patterns": pool.count]
        if let c = playlist.current { out["current"] = Int(c) }
        if let p = playlist.pausedBy { out["holding"] = p }
        if playlist.shuffle { out["leftThisRound"] = playlist.queue.filter(pool.contains).count }
        return out
    }
}
