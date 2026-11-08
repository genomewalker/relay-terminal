import SwiftUI

/// User-only controls. No MCP route invokes these setters.
@MainActor struct RelayMikoPolicySettingsView: View {
    @ObservedObject var preferences = RelayPreferences.shared
    @ObservedObject var supervision = RelayMikoSupervision.shared
    @State private var pauseError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Miko autonomy", selection: $preferences.mikoAutonomy) {
                Text("Autonomous").tag(RelayMikoPolicySettings.Autonomy.autonomous)
                Text("Cards for writes").tag(RelayMikoPolicySettings.Autonomy.cardsForWrites)
                Text("Cards for all actions").tag(RelayMikoPolicySettings.Autonomy.cardsForAllActions)
            }.accessibilityIdentifier("relay.settings.miko.autonomy")
            Text("Miko acts autonomously and asks when it needs your decision. Choose cards to review actions before they run. Pausing stops new actions in every workspace.")
                .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Let agent panes ask Miko to update relayd on hosts", isOn: $preferences.agentHostRelaydUpdates)
                .accessibilityIdentifier("relay.settings.miko.agent-relayd-updates")
            Text("When on, a coding agent's request to Miko to update relayd on a configured host carries your authority and runs without a card. Every other agent request still waits for your Run. Only you can change this here.")
                .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Pause Miko", isOn: Binding(get: { supervision.current.disabledTools.contains("*") }, set: { paused in
                do {
                    try supervision.setMikoPaused(paused)
                    pauseError = nil
                } catch { pauseError = "Miko pause could not be saved: " + error.localizedDescription }
            })).accessibilityIdentifier("relay.settings.miko.pause")
            if let pauseError { Text(pauseError).foregroundStyle(RelayTheme.coral) }
            Stepper("Actions per minute: \(preferences.mikoMinute)", value: $preferences.mikoMinute, in: 1...600)
            Stepper("Actions per hour: \(preferences.mikoHour)", value: $preferences.mikoHour, in: 1...10_000)
            Stepper("Per target per minute: \(preferences.mikoTargetMinute)", value: $preferences.mikoTargetMinute, in: 1...100)
            Stepper("Identical actions per hour: \(preferences.mikoRepetitions)", value: $preferences.mikoRepetitions, in: 1...20)
        }
    }
}
