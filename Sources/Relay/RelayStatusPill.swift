import SwiftUI

/// The Refreshed interface's one status label per agent pane, with a live
/// timer while the agent works or waits on the user. Classic keeps
/// `RelayBadge` with `PaneModel.headerStatus`.
struct RelayPaneStatusLabel: Equatable {
    enum State: CaseIterable, Equatable {
        case running, needsYou, ready, idle, exited, connecting, reconnecting, disconnected

        var text: String {
            switch self {
            case .running: "Running"
            case .needsYou: "Needs you"
            case .ready: "Ready"
            case .idle: "Idle"
            case .exited: "Exited"
            case .connecting: "Connecting"
            case .reconnecting: "Reconnecting"
            case .disconnected: "Disconnected"
            }
        }

        /// Colour is never the only signal: each state also has its own symbol.
        var symbol: String {
            switch self {
            case .running: "circle.fill"
            case .needsYou: "hand.raised.fill"
            case .ready: "checkmark.circle.fill"
            case .idle: "moon.zzz"
            case .exited: "stop.circle"
            case .connecting: "ellipsis.circle"
            case .reconnecting: "arrow.triangle.2.circlepath"
            case .disconnected: "wifi.slash"
            }
        }

        var color: Color {
            switch self {
            case .running: RelayTheme.lime
            case .needsYou: RelayTheme.coral
            case .ready: RelayTheme.success
            case .idle, .exited, .connecting, .reconnecting, .disconnected: RelayTheme.textMuted
            }
        }
    }

    let state: State
    /// Start of the live timer; nil when the state shows no timer.
    let timerSince: Date?

    /// A shell gets no label. A connection problem comes first, then a
    /// question or approval waiting on the user, then the agent's phase.
    static func make(kind: AgentKind, phase: AgentPhase, connection: PaneConnectionState, pendingApprovals: Int,
                     finishedUnseen: Bool, phaseSince: Date) -> RelayPaneStatusLabel? {
        guard kind != .shell else { return nil }
        switch connection {
        case .reconnecting, .waitingForNetwork: return .init(state: .reconnecting, timerSince: nil)
        case .disconnected: return .init(state: .disconnected, timerSince: nil)
        case .connecting: return .init(state: .connecting, timerSince: nil)
        case .connected: break
        }
        if phase == .exited { return .init(state: .exited, timerSince: nil) }
        if phase == .needsInput || pendingApprovals > 0 { return .init(state: .needsYou, timerSince: phaseSince) }
        switch phase {
        case .active: return .init(state: .running, timerSince: phaseSince)
        case .connecting: return .init(state: .connecting, timerSince: nil)
        case .quiet: return .init(state: finishedUnseen ? .ready : .idle, timerSince: nil)
        case .needsInput, .exited: return nil
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

/// A capsule with the state's symbol, its name and, while live, the elapsed
/// time, redrawn once a second only while a timer shows.
struct RelayStatusPill: View {
    let label: RelayPaneStatusLabel

    var body: some View {
        if let since = label.timerSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                pill(timer: RelayPaneStatusLabel.elapsed(context.date.timeIntervalSince(since)))
            }
        } else {
            pill(timer: nil)
        }
    }

    private func pill(timer: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: label.state.symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(label.state.color)
            Text(label.state.text)
                .fontWeight(.medium)
            if let timer {
                Text(timer)
                    .monospacedDigit()
                    .foregroundStyle(RelayTheme.textMuted)
            }
        }
        .font(RelayTheme.font(size: 11))
        .foregroundStyle(RelayTheme.text)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(label.state.color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(label.state.color.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.state.text + (timer.map { ", for " + $0 } ?? ""))
    }
}

/// The pane header's Refreshed label; observes the inbox so Ready appears
/// and clears with the finished-not-seen marker.
struct RelayRefreshedPaneStatus: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject var inbox: AgentIntelligenceStore

    var body: some View {
        if let label = RelayPaneStatusLabel.make(kind: pane.kind, phase: pane.phase, connection: pane.connectionState,
                                                 pendingApprovals: pane.pendingAgentApprovals,
                                                 finishedUnseen: inbox.marker(for: pane.id) == .done,
                                                 phaseSince: pane.phaseChangedAt) {
            RelayStatusPill(label: label)
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
