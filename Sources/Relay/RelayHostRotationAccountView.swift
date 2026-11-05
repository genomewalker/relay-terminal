import SwiftUI

struct RelayHostRotationAccountEditor: View {
    private let service: RelayHostAccountsService
    @State private var account: RelayHostRotationTextRPC.Account
    @State private var daily: String
    @State private var monthly: String
    @State private var requests: String
    @State private var secret = ""
    @State private var pendingReference: String?
    @State private var unconfirmedAccount: RelayHostRotationTextRPC.Account?
    @State private var busy = false
    @State private var progress = ""
    @State private var error: String?
    @State private var credentialStatus: String?
    @State private var confirmDelete = false
    private let targetProfile: ConnectionProfile
    private let onSave: @MainActor (RelayHostRotationTextRPC.Account) async throws -> Void
    private let onConfirmed: @MainActor (RelayHostRotationTextRPC.Status) -> Void
    private let onCancel: () -> Void

    init(service: RelayHostAccountsService, account: RelayHostRotationTextRPC.Account, recoveringReference: String? = nil,
         onSave: @escaping @MainActor (RelayHostRotationTextRPC.Account) async throws -> Void,
         onConfirmed: @escaping @MainActor (RelayHostRotationTextRPC.Status) -> Void,
         onCancel: @escaping () -> Void) {
        self.service = service; targetProfile = service.profile
        _account = State(initialValue: account)
        _pendingReference = State(initialValue: recoveringReference)
        _daily = State(initialValue: RelayHostRotationTextRPC.dollars(account.dailyLimitMicrousd))
        _monthly = State(initialValue: RelayHostRotationTextRPC.dollars(account.monthlyLimitMicrousd))
        _requests = State(initialValue: String(account.maxRequestsPerDay))
        self.onSave = onSave; self.onConfirmed = onConfirmed; self.onCancel = onCancel
    }
    private var hostName: String { targetProfile.kind == .local ? "This Mac" : targetProfile.host }
    private var draftAccount: RelayHostRotationTextRPC.Account? {
        guard let day = RelayHostRotationTextRPC.parseDollars(daily),
              let month = RelayHostRotationTextRPC.parseDollars(monthly),
              requests.range(of: #"^[0-9]{1,5}$"#, options: .regularExpression) != nil,
              let count = Int(requests) else { return nil }
        var value = account
        value.dailyLimitMicrousd = day; value.monthlyLimitMicrousd = month; value.maxRequestsPerDay = count
        return value
    }
    private var canAct: Bool {
        !busy && service.canManageAccounts
    }
    private var validKey: Bool {
        (16...512).contains(secret.utf8.count) && secret.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }
    private var validationMessage: String? {
        guard let value = draftAccount else { return "Enter valid spending limits and a daily request limit from 0 to 10,000." }
        if value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter an account name." }
        if account.provider == "anthropic_api" {
            if !secret.isEmpty && !validKey { return "Paste the complete API key without spaces." }
            if account.credentialReference == nil && !validKey && pendingReference == nil { return "Paste an API key, or finish setup with an already saved key." }
            if value.enabled && (value.dailyLimitMicrousd < 1_000_000 || value.monthlyLimitMicrousd < 1_000_000) {
                return "An account in use needs daily and monthly limits of at least $1."
            }
        }
        // A placeholder is used only to validate the form before secure storage.
        // It can never be sent: saveAccount revalidates the actual saved reference.
        var validated = value
        if account.provider == "anthropic_api" && validKey && validated.credentialReference == nil {
            validated.credentialReference = account.id
        }
        return validated.valid ? nil : "Complete the account name, limits and login settings. API accounts can use 0 for no daily request cap; saved CLI accounts need a positive cap."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Save " + RelayHostRotationTextRPC.providerName(account.provider) + " account").font(.headline)
                    Text("Saved on " + hostName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            field("Account name", text: $account.name)
            if account.provider == "anthropic_api" {
                VStack(alignment: .leading, spacing: 6) {
                    Text(account.credentialReference == nil ? "API key" : "Replace API key (optional)").font(.caption).foregroundStyle(.secondary)
                    SecureField(account.credentialReference == nil ? "Paste your Claude API key" : "Leave blank to keep the stored key", text: $secret)
                        .accessibilityIdentifier("relay.context-management.account-api-key")
                    if let credentialStatus {
                        Label(credentialStatus, systemImage: account.credentialReference == nil ? "key" : "checkmark.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if account.credentialReference != nil {
                        Label("A stored key is linked to this account.", systemImage: "key.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(targetProfile.kind == .local ? "Save account stores the key in macOS Keychain." :
                        "Save account stores the key in this host's unlocked Secret Service keyring.")
                        .font(.caption).foregroundStyle(.secondary)
                    if pendingReference != nil {
                        Text("A key save needs confirmation. Check its status before saving again.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Check key status") { Task { await checkKey() } }.disabled(!canAct)
                    }
                }
            } else {
                field("Saved login directory on " + hostName, text: optional(\.authDirectory))
                field("Model", text: optional(\.model))
                Text("The official CLI manages this saved login. Relay does not change your CLI login.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Use this account for handoff text", isOn: $account.enabled)
            Text("Saving an account makes no API request. Handoff generation also needs to be enabled for this host.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                field("Daily spending limit ($)", text: $daily)
                field("Monthly spending limit ($)", text: $monthly)
            }
            DisclosureGroup("Advanced account options") {
                VStack(alignment: .leading, spacing: 8) {
                    field("Daily request cap", text: $requests)
                    Text(account.provider == "anthropic_api"
                         ? "0 disables the daily request cap. Spending budgets and rate limits still apply."
                         : "Saved CLI accounts require a positive daily request cap when enabled.")
                        .font(.caption).foregroundStyle(.secondary)
                    if account.provider == "anthropic_api" {
                        field("Shared organization budget group", text: optional(\.billingGroup))
                        Text("Use the same group for keys in one organization. This host combines their tracked usage.")
                            .font(.caption).foregroundStyle(.secondary)
                        if account.credentialReference != nil || pendingReference != nil {
                            HStack {
                                Button("Check key status") { Task { await checkKey() } }.disabled(!canAct)
                                Button("Remove stored key", role: .destructive) { confirmDelete = true }.disabled(!canAct)
                            }
                        }
                    } else {
                        field("CLI path on this host (optional)", text: optional(\.cliPath))
                    }
                }.padding(.top, 6)
            }
            if busy { Text(progress).font(.caption).foregroundStyle(.secondary) }
            if let message = validationMessage, !busy {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if unconfirmedAccount != nil {
                Button("Check saved account") { Task { await checkSavedAccount() } }.disabled(!canAct)
            }
            HStack {
                Button("Cancel") { secret = ""; onCancel() }.disabled(busy)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save account") { Task { await saveAccount() } }
                    .disabled(!canAct || validationMessage != nil || pendingReference != nil || unconfirmedAccount != nil)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("relay.context-management.account-save")
            }
        }
        .textFieldStyle(.roundedBorder).padding(22).frame(width: 540)
        .foregroundStyle(RelayTheme.text).background(RelayTheme.sidebar).relaySurface()
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .onDisappear { secret = "" }
        .task { if pendingReference != nil { await checkKey() } }
        .confirmationDialog("Remove this account's stored key?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove stored key", role: .destructive) { Task { await deleteKey() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The exact key is removed from this host. Save account to apply the disabled profile.")
        }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
        }
    }
    private func optional(_ key: WritableKeyPath<RelayHostRotationTextRPC.Account, String?>) -> Binding<String> {
        Binding(get: { account[keyPath: key] ?? "" },
                set: { account[keyPath: key] = $0.isEmpty ? nil : $0 })
    }
    @MainActor private func saveAccount() async {
        guard canAct, validationMessage == nil, pendingReference == nil, unconfirmedAccount == nil else { return }
        if account.provider == "anthropic_api" && !secret.isEmpty {
            await storeKey()
            guard pendingReference == nil, account.credentialReference != nil, error == nil else { return }
        }
        guard canAct, let value = draftAccount, value.valid,
              value.provider != "anthropic_api" || value.credentialReference != nil else { return }
        busy = true; progress = "Saving account on " + hostName + "…"; error = nil
        defer { secret = ""; busy = false }
        do { try await onSave(value) }
        catch {
            unconfirmedAccount = value
            self.error = "Account save is not confirmed. Your stored key is retained. Check the saved account before another save. " + error.localizedDescription
        }
    }
    @MainActor private func storeKey() async {
        guard canAct, validKey, pendingReference == nil else { return }
        let reference = RelayHostRotationRPC.newOperationID()
        pendingReference = reference; busy = true; progress = "Storing key securely…"; error = nil
        defer { secret = ""; busy = false }
        do {
            let result = try await service.saveHostRotationCredential(reference: reference, accountID: account.id, secret: secret)
            guard result.status == "saved" else { throw RelayHostRotationRPC.Failure.invalidResponse }
            account.credentialReference = reference; pendingReference = nil
            credentialStatus = "Key stored securely."
        } catch {
            self.error = "Key save is not confirmed. Check this key's status before another save. " + error.localizedDescription
        }
    }
    @MainActor private func checkSavedAccount() async {
        guard canAct, let expected = unconfirmedAccount else { return }
        busy = true; progress = "Checking saved account…"; error = nil
        defer { busy = false }
        do {
            let result = try await service.readHostRotationTextStatus()
            guard service.profile == targetProfile else { throw RelayHostRotationRPC.Failure.changedConnection }
            guard result.settings?.accounts?.first(where: { $0.id == expected.id }) == expected else {
                self.error = "The account is not confirmed as saved. The key is retained. Cancel and reload the host's saved accounts before editing again."
                return
            }
            unconfirmedAccount = nil
            onConfirmed(result)
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func checkKey() async {
        guard canAct, let reference = pendingReference ?? account.credentialReference else { return }
        busy = true; progress = "Checking key status…"; error = nil; defer { busy = false }
        do {
            let result = try await service.readHostRotationCredential(reference: reference)
            if result.status == "saved" {
                account.credentialReference = reference; pendingReference = nil
                credentialStatus = "Key stored securely."
            } else if result.status == "missing" {
                if account.credentialReference == reference { account.credentialReference = nil; account.enabled = false }
                pendingReference = nil; credentialStatus = "No key is stored for this account."
            } else { credentialStatus = "The key is unavailable. Unlock this host's keyring and check again." }
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func deleteKey() async {
        guard canAct, let reference = pendingReference ?? account.credentialReference else { return }
        busy = true; progress = "Removing stored key…"; error = nil
        defer { secret = ""; busy = false }
        do {
            let result = try await service.deleteHostRotationCredential(reference: reference)
            guard result.status == "deleted" else { throw RelayHostRotationRPC.Failure.invalidResponse }
            if account.credentialReference == reference { account.credentialReference = nil; account.enabled = false }
            pendingReference = nil; credentialStatus = "Key removed."
        } catch { self.error = "Removal is not confirmed. Check key status. " + error.localizedDescription }
    }
}
