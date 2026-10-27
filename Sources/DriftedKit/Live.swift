import Foundation

/// Keeps the table drawing a stream of pushed segments (drifted-host's live mode).
///
/// Two slots, overwritten in place: one draws while the other holds the next segment. The table refuses
/// uploads to the playing id, so the non-playing slot is always free for the next segment or an interrupt.
/// Validated on hardware 2026-10-25: 12 × 28 s segments, no errors, ~1 s joins (see docs/behaviour.md).
@MainActor
public final class LiveSession {
    public enum Event: Sendable {
        case started
        case queued(segment: Int, slot: UInt16, points: Int, uploadSeconds: Double)
        case playing(segment: Int, slot: UInt16)
        case finished(segment: Int, drewSeconds: Double)
        case starved                       // nothing left to draw; the ball rests until the next push
        case warning(String)
        case error(String)
        case stopped
    }

    struct Segment {
        var index: Int
        var points: [PolarPoint]
        var interrupt: Bool
    }

    struct Slot {
        var id: UInt16
        var segment: Segment
        var playedAt: Date?
        var seenDrawing = false
        var lastProgress = -1.0
        var progressChanged = Date()
    }

    let table: DriftTable
    public let slotIds: [UInt16]
    public var onEvent: (Event) -> Void = { _ in }
    /// Prepend a straight connector from where the ball is to each segment's start, so the path between
    /// segments is ours (the table's own move is one long (theta, rho) arc, ~14 s from the rim).
    public var connectors = true
    /// Segments shorter than this risk the table going idle before the next upload lands.
    public var minimumSegmentSeconds = 8.0

    private var pending: [Segment] = []
    private var queued: Slot?
    private var playing: Slot?
    private var tail: PolarPoint?            // where the last uploaded segment ends
    private var nextIndex = 0
    private var savedModes: (random: Bool, loop: Bool)?
    private var pump: Task<Void, Never>?
    private var starvedSent = true          // nothing to report until something has played
    private var generation = 0               // bumped by interrupts; an upload begun before one is discarded

    public init(table: DriftTable, slotIds: [UInt16] = [50900, 50901]) {
        precondition(slotIds.count >= 2, "live mode needs at least two slots")
        self.table = table
        self.slotIds = slotIds
    }

    public var isRunning: Bool { pump != nil }
    /// Segments waiting (not yet uploaded) plus one uploaded but not yet playing.
    public var depth: Int { pending.count + (queued == nil ? 0 : 1) }

    public func start() async throws {
        guard pump == nil else { return }
        if let s = table.tableState { savedModes = (s.randomMode, s.loopMode) }
        // Random mode would start a stock pattern in the gap between segments.
        try await table.send(Command.randomMode(false))
        try await table.send(Command.loopMode(false))
        onEvent(.started)
        pump = Task { [weak self] in await self?.run() }
    }

    /// Queues a segment. `interrupt` drops anything queued and cuts in as soon as it is uploaded.
    @discardableResult
    public func push(_ points: [PolarPoint], interrupt: Bool = false) -> Int {
        let report = PatternValidator.validate(SandPattern(name: "live", points: points))
        for issue in report.issues where issue.severity != .fixed { onEvent(.warning("segment \(nextIndex): \(issue.message)")) }
        if report.stats.estimatedSeconds < minimumSegmentSeconds && !interrupt {
            onEvent(.warning(String(format: "segment %d draws in about %.1f s; under %.0f s the table may idle between segments",
                                    nextIndex, report.stats.estimatedSeconds, minimumSegmentSeconds)))
        }
        let seg = Segment(index: nextIndex, points: report.pattern.points, interrupt: interrupt)
        nextIndex += 1
        if interrupt { pending = [seg]; queued = nil; generation += 1 } else { pending.append(seg) }
        starvedSent = false
        return seg.index
    }

    public func stop() async {
        pump?.cancel(); pump = nil
        pending = []; queued = nil
        if let m = savedModes {
            try? await table.send(Command.randomMode(m.random))
            try? await table.send(Command.loopMode(m.loop))
        }
        onEvent(.stopped)
    }

    // MARK: Pump

    private func run() async {
        while !Task.isCancelled {
            do {
                try await step()
            } catch is CancellationError {
                return
            } catch {
                onEvent(.error("\(error.localizedDescription)"))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func step() async throws {
        // 1. Upload the next segment into the free slot.
        if queued == nil, let seg = pending.first {
            pending.removeFirst()
            let slot = slotIds.first { $0 != playing?.id }!
            var points = seg.points
            let from = seg.interrupt ? ballEstimate() : tail
            if let from {
                if connectors, let first = points.first { points = connector(from, first) + points }
                points = aligned(points, after: from.theta)
            }
            let began = Date(), gen = generation
            try await table.upload(SandPattern(name: "live\(seg.index)", points: points).wirePoints, id: slot)
            guard gen == generation else { return }   // an interrupt arrived mid-upload; it goes next
            tail = seg.points.last
            queued = Slot(id: slot, segment: Segment(index: seg.index, points: points, interrupt: seg.interrupt))
            onEvent(.queued(segment: seg.index, slot: slot, points: points.count, uploadSeconds: Date().timeIntervalSince(began)))
            if seg.interrupt { try await playQueued() }
        }

        // 2. Track the playing segment.
        if var cur = playing, let s = table.tableState {
            let sinceStart = Date().timeIntervalSince(cur.playedAt ?? Date())
            if s.patternId == cur.id && s.status == 1 {
                // No "won't open" check here: right after a chained play the broadcast still shows the
                // previous segment's 100%, so that signature misfires (hardware, 2026-10-25). A file that
                // really won't open shows up as frozen progress and is caught by the stall check below.
                cur.seenDrawing = true
                if s.progress != cur.lastProgress { cur.lastProgress = s.progress; cur.progressChanged = Date() }
                if Date().timeIntervalSince(cur.progressChanged) > 30 {
                    onEvent(.error("segment \(cur.segment.index) stalled at \(Int(s.progress * 100))%"))
                    playing = nil
                    return
                }
                playing = cur
            } else if cur.seenDrawing || sinceStart > 5 {
                if cur.seenDrawing { onEvent(.finished(segment: cur.segment.index, drewSeconds: sinceStart)) }
                else { onEvent(.error("segment \(cur.segment.index) never started drawing")) }
                playing = nil
            }
        }

        // 3. Start the next one as soon as the table is free.
        if playing == nil {
            if queued != nil { try await playQueued() }
            else if pending.isEmpty && !starvedSent { starvedSent = true; onEvent(.starved) }
        }
    }

    private func playQueued() async throws {
        guard var q = queued else { return }
        queued = nil
        try await table.play(q.id)
        q.playedAt = Date(); q.progressChanged = Date()
        playing = q
        onEvent(.playing(segment: q.segment.index, slot: q.id))
    }

    /// Where the ball probably is: along the playing segment by progress, else the last uploaded end.
    private func ballEstimate() -> PolarPoint? {
        if let cur = playing, let s = table.tableState, s.patternId == cur.id, !cur.segment.points.isEmpty {
            let i = min(cur.segment.points.count - 1, Int(s.progress * Double(cur.segment.points.count)))
            return cur.segment.points[i]
        }
        return tail
    }

    /// Shifts the whole path by whole turns so it starts within half a turn of `theta`. The wire format is
    /// theta mod 360°, so this changes nothing on the table, but it stops the validator reading a 2π jump
    /// as a full spin.
    private func aligned(_ points: [PolarPoint], after theta: Double) -> [PolarPoint] {
        guard let first = points.first else { return points }
        let turns = ((theta - first.theta) / (2 * .pi)).rounded()
        guard turns != 0 else { return points }
        return points.map { PolarPoint(theta: $0.theta + turns * 2 * .pi, rho: $0.rho) }
    }

    /// Straight line in table space from `a` to `b`, as polar points (excluding both ends).
    private func connector(_ a: PolarPoint, _ b: PolarPoint) -> [PolarPoint] {
        let d = hypot(a.x - b.x, a.y - b.y)
        guard d > 0.02 else { return [] }
        let n = max(2, Int(d / 0.02))
        var out: [PolarPoint] = []
        var prevTheta = a.theta
        for i in 1..<n {
            let f = Double(i) / Double(n)
            var p = PolarPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
            // Keep theta continuous with the path so the table doesn't take the long way round.
            while p.theta - prevTheta > .pi { p.theta -= 2 * .pi }
            while p.theta - prevTheta < -.pi { p.theta += 2 * .pi }
            prevTheta = p.theta
            out.append(p)
        }
        return out
    }
}

public enum LiveCurves {
    /// A slowly precessing rose: one continuous curve, cut into segments of `step × perSegment` radians.
    /// Segment k starts exactly where k−1 ended, so chained segments draw one unbroken line.
    public static func precessingRose(segment k: Int, perSegment: Int = 150, step: Double = 0.025) -> [PolarPoint] {
        (0...perSegment).map { i in
            let s = Double(k * perSegment + i) * step
            return PolarPoint(theta: s, rho: 0.55 + 0.38 * sin(s * 7.0 / 3.0))
        }
    }
}
