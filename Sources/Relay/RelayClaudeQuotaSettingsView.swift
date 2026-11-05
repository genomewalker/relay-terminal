import SwiftUI

/// Native Settings is the sole writer; relay_update_settings rejects this key.
@MainActor struct RelayClaudeQuotaSettingsView: View {
    var configuredHosts: Set<String> = []
    @ObservedObject private var preferences = RelayPreferences.shared
    @ObservedObject private var scheduler = RelayClaudeQuotaScheduler.shared
    private var settings: Binding<RelayClaudeQuotaSettings> { $preferences.claudeQuotaFailover }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude quota failover").font(.headline)
            Toggle("Automatically move Claude panes when the source quota is high", isOn: settings.enabled)
                .accessibilityIdentifier("relay.settings.claude-quota-failover.enabled")
            LabeledContent("Source account") { TextField("Label", text: settings.source).labelsHidden() }
            LabeledContent("Target account") { TextField("Label", text: settings.target).labelsHidden() }
            Stepper("5-hour threshold: \(Int(settings.wrappedValue.threshold))%", value: settings.threshold, in: 1...100)
            Stepper("Weekly threshold: \(Int(settings.wrappedValue.weeklyThreshold))%", value: settings.weeklyThreshold, in: 1...100)
            Stepper("Target ceiling (both windows): \(Int(settings.wrappedValue.targetCeiling))%", value: settings.targetCeiling, in: 1...100)
            ForEach(configuredHosts.union(scheduler.hostKeys).union(settings.wrappedValue.hosts.keys).sorted(), id: \.self) { host in
                Toggle(host == "local" ? "Enable on This Mac" : "Enable on \(host)", isOn: Binding(
                    get: { settings.wrappedValue.hosts[host] ?? true },
                    set: { preferences.claudeQuotaFailover.hosts[host] = $0 }))
            }
            if !settings.wrappedValue.valid { Text("Choose different valid account labels and percentages from 1 to 100.").foregroundStyle(RelayTheme.coral) }
            ForEach(scheduler.usageLines.keys.sorted(), id: \.self) { host in
                Text(([host] + (scheduler.usageLines[host] ?? [])).joined(separator: " · "))
                    .font(RelayTheme.font(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(scheduler.deferrals.keys.sorted(), id: \.self) { host in
                Text("\(host): waiting — \(scheduler.deferrals[host] ?? "")")
                    .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            Text("5-hour and weekly usage/reset times appear here when fresh observations are available. Enabling now can immediately move idle team panes: weekly team usage was 98% when this feature was requested.")
                .font(RelayTheme.font(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("Runs while Relay is open. Moves wait for a verified empty, idle prompt. Return waits for every triggering reset and fresh usage below both thresholds. Disable failover or this host to stop new moves; the existing caller pause is also honored. Shared conversation history is required; switching accounts loses Claude's prompt cache.")
                .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted).fixedSize(horizontal: false, vertical: true)
            if let problem = scheduler.problem { Text(problem).foregroundStyle(RelayTheme.coral) }
            ForEach(scheduler.notices.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { pane in
                Text("\(pane.uuidString.prefix(8)): \(scheduler.notices[pane] ?? "")").foregroundStyle(RelayTheme.coral)
            }
        }.padding(.vertical, 10)
    }
}
