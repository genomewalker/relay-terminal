import Foundation
import CryptoKit
import Testing
@testable import Relay

private struct EnrollmentFactoryTransport: RelayRotationTransport {
    func ledger(_ operation: String, arguments: Data) async throws -> Data {
        throw RelayRotationAdapterError.mismatchedEvidence
    }
    func backend(_ operation: String, arguments: Data) async throws -> Data {
        throw RelayRotationAdapterError.mismatchedEvidence
    }
}

@Suite struct RelayRotationEnrollmentStoreTests {
    private func record(client: String = "codex", session: String = "session", pid: Int = 42,
                        snapshotPID: Int = 42, reusable: Bool = true,
                        capturedStart: Bool = true) throws -> RelayRetainedRotationEnrollment {
        let pane = "5137b989-b0b2-49c4-b0f0-528261c3b7cb"
        let snapshot = try JSONSerialization.data(withJSONObject: ["schema": 1, "client": client,
            "pid": snapshotPID, "process_start": "1234", "relay_pane_id": pane,
            "cwd": "/project", "executable": "/bin/agent", "launch_id": "retained",
            "effective_args": ["--model", "fixture"], "arguments": ["reusable": reusable]])
        let params = try JSONSerialization.data(withJSONObject: ["cwd": "/project",
            "model": "fixture-model", "approvalPolicy": "never", "sandbox": "readOnly"])
        let codexStart = client == "codex" && capturedStart ? RelayCodexStartConfiguration(
            sourceThreadID: session, sourceTurnID: "turn-1", sourcePID: pid,
            sourceProcessStart: "1234", parameters: params, effort: "medium",
            sha256: SHA256.hash(data: params).map { String(format: "%02x", $0) }.joined(),
            capturedAt: Date(timeIntervalSince1970: 0)) : nil
        let claudePayload = try JSONSerialization.data(withJSONObject: [
            "session_id": session, "pane_id": pane, "source_pid": pid,
            "source_start": "1234", "cwd": "/project", "model": "fixture-model",
            "effort": "high", "permission_mode": "auto", "fresh_args": ["--model", "fixture-model"]])
        let claudeStart = client == "claude" ? RelayClaudeStartConfiguration(
            sourceSessionID: session, sourcePID: pid, sourceProcessStart: "1234",
            payload: claudePayload,
            sha256: SHA256.hash(data: claudePayload).map { String(format: "%02x", $0) }.joined(),
            capturedAt: Date(timeIntervalSince1970: 0)) : nil
        return RelayRetainedRotationEnrollment(sessionID: session, client: client, hostID: "host",
            paneID: pane, processID: pid, processStart: "1234", snapshotPath: "/private/retained.json",
            snapshotSHA256: SHA256.hash(data: snapshot).map { String(format: "%02x", $0) }.joined(),
            snapshot: snapshot, enrolledAt: Date(timeIntervalSince1970: 1),
            codexStart: codexStart, claudeStart: claudeStart)
    }

    @Test func retainsBothClientsAndRejectsUnverifiedLaunch() throws {
        #expect(try record().valid)
        #expect(try record(client: "claude").valid)
        #expect(try !record(pid: 43).valid)
        #expect(try !record(reusable: false).valid)
        #expect(try !record(client: "unknown").valid)
        #expect(try !record(capturedStart: false).valid)
    }

    @Test func completedTurnHintRequiresExactIdentityAndFreshCursor() throws {
        let value = try record(client: "claude")
        let accepted = RelayRotationTurnGate.candidate(enrollment: value,
            hostID: value.hostID, paneID: value.paneID, client: "claude",
            sessionID: value.sessionID, eventName: "Stop", eventSequence: 11,
            priorCursor: 10, replayDepth: 0)
        #expect(accepted?.eventSequence == 11)
        #expect(RelayRotationTurnGate.candidate(enrollment: value,
            hostID: value.hostID, paneID: value.paneID, client: "claude",
            sessionID: value.sessionID, eventName: "Stop", eventSequence: 10,
            priorCursor: 10, replayDepth: 0) == nil)
        #expect(RelayRotationTurnGate.candidate(enrollment: value,
            hostID: value.hostID, paneID: value.paneID, client: "claude",
            sessionID: value.sessionID, eventName: "Stop", eventSequence: 12,
            priorCursor: 10, replayDepth: 1) == nil)
        #expect(RelayRotationTurnGate.candidate(enrollment: value,
            hostID: value.hostID, paneID: value.paneID, client: "codex",
            sessionID: value.sessionID, eventName: "Stop", eventSequence: 12,
            priorCursor: 10, replayDepth: 0) == nil)
        #expect(RelayRotationTurnGate.candidate(enrollment: value,
            hostID: value.hostID, paneID: value.paneID, client: "claude",
            sessionID: "another", eventName: "Stop", eventSequence: 12,
            priorCursor: 10, replayDepth: 0) == nil)
    }

    @Test func factoryRequiresExplicitClientBuilderAndValidCapsule() throws {
        let value = try record()
        let capsule = Data(#"{"revision":1}"#.utf8)
        #expect(throws: RelayRotationFactoryError.self) {
            try RelayConfiguredRotationLifecycleFactory().lifecycle(enrollment: value, capsule: capsule)
        }
        let factory = RelayConfiguredRotationLifecycleFactory(codex: { enrollment, payload in
            #expect(enrollment == value)
            #expect(payload == capsule)
            return RelayCodexRotationLifecycle(transport: EnrollmentFactoryTransport(),
                binding: RelayCodexRotationBinding(projectDir: "/project",
                    sourceStartParameters: Data("{}".utf8), capsule: payload))
        })
        #expect(try factory.lifecycle(enrollment: value, capsule: capsule).client == "codex")
        #expect(throws: RelayRotationFactoryError.self) {
            try factory.lifecycle(enrollment: value, capsule: Data("[]".utf8))
        }
        let claudeValue = try record(client: "claude")
        #expect(throws: RelayRotationFactoryError.self) {
            try factory.lifecycle(enrollment: claudeValue, capsule: capsule)
        }
        let wrong = RelayConfiguredRotationLifecycleFactory(claude: { _, payload in
            RelayCodexRotationLifecycle(transport: EnrollmentFactoryTransport(),
                binding: RelayCodexRotationBinding(projectDir: "/project",
                    sourceStartParameters: Data("{}".utf8), capsule: payload))
        })
        #expect(throws: RelayRotationFactoryError.self) {
            try wrong.lifecycle(enrollment: claudeValue, capsule: capsule)
        }
    }

    @Test func persistsAcrossInstancesAndRejectsConflictingIncarnation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("enrollments.json")
        let first = RelayRotationEnrollmentStore(url: url)
        let second = RelayRotationEnrollmentStore(url: url)
        let value = try record()
        #expect(first.enroll(value))
        #expect(second.records() == [value])
        #expect(second.enroll(value))
        #expect(try !second.enroll(record(pid: 43, snapshotPID: 43)))
        #expect(try !second.enroll(record(session: "other")))
        #expect(!second.remove(sessionID: value.sessionID, snapshotSHA256: "wrong"))
        #expect(second.remove(sessionID: value.sessionID, snapshotSHA256: value.snapshotSHA256))
        #expect(first.records() == [])
    }

    @Test func corruptOrPublicStorageFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("enrollments.json")
        let store = RelayRotationEnrollmentStore(url: url)
        #expect(try store.enroll(record()))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(store.records() == nil)
        #expect(try !store.enroll(record()))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Data("{}".utf8).write(to: url)
        #expect(store.records() == nil)
        #expect(try !store.enroll(record()))
    }
}
