import Foundation
import CryptoKit
import Testing
@testable import Relay

private struct RotationControllerPolicy: RelayRotationPolicy {
    let confidence: Double
    let action: String
    func evaluate(_ input: RelayRotationPolicyInput) async throws -> RelayRotationPolicyDecision {
        RelayRotationPolicyDecision(action: action, reason: "fixture decision", confidence: confidence)
    }
}

private struct RotationControllerContextPolicy: RelayContextRotationPolicy {
    let signalSession: String
    func evaluate(status: Data, now: Date) async throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": 1, "decision": "rotate", "enforceable": true,
            "signal": ["v": 1, "session_id": signalSession, "epoch": "turn-12", "action": "rotate",
                       "reason": "fixture context economics", "usage": ["units": "token equivalents"]]])
    }
}

private actor RotationControllerTransport: RelayRotationTransport {
    var calls: [String] = []
    let owner: String
    let client: String
    let lostSignal: Bool
    init(owner: String = "relay", lostSignal: Bool = false, client: String = "codex") {
        self.owner = owner; self.lostSignal = lostSignal; self.client = client
    }
    func ledger(_ operation: String, arguments: Data) async throws -> Data {
        calls.append(operation)
        if operation == "rotation_status" {
            return try JSONSerialization.data(withJSONObject: ["session_id": "exact-session",
                "owner": owner, "client": client, "cwd": "/fixture", "turn_seq": 12,
                "signal": NSNull(), "claim": NSNull(), "intent": NSNull(), "ack": NSNull()])
        }
        if lostSignal { throw RelayRotationAdapterError.mismatchedEvidence }
        var result = try #require(JSONSerialization.jsonObject(with: arguments) as? [String: Any])
        result["seq"] = 13
        return try JSONSerialization.data(withJSONObject: result)
    }
    func backend(_ operation: String, arguments: Data) async throws -> Data {
        calls.append("backend:\(operation)")
        return Data(#"{"idle":true,"root":true,"no_descendants":true}"#.utf8)
    }
}

@Suite struct RelayRotationControllerTests {
    let now = Date(timeIntervalSince1970: 100)
    func enrollment() throws -> RelayRotationEnrollment {
        RelayRotationEnrollment(sourceThreadID: "exact-session", projectDir: "/fixture",
            codeHead: String(repeating: "a", count: 40), socketPath: "/fixture/socket",
            socketDevice: 1, socketInode: 2,
            sourceStartParameters: Data(#"{"cwd":"/fixture","model":"test-model","approvalPolicy":"on-request","sandbox":"read-only"}"#.utf8),
            enrolledAt: Date(timeIntervalSince1970: 0))
    }
    func status(client: String = "codex") throws -> Data {
        let counters: [String: Any] = ["input": 100, "cached_input": 90, "uncached_input": 10, "output": 10]
        var session = counters; session["turns"] = 4; session["responses"] = 8
        let usage: [String: Any] = ["turn": counters, "session": session, "context_tokens": 100,
            "model": "test-model", "in_flight_tool": ["value": false, "provenance": "transcript"],
            "client": ["value": client, "provenance": "hook"],
            "transcript_mtime_ms_at_stop": ["value": 99_000, "provenance": "hook"],
            "turn_id_fresh": ["value": true, "provenance": "transcript"]]
        return try JSONSerialization.data(withJSONObject: ["v": 1, "session_id": "exact-session", "client": client,
            "turn_seq": 12, "usage": usage, "usage_history": [["seq": 12,
                "session_id": "exact-session", "turn_id": "turn-4", "usage": usage]]])
    }
    private func evaluate(_ controller: RelayRotationController, _ transport: RotationControllerTransport,
                  cost: Double? = 0.60, confidence: Double = 0.95,
                  action: String = "reset") async throws -> RelayRotationControllerResult {
        await controller.evaluate(enrollment: try enrollment(), status: try status(), turnSequence: 12,
            completedTurnID: "turn-4", backendIdle: true, observedAt: now, now: now,
            cost: cost.map { RelayRotationCostObservation(sessionID: "exact-session", turnSequence: 12,
                model: "test-model", totalCostUSD: $0, lastTurnCostUSD: nil, provenance: "measured_billing") },
            policy: RotationControllerPolicy(confidence: confidence, action: action), transport: transport)
    }
    @Test func missingCostAndHeuristicCannotWriteLedger() async throws {
        let transport = RotationControllerTransport()
        #expect(try await evaluate(RelayRotationController(), transport, cost: nil) == .abstain("measured_cost_absent"))
        #expect(try await evaluate(RelayRotationController(), transport, confidence: 0.60) == .abstain("policy_requires_review"))
        #expect(try await evaluate(RelayRotationController(), transport, cost: 0.20) == .abstain("policy_requires_review"))
        #expect(await transport.calls.isEmpty)
    }
    @Test func desktopOwnershipCannotBePromotedByPolicy() async throws {
        let transport = RotationControllerTransport(owner: "desktop")
        #expect(try await evaluate(RelayRotationController(), transport) == .abstain("ledger_state_changed"))
        #expect(await transport.calls == ["rotation_status"])
    }
    @Test func successfulDecisionOnlyPreparesWithStableEpoch() async throws {
        let controller = RelayRotationController(), transport = RotationControllerTransport()
        #expect(try await evaluate(controller, transport) == .preparationRequested(epoch: "relay-turn-12"))
        #expect(await transport.calls == ["rotation_status", "backend:inspect", "rotation_signal"])
        #expect(try await evaluate(controller, transport) == .abstain("preparation_pending"))
        #expect(await transport.calls.count == 3)
    }
    @Test func unknownSignalOutcomeIsNeverRetried() async throws {
        let controller = RelayRotationController(), transport = RotationControllerTransport(lostSignal: true)
        #expect(try await evaluate(controller, transport) == .abstain("preparation_outcome_unknown"))
        #expect(try await evaluate(controller, transport) == .abstain("preparation_pending"))
        #expect(await transport.calls.filter { $0 == "rotation_signal" }.count == 1)
    }
    @Test func continueIsReadOnly() async throws {
        let transport = RotationControllerTransport()
        #expect(try await evaluate(RelayRotationController(), transport, action: "continue") == .continueSession)
        #expect(await transport.calls.isEmpty)
    }
    @Test func contextOnlyPolicyNeedsNoDollarEvidence() async throws {
        let controller = RelayRotationController(), transport = RotationControllerTransport()
        let result = await controller.evaluateContext(enrollment: try enrollment(), status: try status(),
            turnSequence: 12, completedTurnID: "turn-4", backendIdle: true, observedAt: now, now: now,
            policy: RotationControllerContextPolicy(signalSession: "exact-session"), transport: transport)
        #expect(result == .preparationRequested(epoch: "turn-12"))
        #expect(await transport.calls == ["rotation_status", "backend:inspect", "rotation_signal"])
    }
    @Test func contextPolicyCannotSubstituteForeignSession() async throws {
        let controller = RelayRotationController(), transport = RotationControllerTransport()
        let result = await controller.evaluateContext(enrollment: try enrollment(), status: try status(),
            turnSequence: 12, completedTurnID: "turn-4", backendIdle: true, observedAt: now, now: now,
            policy: RotationControllerContextPolicy(signalSession: "other-session"), transport: transport)
        #expect(result == .abstain("invalid_policy_signal"))
        #expect(await transport.calls.isEmpty)
    }

    @Test func retainedClaudeEnrollmentUsesClaudeLedgerAndRejectsCodexLedger() async throws {
        let pane = UUID().uuidString
        let snapshot = try JSONSerialization.data(withJSONObject: ["schema": 1, "client": "claude",
            "pid": 42, "process_start": "123", "relay_pane_id": pane, "cwd": "/fixture",
            "executable": "/bin/claude", "launch_id": "fixture", "effective_args": [String](),
            "arguments": ["reusable": true]])
        let payload = try JSONSerialization.data(withJSONObject: ["session_id": "exact-session",
            "pane_id": pane, "source_pid": 42, "source_start": "123", "cwd": "/fixture",
            "model": "fixture-model", "effort": "high", "permission_mode": "auto",
            "fresh_args": ["--model", "fixture-model"]])
        let value = RelayRetainedRotationEnrollment(sessionID: "exact-session", client: "claude",
            hostID: "fixture-host", paneID: pane, processID: 42, processStart: "123",
            snapshotPath: "/private/snapshot.json",
            snapshotSHA256: SHA256.hash(data: snapshot).map { String(format: "%02x", $0) }.joined(),
            snapshot: snapshot, enrolledAt: Date(timeIntervalSince1970: 0),
            claudeStart: RelayClaudeStartConfiguration(sourceSessionID: "exact-session",
                sourcePID: 42, sourceProcessStart: "123", payload: payload,
                sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                capturedAt: Date(timeIntervalSince1970: 0)))
        let transport = RotationControllerTransport(client: "claude")
        let result = await RelayRotationController().evaluateContext(enrollment: value,
            codeHead: String(repeating: "b", count: 40), status: try status(client: "claude"),
            turnSequence: 12, completedTurnID: "turn-4", backendIdle: true, observedAt: now, now: now,
            policy: RotationControllerContextPolicy(signalSession: "exact-session"), transport: transport)
        #expect(result == .preparationRequested(epoch: "turn-12"))
        let wrong = RotationControllerTransport(client: "codex")
        let rejected = await RelayRotationController().evaluateContext(enrollment: value,
            codeHead: String(repeating: "b", count: 40), status: try status(client: "claude"),
            turnSequence: 12, completedTurnID: "turn-4", backendIdle: true, observedAt: now, now: now,
            policy: RotationControllerContextPolicy(signalSession: "exact-session"), transport: wrong)
        #expect(rejected == .abstain("ledger_state_changed"))
        #expect(await wrong.calls == ["rotation_status"])
    }
}
