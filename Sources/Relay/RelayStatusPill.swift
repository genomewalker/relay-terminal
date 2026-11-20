import SwiftUI

/// The Refreshed interface's one status label per agent pane: a dot, a word
/// and, while the agent works or waits on the user, a live timer. A current
/// program report decides it; terminal output only fills in without one.
/// Classic keeps `RelayBadge` with `PaneModel.headerStatus` and the separate
/// `RelayProgramStatusBadge`.
struct RelayPaneStatusLabel: Equatable {
    enum State: CaseIterable, Equatable {
        case running, needsYou, ready, idle, failed, exited, connecting, reconnecting, disconnected

        var text: String {
            switch self {
            case .running: "Running"
            case .needsYou: "Needs you"
            case .ready: "Ready"
            case .idle: "Idle"
            case .failed: "Failed"
            case .exited: "Exited"
            case .connecting: "Connecting"
            case .reconnecting: "Reconnecting"
            case .disconnected: "Disconnected"
            }
        }

        /// One colour per meaning; the word always says it as well.
        var color: Color {
            switch self {
            case .running: RelayRefreshedTheme.working
            case .needsYou: RelayRefreshedTheme.warn
            case .ready: RelayRefreshedTheme.ok
            case .failed, .disconnected: RelayRefreshedTheme.bad
            case .idle, .exited, .connecting, .reconnecting: RelayRefreshedTheme.faint
            }
        }
    }

    /// A program's current self-report: its most urgent state and when that
    /// state began.
    struct ProgramReport: Equatable {
        let state: String
        let since: Date
    }

    let state: State
    /// Start of the live timer; nil when the state shows no timer.
    let timerSince: Date?

    /// Order: connection problem, exit, a Relay approval, the program's own
    /// report, then what terminal output suggests. A shell gets a label only
    /// when a program in it reports.
    static func make(kind: AgentKind, phase: AgentPhase, connection: PaneConnectionState, pendingApprovals: Int,
                     finishedUnseen: Bool, phaseSince: Date, program: ProgramReport?) -> RelayPaneStatusLabel? {
        guard kind != .shell || program != nil else { return nil }
        switch connection {
        case .reconnecting, .waitingForNetwork: return .init(state: .reconnecting, timerSince: nil)
        case .disconnected: return .init(state: .disconnected, timerSince: nil)
        case .connecting: return .init(state: .connecting, timerSince: nil)
        case .connected: break
        }
        if phase == .exited { return .init(state: .exited, timerSince: nil) }
        if pendingApprovals > 0 { return .init(state: .needsYou, timerSince: phaseSince) }
        if let program {
            switch program.state {
            case "working": return .init(state: .running, timerSince: program.since)
            case "blocked": return .init(state: .needsYou, timerSince: program.since)
            case "error": return .init(state: .failed, timerSince: nil)
            case "done": return .init(state: .ready, timerSince: nil)
            default: return .init(state: finishedUnseen ? .ready : .idle, timerSince: nil)
            }
        }
        switch phase {
        case .needsInput: return .init(state: .needsYou, timerSince: phaseSince)
        case .active: return .init(state: .running, timerSince: phaseSince)
        case .connecting: return .init(state: .connecting, timerSince: nil)
        case .quiet: return .init(state: finishedUnseen ? .ready : .idle, timerSince: nil)
        case .exited: return nil
        }
    }

    /// A quiet spell shorter than this between two working spells is part of
    /// the same run; terminal-output detection goes quiet after 1.4 s.
    static let pauseGrace: TimeInterval = 30

    /// The timer start after a phase change, and the start of the current run
    /// of work. Returning to work within `pauseGrace` of going quiet resumes
    /// the run's start; anything else starts the timer now.
    static func nextTimer(old: AgentPhase, new: AgentPhase, lastChange: Date, runStart: Date?,
                          now: Date) -> (since: Date, runStart: Date?) {
        switch (old, new) {
        case (.quiet, .active):
            if let runStart, now.timeIntervalSince(lastChange) < pauseGrace { return (runStart, runStart) }
            return (now, now)
        case (_, .active): return (now, now)
        case (.active, .quiet): return (now, runStart)
        default: return (now, nil)
        }
    }

    /// "0s", "59s", "3m 12s", "1h 02m".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3_600, (total % 3_600) / 60)
    }
}

/// Dot, word and, while live, the elapsed time; no capsule. Redrawn once a
/// second only while a timer shows.
struct RelayStatusPill: View {
    let label: RelayPaneStatusLabel

    var body: some View {
        if let since = label.timerSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                content(timer: RelayPaneStatusLabel.elapsed(context.date.timeIntervalSince(since)))
            }
        } else {
            content(timer: nil)
        }
    }

    private func content(timer: String?) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(label.state.color)
                .frame(width: 6, height: 6)
            Text(label.state.text)
                .font(RelayTheme.font(size: 11, weight: .medium))
                .foregroundStyle(RelayRefreshedTheme.ink)
            if let timer {
                Text(timer)
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(RelayRefreshedTheme.muted)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.state.text + (timer.map { ", for " + $0 } ?? ""))
    }
}

/// The pane header's Refreshed label; observes the inbox so Ready appears
/// and clears with the finished-not-seen marker. Replaces both the Classic
/// status badge and the program-status badge.
struct RelayRefreshedPaneStatus: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject var inbox: AgentIntelligenceStore

    var body: some View {
        if let label = RelayPaneStatusLabel.make(kind: pane.kind, phase: pane.phase, connection: pane.connectionState,
                                                 pendingApprovals: pane.pendingAgentApprovals,
                                                 finishedUnseen: inbox.marker(for: pane.id) == .done,
                                                 phaseSince: pane.phaseChangedAt, program: pane.programStatusPrimary) {
            if pane.programStatus.records.isEmpty {
                RelayStatusPill(label: label)
            } else {
                // The program's task list opens from the one label.
                RelayProgramStatusBadge(pane: pane, label: label)
            }
        }
    }
}

private struct RelayInterfaceStyleKey: EnvironmentKey {
    static let defaultValue: RelayInterfaceStyle? = nil
}

extension EnvironmentValues {
    /// Overrides the Interface preference for one view tree (tests, previews);
    /// nil reads `RelayPreferences.shared.interfaceStyle`.
    var relayInterfaceStyle: RelayInterfaceStyle? {
        get { self[RelayInterfaceStyleKey.self] }
        set { self[RelayInterfaceStyleKey.self] = newValue }
    }
}
