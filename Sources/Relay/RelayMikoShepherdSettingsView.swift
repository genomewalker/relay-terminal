import SwiftUI

@MainActor struct RelayMikoShepherdSettingsView: View {
    @ObservedObject var preferences: RelayPreferences = .shared
    var workspace: WorkspaceModel?
    private var hosts: [String] {
        Array(Set(workspace?.panes.values.map { $0.profile.kind == .local ? "This Mac" : $0.profile.host } ?? [])).sorted()
    }
    private func watchPane(_ id: UUID) -> Binding<Bool> {
        Binding(get: { !preferences.shepherd.excludedPanes.contains(id) }, set: { watch in
            if watch { preferences.shepherd.excludedPanes.remove(id) } else { preferences.shepherd.excludedPanes.insert(id) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Miko pane shepherd", isOn: $preferences.shepherd.enabled)
                .accessibilityIdentifier("relay.settings.miko.shepherd")
            Picker("Miko model", selection: $preferences.shepherd.model) {
                ForEach(RelayShepherdSettings.Model.allCases, id: \.self) { model in Text("Haiku").tag(model) }
            }.accessibilityIdentifier("relay.settings.miko.model")
            Text("Watch Claude and Codex panes on connected hosts. Report changes, finished jobs, stalls and requests for your input. Reports use templates and consume zero model tokens. Interactive Miko uses Haiku and the hourly cap below.")
                .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
            Text("Shepherd mode allows read-only observation plus the registered report push. Pause Miko above to stop polling and reports.")
                .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
            Stepper("Poll every \(preferences.shepherd.interval) seconds", value: $preferences.shepherd.interval, in: 10...300, step: 10)
            Stepper("Stall after \(preferences.shepherd.stallSeconds / 60) minutes", value: $preferences.shepherd.stallSeconds, in: 60...7200, step: 60)
            Stepper("Model calls per hour: \(preferences.shepherd.callsPerHour)", value: $preferences.shepherd.callsPerHour, in: 0...600)
            Stepper("Input token cap per hour: \(preferences.shepherd.tokensPerHour)", value: $preferences.shepherd.tokensPerHour, in: 0...2_000_000, step: 10_000)
            Text("Reports appear in the attention inbox and Miko's Shepherd reports. To let an agent read them, register its pane below under Miko supervisors; it can use relay_miko_state. Registration and these controls are available only here in Settings.")
                .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
            RelayShepherdPushSettingsView(workspace: workspace)
            DisclosureGroup("Watched hosts and panes") {
                ForEach(hosts, id: \.self) { host in
                    Toggle(host, isOn: Binding(get: { !preferences.shepherd.excludedHosts.contains(host) }, set: { watch in
                        if watch { preferences.shepherd.excludedHosts.remove(host) } else { preferences.shepherd.excludedHosts.insert(host) }
                    }))
                }
                if let workspace {
                    ForEach(workspace.panes.values.filter { $0.kind == .claude || $0.kind == .codex }.sorted { $0.id.uuidString < $1.id.uuidString }) { pane in
                        Toggle(pane.displayName + " · " + String(pane.id.uuidString.prefix(8)), isOn: watchPane(pane.id))
                    }
                }
            }
        }.accessibilityIdentifier("relay.settings.miko.shepherd-controls")
    }
}

@MainActor struct RelayShepherdPushSettingsView: View {
    var workspace: WorkspaceModel?
    @ObservedObject var push: RelayShepherdPushController = .shared
    @State private var choices: [RelayShepherdPushController.Choice] = []
    @State private var selected = ""
    @State private var error: String?
    @State private var registering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One report pane (Settings only)").font(RelayTheme.font(size: 12, weight: .semibold))
            Text("Choose an existing linked destination. Its other pane is a routing link anchor, not the sender. Link panes through Relay first if none appear.")
                .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Report destination", selection: $selected) {
                Text("Choose a linked pane").tag("")
                ForEach(choices) { choice in Text(choice.label).tag(choice.id) }
            }.accessibilityIdentifier("relay.settings.miko.report-target")
            HStack {
                Button("Refresh linked panes") { Task { choices = await push.choices(workspace: workspace) } }
                Button(registering ? "Registering…" : "Register report pane") {
                    guard let choice = choices.first(where: { $0.id == selected }) else { return }
                    registering = true; error = nil
                    Task { @MainActor in
                        defer { registering = false }
                        do { try await push.register(choice, origin: .userSettings) }
                        catch { self.error = "Registration failed; no fallback pane. \(error.localizedDescription)" }
                    }
                }.disabled(registering || selected.isEmpty)
                Button("Stop pane delivery") {
                    do { try push.clearTarget(origin: .userSettings); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }.controlSize(.small)
            Stepper("Report messages per hour: \(push.ledger.settings.messagesPerHour)", value: Binding(
                get: { push.ledger.settings.messagesPerHour }, set: { value in
                    do { try push.setCap(value, origin: .userSettings); error = nil }
                    catch { self.error = error.localizedDescription }
                }), in: 1...600).accessibilityIdentifier("relay.settings.miko.report-cap")
            Text("Owner/Miko-submitted, with the same trust as existing Miko messages. No app, Run, kernel or pane attestation. Reservations survive restart; failures or uncertain outcomes stop this registration until you review and register it again. No retry or fallback. UI/state reports continue.")
                .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text(push.statusText).font(RelayTheme.font(size: 10.5, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(RelayTheme.font(size: 11)).foregroundStyle(.orange) }
        }.accessibilityIdentifier("relay.settings.miko.report-controls")
        .task { choices = await push.choices(workspace: workspace) }
    }
}
