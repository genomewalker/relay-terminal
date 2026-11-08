import Foundation

struct RelayPaneHealthHostControllerStatus: Decodable, Sendable {
    struct Configuration: Decodable, Sendable {
        let hostId: String?
        let ownerId: String?
        let enabled: Bool?
        let haikuEnabled: Bool?
        let generation: UInt64?
        let panes: [String]?
        let checks: [String]?
    }
    struct Observation: Decodable, Sendable {
        let paneId: String
        let observedAt: TimeInterval
        let proof: RelayAgentMaintenanceProbe
        let inputContract: String

        func valid(paneID: UUID, now: Date = Date()) -> Bool {
            let age = now.timeIntervalSince1970 - observedAt
            return proof.version == 1 && paneId == paneID.uuidString.lowercased() && observedAt.isFinite && age >= -5 && age < 300 &&
                inputContract == "desktop_native_verification_required" &&
                (proof.valid(for: paneID) || proof.validShell(for: paneID) ||
                    proof.unavailable != nil && (proof.paneID == nil || proof.paneID == paneId))
        }
    }
    struct Pending: Decodable, Sendable { let operationId: String }
    struct ActionRequest: Decodable, Sendable {
        let id: String
        let operationId: String
        let generation: UInt64
        let call: RelayPaneHealthToolCall
        let before: RelayPaneHealthJSON
        let state: String
    }
    struct State: Decodable, Sendable {
        let generation: UInt64?
        let status: String?
        let lastTickAt: TimeInterval?
        let lastObservedAt: TimeInterval?
        let lastModelAt: TimeInterval?
        let observations: [String: Observation]?
        let pending: Pending?
        let modelOperations: [String]?
        let report: RelayPaneHealthJSON?
        let actionRequests: [String: ActionRequest]?
    }
    let v: Int
    let status: String
    let controller: String?
    let configuration: Configuration?
    let state: State?
    let supervisorPid: Int?
    let supervisorStartTime: UInt64?
    let code: String?
    let acknowledgedActionId: String?

    /// A state file from the previous configuration is historical. It cannot
    /// supply current observations, model reports, or native action requests.
    var currentState: State? {
        guard let generation = configuration?.generation, generation > 0,
              state?.generation == generation else { return nil }
        return state
    }

    static func pendingOperation(controller: Self?, check: String?, legacy: String?) -> String? {
        controller?.currentState?.pending?.operationId ?? check ?? (controller == nil ? legacy : nil)
    }

    func valid(host: String, owner: String, paneIDs: Set<String>, enabled: Bool? = nil,
        haikuEnabled: Bool? = nil, generation: UInt64? = nil) -> Bool {
        guard let configuration, let panes = configuration.panes,
              let configuredGeneration = configuration.generation, configuredGeneration > 0,
              let configuredEnabled = configuration.enabled, let configuredHaiku = configuration.haikuEnabled,
              !panes.isEmpty, panes.count <= 128, Set(panes).count == panes.count,
              panes.allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }),
              configuration.checks.map({ $0.count <= 32 && Set($0).count == $0.count &&
                  $0.allSatisfy(RelayHostRotationRPC.validOperationID) }) ?? true else { return false }
        return v == 1 && status == "controller_status" && controller == "relayd" &&
        (supervisorPid ?? 0) > 1 && (supervisorStartTime ?? 0) > 0 &&
        configuration.hostId == host && configuration.ownerId == owner &&
        Set(panes) == paneIDs && (enabled == nil || configuredEnabled == enabled) &&
        (haikuEnabled == nil || configuredHaiku == haikuEnabled) &&
        (generation == nil || configuredGeneration == generation)
    }
}

/// Captured across a host RPC chain. Every reply must still belong to the
/// current desktop settings/pane set and, after admission, the same daemon.
struct RelayPaneHealthControllerScope: Sendable {
    let host: String
    let owner: String
    let panes: [String]
    let enabled: Bool
    let haiku: Bool
    var digest: String {
        RelayPaneHealthJSON.digest(RelayPaneHealthJSON.object(["host": .string(host), "owner": .string(owner),
            "panes": .array(panes.sorted().map(RelayPaneHealthJSON.string)),
            "enabled": .bool(enabled), "haiku": .bool(haiku)]))
    }

    func accepts(_ reply: RelayPaneHealthHostControllerStatus, currentDigest: String?, cancelled: Bool,
        admitted: RelayPaneHealthHostControllerStatus? = nil, placementsCurrent: Bool = true) -> Bool {
        guard !cancelled, placementsCurrent, currentDigest == digest,
              reply.valid(host: host, owner: owner, paneIDs: Set(panes), enabled: enabled, haikuEnabled: haiku,
                  generation: admitted?.configuration?.generation) else { return false }
        return admitted == nil || reply.supervisorPid == admitted?.supervisorPid &&
            reply.supervisorStartTime == admitted?.supervisorStartTime
    }
}

/// Configuration changes may supersede a sync that is still awaiting a native
/// action. Its eventual completion cannot remove or overwrite its replacement.
@MainActor final class RelayPaneHealthControllerTasks {
    private struct Entry { let id: UUID; let scope: String; let task: Task<Void, Never> }
    private var entries: [String: Entry] = [:]
    subscript(host: String) -> Task<Void, Never>? { entries[host]?.task }
    func scope(for host: String) -> String? { entries[host]?.scope }

    func cancelIfStale(host: String, scope: String) {
        guard let old = entries[host], old.scope != scope else { return }
        entries.removeValue(forKey: host)
        old.task.cancel()
    }

    func start(host: String, scope: String, work: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        cancelIfStale(host: host, scope: scope)
        if let old = entries[host] { return old.task }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            defer { if self?.entries[host]?.id == id { self?.entries.removeValue(forKey: host) } }
            await work()
        }
        entries[host] = Entry(id: id, scope: scope, task: task)
        return task
    }
}

struct RelayPaneHealthControllerCheck: Sendable {
    enum Disposition: Equatable { case queued, awaitingReceipt, recorded, unknown }
    let operationID: String
    let requestedAt: Date?
    let submitted: Bool?

    func disposition(recorded: [String], now: Date = Date()) -> Disposition {
        if recorded.contains(operationID) { return .recorded }
        // A missing field in an older journal is an uncertain dispatch, never
        // permission to send it again. Only an explicitly saved false is queued.
        if submitted == false { return .queued }
        return now.timeIntervalSince(requestedAt ?? .distantPast) > 60 ? .unknown : .awaitingReceipt
    }
}

/// Saved before acknowledging a daemon action. A lost acknowledgement must
/// reuse the exact result, including its original native evidence and wording.
struct RelayPaneHealthControllerActionReceipt: Codable, Sendable {
    let host: String
    let owner: String
    let generation: UInt64
    let actionID: String
    let operationID: String
    let callDigest: String
    let beforeDigest: String
    let result: RelayPaneHealthJSON
    var acknowledged: Bool? = nil

    init(request: RelayPaneHealthHostControllerStatus.ActionRequest, host: String, owner: String,
        result: RelayPaneHealthJSON) {
        self.host = host; self.owner = owner; generation = request.generation; actionID = request.id
        operationID = request.operationId; callDigest = RelayPaneHealthJSON.digest(request.call)
        beforeDigest = RelayPaneHealthJSON.digest(request.before); self.result = result
    }

    func matches(_ request: RelayPaneHealthHostControllerStatus.ActionRequest, host: String, owner: String) -> Bool {
        self.host == host && self.owner == owner && generation == request.generation && actionID == request.id &&
        operationID == request.operationId && callDigest == RelayPaneHealthJSON.digest(request.call) &&
        beforeDigest == RelayPaneHealthJSON.digest(request.before)
    }

    func canForget(currentGeneration: UInt64, requests: [RelayPaneHealthHostControllerStatus.ActionRequest]) -> Bool {
        acknowledged == true && (generation != currentGeneration ||
            !requests.contains { $0.id == actionID && $0.generation == generation && $0.state == "pending_native" })
    }
}

enum RelayPaneHealthHostControllerRPC {
    @MainActor static func send(profile: ConnectionProfile, action: String, operationID: String,
        host: String? = nil, owner: String? = nil, enabled: Bool? = nil, haikuEnabled: Bool? = nil,
        panes: [String]? = nil, generation: UInt64? = nil, facts: [RelayPaneHealthFacts]? = nil,
        actionID: String? = nil, result: RelayPaneHealthJSON? = nil) async throws -> RelayPaneHealthHostControllerStatus {
        try Task.checkCancellation()
        guard profile.backend == .relay, ["configure", "status", "check", "desktop_facts", "complete_action"].contains(action),
              RelayHostRotationRPC.validOperationID(operationID) else { throw RelayHostRotationRPC.Failure.invalidResponse }
        var request: [String: RelayPaneHealthJSON] = ["v": .integer(1), "operation": .string("pane_health_controller"),
            "operation_id": .string(operationID), "action": .string(action)]
        if action == "configure" {
            guard let host, let owner, UUID(uuidString: owner) != nil, let enabled, let haikuEnabled,
                  let panes, !panes.isEmpty, panes.count <= 128,
                  panes.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw RelayHostRotationRPC.Failure.invalidResponse }
            request["host_id"] = .string(host); request["owner_id"] = .string(owner)
            request["enabled"] = .bool(enabled); request["haiku_enabled"] = .bool(haikuEnabled)
            request["panes"] = .array(panes.sorted().map(RelayPaneHealthJSON.string))
        }
        if action == "desktop_facts" {
            guard let owner, UUID(uuidString: owner) != nil, let generation, let facts,
                  !facts.isEmpty, facts.count <= 64 else { throw RelayHostRotationRPC.Failure.invalidResponse }
            request["owner_id"] = .string(owner); request["generation"] = .unsigned(generation)
            request["facts"] = .array(facts.map(\.value))
        }
        if action == "complete_action" {
            guard let owner, UUID(uuidString: owner) != nil, let actionID,
                  RelayHostRotationRPC.validOperationID(actionID), let result else { throw RelayHostRotationRPC.Failure.invalidResponse }
            request["owner_id"] = .string(owner); request["action_id"] = .string(actionID); request["result"] = result
        }
        let payload = RelayPaneHealthJSON.object(["request_id": .string("rpc-" + UUID().uuidString.lowercased()),
            "operation": .string("host_accounts"), "host_accounts": .object(["request": .object(request)])])
        // Encoding and decoding run off the main actor. A status reply carries
        // every pane observation; parsing it on the main thread cost ~160-240 ms
        // per sync in the 0.5.36 idle profile and stalled the UI each time.
        let data = try await Task.detached(priority: .utility) { try RelayPaneHealthJSON.data(payload) }.value
        let raw = try await RelayNodeTransportPool.shared.request(profile: profile, payload: data,
            requiredCapability: "host_pane_health_controller_v1", timeoutSeconds: 35)
        try Task.checkCancellation()
        let reply = try await Task.detached(priority: .utility) { try decodeReply(raw) }.value
        try Task.checkCancellation()
        return reply
    }

    /// One typed pass over the reply envelope. Same outcomes as the former
    /// generic-JSON decode and re-encode: a string `error` is a refusal (even
    /// when `result` is malformed), a missing `result` is invalid, and the
    /// result is decoded with snake_case keys.
    nonisolated static func decodeReply(_ raw: Data) throws -> RelayPaneHealthHostControllerStatus {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(ReplyEnvelope.self, from: raw)
        if let error = envelope.error { throw RelayHostRotationRPC.Failure.refused(String(error.prefix(240))) }
        guard let result = envelope.result else { throw RelayHostRotationRPC.Failure.invalidResponse }
        return result
    }

    private struct ReplyEnvelope: Decodable {
        let error: String?
        let result: RelayPaneHealthHostControllerStatus?
        private enum CodingKeys: String, CodingKey { case error, result }
        init(from decoder: Decoder) throws {
            // A non-object reply had no `result` before: invalid, not a DecodingError.
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                error = nil; result = nil; return
            }
            // A non-string `error` was ignored before; keep ignoring it.
            error = (try? container.decodeIfPresent(String.self, forKey: .error)) ?? nil
            result = error == nil ? try container.decodeIfPresent(RelayPaneHealthHostControllerStatus.self, forKey: .result) : nil
        }
    }
}
