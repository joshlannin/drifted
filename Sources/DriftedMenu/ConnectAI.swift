import AppKit
import SwiftUI
import SystemConfiguration

/// "Connect your AI…": shows a prompt the user pastes into any AI tool, with the MCP server details (this Mac)
/// or the HTTP API address and token (another computer). Drifted never edits other apps' configuration itself.
enum ConnectAI {
    static let repo = "https://github.com/joshlannin/drifted"

    /// drifted-mcp ships next to the host executable inside the app bundle (or the build directory).
    static var mcpPath: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("drifted-mcp").path
    }

    /// http://<this Mac's Bonjour name>.local:<port>, reachable from other machines on the network.
    static func networkURL(port: UInt16) -> String {
        let name = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" } ?? ProcessInfo.processInfo.hostName
        return "http://\(name):\(port)"
    }

    static var localPrompt: String {
        """
        Please connect to my HoMedics Drift sand table through Drifted's MCP server.

        MCP server (stdio, no arguments):
          name:    drifted
          command: \(mcpPath)

        As JSON, for tools that take a config file:
        { "mcpServers": { "drifted": { "command": "\(mcpPath)" } } }

        If you can add MCP servers to your own configuration, check with me, then add it. If you can't, tell me
        exactly where to paste it and what to restart. Once the tools are loaded, call get_status (connection
        should be "ready").

        Before drawing anything, read the drawing guide:
        \(repo)/blob/main/docs/drawing-guide.md

        Then draw a small test: a circle of radius 0.3, previewed first.
        """
    }

    static func networkPrompt(port: UInt16, token: String) -> String {
        """
        Please connect to my HoMedics Drift sand table. It's controlled by Drifted, running on a Mac on my network.

        HTTP API: \(networkURL(port: port))
        Every request needs the header: Authorization: Bearer \(token)
        API description: \(repo)/blob/main/spec/openapi.yaml
        Drawing guide:   \(repo)/blob/main/docs/drawing-guide.md

        Start with GET /status (connection should be "ready"). Preview with POST /patterns/preview before drawing
        with POST /show, and begin with a small test: a circle of radius 0.3.
        """
    }

    private static var window: NSWindow?

    @MainActor
    static func show(port: UInt16, token: String) {
        let model = ConnectAIModel(local: localPrompt, network: networkPrompt(port: port, token: token))
        let w = window ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Connect your AI"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: ConnectAIView(model: model))
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func tell(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Drifted"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

final class ConnectAIModel: ObservableObject {
    @Published var remote = false
    @Published var copied = false
    let local: String
    let network: String

    init(local: String, network: String) { self.local = local; self.network = network }
    var text: String { remote ? network : local }
}

struct ConnectAIView: View {
    @ObservedObject var model: ConnectAIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $model.remote) {
                Text("AI on this Mac").tag(false)
                Text("AI on another computer").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.remote
                 ? "Paste this into the AI tool on the other computer. It contains your table's access token: anyone on your network who has it can control the table."
                 : "Paste this into Claude, Codex or any other AI tool on this Mac. It tells the tool how to add Drifted's MCP server; Drifted doesn't change other apps' settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(model.text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                if model.copied { Text("Copied").foregroundStyle(.secondary) }
                Button("Copy") { ConnectAI.copy(model.text); model.copied = true }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 600, height: 440)
        .onChange(of: model.remote) { _ in model.copied = false }
    }
}
