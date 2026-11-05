import Foundation
import Testing
@testable import Relay

@Test func paneHealthHostControllerDecodesItsExactOwnerAndNativeObservations() throws {
    let pane = "11111111-2222-4333-8444-555555555555"
    let owner = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let wire: [String: Any] = ["v": 1, "status": "controller_status", "controller": "relayd",
        "supervisor_pid": 42, "supervisor_start_time": 99,
        "configuration": ["host_id": "owned-host", "owner_id": owner, "generation": 1,
                          "enabled": true, "haiku_enabled": true, "panes": [pane]],
        "state": ["generation": 1, "status": "Native host checks completed", "last_tick_at": 1800000000,
            "last_model_at": 1800000001, "model_operations": [String(repeating: "1", count: 32)],
            "observations": [pane: ["pane_id": pane, "observed_at": 1800000000,
                "input_contract": "desktop_native_verification_required", "proof": ["version": 1, "pane_id": pane,
                    "worker": ["worker_pid": 400, "worker_start": 900, "upgrade_mode": "in_place", "update_state": "current"],
                    "context": ["supported": true, "enabled": false, "state": "not_enrolled"]]]]]]
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let value = try decoder.decode(RelayPaneHealthHostControllerStatus.self, from: JSONSerialization.data(withJSONObject: wire))
    #expect(value.valid(host: "owned-host", owner: owner, paneIDs: [pane]))
    #expect(!value.valid(host: "another-host", owner: owner, paneIDs: [pane]))
    #expect(!value.valid(host: "owned-host", owner: UUID().uuidString.lowercased(), paneIDs: [pane]))
    #expect(!value.valid(host: "owned-host", owner: owner, paneIDs: [UUID().uuidString.lowercased()]))
    #expect(value.supervisorPid == 42 && value.supervisorStartTime == 99)
    #expect(value.state?.observations?[pane]?.paneId == pane)
    #expect(value.state?.observations?[pane]?.proof.paneID == pane)
    #expect(value.state?.observations?[pane]?.proof.worker?.workerPid == 400)
    #expect(value.state?.observations?[pane]?.proof.context?.enabled == false)
    #expect(value.state?.lastModelAt == 1800000001)
}

@Test func failedHostControllerReadNeverEstablishesOwnership() throws {
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let value = try decoder.decode(RelayPaneHealthHostControllerStatus.self,
        from: Data(#"{"v":1,"status":"failed","code":"controller_state_not_private"}"#.utf8))
    #expect(!value.valid(host: "owned-host", owner: UUID().uuidString.lowercased(), paneIDs: []))
}

@Test @MainActor func hostControllerNativeActionRejectsPIDReuseAndChangedConversation() {
    let base: [String: RelayPaneHealthJSON] = ["pane_id": .string("11111111-2222-4333-8444-555555555555"),
        "kind": .string("claude"), "connection": .string("connected"), "binding": .string("bound"),
        "identity_verified": .bool(true), "session_id": .string("original-session"), "process_id": .integer(1234),
        "process_start": .unsigned(3000), "observed_at": .integer(1800000000)]
    let before = RelayPaneHealthFacts.seal(base)
    var current = base
    current.removeValue(forKey: "observed_at")
    #expect(RelayPaneHealthCoordinator.controllerNativeSourceMatches(before, .seal(current)))
    current["process_start"] = .unsigned(3001)
    #expect(!RelayPaneHealthCoordinator.controllerNativeSourceMatches(before, .seal(current)))
    current = base; current["session_id"] = .string("another-session")
    #expect(!RelayPaneHealthCoordinator.controllerNativeSourceMatches(before, .seal(current)))
    current = base; current["binding"] = .string("unknown")
    #expect(!RelayPaneHealthCoordinator.controllerNativeSourceMatches(before, .seal(current)))
}

private let controllerPane = "11111111-2222-4333-8444-555555555555"
private let controllerOwner = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

private func controllerWire(generation: Int = 1, stateGeneration: Int = 1, pid: Int = 42,
    start: Int = 99, enabled: Bool = true, haiku: Bool = true, panes: [String] = [controllerPane],
    checks: [String] = []) -> [String: Any] {
    ["v": 1, "status": "controller_status", "controller": "relayd", "supervisor_pid": pid,
        "supervisor_start_time": start,
        "configuration": ["host_id": "owned-host", "owner_id": controllerOwner, "generation": generation,
            "enabled": enabled, "haiku_enabled": haiku, "panes": panes, "checks": checks],
        "state": ["generation": stateGeneration, "status": "Native host checks completed",
            "last_model_at": 1800000001, "report": ["panes": []], "action_requests": [:]]]
}

private func decodeController(_ wire: [String: Any]) throws -> RelayPaneHealthHostControllerStatus {
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(RelayPaneHealthHostControllerStatus.self,
        from: JSONSerialization.data(withJSONObject: wire))
}

@Test func hostControllerRejectsReplyAfterSettingsChangeCancellationOrDaemonRestart() throws {
    let scope = RelayPaneHealthControllerScope(host: "owned-host", owner: controllerOwner,
        panes: [controllerPane], enabled: true, haiku: true)
    let admitted = try decodeController(controllerWire())
    #expect(scope.accepts(admitted, currentDigest: scope.digest, cancelled: false))
    #expect(!scope.accepts(admitted, currentDigest: nil, cancelled: false))
    #expect(!scope.accepts(admitted, currentDigest: scope.digest, cancelled: true))
    #expect(!scope.accepts(admitted, currentDigest: scope.digest, cancelled: false, placementsCurrent: false))
    let disabled = RelayPaneHealthControllerScope(host: scope.host, owner: scope.owner,
        panes: scope.panes, enabled: false, haiku: false)
    #expect(!scope.accepts(admitted, currentDigest: disabled.digest, cancelled: false))
    let movedPane = RelayPaneHealthControllerScope(host: scope.host, owner: scope.owner,
        panes: [UUID().uuidString.lowercased()], enabled: true, haiku: true)
    #expect(!scope.accepts(admitted, currentDigest: movedPane.digest, cancelled: false))
    let replacement = try decodeController(controllerWire(pid: 43, start: 100))
    #expect(!scope.accepts(replacement, currentDigest: scope.digest, cancelled: false, admitted: admitted))
    let reusedPID = try decodeController(controllerWire(start: 100))
    #expect(!scope.accepts(reusedPID, currentDigest: scope.digest, cancelled: false, admitted: admitted))
    let reconfigured = try decodeController(controllerWire(generation: 2, stateGeneration: 2))
    #expect(!scope.accepts(reconfigured, currentDigest: scope.digest, cancelled: false, admitted: admitted))
    #expect(!scope.accepts(try decodeController(controllerWire(haiku: false)), currentDigest: scope.digest, cancelled: false))
}

@Test func hostControllerOldGenerationCannotSupplyReportsOrActions() throws {
    let value = try decodeController(controllerWire(generation: 2, stateGeneration: 1))
    #expect(value.valid(host: "owned-host", owner: controllerOwner, paneIDs: [controllerPane]))
    #expect(value.currentState == nil)
    #expect(try decodeController(controllerWire()).currentState?.lastModelAt == 1800000001)
}

@Test func hostControllerCurrentDaemonDoesNotDisplayLegacyGUIPendingWorkAsItsOwn() throws {
    let idle = try decodeController(controllerWire())
    let legacy = String(repeating: "a", count: 32)
    let check = String(repeating: "b", count: 32)
    #expect(RelayPaneHealthHostControllerStatus.pendingOperation(controller: idle, check: nil, legacy: legacy) == nil)
    #expect(RelayPaneHealthHostControllerStatus.pendingOperation(controller: idle, check: check, legacy: legacy) == check)
    #expect(RelayPaneHealthHostControllerStatus.pendingOperation(controller: nil, check: nil, legacy: legacy) == legacy)
    var wire = controllerWire()
    var state = wire["state"] as! [String: Any]
    state["pending"] = ["operation_id": "native-operation"]
    wire["state"] = state
    let active = try decodeController(wire)
    #expect(RelayPaneHealthHostControllerStatus.pendingOperation(controller: active, check: check, legacy: legacy) == "native-operation")
    state["generation"] = 0; wire["state"] = state
    let stale = try decodeController(wire)
    #expect(RelayPaneHealthHostControllerStatus.pendingOperation(controller: stale, check: nil, legacy: legacy) == nil)
}

@Test func hostControllerRejectsAmbiguousOrInvalidConfigurationReceipts() throws {
    for wire in [controllerWire(generation: 0), controllerWire(panes: [controllerPane, controllerPane]),
                 controllerWire(panes: ["AAAAAAAA-2222-4333-8444-555555555555"]), controllerWire(pid: 0), controllerWire(start: 0),
                 controllerWire(checks: ["invalid"]), controllerWire(checks: [String(repeating: "a", count: 32), String(repeating: "a", count: 32)])] {
        let value = try decodeController(wire)
        #expect(!value.valid(host: "owned-host", owner: controllerOwner, paneIDs: [controllerPane]))
    }
    #expect(throws: (any Error).self) { try decodeController(controllerWire(generation: -1)) }
}

@Test func hostControllerObservationRequiresCurrentTimeExactPaneAndSupportedContract() throws {
    let now = Date(timeIntervalSince1970: 1800000000)
    let pane = UUID(uuidString: controllerPane)!
    func observation(at: Double = 1800000000, proofPane: String? = nil,
        contract: String = "desktop_native_verification_required") throws -> RelayPaneHealthHostControllerStatus.Observation {
        var proof: [String: Any] = ["version": 1, "unavailable": "Native identity is unavailable"]
        if let proofPane { proof["pane_id"] = proofPane }
        let wire: [String: Any] = ["pane_id": controllerPane, "observed_at": at, "input_contract": contract, "proof": proof]
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RelayPaneHealthHostControllerStatus.Observation.self,
            from: JSONSerialization.data(withJSONObject: wire))
    }
    #expect(try observation().valid(paneID: pane, now: now))
    #expect(try !observation(at: 1799999700).valid(paneID: pane, now: now))
    #expect(try !observation(at: 1800000006).valid(paneID: pane, now: now))
    #expect(try !observation(proofPane: UUID().uuidString.lowercased()).valid(paneID: pane, now: now))
    #expect(try !observation(contract: "unknown_input_contract").valid(paneID: pane, now: now))
}

@Test func hostControllerExplicitCheckSurvivesBusySyncWithoutReplayingUncertainDispatch() {
    let now = Date(timeIntervalSince1970: 1800000000)
    let id = String(repeating: "a", count: 32)
    let queued = RelayPaneHealthControllerCheck(operationID: id, requestedAt: now.addingTimeInterval(-600), submitted: false)
    #expect(queued.disposition(recorded: [], now: now) == .queued)
    #expect(queued.disposition(recorded: [id], now: now) == .recorded)
    let oldJournal = RelayPaneHealthControllerCheck(operationID: id, requestedAt: now, submitted: nil)
    #expect(oldJournal.disposition(recorded: [], now: now) == .awaitingReceipt)
    #expect(oldJournal.disposition(recorded: [], now: now.addingTimeInterval(61)) == .unknown)
    let dispatched = RelayPaneHealthControllerCheck(operationID: id, requestedAt: now, submitted: true)
    #expect(dispatched.disposition(recorded: [], now: now) == .awaitingReceipt)
    #expect(dispatched.disposition(recorded: [String(repeating: "b", count: 32)], now: now) != .recorded)
    #expect(dispatched.disposition(recorded: [id], now: now) == .recorded)
}

@Test @MainActor func hostControllerReconnectUsesRetainedViewerFactsWithoutAnAgentProbe() {
    let before: [String: RelayPaneHealthJSON] = ["pane_id": .string(controllerPane), "kind": .string("claude"),
        "connection": .string("disconnected"), "binding": .string("unknown"), "identity_verified": .bool(false),
        "allowed_actions": .array([.string("observe"), .string("attention"), .string("reconnect")]),
        "observed_at": .integer(1800000000)]
    let request = RelayPaneHealthFacts.seal(before)
    var current = before; current.removeValue(forKey: "observed_at")
    #expect(request.evidenceID != RelayPaneHealthFacts.seal(current).evidenceID)
    #expect(RelayPaneHealthCoordinator.controllerReconnectIsAdmissible(request, .seal(current)))
    current["connection"] = .string("connected")
    #expect(!RelayPaneHealthCoordinator.controllerReconnectIsAdmissible(request, .seal(current)))
    current = before; current["allowed_actions"] = .array([.string("observe"), .string("attention")])
    #expect(!RelayPaneHealthCoordinator.controllerReconnectIsAdmissible(request, .seal(current)))
    current = before; current["kind"] = .string("codex")
    #expect(!RelayPaneHealthCoordinator.controllerReconnectIsAdmissible(request, .seal(current)))
}

@Test func hostControllerLostAcknowledgementKeepsExactResultAndRejectsReusedActionIdentity() throws {
    let call = RelayPaneHealthToolCall(type: "tool_use", id: "owned-tool", name: "apply_installed_update",
        input: .object(["pane_id": .string(controllerPane), "evidence_id": .string(String(repeating: "f", count: 64))]))
    func request(generation: UInt64 = 1, before: RelayPaneHealthJSON = .object(["process_id": .integer(1234)]),
        state: String = "pending_native") -> RelayPaneHealthHostControllerStatus.ActionRequest {
        .init(id: String(repeating: "a", count: 32), operationId: String(repeating: "b", count: 32),
            generation: generation, call: call, before: before, state: state)
    }
    let original = request()
    let result = RelayPaneHealthJSON.object(["state": .string("already_healthy"),
        "message": .string("Original native result"), "pane": .object(["process_id": .integer(1234)])])
    let saved = RelayPaneHealthControllerActionReceipt(request: original, host: "owned-host", owner: controllerOwner, result: result)
    let restored = try JSONDecoder().decode(RelayPaneHealthControllerActionReceipt.self, from: JSONEncoder().encode(saved))
    #expect(restored.result == result)
    #expect(restored.matches(original, host: "owned-host", owner: controllerOwner))
    #expect(!restored.matches(request(generation: 2), host: "owned-host", owner: controllerOwner))
    #expect(!restored.matches(request(before: .object(["process_id": .integer(1235)])), host: "owned-host", owner: controllerOwner))
    #expect(!restored.matches(original, host: "another-host", owner: controllerOwner))
    #expect(!restored.matches(original, host: "owned-host", owner: UUID().uuidString.lowercased()))
    #expect(!restored.canForget(currentGeneration: 1, requests: []))
    #expect(!restored.canForget(currentGeneration: 2, requests: []))
    var acknowledged = restored; acknowledged.acknowledged = true
    #expect(!acknowledged.canForget(currentGeneration: 1, requests: [original]))
    #expect(acknowledged.canForget(currentGeneration: 1, requests: [request(state: "completed")]))
    #expect(acknowledged.canForget(currentGeneration: 2, requests: []))
}

@Test @MainActor func hostControllerSupersededTaskCannotEraseItsReplacement() async throws {
    let tasks = RelayPaneHealthControllerTasks()
    let (started, notices) = AsyncStream<Int>.makeStream()
    var events = started.makeAsyncIterator()
    var resumeOld: CheckedContinuation<Void, Never>?
    var resumeNew: CheckedContinuation<Void, Never>?
    var oldFinished = false
    var duplicateStarted = false
    let old = tasks.start(host: "owned-host", scope: "old-configuration") {
        // An already admitted native action can finish after cancellation.
        await withCheckedContinuation { resumeOld = $0; notices.yield(1) }
        oldFinished = true
        #expect(Task.isCancelled)
    }
    #expect(await events.next() == 1)
    let replacement = tasks.start(host: "owned-host", scope: "new-configuration") {
        await withCheckedContinuation { resumeNew = $0; notices.yield(2) }
        #expect(!Task.isCancelled)
    }
    #expect(await events.next() == 2)
    #expect(old.isCancelled)
    #expect(!oldFinished)
    #expect(tasks.scope(for: "owned-host") == "new-configuration")
    let joined = tasks.start(host: "owned-host", scope: "new-configuration") { duplicateStarted = true }
    try #require(resumeOld).resume()
    await old.value
    #expect(oldFinished)
    #expect(tasks.scope(for: "owned-host") == "new-configuration")
    #expect(!duplicateStarted)
    try #require(resumeNew).resume()
    await replacement.value
    await joined.value
    #expect(tasks["owned-host"] == nil)
    #expect(!duplicateStarted)
    notices.finish()
}

@Test func hostControllerReplyWithFloatTimestampsDecodesThroughTransportEnvelope() throws {
    // Both the Python and Go controllers emit time.time() floats. The RPC first
    // decodes the whole envelope as RelayPaneHealthJSON, which must keep them.
    let pane = "11111111-2222-4333-8444-555555555555"
    let owner = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let raw = Data(("""
    {"request_id":"rpc-1","result":{"v":1,"status":"controller_status","controller":"relayd",
     "supervisor_pid":42,"supervisor_start_time":1792151059130068,"next_check_seconds":120,
     "configuration":{"host_id":"owned-host","owner_id":"\(owner)","generation":4,"enabled":true,
      "haiku_enabled":true,"panes":["\(pane)"],"configured_at":1792149222.451235},
     "state":{"generation":4,"status":"ok","last_tick_at":1792151308.01098,"last_model_at":1792149232.631014,
      "report":{"score":0.5},"action_requests":{}}}}
    """).utf8)
    let envelope = try JSONDecoder().decode(RelayPaneHealthJSON.self, from: raw)
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let value = try decoder.decode(RelayPaneHealthHostControllerStatus.self,
        from: RelayPaneHealthJSON.data(try #require(envelope["result"])))
    #expect(value.valid(host: "owned-host", owner: owner, paneIDs: [pane]))
    #expect(value.currentState?.lastModelAt == 1792149232.631014)
    #expect(value.currentState?.report?["score"] == .double(0.5))
    #expect(try JSONDecoder().decode(RelayPaneHealthJSON.self, from: Data("7".utf8)) == .integer(7))
}
