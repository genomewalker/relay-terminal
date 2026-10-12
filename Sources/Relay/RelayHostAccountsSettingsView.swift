import SwiftUI

@MainActor final class RelaySettingsNavigation: ObservableObject {
    static let shared = RelaySettingsNavigation()
    @Published var section = "general"
    @Published var preferredAccountsProfile: ConnectionProfile?

    func showAccounts(profile: ConnectionProfile? = nil) {
        preferredAccountsProfile = profile
        section = "accounts"
    }
}

struct RelayHostAccountsSettingsView: View {
    @StateObject private var profiles = ProfileStore()
    @ObservedObject private var navigation = RelaySettingsNavigation.shared
    @State private var selectedHostKey = ConnectionProfile.local.connectionKey

    private var hosts: [ConnectionProfile] {
        var values = [ConnectionProfile.local] + profiles.connectableHosts.filter { $0.backend == .relay }
        if let preferred = navigation.preferredAccountsProfile, preferred.backend == .relay,
           !values.contains(where: { $0.connectionKey == preferred.connectionKey }) { values.append(preferred) }
        return values
    }
    private var selectedProfile: ConnectionProfile {
        hosts.first(where: { $0.connectionKey == selectedHostKey }) ?? .local
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Host", selection: $selectedHostKey) {
                    ForEach(hosts, id: \.connectionKey) { profile in
                        Text(profile.kind == .local ? "This Mac" : profile.name).tag(profile.connectionKey)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("relay.settings.account-hosts")
                Text("Accounts and limits apply to every tab on " + (selectedProfile.kind == .local ? "this Mac." : selectedProfile.host + "."))
                    .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                if selectedProfile.kind == .ssh {
                    Text("Keys stay on the remote host so handoff generation can continue while Relay is closed.")
                        .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.textMuted)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            RelayHostAccountsPanel(profile: selectedProfile).id(selectedProfile.connectionKey)
        }
        .onAppear {
            if let preferred = navigation.preferredAccountsProfile { selectedHostKey = preferred.connectionKey }
        }
        .onChange(of: navigation.preferredAccountsProfile) { _, profile in
            if let profile { selectedHostKey = profile.connectionKey }
        }
    }
}
