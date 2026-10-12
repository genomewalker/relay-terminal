import Foundation
import CryptoKit
import Testing
@testable import Relay

private let coordinatorPane = "8008013b-cb68-46c8-b939-78351b5172a2"
private let coordinatorFresh = RelayClaudeRotationLifecycle.sessionID(for: "claim-1")
private let coordinatorHead = String(repeating: "a", count: 40)

private func coordinatorData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}
private func coordinatorSHA(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private actor CoordinatorHostFixture: RelayClaudeRotationHost {
    let retained: Data
    let loseLaunchResponse: Bool
    let permissionReady: Bool
    let newPromptReady: Bool
    var launches = 0
    var inputs: [String] = []
    var fresh: RelayClaudePhysicalSession?
    var oldExited = false
    init(snapshot: Data, loseLaunchResponse: Bool = false, permissionReady: Bool = true,
         newPromptReady: Bool = true) {
        retained = snapshot; self.loseLaunchResponse = loseLaunchResponse
        self.permissionReady = permissionReady; self.newPromptReady = newPromptReady
    }
    func snapshot(at path: String) -> Data { retained }
    func codeHead(projectDir: String) -> String { coordinatorHead }
    func session(paneID: String, sessionID: String) -> RelayClaudePhysicalSession? {
        if sessionID == "old-1" && !oldExited {
            return .init(sessionID: sessionID, paneID: coordinatorPane, pid: 42, processStart: "123",
                         startedAtMilliseconds: 100, cwd: "/project", idle: true, inputEmpty: true, noDescendants: true,
                         promptReady: true)
        }
        return fresh?.sessionID == sessionID && fresh?.paneID == paneID ? fresh : nil
    }
    func launchDedicated(paneID: String, sessionID: String, intentID: String,
                         executable: String, arguments: [String], cwd: String) throws {
        launches += 1
        #expect(executable == "/agent/claude")
        #expect(arguments == ["--model", "configured", "--session-id", coordinatorFresh])
        fresh = .init(sessionID: sessionID, paneID: paneID, pid: 43, processStart: "456",
                      startedAtMilliseconds: 200, cwd: cwd, idle: true, inputEmpty: true, noDescendants: true,
                      promptReady: newPromptReady)
        if loseLaunchResponse { throw RelayRotationAdapterError.mismatchedEvidence }
    }
    func enrollRelayOwned(_ session: RelayClaudePhysicalSession, intentID: String) {}
    func receiptToolAuthorized(_ command: String, for session: RelayClaudePhysicalSession) -> Bool { permissionReady }
    func sendOnce(_ text: String, to session: RelayClaudePhysicalSession) {
        inputs.append(text)
        if text == "/exit" { oldExited = true }
    }
    func waitForCompletedTurn(_ session: RelayClaudePhysicalSession) {}
    func waitForExit(_ session: RelayClaudePhysicalSession) throws {
        guard oldExited else { throw RelayRotationAdapterError.mismatchedEvidence }
    }
}

private actor CoordinatorLedgerFixture: RelayRotationTransport {
    var acknowledged = false
    func acknowledge() { acknowledged = true }
    func ledger(_ operation: String, arguments: Data) throws -> Data {
        var value: [String: Any] = ["session_id": "old-1", "owner": "relay", "client": "claude", "epoch": "epoch-alpha"]
        if acknowledged {
            value["ack"] = ["claim_id": "claim-1", "token": 13, "capsule_revision": 7,
                            "new_session_id": coordinatorFresh, "lifecycle_performed": true]
        }
        return try coordinatorData(value)
    }
    func backend(_ operation: String, arguments: Data) throws -> Data { throw RelayRotationAdapterError.mismatchedEvidence }
}

private actor CoordinatorRetiredProbe {
    private(set) var attempts = 0
    func next() -> Bool { attempts += 1; return attempts >= 3 }
}

private func coordinatorHelper(retiredProbe: CoordinatorRetiredProbe? = nil) -> RelayClaudeRotationJSONBackend {
    RelayClaudeRotationJSONBackend { bytes in
        let args = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var output: [String: Any] = ["v": 1, "ok": true]
        switch args["op"] as? String {
        case "plan_start":
            output["session_id"] = coordinatorFresh
            output["argv"] = ["--model", "configured", "--session-id", coordinatorFresh]
            output["cwd"] = "/project"
        case "confirm":
            output["confirmed"] = true
            output["incarnation"] = ["session_id": coordinatorFresh, "pid": 43, "started_at_ms": 200]
        case "receipt_plan":
            let digest = coordinatorSHA(try coordinatorData(args["capsule"] as! [String: Any]))
            output["expected_digest"] = digest; output["command"] = "approved receipt helper"
            output["expected_line"] = "receipt " + digest; output["prompt"] = "receipt only"
        case "verify_receipt": output["verified"] = true; output["turn_seq"] = 1
        case "retire_preflight": output["allowed"] = true; output["text"] = "/exit"
        case "retired":
            if let retiredProbe { output["retired"] = await retiredProbe.next() }
            else { output["retired"] = true }
        case "continuation_plan": output["prompt"] = "continue after retirement"
        default: throw RelayRotationAdapterError.mismatchedEvidence
        }
        return try coordinatorData(output)
    }
}

struct RelayClaudeRotationCoordinatorTests {
    private func enrollment() throws -> RelayRetainedRotationEnrollment {
        let snapshot = try coordinatorData(["schema": 1, "client": "claude", "pid": 42, "process_start": "123",
            "relay_pane_id": coordinatorPane, "cwd": "/project", "executable": "/agent/claude", "launch_id": "launch-1",
            "effective_args": ["--model", "configured"],
            "arguments": ["reusable": true, "fresh_args": ["--model", "configured"]]])
        let capturedAt = Date()
        let settings = try coordinatorData(["session_id": "old-1", "pane_id": coordinatorPane,
            "source_pid": 42, "source_start": "123", "cwd": "/project", "model": "configured",
            "effort": "medium", "permission_mode": "manual", "fresh_args": ["--model", "configured"]])
        let start = RelayClaudeStartConfiguration(sourceSessionID: "old-1", sourcePID: 42,
            sourceProcessStart: "123", payload: settings, sha256: coordinatorSHA(settings),
            capturedAt: capturedAt)
        return .init(sessionID: "old-1", client: "claude", hostID: "remote", paneID: coordinatorPane,
            processID: 42, processStart: "123", snapshotPath: "/private/snapshot.json",
            snapshotSHA256: coordinatorSHA(snapshot), snapshot: snapshot, enrolledAt: capturedAt,
            claudeStart: start)
    }
    private func startRequest(_ e: RelayRetainedRotationEnrollment) throws -> Data {
        try coordinatorData(["source_thread_id": e.sessionID, "source_pane_id": e.paneID,
            "source_pid": e.processID, "source_process_start": e.processStart,
            "snapshot_path": e.snapshotPath, "snapshot_sha256": e.snapshotSHA256,
            "cwd": "/project", "code_head": coordinatorHead, "intent_id": "claim-1", "session_id": coordinatorFresh])
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test func lostLaunchResponseRecoversWithoutAnotherLaunch() async throws {
        let e = try enrollment(), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = CoordinatorHostFixture(snapshot: e.snapshot, loseLaunchResponse: true)
        let ledger = CoordinatorLedgerFixture()
        let first = RelayClaudeRotationCoordinator(enrollment: e, helper: coordinatorHelper(), host: host,
            ledgerTransport: ledger, actions: .init(directory: dir))
        let request = try startRequest(e)
        await #expect(throws: RelayRotationAdapterError.self) { try await first.backend("start", arguments: request) }
        let recovered = RelayClaudeRotationCoordinator(enrollment: e, helper: coordinatorHelper(), host: host,
            ledgerTransport: ledger, actions: .init(directory: dir))
        let response = try await recovered.backend("start", arguments: request)
        #expect((try JSONSerialization.jsonObject(with: response) as? [String: Any])?["session_id"] as? String == coordinatorFresh)
        #expect(await host.launches == 1)
    }

    @Test func durableAckPrecedesExitAndContinuation() async throws {
        let e = try enrollment(), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = CoordinatorHostFixture(snapshot: e.snapshot), ledger = CoordinatorLedgerFixture()
        let retiredProbe = CoordinatorRetiredProbe()
        let coordinator = RelayClaudeRotationCoordinator(enrollment: e, helper: coordinatorHelper(retiredProbe: retiredProbe), host: host,
            ledgerTransport: ledger, actions: .init(directory: dir))
        _ = try await coordinator.backend("start", arguments: startRequest(e))
        let capsule = try coordinatorData(["revision": 7, "code_head": coordinatorHead, "objective": "Finish repair", "next_action": "Run check"])
        let load = try coordinatorData(["intent_id": "claim-1", "source_thread_id": e.sessionID,
            "thread_id": coordinatorFresh, "capsule": String(decoding: capsule, as: UTF8.self),
            "sha256": coordinatorSHA(capsule), "capsule_revision": 7, "receipt_only": true])
        _ = try await coordinator.backend("load", arguments: load)
        let archive = try coordinatorData(["intent_id": "claim-1", "thread_id": e.sessionID,
            "source_pane_id": e.paneID, "source_pid": e.processID, "source_process_start": e.processStart,
            "fresh_thread_id": coordinatorFresh, "epoch": "epoch-alpha", "token": 13, "capsule_revision": 7,
            "cwd": "/project", "code_head": coordinatorHead])
        await #expect(throws: RelayRotationAdapterError.self) { try await coordinator.backend("archive", arguments: archive) }
        #expect(await host.inputs == ["receipt only"])
        await ledger.acknowledge()
        _ = try await coordinator.backend("archive", arguments: archive)
        #expect(await retiredProbe.attempts == 3)
        try await coordinator.continueFresh(intentID: "claim-1")
        #expect(await host.inputs == ["receipt only", "/exit", "continue after retirement"])
        try await coordinator.continueFresh(intentID: "claim-1")
        #expect(await host.inputs.count == 3)
    }

    @Test func independentActionStoresClaimOnce() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wins = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { try RelayClaudeRotationActionStore(directory: dir).claim(intent: "one", action: "send", fingerprint: "snapshot") }
            }
            var wins = 0
            for try await won in group { if won { wins += 1 } }
            return wins
        }
        #expect(wins == 1)
        let recovered = RelayClaudeRotationActionStore(directory: dir)
        #expect(try recovered.claim(intent: "one", action: "send", fingerprint: "snapshot") == false)
        #expect(throws: RelayRotationAdapterError.self) {
            try recovered.complete(intent: "one", action: "send", fingerprint: "different snapshot", result: Data())
        }
    }

    @Test(arguments: [false, true]) func receiptHoldsUntilPromptAndPermissionAreProven(permissionReady: Bool) async throws {
        let e = try enrollment(), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = CoordinatorHostFixture(snapshot: e.snapshot, permissionReady: permissionReady,
                                          newPromptReady: !permissionReady)
        let coordinator = RelayClaudeRotationCoordinator(enrollment: e, helper: coordinatorHelper(), host: host,
            ledgerTransport: CoordinatorLedgerFixture(), actions: .init(directory: dir))
        _ = try await coordinator.backend("start", arguments: startRequest(e))
        let capsule = try coordinatorData(["revision": 7, "code_head": coordinatorHead, "objective": "Safe handoff"])
        let load = try coordinatorData(["intent_id": "claim-1", "source_thread_id": e.sessionID,
            "thread_id": coordinatorFresh, "capsule": String(decoding: capsule, as: UTF8.self),
            "sha256": coordinatorSHA(capsule), "capsule_revision": 7, "receipt_only": true])
        await #expect(throws: RelayRotationAdapterError.self) { try await coordinator.backend("load", arguments: load) }
        #expect(await host.inputs.isEmpty)
    }
}
