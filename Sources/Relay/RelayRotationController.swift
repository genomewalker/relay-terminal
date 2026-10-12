import Foundation

/// Retained when Relay starts an explicitly enrolled root task. Existing tasks
/// without their original configuration snapshot cannot be auto-enrolled.
struct RelayRotationEnrollment: Codable, Equatable, Sendable {
    let sourceThreadID: String
    let projectDir: String
    let codeHead: String
    let socketPath: String
    let socketDevice: UInt64
    let socketInode: UInt64
    let sourceStartParameters: Data
    let enrolledAt: Date

    var valid: Bool {
        guard !sourceThreadID.isEmpty, sourceThreadID.utf8.count <= 110,
              !sourceThreadID.contains("/"), projectDir.hasPrefix("/"), socketPath.hasPrefix("/"),
              socketInode > 0, sourceStartParameters.count <= 65_536,
              codeHead.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil,
              let params = try? JSONSerialization.jsonObject(with: sourceStartParameters) as? [String: Any],
              params["cwd"] as? String == projectDir,
              let model = params["model"] as? String, !model.isEmpty,
              params["approvalPolicy"] != nil,
              (params["sandbox"] != nil) != (params["permissions"] != nil) else { return false }
        return true
    }
}

struct RelayRotationPolicyDecision: Codable, Equatable, Sendable {
    let action: String
    let reason: String
    let confidence: Double

    var valid: Bool {
        ["reset", "continue"].contains(action) && confidence.isFinite &&
        (0...1).contains(confidence) && !reason.isEmpty && reason.utf8.count <= 512
    }
}

protocol RelayRotationPolicy: Sendable {
    func evaluate(_ input: RelayRotationPolicyInput) async throws -> RelayRotationPolicyDecision
}

enum RelayRotationControllerResult: Equatable, Sendable {
    case abstain(String)
    case continueSession
    case preparationRequested(epoch: String)
}

/// This phase requests a capsule; it never starts or retires a task. Execution
/// requires a later completed-turn watermark and the separate fenced executor.
actor RelayRotationController {
    private var pending = Set<String>()
    private struct ContextEnrollment: Sendable {
        let sourceThreadID: String
        let projectDir: String
        let client: String
        let enrolledAt: Date
        let inspection: Data
    }

    /// Context-only entry point. The reviewed policy supplies a rotate signal;
    /// preparation remains a distinct phase and still grants no lifecycle act.
    func evaluateContext(enrollment: RelayRotationEnrollment, status: Data,
                         turnSequence: Int, completedTurnID: String, backendIdle: Bool,
                         observedAt: Date, now: Date = Date(),
                         policy: any RelayContextRotationPolicy,
                         transport: any RelayRotationTransport) async -> RelayRotationControllerResult {
        guard enrollment.valid else { return .abstain("not_enrolled") }
        guard let inspection = try? json(["thread_id": enrollment.sourceThreadID,
            "cwd": enrollment.projectDir, "code_head": enrollment.codeHead]) else { return .abstain("invalid_binding") }
        return await evaluateContext(binding: ContextEnrollment(sourceThreadID: enrollment.sourceThreadID,
            projectDir: enrollment.projectDir, client: "codex", enrolledAt: enrollment.enrolledAt,
            inspection: inspection), status: status, turnSequence: turnSequence,
            completedTurnID: completedTurnID, backendIdle: backendIdle, observedAt: observedAt,
            now: now, policy: policy, transport: transport)
    }

    /// CLI launch identity is separate from app-server permission parameters.
    /// The current repository head is supplied at evaluation, not captured once.
    func evaluateContext(enrollment: RelayRetainedRotationEnrollment, codeHead: String,
                         status: Data, turnSequence: Int, completedTurnID: String,
                         backendIdle: Bool, observedAt: Date, now: Date = Date(),
                         policy: any RelayContextRotationPolicy,
                         transport: any RelayRotationTransport) async -> RelayRotationControllerResult {
        let codexProjectDir = enrollment.codexStart.flatMap {
            (try? object($0.parameters))?["cwd"] as? String
        }
        guard enrollment.valid,
              codeHead.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil,
              let snapshot = try? object(enrollment.snapshot), let launchCWD = snapshot["cwd"] as? String,
              let projectDir = enrollment.client == "codex" ? codexProjectDir : Optional(launchCWD),
              let inspection = try? json(["thread_id": enrollment.sessionID, "cwd": projectDir,
                "code_head": codeHead, "source_pane_id": enrollment.paneID,
                "source_pid": enrollment.processID, "source_process_start": enrollment.processStart])
        else { return .abstain("not_enrolled") }
        return await evaluateContext(binding: ContextEnrollment(sourceThreadID: enrollment.sessionID,
            projectDir: projectDir, client: enrollment.client, enrolledAt: enrollment.enrolledAt,
            inspection: inspection), status: status, turnSequence: turnSequence,
            completedTurnID: completedTurnID, backendIdle: backendIdle, observedAt: observedAt,
            now: now, policy: policy, transport: transport)
    }

    private func evaluateContext(binding enrollment: ContextEnrollment, status: Data,
                                 turnSequence: Int, completedTurnID: String, backendIdle: Bool,
                                 observedAt: Date, now: Date,
                                 policy: any RelayContextRotationPolicy,
                                 transport: any RelayRotationTransport) async -> RelayRotationControllerResult {
        guard now.timeIntervalSince(enrollment.enrolledAt) >= 30 else { return .abstain("enrollment_cooldown") }
        guard !pending.contains(enrollment.sourceThreadID) else { return .abstain("preparation_pending") }
        let metrics = RelayRotationMetricAdapter.contextStatus(status,
            expectedSessionID: enrollment.sourceThreadID, expectedTurnSequence: turnSequence,
            expectedTurnID: completedTurnID, expectedClient: enrollment.client, backendIdle: backendIdle,
            observedAt: observedAt, now: now)
        guard case let .ready(validatedStatus) = metrics else {
            if case let .abstain(reason) = metrics { return .abstain(reason) }
            return .abstain("metrics_unavailable")
        }
        pending.insert(enrollment.sourceThreadID)
        do {
            let decision = try object(await policy.evaluate(status: validatedStatus, now: now))
            guard decision["v"] as? Int == 1,
                  let action = decision["decision"] as? String,
                  ["rotate", "hold", "abstain"].contains(action) else {
                pending.remove(enrollment.sourceThreadID); return .abstain("invalid_policy")
            }
            if action != "rotate" {
                pending.remove(enrollment.sourceThreadID)
                return action == "hold" ? .continueSession : .abstain("policy_abstained")
            }
            let epoch = "turn-\(turnSequence)"
            guard decision["enforceable"] as? Bool == true,
                  let signal = decision["signal"] as? [String: Any],
                  signal["v"] as? Int == 1, signal["session_id"] as? String == enrollment.sourceThreadID,
                  signal["epoch"] as? String == epoch, signal["action"] as? String == "rotate",
                  let reason = signal["reason"] as? String, !reason.isEmpty, reason.utf8.count <= 512,
                  let usage = signal["usage"] as? [String: Any] else {
                pending.remove(enrollment.sourceThreadID); return .abstain("invalid_policy_signal")
            }
            let current = try object(await transport.ledger("rotation_status", arguments: json([
                "v": 1, "session_id": enrollment.sourceThreadID])))
            guard current["session_id"] as? String == enrollment.sourceThreadID,
                  current["owner"] as? String == "relay", current["client"] as? String == enrollment.client,
                  current["cwd"] as? String == enrollment.projectDir,
                  current["turn_seq"] as? Int == turnSequence,
                  current["signal"] is NSNull, current["claim"] is NSNull,
                  current["intent"] is NSNull, current["ack"] is NSNull else {
                pending.remove(enrollment.sourceThreadID); return .abstain("ledger_state_changed")
            }
            let inspected = try object(await transport.backend("inspect", arguments: enrollment.inspection))
            guard inspected["idle"] as? Bool == true, inspected["root"] as? Bool == true,
                  inspected["no_descendants"] as? Bool == true else {
                pending.remove(enrollment.sourceThreadID); return .abstain("backend_state_changed")
            }
            let prepared = try object(await transport.ledger("rotation_signal", arguments: json([
                "v": 1, "session_id": enrollment.sourceThreadID, "epoch": epoch,
                "action": "prepare", "reason": reason, "usage": usage])))
            guard prepared["v"] as? Int == 1,
                  prepared["session_id"] as? String == enrollment.sourceThreadID,
                  prepared["epoch"] as? String == epoch, prepared["action"] as? String == "prepare",
                  let sequence = prepared["seq"] as? Int, sequence > turnSequence else {
                return .abstain("preparation_outcome_unknown")
            }
            return .preparationRequested(epoch: epoch)
        } catch { return .abstain("preparation_outcome_unknown") }
    }

    func evaluate(enrollment: RelayRotationEnrollment, status: Data,
                  turnSequence: Int, completedTurnID: String, backendIdle: Bool, observedAt: Date,
                  now: Date = Date(), cost: RelayRotationCostObservation?,
                  policy: any RelayRotationPolicy,
                  transport: any RelayRotationTransport) async -> RelayRotationControllerResult {
        guard enrollment.valid else { return .abstain("not_enrolled") }
        guard now.timeIntervalSince(enrollment.enrolledAt) >= 30 else { return .abstain("enrollment_cooldown") }
        guard !pending.contains(enrollment.sourceThreadID) else { return .abstain("preparation_pending") }
        let metrics = RelayRotationMetricAdapter.adapt(status,
            expectedSessionID: enrollment.sourceThreadID, expectedTurnSequence: turnSequence,
            backendIdle: backendIdle, observedAt: observedAt, now: now, cost: cost,
            expectedTurnID: completedTurnID)
        guard case let .ready(input) = metrics else {
            if case let .abstain(reason) = metrics { return .abstain(reason) }
            return .abstain("metrics_unavailable")
        }
        // Consume the opportunity before suspension so a duplicate observation
        // cannot create competing policy calls or signals within this controller.
        pending.insert(enrollment.sourceThreadID)
        do {
            let decision = try await policy.evaluate(input)
            guard decision.valid else { pending.remove(enrollment.sourceThreadID); return .abstain("invalid_policy") }
            guard decision.action == "reset" else {
                pending.remove(enrollment.sourceThreadID); return .continueSession
            }
            // The context heuristic's 0.60 confidence remains advisory. The
            // initial automatic path admits only the reviewed high-confidence rule.
            guard decision.confidence >= 0.90, input.totalCostUSD >= 0.50 else {
                pending.remove(enrollment.sourceThreadID); return .abstain("policy_requires_review")
            }
            let current = try await transport.ledger("rotation_status", arguments: json([
                "v": 1, "session_id": enrollment.sourceThreadID]))
            let value = try object(current)
            guard value["session_id"] as? String == enrollment.sourceThreadID,
                  value["owner"] as? String == "relay", value["client"] as? String == "codex",
                  value["cwd"] as? String == enrollment.projectDir,
                  value["turn_seq"] as? Int == turnSequence,
                  value["signal"] is NSNull, value["claim"] is NSNull,
                  value["intent"] is NSNull, value["ack"] is NSNull else {
                pending.remove(enrollment.sourceThreadID); return .abstain("ledger_state_changed")
            }
            let inspected = try object(await transport.backend("inspect", arguments: json([
                "thread_id": enrollment.sourceThreadID, "cwd": enrollment.projectDir,
                "code_head": enrollment.codeHead])))
            guard inspected["idle"] as? Bool == true, inspected["root"] as? Bool == true,
                  inspected["no_descendants"] as? Bool == true else {
                pending.remove(enrollment.sourceThreadID); return .abstain("backend_state_changed")
            }
            // The daemon's idempotent key is (session, epoch, action). A stable
            // watermark key also deduplicates competing controller instances.
            let epoch = "relay-turn-\(turnSequence)"
            let prepared = try object(await transport.ledger("rotation_signal", arguments: json([
                "v": 1, "session_id": enrollment.sourceThreadID, "epoch": epoch,
                "action": "prepare", "reason": decision.reason,
                "usage": ["policy_input": try object(JSONEncoder().encode(input)),
                          "confidence": decision.confidence]])))
            guard prepared["v"] as? Int == 1,
                  prepared["session_id"] as? String == enrollment.sourceThreadID,
                  prepared["epoch"] as? String == epoch, prepared["action"] as? String == "prepare",
                  let sequence = prepared["seq"] as? Int, sequence > turnSequence else {
                return .abstain("preparation_outcome_unknown")
            }
            // A lost response or restart must inspect the durable ledger before
            // requesting anything else. No automatic retry is made here.
            return .preparationRequested(epoch: epoch)
        } catch {
            return .abstain("preparation_outcome_unknown")
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        return value
    }
    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
