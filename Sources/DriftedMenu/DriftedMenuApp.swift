import AppKit
import Combine
import DriftedHost
import ServiceManagement
import DriftedKit
import SwiftUI

/// Menu-bar host for drifted-host: runs the daemon in-process (HTTP API, MCP target, table connection)
/// and shows its state. Launched at login by the LaunchAgent in scripts/.
@MainActor
final class Host: ObservableObject {
    let daemon: Daemon?
    @Published var error: String?
    /// False after the user chose Disconnect (or while Choose table is scanning).
    @Published private(set) var wantConnected = true
    /// Shown in the menu when no table has connected for a while.
    @Published private(set) var notFoundHint = false
    private var notReadySince: Date? = Date()
    private var bag: Set<AnyCancellable> = []

    init() {
        var config = Daemon.Config(stateDir: Daemon.defaultStateDir)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--state"), i + 1 < args.count { config.stateDir = URL(fileURLWithPath: args[i + 1]) }
        if let i = args.firstIndex(of: "--port"), i + 1 < args.count, let p = UInt16(args[i + 1]) { config.port = p }
        do {
            let d = try Daemon(config: config)
            daemon = d
            Task { do { try await d.serve() } catch { self.error = "\(error)" } }
            d.table.$status.sink { [weak self] s in
                guard let self else { return }
                if s == .ready { self.notReadySince = nil } else if self.notReadySince == nil { self.notReadySince = Date() }
                self.updateHint()
            }.store(in: &bag)
            Timer.publish(every: 5, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.updateHint() }.store(in: &bag)
        } catch {
            daemon = nil
            self.error = "\(error)"
        }
    }

    func setConnected(_ on: Bool) {
        wantConnected = on
        if on { notReadySince = Date() }
        daemon?.setConnected(on)
        updateHint()
    }

    private func updateHint() {
        guard wantConnected, let since = notReadySince, let status = daemon?.table.status else { notFoundHint = false; return }
        let searching: Bool
        switch status {
        case .idle, .scanning, .connecting, .handshaking, .disconnected: searching = true
        default: searching = false
        }
        notFoundHint = searching && Date().timeIntervalSince(since) > 45
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon (bare SwiftPM executable)
    }
}

struct StatusMenu: View {
    @ObservedObject var table: DriftTable
    @ObservedObject var host: Host

    var body: some View {
        Text(connectionLine)
        if host.notFoundHint {
            Text("No table found yet. Is it switched on, and is the HoMedics app closed on your phone?")
            Text("Wi-Fi models (11\" and newer) aren't supported.")
        }
        if let s = table.tableState {
            Text(s.status == 1 ? "Drawing \(s.patternId) · \(Int(s.progress * 100))%" : "Idle")
        }
        if let a = table.lastAlarm { Text("Latched: \(a.description)") }
        Divider()
        if table.status == .ready {
            Button("Disconnect (let the HoMedics app connect)") { host.setConnected(false) }
        } else if !host.wantConnected {
            Button("Connect") { host.setConnected(true) }
        }
        Button("Choose table…") { ChooseTable.show(host: host) }
        Button("Copy API token") {
            guard let t = host.daemon?.token else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
        }
        Button("Connect your AI…") {
            guard let d = host.daemon else { return }
            ConnectAI.show(port: d.config.port, token: d.token)
        }
        Toggle("Start at login", isOn: Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { ConnectAI.tell("Couldn't change the login item: \(error.localizedDescription). This works from Drifted.app, not a bare build.") }
            }))
        Button("Open state folder") {
            if let dir = host.daemon?.config.stateDir { NSWorkspace.shared.open(dir) }
        }
        Divider()
        Button("Quit Drifted") { NSApp.terminate(nil) }
    }

    var connectionLine: String {
        switch table.status {
        case .ready: return "Connected to \(table.connectedName ?? "table")"
        case .disconnected(let why): return "Disconnected" + (why.map { ": \($0)" } ?? "")
        case .starting: return "Starting… (allow Bluetooth if macOS asks)"
        case .bluetoothOff: return "Bluetooth is off, or Drifted isn't allowed to use it (System Settings → Privacy & Security → Bluetooth)"
        case .scanning: return "Looking for your table…"
        default: return "\(table.status)".capitalized
        }
    }
}

@main
struct DriftedMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var host = Host()

    var body: some Scene {
        MenuBarExtra("Drifted", systemImage: "circle.dotted") {
            if let error = host.error { Text("drifted-host error: \(error)") }
            if let d = host.daemon { StatusMenu(table: d.table, host: host) }
        }
    }
}
