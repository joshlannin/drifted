import AppKit
import DriftedHost
import DriftedKit
import SwiftUI

/// "Choose table…": lets go of the current table, scans, and saves the one the user picks. The host's
/// supervisor then connects to it (it reads the saved device on every reconnect). Closing the window without
/// choosing reconnects to the previous table.
@MainActor
final class ChooseTableModel: NSObject, ObservableObject, NSWindowDelegate {
    let host: Host
    let table: DriftTable
    let deviceFile: URL
    let current: UUID?
    private var chosen = false

    init(host: Host, daemon: Daemon) {
        self.host = host
        table = daemon.table
        deviceFile = daemon.config.stateDir.appendingPathComponent("device")
        current = (try? String(contentsOf: deviceFile)).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func start() {
        host.setConnected(false)
        // Give the table a moment to drop the connection so it advertises again and shows up in the list.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.chosen else { return }
            self.table.startScan()
        }
    }

    func choose(_ id: UUID) {
        chosen = true
        try? id.uuidString.write(to: deviceFile, atomically: true, encoding: .utf8)
        table.stopScan()
        host.setConnected(true)
        ChooseTable.window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !chosen else { return }
        chosen = true
        table.stopScan()
        host.setConnected(true)
    }
}

struct ChooseTableView: View {
    @ObservedObject var model: ChooseTableModel
    @ObservedObject var table: DriftTable

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tables nearby")
                .font(.headline)
            Text("Drifted has let go of its table while it looks. Close the HoMedics app on your phone and make sure the table is on. Wi-Fi models (11\") don't appear: they aren't supported.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(table.discovered.sorted { $0.rssi > $1.rssi }) { t in
                HStack {
                    VStack(alignment: .leading) {
                        Text(t.name + (t.id == model.current ? "  (current)" : ""))
                        Text("Signal \(t.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use this table") { model.choose(t.id) }
                }
            }
            .overlay {
                if table.discovered.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Searching…").foregroundStyle(.secondary) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { ChooseTable.window?.close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 460, height: 360)
    }
}

@MainActor
enum ChooseTable {
    static var window: NSWindow?
    private static var model: ChooseTableModel?

    static func show(host: Host) {
        guard let daemon = host.daemon else { return }
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let m = ChooseTableModel(host: host, daemon: daemon)
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Choose table"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: ChooseTableView(model: m, table: daemon.table))
        w.delegate = m
        w.center()
        window = w
        model = m
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        m.start()
    }
}
