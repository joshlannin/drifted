import Foundation

// drifted-mcp — MCP server (stdio, JSON-RPC 2.0, one message per line) exposing drifted-host to agents.
// It holds no table state: every tool is a call to drifted-host's HTTP API.
// Env: DRIFTED_URL (default http://localhost:8765), DRIFTED_TOKEN or DRIFTED_TOKEN_FILE
//      (default ~/Library/Application Support/Drifted/token).

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
let base = URL(string: env["DRIFTED_URL"] ?? "http://localhost:8765")!
let tokenFile = env["DRIFTED_TOKEN_FILE"]
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Drifted/token").path

func token() -> String {
    env["DRIFTED_TOKEN"] ?? ((try? String(contentsOfFile: tokenFile)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

struct ToolError: Error { var message: String }

/// Calls drifted-host; returns (status, body).
func call(_ method: String, _ path: String, json: Any? = nil) async throws -> (Int, Data) {
    var req = URLRequest(url: URL(string: path, relativeTo: base)!)
    req.httpMethod = method
    req.setValue("Bearer \(token())", forHTTPHeaderField: "Authorization")
    if let json { req.httpBody = try JSONSerialization.data(withJSONObject: json) }
    req.timeoutInterval = 180
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    } catch {
        throw ToolError(message: "drifted-host isn't reachable at \(base.absoluteString) (\(error.localizedDescription)). Is it running?")
    }
}

// MARK: Tools

let drawingSchema: [String: Any] = [
    "name": ["type": "string", "description": "Short name for the drawing"],
    "xy": ["type": "array", "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
           "description": "The path as [x, y] points in table radii: the table is the unit disc, centre (0,0), +x right, +y up. The ball never lifts, so the whole path is drawn, including moves between shapes."],
    "points": ["type": "array", "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
               "description": "Alternative to xy: [theta, rho] polar points, theta in radians, rho 0 (centre) to 1 (rim)."],
    "thr": ["type": "string", "description": "Alternative: Sisyphus .thr text (\"theta rho\" per line)."],
]

func schema(_ props: [String: Any], required: [String] = []) -> [String: Any] {
    ["type": "object", "properties": props, "required": required]
}

let tools: [[String: Any]] = [
    ["name": "get_status", "description": "Connection, what the table is drawing, progress (0-1), light and mode settings, and any latched table alarms (fatal alarms stay listed until the table reboots).",
     "inputSchema": schema([:])],
    ["name": "list_patterns", "description": "Pattern ids stored on the table, with names for ones drifted-host manages.", "inputSchema": schema([:])],
    ["name": "validate_pattern", "description": "Digital twin, no table needed: check a drawing without sending it. Returns issues (errors block sending; 'fixed' were repaired) and stats (points, length, estimated seconds to draw).",
     "inputSchema": schema(drawingSchema.merging(["clear": ["type": "string", "enum": ["none", "area", "full"]]]) { $1 })],
    ["name": "preview_pattern", "description": "Digital twin, no table needed: shows the drawing before anything moves. Returns two images: the sand as it should look afterwards (grooves as wide as the ball, so lines closer than about 0.07 merge, as on the table) and a route diagram (green start, red end; every connecting move is drawn too). Always look at both before show_pattern, and iterate until it reads well.",
     "inputSchema": schema(drawingSchema.merging(["clear": ["type": "string", "enum": ["none", "area", "full"]]]) { $1 })],
    ["name": "animate_pattern", "description": "Digital twin, no table needed: saves an animated GIF of the ball drawing it (a few seconds long), for showing the user before committing minutes of drawing time. Returns the file path and the real drawing time.",
     "inputSchema": schema(drawingSchema.merging([
        "clear": ["type": "string", "enum": ["none", "area", "full"]],
        "save_to": ["type": "string", "description": "File path for the .gif (default: ~/Downloads/<name>.gif)"],
        "seconds": ["type": "number", "description": "Animation length, default 6"],
     ]) { $1 })],
    ["name": "show_pattern", "description": "Draw something now. drifted-host validates, stores it in a managed slot (reusing one if it already holds the drawing) and starts it. clear='area' sweeps the sand under the drawing first so it reads cleanly (a few minutes); 'full' sweeps the whole table (~10 min).",
     "inputSchema": schema(drawingSchema.merging(["clear": ["type": "string", "enum": ["none", "area", "full"], "default": "none"]]) { $1 })],
    ["name": "save_pattern", "description": "Store a drawing permanently under a name (for playlists). Most callers want show_pattern instead.",
     "inputSchema": schema(drawingSchema, required: ["name"])],
    ["name": "delete_pattern", "description": "Delete a saved pattern by id.", "inputSchema": schema(["id": ["type": "integer"]], required: ["id"])],
    ["name": "playback", "description": "Play a stored pattern id, or pause/next/previous.",
     "inputSchema": schema(["action": ["type": "string", "enum": ["play", "pause", "next", "previous"]], "id": ["type": "integer", "description": "Pattern id (play only)"]], required: ["action"])],
    ["name": "settings", "description": "Lights and modes. color '#rrggbb' sets a fixed colour; brightness and speed are 0-1; shifting cycles the palette; random plays random stored patterns when idle.",
     "inputSchema": schema(["color": ["type": "string"], "brightness": ["type": "number"], "speed": ["type": "number"], "shifting": ["type": "boolean"],
                            "breathing": ["type": "boolean"], "random": ["type": "boolean"], "loop": ["type": "boolean"]])],
    ["name": "live_start", "description": "Start a live session: you then push short segments (each ideally 10-30 s of drawing) and the table draws them back to back. Exclusive until live_stop.", "inputSchema": schema([:])],
    ["name": "live_push", "description": "Queue a live segment. interrupt=true cuts in as soon as it's uploaded (about 1-2 s). Keep about two segments queued.",
     "inputSchema": schema(drawingSchema.merging(["interrupt": ["type": "boolean"]]) { $1 })],
    ["name": "live_stop", "description": "End the live session and restore random/loop settings.", "inputSchema": schema([:])],
    ["name": "connection", "description": "connect or disconnect drifted-host from the table (disconnect lets the official app connect).",
     "inputSchema": schema(["action": ["type": "string", "enum": ["connect", "disconnect"]]], required: ["action"])],
]

func drawingBody(_ a: [String: Any]) -> [String: Any] {
    a.filter { ["name", "xy", "points", "thr", "clear", "interrupt"].contains($0.key) }
}

/// Runs a tool; returns MCP content blocks.
func run(_ name: String, _ a: [String: Any]) async throws -> [[String: Any]] {
    func text(_ r: (Int, Data)) throws -> [[String: Any]] {
        let (status, data) = r
        let body = String(decoding: data, as: UTF8.self)
        if status >= 400 { throw ToolError(message: "drifted-host \(status): \(body)") }
        return [["type": "text", "text": body]]
    }
    switch name {
    case "get_status": return try text(try await call("GET", "/status"))
    case "list_patterns": return try text(try await call("GET", "/patterns"))
    case "validate_pattern": return try text(try await call("POST", "/patterns/validate", json: drawingBody(a)))
    case "preview_pattern":
        var out: [[String: Any]] = []
        for style in ["sand", "path"] {
            let (status, data) = try await call("POST", "/patterns/preview?size=512&style=\(style)", json: drawingBody(a))
            if status >= 400 { return try text((status, data)) }
            out.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"])
        }
        let stats = try await call("POST", "/patterns/validate", json: drawingBody(a))
        return [["type": "text", "text": "1: sand after drawing. 2: route (green start, red end). Validation: " + String(decoding: stats.1, as: UTF8.self)]] + out
    case "animate_pattern":
        let seconds = (a["seconds"] as? Double) ?? 6
        let (status, data) = try await call("POST", "/patterns/preview?format=gif&size=384&seconds=\(seconds)", json: drawingBody(a))
        if status >= 400 { return try text((status, data)) }
        let name = ((a["name"] as? String) ?? "drawing").replacingOccurrences(of: "/", with: "-")
        let path = ((a["save_to"] as? String) ?? "~/Downloads/\(name).gif") as NSString
        let url = URL(fileURLWithPath: path.expandingTildeInPath)
        try data.write(to: url)
        let (_, v) = try await call("POST", "/patterns/validate", json: drawingBody(a))
        let secs = ((try? JSONSerialization.jsonObject(with: v)) as? [String: Any])
            .flatMap { ($0["stats"] as? [String: Any])?["estimatedSeconds"] as? Double } ?? 0
        return [["type": "text", "text": "Saved the animation to \(url.path). On the table it takes about \(Int(secs / 60)) min \(Int(secs) % 60) s (plus the move to the start)."]]
    case "show_pattern": return try text(try await call("POST", "/show?wait=true", json: drawingBody(a)))
    case "save_pattern": return try text(try await call("POST", "/patterns?wait=true", json: drawingBody(a)))
    case "delete_pattern":
        guard let id = a["id"] as? Int else { throw ToolError(message: "id is required") }
        return try text(try await call("DELETE", "/patterns/\(id)?wait=true"))
    case "playback":
        let action = a["action"] as? String ?? ""
        if action == "play" {
            guard let id = a["id"] as? Int else { throw ToolError(message: "play needs an id") }
            return try text(try await call("POST", "/play", json: ["id": id]))
        }
        guard ["pause", "next", "previous"].contains(action) else { throw ToolError(message: "unknown action \(action)") }
        return try text(try await call("POST", "/\(action)"))
    case "settings": return try text(try await call("PUT", "/settings", json: a))
    case "live_start": return try text(try await call("POST", "/live/start"))
    case "live_push": return try text(try await call("POST", "/live/segments", json: drawingBody(a)))
    case "live_stop": return try text(try await call("POST", "/live/stop"))
    case "connection":
        let action = a["action"] as? String ?? ""
        guard ["connect", "disconnect"].contains(action) else { throw ToolError(message: "action must be connect or disconnect") }
        return try text(try await call("POST", "/\(action)"))
    default: throw ToolError(message: "unknown tool \(name)")
    }
}

// MARK: JSON-RPC over stdio

func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func respond(_ id: Any, result: Any) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func respond(_ id: Any, error code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func handle(_ msg: [String: Any]) async {
    let method = msg["method"] as? String ?? ""
    guard let id = msg["id"] else { return }   // notifications (e.g. notifications/initialized) need no reply
    switch method {
    case "initialize":
        let requested = (msg["params"] as? [String: Any])?["protocolVersion"] as? String
        respond(id, result: [
            "protocolVersion": requested ?? "2025-06-18",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "drifted-mcp", "version": "0.1"],
            "instructions": "Controls a HoMedics Drift sand table through drifted-host. Preview drawings before showing them; the ball never lifts, so every move is drawn.",
        ])
    case "ping": respond(id, result: [:] as [String: Any])
    case "tools/list": respond(id, result: ["tools": tools])
    case "tools/call":
        let p = msg["params"] as? [String: Any] ?? [:]
        let name = p["name"] as? String ?? ""
        do {
            let content = try await run(name, p["arguments"] as? [String: Any] ?? [:])
            respond(id, result: ["content": content, "isError": false])
        } catch let e as ToolError {
            respond(id, result: ["content": [["type": "text", "text": e.message]], "isError": true])
        } catch {
            respond(id, result: ["content": [["type": "text", "text": "\(error)"]], "isError": true])
        }
    default: respond(id, error: -32601, "method not found: \(method)")
    }
}

Task {
    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8), !line.isEmpty,
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        await handle(msg)
    }
    exit(0)
}
RunLoop.main.run()
