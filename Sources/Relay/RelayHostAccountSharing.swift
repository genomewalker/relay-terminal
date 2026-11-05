import Foundation
import Combine
import CryptoKit
import Darwin

/// Only API-account metadata and immutable vault references are persisted here.
/// The destination is the exact authorized host connection, never the active pane.
struct RelaySharedAccountBinding: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case prepared, submitted, saved }
    var accountID: String
    var sourceReference: String
    var destinationReference: String
    var phase: Phase
    var valid: Bool {
        [accountID, sourceReference, destinationReference].allSatisfy(RelayHostRotationRPC.validOperationID)
    }
}

struct RelayHostAccountSharingPolicy: Codable, Equatable, Sendable {
    struct PendingConfiguration: Codable, Equatable, Sendable {
        let operationID: String
        let settingsDigest: String
    }
    let connectionKey: String
    var enabled: Bool
    var bindings: [RelaySharedAccountBinding] = []
    var managedAccountIDs: [String] = []
    var pendingConfiguration: PendingConfiguration?
    var vaultUnlockReference: String?
    var valid: Bool {
        !connectionKey.isEmpty && connectionKey.utf8.count <= 1024 && bindings.count <= 12 &&
        bindings.allSatisfy(\.valid) && Set(bindings.map(\.accountID)).count == bindings.count &&
        managedAccountIDs.count <= 12 && managedAccountIDs.allSatisfy(RelayHostRotationRPC.validOperationID) &&
        Set(managedAccountIDs).count == managedAccountIDs.count &&
        (vaultUnlockReference.map(RelayHostRotationRPC.validOperationID) ?? true) &&
        (pendingConfiguration.map { RelayHostRotationRPC.validOperationID($0.operationID) &&
            $0.settingsDigest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil } ?? true)
    }
}

enum RelayHostAccountSharingError: LocalizedError {
    case unavailable, noLocalAPIAccount, vaultLocked, outcomeUnknown, sourceChanged, persistence, invalidAccount
    var errorDescription: String? {
        switch self {
        case .unavailable: "Account sharing is unavailable on this connection."
        case .noLocalAPIAccount: "Save an API account on This Mac first."
        case .vaultLocked: "Unlock this host's credential vault, then sync again."
        case .outcomeUnknown: "An earlier sharing request needs review. Refresh the host's stored keys before trying again."
        case .sourceChanged: "The local account changed during sharing. Sync again to use the latest settings."
        case .persistence: "Sharing could not save its recovery record. No new key will be sent."
        case .invalidAccount: "The host's saved account does not match its credential record."
        }
    }
}

final class RelayHostAccountSharingStore: @unchecked Sendable {
    struct Snapshot: Codable, Sendable {
        var schema = 1
        var revision: UInt64 = 0
        var hosts: [RelayHostAccountSharingPolicy] = []
        var valid: Bool {
            schema == 1 && hosts.count <= 64 && hosts.allSatisfy(\.valid) &&
            Set(hosts.map(\.connectionKey)).count == hosts.count
        }
    }
    let url: URL
    init(url: URL) { self.url = url }
    func read() throws -> Snapshot { try transaction { try unlockedRead() } }
    func write(_ hosts: [RelayHostAccountSharingPolicy], expectedRevision: UInt64) throws -> UInt64 {
        try transaction {
            let old = try unlockedRead()
            guard old.revision == expectedRevision, old.revision < UInt64.max else { throw RelayHostAccountSharingError.persistence }
            let next = Snapshot(revision: old.revision + 1, hosts: hosts)
            guard next.valid else { throw RelayHostAccountSharingError.persistence }
            let data = try JSONEncoder().encode(next)
            guard data.count <= 262_144 else { throw RelayHostAccountSharingError.persistence }
            try data.write(to: url, options: .atomic)
            guard chmod(url.path, 0o600) == 0 else { throw RelayHostAccountSharingError.persistence }
            let file = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { throw RelayHostAccountSharingError.persistence }
            defer { Darwin.close(file) }
            guard fsync(file) == 0 else { throw RelayHostAccountSharingError.persistence }
            let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw RelayHostAccountSharingError.persistence }
            defer { Darwin.close(directory) }
            guard fsync(directory) == 0 else { throw RelayHostAccountSharingError.persistence }
            return next.revision
        }
    }
    private func unlockedRead() throws -> Snapshot {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw RelayHostAccountSharingError.persistence }
            return Snapshot()
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= 262_144 else { throw RelayHostAccountSharingError.persistence }
        let value = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        guard value.valid else { throw RelayHostAccountSharingError.persistence }
        return value
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw RelayHostAccountSharingError.persistence }
        let fd = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RelayHostAccountSharingError.persistence }
        defer { Darwin.close(fd) }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, flock(fd, LOCK_EX) == 0 else { throw RelayHostAccountSharingError.persistence }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

@MainActor protocol RelayHostAccountSharingIO {
    func status(_ profile: ConnectionProfile) async throws -> RelayHostRotationTextRPC.Status
    func credentials(_ profile: ConnectionProfile) async throws -> [RelayHostRotationTextRPC.CredentialRecord]
    func credential(_ reference: String, on profile: ConnectionProfile) async throws -> RelayHostRotationTextRPC.CredentialReceipt
    func localSecret(_ reference: String) async throws -> String
    func unlockVault(_ secret: String, on profile: ConnectionProfile) async throws
    func save(_ secret: String, reference: String, accountID: String, on profile: ConnectionProfile) async throws
    func configure(_ settings: RelayHostRotationTextRPC.Settings, operationID: String,
                   expected: String, on profile: ConnectionProfile) async throws -> RelayHostRotationTextRPC.Status
}

extension RelayHostAccountSharingIO {
    func unlockVault(_ secret: String, on profile: ConnectionProfile) async throws { throw RelayHostAccountSharingError.unavailable }
}

@MainActor struct RelayNativeHostAccountSharingIO: RelayHostAccountSharingIO {
    func status(_ profile: ConnectionProfile) async throws -> RelayHostRotationTextRPC.Status {
        try await RelayHostAccountsService(profile: profile).readHostRotationTextStatus()
    }
    func credentials(_ profile: ConnectionProfile) async throws -> [RelayHostRotationTextRPC.CredentialRecord] {
        try await RelayHostAccountsService(profile: profile).readHostRotationCredentials()
    }
    func credential(_ reference: String, on profile: ConnectionProfile) async throws -> RelayHostRotationTextRPC.CredentialReceipt {
        try await RelayHostAccountsService(profile: profile).readHostRotationCredential(reference: reference)
    }
    func localSecret(_ reference: String) async throws -> String { try await RelayLocalAccountSecret.read(reference) }
    func unlockVault(_ secret: String, on profile: ConnectionProfile) async throws {
        try await RelayHostAccountsService(profile: profile).unlockHostVault(secret: secret)
    }
    func save(_ secret: String, reference: String, accountID: String, on profile: ConnectionProfile) async throws {
        let result = try await RelayHostAccountsService(profile: profile).saveHostRotationCredential(
            reference: reference, accountID: accountID, secret: secret)
        guard result.status == "saved" else { throw RelayHostAccountSharingError.vaultLocked }
    }
    func configure(_ settings: RelayHostRotationTextRPC.Settings, operationID: String,
                   expected: String, on profile: ConnectionProfile) async throws -> RelayHostRotationTextRPC.Status {
        try await RelayHostAccountsService(profile: profile).configureHostRotationText(settings,
            expectedConfigurationID: expected, operationID: operationID)
    }
}

/// The Keychain helper's response stays in private process pipes and native
/// memory. It never enters a workspace job, diagnostic, terminal or MCP reply.
enum RelayLocalAccountSecret {
    static func read(_ reference: String) async throws -> String {
        guard RelayHostRotationRPC.validOperationID(reference),
              let executable = Bundle.main.executableURL else { throw RelayHostAccountSharingError.unavailable }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("relay-credentials")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process(), output = Pipe(), errors = Pipe()
                    process.executableURL = helper
                    process.standardInput = Pipe(); process.standardOutput = output; process.standardError = errors
                    process.environment = ProcessInfo.processInfo.environment.filter {
                        ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL"].contains($0.key)
                    }
                    let input = try JSONSerialization.data(withJSONObject: ["v": 1, "operation": "read", "reference": reference])
                    let result = try ProcessCapture.run(process, output: output, errors: errors,
                        input: input, timeout: 8, maximumBytesPerStream: 512)
                    guard process.terminationStatus == 0,
                          let value = String(data: result.standardOutput, encoding: .ascii),
                          (16...512).contains(value.utf8.count), value.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
                    else { throw RelayHostAccountSharingError.vaultLocked }
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: RelayHostAccountSharingError.vaultLocked) }
            }
        }
    }
}

@MainActor final class RelayHostAccountSharing: ObservableObject {
    static let shared = RelayHostAccountSharing(store: .init(url: RelayStateProfile.applicationSupportRoot
        .appendingPathComponent("Relay", isDirectory: true)
        .appendingPathComponent("account-sharing", isDirectory: true).appendingPathComponent("hosts.json")),
        io: RelayNativeHostAccountSharingIO())
    enum Phase: Equatable { case disabled, synchronizing, synchronized, needsReview }
    struct Status: Equatable {
        var phase: Phase = .disabled
        var message = "Local API accounts are not shared with this host."
    }
    @Published private(set) var revision = 0
    private let store: RelayHostAccountSharingStore
    private let io: any RelayHostAccountSharingIO
    private var storeRevision: UInt64 = 0
    private var policies: [String: RelayHostAccountSharingPolicy] = [:]
    private var statuses: [String: Status] = [:]
    private var profiles: [String: ConnectionProfile] = [:]
    private var active: Set<String> = []
    private var requestedAgain: Set<String> = []
    private(set) var storeAvailable = true

    init(store: RelayHostAccountSharingStore, io: any RelayHostAccountSharingIO) {
        self.store = store; self.io = io
        do {
            let snapshot = try store.read(); storeRevision = snapshot.revision
            policies = Dictionary(uniqueKeysWithValues: snapshot.hosts.map { ($0.connectionKey, $0) })
        } catch { storeAvailable = false }
    }
    func isEnabled(_ profile: ConnectionProfile) -> Bool { policies[profile.connectionKey]?.enabled == true }
    func status(_ profile: ConnectionProfile) -> Status {
        if !storeAvailable { return Status(phase: .needsReview, message: RelayHostAccountSharingError.persistence.localizedDescription) }
        return statuses[profile.connectionKey] ?? (isEnabled(profile) ?
            Status(phase: .needsReview, message: "Connect to this host to check its shared API accounts.") : Status())
    }
    func setEnabled(_ enabled: Bool, for profile: ConnectionProfile) async {
        guard profile.kind == .ssh, profile.backend == .relay else { return }
        let key = profile.connectionKey; profiles[key] = profile
        do {
            guard storeAvailable else { throw RelayHostAccountSharingError.persistence }
            var policy = policies[key] ?? .init(connectionKey: key, enabled: false)
            policy.enabled = enabled; policies[key] = policy; try persist()
            if enabled { await synchronize(profile) }
            else { setStatus(key, Status()) }
        } catch { setFailure(key, error) }
    }
    func hostReady(_ profile: ConnectionProfile) {
        guard profile.kind == .ssh, profile.backend == .relay else { return }
        profiles[profile.connectionKey] = profile
        guard isEnabled(profile) else { return }
        Task { await synchronize(profile) }
    }
    func localAccountsChanged() {
        for profile in profiles.values where isEnabled(profile) {
            if active.contains(profile.connectionKey) { requestedAgain.insert(profile.connectionKey) }
            else { Task { await synchronize(profile) } }
        }
    }
    func synchronize(_ profile: ConnectionProfile) async {
        let key = profile.connectionKey
        guard profile.kind == .ssh, profile.backend == .relay, isEnabled(profile), !active.contains(key) else { return }
        active.insert(key); setStatus(key, Status(phase: .synchronizing, message: "Sharing API accounts securely…"))
        defer {
            active.remove(key)
            if requestedAgain.remove(key) != nil, isEnabled(profile) { Task { await synchronize(profile) } }
        }
        do {
            try await perform(profile)
            if isEnabled(profile) { setStatus(key, Status(phase: .synchronized, message: "API accounts are in sync with This Mac.")) }
        } catch {
            if isEnabled(profile) { setFailure(key, error) }
            else { setStatus(key, Status()) }
        }
    }
    private func perform(_ profile: ConnectionProfile) async throws {
        let key = profile.connectionKey
        guard storeAvailable, var policy = policies[key], policy.enabled else { throw RelayHostAccountSharingError.persistence }
        let source = try await io.status(.local)
        let destination = try await io.status(profile)
        guard source.valid, destination.valid, source.supportsCredentials, destination.supportsCredentials,
              let sourceSettings = source.settings, let sourceID = source.configurationID,
              (destination.unresolved ?? []).isEmpty else { throw RelayHostAccountSharingError.unavailable }
        let sourceAccounts = (sourceSettings.accounts ?? []).filter { $0.provider == "anthropic_api" }
        guard !sourceAccounts.isEmpty || !policy.managedAccountIDs.isEmpty else { throw RelayHostAccountSharingError.noLocalAPIAccount }
        if let unlockReference = policy.vaultUnlockReference {
            guard destination.vaultUnlockSupport == "gnome_secret_service_v1", isEnabled(profile) else { throw RelayHostAccountSharingError.unavailable }
            let secret = try await io.localSecret(unlockReference)
            guard isEnabled(profile) else { throw RelayHostAccountSharingError.sourceChanged }
            try await io.unlockVault(secret, on: profile)
        }
        if let pending = policy.pendingConfiguration {
            guard destination.configurationID == pending.operationID,
                  destination.settings.map(Self.digest) == pending.settingsDigest else { throw RelayHostAccountSharingError.outcomeUnknown }
            policy.pendingConfiguration = nil; try persistPolicy(policy)
        }
        let credentials = try await io.credentials(profile)
        var shared: [RelayHostRotationTextRPC.Account] = []
        for var account in sourceAccounts {
            guard isEnabled(profile) else { throw RelayHostAccountSharingError.sourceChanged }
            guard account.valid else { throw RelayHostAccountSharingError.invalidAccount }
            if let sourceReference = account.credentialReference {
                var binding = policy.bindings.first { $0.accountID == account.id }
                if binding?.sourceReference != sourceReference {
                    guard binding?.phase != .submitted else { throw RelayHostAccountSharingError.outcomeUnknown }
                    binding = .init(accountID: account.id, sourceReference: sourceReference,
                        destinationReference: RelayHostRotationRPC.newOperationID(), phase: .prepared)
                    policy.bindings.removeAll { $0.accountID == account.id }; policy.bindings.append(binding!)
                    try persistPolicy(policy)
                }
                guard var value = binding else { throw RelayHostAccountSharingError.persistence }
                if let remote = credentials.first(where: { $0.reference == value.destinationReference }) {
                    guard remote.accountID == account.id,
                          try await io.credential(value.destinationReference, on: profile).status == "saved"
                    else { throw RelayHostAccountSharingError.invalidAccount }
                    value.phase = .saved
                } else {
                    guard value.phase == .prepared else { throw RelayHostAccountSharingError.outcomeUnknown }
                    let secret = try await io.localSecret(sourceReference)
                    let currentSource = try await io.status(.local)
                    guard currentSource.configurationID == sourceID, isEnabled(profile) else { throw RelayHostAccountSharingError.sourceChanged }
                    value.phase = .submitted
                    policy.bindings.removeAll { $0.accountID == account.id }; policy.bindings.append(value)
                    try persistPolicy(policy)
                    try await io.save(secret, reference: value.destinationReference, accountID: account.id, on: profile)
                    guard try await io.credential(value.destinationReference, on: profile).status == "saved"
                    else { throw RelayHostAccountSharingError.vaultLocked }
                    value.phase = .saved
                }
                policy.bindings.removeAll { $0.accountID == account.id }; policy.bindings.append(value)
                try persistPolicy(policy)
                account.credentialReference = value.destinationReference
            }
            shared.append(account)
        }
        guard (try await io.status(.local)).configurationID == sourceID, isEnabled(profile) else { throw RelayHostAccountSharingError.sourceChanged }
        let target = try await io.status(profile)
        guard target.valid, (target.unresolved ?? []).isEmpty else { throw RelayHostAccountSharingError.unavailable }
        guard isEnabled(profile), (try await io.status(.local)).configurationID == sourceID else { throw RelayHostAccountSharingError.sourceChanged }
        let settings = try Self.merged(source: sourceSettings, shared: shared,
            destination: target.settings, managedIDs: policy.managedAccountIDs)
        policy.managedAccountIDs = shared.map(\.id)
        if target.settings != settings {
            let operationID = RelayHostRotationRPC.newOperationID()
            policy.pendingConfiguration = .init(operationID: operationID, settingsDigest: Self.digest(settings))
            try persistPolicy(policy)
            _ = try await io.configure(settings, operationID: operationID, expected: target.configurationID ?? "", on: profile)
            let confirmation = try await io.status(profile)
            guard confirmation.configurationID == operationID, confirmation.settings == settings else { throw RelayHostAccountSharingError.outcomeUnknown }
            policy.pendingConfiguration = nil
        }
        try persistPolicy(policy)
    }
    static func merged(source: RelayHostRotationTextRPC.Settings, shared: [RelayHostRotationTextRPC.Account],
                       destination: RelayHostRotationTextRPC.Settings?, managedIDs: [String]) throws -> RelayHostRotationTextRPC.Settings {
        var value = source
        let replacing = Set(managedIDs + shared.map(\.id))
        let retained = (destination?.accounts ?? []).filter { !replacing.contains($0.id) }
        value.accounts = retained + shared
        // CLI logins and executable paths belong to their execution host.
        value.claudePath = destination?.claudePath; value.codexPath = destination?.codexPath
        value.codexModel = destination?.codexModel ?? source.codexModel
        value.providers = source.providers.filter { provider in
            provider == "anthropic_api" || retained.contains(where: { $0.provider == provider })
        }
        for provider in destination?.providers ?? [] where !value.providers.contains(provider) { value.providers.append(provider) }
        if value.providers.isEmpty { value.providers = ["anthropic_api"] }
        guard value.valid else { throw RelayHostAccountSharingError.invalidAccount }
        return value
    }
    static func digest(_ settings: RelayHostRotationTextRPC.Settings) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(settings)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    private func persistPolicy(_ value: RelayHostAccountSharingPolicy) throws {
        guard let current = policies[value.connectionKey] else { throw RelayHostAccountSharingError.persistence }
        var value = value
        // A user can revoke sharing while a host request is in flight. Record
        // that request's outcome without restoring the earlier enabled flag.
        value.enabled = current.enabled
        policies[value.connectionKey] = value
        try persist()
    }
    private func persist() throws {
        guard storeAvailable else { throw RelayHostAccountSharingError.persistence }
        do { storeRevision = try store.write(Array(policies.values).sorted { $0.connectionKey < $1.connectionKey }, expectedRevision: storeRevision) }
        catch { storeAvailable = false; throw RelayHostAccountSharingError.persistence }
    }
    private func setStatus(_ key: String, _ status: Status) {
        statuses[key] = status; revision += 1
        RelayDiagnostics.shared.record(category: "accounts", name: "sharing_status", details: [
            "phase": String(describing: status.phase), "message": status.message,
        ])
    }
    private func setFailure(_ key: String, _ error: Error) {
        setStatus(key, Status(phase: .needsReview, message: (error as? RelayHostAccountSharingError)?.localizedDescription ??
            "Sharing could not finish. Check this host's credential vault and connection, then sync again."))
    }
}
