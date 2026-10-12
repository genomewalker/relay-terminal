import Foundation
import Testing
@testable import Relay

@Test @MainActor func promptEditorWaitsForInputAckAndRejectsReconnectOrCancellation() async throws {
    let lease = RelayPromptEditorControlLease(connectionID: UUID(), clientID: UUID(), hostID: UUID(), paneID: UUID())
    let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var idle = false
    var finished = false
    let waiting = Task {
        try await RelayPromptEditorLeaseWaiter.wait(for: lease, events: events,
            identity: { lease }, ready: { idle ? lease : nil })
        finished = true
    }
    await Task.yield()
    #expect(!finished)
    idle = true; continuation.yield(())
    try await waiting.value
    #expect(finished)
    continuation.finish()

    let (changedEvents, changedContinuation) = AsyncStream<Void>.makeStream()
    var identity: RelayPromptEditorControlLease? = lease
    let changed = Task {
        try await RelayPromptEditorLeaseWaiter.wait(for: lease, events: changedEvents,
            identity: { identity }, ready: { nil })
    }
    await Task.yield()
    identity = nil; changedContinuation.yield(())
    do { try await changed.value; Issue.record("A changed lease was accepted") }
    catch { #expect(error is RelayPromptEditorRPC.Failure) }
    changedContinuation.finish()

    let (cancelEvents, cancelContinuation) = AsyncStream<Void>.makeStream()
    let cancelled = Task {
        try await RelayPromptEditorLeaseWaiter.wait(for: lease, events: cancelEvents,
            identity: { lease }, ready: { nil })
    }
    await Task.yield()
    cancelled.cancel()
    do { try await cancelled.value; Issue.record("A cancelled lease wait completed") }
    catch { #expect(error is CancellationError) }
    cancelContinuation.finish()
}

@Test func promptEditorLeaseRequiresAnExplicitIdleControlConnection() {
    func permits(attached: Bool = true, detached: Bool = false, writer: Bool = true,
        control: Bool = true, observer: Bool = false, ack: Bool = true,
        pending: Bool = false, overflow: Bool = false) -> Bool {
        RelayPromptEditorLeasePolicy.admits(attached: attached, detached: detached,
            writerAvailable: writer, controlGranted: control, observer: observer,
            acknowledgedInput: ack, pendingInput: pending, overflowed: overflow)
    }
    #expect(permits())
    #expect(!permits(attached: false))
    #expect(!permits(detached: true))
    #expect(!permits(writer: false))
    #expect(!permits(control: false))
    #expect(!permits(observer: true))
    #expect(!permits(ack: false))
    #expect(!permits(pending: true))
    #expect(!permits(overflow: true))
    let old = RelayPromptEditorControlLease(connectionID: UUID(), clientID: UUID(), hostID: UUID(), paneID: UUID())
    let reconnected = RelayPromptEditorControlLease(connectionID: UUID(), clientID: old.clientID,
        hostID: old.hostID, paneID: old.paneID)
    #expect(reconnected != old)
}

@Test func promptEditorWirePreservesExactDraftAndRejectsChangedIdentityOrDigest() throws {
    let pane = UUID()
    let owner = RelayPromptOwnerBinding(version: 1, paneId: pane.uuidString.lowercased(),
        nodeBootId: "owned-kernel", workerPid: 101, workerStart: 102, shellPid: 103, shellStart: 104,
        provider: "claude", processId: 105, processStart: 106, sessionId: "owned-session",
        transcriptIdentity: "input:" + String(repeating: "a", count: 48), inputOnly: true)
    let id = String(repeating: "b", count: 32)
    let bytes = Data("first 🧬\nsecond  \t\n".utf8)
    let digest = RelayPromptEditorRPC.digest(bytes)
    let snapshot = RelayPromptEditorRPC.Request(operation: .snapshot, id: id, owner: owner)
    #expect(snapshot.isValid)
    let commit = RelayPromptEditorRPC.Request(operation: .commit, id: id, owner: owner, digest: digest, text: bytes)
    #expect(commit.isValid)
    let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(commit)) as? [String: Any])
    #expect(encoded["operation"] as? String == "commit")
    #expect(encoded["text"] as? String == bytes.base64EncodedString())
    let wireOwner = try #require(encoded["owner"] as? [String: Any])
    #expect(wireOwner["input_only"] as? Bool == true)
    #expect(wireOwner["pane_id"] as? String == pane.uuidString.lowercased())
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    func response(id responseID: String = id, digest responseDigest: String = digest,
        text: Data = bytes, owner responseOwner: [String: Any] = wireOwner) throws -> RelayPromptEditorRPC.Response {
        try decoder.decode(RelayPromptEditorRPC.Response.self, from: JSONSerialization.data(withJSONObject: [
            "state": "captured", "id": responseID, "digest": responseDigest,
            "text": text.base64EncodedString(), "owner": responseOwner
        ]))
    }
    let captured = try response()
    #expect(captured.isValid(for: snapshot))
    #expect(captured.text == bytes)
    #expect(!captured.isValid(for: commit))
    #expect(!(try response(id: String(repeating: "c", count: 32))).isValid(for: snapshot))
    #expect(!(try response(digest: String(repeating: "0", count: 64))).isValid(for: snapshot))
    #expect(!(try response(text: Data([0xff]))).isValid(for: snapshot))
    var otherOwner = wireOwner; otherOwner["process_start"] = 999
    #expect(!(try response(owner: otherOwner)).isValid(for: snapshot))
    #expect(!RelayPromptEditorRPC.Request(operation: .commit, id: id, owner: owner).isValid)
    #expect(!RelayPromptEditorRPC.Request(operation: .arm, id: "invalid", owner: owner).isValid)
    let receipt = RelayPromptEditorRPC.Request(operation: .receipt, id: id, owner: owner, digest: digest)
    #expect(receipt.isValid)
    #expect(!RelayPromptEditorRPC.Request(operation: .receipt, id: id, owner: owner).isValid)
    let applied = try decoder.decode(RelayPromptEditorRPC.Response.self, from: JSONSerialization.data(withJSONObject: [
        "state": "applied", "id": id, "digest": digest
    ]))
    #expect(applied.isValid(for: receipt))
    let wrongReceipt = RelayPromptEditorRPC.Request(operation: .receipt, id: id, owner: owner,
        digest: String(repeating: "0", count: 64))
    #expect(!applied.isValid(for: wrongReceipt))
}

@Test func promptEditorUnsupportedResponseRequiresExplicitBoundArm() throws {
    let owner = RelayPromptOwnerBinding(version: 1, paneId: UUID().uuidString.lowercased(),
        nodeBootId: "owned-kernel", workerPid: 101, workerStart: 102, shellPid: 103, shellStart: 104,
        provider: "claude", processId: 105, processStart: 106, sessionId: "owned-session",
        transcriptIdentity: "input:" + String(repeating: "a", count: 48), inputOnly: true)
    let id = String(repeating: "b", count: 32)
    let request = RelayPromptEditorRPC.Request(operation: .arm, id: id, owner: owner)
    let encoder = JSONEncoder()
    let wireOwner = try #require(try JSONSerialization.jsonObject(with: encoder.encode(owner)) as? [String: Any])
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    func response(_ overrides: [String: Any] = [:]) throws -> RelayPromptEditorRPC.Response {
        var fields: [String: Any] = ["state": "unavailable", "unsupported": true, "id": id, "owner": wireOwner]
        fields.merge(overrides) { _, new in new }
        return try decoder.decode(RelayPromptEditorRPC.Response.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    let supportedFallback = try response()
    #expect(supportedFallback.isValid(for: request))
    #expect(supportedFallback.isExplicitlyUnsupported(for: request))
    for state in ["refused", "unarmed", "busy"] {
        let refused = try response(["state": state])
        #expect(!refused.isExplicitlyUnsupported(for: request))
        #expect(!refused.isValid(for: request))
    }
    #expect(!(try response(["unsupported": false])).isExplicitlyUnsupported(for: request))
    #expect(!(try response(["unsupported": NSNull()])).isExplicitlyUnsupported(for: request))
    #expect(!(try response(["id": String(repeating: "c", count: 32)])).isValid(for: request))
    #expect(!(try response(["owner": NSNull()])).isValid(for: request))
    var changed = wireOwner; changed["process_start"] = 999
    #expect(!(try response(["owner": changed])).isValid(for: request))
    let snapshot = RelayPromptEditorRPC.Request(operation: .snapshot, id: id, owner: owner)
    #expect(!supportedFallback.isValid(for: snapshot))
}
