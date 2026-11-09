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
    /// A finished turn, "Done", a clean exit and idle are not attention; a
    /// non-zero exit is.
    static func needsAttention(phase: AgentPhase, approvals: Int, programState: String?, failedExit: Bool = false) -> Bool {
        approvals > 0 || phase == .needsInput || programState == "blocked" || programState == "error" || failedExit
    }

    /// Waiting wins over a lost connection: a reconnecting pane whose replayed
    /// state is waiting still waits on the user. A pane still connecting for
    /// the first time is idle, not disconnected.
    static func paneStatus(phase: AgentPhase, approvals: Int, programState: String?,
                           connection: PaneConnectionState, failedExit: Bool = false) -> PaneStatus {
        if needsAttention(phase: phase, approvals: approvals, programState: programState, failedExit: failedExit) { return .waiting }
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
        /// An agent has been seen: a harness or detected provider, an agent
        /// event, a pending approval or a program self-report.
        var isAgent = true
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
        let failedExit = WorkspaceModel.failedExitStatus(pane)
        let status = paneStatus(phase: pane.phase, approvals: pane.pendingAgentApprovals,
                                programState: report, connection: pane.connectionState, failedExit: failedExit != nil)
        // A lost connection names itself (disconnecting also marks the phase
        // exited); a pane whose session ended while connected says Exited.
        let connectionLost = switch pane.connectionState {
        case .disconnected, .reconnecting, .waitingForNetwork: true
        case .connecting, .connected: false
        }
        let detail = status == .waiting && pane.phase == .exited && pane.pendingAgentApprovals == 0 && failedExit != nil
            ? "Exited with status \(failedExit ?? 0)"
            : status == .disconnected
            ? (!connectionLost && pane.phase == .exited ? PaneDisplayState.exited.label : pane.connectionStatusLabel)
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
            rows = facts.filter { $0.isAgent || $0.status == .waiting }
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
                    // Full words when they fit, else counts beside their symbols.
                    ViewThatFits(in: .horizontal) {
                        segmentRow(segments, words: true)
                        segmentRow(segments, words: false)
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

    /// The board's order: waiting, disconnected, running; empty ones hidden.
    static func segments(_ counts: RelayWorkOverviewIndex.PaneCounts) -> [RelayWorkOverviewIndex.PaneStatus] {
        [.waiting, .disconnected, .running].filter { counts[$0] > 0 }
    }

    static func shortLabel(_ status: RelayWorkOverviewIndex.PaneStatus, _ count: Int) -> String {
        switch status {
        case .waiting: "\(count) waiting"
        case .disconnected: "\(count) disconnected"
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

    private func segmentRow(_ segments: [RelayWorkOverviewIndex.PaneStatus], words: Bool) -> some View {
        HStack(spacing: RelayTheme.Space.sm) {
            ForEach(Array(segments.enumerated()), id: \.element) { index, status in
                if index > 0 { Text("·").foregroundStyle(RelayTheme.textMuted) }
                part(words ? Self.shortLabel(status, counts[status]) : "\(counts[status])", status: status)
            }
        }
        .fixedSize()
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

// MARK: - Status mark

/// A tab, workspace or session row's status at a glance, from
/// `RelayWorkOverviewIndex.groupStatus`: a turning arc while an agent runs
/// (still under reduce motion), the warning symbol when something waits on
/// the user, the danger symbol when disconnected, nothing when idle. Each
/// shape differs, so colour is never the only signal.
struct RelayStatusMark: View {
    typealias Status = RelayWorkOverviewIndex.PaneStatus
    enum Kind: Equatable { case none, spinner, staticRunning, symbol(String) }

    let status: Status?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.relayStatusMarkWindowVisible) private var windowVisible

    static let size: CGFloat = 12

    static func kind(_ status: Status?, reduceMotion: Bool) -> Kind {
        switch status {
        case nil, .idle?: .none
        case .running?: reduceMotion ? .staticRunning : .spinner
        case let status?: .symbol(status.role.symbol)
        }
    }

    static func spoken(_ status: Status) -> String { status.role.spoken(status.label) }

    /// Beside a row's alert marker: an unread "needs you" alert (waiting or
    /// error) already says the row waits, so the waiting mark is dropped.
    static func status(_ status: Status?, besideAlert alert: RelayAttentionAlert?) -> Status? {
        status == .waiting && alert?.needsUser == true ? nil : status
    }

    var body: some View {
        if let status, status != .idle {
            Group {
                switch Self.kind(status, reduceMotion: reduceMotion) {
                case .none: EmptyView()
                case .staticRunning: RelayRunningArc()
                case .spinner: RelaySpinningArc(animating: windowVisible)
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

private struct RelayRunningArc: View {
    var angle: Angle = .zero
    var body: some View {
        ZStack {
            Circle().stroke(RelayTheme.success.opacity(0.25), lineWidth: 1.75)
            Circle().trim(from: 0, to: 0.7)
                .stroke(RelayTheme.success, style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                .rotationEffect(angle)
        }
        .padding(1.5)
    }
}

/// The running arc, turned by a Core Animation layer animation: the render
/// server draws the frames, so Relay does no per-frame work (a SwiftUI
/// TimelineView or repeating SwiftUI animation re-renders in-process every
/// frame). The animation is removed while the window does not show.
private struct RelaySpinningArc: NSViewRepresentable {
    let animating: Bool

    func makeNSView(context _: Context) -> RelaySpinnerView { RelaySpinnerView() }

    func updateNSView(_ view: RelaySpinnerView, context _: Context) { view.animating = animating }
}

final class RelaySpinnerView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var occlusionObserver: NSObjectProtocol?
    var animating = false { didSet { if animating != oldValue { updateSpin() } } }
    /// The window server's occlusion; replaceable where no window is shown.
    var occlusionVisible: (NSWindow) -> Bool = { $0.occlusionState.contains(.visible) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for (layer, end) in [(track, 1.0), (arc, 0.7)] {
            layer.fillColor = nil
            layer.lineWidth = 1.75
            layer.lineCap = .round
            layer.strokeEnd = end
            self.layer?.addSublayer(layer)
        }
        updateColors()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: RelayStatusMark.size, height: RelayStatusMark.size) }
    override var isFlipped: Bool { true }

    /// The layers drawn by hand, for tests.
    var shapeLayers: [CAShapeLayer] { [track, arc] }
    var isSpinning: Bool { arc.animation(forKey: "spin") != nil }

    override func layout() {
        super.layout()
        // Same geometry as the still arc: 1.5 pt inset, stroke centred on the circle.
        let inset = 1.5 + 1.75 / 2
        let box = bounds.insetBy(dx: inset, dy: inset)
        withoutImplicitAnimation {
            for layer in [track, arc] {
                layer.frame = bounds
                layer.path = CGPath(ellipseIn: box, transform: nil)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            // Marks outside a visibility scope still stop in a covered window.
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.updateSpin() } }
        }
        updateScale()
        updateSpin()
    }

    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? 2
        withoutImplicitAnimation {
            for layer in [track, arc] { layer.contentsScale = scale }
        }
    }

    private func updateColors() {
        withoutImplicitAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                track.strokeColor = RelayPalette.success.withAlphaComponent(0.25).cgColor
                arc.strokeColor = RelayPalette.success.cgColor
            }
        }
    }

    private func updateSpin() {
        guard animating, let window, occlusionVisible(window) else {
            arc.removeAnimation(forKey: "spin")
            return
        }
        guard !isSpinning else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
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
/// covered), so a spinner in a hidden window stops drawing frames.
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
