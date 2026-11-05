import SwiftUI

struct RelayPaneHealthOverview: View {
    /// Cached rows, refreshed only while this window shows. The body must not
    /// call RelayPaneHealthCoordinator.snapshot(): it reads every pane's screen.
    @StateObject private var feed = RelayPaneHealthOverviewFeed.overview()
    /// Actions only; not observed, so its revisions do not invalidate the body.
    private let health = RelayPaneHealthCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(10)) {
            Text("All terminal panes (\(feed.value.reduce(0) { $0 + $1.summary.panes }))")
                .font(RelayTheme.font(size: 12, weight: .semibold))
            ForEach(feed.value, id: \.summary.host) { overview in
                let host = overview.summary
                VStack(alignment: .leading, spacing: RelayTheme.spacing(5)) {
                    HStack {
                        Text(host.name).fontWeight(.medium)
                        Spacer()
                        Button("Check now") { Task { await health.checkNow(host: host.host) } }
                            .disabled(overview.checkRunning)
                            .accessibilityIdentifier("relay.monitoring.pane-health.check." + host.host)
                        Text("\(host.freshObservations)/\(host.panes - host.endedPanes) recent native checks · \(host.endedPanes) ended")
                    }
                    let current = overview.livePanes.filter { $0.worker?.updateState == "current" }.count
                    let restart = overview.livePanes.filter { $0.worker?.upgradeMode == "restart_required" }.count
                    let update = overview.livePanes.filter { $0.worker?.upgradeMode == "in_place" && $0.worker?.updateState == "update_required" }.count
                    Text("Terminal helpers: \(current) current · \(restart) require restart · \(update) updates available")
                        .foregroundStyle(RelayTheme.textMuted)
                    Text("Haiku: \(host.state)").foregroundStyle(RelayTheme.textMuted)
                    Text(overview.controller == "relayd" ? "Monitoring runs on this host when Relay is closed" : "Host daemon ownership has not been verified")
                        .foregroundStyle(RelayTheme.textMuted)
                    DisclosureGroup("Pane details") {
                        ForEach(overview.livePanes, id: \.paneID) { pane in
                            HStack(alignment: .top, spacing: RelayTheme.spacing(8)) {
                                Text(String(pane.paneID.prefix(8))).monospaced()
                                Text(pane.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text(status(pane)).foregroundStyle(RelayTheme.textMuted)
                            }
                            .padding(.vertical, RelayTheme.spacing(2))
                        }
                    }
                }
                .font(RelayTheme.font(size: 11))
            }
            Text("Native checks are separate from Haiku’s assessment. Context rotation requires verified native support.")
                .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
        }
        .padding(RelayTheme.spacing(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("relay.monitoring.pane-health")
        .background(RelayWindowVisibilityReader(feed: feed).frame(width: 0, height: 0))
        .onDisappear { feed.setVisible(false) }
    }

    private func status(_ pane: RelayPaneHealthCoordinator.PaneOverview) -> String {
        if pane.observationState == "exited" { return "Ended" }
        if pane.observationState == "not_checked" { return "Awaiting native check" }
        if pane.observationState == "stale" { return "Check expired" }
        if pane.observationState == "connection_unavailable" { return "Connection unavailable" }
        var parts: [String] = []
        if pane.observationState == "unavailable" { parts.append("Identity unavailable") }
        switch pane.worker?.updateState {
        case "current": parts.append("Helper current")
        case "update_required": parts.append(pane.worker?.upgradeMode == "restart_required" ? "Helper needs restart" : "Helper update available")
        default: parts.append("Helper unverified")
        }
        if let context = pane.context {
            if !context.supported { parts.append("Context unsupported") }
            else if !context.enabled { parts.append(context.state == "human_takeover" ? "Context paused" : "Context off") }
            else { parts.append(context.lifecycle == "unavailable" ? "Rotation unavailable" : "Context enabled") }
        }
        return parts.joined(separator: " · ")
    }
}
