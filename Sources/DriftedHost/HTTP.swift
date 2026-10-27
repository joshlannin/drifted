import Foundation
import Network

/// Minimal HTTP/1.1 server (one request per connection) with Server-Sent Events.
/// Enough for drifted-host's local JSON API; no dependencies beyond Network.framework.
struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]   // lower-cased names
    var body: Data

    func json<T: Decodable>(_ type: T.Type) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: body.isEmpty ? Data("{}".utf8) : body) }
        catch { throw HTTPError(400, "bad JSON body: \(error)") }
    }
}

struct HTTPResponse {
    var status: Int
    var contentType = "application/json"
    var body: Data

    static func json(_ value: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }
    static func encodable<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return HTTPResponse(status: status, body: (try? enc.encode(value)) ?? Data("{}".utf8))
    }
}

struct HTTPError: Error {
    var status: Int
    var message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

/// A connected SSE client; `send` writes one event.
final class SSEClient {
    let connection: NWConnection
    init(_ c: NWConnection) { connection = c }
    func send(event: String, json: Data) {
        var chunk = Data("event: \(event)\ndata: ".utf8); chunk += json; chunk += Data("\n\n".utf8)
        connection.send(content: chunk, completion: .contentProcessed { _ in })
    }
}

final class HTTPServer {
    typealias Handler = @MainActor (HTTPRequest) async -> HTTPResponse
    private let listener: NWListener
    private let handler: Handler
    private let onSSE: @MainActor (SSEClient) -> Void
    private let onSSEClose: @MainActor (SSEClient) -> Void

    init(port: UInt16, handler: @escaping Handler, onSSE: @escaping @MainActor (SSEClient) -> Void,
         onSSEClose: @escaping @MainActor (SSEClient) -> Void) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        self.handler = handler; self.onSSE = onSSE; self.onSSEClose = onSSEClose
    }

    func start() {
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: .main)
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        read(c, buffer: Data())
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf += data }
            if let req = Self.parse(buf) {
                MainActor.assumeIsolated { self.dispatch(req, on: c) }
            } else if done || error != nil || buf.count > 16 << 20 {
                c.cancel()
            } else {
                self.read(c, buffer: buf)
            }
        }
    }

    @MainActor private func dispatch(_ req: HTTPRequest, on c: NWConnection) {
        if req.method == "GET" && req.path == "/events" {
            Task { @MainActor in
                // Auth runs through the normal handler first (it returns 204 for an authorised /events).
                let check = await handler(req)
                guard check.status == 204 else { return self.write(check, to: c) }
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
                c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                let client = SSEClient(c)
                self.onSSE(client)
                c.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed, .cancelled: MainActor.assumeIsolated { self?.onSSEClose(client) }
                    default: break
                    }
                }
                // Detect the client going away (a read returns done).
                c.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in c.cancel() }
            }
            return
        }
        Task { @MainActor in self.write(await self.handler(req), to: c) }
    }

    private func write(_ r: HTTPResponse, to c: NWConnection) {
        let reason = [200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
                      404: "Not Found", 409: "Conflict", 500: "Internal Server Error", 503: "Service Unavailable"][r.status] ?? "Status"
        var out = Data("HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n\r\n".utf8)
        out += r.body
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    /// Returns a request once headers and the full body (per Content-Length) are in `buf`.
    static func parse(_ buf: Data) -> HTTPRequest? {
        guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buf[headEnd.upperBound...]
        guard body.count >= length else { return nil }
        let target = String(parts[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(parts[0]), path: comps?.path ?? target, query: query, headers: headers,
                           body: Data(body.prefix(length)))
    }
}
