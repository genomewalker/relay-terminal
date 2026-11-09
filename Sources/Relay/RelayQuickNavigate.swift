import SwiftUI

/// One summonable metadata overview. Opening it does not acknowledge activity.
struct RelayQuickNavigate: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var activityIndex: WorkspaceActivityIndex
    @State private var query = ""
    @State private var selectionID: String?
    @State private var expandedIDs: Set<String> = []
    @FocusState private var searchFocused: Bool
    private typealias Index = RelayWorkOverviewIndex
    nonisolated static let title = RelayCommand.quickNavigate.label
    nonisolated static let searchPlaceholder = "Go to a pane, workspace, setting or ask Miko"

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        self.activityIndex = workspace.activityIndex
    }

    private var results: [Index.Entry] {
        _ = activityIndex.revision
        return Self.entries(for: workspace, query: query)
    }

    /// Every row Go to pane lists for `query`, in display order.
    static func entries(for workspace: WorkspaceModel, query: String, now: Date = Date()) -> [RelayWorkOverviewIndex.Entry] {
        let visits = workspace.paneVisits
        var entries = Index.navigationEntries(query: query)
        for item in workspace.ownership.orderedWorkspaces {
            entries.append(.init(id: "workspace:\(item.id)", title: item.name,
                location: "Workspace", status: "", details: "Source: saved workspace list.",
                symbol: "square.grid.2x2", destination: .workspace(item.id),
                searchFields: [item.id.uuidString] + item.aliases, needsAttention: false,
                isCurrent: item.id == workspace.selectedWorkspaceID, changedAt: nil))
        }
        for tab in workspace.tabs {
            let owner = workspace.ownership.owner(of: tab.id).flatMap { workspace.ownership.workspace($0)?.name } ?? "Workspace"
            let title = tab.name.isEmpty ? "Untitled tab" : tab.name
            let current = workspace.ownership.owner(of: tab.id) == workspace.selectedWorkspaceID
            entries.append(.init(id: "tab:\(tab.id)", title: title, location: owner,
                status: "Tab", details: "Source: saved tab list.",
                symbol: "rectangle.on.rectangle", destination: .tab(tab.id), searchFields: [tab.id.uuidString],
                needsAttention: false, isCurrent: current, changedAt: nil))
            for id in workspace.paneIDs(inTab: tab.id) {
                guard let pane = workspace.panes[id] else { continue }
                let hidden = tab.hiddenStackPaneIDs.contains(id)
                let activity = pane.agentActivities.last
                let timestamp = activity.map { $0.occurredAt.formatted(date: .abbreviated, time: .standard) } ?? "Unavailable"
                let stale = activity.map { Date().timeIntervalSince($0.occurredAt) > 300 } ?? false
                // The same metadata and predicate as the fleet board and its counts.
                let fact = Index.paneFact(pane, tabID: tab.id, workspaceName: owner, tabName: title, hidden: hidden)
                let report = Index.mostUrgentProgramState(pane.programStatus.records.map(\.state))
                let reportCurrent = pane.connectionState == .connected && pane.programStatus.revision != nil
                // Idle is only the absence of recent output; it cannot
                // establish that the worker is ready or its task succeeded.
                let signalDetail = pane.pendingAgentApprovals == 0 && report == nil && pane.phase == .quiet
                    ? "No recent output; readiness has not been confirmed.\n" : ""
                let status = Index.paneStatus(phase: pane.phase, approvals: pane.pendingAgentApprovals,
                                              programState: report, programReportCurrent: reportCurrent)
                let stateSource = pane.pendingAgentApprovals > 0 ? "pending agent approval count"
                    : (report != nil ? "program self-report" : "terminal output and agent signals")
                let programDetails = pane.programStatus.records.map { record in
                    [record.title ?? record.app ?? "Program", record.state, record.message ?? ""].filter { !$0.isEmpty }.joined(separator: ": ")
                }.joined(separator: "\n")
                let location = "\(owner) › \(title)" + (hidden ? " · Hidden stack member" : "")
                // The activity record has its own clock. It is not a timestamp
                // for phase, approval count or connection, which lack one here.
                let details = "State source: \(stateSource). State observation time: unavailable.\n\(signalDetail)Connection: \(pane.connectionStatusLabel). Host: \(pane.profile.host).\nLatest pane activity record: \(timestamp)\(stale ? " (older than 5 minutes)" : "").\n\(activity?.label ?? "No timestamped activity available.")\n\(programDetails)"
                entries.append(.init(id: "pane:\(id)", title: pane.displayName, location: location,
                    status: status, details: details,
                    symbol: pane.contentKind == .editor ? "doc.text" : "terminal", destination: .pane(id, tab.id),
                    searchFields: [pane.title, pane.profile.name, pane.profile.host, pane.directory ?? "", id.uuidString,
                                   hidden ? "hidden stack" : "", pane.connectionStatusLabel],
                    needsAttention: fact.status.needsUser,
                    isCurrent: current, changedAt: fact.changedAt,
                    lastVisitedAt: id == workspace.activePaneID ? nil : visits.visit(id)?.lastVisitedAt,
                    frecency: visits.frecency(of: id, at: now), isActivePane: id == workspace.activePaneID))
            }
        }
        return Index.results(entries, query: query)
    }

    private func open(_ result: Index.Entry) {
        workspace.networkVisible = false
        switch result.destination {
        case .workspace(let id): workspace.selectWorkspace(id, origin: .user)
        case .tab(let id): workspace.selectTab(id, origin: .user)
        case .pane(let id, let tab):
            workspace.goToPane(id, inTab: tab)
        case .settings(let section):
            workspace.quickNavigateDidChooseAction {
                RelaySettingsNavigation.shared.section = section
                openSettings()
            }
            return
        case .controlCenter:
            workspace.quickNavigateDidChooseAction { [weak workspace] in
                workspace?.performancePanelSection = "Control"
                workspace?.performancePanelVisible = true
            }
            return
        case .fleetBoard:
            workspace.quickNavigateDidChooseAction { [weak workspace] in
                guard let workspace else { return }
                workspace.presentFleetBoard(filter: .initial(for: Index.fleet(workspace).counts))
            }
            return
        case .askMiko:
            workspace.quickNavigateDidChooseAction { [weak workspace] in
                guard let workspace else { return }
                if !workspace.haikuAssistantVisible { workspace.toggleHaikuAssistant() }
                NotificationCenter.default.post(name: .relayMikoComposerFocus, object: workspace)
            }
            return
        }
        workspace.quickNavigateDidChooseDestination()
    }

    private func move(_ offset: Int) {
        selectionID = Index.movedSelection(selectionID, by: offset, in: results, query: query)
    }

    private func announceSelection(_ row: Index.Entry?) {
        guard let window = NSApp.keyWindow else { return }
        let message = row.map { "\($0.title). \($0.status). \($0.location). Press Return to open." } ?? "No matching work"
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    var body: some View {
        let rows = results
        let selected = Index.selectedID(selectionID, in: rows, query: query)
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.title).font(.headline).padding(.horizontal, 16).padding(.top, 14)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(Self.searchPlaceholder, text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { if let row = rows.first(where: { $0.id == selected }) { open(row) } }
                    .accessibilityLabel(Self.title)
                    .accessibilityHint("Use up and down arrows to select a result, Return to open, Escape to return to the original pane")
                    .accessibilityIdentifier("relay.overview.search")
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { workspace.isQuickNavigatePresented = false; return .handled }
            }.padding(16)
            Divider()
            Text("Work and navigation · Details show sources and context")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
            if rows.isEmpty {
                Text("No matching work").foregroundStyle(.secondary).padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Index.sections(rows, query: query)) { section in
                                let members = section.entries
                                if !members.isEmpty {
                                    Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 12).padding(.top, 10).accessibilityAddTraits(.isHeader)
                                    ForEach(members) { result in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 6) {
                                                Button { open(result) } label: {
                                                    HStack(spacing: 10) {
                                                        Image(systemName: result.symbol).frame(width: 20).foregroundStyle(.secondary)
                                                        VStack(alignment: .leading, spacing: 3) {
                                                            Text(result.title).lineLimit(1)
                                                            Text([result.status, result.location].filter { !$0.isEmpty }.joined(separator: " · "))
                                                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                                        }
                                                        Spacer()
                                                    }.contentShape(Rectangle())
                                                }.buttonStyle(.plain)
                                                .accessibilityLabel("\(result.title), \(result.status), \(result.location)")
                                                .accessibilityAddTraits(result.id == selected ? [.isSelected] : [])
                                                Button {
                                                    if !expandedIDs.insert(result.id).inserted { expandedIDs.remove(result.id) }
                                                } label: { Image(systemName: expandedIDs.contains(result.id) ? "chevron.up" : "info.circle") }
                                                .buttonStyle(.plain).help("Show source and activity details")
                                                .accessibilityLabel("\(expandedIDs.contains(result.id) ? "Hide" : "Show") details for \(result.title)")
                                            }
                                            if expandedIDs.contains(result.id) {
                                                Text(result.details).font(.caption).foregroundStyle(.secondary)
                                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                                    .padding(.leading, 30)
                                            }
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(result.id == selected ? Color.primary.opacity(0.08) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 6)).id(result.id)
                                    }
                                }
                            }
                        }.padding(6)
                    }
                    .onChange(of: selected) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                }.frame(height: 370)
            }
            Divider()
            HStack {
                Text("↑↓ Select   ↵ Open   esc Close")
                Spacer()
                Text("\(rows.count) results")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 620)
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selectionID = nil }
        .onChange(of: rows.map(\.id)) { _, _ in selectionID = Index.selectedID(selectionID, in: rows, query: query) }
        .onChange(of: selected) { _, id in announceSelection(rows.first { $0.id == id }) }
        .onMoveCommand { direction in
            switch direction { case .down: move(1); case .up: move(-1); default: break }
        }
        .onExitCommand { workspace.isQuickNavigatePresented = false }
    }
}
