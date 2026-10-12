import Foundation
import Testing
@testable import Relay

private actor ClaudeRotationWireFixture: RelayRotationTransport {
    let capsule: Data
    let staleCapsule: Bool
    var operations: [String] = []
    var bound = false
    var acknowledged = false
    init(capsule: Data, staleCapsule: Bool = false) { self.capsule = capsule; self.staleCapsule = staleCapsule }
    private func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    func ledger(_ operation: String, arguments: Data) throws -> Data {
        operations.append(operation)
        let args = try JSONSerialization.jsonObject(with: arguments) as! [String: Any]
        #expect(args["session_id"] as? String == "old-1")
        if operation == "capsule_get" {
            var value = try JSONSerialization.jsonObject(with: capsule) as! [String: Any]
            if staleCapsule { value["objective"] = "Replaced checkpoint" }
            return try data(["status": "ok", "capsule": value])
        }
        #expect(args["epoch"] as? String == "epoch-alpha")
        if operation == "rotation_status" {
            var value: [String: Any] = ["v": 1, "session_id": "old-1", "epoch": "epoch-alpha",
                "owner": "relay", "client": "claude", "cwd": "/project", "turn_seq": 12, "live": true,
                "signal": ["action": "rotate", "seq": 10],
                "claim": ["claim_id": "claim-1", "token": 13, "expected_seq": 12],
                "capsule": ["token": 13, "revision": 7, "code_head": String(repeating: "a", count: 40), "ledger_seq": 12]]
            if bound { value["intent"] = ["state": "bound", "claim_id": "claim-1", "token": 13, "new_session_id": "68ec16aa-4092-5ef7-9727-334322871101"] }
            if acknowledged { value["ack"] = ["claim_id": "claim-1", "token": 13, "capsule_revision": 7,
                "new_session_id": "68ec16aa-4092-5ef7-9727-334322871101", "lifecycle_performed": true] }
            return try data(value)
        }
        #expect(args["token"] as? Int == 13)
        if operation == "rotation_intent" {
            #expect(args["new_session_id"] == nil)
            return try data(["intent_id": args["intent_id"]!, "token": 13, "state": "ambiguous"])
        }
        if operation == "rotation_bind" { bound = true; return try data(["state": "bound", "new_session_id": "68ec16aa-4092-5ef7-9727-334322871101"]) }
        if operation == "rotation_ack" { acknowledged = true; return try data(["new_session_id": "68ec16aa-4092-5ef7-9727-334322871101", "lifecycle_performed": true]) }
        throw RelayRotationAdapterError.mismatchedEvidence
    }
    func backend(_ operation: String, arguments: Data) throws -> Data {
        operations.append(operation)
        let args = try JSONSerialization.jsonObject(with: arguments) as! [String: Any]
        if operation == "inspect" { return try data(["idle": true, "root": true, "no_descendants": true]) }
        if operation == "start" {
            #expect(args["snapshot_path"] as? String == "/private/snapshot.json")
            #expect(args["snapshot_sha256"] as? String == String(repeating: "b", count: 64))
            #expect(args["start_parameters"] == nil)
            return try data(["thread_id": "68ec16aa-4092-5ef7-9727-334322871101", "session_id": "68ec16aa-4092-5ef7-9727-334322871101",
                             "dedicated_pane": true, "snapshot_sha256": args["snapshot_sha256"]!])
        }
        if operation == "load" { #expect(bound); return try data(["thread_id": "68ec16aa-4092-5ef7-9727-334322871101", "completed": true, "sha256": args["sha256"]!, "intent_id": "claim-1", "capsule_revision": 7, "receipt_verified": true, "owner": "relay"]) }
        if operation == "archive" { #expect(acknowledged); return try data(["thread_id": "old-1", "archived": true]) }
        throw RelayRotationAdapterError.mismatchedEvidence
    }
}

struct RelayClaudeRotationLifecycleTests {
    private func capsule() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 2, "state": "in_progress", "session_id": "old-1", "project_dir": "/project",
            "code_head": String(repeating: "a", count: 40), "revision": 7, "ledger_seq": 12, "objective": "Finish repair", "next_action": "Run focused test"], options: [.sortedKeys])
    }
    private func admission() -> RelayRotationAdmission {
        RelayRotationAdmission(sourceThreadID: "old-1", owner: "relay", client: "claude", enrolled: true,
            turnIdle: true, epoch: "epoch-alpha", signalSequence: 10, completedTurnSequence: 12,
            claimID: "claim-1", fencingToken: 13, claimExpiresAt: .distantFuture,
            capsuleRevision: 7, capsuleLedgerSequence: 12, codeHead: String(repeating: "a", count: 40))
    }
    @Test func realWireOperationsPreserveSettingsAndAckBeforeArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capsule = try capsule(), transport = ClaudeRotationWireFixture(capsule: capsule)
        let adapter = RelayClaudeRotationLifecycle(transport: transport,
            binding: .init(projectDir: "/project", snapshotPath: "/private/snapshot.json", snapshotSHA256: String(repeating: "b", count: 64), sourcePaneID: "8008013b-cb68-46c8-b939-78351b5172a2", sourcePID: 42, sourceProcessStart: "123", capsule: capsule))
        let executor = RelayChittaRotationExecutor(journal: .init(url: directory.appendingPathComponent("journal.json")))
        #expect(await executor.execute(admission(), using: adapter) == .completed("68ec16aa-4092-5ef7-9727-334322871101"))
        let operations = await transport.operations
        #expect(operations.firstIndex(of: "rotation_intent")! < operations.firstIndex(of: "start")!)
        #expect(operations.firstIndex(of: "rotation_ack")! < operations.firstIndex(of: "archive")!)
    }
    @Test func sameRevisionWithChangedCapsuleCannotStart() async throws {
        let capsule = try capsule(), transport = ClaudeRotationWireFixture(capsule: capsule, staleCapsule: true)
        let adapter = RelayClaudeRotationLifecycle(transport: transport,
            binding: .init(projectDir: "/project", snapshotPath: "/private/snapshot.json", snapshotSHA256: String(repeating: "b", count: 64), sourcePaneID: "8008013b-cb68-46c8-b939-78351b5172a2", sourcePID: 42, sourceProcessStart: "123", capsule: capsule))
        await #expect(throws: RelayRotationAdapterError.self) { try await adapter.validate(admission()) }
        #expect(!(await transport.operations).contains("start"))
    }

    @Test func deterministicSessionMatchesPythonUUID5() {
        #expect(RelayClaudeRotationLifecycle.sessionID(for: "claim-1") == "68ec16aa-4092-5ef7-9727-334322871101")
    }
    @Test func jsonWrapperRejectsOperationSpoofAndErrorResponse() async throws {
        let backend = RelayClaudeRotationJSONBackend { _ in Data(#"{"v":1,"ok":false,"error":"refused"}"#.utf8) }
        await #expect(throws: RelayRotationAdapterError.self) {
            try await backend.request(.confirm, arguments: Data(#"{"op":"plan_start"}"#.utf8))
        }
        await #expect(throws: RelayRotationAdapterError.self) {
            try await backend.request(.confirm, arguments: Data(#"{"intent_id":"claim-1","pane_pid":42}"#.utf8))
        }
    }
    @Test func jsonWrapperPreservesReadOnlyRetirementRefusal() async throws {
        let backend = RelayClaudeRotationJSONBackend { input in
            let request = try JSONSerialization.jsonObject(with: input) as! [String: Any]
            #expect(request["op"] as? String == "retire_preflight")
            return Data(#"{"v":1,"ok":true,"allowed":false,"reason":"busy","text":null}"#.utf8)
        }
        let output = try await backend.request(.retirePreflight, arguments: Data("{}".utf8))
        #expect((try JSONSerialization.jsonObject(with: output) as? [String: Any])?["allowed"] as? Bool == false)
    }
}
