import SwiftUI

/// One Relay pane on one host, as the Sessions monitor shows it.
struct RelaySessionRow: Identifiable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case open = "Open in this window"
        case detached = "Running, not open"
        case dead = "Dead"
    }

    let host: String
    let paneID: UUID
    let pane: RemoteCatalogPane
    let category: Category
    /// Programs running in the pane besides its shell. Nil when the host's
    /// process list could not be read, so idleness is unknown.
    let programs: [String]?

    var id: String { host + "/" + paneID.uuidString }
    var isIdleShell: Bool { category == .detached && programs?.isEmpty == true }
    var retained: Bool { pane.retained == true }
}

enum RelaySessionInventory {
    static func category(state: String, attached: Bool) -> RelaySessionRow.Category {
        if attached { return .open }
        return state == "running" ? .detached : .dead
    }

    /// Names of processes relayd links to the pane, excluding its worker and shell.
    static func programs(for pane: RemoteCatalogPane, processes: [[String: Any]]) -> [String] {
        let id = pane.paneID.lowercased()
        let names = processes.compactMap { row -> String? in
            guard (row["pane_id"] as? String)?.lowercased() == id,
                  let pid = row["pid"] as? Int, pid != pane.workerPID, pid != pane.shellPID,
                  let name = row["name"] as? String else { return nil }
            return (name as NSString).lastPathComponent
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    static func rows(host: String, panes: [RemoteCatalogPane], processes: [[String: Any]]?,
                     attached: (UUID) -> Bool) -> [RelaySessionRow] {
        panes.compactMap { pane in
            guard let id = UUID(uuidString: pane.paneID) else { return nil }
            let category = category(state: pane.state, attached: attached(id))
            let programs = category == .detached ? processes.map { programs(for: pane, processes: $0) } : nil
            return RelaySessionRow(host: host, paneID: id, pane: pane, category: category, programs: programs)
        }
    }

    /// Rows a "clean up" pass may touch: dead records always; detached panes
    /// only when they are known to be idle shells and the caller includes them.
    static func cleanupTargets(_ rows: [RelaySessionRow], includeIdleShells: Bool) -> [RelaySessionRow] {
        rows.filter { $0.category == .dead || (includeIdleShells && $0.isIdleShell) }
    }
}

struct RelaySessionMonitor: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var rows: [RelaySessionRow] = []
    @State private var catalogs: [String: RemoteCatalogSnapshot] = [:]
    @State private var hostErrors: [String: String] = [:]
    @State private var filter: RelaySessionRow.Category?
    @State private var search = ""
    @State private var busy = false
    @State private var receipt: String?
    @State private var proposal: Proposal?

    private struct Proposal: Identifiable {
        let title: String
        let action: String
        let targets: [RelaySessionRow]
        var id: String { action + targets.map(\.id).joined() }
    }

    private var profiles: [(String, ConnectionProfile)] {
        [("This Mac", .local)] + workspace.profileStore.connectableHosts
            .filter { $0.kind == .ssh && $0.backend == .relay }.map { ($0.host, $0) }
    }
    private var visible: [RelaySessionRow] {
        rows.filter { row in
            (filter == nil || row.category == filter) &&
            (search.isEmpty || "\(row.host) \(row.pane.paneID) \(row.pane.title ?? "") \(row.pane.directory ?? "") \(row.programs?.joined(separator: " ") ?? "")"
                .localizedCaseInsensitiveContains(search))
        }
    }
    private var dead: [RelaySessionRow] { RelaySessionInventory.cleanupTargets(rows, includeIdleShells: false) }
    private var idleShells: [RelaySessionRow] { rows.filter(\.isIdleShell) }

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Clear dead (\(dead.count))") {
                    proposal = Proposal(title: "Clear \(dead.count) dead panes?", action: "clear", targets: dead)
                }.disabled(busy || dead.isEmpty)
                Button("End idle shells (\(idleShells.count))", role: .destructive) {
                    proposal = Proposal(title: "End \(idleShells.count) idle shells?", action: "end", targets: idleShells)
                }.disabled(busy || idleShells.isEmpty)
            }
            Picker("Show", selection: $filter) {
                Text("All \(rows.count)").tag(RelaySessionRow.Category?.none)
                ForEach(RelaySessionRow.Category.allCases, id: \.self) { category in
                    Text("\(category.rawValue) \(rows.count { $0.category == category })").tag(Optional(category))
                }
            }.pickerStyle(.segmented)
            TextField("Find a pane, host, folder or program", text: $search)
            ForEach(hostErrors.keys.sorted(), id: \.self) { host in
                Text("\(host): \(hostErrors[host] ?? "")").font(.caption).foregroundStyle(RelayTheme.red).textSelection(.enabled)
            }
            if let receipt { Text(receipt).font(.caption).foregroundStyle(RelayTheme.textMuted).textSelection(.enabled) }
            if visible.isEmpty && !busy { Text("No matching panes").foregroundStyle(RelayTheme.textMuted) }
            ForEach(profiles.map(\.0).filter { host in visible.contains { $0.host == host } }, id: \.self) { host in
                Text(host).font(RelayTheme.font(size: 12, weight: .semibold)).padding(.top, RelayTheme.spacing(4))
                ForEach(visible.filter { $0.host == host }) { row in rowView(row) }
            }
        }
        .padding(RelayTheme.spacing(14))
        .task {
            workspace.profileStore.refreshSSHConfig()
            await refresh()
        }
        .alert(item: $proposal) { proposal in
            Alert(title: Text(proposal.title), message: Text(summary(proposal)),
                  primaryButton: .destructive(Text(proposal.action == "end" ? "End" : "Clear")) {
                      Task { await run(proposal) }
                  }, secondaryButton: .cancel())
        }
    }

    private func rowView(_ row: RelaySessionRow) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(5)) {
            HStack {
                Text(row.pane.title?.isEmpty == false ? row.pane.title! : "Pane")
                    .font(RelayTheme.font(size: 12, weight: .semibold))
                Text(String(row.pane.paneID.prefix(8))).font(.caption.monospaced()).foregroundStyle(RelayTheme.textFaint)
                Spacer()
                switch row.category {
                case .open:
                    Button("Show") { workspace.revealPane(row.paneID) }
                case .detached:
                    Button("Open") { open(row) }.disabled(busy || !row.pane.recoverable)
                    Button("End", role: .destructive) {
                        proposal = Proposal(title: "End this pane?", action: "end", targets: [row])
                    }.disabled(busy)
                case .dead:
                    Button("Clear") {
                        proposal = Proposal(title: "Clear this dead pane?", action: "clear", targets: [row])
                    }.disabled(busy)
                }
            }
            Text(detail(row)).font(.caption).foregroundStyle(RelayTheme.textMuted)
            if let directory = row.pane.directory, !directory.isEmpty {
                Text(directory).font(.caption.monospaced()).foregroundStyle(RelayTheme.textFaint)
            }
            Divider()
        }.textSelection(.enabled)
    }

    private func detail(_ row: RelaySessionRow) -> String {
        var parts = [row.category == .dead ? "Dead · \(row.pane.state)" : row.category.rawValue]
        if row.category == .detached {
            switch row.programs {
            case .none: parts.append("programs unknown")
            case .some(let names) where names.isEmpty: parts.append("idle shell")
            case .some(let names): parts.append("running " + names.joined(separator: ", "))
            }
        }
        if let updated = row.pane.updatedAt { parts.append("last change " + String(updated.prefix(16)).replacingOccurrences(of: "T", with: " ")) }
        if row.retained { parts.append("kept by an upgrade, so relayd never removes it on its own") }
        return parts.joined(separator: " · ")
    }

    private func summary(_ proposal: Proposal) -> String {
        let lines = proposal.targets.prefix(12).map { "\($0.host) · \($0.pane.paneID.prefix(8)) · \($0.pane.directory ?? $0.pane.title ?? "")" }
        let more = proposal.targets.count > 12 ? "\nand \(proposal.targets.count - 12) more" : ""
        let consequence = proposal.action == "end"
            ? "Each pane's shell and anything in it stops, and its record is removed. Its scrollback is lost."
            : "Each pane's leftover worker stops and its record is removed. Its last screen is lost."
        return lines.joined(separator: "\n") + more + "\n\n" + consequence + " Each pane is checked again by exact ID before it is touched."
    }

    private func open(_ row: RelaySessionRow) {
        guard let profile = profiles.first(where: { $0.0 == row.host })?.1 else { return }
        let session = catalogs[row.host]?.sessions.first(where: { $0.panes.contains(where: { $0.paneID == row.pane.paneID }) })
        if workspace.attachRemotePane(profile: profile, remotePane: row.pane, workspaceID: row.pane.workspaceID,
                                      sessionLabel: session?.label ?? profile.name, intoSessionID: workspace.selectedTab?.sessionID) {
            receipt = "Opened \(row.pane.paneID.prefix(8)) from \(row.host)."
            Task { await refresh() }
        } else {
            receipt = "Could not open \(row.pane.paneID.prefix(8)): it does not match its host anymore."
        }
    }

    @MainActor private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var loaded: [RelaySessionRow] = []
        var snapshots: [String: RemoteCatalogSnapshot] = [:]
        var errors: [String: String] = [:]
        for (host, profile) in profiles {
            do {
                let catalog = try await RemoteCatalogService.load(profile: profile)
                let processes = try? await RelayHostFiles.request(
                    context: RelayExecutionContext(profile: profile, directory: "/"),
                    fields: ["operation": "process_list"])["processes"] as? [[String: Any]]
                snapshots[host] = catalog
                loaded += RelaySessionInventory.rows(host: host, panes: catalog.panes, processes: processes) {
                    workspace.panes[$0] != nil
                }
            } catch {
                errors[host] = error.localizedDescription
            }
        }
        rows = loaded; catalogs = snapshots; hostErrors = errors
    }

    @MainActor private func run(_ proposal: Proposal) async {
        guard !busy else { return }
        busy = true
        var done = 0
        var failures: [String] = []
        for row in proposal.targets {
            guard let profile = profiles.first(where: { $0.0 == row.host })?.1 else { continue }
            do {
                // Recheck the exact pane right before touching it.
                let current = try await RemoteCatalogService.load(profile: profile).panes
                    .first(where: { $0.paneID.lowercased() == row.pane.paneID.lowercased() })
                guard let current, workspace.panes[row.paneID] == nil,
                      RelaySessionInventory.category(state: current.state, attached: false) == row.category else {
                    failures.append("\(row.pane.paneID.prefix(8)): changed since listed, skipped"); continue
                }
                if row.isIdleShell {
                    let processes = try? await RelayHostFiles.request(
                        context: RelayExecutionContext(profile: profile, directory: "/"),
                        fields: ["operation": "process_list"])["processes"] as? [[String: Any]]
                    guard let processes, RelaySessionInventory.programs(for: current, processes: processes).isEmpty else {
                        failures.append("\(row.pane.paneID.prefix(8)): no longer an idle shell, skipped"); continue
                    }
                }
                if proposal.action == "end" {
                    try await RemotePaneControlService.terminate(profile: profile, paneID: row.paneID)
                } else {
                    try await RemotePaneControlService.clear(profile: profile, paneID: row.paneID, workerValid: current.recoverable)
                }
                done += 1
            } catch {
                failures.append("\(row.pane.paneID.prefix(8)): \(error.localizedDescription)")
            }
        }
        receipt = "\(proposal.action == "end" ? "Ended" : "Cleared") \(done) of \(proposal.targets.count)." +
            (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
        busy = false
        await refresh()
    }
}
