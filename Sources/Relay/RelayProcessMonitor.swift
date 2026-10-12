import SwiftUI

struct RelayMonitoredProcess: Decodable, Identifiable, Sendable {
    let pid: Int
    let parent_pid: Int
    let cpu_percent: Double
    let memory_bytes: Int64
    let tty: String
    let name: String
    let start: String
    let pane_id: String?
    let terminal: String?
    let job_id: String?
    let relationship: String
    let can_signal: Bool
    var id: String { "\(pid):\(start)" }
}

struct RelayProcessMonitor: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var host = "This Mac"
    @State private var processes: [RelayMonitoredProcess] = []
    @State private var filter = "All"
    @State private var search = ""
    @State private var busy = false
    @State private var error: String?
    @State private var receipt: String?
    @State private var captured: RelayExecutionContext?
    @State private var proposal: SignalProposal?
    private struct SignalProposal: Identifiable {
        let process: RelayMonitoredProcess
        let context: RelayExecutionContext
        let signal: String
        var id: String { process.id + signal }
    }
    private var profiles: [ConnectionProfile] {
        [.local] + workspace.profileStore.connectableHosts.filter { $0.kind == .ssh && $0.backend == .relay }
    }
    private var visible: [RelayMonitoredProcess] {
        processes.filter {
            (filter == "All" || (filter == "Terminals" ? $0.pane_id != nil : $0.pane_id == nil)) &&
            (search.isEmpty || "\($0.pid) \($0.name) \($0.terminal ?? "") \($0.relationship)".localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
            HStack {
                Picker("Host", selection: $host) {
                    ForEach(profiles) { profile in
                        Text(profile.kind == .local ? "This Mac" : profile.host)
                            .tag(profile.kind == .local ? "This Mac" : profile.host)
                    }
                }.disabled(busy)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            Picker("Processes", selection: $filter) {
                Text("All").tag("All")
                Text("Relay terminals").tag("Terminals")
                Text("Agents & services").tag("Background")
            }.pickerStyle(.segmented)
            TextField("Find a process, PID or terminal", text: $search)
            Text("\(captured?.host ?? host) · \(processes.count) related processes")
                .font(.caption).foregroundStyle(RelayTheme.textMuted)
            if let error { Text(error).foregroundStyle(RelayTheme.red).textSelection(.enabled) }
            if let receipt { Text(receipt).font(.caption).foregroundStyle(RelayTheme.textMuted) }
            if visible.isEmpty && !busy { Text("No matching processes").foregroundStyle(RelayTheme.textMuted) }
            ForEach(visible) { process in
                VStack(alignment: .leading, spacing: RelayTheme.spacing(5)) {
                    HStack {
                        Text((process.name as NSString).lastPathComponent).font(RelayTheme.font(size: 12, weight: .semibold))
                        Spacer()
                        Text("PID \(process.pid) · parent \(process.parent_pid)").font(.caption.monospaced())
                    }
                    Text(attachment(process)).font(.caption).foregroundStyle(RelayTheme.textMuted)
                    HStack {
                        Text(String(format: "CPU %.1f%% · %@", process.cpu_percent,
                            ByteCountFormatter.string(fromByteCount: process.memory_bytes, countStyle: .memory)))
                            .font(.caption.monospaced())
                        Spacer()
                        Button("Stop") { propose(process, signal: "terminate") }
                        Button("Force Kill", role: .destructive) { propose(process, signal: "kill") }
                    }.disabled(busy || !process.can_signal)
                    if !process.can_signal { Text("Supervisor · managed through supervisor controls").font(.caption) }
                    Divider()
                }.textSelection(.enabled)
            }
        }.padding(RelayTheme.spacing(14))
        .task {
            workspace.profileStore.refreshSSHConfig()
            host = workspace.executionContext()?.host ?? "This Mac"
            await refresh()
        }
        .onChange(of: host) { _, _ in
            processes = []; captured = nil; error = nil; receipt = nil
            Task { await refresh() }
        }
        .alert(item: $proposal) { proposal in
            Alert(title: Text(proposal.signal == "kill" ? "Force kill this process?" : "Stop this process?"),
                  message: Text("\(proposal.context.host) · PID \(proposal.process.pid)\n\(proposal.process.name)\n\(attachment(proposal.process))\nUnsaved work may be lost. A terminal process may end its session. The process identity is checked again before sending the signal."),
                  primaryButton: .destructive(Text(proposal.signal == "kill" ? "Force Kill" : "Stop")) {
                      Task { await signal(proposal) }
                  }, secondaryButton: .cancel())
        }
    }
    private func attachment(_ process: RelayMonitoredProcess) -> String {
        if let raw = process.pane_id {
            let open = UUID(uuidString: raw).map { workspace.panes[$0] != nil } == true
            return "\(process.terminal ?? "Relay terminal") · \(open ? "open in this window" : "not open in this window")"
        }
        if process.tty != "?" && process.tty != "??" && process.tty != "-" {
            return "\(process.relationship) · other terminal \(process.tty)"
        }
        return "\(process.relationship) · no terminal\(process.job_id.map { " · " + $0 } ?? "")"
    }
    private func propose(_ process: RelayMonitoredProcess, signal: String) {
        guard let captured, !busy else { return }
        proposal = SignalProposal(process: process, context: captured, signal: signal)
    }
    @MainActor private func refresh() async {
        guard !busy, let profile = profiles.first(where: { ($0.kind == .local ? "This Mac" : $0.host) == host }) else { return }
        let context = RelayExecutionContext(profile: profile, directory: "/")
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await RelayHostFiles.request(context: context, fields: ["operation": "process_list"])
            guard let rows = result["processes"] else { throw RelayHostRPCError.invalidRequest }
            processes = try JSONDecoder().decode([RelayMonitoredProcess].self, from: JSONSerialization.data(withJSONObject: rows))
            captured = context
        } catch { self.error = error.localizedDescription; processes = []; captured = nil }
    }
    @MainActor private func signal(_ proposal: SignalProposal) async {
        guard !busy else { return }
        busy = true; error = nil; receipt = nil
        do {
            let result = try await RelayHostFiles.request(context: proposal.context, fields: [
                "operation": "process_signal", "process_pid": proposal.process.pid,
                "process_start": proposal.process.start, "signal": proposal.signal])
            guard result["status"] as? String == "signal_sent" else { throw RelayHostRPCError.outcomeUnknown }
            receipt = "Signal sent to \(proposal.context.host) · PID \(proposal.process.pid). Refresh to inspect its state."
        } catch { self.error = "Signal outcome: " + error.localizedDescription + ". Inspect the process before trying again." }
        busy = false
        await refresh()
    }
}
