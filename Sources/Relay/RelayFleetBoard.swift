import AppKit
import SwiftUI

// MARK: - Shared classification

/// Metadata only, like the rest of `RelayWorkOverviewIndex`: a pane's status
/// comes from its agent phase (terminal agent signals and structured agent
/// events, local and relayd), pending approval count, program self-report and
/// connection state. Nothing here reads a transcript or acknowledges an alert.
extension RelayWorkOverviewIndex {
    /// Board order: what needs the user first, then what is broken, then work.
    enum PaneStatus: Int, CaseIterable, Comparable, Sendable {
        /// `failed`: a program that exited with a non-zero status. It waits on
        /// the user like `waiting`, but it is a failure, so it is red.
        case waiting, failed, disconnected, reconnecting, running, idle

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The role's symbol, except running: a waveform, so working never
        /// reads as finished (checkmark) or reconnecting (circular arrows).
        var symbol: String { self == .running ? RelayStatusMark.runningSymbol : role.symbol }

        /// Waiting on the user: a wait or approval, or a failed exit.
        var needsUser: Bool { self == .waiting || self == .failed }

        var label: String {
            switch self {
            case .waiting: "Waiting on you"
            case .failed: "Failed"
            case .disconnected: "Disconnected"
            case .reconnecting: "Reconnecting"
            case .running: "Running"
            case .idle: "Idle"
            }
        }

        var role: RelayTheme.StatusRole {
            switch self {
            case .waiting: .warning
            // Red is for failures only: a non-zero exit. A lost or returning
            // connection is not a failure.
            case .failed: .danger
            case .disconnected: .offline
            case .reconnecting: .pending
            case .running: .success
            case .idle: .neutral
            }
        }
    }

    /// The one "waiting on you" predicate. Go to pane's Needs attention group,
    /// the fleet board and the navigator counts all call this.
    /// A finished turn, "Done", a clean exit and idle are not attention; a
    /// non-zero exit is.
    static func needsAttention(phase: AgentPhase, approvals: Int, programState: String?, failedExit: Bool = false) -> Bool {
        approvals > 0 || phase == .needsInput || programState == "blocked" || programState == "error" || failedExit
    }

    /// A failed exit is the newest fact, so it wins over a stale wait or
    /// report. Waiting wins over a lost connection: a reconnecting pane whose
    /// replayed state is waiting still waits on the user. A pane still
    /// connecting for the first time is idle, not disconnected.
    static func paneStatus(phase: AgentPhase, approvals: Int, programState: String?,
                           connection: PaneConnectionState, failedExit: Bool = false) -> PaneStatus {
        if failedExit { return .failed }
        if needsAttention(phase: phase, approvals: approvals, programState: programState, failedExit: failedExit) { return .waiting }
        switch connection {
        case .disconnected: return .disconnected
        case .reconnecting, .waitingForNetwork: return .reconnecting
        case .connecting, .connected: break
        }
        // A clean exit is finished work, not a lost connection; a failed one
        // already returned .failed.
        if phase == .exited { return .idle }
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
        /// An agent has been seen: a harness or detected provider, an agent
        /// event, a pending approval or a program self-report.
        var isAgent = true
        var id: UUID { paneID }
    }

    struct PaneCounts: Equatable, Sendable {
        var waiting = 0, failed = 0, disconnected = 0, reconnecting = 0, running = 0, idle = 0
        init(_ facts: [PaneFact] = []) {
            for fact in facts { self[fact.status] += 1 }
        }
        init(waiting: Int, failed: Int = 0, disconnected: Int, reconnecting: Int = 0, running: Int, idle: Int) {
            (self.waiting, self.failed, self.disconnected, self.reconnecting, self.running, self.idle) =
                (waiting, failed, disconnected, reconnecting, running, idle)
        }
        subscript(status: PaneStatus) -> Int {
            get {
                switch status {
                case .waiting: waiting
                case .failed: failed
                case .disconnected: disconnected
                case .reconnecting: reconnecting
                case .running: running
                case .idle: idle
                }
            }
            set {
                switch status {
                case .waiting: waiting = newValue
                case .failed: failed = newValue
                case .disconnected: disconnected = newValue
                case .reconnecting: reconnecting = newValue
                case .running: running = newValue
                case .idle: idle = newValue
                }
            }
        }
        var total: Int { waiting + failed + disconnected + reconnecting + running + idle }
    }

    /// Every terminal pane in every tab and workspace, Mac and remote, from published
    /// pane state. Cheap enough to run on each throttled activity revision.
    /// Each pane's fact is reused while the pane's `overviewRevision` and its
    /// tab placement are unchanged, so a pass recomputes only changed panes.
    @MainActor static func paneFacts(_ workspace: WorkspaceModel) -> [PaneFact] {
        paneFacts(workspace, cache: workspace.paneFactCache)
    }

    /// With `cache: nil` every fact is recomputed: the reference result.
    @MainActor static func paneFacts(_ workspace: WorkspaceModel, cache: PaneFactCache?) -> [PaneFact] {
        var facts: [PaneFact] = []
        // One lookup table per pass instead of a linear search per tab; the
        // first match wins, as in `owner(of:)` and `workspace(_:)`.
        let ownership = workspace.ownership
        let ownerOf = Dictionary(ownership.owners.map { ($0.id, $0.workspaceID) }, uniquingKeysWith: { first, _ in first })
        let nameOf = Dictionary(ownership.workspaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for tab in workspace.tabs {
            let owner = ownerOf[tab.id].flatMap { nameOf[$0] } ?? "Workspace"
            let tabName = tab.name.isEmpty ? "Untitled tab" : tab.name
            let hiddenIDs = Set(tab.hiddenStackPaneIDs)
            for id in workspace.paneIDs(in: tab) {
                // Editors have no agent; a never-started one would read as lost.
                guard let pane = workspace.panes[id], pane.contentKind == .terminal else { continue }
                let hidden = hiddenIDs.contains(id)
                facts.append(cache?.fact(pane, tabID: tab.id, workspaceName: owner, tabName: tabName, hidden: hidden)
                             ?? paneFact(pane, tabID: tab.id, workspaceName: owner, tabName: tabName, hidden: hidden))
            }
        }
        cache?.endPass()
        return facts
    }

    /// Per-workspace memo of `paneFact`, keyed by the pane's overview
    /// revision and placement. A plain class, not observable: SwiftUI bodies
    /// fill it while they draw. `paneFact` reads no clock, so a reused fact
    /// cannot go stale with time alone.
    @MainActor final class PaneFactCache {
        private struct Key: Equatable {
            let revision: UInt64
            let tabID: UUID
            let workspaceName: String
            let tabName: String
            let hidden: Bool
        }
        private var entries: [UUID: (key: Key, fact: PaneFact)] = [:]
        private var seen = Set<UUID>()
        /// Facts computed rather than reused; for tests.
        private(set) var computed = 0
        var count: Int { entries.count }

        func fact(_ pane: PaneModel, tabID: UUID, workspaceName: String, tabName: String, hidden: Bool) -> PaneFact {
            let key = Key(revision: pane.overviewRevision, tabID: tabID, workspaceName: workspaceName,
                          tabName: tabName, hidden: hidden)
            seen.insert(pane.id)
            if let entry = entries[pane.id], entry.key == key { return entry.fact }
            computed += 1
            let fact = RelayWorkOverviewIndex.paneFact(pane, tabID: tabID, workspaceName: workspaceName,
                                                       tabName: tabName, hidden: hidden)
            entries[pane.id] = (key, fact)
            return fact
        }

        /// Drops panes the pass did not visit (closed, or now an editor).
        func endPass() {
            if entries.count != seen.count { entries = entries.filter { seen.contains($0.key) } }
            seen.removeAll(keepingCapacity: true)
        }
    }

    @MainActor static func paneFact(_ pane: PaneModel, tabID: UUID, workspaceName: String,
                                    tabName: String, hidden: Bool) -> PaneFact {
        let report = mostUrgentProgramState(pane.programStatus.records.map(\.state))
        let reportCurrent = pane.connectionState == .connected && pane.programStatus.revision != nil
        let failedExit = WorkspaceModel.failedExitStatus(pane)
        let status = paneStatus(phase: pane.phase, approvals: pane.pendingAgentApprovals,
                                programState: report, connection: pane.connectionState, failedExit: failedExit != nil)
        // A lost connection names itself (disconnecting also marks the phase
        // exited); a pane whose session ended while connected says Exited.
        let detail = status == .failed
            ? "Exited with status \(failedExit ?? 0)"
            : status == .disconnected || status == .reconnecting
            ? pane.connectionStatusLabel
            : status == .idle && pane.phase == .exited
            ? PaneDisplayState.exited.label
            : paneStatus(phase: pane.phase, approvals: pane.pendingAgentApprovals,
                         programState: report, programReportCurrent: reportCurrent)
        let changedAt = [pane.agentActivities.last?.occurredAt, pane.lastCompletedAgentTurn].compactMap { $0 }.max()
        let isAgent = pane.harnessIdentity != nil || pane.kind != .shell || !pane.agentActivities.isEmpty
            || pane.pendingAgentApprovals > 0 || !pane.programStatus.records.isEmpty
        return PaneFact(paneID: pane.id, tabID: tabID, name: pane.displayName, workspaceName: workspaceName,
                        tabName: tabName, host: pane.profile.kind == .ssh ? pane.profile.host : "This Mac",
                        status: status, detail: detail, changedAt: changedAt, hiddenStackMember: hidden,
                        isAgent: isAgent)
    }

    /// The mark a tab, workspace or session row shows: the most urgent status
    /// among the board's rows (agent panes, plus a waiting shell), nil when
    /// they are all idle or there is none. Running is dropped for the focused
    /// tab, where the user already sees the work; waiting and disconnected stay.
    static func groupStatus(_ facts: [PaneFact], focused: Bool = false) -> PaneStatus? {
        Fleet(facts).rows.lazy.map(\.status).filter { $0 != .idle && !(focused && $0 == .running) }.min()
    }

    /// Each tab's mark, from one pass over the pane facts.
    static func tabStatuses(_ facts: [PaneFact], focusedTabID: UUID?) -> [UUID: PaneStatus] {
        Dictionary(grouping: facts, by: \.tabID).compactMapValues { group in
            groupStatus(group, focused: group.first?.tabID == focusedTabID)
        }
    }

    /// A row holding several tabs shows the most urgent of their marks.
    static func mostUrgent(_ tabIDs: some Sequence<UUID>, in marks: [UUID: PaneStatus]) -> PaneStatus? {
        tabIDs.compactMap { marks[$0] }.min()
    }

    /// The board's rows: agent panes, plus any pane waiting on the user (a
    /// shell prompt such as "(y/n)" is waiting in Go to pane too, so it stays
    /// listed and counted). Other plain shells are only counted as not shown.
    struct Fleet: Equatable, Sendable {
        let rows: [PaneFact]
        let shellsNotShown: Int
        var counts: PaneCounts { PaneCounts(rows) }
        var hostCount: Int { Set(rows.map(\.host)).count }

        init(_ facts: [PaneFact]) {
            rows = facts.filter { $0.isAgent || $0.status.needsUser }
            shellsNotShown = facts.count - rows.count
        }
    }

    @MainActor static func fleet(_ workspace: WorkspaceModel) -> Fleet { Fleet(paneFacts(workspace)) }

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
    case all, waiting, failed, running, disconnected
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .waiting: "Waiting"
        case .failed: "Failed"
        case .running: "Running"
        case .disconnected: "Disconnected"
        }
    }

    var status: RelayWorkOverviewIndex.PaneStatus? {
        switch self {
        case .all: nil
        case .waiting: .waiting
        case .failed: .failed
        case .running: .running
        case .disconnected: .disconnected
        }
    }

    /// "Disconnected" also lists panes whose connection is coming back.
    var statuses: [RelayWorkOverviewIndex.PaneStatus] {
        switch self {
        case .all: []
        case .disconnected: [.disconnected, .reconnecting]
        default: status.map { [$0] } ?? []
        }
    }

    func includes(_ fact: RelayWorkOverviewIndex.PaneFact) -> Bool {
        self == .all || statuses.contains(fact.status)
    }

    /// Opening from the counts shows what is waiting when anything is.
    static func initial(for counts: RelayWorkOverviewIndex.PaneCounts) -> Self {
        counts.waiting > 0 ? .waiting : counts.failed > 0 ? .failed : .all
    }
}

// MARK: - Views

/// Title, summary and status chips.
struct RelayFleetBoardHeader: View {
    let counts: RelayWorkOverviewIndex.PaneCounts
    let hostCount: Int
    var shellsNotShown = 0
    @Binding var filter: RelayFleetFilter
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: RelayTheme.Space.md) {
                Text(RelayCommand.fleetBoard.label).relayText(.title).foregroundStyle(RelayTheme.text)
                Text(Self.subtitle(total: counts.total, hosts: hostCount, shellsNotShown: shellsNotShown))
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

    static func subtitle(total: Int, hosts: Int, shellsNotShown: Int) -> String {
        var text = "\(total) \(total == 1 ? "agent" : "agents") on \(hosts) \(hosts == 1 ? "host" : "hosts")"
        if shellsNotShown > 0 { text += " · \(shellsNotShown) \(shellsNotShown == 1 ? "shell" : "shells") not shown" }
        return text
    }

    private func count(_ option: RelayFleetFilter) -> Int {
        option == .all ? counts.total : option.statuses.reduce(0) { $0 + counts[$1] }
    }

    private func chip(_ option: RelayFleetFilter) -> some View {
        let selected = filter == option
        let role = option.status?.role ?? .info
        return Button { filter = option } label: {
            HStack(spacing: RelayTheme.Space.xs) {
                if let status = option.status {
                    Image(systemName: status.symbol).imageScale(.small)
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
    /// A fixed clock for snapshots; nil follows the wall clock.
    var now: Date? = nil
    let onOpen: (RelayWorkOverviewIndex.PaneFact) -> Void

    var body: some View {
        let shown = RelayWorkOverviewIndex.boardOrder(facts.filter(filter.includes))
        if shown.isEmpty {
            RelayEmptyState(facts.isEmpty ? "No agents" : "Nothing \(filter.title.lowercased())",
                            symbol: filter == .waiting ? "checkmark.circle" : "rectangle.grid.1x2",
                            detail: facts.isEmpty ? "Panes appear here once an agent runs in them." : "No agent has this status right now.")
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
    var now: Date? = nil
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: RelayTheme.Space.md) {
                Image(systemName: fact.status.symbol)
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
                Group {
                    if let now {
                        changeText(now)
                    } else {
                        // Only the label follows the clock; no model timer.
                        TimelineView(.periodic(from: .now, by: 60)) { context in changeText(context.date) }
                    }
                }
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
        .accessibilityLabel("\(fact.name). \(fact.status.role.spoken(fact.status.label)). \(fact.detail). \(fact.host), \(fact.workspaceName), \(fact.tabName). \(RelayWorkOverviewIndex.changeLabel(fact.changedAt, now: now ?? Date()))")
        .accessibilityHint("Opens the pane")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("relay.fleet.row.\(fact.paneID)")
    }

    private func changeText(_ date: Date) -> some View {
        Text(RelayWorkOverviewIndex.changeLabel(fact.changedAt, now: date))
            .relayText(.caption).monospacedDigit().foregroundStyle(RelayTheme.textMuted)
            .lineLimit(1)
    }
}

/// "3 running · 2 waiting" in the navigator header; opens the board.
struct RelayFleetCountsButton: View {
    let counts: RelayWorkOverviewIndex.PaneCounts
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: RelayTheme.Space.sm) {
                let segments = Self.segments(counts)
                if segments.isEmpty {
                    part("All quiet", status: .idle)
                } else {
                    // Always labelled ("2 waiting · 2 disconnected · 3 running"),
                    // on one line: smaller type first, then the least urgent
                    // segments fold into "+N" (the tooltip names them all).
                    ViewThatFits(in: .horizontal) {
                        segmentRow(segments, small: false)
                        segmentRow(segments, small: true)
                        ForEach(Array((1 ..< segments.count).reversed()), id: \.self) { shown in
                            segmentRow(Array(segments.prefix(shown)), small: true,
                                       more: segments.dropFirst(shown).reduce(0) { $0 + counts[$1] })
                        }
                    }
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
        .help("\(Self.spokenSummary(counts)). Open \(RelayCommand.fleetBoard.label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenSummary(counts))
        .accessibilityHint("Opens \(RelayCommand.fleetBoard.label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("relay.navigator.fleet-counts")
    }

    /// The board's order: waiting, failed, disconnected, running; empty ones hidden.
    static func segments(_ counts: RelayWorkOverviewIndex.PaneCounts) -> [RelayWorkOverviewIndex.PaneStatus] {
        [.waiting, .failed, .disconnected, .reconnecting, .running].filter { counts[$0] > 0 }
    }

    static func shortLabel(_ status: RelayWorkOverviewIndex.PaneStatus, _ count: Int) -> String {
        switch status {
        case .waiting: "\(count) waiting"
        case .failed: "\(count) failed"
        case .disconnected: "\(count) disconnected"
        case .reconnecting: "\(count) reconnecting"
        case .running: "\(count) running"
        case .idle: "\(count) idle"
        }
    }

    static func spokenSummary(_ counts: RelayWorkOverviewIndex.PaneCounts) -> String {
        let segments = segments(counts)
        if segments.isEmpty { return "All quiet" }
        return segments.map { $0 == .waiting ? "\(counts.waiting) waiting on you" : shortLabel($0, counts[$0]) }
            .joined(separator: ", ")
    }

    private func segmentRow(_ segments: [RelayWorkOverviewIndex.PaneStatus], small: Bool, more: Int = 0) -> some View {
        HStack(spacing: RelayTheme.Space.sm) {
            ForEach(Array(segments.enumerated()), id: \.element) { index, status in
                if index > 0 { Text("·").foregroundStyle(RelayTheme.textMuted) }
                part(Self.shortLabel(status, counts[status]), status: status)
            }
            if more > 0 { Text("· +\(more)").foregroundStyle(RelayTheme.textMuted) }
        }
        .font(small ? RelayTheme.TextRole.micro.font : RelayTheme.TextRole.caption.font)
        .lineLimit(1)
        .fixedSize()
    }

    private func part(_ text: String, status: RelayWorkOverviewIndex.PaneStatus) -> some View {
        HStack(spacing: RelayTheme.Space.xs) {
            Image(systemName: status.symbol).imageScale(.small).foregroundStyle(status.role.color)
            Text(text).monospacedDigit().lineLimit(1).foregroundStyle(status == .idle ? RelayTheme.textMuted : RelayTheme.text)
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
        let fleet = RelayWorkOverviewIndex.fleet(workspace)
        VStack(alignment: .leading, spacing: 0) {
            RelayFleetBoardHeader(counts: fleet.counts, hostCount: fleet.hostCount,
                                  shellsNotShown: fleet.shellsNotShown,
                                  filter: $filter) { workspace.isFleetBoardPresented = false }
                .padding(RelayTheme.Space.xl)
            Divider()
            ScrollView {
                RelayFleetBoardList(facts: fleet.rows, filter: filter) { fact in
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

// MARK: - Finished, not yet seen

/// A calm accent dot (info role, not a wait): an agent finished a turn or a
/// program reported done while the pane was out of sight. It is the store's
/// unread "done" marker, set only when nobody was looking and cleared when the
/// user views the pane. It never counts toward waiting.
struct RelayFinishedDot: View {
    let paneIDs: [UUID]
    var inbox: AgentIntelligenceStore?
    @Environment(\.relayInboxStore) private var environmentInbox

    var body: some View { Marker(paneIDs: paneIDs, inbox: inbox ?? environmentInbox) }

    static func unseen(_ paneIDs: [UUID], inbox: AgentIntelligenceStore) -> Int {
        paneIDs.filter { inbox.marker(for: $0) == .done }.count
    }

    static func label(_ count: Int) -> String {
        count > 1 ? "\(count) panes finished, not yet seen" : "Finished, not yet seen"
    }

    private struct Marker: View {
        let paneIDs: [UUID]
        @ObservedObject var inbox: AgentIntelligenceStore

        var body: some View {
            let count = RelayFinishedDot.unseen(paneIDs, inbox: inbox)
            if count > 0 {
                Circle().fill(RelayTheme.StatusRole.info.color)
                    .frame(width: 6, height: 6)
                    .help(RelayFinishedDot.label(count))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(RelayFinishedDot.label(count))
            }
        }
    }
}

private struct RelayInboxStoreKey: EnvironmentKey {
    static var defaultValue: AgentIntelligenceStore { MainActor.assumeIsolated { .shared } }
}

extension EnvironmentValues {
    /// The inbox the finished-dot reads; tests inject a private store.
    var relayInboxStore: AgentIntelligenceStore {
        get { self[RelayInboxStoreKey.self] }
        set { self[RelayInboxStoreKey.self] = newValue }
    }
}

// MARK: - Status mark

/// A tab, workspace or session row's status at a glance, from
/// `RelayWorkOverviewIndex.groupStatus`: a green waveform while an agent
/// runs, the warning symbol when something waits on the user, the danger
/// symbol for a failed exit, the grey reconnect or offline symbol for a
/// returning or lost connection, nothing when idle. Each shape differs, so
/// colour is never the only signal.
struct RelayStatusMark: View {
    typealias Status = RelayWorkOverviewIndex.PaneStatus
    enum Kind: Equatable { case none, symbol(String) }

    let status: Status?

    static let size: CGFloat = 12

    /// Working, not finished (the success checkmark) and not a circle, so it
    /// is never read as the reconnect arrows or the finished-unseen dot.
    static let runningSymbol = "waveform"

    static func kind(_ status: Status?) -> Kind {
        switch status {
        case nil, .idle?: .none
        case let status?: .symbol(status.symbol)
        }
    }

    static func spoken(_ status: Status) -> String { status.role.spoken(status.label) }

    /// Beside a row's alert marker: an unread "needs you" alert (waiting or
    /// error) already says the row waits, so the waiting or failed mark is dropped.
    static func status(_ status: Status?, besideAlert alert: RelayAttentionAlert?) -> Status? {
        status?.needsUser == true && alert?.needsUser == true ? nil : status
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.relayStatusMarkWindowVisible) private var windowVisible

    /// A running mark moves gently (the waveform's bars fill in turn) so a
    /// working agent stands out from the still marks; it stays still when the
    /// user asks for reduced motion or the window is not visible.
    static func animates(_ status: Status?, reduceMotion: Bool, windowVisible: Bool) -> Bool {
        status == .running && !reduceMotion && windowVisible
    }

    var body: some View {
        if let status, status != .idle {
            Group {
                switch Self.kind(status) {
                case .none: EmptyView()
                case let .symbol(name) where name == Self.runningSymbol:
                    // Core Animation plays the motion; no main-thread frames.
                    RelayRunningWaveform(color: status.role.color,
                                         animating: Self.animates(status, reduceMotion: reduceMotion,
                                                                  windowVisible: windowVisible))
                case let .symbol(name):
                    Image(systemName: name)
                        .font(RelayTheme.font(size: 10, weight: .semibold))
                        .foregroundStyle(status.role.color)
                }
            }
            .frame(width: Self.size, height: Self.size)
            .help(status.label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(status))
        }
    }
}

private struct RelayStatusMarkWindowVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the window holding status marks shows; set once per container.
    var relayStatusMarkWindowVisible: Bool {
        get { self[RelayStatusMarkWindowVisibleKey.self] }
        set { self[RelayStatusMarkWindowVisibleKey.self] = newValue }
    }
}

/// One window visibility observer per container (tab strip, navigator,
/// session list) for all the status marks inside it.
private struct RelayStatusMarkVisibilityScope: ViewModifier {
    @State private var visible = true
    func body(content: Content) -> some View {
        content
            .environment(\.relayStatusMarkWindowVisible, visible)
            .background(RelayStatusMarkVisibility(visible: $visible).frame(width: 0, height: 0))
    }
}

extension View {
    func relayStatusMarkVisibility() -> some View { modifier(RelayStatusMarkVisibilityScope()) }
}

/// The shared window visibility view (ordered in, not minimised, not fully
/// covered). The running waveform animates only while this reports visible.
private struct RelayStatusMarkVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context _: Context) -> RelayWindowVisibilityView {
        let view = RelayWindowVisibilityView()
        bind(view)
        return view
    }

    func updateNSView(_ view: RelayWindowVisibilityView, context _: Context) { bind(view) }

    private func bind(_ view: RelayWindowVisibilityView) {
        let visible = $visible
        // Reported from inside view updates; apply on the next turn.
        view.onChange = { showing in DispatchQueue.main.async { visible.wrappedValue = showing } }
    }

    static func dismantleNSView(_ view: RelayWindowVisibilityView, coordinator: ()) { view.detach() }
}
