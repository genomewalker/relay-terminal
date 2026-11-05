import Foundation
import Testing
@testable import Relay

@MainActor private final class SharingFixtureIO: RelayHostAccountSharingIO {
    enum SaveFault: Equatable { case none, beforeCommit, afterCommit }
    var source = SharingFixtureIO.settings(apiReference: String(repeating: "a", count: 32))
    var sourceID = String(repeating: "1", count: 32)
    var destination = SharingFixtureIO.remoteSettings()
    var destinationID = String(repeating: "2", count: 32)
    var saved: [String: String] = [:]
    var saveFault = SaveFault.none
    var mutateSourceOnRead = false
    var afterSave: (() async -> Void)?
    var vaultSupport = false
    var vaultUnlocks = 0
    var reads = 0, secretReads = 0, saves = 0, configurations = 0
    var destinations: [String] = []
    static let secret = "FIXTURE_ONLY_NOT_A_REAL_API_KEY_123456789"

    static func settings(apiReference: String) -> RelayHostRotationTextRPC.Settings {
        var account = RelayHostRotationTextRPC.Account()
        account.id = String(repeating: "3", count: 32); account.name = "Shared API"
        account.enabled = true; account.credentialReference = apiReference; account.billingGroup = "fixture"
        account.dailyLimitMicrousd = 3_000_000; account.monthlyLimitMicrousd = 20_000_000; account.maxRequestsPerDay = 40
        var result = RelayHostRotationTextRPC.Settings()
        result.enabled = true; result.accounts = [account]; result.providers = ["anthropic_api", "claude_account"]
        result.dailyLimitMicrousd = 6_000_000; result.monthlyLimitMicrousd = 40_000_000; result.maxRequestsPerDay = 70
        result.claudePath = "/local-only/bin/claude"
        return result
    }
    static func remoteSettings() -> RelayHostRotationTextRPC.Settings {
        var account = RelayHostRotationTextRPC.Account()
        account.id = String(repeating: "4", count: 32); account.name = "Remote CLI"
        account.provider = "claude_account"; account.enabled = true
        account.authDirectory = "/home/remote/.claude"; account.model = "claude-haiku-5-5"; account.maxRequestsPerDay = 20
        var result = RelayHostRotationTextRPC.Settings()
        result.enabled = true; result.providers = ["claude_account"]; result.accounts = [account]
        result.claudePath = "/remote/bin/claude"; result.maxRequestsPerDay = 20
        return result
    }
    func status(_ profile: ConnectionProfile) async throws -> RelayHostRotationTextRPC.Status {
        reads += 1
        var value = try Self.status(settings: profile.kind == .local ? source : destination,
                                    id: profile.kind == .local ? sourceID : destinationID)
        if profile.kind != .local && vaultSupport { value.vaultUnlockSupport = "gnome_secret_service_v1" }
        return value
    }
    static func status(settings: RelayHostRotationTextRPC.Settings, id: String) throws -> RelayHostRotationTextRPC.Status {
        let settingsObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        let object: [String: Any] = ["v": 1, "status": "ready", "configuration_id": id,
            "credential_support": "v1", "settings": settingsObject, "day": "2026-10-14", "month": "2026-10",
            "requests_today": 0, "charged_today_microusd": 0, "charged_month_microusd": 0, "unresolved": []]
        return try JSONDecoder().decode(RelayHostRotationTextRPC.Status.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func credentials(_ profile: ConnectionProfile) async throws -> [RelayHostRotationTextRPC.CredentialRecord] {
        saved.map { .init(reference: $0.key, accountID: $0.value, state: "saved") }
    }
    func credential(_ reference: String, on profile: ConnectionProfile) async throws -> RelayHostRotationTextRPC.CredentialReceipt {
        guard saved[reference] != nil else { throw RelayHostAccountSharingError.vaultLocked }
        return try JSONDecoder().decode(RelayHostRotationTextRPC.CredentialReceipt.self, from:
            JSONSerialization.data(withJSONObject: ["v": 1, "status": "saved", "reference": reference, "storage": "linux_secret_service"]))
    }
    func localSecret(_ reference: String) async throws -> String {
        secretReads += 1
        if mutateSourceOnRead { sourceID = String(repeating: "9", count: 32) }
        return Self.secret
    }
    func unlockVault(_ secret: String, on profile: ConnectionProfile) async throws {
        #expect(secret == Self.secret)
        vaultUnlocks += 1
    }
    func save(_ secret: String, reference: String, accountID: String, on profile: ConnectionProfile) async throws {
        #expect(secret == Self.secret)
        saves += 1; destinations.append(profile.connectionKey)
        if saveFault == .beforeCommit { throw RelayHostAccountSharingError.unavailable }
        saved[reference] = accountID
        if let afterSave { await afterSave() }
        if saveFault == .afterCommit { throw RelayHostAccountSharingError.unavailable }
    }
    func configure(_ settings: RelayHostRotationTextRPC.Settings, operationID: String,
                   expected: String, on profile: ConnectionProfile) async throws -> RelayHostRotationTextRPC.Status {
        #expect(expected == destinationID)
        configurations += 1; destination = settings; destinationID = operationID
        return try Self.status(settings: settings, id: operationID)
    }
}

@Suite(.serialized) @MainActor struct RelayHostAccountSharingTests {
    private func fixture() throws -> (URL, RelayHostAccountSharingStore, SharingFixtureIO, RelayHostAccountSharing, ConnectionProfile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-sharing-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = RelayHostAccountSharingStore(url: root.appendingPathComponent("private/hosts.json"))
        let io = SharingFixtureIO()
        let manager = RelayHostAccountSharing(store: store, io: io)
        let profile = ConnectionProfile(name: "Exact remote", kind: .ssh, host: "authorized.example", user: "alice")
        return (root, store, io, manager, profile)
    }

    @Test func disabledOrLocalDestinationsDoNotReadSecrets() async throws {
        let (root, _, io, manager, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await manager.synchronize(profile)
        await manager.setEnabled(true, for: .local)
        #expect(io.reads == 0 && io.secretReads == 0 && io.saves == 0)
    }

    @Test func nativeSharingPreservesRemoteLoginsAndDoesNotRepeatSaves() async throws {
        let (root, store, io, manager, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await manager.setEnabled(true, for: profile)
        #expect(manager.status(profile).phase == .synchronized)
        #expect(io.saves == 1 && io.configurations == 1)
        #expect(io.destinations == [profile.connectionKey])
        let api = try #require(io.destination.accounts?.first { $0.provider == "anthropic_api" })
        #expect(api.credentialReference != io.source.accounts?.first?.credentialReference)
        #expect(io.destination.accounts?.first { $0.provider == "claude_account" }?.authDirectory == "/home/remote/.claude")
        #expect(io.destination.claudePath == "/remote/bin/claude")
        #expect(io.destination.dailyLimitMicrousd == io.source.dailyLimitMicrousd)
        #expect(io.destination.maxRequestsPerDay == io.source.maxRequestsPerDay)
        let metadata = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!metadata.contains(SharingFixtureIO.secret))
        await manager.synchronize(profile)
        #expect(io.saves == 1 && io.configurations == 1 && io.secretReads == 1)
    }

    @Test func lostSaveReplyRecoversByReadbackAcrossManagerRestart() async throws {
        let (root, store, io, manager, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        io.saveFault = .afterCommit
        await manager.setEnabled(true, for: profile)
        #expect(io.saves == 1 && io.configurations == 0)
        #expect(try store.read().hosts.first?.bindings.first?.phase == .submitted)
        let recovered = RelayHostAccountSharing(store: store, io: io)
        await recovered.synchronize(profile)
        #expect(recovered.status(profile).phase == .synchronized)
        #expect(io.saves == 1 && io.configurations == 1)
    }

    @Test func uncertainUncommittedSaveIsNeverResent() async throws {
        let (root, store, io, manager, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        io.saveFault = .beforeCommit
        await manager.setEnabled(true, for: profile)
        let reference = try store.read().hosts.first?.bindings.first?.destinationReference
        let recovered = RelayHostAccountSharing(store: store, io: io)
        await recovered.synchronize(profile)
        #expect(recovered.status(profile).phase == .needsReview)
        #expect(io.saves == 1 && io.configurations == 0)
        #expect(try store.read().hosts.first?.bindings.first?.destinationReference == reference)
    }

    @Test func changedSourceIsNotExportedFromAnOldSnapshot() async throws {
        let (root, _, io, manager, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        io.mutateSourceOnRead = true
        await manager.setEnabled(true, for: profile)
        #expect(manager.status(profile).phase == .needsReview)
        #expect(io.secretReads == 1 && io.saves == 0 && io.configurations == 0)
    }

    @Test func revocationDuringAnInFlightSaveStaysDisabled() async throws {
        let (root, store, io, manager, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        io.afterSave = { await manager.setEnabled(false, for: profile) }
        await manager.setEnabled(true, for: profile)
        #expect(!manager.isEnabled(profile))
        #expect(manager.status(profile).phase == .disabled)
        #expect(io.saves == 1 && io.configurations == 0)
        #expect(try store.read().hosts.first?.enabled == false)
    }

    @Test func competingStoreWriterBlocksBeforeAnySecretRead() async throws {
        let (root, store, io, manager, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.write([], expectedRevision: 0)
        await manager.setEnabled(true, for: profile)
        #expect(!manager.storeAvailable)
        #expect(io.secretReads == 0 && io.saves == 0)
    }

    @Test func changedSourceCredentialGetsANewImmutableDestinationReference() async throws {
        let (root, _, io, manager, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await manager.setEnabled(true, for: profile)
        let first = io.destination.accounts?.first { $0.provider == "anthropic_api" }?.credentialReference
        io.source.accounts?[0].credentialReference = String(repeating: "b", count: 32)
        io.sourceID = String(repeating: "8", count: 32)
        await manager.synchronize(profile)
        let second = io.destination.accounts?.first { $0.provider == "anthropic_api" }?.credentialReference
        #expect(first != second)
        #expect(io.saves == 2 && io.configurations == 2 && io.saved.count == 2)
    }

    @Test func unsafeMetadataFileCannotAuthorizeSharing() throws {
        let (root, store, _, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.write([], expectedRevision: 0)
        let target = root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: store.url, to: target)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: target)
        #expect(throws: (any Error).self) { try store.read() }
    }

    @Test func linkedVaultUnlocksOnReconnectWithoutAnotherCredentialSave() async throws {
        let (root, store, io, _, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = RelayHostAccountSharingPolicy(connectionKey: profile.connectionKey, enabled: true)
        policy.vaultUnlockReference = String(repeating: "c", count: 32)
        _ = try store.write([policy], expectedRevision: 0)
        io.vaultSupport = true
        let linked = RelayHostAccountSharing(store: store, io: io)
        await linked.synchronize(profile)
        await linked.synchronize(profile)
        #expect(linked.status(profile).phase == .synchronized)
        #expect(io.vaultUnlocks == 2 && io.saves == 1 && io.configurations == 1)
        #expect(!(try String(contentsOf: store.url, encoding: .utf8)).contains(SharingFixtureIO.secret))
    }

    @Test func oldHostDoesNotReceiveAnUnlockSecret() async throws {
        let (root, store, io, _, profile) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = RelayHostAccountSharingPolicy(connectionKey: profile.connectionKey, enabled: true)
        policy.vaultUnlockReference = String(repeating: "c", count: 32)
        _ = try store.write([policy], expectedRevision: 0)
        let linked = RelayHostAccountSharing(store: store, io: io)
        await linked.synchronize(profile)
        #expect(linked.status(profile).phase == .needsReview)
        #expect(io.secretReads == 0 && io.vaultUnlocks == 0 && io.saves == 0)
    }

    @Test func vaultUnlockRequestHasNoPaneAccountOrSettingsAuthority() throws {
        let value = RelayHostRotationTextRPC.Request(operation: .vaultUnlock, credentialSecret: SharingFixtureIO.secret)
        #expect(value.valid)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(Set(object.keys) == Set(["v", "operation", "credential_secret"]))
        var invalid = value
        invalid.credentialReference = String(repeating: "d", count: 32)
        #expect(!invalid.valid)
        invalid = value; invalid.credentialAccountID = String(repeating: "e", count: 32)
        #expect(!invalid.valid)
        invalid = value; invalid.credentialSecret = "contains a space in the secret"
        #expect(!invalid.valid)
    }
}
