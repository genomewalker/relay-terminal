import Foundation

/// Account configuration belongs to the authenticated execution host.
/// A Settings view can use this service without a tab, pane or input lease.
struct RelayHostAccountsService: Sendable {
    let profile: ConnectionProfile
    var hostName: String { profile.kind == .local ? "This Mac" : profile.host }
    var canManageAccounts: Bool { profile.backend == .relay && (profile.kind == .local || !profile.host.isEmpty) }

    @MainActor func readHostRotationTextStatus() async throws -> RelayHostRotationTextRPC.Status {
        let request = RelayHostRotationTextRPC.Request(operation: .status)
        return try RelayHostRotationTextRPC.decode(
            await RelayHostRotationTextRPC.sendHost(request, profile: profile), request: request)
    }
    @MainActor func configureHostRotationText(_ settings: RelayHostRotationTextRPC.Settings, expectedConfigurationID: String) async throws -> RelayHostRotationTextRPC.Status {
        let request = RelayHostRotationTextRPC.Request(operation: .configure,
            id: RelayHostRotationRPC.newOperationID(), settings: settings)
        return try RelayHostRotationTextRPC.decode(
            await RelayHostRotationTextRPC.sendHost(request, profile: profile, expectedConfigurationID: expectedConfigurationID), request: request)
    }
    @MainActor func abandonHostRotationText(operationID: String) async throws -> RelayHostRotationTextRPC.Status {
        let request = RelayHostRotationTextRPC.Request(operation: .abandon, operationID: operationID)
        let data = try await RelayHostRotationTextRPC.sendHost(request, profile: profile)
        try RelayHostRotationTextRPC.decodeAbandon(data, operationID: operationID)
        return try await readHostRotationTextStatus()
    }
    @MainActor func saveHostRotationCredential(reference: String, accountID: String, secret: String) async throws -> RelayHostRotationTextRPC.CredentialReceipt {
        let request = RelayHostRotationTextRPC.Request(operation: .credentialSave,
            credentialReference: reference, credentialSecret: secret, credentialAccountID: accountID)
        return try RelayHostRotationTextRPC.decodeCredential(
            await RelayHostRotationTextRPC.sendHost(request, profile: profile), reference: reference)
    }
    @MainActor func deleteHostRotationCredential(reference: String) async throws -> RelayHostRotationTextRPC.CredentialReceipt {
        let request = RelayHostRotationTextRPC.Request(operation: .credentialDelete, credentialReference: reference)
        return try RelayHostRotationTextRPC.decodeCredential(
            await RelayHostRotationTextRPC.sendHost(request, profile: profile), reference: reference)
    }
    @MainActor func readHostRotationCredential(reference: String) async throws -> RelayHostRotationTextRPC.CredentialReceipt {
        let request = RelayHostRotationTextRPC.Request(operation: .credentialStatus, credentialReference: reference)
        return try RelayHostRotationTextRPC.decodeCredential(
            await RelayHostRotationTextRPC.sendHost(request, profile: profile), reference: reference)
    }
    @MainActor func readHostRotationCredentials() async throws -> [RelayHostRotationTextRPC.CredentialRecord] {
        let request = RelayHostRotationTextRPC.Request(operation: .credentialList)
        return try RelayHostRotationTextRPC.decodeCredentials(
            await RelayHostRotationTextRPC.sendHost(request, profile: profile))
    }
}
