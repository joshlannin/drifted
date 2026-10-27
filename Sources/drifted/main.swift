import DriftedKit
import Foundation

let usage = """
drifted — talk to a HoMedics Drift sand table

  drifted scan [--all] [--seconds N]          list nearby tables (--all: every BLE device)
  drifted listen [--device UUID] [--seconds N] connect, do the handshake, print what the table says
  drifted upload FILE [--id N] [--play] [--device UUID] [--delay MS]
                                            (--delay: ms between pages, default 100)
                                            FILE is a Drift .txt (theta,rho) or Sisyphus .thr
  drifted play ID [--device UUID]             draw a pattern already stored on the table
  drifted pause | next | prev [--device UUID] playback controls
  drifted raw CMD [BYTES…] [--ack] [--device UUID]
                                            send a framed packet, e.g. `drifted raw 14 03` (play/pause)
  drifted generate spiral|rose|spirograph OUT.txt   write a generated pattern (offline)
  drifted live [--segments N] [--points N] [--interrupt-at K]
                                            stream a generated drawing through LiveSession (soak test)
  drifted session [--device UUID] < SCRIPT    run a timed script over one connection, logging state changes.
                                            Lines: upload FILE ID | play ID | delete ID… | random on|off |
                                            loop on|off | wait SECONDS | waitdone ID [TIMEOUT] | say TEXT |
                                            raw CMD BYTES… | state | # note

Through drifted-host (the normal way; env DRIFTED_URL, DRIFTED_TOKEN_FILE):
  drifted status                              connection, drawing, progress, latched alarms
  drifted show FILE [--clear area|full]       draw a .txt/.thr file via drifted-host's slots (optionally sweep first)
  drifted preview FILE OUT.png|OUT.gif [--style sand|path] [--clear …] [--size N]
                                            digital twin, offline: picture (or animation) of the result
  drifted settings key=value…                 e.g. color=#ffffff brightness=0.8 speed=0.5 shifting=false random=false
  drifted events                              stream drifted-host's events
  drifted doctor [--draw]                     health summary to paste into a discussion (--draw: test circle)

The commands above scan/listen/upload/raw/session/live talk Bluetooth directly (debugging; stop drifted-host first).
Options: --quiet hides raw packet hex.
"""

setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered even when redirected, so logs survive Ctrl-C
var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func hexByte(_ s: String) -> UInt8 {
    guard let v = UInt8(s.hasPrefix("0x") ? String(s.dropFirst(2)) : s, radix: 16) else { fail("bad hex byte: \(s)") }
    return v
}

@MainActor
func powerOn(_ table: DriftTable) async throws {
    let hint = Task { @MainActor in
        try await Task.sleep(nanoseconds: 3_000_000_000)
        print("Waiting for Bluetooth… (check for a macOS permission prompt, or allow your terminal under System Settings → Privacy & Security → Bluetooth)")
    }
    defer { hint.cancel() }
    try await table.waitForPoweredOn()
}

@MainActor
func connectedTable(device: String?, quiet: Bool) async throws -> DriftTable {
    let table = DriftTable()
    table.logPackets = !quiet
    table.logHandler = { print($0) }
    try await powerOn(table)
    var target = device.flatMap(UUID.init(uuidString:))
    if target == nil {
        table.startScan()
        let deadline = Date().addingTimeInterval(10)
        while table.discovered.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
        table.stopScan()
        guard let first = table.discovered.max(by: { $0.rssi < $1.rssi }) else { throw DriftError.timeout("a table to show up in a scan") }
        target = first.id
    }
    table.connect(target!)
    if await table.waitUntilReady(timeout: 30) {
        print("Ready. Stored pattern ids: \(table.storedPatternIds.sorted().map(String.init).joined(separator: ","))")
    } else {
        print("Warning: no init-complete from table within 30 s (status \(table.status)); continuing")
    }
    return table
}

/// Timed script runner for hardware experiments: prints every pattern/status change with elapsed seconds.
@MainActor
func runSession(_ script: String, table: DriftTable) async throws {
    let start = Date()
    func t() -> String { String(format: "%7.2f", Date().timeIntervalSince(start)) }
    print("session clock starts at epoch \(String(format: "%.3f", start.timeIntervalSince1970))")
    func say(_ text: String) {
        print("\(t())  say: \(text)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = [text]
        try? p.run()
    }
    var last: (UInt16, UInt8)?
    var lastBucket = -1
    let watcher = Task { @MainActor in
        while !Task.isCancelled {
            if let s = table.tableState {
                if last == nil || last! != (s.patternId, s.status) {
                    print("\(t())  state: pattern \(s.patternId) status \(s.status) progress \(String(format: "%.1f%%", s.progress * 100))")
                    last = (s.patternId, s.status)
                    lastBucket = Int(s.progress * 10)
                } else if Int(s.progress * 10) != lastBucket {
                    lastBucket = Int(s.progress * 10)
                    print("\(t())  progress \(String(format: "%.1f%%", s.progress * 100))")
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    defer { watcher.cancel() }

    for raw in script.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("#") { print("\(t())  \(line)"); continue }
        let words = line.split(separator: " ").map(String.init)
        let arg = { (i: Int) -> String in i < words.count ? words[i] : "" }
        switch words[0] {
        case "upload":
            let pattern = try SandPattern.load(url: URL(fileURLWithPath: arg(1)))
            guard let id = UInt16(arg(2)) else { fail("upload needs FILE ID") }
            let began = Date()
            try await table.upload(pattern.wirePoints, id: id)
            print("\(t())  uploaded \(id): \(pattern.points.count) points, \(pattern.pageCount) pages in \(String(format: "%.2f", Date().timeIntervalSince(began))) s")
        case "play":
            guard let id = UInt16(arg(1)) else { fail("play needs ID") }
            try await table.play(id)
            print("\(t())  play \(id) sent")
        case "delete":
            try await table.send(Command.deletePatterns(words.dropFirst().compactMap { UInt16($0) }))
            print("\(t())  delete \(words.dropFirst().joined(separator: ",")) sent")
        case "random": try await table.send(Command.randomMode(arg(1) == "on")); print("\(t())  random \(arg(1))")
        case "loop": try await table.send(Command.loopMode(arg(1) == "on")); print("\(t())  loop \(arg(1))")
        case "wait": try await Task.sleep(nanoseconds: UInt64((Double(arg(1)) ?? 1) * 1e9))
        case "say": say(words.dropFirst().joined(separator: " "))
        case "raw":
            let packet = Packet(command: hexByte(arg(1)), data: words.dropFirst(2).map(hexByte))
            try await table.send(packet)
            print("\(t())  raw \(words.dropFirst().joined(separator: " ")) sent")
        case "state":
            if let s = table.tableState { print("\(t())  \(s)") } else { print("\(t())  no state yet") }
        case "waitdone":
            // Done = we saw this pattern drawing, and now it isn't (other pattern, or status changed).
            guard let id = UInt16(arg(1)) else { fail("waitdone needs ID") }
            let deadline = Date().addingTimeInterval(Double(arg(2)) ?? 120)
            var seen = false
            var began: Date?
            var lastProgress = -1.0
            var lastChange = Date()
            while Date() < deadline {
                // Stall = no progress change for 30 s (the move to a pattern's start can take 15 s with no progress). The table repeats its last fatal alarm long after
                // the fault, so an alarm alone isn't proof; a stall is (observed 2026-10-25).
                if let s = table.tableState {
                    if s.progress != lastProgress { lastProgress = s.progress; lastChange = Date() }
                    if Date().timeIntervalSince(lastChange) > 30 {
                        fail("\(t())  ABORT: pattern \(s.patternId) stalled at \(Int(s.progress * 100))%" + (table.lastAlarm.map { " (last \($0))" } ?? ""))
                    }
                }
                if let s = table.tableState {
                    if s.patternId == id && s.status == 1 {
                        if !seen { began = Date() }
                        seen = true
                    } else if seen { break }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let took = began.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "?"
            print("\(t())  waitdone \(id): \(Date() < deadline ? "finished" : "TIMEOUT") after drawing \(took) s")
        default:
            fail("unknown session command: \(line)")
        }
    }
}

// MARK: drifted-host client

let hostURL = URL(string: ProcessInfo.processInfo.environment["DRIFTED_URL"] ?? "http://localhost:8765")!
func hostToken() -> String {
    let env = ProcessInfo.processInfo.environment
    if let t = env["DRIFTED_TOKEN"] { return t }
    let file = env["DRIFTED_TOKEN_FILE"] ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Drifted/token").path
    return ((try? String(contentsOfFile: file)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func hostAPI(_ method: String, _ path: String, json: Any? = nil) async throws -> Data {
    var req = URLRequest(url: URL(string: path, relativeTo: hostURL)!)
    req.httpMethod = method
    req.timeoutInterval = 600
    req.setValue("Bearer \(hostToken())", forHTTPHeaderField: "Authorization")
    if let json { req.httpBody = try JSONSerialization.data(withJSONObject: json) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if status >= 400 { fail("drifted-host \(status): \(String(decoding: data, as: UTF8.self))") }
    return data
}

/// A drawing from a .txt/.thr pattern file, or a .json body as sent to POST /show ({name, xy|points|thr}).
func loadDrawing(_ file: String) throws -> SandPattern {
    let url = URL(fileURLWithPath: file)
    guard url.pathExtension.lowercased() == "json" else { return try SandPattern.load(url: url) }
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    let name = obj["name"] as? String ?? url.deletingPathExtension().lastPathComponent
    if let xy = obj["xy"] as? [[Double]] { return SandPattern.fromStrokes([xy.map { (x: $0[0], y: $0[1]) }], name: name) }
    if let pts = obj["points"] as? [[Double]] { return SandPattern(name: name, points: pts.map { PolarPoint(theta: $0[0], rho: $0[1]) }) }
    if let thr = obj["thr"] as? String { return SandPattern(thr: thr, name: name) }
    fail("\(file): expected xy, points or thr")
}

func patternBody(_ file: String, clear: String?) throws -> [String: Any] {
    let pattern = try SandPattern.load(url: URL(fileURLWithPath: file))
    var body: [String: Any] = ["name": pattern.name, "points": pattern.points.map { [$0.theta, $0.rho] }]
    if let clear { body["clear"] = clear }
    return body
}

func printJSON(_ data: Data) {
    if let obj = try? JSONSerialization.jsonObject(with: data),
       let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: pretty, as: UTF8.self))
    } else { print(String(decoding: data, as: UTF8.self)) }
}

@MainActor
func run() async throws {
    let quiet = flag("--quiet")
    let device = option("--device")
    guard let command = args.first else { print(usage); return }
    args.removeFirst()

    switch command {
    case "status":
        printJSON(try await hostAPI("GET", "/status"))
    case "show":
        let clear = option("--clear")
        guard let file = args.first else { fail("show needs FILE") }
        printJSON(try await hostAPI("POST", "/show?wait=true", json: try patternBody(file, clear: clear)))
    case "preview":
        // The digital twin runs here: no table or drifted-host needed.
        let clear = Clearing.Mode(rawValue: option("--clear") ?? "none") ?? .none
        let style = PatternPreview.Style(rawValue: option("--style") ?? "sand") ?? .sand
        let size = option("--size").flatMap(Int.init)
        guard args.count >= 2 else { fail("preview needs FILE OUT.png|OUT.gif") }
        let report = PatternValidator.validate(Clearing.prepend(clear, to: try loadDrawing(args[0])))
        for issue in report.issues { print("\(issue.severity.rawValue): \(issue.message)") }
        let out = URL(fileURLWithPath: args[1])
        let data = out.pathExtension.lowercased() == "gif"
            ? PatternPreview.gif(report.pattern, size: size ?? 384)
            : PatternPreview.png(report.pattern, size: size ?? 768, style: style)
        guard let data else { fail("render failed") }
        try data.write(to: out)
        let secs = Int(TableTwin.simulate(report.pattern).drawSeconds)
        print("wrote \(out.path); draws in about \(secs / 60) min \(secs % 60) s, plus the move to the start")
    case "settings":
        var body: [String: Any] = [:]
        for kv in args {
            let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { fail("settings take key=value") }
            if let b = Bool(parts[1]) { body[parts[0]] = b }
            else if let d = Double(parts[1]) { body[parts[0]] = d }
            else { body[parts[0]] = parts[1] }
        }
        printJSON(try await hostAPI("PUT", "/settings", json: body))
    case "doctor":
        // A short, safe health check whose output is fine to paste into a GitHub discussion (no token, no device id).
        let status = try JSONSerialization.jsonObject(with: try await hostAPI("GET", "/status")) as? [String: Any] ?? [:]
        let state = status["state"] as? [String: Any] ?? [:]
        print("drifted doctor")
        print("  host: reachable at \(hostURL.absoluteString)")
        print("  connection: \(status["connection"] ?? "?")")
        print("  controller: \(state["controller"] ?? "?"), driver: \(state["driver"] ?? "?")")
        print("  stored patterns: \(status["storedPatterns"] ?? "?")")
        print("  drawing: \((state["drawing"] as? Bool).map(String.init) ?? "?"), speed raw: \(state["speedRaw"] ?? "?"), random: \((state["random"] as? Bool).map(String.init) ?? "?")")
        let alarms = (status["alarms"] as? [[String: Any]] ?? []).map { "\($0["code"] ?? "?") \($0["name"] ?? "")" }
        print("  latched alarms: \(alarms.isEmpty ? "none" : alarms.joined(separator: ", "))")
        if flag("--draw") {
            // A 0.25-radius circle: proves upload + play end to end.
            let circle = (0...120).map { i -> [Double] in let a = Double(i) / 120 * 2 * .pi; return [0.25 * cos(a), 0.25 * sin(a)] }
            let job = try JSONSerialization.jsonObject(with: try await hostAPI("POST", "/show?wait=true", json: ["name": "doctor", "xy": circle])) as? [String: Any] ?? [:]
            print("  test circle: \(job["state"] ?? "?")\(job["error"].map { " (\($0))" } ?? "")")
        }
    case "events":
        var req = URLRequest(url: URL(string: "/events", relativeTo: hostURL)!)
        req.setValue("Bearer \(hostToken())", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = .infinity
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        for try await line in bytes.lines where !line.isEmpty { print(line) }

    case "scan":
        let all = flag("--all")
        let seconds = Double(option("--seconds") ?? "8") ?? 8
        let table = DriftTable()
        table.scanAll = all
        table.logHandler = { print($0) }
        try await powerOn(table)
        table.startScan()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        table.stopScan()
        if table.discovered.isEmpty { print("Nothing found. Is the table on and the official app disconnected?") }

    case "listen":
        let seconds = Double(option("--seconds") ?? "30") ?? 30
        let table = try await connectedTable(device: device, quiet: quiet)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        if let s = table.tableState { print("State: \(s)") }
        table.disconnect()

    case "upload":
        let play = flag("--play")
        let idArg = option("--id")
        let delay = (Double(option("--delay") ?? "100") ?? 100) / 1000
        guard let path = args.first else { fail("upload needs a FILE") }
        let pattern = try SandPattern.load(url: URL(fileURLWithPath: path))
        guard !pattern.points.isEmpty else { fail("no points in \(path)") }
        print("\(pattern.name): \(pattern.points.count) points, \(pattern.pageCount) pages")
        let table = try await connectedTable(device: device, quiet: quiet)
        let id = idArg.flatMap(UInt16.init) ?? table.freePatternId()
        var lastShown = -1
        try await table.upload(pattern.wirePoints, id: id, pageDelay: delay) { p in
            let pct = Int(p * 100)
            if pct / 10 != lastShown / 10 { print("  \(pct)%"); lastShown = pct }
        }
        print("Stored as id \(id)")
        if play {
            try await table.play(id)
            print("Drawing \(id)")
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        table.disconnect()

    case "play", "pause", "next", "prev":
        let table = try await connectedTable(device: device, quiet: quiet)
        switch command {
        case "play":
            guard let id = args.first.flatMap(UInt16.init) else { fail("play needs a numeric ID") }
            try await table.play(id)
        case "pause": try await table.send(Command.playPause)
        case "next": try await table.send(Command.next)
        default: try await table.send(Command.previous)
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        table.disconnect()

    case "raw":
        let ack = flag("--ack")
        guard let cmd = args.first.map(hexByte) else { fail("raw needs CMD") }
        let packet = Packet(command: cmd, data: args.dropFirst().map(hexByte), ack: ack)
        let table = try await connectedTable(device: device, quiet: quiet)
        try await table.send(packet)
        try await Task.sleep(nanoseconds: 5_000_000_000)
        table.disconnect()

    case "live":
        // drifted live [--segments N] [--points N] [--interrupt-at K]: streams a precessing rose through LiveSession.
        let count = Int(option("--segments") ?? "") ?? 12
        let per = Int(option("--points") ?? "") ?? 150
        let interruptAt = Int(option("--interrupt-at") ?? "")
        let table = try await connectedTable(device: device, quiet: true)
        let t0 = Date()
        print("live clock starts at epoch \(String(format: "%.3f", t0.timeIntervalSince1970))")
        let live = LiveSession(table: table)
        var done = 0, errors = 0, starved = false
        live.onEvent = { e in
            print(String(format: "%7.2f  ", Date().timeIntervalSince(t0)) + "\(e)")
            if case .finished = e { done += 1 }
            if case .error = e { errors += 1 }
            if case .starved = e { starved = true }
        }
        try await live.start()
        var pushed = 0
        // An interrupt discards the queued segment, so "all pushed and the queue ran dry" is the end.
        while !(pushed == count && starved) {
            // Keep about two segments ahead, like a real event source with backpressure.
            if pushed < count && live.depth < 2 {
                if let k = interruptAt, pushed == k {
                    // Cut in with a small circle somewhere else on the table.
                    let circle = (0...120).map { i -> PolarPoint in
                        let a = Double(i) / 120 * 2 * .pi
                        return PolarPoint(x: -0.4 + 0.2 * cos(a), y: 0.2 * sin(a))
                    }
                    live.push(circle, interrupt: true)
                } else {
                    live.push(LiveCurves.precessingRose(segment: pushed, perSegment: per))
                }
                pushed += 1
                starved = false
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        await live.stop()
        print("done: \(done) finished, \(errors) errors")
        table.disconnect()

    case "session":
        let script = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let table = try await connectedTable(device: device, quiet: true)
        try await runSession(script, table: table)
        table.disconnect()

    case "generate":
        guard args.count >= 2 else { fail("generate needs KIND and OUT.txt") }
        let pattern: SandPattern
        switch args[0] {
        case "spiral": pattern = Generators.spiral()
        case "rose": pattern = Generators.rose(petals: 5, loops: 1)
        case "spirograph": pattern = Generators.spirograph()
        default: fail("unknown generator \(args[0])")
        }
        try pattern.driftText.write(toFile: args[1], atomically: true, encoding: .utf8)
        print("Wrote \(pattern.points.count) points to \(args[1])")

    default:
        print(usage)
    }
}

Task { @MainActor in
    do {
        try await run()
        exit(0)
    } catch {
        fail("error: \(error.localizedDescription)")
    }
}
RunLoop.main.run()  // not dispatchMain(): that parks the main thread, and MainActor.assumeIsolated then traps in CoreBluetooth callbacks
