import AppKit
import Network
import SwiftUI

@MainActor final class RelayVPNStore: ObservableObject {
    static let shared = RelayVPNStore()
    nonisolated private static let executable = "/opt/cisco/secureclient/bin/vpn"
    @Published private(set) var state = "Checking"
    @Published private(set) var events: [String] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var checkingSleep = false
    @Published private(set) var probingOpenConnect = false
    @Published private(set) var openConnectResult: String?
    nonisolated private static var openConnectExecutable: String? {
        ["/opt/homebrew/bin/openconnect", "/usr/local/bin/openconnect"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    var openConnectInstalled: Bool { Self.openConnectExecutable != nil }
    private var baseline: Set<UUID> = []
    private var active = false
    private var observers: [NSObjectProtocol] = []
    private var pathMonitor = NWPathMonitor()
    private var lastPathAvailable: Bool?
    private weak var workspace: WorkspaceModel?

    var installed: Bool { FileManager.default.isExecutableFile(atPath: Self.executable) }

    func start(workspace: WorkspaceModel? = nil) {
        if let workspace { self.workspace = workspace }
        guard observers.isEmpty else { return }
        active = true
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    Self.shared.record("Laptop sleeping")
                    RelayNodeTransportPool.shared.setSystemSleeping(true)
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    let store = Self.shared
                    store.record("Laptop awake")
                    RelayNodeTransportPool.shared.setSystemSleeping(false)
                    RelayNodeTransportPool.shared.resumeAfterNetworkChange()
                    store.checkRetainedPanes()
                    await store.refresh()
                }
            }
        ]
        pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            Task { @MainActor in
                let store = Self.shared
                guard store.active else { return }
                if let previous = store.lastPathAvailable, previous != available {
                    store.record(available ? "Network available" : "Network unavailable")
                    if available { RelayNodeTransportPool.shared.resumeAfterNetworkChange() }
                    await store.refresh()
                }
                store.lastPathAvailable = available
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "relay.vpn.path"))
        Task { await refresh() }
    }

    func stop() {
        active = false
        RelayOpenConnectStore.shared.cancel()
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers = []
        pathMonitor.cancel()
        RelayNodeTransportPool.shared.setSystemSleeping(false)
    }

    // Keep Cisco CLI queries short lived: an interactive CLI can acquire the
    // connection capability and prevent Cisco Secure Client from connecting.
    private func acceptState(_ line: String) {
        guard let range = line.range(of: ">> state:", options: .caseInsensitive) else { return }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let states = ["Connected", "Disconnected", "Connecting", "Disconnecting", "Reconnecting", "Unknown"]
        guard let known = states.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }), known != state else { return }
        state = known
        record("VPN " + known.lowercased())
    }

    private nonisolated static func command(_ argument: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [argument]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = errors
            let result = try ProcessCapture.run(process, output: output, errors: errors,
                                                timeout: 8, maximumBytesPerStream: 32_768)
            guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
            return String(decoding: result.standardOutput, as: UTF8.self)
        }.value
    }

    func refresh() async {
        guard active else { return }
        guard !busy else { return }
        guard installed else { state = "Not installed"; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let text = try await Self.command("state")
            guard active else { return }
            for line in text.split(whereSeparator: \.isNewline) { acceptState(String(line)) }
            if checkingSleep {
                let links = RelayNodeTransportPool.shared.networkSnapshots()
                record("\(links.filter { $0.phase == .ready }.count)/\(links.count) Relay connections ready")
            }
        } catch { self.error = "Cisco status unavailable. Try Refresh." }
    }

    func connectOrLogin() {
        error = nil
        let url = URL(fileURLWithPath: "/Applications/Cisco/Cisco Secure Client.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, failure in
            if failure != nil { Task { @MainActor in Self.shared.error = "Could not open Cisco Secure Client." } }
        }
        record("Cisco opened for connection or login")
    }

    func disconnect() async {
        guard !busy else { return }
        busy = true; error = nil
        do { _ = try await Self.command("disconnect"); record("Disconnect requested") }
        catch { self.error = "Cisco could not disconnect." }
        busy = false
        await refresh()
    }

    func probeOpenConnect() async {
        guard active, !probingOpenConnect else { return }
        guard let executable = Self.openConnectExecutable else { openConnectResult = "OpenConnect is not installed."; return }
        probingOpenConnect = true
        openConnectResult = nil
        defer { probingOpenConnect = false }
        do {
            let result = try await Task.detached(priority: .utility) {
                let process = Process(), output = Pipe(), errors = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                // Authentication discovery only: no credentials, browser, tunnel or routing changes.
                process.arguments = ["--protocol=anyconnect", "--authenticate", "--non-inter", "--no-passwd", "https://vpn.ku.dk"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output; process.standardError = errors
                let captured = try ProcessCapture.run(process, output: output, errors: errors,
                                                      timeout: 15, maximumBytesPerStream: 65_536)
                let text = (String(decoding: captured.standardOutput, as: UTF8.self) + String(decoding: captured.standardError, as: UTF8.self)).lowercased()
                // Never publish raw authentication responses or cookies.
                if text.contains("certificate verify failed") || text.contains("server certificate verify failed") || text.contains("ssl connection failure") {
                    return "Certificate or TLS verification failed."
                }
                if text.contains("single-sign-on-external-browser") || text.contains("saml") {
                    return "KU gateway reached. Browser authentication detected; no tunnel created."
                }
                if text.contains("password") || text.contains("username") || text.contains("auth form") {
                    return "KU gateway reached. Login form detected; no credentials supplied or tunnel created."
                }
                return "Compatibility not established. No tunnel created."
            }.value
            guard active else { return }
            openConnectResult = result
            record("OpenConnect compatibility check completed")
        } catch { openConnectResult = "Compatibility check unavailable. No tunnel created." }
    }

    func beginSleepCheck(workspace: WorkspaceModel) {
        self.workspace = workspace
        baseline = Set(workspace.panes.keys)
        checkingSleep = true
        events = []
        record("Sleep check started · \(baseline.count) panes · VPN \(state.lowercased())")
        Task { await refresh() }
    }

    func endSleepCheck() {
        checkRetainedPanes()
        record("Sleep check finished")
        checkingSleep = false
    }

    private func checkRetainedPanes() {
        guard checkingSleep, let workspace else { return }
        let retained = baseline.intersection(Set(workspace.panes.keys)).count
        record("\(retained)/\(baseline.count) original panes retained")
    }

    private func record(_ message: String) {
        events.append(Date().formatted(date: .omitted, time: .standard) + " · " + message)
        if events.count > 48 { events.removeFirst(events.count - 48) }
    }
}

struct RelayVPNPanel: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var store = RelayVPNStore.shared
    let pluginID: String
    let digest: String
    @ObservedObject private var manager = RelayPluginManager.shared
    private var authorized: Bool { manager.installations[pluginID]?.enabled == true && manager.installations[pluginID]?.current.digest == digest }
    @State private var backend = "OpenConnect"
    @State private var details = false
    @State private var confirmingDisconnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RelayTheme.spacing(0)) {
                HStack {
                    Label("VPN", systemImage: "lock.shield").font(.headline)
                    Spacer()
                    Picker("Backend", selection: $backend) {
                        Text("OpenConnect").tag("OpenConnect")
                        Text("Cisco").tag("Cisco")
                    }.pickerStyle(.segmented).frame(width: 220)
                }.padding(RelayTheme.spacing(22))
                Divider()
                if backend == "OpenConnect" {
                    RelayVPNConnectionView(ciscoConnected: store.state == "Connected")
                } else {
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(16)) {
                        HStack {
                            Image(systemName: "shield.lefthalf.filled").font(RelayTheme.font(size: 30)).foregroundStyle(store.state == "Connected" ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                                Text("Cisco Secure Client").font(.title2.weight(.semibold))
                                Text(store.state).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.busy { ProgressView().controlSize(.small) }
                        }
                        Text("Managed VPN connection").font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Open Cisco login…") { store.connectOrLogin() }.disabled(!store.installed || store.busy)
                            if store.state == "Connected" {
                                Button("Disconnect", role: .destructive) { confirmingDisconnect = true }.disabled(store.busy)
                            }
                            Spacer()
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }.disabled(store.busy)
                        }
                        if let error = store.error { Text(error).font(.callout).foregroundStyle(.orange) }
                    }.padding(RelayTheme.spacing(22))
                }
                Divider()
                VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
                    HStack {
                        Button { details.toggle() } label: {
                            Label("Sleep and reconnect", systemImage: details ? "chevron.down" : "chevron.right")
                        }.buttonStyle(.plain).font(.callout.weight(.medium))
                        Spacer()
                        Text("Cisco: " + store.state).font(.caption).foregroundStyle(.secondary)
                    }
                    if details {
                        Text("Track VPN recovery and retained Relay panes across a normal laptop sleep.").font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button(store.checkingSleep ? "Finish check" : "Start sleep check") {
                                if store.checkingSleep { store.endSleepCheck() }
                                else { store.beginSleepCheck(workspace: workspace) }
                            }
                            Spacer()
                            if !store.events.isEmpty { Button("Copy log") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(store.events.joined(separator: "\n"), forType: .string)
                            } }
                        }
                        if store.checkingSleep { Text("Close the lid, then reopen. Complete Cisco login if requested.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(Array(store.events.enumerated()), id: \.offset) { _, event in Text(event).font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(RelayTheme.spacing(22))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(!authorized)
        .task {
            do { try await manager.authorize(id: pluginID, digest: digest, operation: .vpn); store.start(workspace: workspace) }
            catch { }
        }
        .confirmationDialog("Disconnect the Cisco VPN?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) { Task { await store.disconnect() } }
        }
    }
}
