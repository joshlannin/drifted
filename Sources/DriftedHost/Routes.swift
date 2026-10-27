import DriftedKit
import Foundation

/// A drawing in a request body: `points` [[theta, rho]…], `xy` [[x, y]…] in table radii, or `thr` text.
struct PatternInput: Decodable {
    var name: String?
    var points: [[Double]]?
    var xy: [[Double]]?
    var thr: String?
    var clear: Clearing.Mode?     // show only: sweep the sand first ("area" or "full")

    func pattern() throws -> SandPattern {
        let name = self.name ?? "drawing"
        if let points {
            guard points.allSatisfy({ $0.count == 2 }) else { throw HTTPError(400, "points must be [theta, rho] pairs") }
            return SandPattern(name: name, points: points.map { PolarPoint(theta: $0[0], rho: $0[1]) })
        }
        if let xy {
            guard xy.allSatisfy({ $0.count == 2 }) else { throw HTTPError(400, "xy must be [x, y] pairs") }
            return SandPattern.fromStrokes([xy.map { (x: $0[0], y: $0[1]) }], name: name)
        }
        if let thr { return SandPattern(thr: thr, name: name) }
        throw HTTPError(400, "give the drawing as points, xy or thr")
    }
}

struct SettingsInput: Decodable {
    var speed: Double?
    var brightness: Double?
    var color: String?          // "#rrggbb"
    var shifting: Bool?
    var breathing: Bool?
    var shiftSeconds: Int?
    var random: Bool?
    var loop: Bool?
    var power: Bool?
}

extension Daemon {
    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        guard req.headers["authorization"] == "Bearer \(token)" else {
            return .json(["error": "missing or wrong bearer token (see \(config.stateDir.path)/token)"], status: 401)
        }
        do { return try await route(req) }
        catch let e as HTTPError { return .json(["error": e.message], status: e.status) }
        catch { return .json(["error": error.localizedDescription], status: 500) }
    }

    private func route(_ req: HTTPRequest) async throws -> HTTPResponse {
        let parts = req.path.split(separator: "/").map(String.init)
        // Routes with an id segment (array patterns can't bind).
        if parts.count == 2, let id = Int(parts[1]) {
            if req.method == "DELETE" && parts[0] == "patterns" {
                guard let id = UInt16(exactly: id) else { throw HTTPError(400, "bad id") }
                return try await jobResponse(forget(id, force: req.query["force"] == "true"), req)
            }
            if req.method == "GET" && parts[0] == "jobs" {
                guard let j = job(id) else { throw HTTPError(404, "no such job") }
                return .json(jobJSON(j))
            }
        }
        switch (req.method, parts) {
        case ("GET", ["events"]):
            return HTTPResponse(status: 204, body: Data())
        case ("GET", ["status"]):
            return .json(statusJSON())
        case ("POST", ["connect"]):
            setConnected(true); return .json(["ok": true])
        case ("POST", ["disconnect"]):
            setConnected(false); return .json(["ok": true])

        case ("GET", ["patterns"]):
            let list = table.storedPatternIds.sorted().map { id -> [String: Any] in
                var e: [String: Any] = ["id": Int(id)]
                if let n = slots.name(of: id) { e["name"] = n }
                if slots.isSaved(id) { e["saved"] = true } else if SlotStore.ringIds.contains(id) { e["slot"] = true }
                return e
            }
            return .json(["patterns": list])
        case ("POST", ["patterns", "validate"]):
            let input = try req.json(PatternInput.self)
            let r = PatternValidator.validate(Clearing.prepend(input.clear ?? .none, to: try input.pattern()))
            return .json(["ok": r.ok, "issues": r.issues.map { ["severity": $0.severity.rawValue, "message": $0.message] },
                          "stats": ["points": r.stats.points, "pages": r.stats.pages, "length": r.stats.length,
                                    "estimatedSeconds": r.stats.estimatedSeconds, "start": r.stats.start, "end": r.stats.end]])
        case ("POST", ["patterns", "preview"]):
            let input = try req.json(PatternInput.self)
            let r = PatternValidator.validate(Clearing.prepend(input.clear ?? .none, to: try input.pattern()))
            // Digital twin: style=sand (ball-width grooves) or path (route diagram); format=gif animates it.
            let size = Int(req.query["size"] ?? "") ?? 512
            if req.query["format"] == "gif" {
                guard let gif = PatternPreview.gif(r.pattern, size: min(size, 768), frames: Int(req.query["frames"] ?? "") ?? 60,
                                                   seconds: Double(req.query["seconds"] ?? "") ?? 6) else { throw HTTPError(500, "render failed") }
                return HTTPResponse(status: 200, contentType: "image/gif", body: gif)
            }
            let style = PatternPreview.Style(rawValue: req.query["style"] ?? "path") ?? .path
            guard let png = PatternPreview.png(r.pattern, size: size, style: style) else { throw HTTPError(500, "render failed") }
            return HTTPResponse(status: 200, contentType: "image/png", body: png)
        case ("POST", ["patterns"]):
            return try await jobResponse(save(try req.json(PatternInput.self).pattern()), req)
        case ("POST", ["show"]):
            let input = try req.json(PatternInput.self)
            // Validate the client's drawing as sent (unwrapped xy etc.), then put the sweep in front.
            let drawing = PatternValidator.validate(try input.pattern()).pattern
            return try await jobResponse(show(Clearing.prepend(input.clear ?? .none, to: drawing)), req)

        case ("POST", ["play"]):
            struct Body: Decodable { var id: UInt16 }
            guard !liveRunning else { throw HTTPError(409, "a live session is running") }
            return try await jobResponse(command("play", [Command.drawPattern(try req.json(Body.self).id)]), req, wait: true)
        case ("POST", ["pause"]): return try await jobResponse(command("pause", [Command.playPause]), req, wait: true)
        case ("POST", ["next"]): return try await jobResponse(command("next", [Command.next]), req, wait: true)
        case ("POST", ["previous"]): return try await jobResponse(command("previous", [Command.previous]), req, wait: true)
        case ("PUT", ["settings"]):
            return try await jobResponse(command("settings", try settingsPackets(try req.json(SettingsInput.self))), req, wait: true)

        case ("POST", ["live", "start"]):
            try await liveStart(); return .json(["ok": true])
        case ("POST", ["live", "segments"]):
            struct Body: Decodable { var points: [[Double]]?; var xy: [[Double]]?; var thr: String?; var interrupt: Bool? }
            let b = try req.json(Body.self)
            let pattern = try PatternInput(name: "live", points: b.points, xy: b.xy, thr: b.thr, clear: nil).pattern()
            return .json(try livePush(pattern.points, interrupt: b.interrupt ?? false), status: 202)
        case ("POST", ["live", "stop"]):
            await liveStop(); return .json(["ok": true])

        default:
            throw HTTPError(404, "no route for \(req.method) \(req.path)")
        }
    }

    /// Long jobs answer 202 with the queued job unless `?wait=true`; quick commands always wait.
    private func jobResponse(_ job: Job, _ req: HTTPRequest, wait: Bool = false) async throws -> HTTPResponse {
        if wait || req.query["wait"] == "true" {
            let done = await self.wait(job)
            return .json(jobJSON(done), status: done.state == .failed ? 500 : 200)
        }
        return .json(jobJSON(job), status: 202)
    }

    private func settingsPackets(_ s: SettingsInput) throws -> [Packet] {
        var out: [Packet] = []
        if let v = s.speed { out.append(Command.speed(v)) }
        if let c = s.color {
            let hex = c.hasPrefix("#") ? String(c.dropFirst()) : c
            guard hex.count == 6, let v = UInt32(hex, radix: 16) else { throw HTTPError(400, "color must be #rrggbb") }
            out.append(Command.previewColor(r: UInt8(v >> 16), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF)))
            out.append(Command.selectColor("Temp"))
        }
        if s.shifting != nil || s.breathing != nil || s.brightness != nil || s.color != nil {
            // 0x11/4 sets all four at once; a fixed colour implies shifting off unless asked otherwise.
            let brightness = s.brightness ?? (table.tableState.map { Double($0.brightness) / 100 } ?? 1)
            out.append(Command.lightMode(shifting: s.shifting ?? false, shiftTime: UInt16(s.shiftSeconds ?? 0),
                                         breathing: s.breathing ?? false, brightness: brightness))
        }
        if let v = s.random { out.append(Command.randomMode(v)) }
        if let v = s.loop { out.append(Command.loopMode(v)) }
        if let v = s.power { out.append(Command.power(v)) }
        guard !out.isEmpty else { throw HTTPError(400, "no settings given") }
        return out
    }
}
