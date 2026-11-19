import Foundation
import Network

// The Drifted relay (relay/ in this repo): a small Wi-Fi board next to the table that holds the Bluetooth link
// and passes the table's bytes to and from a host over TCP. This file is the host's side of that TCP protocol.
//
// Every message is `type:u8, length:u16 little-endian, payload`. See relay/README.md ("Relay protocol").

public enum RelayMessageType: UInt8 {
    /// host → relay, first message: `flags:u8` then the token (UTF-8). Flag bit 0: observe only (don't take
    /// the table back from a release).
    case hello = 0x01
    /// relay → host: JSON `{proto, firmware, name}` once the token checks out.
    case welcome = 0x02
    /// relay → host: JSON `{error}`; the relay closes the connection after it.
    case error = 0x03
    /// relay → host: bytes the table notified on FFE4, as they arrived (reassemble packets from the stream).
    case tableData = 0x10
    /// host → relay: one table packet to write to FFE9.
    case tableWrite = 0x11
    /// relay → host: JSON link status, on every change and every 5 s.
    case status = 0x20
    /// relay → host: JSON `{tables: [{name, address, addrType, rssi}]}` after a scan.
    case scan = 0x21
    /// host → relay: a command line (`scan`, `select ADDRESS|NAME`, `forget`, `release`, `connect`, …).
    case command = 0x30
    /// relay → host: JSON `{command, ok, message}` answering a command.
    case result = 0x31
    /// relay → host: one line of the relay's log.
    case log = 0x40
}

public struct RelayFrame: Equatable {
    public static let maxPayload = 4096
    public var type: UInt8
    public var payload: [UInt8]

    public init(_ type: RelayMessageType, _ payload: [UInt8] = []) { self.type = type.rawValue; self.payload = payload }
    public init(rawType: UInt8, payload: [UInt8]) { self.type = rawType; self.payload = payload }

    public var kind: RelayMessageType? { RelayMessageType(rawValue: type) }

    public func encoded() -> [UInt8] {
        precondition(payload.count <= Self.maxPayload, "relay frame too long")
        return [type, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)] + payload
    }

    public static func hello(token: String, observe: Bool = false) -> RelayFrame {
        RelayFrame(.hello, [observe ? 1 : 0] + Array(token.utf8))
    }

    public static func command(_ line: String) -> RelayFrame { RelayFrame(.command, Array(line.utf8)) }

    /// The payload as a JSON object (welcome, error, status, scan, result).
    public var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any]
    }
}

public struct RelayFrameParser {
    public enum ParseError: Error, Equatable { case tooLong(Int) }
    private var buffer: [UInt8] = []
    public init() {}

    /// Feeds bytes from the TCP stream; returns the complete frames. Throws if a frame claims more than
    /// `RelayFrame.maxPayload` bytes (the stream is out of step, so the connection should be dropped).
    public mutating func feed<S: Sequence>(_ bytes: S) throws -> [RelayFrame] where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var frames: [RelayFrame] = []
        var offset = 0
        while buffer.count - offset >= 3 {
            let length = Int(buffer[offset + 1]) | Int(buffer[offset + 2]) << 8
            guard length <= RelayFrame.maxPayload else { throw ParseError.tooLong(length) }
            guard buffer.count - offset >= 3 + length else { break }
            frames.append(RelayFrame(rawType: buffer[offset], payload: Array(buffer[(offset + 3)..<(offset + 3 + length)])))
            offset += 3 + length
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return frames
    }
}

/// Where Drifted finds its relay, saved in the state dir as relay.json.
public struct RelayEndpoint: Codable, Equatable {
    public static let defaultPort: UInt16 = 8766
    public static let serviceType = "_drifted-relay._tcp"
    /// IP address or host name. Without it the relay is found by Bonjour (`name`, or the first one found).
    public var host: String?
    public var port: UInt16?
    /// Bonjour instance name, e.g. "drifted-relay-1a2b3c".
    public var name: String?
    public var token: String

    public init(host: String? = nil, port: UInt16? = nil, name: String? = nil, token: String) {
        self.host = host; self.port = port; self.name = name; self.token = token
    }

    public var description: String {
        if let host, !host.isEmpty { return "\(host):\(port ?? Self.defaultPort)" }
        return name ?? "the first relay found on the network"
    }
}

/// A table the relay can see (scan results), or the one it's linked to.
public struct RelayTable: Equatable {
    public var name: String
    public var address: String     // "aa:bb:cc:dd:ee:ff"
    public var addrType: Int       // 0 public, 1 random
    public var rssi: Int?

    public init(name: String, address: String, addrType: Int, rssi: Int?) {
        self.name = name; self.address = address; self.addrType = addrType; self.rssi = rssi
    }

    init?(_ j: [String: Any]) {
        guard let address = j["address"] as? String else { return nil }
        self.init(name: (j["name"] as? String) ?? "", address: address, addrType: (j["addrType"] as? Int) ?? 0,
                  rssi: j["rssi"] as? Int)
    }

    /// Tables behind a relay have no CoreBluetooth identifier; this stands in for one in `DriftTable.discovered`
    /// so the same "choose a table" UI works. It encodes the address, so `address(fromId:)` reverses it.
    public var id: UUID {
        let hex = address.replacingOccurrences(of: ":", with: "").lowercased()
        return UUID(uuidString: String(format: "D21F7000-0000-0000-00%02X-", addrType & 0xFF) + hex) ?? UUID()
    }

    public static func address(fromId id: UUID) -> String? {
        let s = id.uuidString
        guard s.hasPrefix("D21F7000-0000-0000-00") else { return nil }
        let hex = s.suffix(12).lowercased()
        return stride(from: 0, to: 12, by: 2).map { i -> String in
            let a = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[a..<hex.index(a, offsetBy: 2)])
        }.joined(separator: ":")
    }
}

/// The relay's STATUS message.
public struct RelayStatus: Equatable {
    /// "off" (Wi-Fi only, Bluetooth not started), "released" (let go so the phone app can connect),
    /// "scanning", "connecting", or "linked" (connected and subscribed to the table's notifications).
    public var link: String
    public var table: RelayTable?
    /// Signal from the relay to the table, dBm.
    public var rssi: Int?
    public var wifiRssi: Int?
    public var firmware: String?
    /// The relay passes host writes on only after the table asks for a handshake (see relay/README.md).
    public var gate: String?

    public init(link: String, table: RelayTable? = nil, rssi: Int? = nil, wifiRssi: Int? = nil, firmware: String? = nil, gate: String? = nil) {
        self.link = link; self.table = table; self.rssi = rssi; self.wifiRssi = wifiRssi; self.firmware = firmware; self.gate = gate
    }

    public init?(json j: [String: Any]) {
        guard let link = j["link"] as? String else { return nil }
        self.init(link: link, table: (j["table"] as? [String: Any]).flatMap(RelayTable.init), rssi: j["rssi"] as? Int,
                  wifiRssi: j["wifiRssi"] as? Int, firmware: j["firmware"] as? String, gate: j["gate"] as? String)
    }

    public var linked: Bool { link == "linked" }
}

/// One TCP connection to a relay (Network.framework). Callbacks arrive on the main queue.
@MainActor
public final class RelayLink {
    public enum Event {
        case opened(name: String, firmware: String)
        case status(RelayStatus, raw: [String: Any])
        case tableData([UInt8])
        case scan([RelayTable])
        case result([String: Any])
        case log(String)
        case closed(String?)
    }

    public let endpoint: RelayEndpoint
    public let observe: Bool
    public private(set) var isOpen = false
    /// The relay's own name from its welcome, and where we reached it.
    public private(set) var relayName: String?
    public private(set) var remote: String?
    var onEvent: ((Event) -> Void)?

    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var parser = RelayFrameParser()
    private var lastHeard = Date()
    private var watchdog: Timer?
    private var closed = false

    init(endpoint: RelayEndpoint, observe: Bool) {
        self.endpoint = endpoint
        self.observe = observe
    }

    func open() {
        if let host = endpoint.host, !host.isEmpty {
            connect(.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: endpoint.port ?? RelayEndpoint.defaultPort)!))
        } else if let name = endpoint.name, !name.isEmpty {
            connect(.service(name: name, type: RelayEndpoint.serviceType, domain: "local.", interface: nil))
        } else {
            browse()
        }
        // The relay sends its status every 5 s, so 15 s of silence means the connection is dead (Wi-Fi gone,
        // relay rebooted) even if TCP hasn't noticed. Also bounds the time to get a welcome.
        lastHeard = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                let quiet = Date().timeIntervalSince(self.lastHeard)
                if !self.isOpen, quiet > 12 { self.close("no answer from the relay at \(self.endpoint.description)") }
                else if quiet > 15 { self.close("the relay went quiet for 15 s") }
            }
        }
    }

    private func browse() {
        let b = NWBrowser(for: .bonjour(type: RelayEndpoint.serviceType, domain: nil), using: .tcp)
        browser = b
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.connection == nil, !self.closed else { return }
                guard let first = results.map(\.endpoint).sorted(by: { "\($0)" < "\($1)" }).first else { return }
                self.browser?.cancel(); self.browser = nil
                self.connect(first)
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed(let e) = state { self?.close("Bonjour browsing failed: \(e)") }
            }
        }
        b.start(queue: .main)
    }

    private func connect(_ target: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true            // ConfirmData replies are tiny; don't let Nagle hold them back
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.connectionTimeout = 10
        let c = NWConnection(to: target, using: NWParameters(tls: nil, tcp: tcp))
        connection = c
        remote = "\(target)"
        c.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.connection === c else { return }
                switch state {
                case .ready:
                    if let r = c.currentPath?.remoteEndpoint { self.remote = "\(r)" }
                    c.send(content: Data(RelayFrame.hello(token: self.endpoint.token, observe: self.observe).encoded()),
                           completion: .contentProcessed { _ in })
                    self.receive(c)
                case .waiting(let e): self.close("can't reach the relay at \(self.remote ?? self.endpoint.description): \(e)")
                case .failed(let e): self.close("relay connection failed: \(e)")
                case .cancelled: self.close(nil)
                default: break
                }
            }
        }
        c.start(queue: .main)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.connection === c, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.lastHeard = Date()
                    do {
                        for frame in try self.parser.feed(data) { self.dispatch(frame) }
                    } catch {
                        self.close("relay sent a malformed frame (\(error))"); return
                    }
                }
                if let error { self.close("relay connection error: \(error)"); return }
                if complete { self.close("the relay closed the connection"); return }
                if !self.closed { self.receive(c) }
            }
        }
    }

    private func dispatch(_ frame: RelayFrame) {
        switch frame.kind {
        case .welcome:
            let j = frame.json ?? [:]
            isOpen = true
            relayName = j["name"] as? String
            onEvent?(.opened(name: relayName ?? "relay", firmware: (j["firmware"] as? String) ?? "?"))
        case .error:
            close("relay refused the connection: \((frame.json?["error"] as? String) ?? "unknown error")")
        case .tableData:
            onEvent?(.tableData(frame.payload))
        case .status:
            if let j = frame.json, let s = RelayStatus(json: j) { onEvent?(.status(s, raw: j)) }
        case .scan:
            let tables = ((frame.json?["tables"] as? [[String: Any]]) ?? []).compactMap(RelayTable.init)
            onEvent?(.scan(tables))
        case .result:
            onEvent?(.result(frame.json ?? [:]))
        case .log:
            onEvent?(.log(String(decoding: frame.payload, as: UTF8.self)))
        default:
            break   // unknown types are ignored so the relay can add messages
        }
    }

    /// Sends one frame; returns when the network stack has taken it (keeps writes in order).
    func send(_ frame: RelayFrame) async throws {
        guard let c = connection, isOpen, !closed else { throw DriftError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: Data(frame.encoded()), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func close(_ reason: String?) {
        guard !closed else { return }
        closed = true
        isOpen = false
        watchdog?.invalidate(); watchdog = nil
        browser?.cancel(); browser = nil
        connection?.cancel()
        onEvent?(.closed(reason))
    }

    /// Looks for relays on the local network for `seconds`. Returns their Bonjour names with TXT details.
    public static func discover(seconds: Double = 3) async -> [[String: Any]] {
        final class Found: @unchecked Sendable { var byName: [String: [String: Any]] = [:] }   // touched on main only
        let found = Found()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: serviceTypeName, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            MainActor.assumeIsolated {
                for r in results {
                    guard case .service(let name, _, _, _) = r.endpoint else { continue }
                    var entry: [String: Any] = ["name": name]
                    if case .bonjour(let txt) = r.metadata {
                        for (k, v) in txt.dictionary { entry[k] = v }
                    }
                    found.byName[name] = entry
                }
            }
        }
        b.start(queue: .main)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        b.cancel()
        return found.byName.keys.sorted().map { found.byName[$0]! }
    }

    private static var serviceTypeName: String { RelayEndpoint.serviceType }
}
