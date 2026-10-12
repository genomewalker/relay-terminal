import Foundation

/// Uses the existing pane worker. Probe requests never attach an input client
/// or start a provider; writes use this viewer's current terminal input lease.
enum RelayHostRotationRPC {
    enum Operation: String, Encodable, Sendable { case status, enroll, disable }

    struct Enrollment: Codable, Equatable, Sendable {
        let sessionID: String
        let client: String
        let cwd: String
        let paneID: String
        let agentPID: Int
        let agentStart: UInt64
        let workerPID: Int
        let workerStart: UInt64
        let nodeBootID: String
        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id", client, cwd, paneID = "pane_id"
            case agentPID = "agent_pid", agentStart = "agent_start"
            case workerPID = "worker_pid", workerStart = "worker_start", nodeBootID = "node_boot_id"
        }
        func valid(for paneID: UUID) -> Bool {
            self.paneID == paneID.uuidString.lowercased() && validIdentifier(sessionID) &&
                ["claude", "codex"].contains(client) && validDirectory(cwd) &&
                agentPID > 1 && agentStart > 0 && workerPID > 1 && workerStart > 0 &&
                !nodeBootID.isEmpty && nodeBootID.utf8.count <= 128
        }
    }

    struct Decision: Decodable, Equatable, Sendable {
        let v: Int
        let decision: String
    }
    struct Preparation: Decodable, Equatable, Sendable {
        let state: String
        let code: String?
        var hint: String? {
            switch code {
            case "spending_limit": return "This host reached a spending or request limit. Review the Handoff text settings."
            case "text_backend_disabled": return "Enable Handoff text on this host to prepare a saved handoff."
            case "reconciliation_required": return "Review the unresolved Handoff text requests before continuing."
            case "text_settings_unavailable", "text_service_unavailable": return "Read Handoff text status. Update this host's helper if the text service remains unavailable."
            case "completed_turn_unavailable": return "Wait for a completed turn in the original CLI before preparing a handoff."
            case "source_unavailable", "source_changed", "invalid_source_binding", "generation_changed": return "The original session changed. Keep it open and wait for its next completed turn."
            case "ledger_unavailable", "capsule_storage_unavailable", "capsule_receipt_binding_mismatch": return "The host could not verify a saved handoff. Keep the original session open and check Chitta on this host."
            case "merge_limit", "incomplete_source_coverage": return "This conversation exceeds the supported handoff limits. Keep the original session open."
            default: return state.contains("failed") || state.contains("unavailable") ?
                "Handoff preparation could not finish. Keep the original session open and read Handoff text status." : nil
            }
        }
    }
    struct Status: Decodable, Equatable, Sendable {
        let version: Int?
        let operationID: String?
        let operation: String?
        let enabled: Bool?
        let state: String
        let generation: UInt64?
        let enrollment: Enrollment?
        let lifecycle: String?
        let refreshCapability: String?
        let nextEvaluationMS: Int64?
        let decision: Decision?
        let preparation: Preparation?
        let nativeRecoveryState: String?
        let message: String?
        enum CodingKeys: String, CodingKey {
            case version = "v", operationID = "operation_id", operation, enabled, state, generation, enrollment
            case lifecycle, refreshCapability = "refresh_capability", nextEvaluationMS = "next_evaluation_ms"
            case decision, preparation, nativeRecoveryState = "native_recovery_state", message
        }
        var isUnsupported: Bool { state == "unsupported" }
        func valid(for paneID: UUID) -> Bool {
            guard !state.isEmpty, state.utf8.count <= 80,
                  (message?.utf8.count ?? 0) <= 8192 else { return false }
            if isUnsupported { return version == nil && enabled == nil }
            guard version == 1, enabled != nil, generation != nil,
                  lifecycle?.isEmpty == false, (lifecycle?.utf8.count ?? 0) <= 80,
                  refreshCapability?.isEmpty == false, (refreshCapability?.utf8.count ?? 0) <= 80,
                  (nativeRecoveryState?.utf8.count ?? 0) <= 160,
                  nextEvaluationMS.map({ $0 >= 0 }) ?? true,
                  decision.map({ $0.v == 1 && !$0.decision.isEmpty && $0.decision.utf8.count <= 80 }) ?? true,
                  preparation.map({ !$0.state.isEmpty && $0.state.utf8.count <= 80 && ($0.code?.utf8.count ?? 0) <= 1024 }) ?? true
            else { return false }
            if ["not_enrolled", "invalid_saved_state", "saved_state_unavailable"].contains(state) {
                return enabled == false && (operationID == nil || operationID == "")
            }
            if operation == "disable", enabled == false, enrollment?.paneID == "" {
                return validOperationID(operationID ?? "") && enrollment?.agentPID == 0 && enrollment?.agentStart == 0
            }
            return validOperationID(operationID ?? "") && ["enroll", "disable"].contains(operation ?? "") &&
                enrollment?.valid(for: paneID) == true
        }
        var title: String {
            if isUnsupported { return "Host update required" }
            if state.contains("unavailable") || state.contains("failed") || state.contains("invalid") {
                return "Needs attention"
            }
            if enabled != true { return state == "human_takeover" ? "Paused after your input" : "Off" }
            if nativeRecoveryState != nil || state.contains("pending") && state.contains("native") {
                return "Finishing recovery"
            }
            if state == "native_refused" { return "Waiting for a new completed turn" }
            if state.contains("unavailable") || state.contains("failed") || state.contains("invalid") {
                return "Needs attention"
            }
            if state == "awaiting_completed_turn" { return "Waiting for a completed turn" }
            if state.hasPrefix("native_") { return "Managing context" }
            return "Monitoring context"
        }
    }

    struct NativeBinding: Decodable, Equatable, Sendable {
        struct Producer: Decodable, Equatable, Sendable {
            let paneID: String
            let provider: String
            let processID: Int
            let processStart: UInt64
            enum CodingKeys: String, CodingKey {
                case paneID = "pane_id", provider, processID = "process_id", processStart = "process_start"
            }
        }
        let version: Int
        let sessionID: String
        let transcriptPath: String
        let revision: String
        let producer: Producer
        enum CodingKeys: String, CodingKey {
            case version, sessionID = "session_id", transcriptPath = "transcript_path", revision, producer
        }
        func valid(for paneID: UUID) -> Bool {
            version == 1 && producer.paneID == paneID.uuidString.lowercased() &&
                ["claude", "codex"].contains(producer.provider) && producer.processID > 1 &&
                producer.processStart > 0 && validIdentifier(sessionID) &&
                validDirectory(transcriptPath) && !revision.isEmpty && revision.utf8.count <= 128
        }
    }


    struct NativeCandidate: Decodable, Equatable, Sendable {
        let version: Int
        let state: String
        let cwd: String
        let binding: NativeBinding
        enum CodingKeys: String, CodingKey { case version = "v", state, cwd, binding }
        func valid(for paneID: UUID) -> Bool {
            version == 1 && state == "ready" && validDirectory(cwd) && binding.valid(for: paneID)
        }
    }

    struct Request: Encodable, Sendable {
        let version = 1
        let operation: Operation
        var id: String? = nil
        var sessionID: String? = nil
        var client: String? = nil
        var cwd: String? = nil
        var agentPID: Int? = nil
        var agentStart: UInt64? = nil
        enum CodingKeys: String, CodingKey {
            case version = "v", operation, id, sessionID = "session_id", client, cwd
            case agentPID = "agent_pid", agentStart = "agent_start"
        }
        var valid: Bool {
            switch operation {
            case .status:
                return id == nil && sessionID == nil && client == nil && cwd == nil && agentPID == nil && agentStart == nil
            case .disable:
                return validOperationID(id ?? "") && sessionID == nil && client == nil && cwd == nil &&
                    agentPID == nil && agentStart == nil
            case .enroll:
                return validOperationID(id ?? "") && validIdentifier(sessionID ?? "") &&
                    ["claude", "codex"].contains(client ?? "") && validDirectory(cwd ?? "") &&
                    (agentPID ?? 0) > 1 && (agentStart ?? 0) > 0
            }
        }
    }

    enum Failure: LocalizedError {
        case unavailable, changedConnection, invalidResponse, refused(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Connect to this pane and take terminal control to change context management."
            case .changedConnection: "The pane or input ownership changed. Read host status before trying again."
            case .invalidResponse: "The host response could not be verified. Read host status; do not repeat the previous request."
            case .refused(let message): message
            }
        }
    }

    static func newOperationID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    static func validOperationID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 110 &&
            value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }
    static func validDirectory(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096 && !value.contains("\0")
    }

    static func decode(_ data: Data, paneID: UUID, request: Request) throws -> Status {
        guard data.count <= 262_144 else { throw Failure.invalidResponse }
        let response = try JSONDecoder().decode(Status.self, from: data)
        if response.state == "refused" {
            guard (response.message?.utf8.count ?? 0) <= 8192 else { throw Failure.invalidResponse }
            throw Failure.refused(response.message ?? "The host refused the request. Read status and check the pane's input ownership.")
        }
        guard response.valid(for: paneID) else { throw Failure.invalidResponse }
        if request.operation != .status {
            guard !response.isUnsupported, response.operationID == request.id,
                  response.operation == request.operation.rawValue,
                  response.enabled == (request.operation == .enroll) else { throw Failure.invalidResponse }
            if request.operation == .enroll {
                guard let e = response.enrollment, e.sessionID == request.sessionID, e.client == request.client,
                      e.cwd == request.cwd, e.agentPID == request.agentPID, e.agentStart == request.agentStart
                else { throw Failure.invalidResponse }
            }
        }
        return response
    }

    @MainActor static func send(_ request: Request, profile: ConnectionProfile, paneID: UUID,
        lease: RelayPromptEditorControlLease? = nil,
        currentLease: () -> RelayPromptEditorControlLease? = { nil }) async throws -> Status {
        guard request.valid, profile.backend == .relay else { throw Failure.unavailable }
        if request.operation != .status {
            guard let lease, lease.paneID == paneID, lease.hostID == profile.id,
                  currentLease() == lease else { throw Failure.changedConnection }
        }
        let command = RelayHostExecution.daemonCommand(profile: profile, arguments: [
            "rotation-supervisor-rpc", paneID.uuidString.lowercased(),
            (lease?.clientID ?? RelayClientIdentity.id).uuidString.lowercased()
        ])
        // HostExecution preserves an uncertain job ID. Never resubmit writes.
        let output = try await RelayHostExecution.capture(profile: profile, command: command,
            input: JSONEncoder().encode(request), timeout: 15, maximumBytes: 262_144)
        try Task.checkCancellation()
        if let lease, request.operation != .status, currentLease() != lease { throw Failure.changedConnection }
        guard output.exitCode == 0 else { throw Failure.invalidResponse }
        return try decode(output.stdout, paneID: paneID, request: request)
    }

    @MainActor static func readNativeBinding(profile: ConnectionProfile, paneID: UUID) async throws -> NativeBinding {
        let command = RelayHostExecution.daemonCommand(profile: profile,
            arguments: ["agent-binding", "--native", paneID.uuidString.lowercased()])
        let output = try await RelayHostExecution.capture(profile: profile, command: command,
            timeout: 12, maximumBytes: 65_536)
        try Task.checkCancellation()
        guard output.exitCode == 0 else { throw Failure.unavailable }
        let binding = try JSONDecoder().decode(NativeBinding.self, from: output.stdout)
        guard binding.valid(for: paneID) else { throw Failure.invalidResponse }
        return binding
    }

    @MainActor static func readNativeCandidate(profile: ConnectionProfile, paneID: UUID) async throws -> NativeCandidate {
        struct Probe: Encodable { let v = 1; let operation = "native_candidate" }
        struct Refusal: Decodable { let state: String?; let message: String? }
        let command = RelayHostExecution.daemonCommand(profile: profile, arguments: [
            "rotation-supervisor-rpc", paneID.uuidString.lowercased(), RelayClientIdentity.id.uuidString.lowercased()
        ])
        let output = try await RelayHostExecution.capture(profile: profile, command: command,
            input: JSONEncoder().encode(Probe()), timeout: 15, maximumBytes: 65_536)
        try Task.checkCancellation()
        guard output.exitCode == 0 else { throw Failure.unavailable }
        if let refusal = try? JSONDecoder().decode(Refusal.self, from: output.stdout),
           refusal.state == "refused" || refusal.state == "unsupported" {
            throw Failure.refused(refusal.message ?? "This host cannot verify the native session directory. Update the host helper and read status.")
        }
        let candidate = try JSONDecoder().decode(NativeCandidate.self, from: output.stdout)
        guard candidate.valid(for: paneID) else { throw Failure.invalidResponse }
        return candidate
    }
}
