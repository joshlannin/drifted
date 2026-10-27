import DriftedKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // `DriftedStudio --open pattern.txt` (or `open DriftedStudio.app --args --open pattern.txt`)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            FileInbox.shared.pending.append(URL(fileURLWithPath: args[i + 1]))
        }
    }

    // `open -a DriftedStudio.app pattern.txt`, drag onto the Dock icon, etc.
    func application(_ application: NSApplication, open urls: [URL]) {
        FileInbox.shared.pending.append(contentsOf: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif

@main
struct DriftedStudioApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    @StateObject private var table = DriftTable()
    @StateObject private var studio = Studio()

    var body: some Scene {
        Window("Drifted Studio", id: "main") {
            ContentView()
                .environmentObject(table)
                .environmentObject(studio)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .defaultSize(width: 1280, height: 860)
    }
}

struct TextFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Files handed to the app from outside (Finder, `open -a`, `--open`).
final class FileInbox: ObservableObject {
    static let shared = FileInbox()
    @Published var pending: [URL] = []
}

struct ContentView: View {
    @EnvironmentObject var table: DriftTable
    @EnvironmentObject var studio: Studio
    @ObservedObject private var inbox = FileInbox.shared

    var body: some View {
        NavigationSplitView {
            TablePanel()
                .navigationSplitViewColumnWidth(min: 260, ideal: 290)
        } detail: {
            EditorView()
        }
        .onReceive(inbox.$pending) { urls in
            guard let url = urls.last else { return }
            inbox.pending = []
            try? studio.importFile(url, watch: true)
        }
    }
}

// MARK: - Table connection / playback

struct TablePanel: View {
    @EnvironmentObject var table: DriftTable
    @StateObject private var ui = PanelUI()

    var body: some View {
        List {
            Section("Table") {
                Label(statusText, systemImage: statusIcon)
                    .foregroundStyle(table.status == .ready ? .green : .primary)
                if let name = table.connectedName, isConnected { Text(name).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    if table.status == .scanning {
                        Button("Stop") { table.stopScan() }
                    } else if !isConnected {
                        Button("Scan") { table.startScan() }.disabled(table.status == .bluetoothOff || table.status == .starting)
                    }
                    if isConnected { Button("Disconnect") { table.disconnect() } }
                }
                Toggle("Show all BLE devices", isOn: $table.scanAll).font(.caption)
            }

            if !isConnected && !table.discovered.isEmpty {
                Section("Nearby") {
                    ForEach(table.discovered) { d in
                        Button { table.connect(d.id) } label: {
                            HStack { Text(d.name); Spacer(); Text("\(d.rssi) dB").foregroundStyle(.secondary).font(.caption) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isConnected {
                Section("Now playing") {
                    if let s = table.tableState {
                        Text("Pattern \(s.patternId)")
                        ProgressView(value: s.progress)
                        Text("Status \(s.status) · speed \(s.speedRaw) · brightness \(s.brightness)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No state yet").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button { send(Command.previous) } label: { Image(systemName: "backward.fill") }
                        Button { send(Command.playPause) } label: { Image(systemName: "playpause.fill") }
                        Button { send(Command.next) } label: { Image(systemName: "forward.fill") }
                    }
                }
                Section("Stored on table") {
                    Text(table.storedPatternIds.isEmpty ? "None reported" : table.storedPatternIds.sorted().map(String.init).joined(separator: ", "))
                        .font(.caption).textSelection(.enabled)
                }
            }

            Section {
                Toggle("Protocol log", isOn: $ui.showLog)
                Toggle("Log raw packets", isOn: $table.logPackets).font(.caption)
            }
        }
        .sheet(isPresented: $ui.showLog) { LogView().frame(minWidth: 700, minHeight: 450) }
    }

    var isConnected: Bool { [.connecting, .handshaking, .ready].contains(table.status) }

    var statusText: String {
        switch table.status {
        case .starting: return "Starting Bluetooth…"
        case .bluetoothOff: return "Bluetooth off / not allowed"
        case .idle: return "Not connected"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .handshaking: return "Handshaking…"
        case .ready: return "Ready"
        case .disconnected(let e): return e.map { "Disconnected: \($0)" } ?? "Disconnected"
        }
    }

    var statusIcon: String { table.status == .ready ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right" }

    func send(_ p: Packet) { Task { try? await table.send(p) } }
}

struct LogView: View {
    @EnvironmentObject var table: DriftTable
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Protocol log").font(.headline)
                Spacer()
                Button("Copy") {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(table.log.map(\.text).joined(separator: "\n"), forType: .string)
                    #endif
                }
                Button("Close") { dismiss() }
            }
            ScrollViewReader { proxy in
                List(table.log) { line in
                    Text(line.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(line.id)
                }
                .onAppear { if let last = table.log.last { proxy.scrollTo(last.id) } }
            }
        }
        .padding()
    }
}

// MARK: - Editor

struct EditorView: View {
    @EnvironmentObject var table: DriftTable
    @EnvironmentObject var studio: Studio

    @StateObject private var ui = EditorUI()

    var body: some View {
        let pattern = studio.pattern
        HStack(spacing: 0) {
            VStack {
                Picker("", selection: $studio.source) {
                    ForEach(Studio.Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                SandCanvas(pattern: pattern, progress: ui.progress, ballDiameter: studio.ballDiameter,
                           connectors: studio.source == .draw ? studio.connectorSegments : [],
                           onStroke: studio.source == .draw ? addPoint : nil)
                    .padding()

                HStack {
                    Button { animate() } label: { Image(systemName: ui.animating ? "stop.fill" : "play.fill") }
                    Slider(value: $ui.progress, in: 0...1)
                    Text(stats(pattern)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                sendBar(pattern)
            }
            .padding(.vertical)

            Divider()
            inspector
                .frame(width: 260)
        }
        .fileImporter(isPresented: $ui.showImporter, allowedContentTypes: [.plainText, UTType(filenameExtension: "thr") ?? .data, .data]) { result in
            if case .success(let url) = result {
                do { try studio.importFile(url) } catch { ui.uploadMessage = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $ui.showExporter, document: TextFile(text: pattern.driftText),
                      contentType: .plainText, defaultFilename: "\(pattern.name).txt") { _ in }
    }

    func addPoint(_ p: CGPoint, began: Bool) {
        ui.progress = 1
        if began { studio.strokes.append([p]) } else if !studio.strokes.isEmpty {
            // Skip sub-pixel jitter.
            if let last = studio.strokes[studio.strokes.count - 1].last, hypot(last.x - p.x, last.y - p.y) < 0.004 { return }
            studio.strokes[studio.strokes.count - 1].append(p)
        }
    }

    func stats(_ p: SandPattern) -> String {
        "\(p.points.count) pts · \(p.pageCount) pages · \(String(format: "%.1f", p.length)) radii of travel"
    }

    func animate() {
        if ui.animating { ui.animating = false; return }
        ui.animating = true
        ui.progress = 0
        Task { @MainActor in
            while ui.animating, ui.progress < 1 {
                try? await Task.sleep(nanoseconds: 16_000_000)
                ui.progress = min(1, ui.progress + 0.004)
            }
            ui.animating = false
        }
    }

    @ViewBuilder
    func sendBar(_ pattern: SandPattern) -> some View {
        HStack(spacing: 12) {
            TextField("Pattern id (auto)", text: $ui.patternId)
                .frame(width: 130)
            Toggle("Draw after upload", isOn: $ui.playAfterUpload)
                .fixedSize()
            Spacer(minLength: 8)
            if let uploadProgress = ui.uploadProgress {
                ProgressView(value: uploadProgress).frame(width: 120)
            } else if let uploadMessage = ui.uploadMessage {
                Text(uploadMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("Export…") { ui.showExporter = true }
                .fixedSize()
                .disabled(pattern.points.isEmpty)
            Button("Send to Table") { upload(pattern) }
                .fixedSize()
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(pattern.points.isEmpty || ui.uploadProgress != nil || table.status != .ready && table.status != .handshaking)
        }
        .padding(.horizontal)
    }

    func upload(_ pattern: SandPattern) {
        let id = UInt16(ui.patternId) ?? table.freePatternId()
        ui.patternId = String(id)
        ui.uploadMessage = nil
        ui.uploadProgress = 0
        Task { @MainActor in
            do {
                try await table.upload(pattern.wirePoints, id: id) { ui.uploadProgress = $0 }
                if ui.playAfterUpload { try await table.play(id) }
                ui.uploadMessage = "Stored as \(id)\(ui.playAfterUpload ? " — drawing" : "")"
            } catch {
                ui.uploadMessage = error.localizedDescription
            }
            ui.uploadProgress = nil
        }
    }

    // MARK: Inspector

    var inspector: some View {
        Form {
            switch studio.source {
            case .draw:
                Section("Drawing") {
                    Stepper("Symmetry: \(studio.symmetry)×", value: $studio.symmetry, in: 1...16)
                    Toggle("Mirror", isOn: $studio.mirror)
                    HStack {
                        Button("Undo stroke") { _ = studio.strokes.popLast() }.disabled(studio.strokes.isEmpty)
                        Button("Clear") { studio.strokes = [] }.disabled(studio.strokes.isEmpty)
                    }
                    Text("Orange dashes are moves you didn't draw — the ball can't lift, so they leave a groove too.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .generate:
                Section("Generator") {
                    Picker("Kind", selection: $studio.generator) {
                        ForEach(Studio.GeneratorKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch studio.generator {
                    case .rose:
                        slider("Petal factor", $studio.petals, 1...12, step: 0.5)
                        slider("Loops", $studio.roseLoops, 1...20, step: 1)
                        slider("Precession", $studio.precession, -0.2...0.2, step: 0.005)
                    case .spirograph:
                        slider("R", $studio.spiroR, 1...12, step: 1)
                        slider("r", $studio.spiror, 1...12, step: 1)
                        slider("d", $studio.spirod, 0...12, step: 0.5)
                        slider("Loops", $studio.spiroLoops, 1...20, step: 1)
                    case .spiral:
                        slider("Turns", $studio.spiralTurns, 2...60, step: 1)
                    }
                }
            case .file:
                Section("Import") {
                    Button("Open .txt / .thr…") { ui.showImporter = true }
                    if let p = studio.imported { Text("\(p.name): \(p.points.count) points").font(.caption) }
                    Text("Drift .txt (theta millidegrees, rho 0–100000) or Sisyphus/Dune Weaver .thr (radians, 0–1).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Output") {
                Toggle("Wipe (spiral) first", isOn: $studio.wipeFirst)
                Toggle("Mirror (if the table draws text backwards)", isOn: $studio.mirrorOutput)
                slider("Rotate °", $studio.rotationDegrees, -180...180, step: 1)
                slider("Ball width", $studio.ballDiameter, 0.02...0.12, step: 0.005)
                Text("Ball width only affects the preview and wipe spacing. Detail finer than the ball disappears in sand.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading) {
            Text("\(label): \(value.wrappedValue, specifier: step < 1 ? "%.3g" : "%.0f")").font(.caption)
            Slider(value: value, in: range, step: step)
        }
    }
}

final class PanelUI: ObservableObject {
    @Published var showLog = false
}

final class EditorUI: ObservableObject {
    @Published var progress = 1.0
    @Published var animating = false
    @Published var showImporter = false
    @Published var showExporter = false
    @Published var patternId = ""
    @Published var playAfterUpload = true
    @Published var uploadProgress: Double?
    @Published var uploadMessage: String?
}
