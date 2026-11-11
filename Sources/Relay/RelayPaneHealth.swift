import CryptoKit
import Foundation

indirect enum RelayPaneHealthJSON: Codable, Equatable, Sendable {
    // Controller replies carry Python/Go float timestamps (configured_at,
    // observed_at, last_model_at); without a number case they cannot decode.
    case object([String: Self]), array([Self]), string(String), integer(Int64), unsigned(UInt64), double(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> Self? { if case .object(let v) = self { v[key] } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var array: [Self]? { if case .array(let v) = self { v } else { nil } }
    var boolean: Bool? { if case .bool(let v) = self { v } else { nil } }
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func digest<T: Encodable>(_ value: T) -> String {
        guard let data = try? data(value) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct RelayPaneHealthFacts: Codable, Equatable, Sendable {
    let value: RelayPaneHealthJSON
    var paneID: String { value["pane_id"]?.string ?? "" }
    var evidenceID: String { value["evidence_id"]?.string ?? "" }
    var allowedActions: [String] { value["allowed_actions"]?.array?.compactMap(\.string) ?? [] }

    static func seal(_ fields: [String: RelayPaneHealthJSON]) -> Self {
        var value = fields
        value.removeValue(forKey: "evidence_id")
        value["evidence_id"] = .string(RelayPaneHealthJSON.digest(RelayPaneHealthJSON.object(value)))
        return Self(value: .object(value))
    }

    @MainActor static func read(_ pane: PaneModel, proof: RelayAgentMaintenanceProbe?) -> Self {
        let ended = pane.phase == .exited || pane.remoteExitCode != nil
        let agentValid = !ended && proof?.valid(for: pane.id) == true
        let shellValid = !ended && proof?.validShell(for: pane.id) == true
        let valid = agentValid || shellValid
        let draft = pane.composerStateIfCreated.map {
            !$0.draft.isEmpty || !$0.attachmentQueue.attachments.isEmpty || $0.submitting || $0.nativeDeliveryHeld
        } ?? false
        let explained = proof.map { RelayAgentMaintenancePolicy.explainedFooterAgents($0, subagents: pane.subagents) } ?? 0
        let empty = pane.runtime.agentMaintenancePromptIsEmpty(explainedAgents: explained)
        let inputIdle = Date().timeIntervalSince(pane.agentLastInputAt) >= 15
        let connection: String
        switch pane.connectionState {
        case .connected: connection = ended ? "disconnected" : "connected"
        case .connecting: connection = "connecting"
        case .reconnecting: connection = "reconnecting"
        case .waitingForNetwork: connection = "waiting_for_network"
        case .disconnected: connection = "disconnected"
        }
        let kind = shellValid ? "shell" : agentValid ? proof!.provider! :
            pane.kind == .claude ? "claude" : pane.kind == .codex ? "codex" : "shell"
        var actions = ["observe", "attention"]
        if RelayPreferences.shared.automaticAgentMaintenance {
            if agentValid, let proof,
               RelayAgentMaintenancePolicy.deferral(proof, paneID: pane.id, emptyPrompt: empty,
                   hasDraft: draft, pendingApprovals: pane.pendingAgentApprovals,
                   inputAge: Date().timeIntervalSince(pane.agentLastInputAt),
                   recordedAccount: pane.agentAccount?.recorded) == nil,
               pane.connectionState == .connected {
                if proof.bound == false { actions.append("repair_link") }
                if proof.installedUpdate == true { actions.append("apply_update") }
            }
            // A lost transport also marks the phase exited, so `ended` is true
            // here; only a program that really ended rules out a reattach.
            if !pane.programExited, case .disconnected = pane.connectionState,
               pane.profile.backend == .relay { actions.append("reconnect") }
        }
        var fields: [String: RelayPaneHealthJSON] = [
            "pane_id": .string(pane.id.uuidString.lowercased()), "kind": .string(kind),
            "connection": .string(connection),
            "binding": .string(shellValid ? "not_applicable" : agentValid ? (proof?.bound == true ? "bound" : proof?.bound == false ? "unbound" : "unknown") : "unknown"),
            "activity": .string(valid && (proof?.backgroundWork == true || ["active", "working"].contains(proof?.lifecycle ?? "")) ?
                "working" : valid && proof?.lifecycle == "quiet" ? "quiet" : "unknown"),
            "identity_verified": .bool(valid), "prompt_empty": .bool(empty), "has_draft": .bool(draft),
            "pending_approvals": .integer(Int64(pane.pendingAgentApprovals)), "input_idle": .bool(inputIdle),
            "installed_update": .bool(valid && proof?.installedUpdate == true),
            "allowed_actions": .array(actions.map { .string($0) }),
        ]
        // prompt_empty=false also means "could not be read" (a hidden pane
        // whose screen was never read, a changing screen, a guard). Say which,
        // so a hold is not mistaken for typed text. Unknown still holds.
        if !empty {
            fields["prompt_blocker"] = .string(pane.runtime.agentMaintenancePromptBlocker(explainedAgents: explained)
                ?? "the screen changed while it was read")
            if let proof {
                fields["footer_agent_facts"] = .string(RelayAgentMaintenancePolicy.footerAgentFacts(proof,
                    subagents: pane.subagents))
            }
        }
        if shellValid, let proof, let pid = proof.processID, let start = proof.processStart {
            fields["process_id"] = .integer(Int64(pid)); fields["process_start"] = .unsigned(start)
        }
        if valid, let proof, let session = proof.sessionID, let pid = proof.processID, let start = proof.processStart {
            fields["session_id"] = .string(session); fields["process_id"] = .integer(Int64(pid))
            fields["process_start"] = .unsigned(start)
        }
        return seal(fields)
    }
}

struct RelayPaneHealthToolCall: Codable, Equatable, Sendable {
    let type: String
    let id: String
    let name: String
    let input: RelayPaneHealthJSON
    var paneID: UUID? { input["pane_id"]?.string.flatMap(UUID.init(uuidString:)) }
}

struct RelayPaneHealthStep: Codable, Sendable {
    let v: Int
    let status: String
    let operationID: String
    let result: Backend?
    let chargedMicrousd: UInt64?
    let code: String?
    enum CodingKeys: String, CodingKey {
        case v, status, result, code, operationID = "operation_id", chargedMicrousd = "charged_microusd"
    }
    struct Backend: Codable, Sendable {
        let v: Int
        let status: String
        let operationID: String
        let code: String?
        let purpose: String?
        let provider: String?
        let model: String?
        let effort: String?
        let thinking: String?
        let binding: RelayPaneHealthJSON?
        let sourceSHA256: String?
        let assistantContent: [RelayPaneHealthJSON]?
        let toolCalls: [RelayPaneHealthToolCall]?
        enum CodingKeys: String, CodingKey {
            case v, status, code, purpose, provider, model, effort, thinking, binding
            case operationID = "operation_id", sourceSHA256 = "source_sha256"
            case assistantContent = "assistant_content", toolCalls = "tool_calls"
        }
    }
    func valid(operationID expected: String, host: String, snapshot: String,
               evidence: RelayPaneHealthJSON, paneIDs: Set<String>) -> Bool {
        guard v == 1, operationID == expected, status == "complete", let result,
              result.v == 1, result.status == "health_step", result.operationID == expected,
              result.purpose == "pane_health", result.provider == "anthropic_api",
              result.model == "claude-haiku-5-5", result.effort == "low", result.thinking == "disabled",
              result.binding == .object(["host_id": .string(host), "snapshot_id": .string(snapshot)]),
              result.sourceSHA256 == RelayPaneHealthJSON.digest(evidence),
              let calls = result.toolCalls, !calls.isEmpty, calls.count <= 64,
              Set(calls.map(\.id)).count == calls.count,
              let content = result.assistantContent,
              content.filter({ $0["type"]?.string == "tool_use" }).count == calls.count else { return false }
        for call in calls {
            guard call.type == "tool_use", call.id.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil,
                  let encoded = try? RelayPaneHealthJSON.data(call),
                  let canonical = try? JSONDecoder().decode(RelayPaneHealthJSON.self, from: encoded),
                  content.contains(canonical) else { return false }
            switch call.name {
            case "inspect_pane", "verify_pane", "repair_agent_link", "apply_installed_update", "reconnect_pane":
                guard let id = call.input["pane_id"]?.string, paneIDs.contains(id) else { return false }
            case "report_health":
                guard calls.count == 1, let rows = call.input["panes"]?.array,
                      rows.count == paneIDs.count,
                      Set(rows.compactMap { $0["pane_id"]?.string }) == paneIDs else { return false }
            default: return false
            }
        }
        return true
    }
}

enum RelayPaneHealthRPC {
    @MainActor static func send(profile: ConnectionProfile, operationID: String,
                               host: String? = nil, snapshot: String? = nil,
                               panes: [RelayPaneHealthFacts]? = nil,
                               messages: [RelayPaneHealthJSON]? = nil) async throws -> RelayPaneHealthStep {
        guard profile.backend == .relay, RelayHostRotationRPC.validOperationID(operationID) else {
            throw RelayHostRotationRPC.Failure.invalidResponse
        }
        var request: [String: RelayPaneHealthJSON] = ["v": .integer(1),
            "operation": .string(panes == nil ? "pane_health_status" : "pane_health_step"),
            "operation_id": .string(operationID)]
        if let panes {
            guard let host, let snapshot, let messages, !panes.isEmpty, panes.count <= 64 else {
                throw RelayHostRotationRPC.Failure.invalidResponse
            }
            request["host_id"] = .string(host); request["snapshot_id"] = .string(snapshot)
            request["panes"] = .array(panes.map(\.value)); request["messages"] = .array(messages)
        }
        let payload = RelayPaneHealthJSON.object([
            "request_id": .string("rpc-" + UUID().uuidString.lowercased()),
            "operation": .string("host_accounts"),
            "host_accounts": .object(["request": .object(request)]),
        ])
        let data = try RelayPaneHealthJSON.data(payload)
        guard data.count <= 262144 else { throw RelayHostRotationRPC.Failure.invalidResponse }
        let raw = try await RelayNodeTransportPool.shared.request(profile: profile, payload: data,
            requiredCapability: "pane_health_tools_v1", timeoutSeconds: 80)
        let envelope = try JSONDecoder().decode(RelayPaneHealthJSON.self, from: raw)
        if let error = envelope["error"]?.string {
            throw RelayHostRotationRPC.Failure.refused(String(error.prefix(240)))
        }
        guard let result = envelope["result"] else { throw RelayHostRotationRPC.Failure.invalidResponse }
        return try JSONDecoder().decode(RelayPaneHealthStep.self, from: RelayPaneHealthJSON.data(result))
    }
}
struct RelayPaneWorkerObservation: Codable, Equatable, Sendable {
    let workerPid: Int?
    let workerStart: UInt64?
    let upgradeMode: String
    let updateState: String
    let runningSha256: String?
    let installedSha256: String?
    let unavailable: String?
}

struct RelayPaneContextObservation: Codable, Equatable, Sendable {
    let supported: Bool
    let enabled: Bool
    let state: String
    let generation: UInt64?
    let lifecycle: String?
    let refreshCapability: String?
    let unavailable: String?
}

