import AppKit
import SwiftUI

/// Read-only discovery of scheduler identities on hosts with remote sessions.
/// Unknown identities remain separate; queue contents and job IDs are not identities.
enum PluginHPCDiscovery {
    struct Host: Sendable {
        let paneID: UUID
        let profile: ConnectionProfile
        let directory: String?
    }
    struct Probe: Sendable {
        let host: Host
        let cluster: String?
        let noSlurm: Bool
        let diagnostic: String?
    }
    static func probe(_ host: Host) async -> Probe {
        await Task.detached(priority: .utility) {
            do {
                let process = Process(), output = Pipe(), errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                // A login shell exposes the host's configured scheduler environment.
                let script = "if ! command -v squeue >/dev/null 2>&1; then exit 44; fi; scontrol show config 2>/dev/null | sed -n 's/^[[:space:]]*ClusterName[[:space:]]*=[[:space:]]*//p'"
                let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
                process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ControlMaster=no", "-o", "ControlPath=~/.ssh/relay-%C"] + host.profile.sshConnectionArguments + ["/bin/bash -lc " + quoted]
                process.standardOutput = output; process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                let captured = try ProcessCapture.run(process, output: output, errors: errors, timeout: 12, maximumBytesPerStream: 4096)
                if process.terminationStatus == 44 {
                    return Probe(host: host, cluster: nil, noSlurm: true, diagnostic: nil)
                }
                guard process.terminationStatus == 0 else {
                    return Probe(host: host, cluster: nil, noSlurm: false,
                                 diagnostic: String(decoding: captured.standardError, as: UTF8.self))
                }
                let name = String(decoding: captured.standardOutput, as: UTF8.self)
                    .split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                return Probe(host: host, cluster: name?.isEmpty == false ? name : nil,
                             noSlurm: false, diagnostic: nil)
            } catch {
                return Probe(host: host, cluster: nil, noSlurm: false, diagnostic: error.localizedDescription)
            }
        }.value
    }
    static func discover(_ hosts: [Host]) async -> [Probe] {
        var result: [Probe] = []
        // Keep discovery bounded independently of the plugin operation budget.
        for offset in stride(from: 0, to: hosts.count, by: 2) {
            let batch = Array(hosts[offset..<min(offset + 2, hosts.count)])
            let probes = await withTaskGroup(of: Probe.self, returning: [Probe].self) { group in
                for host in batch { group.addTask { await probe(host) } }
                var values: [Probe] = []
                for await value in group { values.append(value) }
                return values
            }
            result.append(contentsOf: probes)
            if Task.isCancelled { break }
        }
        return result
    }
}

struct HPCDiscoveryWorkspace: View {
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.relayNativeToolSurface) private var nativeSurface
    let preferredPaneID: UUID
    let close: () -> Void
    private struct Cluster: Identifiable {
        let id: String
        let name: String
        let hosts: [PluginHPCDiscovery.Host]
    }
    @State private var clusters: [Cluster] = []
    @State private var selection = ""
    @State private var discovering = false
    @State private var diagnostics: [String] = []
    @State private var presentation = PluginToolPresentation()
    @State private var chrome = WorkspaceChrome()
    private var selected: Cluster? { clusters.first { $0.id == selection } }
    private var target: PaneModel? {
        guard let cluster = selected else { return nil }
        let host = cluster.hosts.first { $0.paneID == preferredPaneID } ?? cluster.hosts.first
        return host.flatMap { workspace.panes[$0.paneID] }
    }
    private var locked: Bool { presentation.operationLifetime.running || presentation.reviewingAction }
    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            HStack {
                Text("HPC").font(.headline)
                Picker("Cluster", selection: Binding(get: { selection }, set: selectCluster)) {
                    ForEach(clusters) { cluster in Text(cluster.name).tag(cluster.id) }
                }.frame(maxWidth: 320).disabled(discovering || locked)
                if discovering { ProgressView().controlSize(.small) }
                Spacer()
                Button("Discover hosts", systemImage: "arrow.clockwise") { Task { await discover() } }
                    .disabled(discovering || locked)
                if !nativeSurface { RelayIconAction("Close HPC", symbol: "xmark", action: close) }
            }.padding(RelayTheme.spacing(14))
            if let selected {
                Text("Remote hosts: " + selected.hosts.map { $0.profile.host }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(RelayTheme.textMuted).padding(.bottom, RelayTheme.spacing(8))
            }
            if !diagnostics.isEmpty {
                DisclosureGroup("Host discovery (\(diagnostics.count))") {
                    ForEach(diagnostics, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }.padding(.horizontal, RelayTheme.spacing(14)).padding(.bottom, RelayTheme.spacing(8))
            }
            if let target {
                HPCClusterWorkspaceOverlay(workspace: workspace, pane: target, close: close,
                                           presentation: presentation, chrome: chrome).id(selection)
            } else {
                VStack(spacing: RelayTheme.spacing(12)) {
                    Text(discovering ? "Checking remote sessions for Slurm…" : "No remote Slurm queues available")
                    Text("Connect to a remote host with Slurm, then discover hosts.").font(.caption).foregroundStyle(RelayTheme.textMuted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(RelayTheme.surface)
        .task(id: workspace.tabs.flatMap(\.allPaneIDs).map(\.uuidString).sorted().joined(separator: ":")) { await discover() }
    }
    @MainActor private func selectCluster(_ id: String) {
        guard !locked else { return }
        presentation = PluginToolPresentation()
        chrome = WorkspaceChrome()
        if let cluster = clusters.first(where: { $0.id == id }),
           let host = cluster.hosts.first(where: { $0.paneID == preferredPaneID }) ?? cluster.hosts.first {
            presentation.captureOnce(id: host.paneID, profile: host.profile, directory: host.directory)
        }
        selection = id
    }
    @MainActor private func discover() async {
        guard !discovering, !locked else { return }
        discovering = true
        defer { discovering = false }
        var keys = Set<String>()
        let hosts = workspace.panes.values.sorted { $0.profile.host < $1.profile.host }
            .filter { $0.profile.kind == .ssh && keys.insert($0.profile.connectionKey).inserted }
            .map { PluginHPCDiscovery.Host(paneID: $0.id, profile: $0.profile, directory: $0.directory) }
        let probes = await PluginHPCDiscovery.discover(hosts)
        guard !Task.isCancelled else { return }
        var grouped: [String: [PluginHPCDiscovery.Probe]] = [:]
        diagnostics = []
        var absent: [String] = []
        for probe in probes {
            if probe.noSlurm {
                absent.append(probe.host.profile.host)
                diagnostics.append(probe.host.profile.host + ": no Slurm available")
            } else if let diagnostic = probe.diagnostic {
                diagnostics.append(probe.host.profile.host + ": " + diagnostic)
            } else {
                let key = probe.cluster.map { "cluster:" + $0 } ?? "host:" + probe.host.profile.connectionKey
                grouped[key, default: []].append(probe)
                if probe.cluster == nil { diagnostics.append(probe.host.profile.host + ": cluster identity unavailable; kept separate") }
            }
        }
        clusters = grouped.map { key, probes in
            Cluster(id: key, name: probes.first?.cluster ?? probes[0].host.profile.host,
                    hosts: probes.map(\.host).sorted { $0.profile.host < $1.profile.host })
        }.sorted { $0.name < $1.name }
        if !clusters.contains(where: { $0.id == selection }) {
            selectCluster(clusters.first { $0.hosts.contains { $0.paneID == preferredPaneID } }?.id ?? clusters.first?.id ?? "")
        }
        if !absent.isEmpty {
            let dialog = RelayTheme.alert()
            dialog.messageText = "No Slurm available"
            dialog.informativeText = "Slurm is not installed or available in the remote login environment on: " + absent.sorted().joined(separator: ", ")
            dialog.addButton(withTitle: "OK")
            dialog.runModal()
        }
    }
}
