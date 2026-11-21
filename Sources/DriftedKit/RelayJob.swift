import Foundation

/// A piece of table work the relay does by itself (relay/README.md, "Jobs"; relay/firmware/main/job.h).
///
/// The relay's Wi-Fi is poor while it holds the table's Bluetooth link, so instead of driving the table live
/// the host hands over a short script of steps (and, for an upload, the pattern's points) while the table is
/// released. The relay links to the table, does the handshake, runs the steps, lets go, and reports.
public struct RelayJob {
    /// What an `expect` step waits for.
    public enum Expect: Equatable {
        /// A table packet with this command (and action, if given) whose data contains these bytes.
        case packet(command: UInt8, action: UInt8?, contains: [UInt8])
        /// The running state shows this pattern drawing.
        case drawing(UInt16)
    }

    public enum Op: Equatable {
        /// Write one packet.
        case send(Packet)
        /// Wait for the table to say something. Listens from the moment of the `send` before it.
        case expect(Expect, timeout: TimeInterval)
        /// Start a stored pattern and check it's drawing (`DriftTable.play`). Nil: the id the last upload went into.
        case play(UInt16?)
        /// Upload (`DriftTable.upload`, with its retries). `ids`: where to store it, then the ids to fall back to
        /// if the table refuses the first at Start (an id stuck "drawing": docs/failure-modes.md).
        case upload(points: [WirePoint], ids: [UInt16])
        case wait(TimeInterval)
        /// Stop here, successfully.
        case end
    }

    public struct Step: Equatable {
        public var op: Op
        /// If the step fails: nil fails the job; otherwise the index of the step to carry on from.
        public var onFail: Int?
        public init(_ op: Op, onFail: Int? = nil) { self.op = op; self.onFail = onFail }
    }

    public var steps: [Step]
    /// How long the relay keeps listening after the last step, for a last look at what the table is doing.
    public var linger: TimeInterval

    public init(_ steps: [Step] = [], linger: TimeInterval = 2) {
        self.steps = steps
        self.linger = linger
    }

    public static let maxSteps = 32
    /// Step bodies together (the relay's limit).
    public static let maxScript = 2048

    /// Doing it twice comes to the same as doing it once: true unless a step toggles or steps something
    /// (play/pause, next, previous). If the relay loses a job after it may have started it (it restarted, or
    /// went silent), a repeatable job is simply handed over again; one that isn't fails, saying it may or may
    /// not have been done.
    public var repeatable: Bool {
        !steps.contains {
            guard case .send(let p) = $0.op else { return false }
            return p.command == Command.playPause.command && [Command.playPause.action, Command.next.action, Command.previous.action].contains(p.action)
        }
    }

    public var uploadPoints: Int {
        steps.reduce(0) { if case .upload(let p, _) = $1.op { return $0 + p.count } else { return $0 } }
    }

    /// Longest the relay can take over it: connecting (two tries), up to three sessions, and the steps with
    /// their retries. Generous: the relay keeps the result until it's collected, so this only bounds a relay
    /// that vanished.
    public var timeLimit: TimeInterval {
        var t = 200.0 + linger
        for s in steps {
            switch s.op {
            case .send: t += 0.5
            case .expect(_, let timeout): t += timeout + 1
            case .play: t += 20
            case .upload(let points, _): t += 90 + Double(points.count / Command.pointsPerPage) * 0.5
            case .wait(let s): t += s
            case .end: break
            }
        }
        return t
    }

    public enum EncodingError: LocalizedError {
        case tooManySteps, tooLong, badStep(String)
        public var errorDescription: String? {
            switch self {
            case .tooManySteps: return "a relay job takes at most \(RelayJob.maxSteps) steps"
            case .tooLong: return "the relay job's steps are too long"
            case .badStep(let s): return "bad relay job step: \(s)"
            }
        }
    }

    /// The MSG_JOB_BEGIN payload and the pattern points that follow in MSG_JOB_DATA messages.
    /// `now` becomes the time the relay gives the table when it asks.
    public func encoded(id: UInt32, now: Date = Date(), timeZone: TimeZone = .current) throws -> (begin: [UInt8], blob: [UInt8]) {
        guard steps.count <= Self.maxSteps else { throw EncodingError.tooManySteps }
        var blob: [UInt8] = []
        var ops = ByteWriter()
        var script = 0
        for (i, step) in steps.enumerated() {
            var body = ByteWriter()
            let kind: UInt8
            switch step.op {
            case .send(let packet):
                kind = 1
                body.bytes = packet.encoded()
                guard body.bytes.count <= 200 else { throw EncodingError.badStep("packet too long") }
            case .expect(let what, let timeout):
                kind = 2
                body.u16(UInt16(max(1, min(65000, timeout * 1000))))
                switch what {
                case .packet(let command, let action, let contains):
                    guard contains.count <= 200 else { throw EncodingError.badStep("too much to look for") }
                    body.u8(1); body.u8(command); body.u8(action ?? 0xFF); body.u8(UInt8(contains.count))
                    body.bytes += contains
                case .drawing(let pattern):
                    body.u8(2); body.u16(pattern)
                }
            case .play(let pattern):
                kind = 3
                body.u16(pattern ?? 0)
            case .upload(let points, let ids):
                kind = 4
                guard !points.isEmpty, (1...8).contains(ids.count), !ids.contains(0) else { throw EncodingError.badStep("upload needs points and 1-8 ids") }
                body.u32(UInt32(points.count)); body.u32(UInt32(blob.count)); body.u8(UInt8(ids.count))
                ids.forEach { body.u16($0) }
                blob.reserveCapacity(blob.count + points.count * 4)
                for p in points { blob += [UInt8(p.t & 0xFF), UInt8(p.t >> 8), UInt8(p.r & 0xFF), UInt8(p.r >> 8)] }
            case .wait(let seconds):
                kind = 5
                body.u16(UInt16(max(0, min(65000, seconds * 1000))))
            case .end:
                kind = 6
            }
            if let go = step.onFail {
                guard steps.indices.contains(go), go != i else { throw EncodingError.badStep("onFail points nowhere") }
                ops.u8(kind); ops.u8(UInt8(go))
            } else {
                ops.u8(kind); ops.u8(0xFF)
            }
            ops.u16(UInt16(body.bytes.count))
            ops.bytes += body.bytes
            script += body.bytes.count
        }
        guard script <= Self.maxScript else { throw EncodingError.tooLong }
        var w = ByteWriter()
        w.u32(id)
        // The table's clock is local time; the relay has no clock or time zone of its own.
        w.u32(UInt32(max(0, now.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: now)))))
        w.u16(UInt16(max(0, min(65000, linger * 1000))))
        w.u32(UInt32(blob.count))
        w.u32(Self.crc32(blob))
        w.u8(UInt8(steps.count))
        w.bytes += ops.bytes
        guard w.bytes.count <= RelayFrame.maxPayload else { throw EncodingError.tooLong }
        return (w.bytes, blob)
    }

    /// CRC-32 (zlib's), which the relay checks the stored points against before it starts.
    public static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return ~crc
    }
}

/// What the relay reports when a job ends (MSG_JOB_RESULT).
public struct RelayJobResult {
    public struct Step {
        public var ran: Bool
        public var ok: Bool
        /// upload: the id it went into. play: the id.
        public var value: Int
        /// upload: pages sent again. play: how many times play was sent.
        public var count: Int
        public var seconds: Double
    }

    public var ok: Bool
    public var error: String
    /// Where it failed: "link" (never connected), "handshake", or "step".
    public var stage: String
    public var failedStep: Int?
    /// From the start of the job: to the Bluetooth link, to the end of the handshake and init dump, to the end.
    public var linkSeconds: Double
    public var readySeconds: Double
    public var totalSeconds: Double
    /// The relay's signal to the table, dBm.
    public var rssi: Int?
    public var links: Int
    public var handshakes: Int
    public var restarts: Int
    public var steps: [Step]
    /// What the table said during the job didn't all fit in the relay's memory.
    public var truncated: Bool
    public var tableBytes: Int

    public init?(json j: [String: Any]) {
        guard let ok = j["ok"] as? Bool else { return nil }
        func ms(_ key: String) -> Double { Double((j[key] as? Int) ?? 0) / 1000 }
        self.ok = ok
        error = (j["error"] as? String) ?? ""
        stage = (j["stage"] as? String) ?? ""
        failedStep = (j["failedOp"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
        linkSeconds = ms("linkMs"); readySeconds = ms("readyMs"); totalSeconds = ms("totalMs")
        rssi = (j["rssi"] as? Int).flatMap { $0 == 0 ? nil : $0 }
        links = (j["links"] as? Int) ?? 0
        handshakes = (j["handshakes"] as? Int) ?? 0
        restarts = (j["restarts"] as? Int) ?? 0
        truncated = (j["truncated"] as? Bool) ?? false
        tableBytes = (j["tableBytes"] as? Int) ?? 0
        steps = ((j["ops"] as? [[Int]]) ?? []).map {
            Step(ran: $0.count > 0 && $0[0] != 0, ok: $0.count > 1 && $0[1] != 0, value: $0.count > 2 ? $0[2] : 0,
                 count: $0.count > 3 ? $0[3] : 0, seconds: $0.count > 4 ? Double($0[4]) / 1000 : 0)
        }
    }

    /// The step failed for a reason another try won't change (as opposed to never reaching the table).
    public var failedAtStep: Bool { !ok && stage == "step" }
}
