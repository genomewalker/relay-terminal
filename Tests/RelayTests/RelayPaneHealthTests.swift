import AppKit
import Foundation
import Testing
@testable import Relay

private let healthPaneID = "0e426bf7-58ab-4e0b-a521-b2400a8989aa"

@Test func paneHealthNativeMetadataSurvivesTheMaintenanceDecoder() throws {
    let wire = #"{"version":1,"worker":{"worker_pid":42,"worker_start":99,"upgrade_mode":"in_place","update_state":"current","running_sha256":"same","installed_sha256":"same"},"context":{"supported":true,"enabled":false,"state":"not_enrolled","generation":0,"lifecycle":"unavailable","refresh_capability":"unverified"}}"#
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let proof = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(wire.utf8))
    #expect(proof.worker?.workerPid == 42)
    #expect(proof.worker?.upgradeMode == "in_place")
    #expect(proof.worker?.updateState == "current")
    #expect(proof.context?.state == "not_enrolled")
    #expect(proof.context?.enabled == false)
    #expect(proof.context?.refreshCapability == "unverified")
}

@MainActor @Test func paneHealthEndedTerminalIsDistinctFromItsConnectedTransport() throws {
    _ = NSApplication.shared
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try #require(workspace.activePaneID.flatMap { workspace.panes[$0] })
    pane.connected()
    // relayd's exit status always carries a code (TerminalRuntime passes ?? 0).
    pane.exited(exitCode: 0)
    #expect(pane.remoteExitCode == 0)
    #expect(pane.phase == .exited)
    let coordinator = RelayPaneHealthCoordinator(url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json"))
    coordinator.heartbeat(workspace)
    let host = try #require(coordinator.snapshot().hosts.first)
    #expect(host.endedPanes == 1)
    #expect(host.livePanes.first?.observationState == "exited")
    let facts = try #require(host.livePanes.first?.facts)
    #expect(facts.value["connection"]?.string == "disconnected")
    #expect(!facts.allowedActions.contains("reconnect"))
}

/// A lost connection marks the agent phase exited, but the program may still
/// run in its retained worker: health must not report it ended, and must
/// offer the retained-worker reconnect that the coordinator performs.
@MainActor @Test func paneHealthLostTransportIsNotAProgramExit() throws {
    _ = NSApplication.shared
    let oldMaintenance = RelayPreferences.shared.automaticAgentMaintenance
    RelayPreferences.shared.automaticAgentMaintenance = true
    defer { RelayPreferences.shared.automaticAgentMaintenance = oldMaintenance }
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try #require(workspace.activePaneID.flatMap { workspace.panes[$0] })
    pane.connected()
    pane.disconnected("Owned transport loss")
    #expect(pane.phase == .exited)
    #expect(pane.remoteExitCode == nil)
    #expect(!pane.programExited)
    let coordinator = RelayPaneHealthCoordinator(url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json"))
    coordinator.heartbeat(workspace)
    let host = try #require(coordinator.snapshot().hosts.first)
    #expect(host.endedPanes == 0)
    #expect(host.livePanes.first?.observationState == "connection_unavailable")
    let facts = try #require(host.livePanes.first?.facts)
    #expect(facts.value["connection"]?.string == "disconnected")
    #expect(facts.allowedActions.contains("reconnect"))

    // The program's own exit, reported while disconnected, still ends it.
    pane.exited(exitCode: 1)
    #expect(pane.programExited)
    coordinator.heartbeat(workspace)
    let ended = try #require(coordinator.snapshot().hosts.first)
    #expect(ended.livePanes.first?.observationState == "exited")
    #expect(!(ended.livePanes.first?.facts.allowedActions.contains("reconnect") ?? true))
}

@MainActor @Test func paneHealthNativeCoverageIncludesShellsWithoutClaimingHeartbeatAsObservation() throws {
    _ = NSApplication.shared
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try #require(workspace.activePaneID.flatMap { workspace.panes[$0] })
    pane.connected()
    let coordinator = RelayPaneHealthCoordinator(url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json"))
    let now = Date()
    coordinator.heartbeat(workspace, now: now)
    let initial = try #require(coordinator.snapshot(now: now).hosts.first)
    #expect(initial.panes == 1)
    #expect(initial.lastHeartbeatAt == now)
    #expect(initial.lastObservedAt == nil)
    #expect(initial.freshObservations == 0)
    #expect(initial.livePanes.first?.observationState == "not_checked")
    #expect(coordinator.monitoredContexts()[pane.id] != nil)
    coordinator.observe(pane, proof: RelayAgentMaintenanceProbe(version: 1, unavailable: "Owned unavailable proof"), now: now)
    let checked = try #require(coordinator.snapshot(now: now).hosts.first)
    #expect(checked.freshObservations == 1)
    #expect(checked.livePanes.first?.observationState == "unavailable")
    #expect(checked.livePanes.first?.facts.value["identity_verified"]?.boolean == false)
    let stale = try #require(coordinator.snapshot(now: now.addingTimeInterval(301)).hosts.first)
    #expect(stale.freshObservations == 0)
    #expect(stale.livePanes.first?.observationState == "stale")
    #expect(stale.lastObservedAt == now)
}

@MainActor @Test func paneHealthExpiredEvidenceRequiresInspectionWithoutInventingARecurringFault() throws {
    _ = NSApplication.shared
    let pane = PaneModel(profile: .local)
    pane.connected()
    let wire = #"{"version":1,"pane_id":"PANE_UUID","provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","bound":true,"lifecycle":"quiet","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"PANE_UUID","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":false,"resume_command":"/owned/codex resume exact-session"}"#
        .replacingOccurrences(of: "PANE_UUID", with: pane.id.uuidString.lowercased())
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let proof = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(wire.utf8))
    let coordinator = RelayPaneHealthCoordinator(url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json"))
    let observedAt = Date()
    coordinator.observe(pane, proof: proof, now: observedAt)
    let fresh = coordinator.facts(pane, now: observedAt)
    let expired = coordinator.facts(pane, now: observedAt.addingTimeInterval(301))
    let scheduling = coordinator.facts(pane, now: observedAt.addingTimeInterval(301), forScheduling: true)
    #expect(fresh.value["identity_verified"]?.boolean == true)
    #expect(expired.value["identity_verified"]?.boolean == false)
    #expect(RelayPaneHealthCoordinator.healthSignal([fresh]) == RelayPaneHealthCoordinator.healthSignal([scheduling]))
    pane.disconnected("Owned scheduling check")
    #expect(RelayPaneHealthCoordinator.healthSignal([fresh]) != RelayPaneHealthCoordinator.healthSignal([
        coordinator.facts(pane, forScheduling: true)]))
}

@MainActor @Test func paneHealthCapturedHostIdentifiersAcceptLocalAndSSHConnectionKeys() {
    let keys = [ConnectionProfile.local.connectionKey,
                ConnectionProfile.sshConfigHost("dandy-07").connectionKey,
                "ssh:researcher@[2001:db8::1]:22"]
    let identifiers = keys.map { RelayPaneHealthCoordinator.rpcHostID($0) }
    #expect(Set(identifiers).count == keys.count)
    for identifier in identifiers {
        #expect(identifier.range(of: #"^host-[a-f0-9]{64}$"#, options: .regularExpression) != nil)
    }
}

private func healthFacts() -> RelayPaneHealthFacts {
    RelayPaneHealthFacts.seal([
        "pane_id": .string(healthPaneID), "kind": .string("codex"),
        "connection": .string("connected"), "binding": .string("bound"), "activity": .string("quiet"),
        "identity_verified": .bool(true), "prompt_empty": .bool(true), "has_draft": .bool(false),
        "pending_approvals": .integer(0), "input_idle": .bool(true), "installed_update": .bool(false),
        "session_id": .string("exact-session"), "process_id": .integer(123), "process_start": .unsigned(456),
        "allowed_actions": .array([.string("observe"), .string("attention")]),
    ])
}

@Test func paneHealthJSONPreservesExactProcessStartIntegers() throws {
    let original = RelayPaneHealthJSON.object(["start": .unsigned(UInt64.max), "safe": .bool(true)])
    let data = try RelayPaneHealthJSON.data(original)
    let decoded = try JSONDecoder().decode(RelayPaneHealthJSON.self, from: data)
    #expect(decoded == original)
    #expect(String(decoding: data, as: UTF8.self).contains("18446744073709551615"))
}

@Test func paneHealthEvidenceChangesWithNativeSafetyFacts() throws {
    let original = healthFacts()
    guard case .object(var changed) = original.value else { Issue.record("missing facts"); return }
    changed["has_draft"] = .bool(true)
    #expect(RelayPaneHealthFacts.seal(changed).evidenceID != original.evidenceID)
    changed["has_draft"] = .bool(false)
    #expect(RelayPaneHealthFacts.seal(changed).evidenceID == original.evidenceID)
}

@MainActor @Test func paneHealthReportRejectsStaleOrDifferentPaneEvidenceAndInventedActions() {
    let fact = healthFacts()
    func report(_ id: String = healthPaneID, evidence: String? = nil, action: String = "observe") -> RelayPaneHealthJSON {
        .object(["panes": .array([.object(["pane_id": .string(id), "evidence_id": .string(evidence ?? fact.evidenceID),
            "health": .string("healthy"), "action": .string(action), "reason": .string("Native binding is healthy.")])])])
    }
    #expect(RelayPaneHealthCoordinator.validReport(report(), original: [fact], inspected: [:]))
    #expect(!RelayPaneHealthCoordinator.validReport(report(evidence: String(repeating: "0", count: 64)), original: [fact], inspected: [:]))
    #expect(!RelayPaneHealthCoordinator.validReport(report("11111111-1111-1111-1111-111111111111"), original: [fact], inspected: [:]))
    #expect(!RelayPaneHealthCoordinator.validReport(report(action: "repair_link"), original: [fact], inspected: [:]))
    #expect(!RelayPaneHealthCoordinator.validReport(.object(["panes": .array([])]), original: [fact], inspected: [:]))
}

@MainActor @Test func paneHealthSuccessfulReportRequiresVerifiedConnectedIdentity() {
    let good = healthFacts()
    guard case .object(let original) = good.value else { return }
    func valid(_ changes: [String: RelayPaneHealthJSON], state: String = "healthy") -> Bool {
        let fact = RelayPaneHealthFacts.seal(original.merging(changes, uniquingKeysWith: { _, new in new }))
        let report = RelayPaneHealthJSON.object(["panes": .array([.object([
            "pane_id": .string(healthPaneID), "evidence_id": .string(fact.evidenceID),
            "health": .string(state), "action": .string("observe"), "reason": .string("Native health evidence.")])])])
        return RelayPaneHealthCoordinator.validReport(report, original: [fact], inspected: [:])
    }
    #expect(valid([:]))
    #expect(!valid(["identity_verified": .bool(false)]))
    #expect(!valid(["binding": .string("unbound")]))
    #expect(!valid(["connection": .string("disconnected")]))
    #expect(!valid([:], state: "working"))
    #expect(valid(["activity": .string("working")], state: "working"))
    let shell: [String: RelayPaneHealthJSON] = ["kind": .string("shell"), "binding": .string("not_applicable")]
    #expect(valid(shell))
    #expect(!valid(shell, state: "working"))
}

@MainActor @Test func paneHealthBudgetRefusalIsBoundToTheExactUnsubmittedRequest() throws {
    let operation = String(repeating: "1", count: 32)
    func receipt(_ status: String = "refused", code: String = "spending_limit", identity: String? = nil) throws -> RelayPaneHealthStep {
        let wire = RelayPaneHealthJSON.object(["v": .integer(1), "operation_id": .string(identity ?? operation),
            "status": .string(status), "code": .string(code)])
        return try JSONDecoder().decode(RelayPaneHealthStep.self, from: RelayPaneHealthJSON.data(wire))
    }
    #expect(RelayPaneHealthCoordinator.preflightRefusal(try receipt(), operationID: operation)?.contains("spending limit") == true)
    #expect(RelayPaneHealthCoordinator.preflightRefusal(try receipt(code: "no_ready_account"), operationID: operation)?.contains("No configured API account") == true)
    #expect(RelayPaneHealthCoordinator.preflightRefusal(try receipt(identity: String(repeating:"2",count:32)), operationID: operation) == nil)
    #expect(RelayPaneHealthCoordinator.preflightRefusal(try receipt("uncertain"), operationID: operation) == nil)
    #expect(RelayPaneHealthCoordinator.preflightRefusal(try receipt(code:"journal_or_backend_unavailable"), operationID: operation) == nil)
}

@MainActor @Test func paneHealthStepRequiresExactHostSnapshotAndActualToolCallContent() throws {
    let fact = healthFacts(), host = "config:unit-host", operation = String(repeating: "1", count: 32)
    let snapshot = RelayPaneHealthCoordinator.snapshotID(host: host, panes: [fact])
    let evidence = RelayPaneHealthJSON.object(["panes": .array([fact.value]), "messages": .array([])])
    let call = RelayPaneHealthJSON.object(["type": .string("tool_use"), "id": .string("toolu_check"),
        "name": .string("inspect_pane"), "input": .object(["pane_id": .string(healthPaneID)])])
    let backend = RelayPaneHealthJSON.object([
        "v": .integer(1), "status": .string("health_step"), "operation_id": .string(operation),
        "purpose": .string("pane_health"), "provider": .string("anthropic_api"),
        "model": .string("claude-haiku-5-5"), "effort": .string("low"), "thinking": .string("disabled"),
        "binding": .object(["host_id": .string(host), "snapshot_id": .string(snapshot)]),
        "source_sha256": .string(RelayPaneHealthJSON.digest(evidence)),
        "assistant_content": .array([call]), "tool_calls": .array([call]),
    ])
    let outer = RelayPaneHealthJSON.object(["v": .integer(1), "status": .string("complete"),
        "operation_id": .string(operation), "result": backend, "charged_microusd": .integer(20)])
    let step = try JSONDecoder().decode(RelayPaneHealthStep.self, from: RelayPaneHealthJSON.data(outer))
    #expect(step.valid(operationID: operation, host: host, snapshot: snapshot, evidence: evidence, paneIDs: [healthPaneID]))
    #expect(!step.valid(operationID: operation, host: "config:other", snapshot: snapshot, evidence: evidence, paneIDs: [healthPaneID]))
    #expect(!step.valid(operationID: operation, host: host, snapshot: String(repeating: "0", count: 64), evidence: evidence, paneIDs: [healthPaneID]))
    #expect(!step.valid(operationID: String(repeating: "2", count: 32), host: host, snapshot: snapshot, evidence: evidence, paneIDs: [healthPaneID]))
}

@MainActor @Test func paneHealthUnknownActionCanOnlyCloseFromItsExactNativePostcondition() {
    let current = healthFacts()
    let receipt = RelayPaneHealthCoordinator.ToolReceipt(id: "host:toolu_update", operationID: String(repeating: "1", count: 32),
        host: "host", paneID: healthPaneID, name: "apply_installed_update", inputDigest: current.evidenceID,
        before: current, createdAt: Date(), state: "verification_unknown", result: nil)
    #expect(RelayPaneHealthCoordinator.postcondition(receipt, current: current, imageVerified: true))
    // A resumed process on another image, or without image proof, never closes an update.
    #expect(!RelayPaneHealthCoordinator.postcondition(receipt, current: current, imageVerified: false))
    guard case .object(var changed) = current.value else { return }
    changed["session_id"] = .string("a-different-session")
    #expect(!RelayPaneHealthCoordinator.postcondition(receipt, current: .seal(changed), imageVerified: true))
    changed["session_id"] = .string("exact-session"); changed["installed_update"] = .bool(true)
    #expect(!RelayPaneHealthCoordinator.postcondition(receipt, current: .seal(changed), imageVerified: true))
    changed["installed_update"] = .bool(false); changed["binding"] = .string("unbound")
    #expect(!RelayPaneHealthCoordinator.postcondition(receipt, current: .seal(changed), imageVerified: true))
}

@MainActor @Test func paneHealthNormalTypingDoesNotScheduleAnotherModelPassForAHealthyPane() {
    let original = healthFacts()
    guard case .object(var changed) = original.value else { return }
    changed["has_draft"] = .bool(true); changed["prompt_empty"] = .bool(false); changed["activity"] = .string("working")
    #expect(RelayPaneHealthCoordinator.healthSignal([original]) == RelayPaneHealthCoordinator.healthSignal([.seal(changed)]))
    changed["installed_update"] = .bool(true)
    #expect(RelayPaneHealthCoordinator.healthSignal([original]) != RelayPaneHealthCoordinator.healthSignal([.seal(changed)]))
}

@Test @MainActor func retainedShellHealthHasNoAgentRestartAuthority() throws {
    let pane = PaneModel(profile: .local)
    pane.setAgentKind(.codex)
    let wire = #"{"version":1,"pane_id":"PANE","provider":"shell","process_id":12,"process_start":13,"installed_update":false,"owner":{"version":1,"pane_id":"PANE","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"shell","process_id":12,"process_start":13}}"#
        .replacingOccurrences(of: "PANE", with: pane.id.uuidString.lowercased())
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    var proof = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(wire.utf8))
    #expect(proof.validShell(for: pane.id))
    #expect(!proof.valid(for: pane.id))
    let facts = RelayPaneHealthFacts.read(pane, proof: proof)
    #expect(facts.value["kind"]?.string == "shell")
    #expect(facts.value["identity_verified"]?.boolean == true)
    #expect(facts.value["binding"]?.string == "not_applicable")
    #expect(!facts.allowedActions.contains("repair_link"))
    #expect(!facts.allowedActions.contains("apply_update"))
    proof.processStart = 14
    #expect(!proof.validShell(for: pane.id))
}

@Test @MainActor func paneHealthUsesTheVerifiedProviderAndBackgroundActivityInsteadOfAnOldPaneLabel() throws {
    let pane = PaneModel(profile: .local)
    pane.connected()
    let wire = #"{"version":1,"pane_id":"PANE","provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","bound":true,"lifecycle":"active","background_work":true,"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"PANE","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":true,"resume_command":"/owned/claude --resume exact-session"}"#
        .replacingOccurrences(of: "PANE", with: pane.id.uuidString.lowercased())
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    var proof = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(wire.utf8))
    #expect(proof.valid(for: pane.id))
    for background in [true, false] {
        proof.backgroundWork = background
        let facts = RelayPaneHealthFacts.read(pane, proof: proof)
        #expect(facts.value["kind"]?.string == "claude")
        #expect(facts.value["activity"]?.string == "working")
        #expect(facts.value["identity_verified"]?.boolean == true)
        #expect(!facts.allowedActions.contains("apply_update"))
    }
}

@Test @MainActor func paneHealthBatchesCoverLargeHostsWithinTheToolStepBudget() {
    let rows = (0..<38).map { n in RelayPaneHealthFacts.seal(["pane_id": .string("pane-\(n)")]) }
    let batches = RelayPaneHealthCoordinator.assessmentBatches(rows)
    #expect(batches.flatMap { $0 }.map(\.paneID) == rows.map(\.paneID))
    #expect(batches.allSatisfy { $0.count <= 8 && $0.count + 1 <= 12 })
}

@Test @MainActor func paneHealthBatchReportsPreserveOtherPanesAndRemoveRetiredOnes() {
    func row(_ id: String, _ state: String) -> RelayPaneHealthJSON {
        .object(["pane_id": .string(id), "health": .string(state)])
    }
    let previous = RelayPaneHealthJSON.object(["panes": .array([
        row("kept", "healthy"), row("updated", "attention"), row("retired", "held")])])
    let batch = RelayPaneHealthJSON.object(["panes": .array([row("updated", "healthy")])])
    let merged = RelayPaneHealthCoordinator.mergingReport(previous, batch: batch,
        activePaneIDs: ["kept", "updated"])
    #expect(merged["panes"]?.array?.compactMap { $0["pane_id"]?.string } == ["kept", "updated"])
    #expect(merged["panes"]?.array?.allSatisfy { $0["health"]?.string == "healthy" } == true)
}
