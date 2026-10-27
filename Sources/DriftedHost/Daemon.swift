import Combine
import DriftedKit
import Foundation

/// drifted-host's core: the only thing that talks to the table. Holds the connection, runs jobs one at a time,
/// manages the `show` ring and saved patterns, runs live sessions, and publishes events.
@MainActor
public final class Daemon {
    public struct Config {
        public var port: UInt16 = 8765
        public var stateDir: URL
        public var device: UUID?
        public init(port: UInt16 = 8765, stateDir: URL, device: UUID? = nil) { self.port = port; self.stateDir = stateDir; self.device = device }
    }

    struct Job: Codable {
        enum State: String, Codable { case queued, running, done, failed }
        var id: Int
        var kind: String
        var state: State = .queued
        var progress: Double = 0
        var error: String?
        var result: [String: String]?
    }

    public let table = DriftTable()
    public let config: Config
    public let token: String
    var slots: SlotStore
    private var wantConnected = true
    private var sse: [ObjectIdentifier: SSEClient] = [:]
    private var jobs: [Int: Job] = [:]
    private var nextJob = 1
    private var jobChain: Task<Void, Never> = Task {}
    private var live: LiveSession?
    private var reportedAlarms: Set<UInt16> = []
    private var lastStateKey = ""
    private var lastProgressEvent = Date.distantPast
    private var bag: Set<AnyCancellable> = []

    public init(config: Config) throws {
        self.config = config
        try FileManager.default.createDirectory(at: config.stateDir, withIntermediateDirectories: true)
        token = try Self.loadToken(config.stateDir.appendingPathComponent("token"))
        slots = SlotStore(file: config.stateDir.appendingPathComponent("slots.json"))
        table.logPackets = false
        table.logHandler = { print("table: \($0)") }
    }

    // MARK: Lifecycle

    private var server: HTTPServer?

    /// Starts the HTTP API and the table connection; returns once Bluetooth is up.
    public func serve() async throws {
        let server = try HTTPServer(port: config.port, handler: { [unowned self] in await self.handle($0) },
                                    onSSE: { [unowned self] in self.addSSE($0) }, onSSEClose: { [unowned self] in self.removeSSE($0) })
        server.start()
        self.server = server
        print("drifted-host listening on :\(config.port); token in \(config.stateDir.path)/token")
        try await start()
    }

    /// Default state directory: ~/Library/Application Support/Drifted
    nonisolated public static var defaultStateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Drifted")
    }

    public func start() async throws {
        try await table.waitForPoweredOn()
        table.$status.sink { [weak self] s in self?.emit("connection", ["status": "\(s)"]) }.store(in: &bag)
        table.$tableState.sink { [weak self] s in if let s { self?.stateChanged(s) } }.store(in: &bag)
        table.$lastAlarm.sink { [weak self] a in if let a { self?.alarm(a) } }.store(in: &bag)
        Task { await supervise() }
    }

    /// Keeps the connection up unless a client asked us to let go.
    private func supervise() async {
        while true {
            if wantConnected {
                switch table.status {
                case .ready, .connecting, .handshaking, .scanning: break
                default: await connectOnce()
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func connectOnce() async {
        var target = config.device ?? savedDevice()
        if target == nil {
            table.startScan()
            let deadline = Date().addingTimeInterval(10)
            while table.discovered.isEmpty, Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
            table.stopScan()
            target = table.discovered.max(by: { $0.rssi < $1.rssi })?.id
        }
        guard let target else { print("drifted-host: no table found; retrying"); return }
        table.connect(target)
        if await table.waitUntilReady(timeout: 30) {
            try? target.uuidString.write(to: config.stateDir.appendingPathComponent("device"), atomically: true, encoding: .utf8)
            print("drifted-host: connected, \(table.storedPatternIds.count) patterns stored")
        }
    }

    private func savedDevice() -> UUID? {
        (try? String(contentsOf: config.stateDir.appendingPathComponent("device"))).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    // MARK: Events

    func addSSE(_ c: SSEClient) {
        sse[ObjectIdentifier(c)] = c
        c.send(event: "status", json: Self.data(statusJSON()))
    }
    func removeSSE(_ c: SSEClient) { sse[ObjectIdentifier(c)] = nil }

    func emit(_ event: String, _ payload: [String: Any]) {
        let data = Self.data(payload)
        for c in sse.values { c.send(event: event, json: data) }
    }

    private func stateChanged(_ s: TableState) {
        let key = "\(s.patternId)/\(s.status)"
        if key != lastStateKey || Date().timeIntervalSince(lastProgressEvent) >= 1 {
            lastStateKey = key; lastProgressEvent = Date()
            emit("state", stateJSON(s))
        }
    }

    /// Fatal alarms latch until the table reboots and repeat every second, so only new codes are events.
    private func alarm(_ a: TableAlarm) {
        let fresh = a.codes.filter { !reportedAlarms.contains($0) }
        guard !fresh.isEmpty else { return }
        reportedAlarms.formUnion(fresh)
        emit("alarm", ["kind": Int(a.kind), "codes": fresh.map { ["code": Int($0), "name": TableAlarm.codeNames[$0] ?? "?"] }])
    }

    // MARK: Jobs

    /// Queues `work`; jobs run one at a time, in order.
    func enqueue(_ kind: String, _ work: @escaping @MainActor (_ progress: @escaping (Double) -> Void) async throws -> [String: String]?) -> Job {
        let id = nextJob; nextJob += 1
        let job = Job(id: id, kind: kind)
        jobs[id] = job
        if jobs.count > 200, let oldest = jobs.keys.min() { jobs[oldest] = nil }
        let previous = jobChain
        jobChain = Task { @MainActor in
            await previous.value
            self.update(id) { $0.state = .running }
            do {
                guard self.table.status == .ready else { throw DriftError.notConnected }
                let result = try await work { p in self.update(id) { $0.progress = p } }
                self.update(id) { $0.state = .done; $0.progress = 1; $0.result = result }
            } catch {
                self.update(id) { $0.state = .failed; $0.error = error.localizedDescription }
            }
        }
        emit("job", jobJSON(job))
        return job
    }

    private func update(_ id: Int, _ change: (inout Job) -> Void) {
        guard var j = jobs[id] else { return }
        let before = (j.state, Int(j.progress * 10))
        change(&j); jobs[id] = j
        if before != (j.state, Int(j.progress * 10)) { emit("job", jobJSON(j)) }
    }

    /// Waits for a job (quick commands answer with the finished job).
    func wait(_ job: Job, timeout: TimeInterval = 120) async -> Job {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let j = jobs[job.id], j.state == .done || j.state == .failed { return j }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return jobs[job.id] ?? job
    }

    // MARK: Operations

    /// Shows a drawing using the slot ring: reuse a slot that already holds it, else overwrite the least
    /// recently used one that isn't drawing. Clients never pick ids or delete anything.
    func show(_ pattern: SandPattern) throws -> Job {
        try requireNoLive()
        let report = PatternValidator.validate(pattern)
        guard report.ok else { throw HTTPError(400, report.issues.filter { $0.severity == .error }.map(\.message).joined(separator: "; ")) }
        let hash = PatternValidator.contentHash(report.pattern)
        return enqueue("show") { progress in
            let playing = self.table.tableState.flatMap { $0.status == 1 ? $0.patternId : nil }
            if let id = self.slots.slot(holding: hash), self.table.storedPatternIds.contains(id) {
                try await self.table.play(id)
                self.slots.touch(id)
                return ["id": "\(id)", "uploaded": "false", "hash": hash]
            }
            let id = self.slots.leastRecentlyUsed(excluding: playing)
            try await self.table.upload(report.pattern.wirePoints, id: id, progress: { progress($0 * 0.95) })
            try await self.table.play(id)
            self.slots.assign(id, hash: hash, name: pattern.name)
            return ["id": "\(id)", "uploaded": "true", "hash": hash]
        }
    }

    func save(_ pattern: SandPattern) throws -> Job {
        let report = PatternValidator.validate(pattern)
        guard report.ok else { throw HTTPError(400, report.issues.filter { $0.severity == .error }.map(\.message).joined(separator: "; ")) }
        let hash = PatternValidator.contentHash(report.pattern)
        return enqueue("save") { progress in
            let id = self.slots.savedId(for: pattern.name, avoiding: self.table.storedPatternIds)
            try await self.table.upload(report.pattern.wirePoints, id: id, progress: progress)
            self.slots.save(id, name: pattern.name, hash: hash)
            return ["id": "\(id)", "name": pattern.name]
        }
    }

    func forget(_ id: UInt16, force: Bool) throws -> Job {
        guard force || slots.isSaved(id) else { throw HTTPError(409, "id \(id) is not a saved pattern; pass force=true to delete it anyway") }
        guard table.storedPatternIds.contains(id) else { throw HTTPError(404, "the table doesn't have id \(id)") }
        guard table.tableState?.patternId != id else { throw HTTPError(409, "id \(id) is drawing; the table won't delete it") }
        return enqueue("delete") { _ in
            try await self.table.send(Command.deletePatterns([id]))
            self.slots.forget(id)
            return ["id": "\(id)"]
        }
    }

    func command(_ kind: String, _ packets: [Packet]) -> Job {
        enqueue(kind) { _ in
            for p in packets { try await self.table.send(p) }
            return nil
        }
    }

    public func setConnected(_ on: Bool) {
        wantConnected = on
        if !on { table.disconnect() }
    }

    // MARK: Live

    func liveStart() async throws {
        guard live == nil else { return }
        guard table.status == .ready else { throw HTTPError(503, "table not connected") }
        let session = LiveSession(table: table)
        session.onEvent = { [weak self] e in self?.emit("live", ["event": "\(e)"]) }
        // Live owns the table: wait for queued jobs to drain first.
        await jobChain.value
        try await session.start()
        live = session
    }

    func livePush(_ points: [PolarPoint], interrupt: Bool) throws -> [String: Any] {
        guard let live else { throw HTTPError(409, "no live session; POST /live/start first") }
        let index = live.push(points, interrupt: interrupt)
        return ["segment": index, "depth": live.depth]
    }

    func liveStop() async {
        await live?.stop()
        live = nil
    }

    private func requireNoLive() throws {
        if live != nil { throw HTTPError(409, "a live session is running; POST /live/stop first") }
    }
    public var liveRunning: Bool { live != nil }
    var liveDepth: Int { live?.depth ?? 0 }

    // MARK: JSON

    public func statusJSON() -> [String: Any] {
        var out: [String: Any] = [
            "connection": "\(table.status)",
            "device": table.connectedName ?? NSNull(),
            "storedPatterns": table.storedPatternIds.count,
            "live": live.map { ["running": true, "depth": $0.depth] as [String: Any] } ?? ["running": false],
            "alarms": reportedAlarms.sorted().map { ["code": Int($0), "name": TableAlarm.codeNames[$0] ?? "?"] },
        ]
        if let s = table.tableState { out["state"] = stateJSON(s) }
        return out
    }

    func stateJSON(_ s: TableState) -> [String: Any] {
        ["patternId": Int(s.patternId), "drawing": s.status == 1, "progress": s.progress, "brightness": Int(s.brightness),
         "color": s.colorName, "speedRaw": Int(s.speedRaw), "random": s.randomMode, "loop": s.loopMode,
         "controller": s.controllerVersion ?? NSNull(), "driver": s.driverVersion ?? NSNull()]
    }

    func jobJSON(_ j: Job) -> [String: Any] {
        var out: [String: Any] = ["id": j.id, "kind": j.kind, "state": j.state.rawValue, "progress": j.progress]
        if let e = j.error { out["error"] = e }
        if let r = j.result { out["result"] = r }
        return out
    }

    func job(_ id: Int) -> Job? { jobs[id] }

    static func data(_ v: Any) -> Data { (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])) ?? Data("{}".utf8) }

    private static func loadToken(_ url: URL) throws -> String {
        if let t = try? String(contentsOf: url).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        let t = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try t.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return t
    }
}

/// drifted-host's only persistent state: which drawing each ring slot holds, and saved patterns.
/// Losing the file costs at most one extra upload per slot.
struct SlotStore {
    struct Entry: Codable { var id: UInt16; var hash: String; var name: String; var lastUsed: Date }
    struct State: Codable { var ring: [Entry] = []; var saved: [Entry] = [] }

    let file: URL
    static let ringIds = Array(UInt16(50000)...UInt16(50007))
    static let savedStart: UInt16 = 50100
    private(set) var state: State

    init(file: URL) {
        self.file = file
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        state = (try? dec.decode(State.self, from: Data(contentsOf: file))) ?? State()
    }

    func slot(holding hash: String) -> UInt16? { state.ring.first { $0.hash == hash }?.id }

    func leastRecentlyUsed(excluding playing: UInt16?) -> UInt16 {
        let candidates = Self.ringIds.filter { $0 != playing }
        if let empty = candidates.first(where: { id in !state.ring.contains { $0.id == id } }) { return empty }
        return state.ring.filter { $0.id != playing }.min { $0.lastUsed < $1.lastUsed }!.id
    }

    mutating func assign(_ id: UInt16, hash: String, name: String) {
        state.ring.removeAll { $0.id == id }
        state.ring.append(Entry(id: id, hash: hash, name: name, lastUsed: Date()))
        persist()
    }

    mutating func touch(_ id: UInt16) {
        if let i = state.ring.firstIndex(where: { $0.id == id }) { state.ring[i].lastUsed = Date(); persist() }
    }

    func isSaved(_ id: UInt16) -> Bool { state.saved.contains { $0.id == id } }

    func savedId(for name: String, avoiding stored: Set<UInt16>) -> UInt16 {
        if let e = state.saved.first(where: { $0.name == name }) { return e.id }   // re-saving a name overwrites it
        var id = Self.savedStart
        while stored.contains(id) || isSaved(id) { id += 1 }
        return id
    }

    mutating func save(_ id: UInt16, name: String, hash: String) {
        state.saved.removeAll { $0.id == id }
        state.saved.append(Entry(id: id, hash: hash, name: name, lastUsed: Date()))
        persist()
    }

    mutating func forget(_ id: UInt16) {
        state.saved.removeAll { $0.id == id }; state.ring.removeAll { $0.id == id }
        persist()
    }

    func name(of id: UInt16) -> String? { (state.ring + state.saved).first { $0.id == id }?.name }

    private func persist() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try? enc.encode(state).write(to: file, options: .atomic)
    }
}
