import SwiftUI

// MARK: - Shared classification

/// Metadata only, like the rest of `RelayWorkOverviewIndex`: a pane's status
/// comes from its agent phase (terminal agent signals and structured agent
/// events, local and relayd), pending approval count, program self-report and
/// connection state. Nothing here reads a transcript or acknowledges an alert.
extension RelayWorkOverviewIndex {
    /// Board order: what needs the user first, then what is broken, then work.
    enum PaneStatus: Int, CaseIterable, Comparable, Sendable {
        case waiting, disconnected, running, idle

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .waiting: "Waiting on you"
            case .disconnected: "Disconnected"
            case .running: "Running"
            case .idle: "Idle"
            }
        }

        var role: RelayTheme.StatusRole {
            switch self {
            case .waiting: .warning
            case .disconnected: .danger
            case .running: .success
            case .idle: .neutral
            }
        }
    }

    /// The one "waiting on you" predicate. Go to pane's Needs attention group,
    /// the fleet board and the navigator counts all call this.
    static func needsAttention(phase: AgentPhase, approvals: Int, programState: String?) -> Bool {
        approvals > 0 || phase == .needsInput || programState == "blocked" || programState == "error"
    }

    /// Waiting wins over a lost connection: a reconnecting pane whose replayed
    /// state is waiting still waits on the user. A pane still connecting for
    /// the first time is idle, not disconnected.
    static func paneStatus(phase: AgentPhase, approvals: Int, programState: String?,
                           connection: PaneConnectionState) -> PaneStatus {
        if needsAttention(phase: phase, approvals: approvals, programState: programState) { return .waiting }
        switch connection {
        case .disconnected, .reconnecting, .waitingForNetwork: return .disconnected
        case .connecting, .connected: break
        }
        if phase == .exited { return .disconnected }
        if phase == .active || programState == "working" { return .running }
        return .idle
    }

    /// The most urgent program self-report, as Go to pane shows it.
    static func mostUrgentProgramState(_ records: [String]) -> String? {
        let priority = ["blocked": 0, "error": 1, "working": 2, "done": 3, "idle": 4]
        return records.min { (priority[$0] ?? 5) < (priority[$1] ?? 5) }
    }

    /// One pane's board metadata, derived once per activity revision.
    struct PaneFact: Identifiable, Equatable, Sendable {
        let paneID: UUID
        let tabID: UUID
        let name: String
        let workspaceName: String
        let tabName: String
        let host: String
        let status: PaneStatus
        /// Go to pane's status text, or the connection label when disconnected.
        let detail: String
        /// Timestamped activity records only; nil when there is none.
        let changedAt: Date?
        let hiddenStackMember: Bool
        var id: UUID { paneID }
    }

    struct PaneCounts: Equatable, Sendable {
        var waiting = 0, disconnected = 0, running = 0, idle = 0
        init(_ facts: [PaneFact] = []) {
            for fact in facts { self[fact.status] += 1 }
        }
        init(waiting: Int, disconnected: Int, running: Int, idle: Int) {
            (self.waiting, self.disconnected, self.running, self.idle) = (waiting, disconnected, running, idle)
        }
        subscript(status: PaneStatus) -> Int {
            get {
                switch status {
                case .waiting: waiting
                case .disconnected: disconnected
                case .running: running
                case .idle: idle
                }
            }
            set {
                switch status {
                case .waiting: waiting = newValue
                case .disconnected: disconnected = newValue
                case .running: running = newValue
                case .idle: idle = newValue
                }
            }
        }
        var total: Int { waiting + disconnected + running + idle }
    }

    /// Every terminal pane in every tab and workspace, Mac and remote, from published
    /// pane state. Cheap enough to run on each throttled activity revision.
    @MainActor static func paneFacts(_ workspace: WorkspaceModel) -> [PaneFact] {
        var facts: [PaneFact] = []
        for tab in workspace.tabs {
            let owner = workspace.ownership.owner(of: tab.id).flatMap { workspace.ownership.workspace($0)?.name } ?? "Workspace"
            let tabName = tab.name.isEmpty ? "Untitled tab" : tab.name
            for id in workspace.paneIDs(inTab: tab.id) {
                // Editors have no agent; a never-started one would read as lost.
                guard let pane = workspace.panes[id], pane.contentKind == .terminal else { continue }
                facts.append(paneFact(pane, tabID: tab.id, workspaceName: owner, tabName: tabName,
                                      hidden: tab.hiddenStackPaneIDs.contains(id)))
            }
        }
        return facts
    }

    @MainActor static func paneFact(_ pane: PaneModel, tabID: UUID, workspaceName: String,
                                    tabName: String, hidden: Bool) -> PaneFact {
        let report = mostUrgentProgramState(pane.programStatus.records.map(\.state))
        let reportCurrent = pane.connectionState == .connected && pane.programStatus.revision != nil
        let status = paneStatus(phase: pane.phase, approvals: pane.pendingAgentApprovals,
                                programState: report, connection: pane.connectionState)
        let detail = status == .disconnected ? pane.connectionStatusLabel
            : paneStatus(phase: pane.phase, approvals: pane.pendingAgentApprovals,
                         programState: report, programReportCurrent: reportCurrent)
        let changedAt = [pane.agentActivities.last?.occurredAt, pane.lastCompletedAgentTurn].compactMap { $0 }.max()
        return PaneFact(paneID: pane.id, tabID: tabID, name: pane.displayName, workspaceName: workspaceName,
                        tabName: tabName, host: pane.profile.kind == .ssh ? pane.profile.host : "This Mac",
                        status: status, detail: detail, changedAt: changedAt, hiddenStackMember: hidden)
    }

    /// Board order: status, then most recent change, then name.
    static func boardOrder(_ facts: [PaneFact]) -> [PaneFact] {
        facts.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status < rhs.status }
            if lhs.changedAt != rhs.changedAt { return (lhs.changedAt ?? .distantPast) > (rhs.changedAt ?? .distantPast) }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.paneID.uuidString < rhs.paneID.uuidString : order == .orderedAscending
        }
    }

    /// "now", "4 min ago", "2 h ago", "3 d ago"; "No activity" without a record.
    static func changeLabel(_ date: Date?, now: Date) -> String {
        guard let date else { return "No activity" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }
}

// MARK: - Board filter

enum RelayFleetFilter: String, CaseIterable, Identifiable, Sendable {
    case all, waiting, running, disconnected
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .waiting: "Waiting"
        case .running: "Running"
        case .disconnected: "Disconnected"
        }
    }

    var status: RelayWorkOverviewIndex.PaneStatus? {
        switch self {
        case .all: nil
        case .waiting: .waiting
        case .running: .running
        case .disconnected: .disconnected
        }
    }

    func includes(_ fact: RelayWorkOverviewIndex.PaneFact) -> Bool {
        status.map { fact.status == $0 } ?? true
    }

    /// Opening from the counts shows what is waiting when anything is.
    static func initial(for counts: RelayWorkOverviewIndex.PaneCounts) -> Self {
        counts.waiting > 0 ? .waiting : .all
    }
}

// MARK: - Views

/// Title, summary and status chips.
struct RelayFleetBoardHeader: View {
    let counts: RelayWorkOverviewIndex.PaneCounts
    let hostCount: Int
    @Binding var filter: RelayFleetFilter
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: RelayTheme.Space.md) {
                Text(RelayCommand.fleetBoard.label).relayText(.title).foregroundStyle(RelayTheme.text)
                Text("\(counts.total) \(counts.total == 1 ? "pane" : "panes") on \(hostCount) \(hostCount == 1 ? "host" : "hosts")")
                    .relayText(.caption).foregroundStyle(RelayTheme.textMuted)
                Spacer(minLength: 0)
                if let onClose {
                    RelayIconAction("Close", symbol: "xmark", size: .compact, action: onClose)
                        .keyboardShortcut(.cancelAction)
                }
            }
            HStack(spacing: RelayTheme.Space.sm) {
                ForEach(RelayFleetFilter.allCases) { option in
                    chip(option)
                }
            }
        }
    }

    private func count(_ option: RelayFleetFilter) -> Int {
        option.status.map { counts[$0] } ?? counts.total
    }

    private func chip(_ option: RelayFleetFilter) -> some View {
        let selected = filter == option
        let role = option.status?.role ?? .info
        return Button { filter = option } label: {
            HStack(spacing: RelayTheme.Space.xs) {
                if let status = option.status {
                    Image(systemName: status.role.symbol).imageScale(.small)
                        .foregroundStyle(selected ? RelayTheme.text : role.color)
                }
                Text(option.title)
                Text("\(count(option))").monospacedDigit()
                    .foregroundStyle(selected ? RelayTheme.text : RelayTheme.textMuted)
            }
            .relayText(.caption)
            .foregroundStyle(RelayTheme.text)
            .padding(.horizontal, RelayTheme.Space.md)
            .frame(height: RelayTheme.Control.compactIcon)
            .background(selected ? role.color.opacity(0.22) : RelayTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? role.color.opacity(0.7) : RelayTheme.stroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title), \(count(option))")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("relay.fleet.filter.\(option.rawValue)")
    }
}

/// Rows grouped by status in board order. No scroll view, so snapshots and
/// the sheet share it; the sheet wraps it in one.
struct RelayFleetBoardList: View {
    let facts: [RelayWorkOverviewIndex.PaneFact]
    let filter: RelayFleetFilter
    let now: Date
    let onOpen: (RelayWorkOverviewIndex.PaneFact) -> Void

    var body: some View {
        let shown = RelayWorkOverviewIndex.boardOrder(facts.filter(filter.includes))
        if shown.isEmpty {
            RelayEmptyState(facts.isEmpty ? "No panes" : "Nothing \(filter.title.lowercased())",
                            symbol: filter == .waiting ? "checkmark.circle" : "rectangle.grid.1x2",
                            detail: facts.isEmpty ? "Open a tab to see it here." : "No pane has this status right now.")
        } else {
            VStack(alignment: .leading, spacing: RelayTheme.Space.lg) {
                ForEach(RelayWorkOverviewIndex.PaneStatus.allCases, id: \.self) { status in
                    let members = shown.filter { $0.status == status }
                    if !members.isEmpty {
                        VStack(alignment: .leading, spacing: RelayTheme.Space.xs) {
                            RelaySectionHeader("\(status.label) · \(members.count)")
                                .padding(.horizontal, RelayTheme.Space.md)
                            VStack(spacing: 0) {
                                ForEach(Array(members.enumerated()), id: \.element.id) { index, fact in
                                    if index > 0 { Divider().overlay(RelayTheme.stroke.opacity(0.5)) }
                                    RelayFleetBoardRow(fact: fact, now: now) { onOpen(fact) }
                                }
                            }
                            .relayCard()
                        }
                    }
                }
            }
        }
    }
}

/// One pane. The whole row opens the pane; nothing else happens here.
struct RelayFleetBoardRow: View {
    let fact: RelayWorkOverviewIndex.PaneFact
    let now: Date
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: RelayTheme.Space.md) {
                Image(systemName: fact.status.role.symbol)
                    .font(RelayTheme.TextRole.body.font)
                    .foregroundStyle(fact.status.role.color)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: RelayTheme.Space.xxs) {
                    Text(fact.name).relayText(.label).foregroundStyle(RelayTheme.text).lineLimit(1)
                    Text("\(fact.workspaceName) › \(fact.tabName)" + (fact.hiddenStackMember ? " · in stack" : ""))
                        .relayText(.caption).foregroundStyle(RelayTheme.textMuted).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(fact.detail).relayText(.caption).foregroundStyle(RelayTheme.textMuted)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: 170, alignment: .leading)
                RelayBadge(fact.host, role: .neutral, showsSymbol: false)
                    .frame(width: 96, alignment: .leading)
                Text(RelayWorkOverviewIndex.changeLabel(fact.changedAt, now: now))
                    .relayText(.caption).monospacedDigit().foregroundStyle(RelayTheme.textMuted)
                    .lineLimit(1)
                    .frame(width: 76, alignment: .trailing)
                Image(systemName: "arrow.right")
                    .font(RelayTheme.TextRole.caption.font)
                    .foregroundStyle(hovering ? RelayTheme.text : RelayTheme.textFaint)
                    .frame(width: RelayTheme.Control.compactIcon, height: RelayTheme.Control.compactIcon)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, RelayTheme.Space.md)
            .padding(.vertical, RelayTheme.Space.sm)
            .background(hovering ? RelayTheme.accent.opacity(0.10) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Go to \(fact.name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(fact.name). \(fact.status.role.spoken(fact.status.label)). \(fact.detail). \(fact.host), \(fact.workspaceName), \(fact.tabName). \(RelayWorkOverviewIndex.changeLabel(fact.changedAt, now: now))")
        .accessibilityHint("Opens the pane")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("relay.fleet.row.\(fact.paneID)")
    }
}

/// "3 running · 2 waiting" in the navigator header; opens the board.
struct RelayFleetCountsButton: View {
    let counts: RelayWorkOverviewIndex.PaneCounts
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: RelayTheme.Space.sm) {
                if counts.running == 0 && counts.waiting == 0 {
                    part("All quiet", status: .idle)
                } else {
                    if counts.running > 0 { part("\(counts.running) running", status: .running) }
                    if counts.waiting > 0 && counts.running > 0 {
                        Text("·").foregroundStyle(RelayTheme.textMuted)
                    }
                    if counts.waiting > 0 { part("\(counts.waiting) waiting", status: .waiting) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(RelayTheme.textMuted)
            }
            .relayText(.caption)
            .padding(.horizontal, RelayTheme.Space.sm)
            .frame(height: RelayTheme.Control.compactIcon)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(RelayCommand.fleetBoard.label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenSummary(counts))
        .accessibilityHint("Opens \(RelayCommand.fleetBoard.label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("relay.navigator.fleet-counts")
    }

    static func spokenSummary(_ counts: RelayWorkOverviewIndex.PaneCounts) -> String {
        if counts.running == 0 && counts.waiting == 0 { return "All quiet" }
        return "\(counts.running) running, \(counts.waiting) waiting on you"
    }

    private func part(_ text: String, status: RelayWorkOverviewIndex.PaneStatus) -> some View {
        HStack(spacing: RelayTheme.Space.xs) {
            Image(systemName: status.role.symbol).imageScale(.small).foregroundStyle(status.role.color)
            Text(text).monospacedDigit().foregroundStyle(status == .idle ? RelayTheme.textMuted : RelayTheme.text)
        }
    }
}

/// The sheet: derives facts from published pane state on each throttled
/// activity revision. Opening a row records a user visit, like Go to pane.
struct RelayFleetBoard: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var activityIndex: WorkspaceActivityIndex
    @State private var filter: RelayFleetFilter

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        self.activityIndex = workspace.activityIndex
        _filter = State(initialValue: workspace.fleetBoardInitialFilter)
    }

    /// Go to pane's path: shows the pane's tab and records a user visit.
    static func open(_ fact: RelayWorkOverviewIndex.PaneFact, in workspace: WorkspaceModel) {
        workspace.goToPane(fact.paneID, inTab: fact.tabID)
        workspace.isFleetBoardPresented = false
    }

    var body: some View {
        let _ = activityIndex.revision
        let facts = RelayWorkOverviewIndex.paneFacts(workspace)
        VStack(alignment: .leading, spacing: 0) {
            RelayFleetBoardHeader(counts: .init(facts), hostCount: Set(facts.map(\.host)).count,
                                  filter: $filter) { workspace.isFleetBoardPresented = false }
                .padding(RelayTheme.Space.xl)
            Divider()
            ScrollView {
                RelayFleetBoardList(facts: facts, filter: filter, now: Date()) { fact in
                    Self.open(fact, in: workspace)
                }
                .padding(RelayTheme.Space.xl)
            }
        }
        .frame(width: 720)
        .frame(minHeight: 320, idealHeight: 520, maxHeight: 640)
        .relaySurface()
        .onExitCommand { workspace.isFleetBoardPresented = false }
        .accessibilityIdentifier("relay.fleet.board")
    }
}
