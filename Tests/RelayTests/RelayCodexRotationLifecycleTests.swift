import Foundation
import Testing
@testable import Relay

private actor RotationWireFixture: RelayRotationTransport {
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
                "owner": "relay", "client": "codex", "cwd": "/project", "turn_seq": 12, "live": true,
                "signal": ["action": "rotate", "seq": 10],
                "claim": ["claim_id": "claim-1", "token": 13, "expected_seq": 12],
                "capsule": ["token": 13, "revision": 7, "code_head": String(repeating: "a", count: 40), "ledger_seq": 12]]
            if bound { value["intent"] = ["state": "bound", "claim_id": "claim-1", "token": 13, "new_session_id": "new-1"] }
            if acknowledged { value["ack"] = ["claim_id": "claim-1", "token": 13, "capsule_revision": 7,
                "new_session_id": "new-1", "lifecycle_performed": true] }
            return try data(value)
        }
        #expect(args["token"] as? Int == 13)
        if operation == "rotation_intent" {
            #expect(args["new_session_id"] == nil)
            return try data(["intent_id": args["intent_id"]!, "token": 13, "state": "ambiguous"])
        }
        if operation == "rotation_bind" { bound = true; return try data(["state": "bound", "new_session_id": "new-1"]) }
        if operation == "rotation_ack" { acknowledged = true; return try data(["new_session_id": "new-1", "lifecycle_performed": true]) }
        throw RelayRotationAdapterError.mismatchedEvidence
    }
    func backend(_ operation: String, arguments: Data) throws -> Data {
        operations.append(operation)
        let args = try JSONSerialization.jsonObject(with: arguments) as! [String: Any]
        if operation == "inspect" { return try data(["idle": true, "root": true, "no_descendants": true]) }
        if operation == "start" {
            let parameters = args["start_parameters"] as! [String: Any]
            #expect(parameters["sandbox"] as? String == "read-only")
            #expect(parameters["approvalPolicy"] as? String == "never")
            return try data(["thread_id": "new-1", "session_id": "new-1"])
        }
        if operation == "load" { #expect(bound); return try data(["thread_id": "new-1", "completed": true, "sha256": args["sha256"]!]) }
        if operation == "archive" { #expect(acknowledged); return try data(["thread_id": "old-1", "archived": true]) }
        throw RelayRotationAdapterError.mismatchedEvidence
    }
}

struct RelayCodexRotationLifecycleTests {
    private func capsule() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 2, "state": "in_progress", "session_id": "old-1", "project_dir": "/project",
            "code_head": String(repeating: "a", count: 40), "revision": 7, "ledger_seq": 12, "objective": "Finish repair", "next_action": "Run focused test"], options: [.sortedKeys])
    }
    private func admission() -> RelayRotationAdmission {
        RelayRotationAdmission(sourceThreadID: "old-1", owner: "relay", client: "codex", enrolled: true,
            turnIdle: true, epoch: "epoch-alpha", signalSequence: 10, completedTurnSequence: 12,
            claimID: "claim-1", fencingToken: 13, claimExpiresAt: .distantFuture,
            capsuleRevision: 7, capsuleLedgerSequence: 12, codeHead: String(repeating: "a", count: 40))
    }
    @Test func realWireOperationsPreserveSettingsAndAckBeforeArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capsule = try capsule(), transport = RotationWireFixture(capsule: capsule)
        let parameters = try JSONSerialization.data(withJSONObject: ["cwd": "/project", "model": "retained-model", "sandbox": "read-only", "approvalPolicy": "never"])
        let adapter = RelayCodexRotationLifecycle(transport: transport,
            binding: .init(projectDir: "/project", sourceStartParameters: parameters, capsule: capsule))
        let executor = RelayChittaRotationExecutor(journal: .init(url: directory.appendingPathComponent("journal.json")))
        #expect(await executor.execute(admission(), using: adapter) == .completed("new-1"))
        let operations = await transport.operations
        #expect(operations.firstIndex(of: "rotation_intent")! < operations.firstIndex(of: "start")!)
        #expect(operations.firstIndex(of: "rotation_ack")! < operations.firstIndex(of: "archive")!)
    }
    @Test func sameRevisionWithChangedCapsuleCannotStart() async throws {
        let capsule = try capsule(), transport = RotationWireFixture(capsule: capsule, staleCapsule: true)
        let adapter = RelayCodexRotationLifecycle(transport: transport,
            binding: .init(projectDir: "/project", sourceStartParameters: Data(), capsule: capsule))
        await #expect(throws: RelayRotationAdapterError.self) { try await adapter.validate(admission()) }
        #expect(!(await transport.operations).contains("start"))
    }
    @Test func realProcessTransportDeliversJSONOnStandardInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("probe.py")
        try Data("import sys,json;print(json.dumps(json.load(sys.stdin)))".utf8).write(to: script)
        let transport = RelayRotationProcessTransport(chittaExecutable: URL(fileURLWithPath: "/unused"),
            pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"), backendScript: script,
            socketPath: "/unused", socketDevice: 1, socketInode: 1)
        let request = Data(#"{"thread_id":"exact-destination","probe":"stdin-received"}"#.utf8)
        let response = try await transport.backend("inspect", arguments: request)
        let value = try JSONSerialization.jsonObject(with: response) as? [String: String]
        #expect(value?["thread_id"] == "exact-destination")
        #expect(value?["probe"] == "stdin-received")
    }

}
