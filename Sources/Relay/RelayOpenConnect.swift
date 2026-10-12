import AppKit
import SwiftUI
import ServiceManagement

struct RelayVPNChoice: Decodable, Identifiable {
    let value: String
    let label: String
    var id: String { value }
}
struct RelayVPNField: Decodable, Identifiable {
    let id: String
    let label: String
    let kind: String
    let choices: [RelayVPNChoice]
    let initial: String
}
struct RelayVPNAuthEvent: Decodable {
    let type: String
    let id: Int?
    let message: String?
    let banner: String?
    let error: String?
    let fields: [RelayVPNField]?
    let url: String?
}

@MainActor final class RelayOpenConnectStore: ObservableObject {
    static let shared = RelayOpenConnectStore()
    @Published var gateway = "https://vpn.ku.dk"
    @Published private(set) var phase = "Not connected"
    @Published private(set) var message = "Sign in to your VPN using OpenConnect."
    @Published private(set) var form: RelayVPNAuthEvent?
    @Published private(set) var running = false
    @Published private(set) var failure: String?
    @Published private(set) var helperStatus = "Not installed"
    @Published private(set) var helperEnabled = false
    @Published private(set) var browserHost: String?
    @Published private(set) var connectedAt: Date?
    private var browserURL: URL?
    private var service: SMAppService { .daemon(plistName: "dev.relay.terminal.vpn-network.plist") }
    func refreshHelper() {
        switch service.status {
        case .enabled: helperStatus = "Ready"; helperEnabled = true
        case .requiresApproval: helperStatus = "Awaiting macOS approval"; helperEnabled = false
        case .notRegistered: helperStatus = "Not installed"; helperEnabled = false
        case .notFound: helperStatus = "Helper unavailable"; helperEnabled = false
        @unknown default: helperStatus = "Unavailable"; helperEnabled = false
        }
    }
    func prepareHelper() {
        guard !running else { return }
        do {
            if service.status == .notRegistered || service.status == .notFound { try service.register() }
            refreshHelper()
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { failure = "macOS could not register the VPN network helper. " + error.localizedDescription; refreshHelper() }
    }
    func removeHelper() async {
        guard !running else { failure = "Disconnect OpenConnect before removing its helper."; return }
        do { try await service.unregister(); refreshHelper() }
        catch { failure = "macOS could not remove the VPN helper." }
    }
    func openBrowser() {
        guard let browserURL else { return }
        NSWorkspace.shared.open(browserURL)
        self.browserURL = nil; browserHost = nil
    }
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var generation = UUID()
    private var watchdog: Task<Void, Never>?
    var available: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path) &&
        ["/opt/homebrew/opt/openconnect/lib/libopenconnect.dylib", "/usr/local/opt/openconnect/lib/libopenconnect.dylib"].contains { FileManager.default.fileExists(atPath: $0) }
    }
    private var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/relay-vpn-auth") }

    func start() {
        guard !running else { return }
        refreshHelper()
        guard helperEnabled else { failure = "Set up and approve the VPN network helper first."; return }
        guard available else { failure = "OpenConnect or its Relay authentication bridge is not installed."; return }
        let address = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              address.utf8.count < 2048 else { failure = "Enter an HTTPS gateway address without login details."; return }
        generation = UUID()
        let token = generation
        failure = nil; form = nil; buffer = Data(); running = true
        phase = "Contacting gateway"; message = "Requesting the gateway’s sign-in form…"
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.arguments = [address, "--connect"]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        process = child; input = stdin; output = stdout
        do {
            try child.run(); armTimeout(seconds: 30)
            // One reader preserves form/progress/exit ordering and never blocks the UI.
            Task.detached(priority: .utility) {
                while let data = try? stdout.fileHandleForReading.read(upToCount: 16_384), !data.isEmpty {
                    await MainActor.run {
                        guard Self.shared.generation == token else { return }
                        Self.shared.consume(data)
                    }
                }
                child.waitUntilExit()
                await MainActor.run {
                    let store = Self.shared
                    guard store.generation == token else { return }
                    store.cleanup()
                    if !["Sign-in verified", "Disconnected"].contains(store.phase) && store.failure == nil {
                        store.phase = "Not connected"
                        store.failure = "Sign-in did not complete. Try again."
                    }
                }
            }
        }
        catch { cleanup(); phase = "Unavailable"; failure = "The OpenConnect authentication bridge could not start." }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= 131_072 else { cancel(); failure = "The gateway response was too large."; return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard line.count <= 65_536, let event = try? JSONDecoder().decode(RelayVPNAuthEvent.self, from: line) else { continue }
            switch event.type {
            case "form":
                guard let fields = event.fields, fields.count <= 32, event.id != nil else { continue }
                form = event; phase = "Sign in"; message = "Enter the details requested by your VPN gateway."
                armTimeout(seconds: 300)
            case "progress":
                message = event.message ?? "Signing in…"
            case "browser":
                guard let address = event.url, address.utf8.count <= 16_384,
                      let url = URL(string: address), url.scheme == "https", let host = url.host,
                      url.user == nil, url.password == nil else { cancel(); failure = "The browser sign-in URL is invalid."; return }
                browserURL = url; browserHost = host; phase = "Browser sign-in"
                message = "Continue sign-in in your browser."
                armTimeout(seconds: 300)
            case "connected":
                form = nil; browserURL = nil; browserHost = nil; watchdog?.cancel(); watchdog = nil
                phase = "Connected"; connectedAt = Date(); message = "VPN traffic is routed through OpenConnect."
            case "disconnected":
                phase = "Disconnected"; connectedAt = nil; message = "VPN disconnected."
            case "authenticated":
                form = nil; phase = "Sign-in verified"
                message = event.message ?? "Sign-in verified. Tunnel setup is required."
            case "error":
                form = nil; phase = "Not connected"
                // Only fixed bridge status strings reach this property; raw library output is discarded.
                if failure == nil { failure = event.message ?? "Sign-in failed." }
            default: break
            }
        }
    }

    func submit(_ values: [String: String]) {
        guard running, let form, let id = form.id, let input,
              values.count <= 32, values.values.allSatisfy({ $0.utf8.count <= 8192 }) else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: ["id": id, "values": values])
            guard data.count < 65_536 else { failure = "Sign-in input is too large."; return }
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
            data.resetBytes(in: data.startIndex..<data.endIndex)
            self.form = nil; phase = "Signing in"; message = "Waiting for the VPN gateway…"
            armTimeout(seconds: 60)
        } catch { cancel(); failure = "The sign-in session ended. Try again." }
    }

    func cancel() {
        generation = UUID()
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        let connected = phase == "Connected"
        cleanup(); phase = "Disconnected"; message = connected ? "VPN disconnected." : "Sign-in cancelled."
    }
    private func cleanup() {
        watchdog?.cancel(); watchdog = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        input = nil; output = nil; process = nil; form = nil; browserURL = nil; browserHost = nil; connectedAt = nil; buffer = Data(); running = false
    }
    private func armTimeout(seconds: UInt64) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            guard let self, self.running else { return }
            self.cancel(); self.failure = "The sign-in session timed out. Try again."
        }
    }
}

private struct RelayVPNLoginForm: View {
    let form: RelayVPNAuthEvent
    let submit: ([String: String]) -> Void
    let cancel: () -> Void
    @State private var values: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(14)) {
            if let banner = form.banner, !banner.isEmpty { Text(banner).font(.callout).textSelection(.enabled) }
            if let message = form.message, !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
            if let error = form.error, !error.isEmpty { Text(error).foregroundStyle(.orange) }
            ForEach(form.fields ?? []) { field in
                VStack(alignment: .leading, spacing: RelayTheme.spacing(5)) {
                    Text(field.label).font(.callout.weight(.medium))
                    if field.kind == "password" {
                        SecureField(field.label, text: binding(field)).textFieldStyle(.roundedBorder)
                    } else if field.kind == "select" {
                        Picker(field.label, selection: binding(field)) {
                            ForEach(field.choices) { choice in Text(choice.label).tag(choice.value) }
                        }.labelsHidden()
                    } else {
                        TextField(field.label, text: binding(field)).textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Button("Continue") {
                    let response = Dictionary(uniqueKeysWithValues: (form.fields ?? []).map { ($0.id, values[$0.id] ?? $0.initial) })
                    submit(response); values.removeAll(keepingCapacity: false)
                }.buttonStyle(RelayPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            Text("Login details are used for this sign-in only.").font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { values.removeAll(keepingCapacity: false) }
    }
    private func binding(_ field: RelayVPNField) -> Binding<String> {
        Binding(get: { values[field.id] ?? field.initial }, set: { values[field.id] = $0 })
    }
}

struct RelayVPNConnectionView: View {
    @ObservedObject private var native = RelayOpenConnectStore.shared
    let ciscoConnected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(18)) {
            HStack(spacing: RelayTheme.spacing(12)) {
                Image(systemName: "network.badge.shield.half.filled").font(RelayTheme.font(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                    Text("OpenConnect").font(.title2.weight(.semibold))
                    Text(native.phase).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if native.running && native.phase != "Connected" { ProgressView().controlSize(.small) }
            }
            VStack(alignment: .leading, spacing: RelayTheme.spacing(6)) {
                Text("VPN gateway").font(.callout.weight(.medium))
                TextField("https://vpn.example.org", text: $native.gateway).textFieldStyle(.roundedBorder).disabled(native.running)
                Text("Cisco AnyConnect protocol").font(.caption).foregroundStyle(.secondary)
            }
            if let form = native.form {
                RelayVPNLoginForm(form: form, submit: native.submit, cancel: native.cancel).id(form.id)
            } else {
                Text(native.message).font(.callout).foregroundStyle(.secondary)
                if let error = native.failure { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
                if ciscoConnected {
                    Label("Cisco is connected. Disconnect it before signing in with OpenConnect.", systemImage: "checkmark.shield").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    if let browserHost = native.browserHost {
                        Button("Open " + browserHost, action: native.openBrowser).buttonStyle(RelayPrimaryButtonStyle())
                    }
                    if native.running { Button(native.phase == "Connected" ? "Disconnect" : "Cancel", action: native.cancel) }
                    else { Button("Connect", action: native.start).buttonStyle(RelayPrimaryButtonStyle()).disabled(!native.available || !native.helperEnabled || ciscoConnected) }
                    Spacer()
                }
            }
            Divider()
            HStack {
                Label("Network helper: " + native.helperStatus, systemImage: native.helperEnabled ? "checkmark.shield" : "wrench.and.screwdriver").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if native.helperEnabled { Button("Remove helper") { Task { await native.removeHelper() } }.disabled(native.running) }
                else { Button(native.helperStatus == "Awaiting macOS approval" ? "Open System Settings…" : "Set up helper…", action: native.prepareHelper).disabled(native.running) }
            }
        }
        .padding(RelayTheme.spacing(22))
        .task { native.refreshHelper() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in native.refreshHelper() }
    }
}
