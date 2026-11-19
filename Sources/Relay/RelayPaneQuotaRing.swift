import SwiftUI

extension AgentKind {
    /// The subscription a pane of this kind draws on, if any.
    var quotaProvider: RelaySubscriptionQuota.Provider? {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .shell, .other: return nil
        }
    }
}

/// What one agent pane's quota ring shows: the shortest open usage window
/// (Claude's and Codex's 5-hour limit) of the pane's own account.
struct RelayPaneQuotaGlance: Equatable {
    enum Level: Equatable { case normal, warning, critical }
    /// 0...1 of the shown window used, or nil when nothing is known.
    let usedFraction: Double?
    /// The reading is older than the live bound or its host read failed.
    let stale: Bool
    let level: Level
    let help: String

    static let warningPercent = 75.0
    static let criticalPercent = 90.0

    /// A reading stays shown after it ages, marked stale with its age, until
    /// its window resets; a passed reset is never shown as a fresh allowance.
    static func make(entry: RelaySubscriptionQuotaStore.Entry?, now: Date) -> RelayPaneQuotaGlance {
        guard let entry, let quota = entry.quota else {
            let reason = entry?.refreshFailed == true ? "Usage refresh failed" : "Usage not known yet"
            return .init(usedFraction: nil, stale: true, level: .normal, help: reason)
        }
        let open = quota.windows.filter { window in window.resetsAt.map { $0 > now } ?? true }
            .sorted { ($0.durationMinutes ?? .max, $0.id) < ($1.durationMinutes ?? .max, $1.id) }
        let account = entry.provider.rawValue.capitalized + (entry.accountLabel.map { " · " + $0 } ?? "")
        guard let shown = open.first else {
            return .init(usedFraction: nil, stale: true, level: .normal,
                         help: account + "\nNo open usage window · refresh to check")
        }
        let stale = entry.refreshFailed || !quota.observationIsCurrent(now: now)
        let used = min(max(shown.usedPercent, 0), 100)
        let level: Level = used >= criticalPercent ? .critical : used >= warningPercent ? .warning : .normal
        var lines = [account]
        for window in open.prefix(3) {
            var line = "\(window.label): \(Int(window.usedPercent.rounded()))% used"
            if let reset = window.resetsAt { line += " · resets " + resetText(reset, now: now) }
            lines.append(line)
        }
        lines.append((stale ? "Last known, " : "As of ") + ageText(now.timeIntervalSince(quota.observedAt)))
        return .init(usedFraction: used / 100, stale: stale, level: level, help: lines.joined(separator: "\n"))
    }

    static func resetText(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm")
        return formatter.string(from: date)
    }

    static func ageText(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) h \(minutes % 60) min ago"
    }
}

/// A small usage ring in an agent pane's header.
struct RelayPaneQuotaRing: View {
    let paneID: UUID
    @ObservedObject private var store = RelaySubscriptionQuotaStore.shared
    @State private var now = Date()

    var body: some View {
        let glance = RelayPaneQuotaGlance.make(entry: store.entry(forPane: paneID), now: now)
        ZStack {
            Circle().stroke(RelayTheme.textFaint.opacity(0.35), lineWidth: 2)
            if let used = glance.usedFraction {
                Circle().trim(from: 0, to: max(used, 0.02))
                    .stroke(color(glance.level), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle().stroke(RelayTheme.textFaint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [1.5, 2]))
            }
        }
        .frame(width: 11, height: 11)
        .opacity(glance.stale ? 0.45 : 1)
        .frame(width: 20, height: 24)
        .contentShape(Rectangle())
        .help(glance.help)
        .accessibilityElement()
        .accessibilityLabel(glance.usedFraction.map { "Account usage \(Int(($0 * 100).rounded())) percent of the current window" }
            ?? "Account usage unknown")
        .accessibilityHint(glance.help)
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private func color(_ level: RelayPaneQuotaGlance.Level) -> Color {
        switch level {
        case .normal: return RelayTheme.accent
        case .warning: return .orange
        case .critical: return RelayTheme.coral
        }
    }
}
