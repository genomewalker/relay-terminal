import Foundation
import CryptoKit
import Combine

/// Scoped credentials identify a registered client, not the person/process that
/// first requested registration. The shared installation credential is legacy.
@MainActor
final class RelayCallerControl: ObservableObject {
    static let shared = RelayCallerControl()
    struct Summary: Identifiable {
        let id: String
        let label: String
        let thread: String?
        let paused: Bool
    }
    struct Caller: Codable {
        let id: UUID
        let label: String
        let thread: String?
        let tokenHash: String
        var paused: Bool
    }
    struct Audit: Codable {
        let id: UUID
        let at: Date
        let caller: String
        let path: String
        let operation: String?
        let requestID: String?
        let tabID: String?
        let paneID: String?
        let jobID: String?
        let outcome: String
        /// The user request behind an in-process Relay assistant action.
        var request: String? = nil
        /// Relay assistant Change actions: stable action ID, SHA-256 of the
        /// exact request body, and a redacted preview of its arguments.
        var actionID: String? = nil
        var argumentsDigest: String? = nil
        var preview: String? = nil
    }
    static let assistantCaller = "relay-assistant"
    /// A reserved, app-owned publisher namespace. No caller token maps to it;
    /// only the in-process assistant route may select it. It grants nothing.
    static let assistantPublisher = "a5515700-0000-4000-8000-00000000face"
    /// MCP calls on the Miko supervisor channel, by kernel-verified pane.
    static let supervisorCaller = "miko-supervisor"
    private struct Disk: Codable {
        var callers: [Caller] = []
        var audit: [Audit] = []
        var legacyPaused = false
        var daemonOwners: [ConnectionProfile]? = nil
    }
    @Published private var disk = Disk()
    @Published private var daemonSnapshots: [String: [Summary]] = [:]
    /// Hosts whose latest caller-list read failed.
    @Published private var daemonReadFailures: Set<String> = []
    private var daemonReadFailed: Bool { !daemonReadFailures.isEmpty }
    /// Recorded on every MCP request. Deliberately not published: SwiftUI
    /// would otherwise lay out caller views twice per request.
    private var auditRecords: [Audit] = []
    /// Connection key -> the transport incarnation and policy revision the
    /// daemon last received. A matching attach is skipped entirely.
    private var attachedDaemons: [String: String] = [:]
    /// Bumped whenever local callers or the installation pause change, so the
    /// next attach to each host imports them again.
    private var policyRevision = 0
    /// Replaceable in tests: the daemon transport and its incarnation.
    var policyTransport: @MainActor (ConnectionProfile, [String: Any]) async throws -> [String: Any] = { profile, packet in
        let result = try await RelayHostExecution.communicationRequest(profile: profile, packet: packet)
        guard let value = result.value else { throw RelayHostRPCError.invalidRequest }
        return value
    }
    var transportIncarnation: (ConnectionProfile) -> String? = { RelayNodeTransportPool.shared.incarnation(profile: $0) }
    static let auditLimit = 2000
    private let url: URL
    private let auditLog: RelayCallerAuditLog
    private var storageReady = true
    init(directory: URL? = nil) {
        let root = directory ?? RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay", isDirectory: true)
        url = root.appendingPathComponent("caller-control-v1.json")
        auditLog = RelayCallerAuditLog(url: root.appendingPathComponent("caller-audit-v1.jsonl"), limit: Self.auditLimit)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 4 << 20 else { throw RelayHostRPCError.invalidRequest }
                disk = try JSONDecoder().decode(Disk.self, from: data)
            } catch { storageReady = false }
        }
        guard storageReady else { return }
        do {
            if !disk.audit.isEmpty {
                // One-time move out of the caller file. The log is written
                // first; a crash between the two steps keeps the log's copy.
                if !auditLog.exists { try auditLog.replace(with: disk.audit) }
                disk.audit = []
                try save()
            }
            auditRecords = try auditLog.load()
        } catch { storageReady = false }
    }
    private func save() throws {
        guard storageReady else { throw RelayHostRPCError.invalidRequest }
        let data = try JSONEncoder().encode(disk)
        guard data.count <= 4 << 20 else { throw RelayHostRPCError.invalidRequest }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func register(label: String, thread: String?) async throws -> [String: String] {
        guard storageReady, !label.isEmpty, label.utf8.count <= 120,
              thread == nil || (thread!.utf8.count <= 100 && !thread!.isEmpty),
              disk.callers.count < 128 else { throw RelayHostRPCError.invalidRequest }
        let id = UUID(), token = UUID().uuidString + UUID().uuidString
        let caller = Caller(id: id, label: label, thread: thread, tokenHash: hash(token), paused: false)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(caller))
        for profile in disk.daemonOwners ?? [] {
            _ = try await daemonPolicyRequest(profile: profile, packet: ["operation": "caller_register", "policy": ["callers": [object], "legacyPaused": false]])
        }
        disk.callers.append(caller)
        do { try save() } catch { disk.callers.removeLast(); throw error }
        policyRevision += 1
        return ["caller_id": id.uuidString.lowercased(), "caller_token": token,
                "identity": "registered_client; thread_label_is_claimed"]
    }
    func identity(token: String?) throws -> String {
        guard storageReady else { throw RelayHostRPCError.invalidRequest }
        guard let token else { return "legacy-unattributed" }
        guard token.utf8.count <= 200,
              let caller = disk.callers.first(where: { $0.tokenHash == hash(token) }),
              caller.id.uuidString.lowercased() != Self.assistantPublisher else {
            throw RelayHostRPCError.invalidRequest
        }
        return caller.id.uuidString.lowercased()
    }
    /// A request is authorized by a registered caller token alone, or by the
    /// installation token. With both, the caller token decides the identity
    /// (`identity(token:)` reads the caller header first); with only the
    /// installation token the identity is `legacy-unattributed`.
    func authorizes(_ request: RelaySidePanelHTTPRequest, installationToken: String) -> Bool {
        if let presented = request.headers["x-relay-caller-token"], (try? identity(token: presented)) != nil { return true }
        return request.isAuthorized(token: installationToken)
    }
    /// Paths that register or pause callers. Never served over HTTP.
    nonisolated static func isAdministrativePath(_ path: String) -> Bool {
        path == "/api/callers/register" || path == "/api/callers/control"
    }
    /// App-UI entry points: only a hardware-origin click or key press admits
    /// the change. A nil or synthesized event is refused before any state moves.
    func register(label: String, thread: String?, origin: RelayKeyEventOrigin) async throws -> [String: String] {
        guard origin == .hardware else { throw RelayHostRPCError.invalidRequest }
        return try await register(label: label, thread: thread)
    }
    func setPaused(id: String, paused: Bool, origin: RelayKeyEventOrigin) async throws {
        guard origin == .hardware else { throw RelayHostRPCError.invalidRequest }
        try await setPaused(id: id, paused: paused)
    }
    func permitted(_ identity: String) -> Bool {
        // The in-app Relay assistant uses the installation credential path, so
        // the installation-level pause also pauses it.
        if identity == "legacy-unattributed" { return !disk.legacyPaused }
        if identity == Self.assistantCaller { return !disk.legacyPaused }
        if identity == Self.assistantPublisher { return !disk.legacyPaused }
        return disk.callers.first { $0.id.uuidString.lowercased() == identity }?.paused == false
    }
    func isRegisteredPublisher(_ identity: String) -> Bool {
        identity == Self.assistantPublisher || summaries.contains { $0.id == identity }
    }
    @discardableResult private func daemonPolicyRequest(profile: ConnectionProfile, packet: [String: Any]) async throws -> [String: Any] {
        try await policyTransport(profile, packet)
    }
    /// Imports the local caller policy into a host's daemon once per transport
    /// incarnation and policy revision; a reconnect or a local policy change
    /// imports it again. Only an actual import reads that host's caller list.
    func attachDaemon(profile: ConnectionProfile) async throws {
        guard storageReady else { throw RelayHostRPCError.invalidRequest }
        let key = profile.connectionKey
        let revision = policyRevision
        let incarnation = transportIncarnation(profile)
        if let incarnation, attachedDaemons[key] == "\(incarnation)|\(revision)" { return }
        // Import is create-only: server pause changes survive stale client caches.
        let policy: [String: Any] = ["callers": try JSONSerialization.jsonObject(with: JSONEncoder().encode(disk.callers)),
                                    "legacyPaused": disk.legacyPaused]
        try await daemonPolicyRequest(profile: profile, packet: ["operation": "caller_policy_import", "policy": policy])
        if !(disk.daemonOwners ?? []).contains(where: { $0.connectionKey == key }) {
            let old = disk
            disk.daemonOwners = (disk.daemonOwners ?? []) + [profile]
            do { try save() } catch { disk = old; throw error }
        }
        try await refreshDaemonPolicy(profile)
        // Only the incarnation read before the import is known to hold the
        // policy, and only while it is still current: a transport created or
        // reconnected during these requests is attached again next time.
        if let incarnation, transportIncarnation(profile) == incarnation { attachedDaemons[key] = "\(incarnation)|\(revision)" }
    }
    /// Reads every daemon owner's caller list: after a policy change, and
    /// while the Settings caller view is open. Polling paths never call it.
    func refreshDaemonPolicies() async throws {
        var failed = false
        for profile in disk.daemonOwners ?? [] {
            do { try await refreshDaemonPolicy(profile) } catch { failed = true }
        }
        if failed { throw RelayHostRPCError.invalidRequest }
    }
    private func refreshDaemonPolicy(_ profile: ConnectionProfile) async throws {
        do {
            try await readDaemonPolicy(profile)
            daemonReadFailures.remove(profile.connectionKey)
        } catch {
            daemonReadFailures.insert(profile.connectionKey)
            throw error
        }
    }
    private func readDaemonPolicy(_ profile: ConnectionProfile) async throws {
        let response = try await daemonPolicyRequest(profile: profile, packet: ["operation": "caller_list"])
        guard response["authority"] as? String == "relayd", let callers = response["callers"] as? [[String: Any]] else { throw RelayHostRPCError.invalidRequest }
        let values = try callers.map { item -> Summary in
            guard let id = item["caller_id"] as? String, let label = item["label"] as? String, let paused = item["paused"] as? Bool else { throw RelayHostRPCError.invalidRequest }
            return Summary(id: id, label: label, thread: item["thread"] as? String, paused: paused)
        }
        daemonSnapshots[profile.connectionKey] = values
    }
    func setPaused(id: String, paused: Bool) async throws {
        guard id == "legacy-unattributed" || disk.callers.contains(where: { $0.id.uuidString.lowercased() == id }) else { throw RelayHostRPCError.invalidRequest }
        // All known servers must accept this change. A failed remote update is
        // reported to the user; successful server writes are never hidden.
        do {
            for profile in disk.daemonOwners ?? [] {
                try await daemonPolicyRequest(profile: profile, packet: ["operation": "caller_set_paused", "caller_id": id, "paused": paused])
            }
        } catch {
            try? await refreshDaemonPolicies()
            throw error
        }
        let old = disk
        if id == "legacy-unattributed" { disk.legacyPaused = paused }
        else {
            guard let i = disk.callers.firstIndex(where: { $0.id.uuidString.lowercased() == id }) else {
                throw RelayHostRPCError.invalidRequest
            }
            disk.callers[i].paused = paused
        }
        do { try save() } catch { disk = old; throw error }
        policyRevision += 1
        try await refreshDaemonPolicies()
    }
    func listing() -> [[String: String]] {
        summaries.map {
            ["caller_id": $0.id, "label": $0.label,
             "thread": $0.thread ?? "", "paused": String($0.paused), "identity": $0.id == "legacy-unattributed" ? "unknown" : "registered_client; claimed_thread"]
        }
    }
    var summaries: [Summary] {
        let local = [Summary(id: "legacy-unattributed", label: "Shared installation credential", thread: nil, paused: disk.legacyPaused)] + disk.callers.map {
            Summary(id: $0.id.uuidString.lowercased(), label: $0.label, thread: $0.thread, paused: $0.paused)
        }
        // Any paused server keeps the aggregate paused. Changes apply to every
        // tracked owner, including after a partially successful operation.
        return local.map { caller in
            let server = daemonSnapshots.values.flatMap { $0 }.filter { $0.id == caller.id }
            return Summary(id: caller.id, label: caller.label, thread: caller.thread,
                           paused: caller.paused || server.contains(where: { $0.paused }))
        }
    }
    var available: Bool { storageReady && !daemonReadFailed }
    func label(for identity: String) -> String {
        summaries.first(where: { $0.id == identity })?.label ?? identity
    }
    func audit() -> [Audit] { auditRecords }
    /// Relay assistant navigation runs in-process rather than over MCP, but is
    /// journaled in the same durable, append-only caller audit with the
    /// assistant request that caused it.
    func recordAssistantAction(operation: String, requestID: String, request: String,
                               tabID: UUID?, paneID: UUID?, outcome: String, path: String = "in-process/relay-assistant",
                               actionID: UUID? = nil, argumentsDigest: String? = nil, preview: String? = nil) throws {
        guard storageReady else { throw RelayHostRPCError.invalidRequest }
        var record = Audit(id: UUID(), at: Date(), caller: Self.assistantCaller, path: String(path.prefix(180)),
            operation: String(operation.prefix(128)), requestID: String(requestID.prefix(128)),
            tabID: tabID?.uuidString.lowercased(), paneID: paneID?.uuidString.lowercased(), jobID: nil,
            outcome: String(outcome.prefix(64)), request: RelayAssistantSnapshot.clean(request, limit: 240))
        record.actionID = actionID?.uuidString.lowercased()
        record.argumentsDigest = argumentsDigest.map { String($0.prefix(64)) }
        record.preview = preview.map { RelayAssistantSnapshot.clean($0, limit: 240) }
        try auditLog.append(record)
        auditRecords.append(record)
        if auditRecords.count > Self.auditLimit { auditRecords.removeFirst(auditRecords.count - Self.auditLimit) }
    }
    /// A Miko supervisor channel call: the supervisor's kernel-verified pane,
    /// the single-use attestation it was proven by, and the exact arguments'
    /// digest. Durable before the call is answered.
    func recordSupervisorAction(supervisorPaneID: String, operation: String, requestID: String, attestationID: String,
                                argumentsDigest: String, preview: String?, outcome: String) throws {
        guard storageReady else { throw RelayHostRPCError.invalidRequest }
        var record = Audit(id: UUID(), at: Date(), caller: Self.supervisorCaller,
            path: "mcp/miko-supervisor/attestation/" + String(attestationID.prefix(32)),
            operation: String(operation.prefix(128)), requestID: String(requestID.prefix(128)),
            tabID: nil, paneID: String(supervisorPaneID.prefix(64)), jobID: nil, outcome: String(outcome.prefix(64)))
        record.argumentsDigest = String(argumentsDigest.prefix(64))
        record.preview = preview.map { RelayAssistantSnapshot.clean(RelayAssistantRedaction.redact($0), limit: 240) }
        try auditLog.append(record)
        auditRecords.append(record)
        if auditRecords.count > Self.auditLimit { auditRecords.removeFirst(auditRecords.count - Self.auditLimit) }
    }
    /// Durable before returning, so callers can keep refusing to dispatch an
    /// operation whose audit failed. Costs one small append, not a rewrite.
    func record(caller: String, request: RelaySidePanelHTTPRequest, outcome: String,
                responseData: Data? = nil) throws {
        guard storageReady else { throw RelayHostRPCError.invalidRequest }
        let input = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let output = responseData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        // Workspace RPC wraps the operation in `request`; caller identity still
        // comes from the server-resolved credential, never from either payload.
        let operationInput = request.path == "/api/workspace/host-request"
            ? (input["request"] as? [String: Any] ?? [:]) : input
        func field(_ names: [String], in object: [String: Any]) -> String? {
            for name in names { if let value = object[name] as? String { return String(value.prefix(128)) } }
            return nil
        }
        let record = Audit(id: UUID(), at: Date(), caller: caller, path: String(request.path.prefix(180)),
            operation: field(["operation", "action"], in: operationInput),
            requestID: field(["request_id", "requestID"], in: input)
                ?? field(["request_id", "requestID"], in: operationInput),
            tabID: field(["tabID", "tab_id"], in: output) ?? field(["tab_id", "tabID"], in: input),
            paneID: field(["paneID", "pane_id"], in: output) ?? field(["pane_id", "paneID"], in: input)
                ?? field(["pane_id", "paneID"], in: operationInput),
            jobID: field(["job_id"], in: operationInput), outcome: outcome)
        try auditLog.append(record)
        auditRecords.append(record)
        if auditRecords.count > Self.auditLimit { auditRecords.removeFirst(auditRecords.count - Self.auditLimit) }
    }
}

/// Append-only caller audit: one JSON line per record. A background queue
/// compacts it to the newest `limit` records once it holds twice that many,
/// so no request pays for re-encoding or rewriting the whole history.
final class RelayCallerAuditLog: @unchecked Sendable {
    private let url: URL
    private let limit: Int
    private let lock = NSLock()
    private let compactionQueue = DispatchQueue(label: "relay.caller-audit-compaction", qos: .utility)
    private var lineCount = 0
    private var compactionScheduled = false
    private static let maximumBytes = 32 << 20

    init(url: URL, limit: Int) {
        self.url = url
        self.limit = limit
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// An incomplete final line from an interrupted append is truncated so the
    /// next append starts cleanly; any undecodable complete line means the
    /// evidence is damaged and storage fails closed.
    func load() throws -> [RelayCallerControl.Audit] {
        lock.lock()
        defer { lock.unlock() }
        guard exists else { lineCount = 0; return [] }
        var data = try Data(contentsOf: url)
        guard data.count <= Self.maximumBytes else { throw RelayHostRPCError.invalidRequest }
        let complete = (data.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 }) ?? data.startIndex
        if complete < data.endIndex {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(complete - data.startIndex))
            data = data.prefix(upTo: complete)
        }
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        let records = try lines.map { try decoder.decode(RelayCallerControl.Audit.self, from: Data($0)) }
        lineCount = lines.count
        return Array(records.suffix(limit))
    }

    func append(_ record: RelayCallerControl.Audit) throws {
        var line = try JSONEncoder().encode(record)
        line.append(UInt8(ascii: "\n"))
        lock.lock()
        defer { lock.unlock() }
        try ensureFile()
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        lineCount += 1
        if lineCount > limit * 2, !compactionScheduled {
            compactionScheduled = true
            compactionQueue.async { [weak self] in self?.compact() }
        }
    }

    /// Replaces the log atomically with `records`, newest `limit` kept.
    func replace(with records: [RelayCallerControl.Audit]) throws {
        let encoder = JSONEncoder()
        var data = Data()
        for record in records.suffix(limit) {
            data.append(try encoder.encode(record))
            data.append(UInt8(ascii: "\n"))
        }
        lock.lock()
        defer { lock.unlock() }
        try writeAtomically(data)
        lineCount = min(records.count, limit)
    }

    private func compact() {
        lock.lock()
        defer { compactionScheduled = false; lock.unlock() }
        guard let data = try? Data(contentsOf: url), data.count <= Self.maximumBytes else { return }
        // Lines are already validated JSON written by append; keep them verbatim.
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        guard lines.count > limit else { return }
        var kept = Data()
        for line in lines.suffix(limit) {
            kept.append(contentsOf: line)
            kept.append(UInt8(ascii: "\n"))
        }
        if (try? writeAtomically(kept)) != nil { lineCount = limit }
    }

    private func ensureFile() throws {
        guard !exists else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RelayHostRPCError.invalidRequest
        }
    }

    private func writeAtomically(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
