import DriftedKit
import Foundation

/// relay.json in the state dir: whether drifted-host reaches the table through a Drifted relay (relay/README.md)
/// instead of this Mac's Bluetooth, and where the relay is. The token is a secret, so the file is 0600.
struct RelaySettings: Codable, Equatable {
    var enabled = false
    /// IP address or host name; without it the relay is found by Bonjour (`name`, or the first one found).
    var host: String?
    var port: UInt16?
    /// Bonjour instance name, e.g. "drifted-relay-1a2b3c".
    var name: String?
    var token: String?

    var endpoint: RelayEndpoint? {
        guard enabled, let token, !token.isEmpty else { return nil }
        return RelayEndpoint(host: host, port: port, name: name, token: token)
    }

    static func file(_ stateDir: URL) -> URL { stateDir.appendingPathComponent("relay.json") }

    static func load(_ stateDir: URL) -> RelaySettings {
        (try? JSONDecoder().decode(RelaySettings.self, from: Data(contentsOf: file(stateDir)))) ?? RelaySettings()
    }

    func save(_ stateDir: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = Self.file(stateDir)
        try enc.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    var json: [String: Any] {
        ["enabled": enabled, "host": host ?? NSNull(), "port": Int(port ?? RelayEndpoint.defaultPort),
         "name": name ?? NSNull(), "tokenSet": !(token ?? "").isEmpty]
    }
}

extension Daemon {
    /// One reconnect attempt through the relay (supervise() calls this instead of the Bluetooth scan/connect).
    func connectViaRelay() async {
        table.connectRelay()
        if await table.waitUntilReady(timeout: 30) {
            log("drifted-host: connected through relay \(table.relayDescription ?? ""), \(table.storedPatternIds.count) patterns stored")
        } else {
            // Closes the TCP connection; the relay keeps its Bluetooth link, and the next attempt gets a fresh handshake.
            table.abandonConnection("not ready after 30 s")
        }
    }

    /// /status "link": how the table is reached, and through a relay its signal to the table.
    func linkJSON() -> [String: Any] {
        guard table.viaRelay else { return ["via": "bluetooth"] }
        let s = table.relayStatus
        return ["via": "relay", "relay": table.relayDescription ?? table.relayEndpoint?.description ?? NSNull(),
                "relayConnected": table.relayConnected, "tableLink": s?.link ?? NSNull(),
                "rssi": s?.rssi ?? NSNull(), "wifiRssi": s?.wifiRssi ?? NSNull(), "firmware": s?.firmware ?? NSNull()]
    }

    func relayJSON() -> [String: Any] {
        var out = RelaySettings.load(config.stateDir).json
        out["active"] = table.viaRelay
        out["connected"] = table.relayConnected
        out["relay"] = table.relayDescription ?? NSNull()
        out["status"] = table.relayStatusJSON ?? NSNull()
        return out
    }

    /// GET/PUT /relay, GET /relay/discover, POST /relay/command. Nil for other paths.
    func relayRoute(_ req: HTTPRequest) async throws -> HTTPResponse? {
        switch (req.method, req.path.split(separator: "/").map(String.init)) {
        case ("GET", ["relay"]):
            return .json(relayJSON())
        case ("PUT", ["relay"]):
            guard let body = (try? JSONSerialization.jsonObject(with: req.body.isEmpty ? Data("{}".utf8) : req.body)) as? [String: Any] else {
                throw HTTPError(400, "body must be a JSON object")
            }
            try setRelay(body)
            return .json(relayJSON())
        case ("GET", ["relay", "discover"]):
            return .json(["relays": await RelayLink.discover(seconds: 3)])
        case ("POST", ["relay", "command"]):
            struct Body: Decodable { var command: String }
            let line = try req.json(Body.self).command.trimmingCharacters(in: .whitespacesAndNewlines)
            let word = line.split(separator: " ").first.map(String.init) ?? ""
            // release/connect belong to /disconnect and /connect, which also stop the host reconnecting.
            guard ["scan", "select", "forget", "hold", "status", "reboot", "ota"].contains(word) else {
                throw HTTPError(400, "command must be scan, select ADDRESS|NAME, forget, hold on|off, status, reboot or ota URL")
            }
            guard table.viaRelay, table.relayConnected else { throw HTTPError(409, "not connected to a relay") }
            log("relay command: \(word == "ota" ? line : word)")
            return .json(try await table.relayCommand(line, timeout: word == "scan" ? 12 : 10))
        default:
            return nil
        }
    }

    /// Merges a PUT /relay body into relay.json and switches the transport if it changed.
    func setRelay(_ body: [String: Any]) throws {
        var s = RelaySettings.load(config.stateDir)
        func string(_ key: String) throws -> String?? {
            guard let v = body[key] else { return .none }
            if v is NSNull { return .some(nil) }
            guard let str = v as? String else { throw HTTPError(400, "\(key) must be a string or null") }
            let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return .some(t.isEmpty ? nil : t)
        }
        if let v = body["enabled"] {
            guard let b = v as? Bool else { throw HTTPError(400, "enabled must be true or false") }
            s.enabled = b
        }
        if let v = try string("host") { s.host = v }
        if let v = try string("name") { s.name = v }
        if let v = try string("token") {
            guard let t = v, t.count >= 16 else { throw HTTPError(400, "token must be at least 16 characters (relay/setup.py prints it)") }
            s.token = t
        }
        if let v = body["port"] {
            if v is NSNull { s.port = nil }
            else if let n = v as? Int, (1...65535).contains(n) { s.port = UInt16(n) }
            else { throw HTTPError(400, "port must be 1-65535 or null") }
        }
        if s.enabled, (s.token ?? "").isEmpty { throw HTTPError(400, "enabling the relay needs its token") }
        do { try s.save(config.stateDir) } catch { throw HTTPError(500, "couldn't save relay.json: \(error.localizedDescription)") }
        log(s.enabled ? "relay: reaching the table through \(s.endpoint?.description ?? "?")" : "relay: off; using this Mac's Bluetooth")
        table.useRelay(s.endpoint)
    }
}
