import DriftedHost
import Foundation

// drifted-host — holds the Drift table's BLE connection and serves a local HTTP/JSON API with SSE events.
// Usage: drifted-host [--port N] [--state DIR] [--device UUID]
setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}

var config = Daemon.Config(stateDir: Daemon.defaultStateDir)
if let p = option("--port").flatMap(UInt16.init) { config.port = p }
if let d = option("--state") { config.stateDir = URL(fileURLWithPath: d) }
config.device = option("--device").flatMap(UUID.init(uuidString:))

var daemon: Daemon?
Task { @MainActor in
    do {
        let d = try Daemon(config: config)
        daemon = d
        try await d.serve()
    } catch {
        print("drifted-host: \(error)")
        exit(1)
    }
}
RunLoop.main.run()
