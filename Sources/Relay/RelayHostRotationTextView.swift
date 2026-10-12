import SwiftUI

struct RelayHostAccountsPanel: View {
    private let service: RelayHostAccountsService
    init(profile: ConnectionProfile) { service = .init(profile: profile) }
    @State private var status: RelayHostRotationTextRPC.Status?
    @State private var settings = RelayHostRotationTextRPC.Settings()
    @State private var daily = "0"
    @State private var monthly = "0"
    @State private var requests = "0"
    @State private var busy = false
    @State private var needsStatus = false
    @State private var error: String?
    @State private var acknowledgeID: String?
    @State private var confirmAcknowledgement = false
    @State private var editingAccount: RelayHostRotationTextRPC.Account?
    @State private var recoveringReference: String?
    @State private var credentials: [RelayHostRotationTextRPC.CredentialRecord] = []
    @State private var credentialsBusy = false
    @State private var credentialError: String?
    @State private var observedProfile: ConnectionProfile?
    @State private var savedMessage: String?
    @State private var showStoredKeys = false

    private var hostName: String { service.profile.kind == .local ? "This Mac" : service.profile.host }

    private var pendingSettings: RelayHostRotationTextRPC.Settings? {
        guard let day = RelayHostRotationTextRPC.parseDollars(daily),
              let month = RelayHostRotationTextRPC.parseDollars(monthly),
              requests.range(of: #"^[0-9]{1,5}$"#, options: .regularExpression) != nil,
              let count = Int(requests) else { return nil }
        var value = settings
        value.dailyLimitMicrousd = day; value.monthlyLimitMicrousd = month; value.maxRequestsPerDay = count
        return value.valid ? value : nil
    }
    private var validationMessage: String? {
        if RelayHostRotationTextRPC.parseDollars(daily) == nil ||
            RelayHostRotationTextRPC.parseDollars(monthly) == nil {
            return "Enter dollar budgets from 0 to 200, with up to six decimal places."
        }
        if settings.enabled && settings.accounts == nil && settings.providers.contains("codex_account") && settings.codexModel == nil {
            return "Choose the Codex model used by the saved account."
        }
        if pendingSettings == nil {
            return "Choose at least one provider and a request cap up to 10,000. When enabled, the cap must be positive; Claude API also needs budgets of at least $1."
        }
        return nil
    }
    private var canChange: Bool {
        !busy && !needsStatus && observedProfile == service.profile && status != nil && status?.isUnsupported != true && service.canManageAccounts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(10)) {
            HStack {
                Text("Saved accounts").font(.subheadline.weight(.semibold))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            if let status, !status.isUnsupported {
                if status.supportsCredentials { accounts.disabled(!canChange) }
                Divider().padding(.vertical, 8)
                Text("Handoff generation").font(.subheadline.weight(.semibold))
                Toggle("Generate handoff text", isOn: $settings.enabled).disabled(!canChange)
                    .accessibilityIdentifier("relay.context-management.text-enabled")
                Text("Generation is " + (settings.enabled ? "on" : "off") + " for this host. Changes apply when you save.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Provider order and host limits") {
                providerOrder.disabled(!canChange)
                HStack {
                    amountField("Daily budget ($)", text: $daily)
                    amountField("Monthly budget ($)", text: $monthly)
                }.disabled(!canChange)
                amountField("Maximum requests per day", text: $requests).disabled(!canChange)
                }
                if !status.supportsCredentials {
                    Text("Update Relay on this host to manage its saved accounts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.accounts == nil && settings.providers.contains(where: { $0 != "anthropic_api" }) { DisclosureGroup("Saved login options") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Codex model", text: optionalString(\.codexModel))
                        TextField("Claude CLI path (optional)", text: optionalString(\.claudePath))
                        TextField("Codex CLI path (optional)", text: optionalString(\.codexPath))
                        Text("CLI paths are absolute paths on this host. Existing saved logins stay with the CLI.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.textFieldStyle(.roundedBorder).disabled(!canChange)
                }
                }
                if let usage = status.requestsToday {
                    Text("Today: \(usage) requests · $\(RelayHostRotationTextRPC.dollars(status.chargedTodayMicrousd ?? 0)) charged")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("This month: $\(RelayHostRotationTextRPC.dollars(status.chargedMonthMicrousd ?? 0)) charged")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.providers.contains("anthropic_api") {
                    Text("Haiku API uses the selected account's securely stored key. Each API request reserves $1 until its outcome is known. Host limits also cap all accounts; other hosts and applications have separate usage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let unresolved = status.unresolved, !unresolved.isEmpty {
                    Text("Earlier requests need review before more text can be generated.")
                        .font(.caption).foregroundStyle(.orange)
                    ForEach(unresolved, id: \.self) { id in
                        HStack {
                            Text(id).font(.caption.monospaced()).textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Acknowledge") { acknowledgeID = id; confirmAcknowledgement = true }
                                .disabled(!canChange)
                        }
                    }
                }
                if let validationMessage {
                    Text(validationMessage).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Reload saved settings") { Task { await refresh() } }.disabled(busy)
                        .accessibilityIdentifier("relay.context-management.text-refresh")
                    Spacer()
                    Button("Save changes") { Task { await save() } }
                        .disabled(!canChange || validationMessage != nil || pendingSettings == status.settings)
                        .accessibilityIdentifier("relay.context-management.text-save")
                }
            } else if status?.isUnsupported == true {
                Text("Update this host's Relay helper to configure handoff text.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Read text status") { Task { await refresh() } }.disabled(busy)
            } else if !busy {
                Button("Read text status") { Task { await refresh() } }
            }
            if let savedMessage {
                Label(savedMessage, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    .accessibilityIdentifier("relay.context-management.account-saved")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("relay.context-management.text-error")
            }
        }
        .task { await refresh(); await refreshCredentials() }
        .onChange(of: service.profile) { _, _ in
            observedProfile = nil; status = nil; settings = .init(); credentials = []; savedMessage = nil
            editingAccount = nil; recoveringReference = nil
            Task { await refresh(); await refreshCredentials() }
        }
        .sheet(item: $editingAccount, onDismiss: {
            recoveringReference = nil
            Task { await refreshCredentials() }
        }) { account in
            let profile = service.profile
            let original = status?.settings?.accounts?.first(where: { $0.id == account.id })
            RelayHostRotationAccountEditor(service: service, account: account, recoveringReference: recoveringReference,
                onSave: { value in try await persistAccount(value, original: original, profile: profile) },
                onConfirmed: { result in
                    accept(result); savedMessage = "Account saved on " + hostName + "."
                    editingAccount = nil
                },
                onCancel: { editingAccount = nil })
        }
        .confirmationDialog("Acknowledge the unknown request outcome?", isPresented: $confirmAcknowledgement, titleVisibility: .visible) {
            Button("Acknowledge and keep the charge") {
                if let id = acknowledgeID { Task { await acknowledge(id) } }
            }
            Button("Cancel", role: .cancel) { acknowledgeID = nil }
        } message: {
            Text("Confirm that the original request has stopped before acknowledging it. Its reserved usage remains charged, and the request will not be retried.")
        }
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 6) {
            if (settings.accounts ?? []).isEmpty {
                Text("No account has been saved on " + hostName + ". Add an account below, or finish setup with a saved key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array((settings.accounts ?? []).enumerated()), id: \.element.id) { index, account in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name).font(.caption.weight(.medium))
                        Text(RelayHostRotationTextRPC.providerName(account.provider) + (account.enabled ? " · In use" : " · Saved, off"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let reference = account.credentialReference {
                            Text(credentials.contains(where: { $0.reference == reference && $0.state == "saved" }) ? "Key stored securely" : "Check stored key status")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let usage = status?.accountUsage?.first(where: { $0.accountID == account.id }) {
                            Text("\(usage.requestsToday) requests today · $\(RelayHostRotationTextRPC.dollars(usage.chargedTodayMicrousd)) charged")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Edit") { recoveringReference = nil; editingAccount = account }
                    Button {
                        settings.accounts?.swapAt(index, index-1)
                    } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move account earlier")
                    Button {
                        settings.accounts?.remove(at: index)
                    } label: { Image(systemName: "minus.circle") }
                        .disabled(account.credentialReference != nil)
                        .help("Remove its key in the account editor before removing this profile")
                }
            }
            Menu("Add account") {
                ForEach(RelayHostRotationTextRPC.providers, id: \.self) { provider in
                    Button(RelayHostRotationTextRPC.providerName(provider)) {
                        var account = newAccount(provider: provider)
                        let number = (settings.accounts ?? []).filter { $0.provider == provider }.count + 1
                        account.name = RelayHostRotationTextRPC.providerName(provider) + " \(number)"
                        if provider == "codex_account" { account.model = "gpt-6.1-sol" }
                        if provider == "claude_account" { account.model = "claude-haiku-5-5" }
                        recoveringReference = nil; editingAccount = account
                    }
                }
            }.disabled((settings.accounts?.count ?? 0) >= 12)
            storedKeys
            Text("Accounts are checked in this order within each provider. A request keeps the account selected before submission.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func newAccount(provider: String) -> RelayHostRotationTextRPC.Account {
        var account = RelayHostRotationTextRPC.Account()
        account.provider = provider
        account.dailyLimitMicrousd = 1_000_000
        account.monthlyLimitMicrousd = 5_000_000
        account.maxRequestsPerDay = 10
        if provider == "anthropic_api" { account.billingGroup = "anthropic" }
        return account
    }
    @MainActor private func persistAccount(_ account: RelayHostRotationTextRPC.Account,
        original: RelayHostRotationTextRPC.Account?, profile: ConnectionProfile) async throws {
        guard canChange, service.profile == profile else { throw RelayHostRotationRPC.Failure.changedConnection }
        busy = true; error = nil; savedMessage = nil
        defer { busy = false }
        do {
            let current = try await service.readHostRotationTextStatus()
            guard service.profile == profile, current.supportsCredentials else { throw RelayHostRotationRPC.Failure.changedConnection }
            let value = try (current.settings ?? .init()).mergingAccount(account, replacing: original)
            let result = try await service.configureHostRotationText(value, expectedConfigurationID: current.configurationID ?? "")
            guard service.profile == profile else { throw RelayHostRotationRPC.Failure.changedConnection }
            accept(result)
            savedMessage = "Account saved on " + hostName + "."
            editingAccount = nil
            await refreshCredentials()
        } catch {
            needsStatus = true
            self.error = error.localizedDescription
            throw error
        }
    }

    private var keysToReview: [RelayHostRotationTextRPC.CredentialRecord] {
        let selected = Set((settings.accounts ?? []).compactMap(\.credentialReference))
        return credentials.filter { !selected.contains($0.reference) }
    }
    private var storedKeys: some View {
        DisclosureGroup("Saved keys not linked to an account (\(keysToReview.count))", isExpanded: $showStoredKeys) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your keys are already stored securely. Finish setup to link one to an account; you do not need to paste it again. Previous keys are retained until you remove them.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(keysToReview) { record in
                    let profile = settings.accounts?.first(where: { $0.id == record.accountID })
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.map { "Previous key for " + $0.name } ?? "Unfinished API account")
                                .font(.caption)
                            Text("Key \(record.reference.prefix(8)) · \(record.stateLabel)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Finish setup") {
                            var account = profile ?? newAccount(provider: "anthropic_api")
                            account.id = record.accountID
                            if profile == nil { account.name = "Recovered API account" }
                            recoveringReference = record.reference
                            editingAccount = account
                        }.disabled(!canChange || profile == nil && (settings.accounts?.count ?? 0) >= 12)
                    }
                }
                if let credentialError { Text(credentialError).font(.caption).foregroundStyle(.red) }
                Button("Read saved keys") { Task { await refreshCredentials() } }
                    .disabled(credentialsBusy)
            }.padding(.top, 6)
        }
        .accessibilityIdentifier("relay.context-management.stored-keys")
    }
    @MainActor private func refreshCredentials() async {
        guard !credentialsBusy else { return }
        credentialsBusy = true; credentialError = nil
        defer { credentialsBusy = false }
        let profile = service.profile
        do {
            let result = try await service.readHostRotationCredentials()
            guard service.profile == profile else { throw RelayHostRotationRPC.Failure.changedConnection }
            credentials = result
            if (settings.accounts ?? []).isEmpty && !result.isEmpty { showStoredKeys = true }
        } catch { credentials = []; credentialError = error.localizedDescription }
    }

    private var providerOrder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Providers, in order").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(settings.providers.enumerated()), id: \.element) { index, provider in
                HStack(spacing: 8) {
                    Text(RelayHostRotationTextRPC.providerName(provider)).font(.caption)
                    Spacer()
                    Button { settings.providers.swapAt(index, index-1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).help("Move earlier")
                    Button { settings.providers.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .disabled(settings.providers.count == 1).help("Remove provider")
                }
            }
            Menu("Add provider") {
                ForEach(RelayHostRotationTextRPC.providers.filter { !settings.providers.contains($0) }, id: \.self) { provider in
                    Button(RelayHostRotationTextRPC.providerName(provider)) { settings.providers.append(provider) }
                }
            }.disabled(settings.providers.count == 3)
            Text("The next provider is tried only if the previous one is unavailable before submission.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func amountField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder)
        }
    }
    private func optionalString(_ key: WritableKeyPath<RelayHostRotationTextRPC.Settings, String?>) -> Binding<String> {
        Binding(get: { settings[keyPath: key] ?? "" },
                set: { settings[keyPath: key] = $0.isEmpty ? nil : $0 })
    }
    @MainActor private func accept(_ result: RelayHostRotationTextRPC.Status) {
        status = result; needsStatus = false; error = nil
        settings = result.settings ?? .init()
        daily = RelayHostRotationTextRPC.dollars(settings.dailyLimitMicrousd)
        monthly = RelayHostRotationTextRPC.dollars(settings.monthlyLimitMicrousd)
        requests = String(settings.maxRequestsPerDay)
    }
    @MainActor private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let profile = service.profile
        do {
            let result = try await service.readHostRotationTextStatus()
            guard service.profile == profile else { throw RelayHostRotationRPC.Failure.changedConnection }
            observedProfile = profile; accept(result)
        }
        catch { status = nil; self.error = error.localizedDescription }
    }
    @MainActor private func save() async {
        guard canChange, let value = pendingSettings, validationMessage == nil else { return }
        busy = true; error = nil; savedMessage = nil
        defer { busy = false }
        do {
            accept(try await service.configureHostRotationText(value, expectedConfigurationID: status?.configurationID ?? ""))
            savedMessage = "Changes saved on " + hostName + "."
        }
        catch { needsStatus = true; self.error = error.localizedDescription }
    }
    @MainActor private func acknowledge(_ operationID: String) async {
        guard canChange else { return }
        busy = true; error = nil
        defer { busy = false; acknowledgeID = nil }
        do { accept(try await service.abandonHostRotationText(operationID: operationID)) }
        catch { needsStatus = true; self.error = error.localizedDescription }
    }
}
