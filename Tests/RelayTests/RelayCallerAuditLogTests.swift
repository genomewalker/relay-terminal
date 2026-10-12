import Combine
import Foundation
import Testing
@testable import Relay

private func auditDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("relay-audit-log-" + UUID().uuidString)
}

private func auditRequest(_ index: Int) -> RelaySidePanelHTTPRequest {
    let body = try! JSONSerialization.data(withJSONObject: ["operation": "exec", "request_id": "request-\(index)"])
    return RelaySidePanelHTTPRequest(method: "POST", path: "/api/host/request", headers: [:], body: body)
}

private func lines(_ url: URL) throws -> [Substring] {
    String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n")
}

@Test @MainActor func callerAuditAppendsWithoutRewritingCallerFile() async throws {
    let directory = auditDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = RelayCallerControl(directory: directory)
    _ = try await control.register(label: "Fixture", thread: nil)
    let callerFile = directory.appendingPathComponent("caller-control-v1.json")
    let before = try Data(contentsOf: callerFile)
    for index in 0..<3 { try control.record(caller: "client", request: auditRequest(index), outcome: "admitted") }
    #expect(try Data(contentsOf: callerFile) == before)
    let log = directory.appendingPathComponent("caller-audit-v1.jsonl")
    #expect(try lines(log).count == 3)
    #expect((try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(control.audit().map(\.requestID) == ["request-0", "request-1", "request-2"])
}

@Test @MainActor func callerAuditDoesNotPublishUIChanges() throws {
    let directory = auditDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = RelayCallerControl(directory: directory)
    var changes = 0
    let subscription = control.objectWillChange.sink { changes += 1 }
    defer { subscription.cancel() }
    for index in 0..<5 { try control.record(caller: "client", request: auditRequest(index), outcome: "admitted") }
    #expect(changes == 0)
    #expect(control.audit().count == 5)
}

@Test @MainActor func callerAuditPersistsAcrossInstancesInOrder() throws {
    let directory = auditDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = RelayCallerControl(directory: directory)
    for index in 0..<4 { try first.record(caller: "client", request: auditRequest(index), outcome: "http-200") }
    let restored = RelayCallerControl(directory: directory)
    #expect(restored.available)
    #expect(restored.audit().map(\.requestID) == ["request-0", "request-1", "request-2", "request-3"])
}

@Test @MainActor func callerAuditMigratesOldEmbeddedAuditOnce() throws {
    let directory = auditDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacy = (0..<3).map {
        RelayCallerControl.Audit(id: UUID(), at: Date(timeIntervalSince1970: Double($0)), caller: "old", path: "/api/x",
                                 operation: nil, requestID: "old-\($0)", tabID: nil, paneID: nil, jobID: nil, outcome: "admitted")
    }
    let callerID = UUID()
    let old: [String: Any] = [
        "callers": [["id": callerID.uuidString, "label": "Kept", "tokenHash": "hash", "paused": true]],
        "audit": try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)),
        "legacyPaused": true,
    ]
    let callerFile = directory.appendingPathComponent("caller-control-v1.json")
    try JSONSerialization.data(withJSONObject: old).write(to: callerFile)
    let migrated = RelayCallerControl(directory: directory)
    #expect(migrated.available)
    #expect(migrated.audit().map(\.requestID) == ["old-0", "old-1", "old-2"])
    #expect(!migrated.permitted("legacy-unattributed"))
    #expect(!migrated.permitted(callerID.uuidString.lowercased()))
    let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: callerFile)) as? [String: Any]
    #expect((rewritten?["audit"] as? [Any])?.isEmpty == true)
    // A second start must not import the old audit again.
    let again = RelayCallerControl(directory: directory)
    #expect(again.audit().count == 3)
}

@Test @MainActor func callerAuditDropsTornTailAndKeepsAppending() throws {
    let directory = auditDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = RelayCallerControl(directory: directory)
    for index in 0..<2 { try first.record(caller: "client", request: auditRequest(index), outcome: "admitted") }
    let log = directory.appendingPathComponent("caller-audit-v1.jsonl")
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"id\":\"torn".utf8))
    try handle.close()
    let restored = RelayCallerControl(directory: directory)
    #expect(restored.available)
    #expect(restored.audit().count == 2)
    try restored.record(caller: "client", request: auditRequest(2), outcome: "admitted")
    let reopened = RelayCallerControl(directory: directory)
    #expect(reopened.available)
    #expect(reopened.audit().map(\.requestID) == ["request-0", "request-1", "request-2"])
}

@Test @MainActor func callerAuditCorruptCompleteLineFailsClosed() throws {
    let directory = auditDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let log = directory.appendingPathComponent("caller-audit-v1.jsonl")
    try Data("not json\n".utf8).write(to: log)
    let control = RelayCallerControl(directory: directory)
    #expect(!control.available)
    #expect(throws: (any Error).self) { try control.identity(token: nil) }
    #expect(throws: (any Error).self) {
        try control.record(caller: "client", request: auditRequest(0), outcome: "admitted")
    }
    #expect(try Data(contentsOf: log) == Data("not json\n".utf8))
}

@Test func callerAuditLogCompactsInTheBackground() async throws {
    let directory = auditDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("caller-audit-v1.jsonl")
    let log = RelayCallerAuditLog(url: url, limit: 10)
    for index in 0..<21 {
        try log.append(RelayCallerControl.Audit(id: UUID(), at: Date(), caller: "client", path: "/api/x", operation: nil,
                                                requestID: "r-\(index)", tabID: nil, paneID: nil, jobID: nil, outcome: "admitted"))
    }
    for _ in 0..<100 where (try lines(url)).count > 10 { try await Task.sleep(for: .milliseconds(20)) }
    let kept = try log.load()
    #expect(kept.map(\.requestID) == (11..<21).map { "r-\($0)" })
    #expect(try lines(url).count == 10)
}
